# Azure Local OS configuration: the Ansible front end

An Ansible role (`azurelocal_os_configuration`) and a playbook (`os-configuration.yml`) that start
`scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1` for operators and teams that run
everything from Ansible or AWX. **The engine stays PowerShell 7.** Ansible does not configure the nodes, does not connect to them and
does not decide anything the wrapper decides: it starts `pwsh`, gives the wrapper its parameters, puts a pause for approval between Plan
and Apply, surfaces `report.json` as facts and fails with the wrapper's exit code. What the wrapper does, step by step, is in
[OS configuration and ARM Validate/Deploy](../../docs/os-configuration-and-arm-deployment.md).

## What runs where

```text
ansible-playbook (controller, or an AWX execution environment / runner)
  -> pwsh -File Invoke-OsConfigurationFromAnsible.ps1      (launcher: builds -Credential from the environment, nothing else)
       -> Invoke-AzureLocalOsConfiguration.ps1 -Mode Plan|Apply ...
            -> Azure Arc Run Command (ZTP nodes)  or  WinRM TCP 5985 (ISO-installed nodes)  ->  the Azure Local nodes
```

The nodes are not Ansible hosts. The play runs on **one runner** (the inventory group `os_config_runner`, usually `localhost` with
`ansible_connection: local`). The runner needs:

- PowerShell 7 (`pwsh`) with the `powershell-yaml`, `Az.Accounts` and `Az.KeyVault` modules;
- an Azure sign-in (`Connect-AzAccount`, a pipeline login, or `azurelocal_os_configuration_azure_auth: ManagedIdentity`);
- a checkout of this repository (the default `azurelocal_os_configuration_toolkit_root` is the checkout the playbook runs from);
- for ISO-installed nodes, and for `hardware.sbe.delivery: winrm_copy`, a route to the nodes' management addresses on TCP 5985
  (WinRM, the default for ISO nodes; from a Linux runner the PSWSMan module is needed for Negotiate). ZTP-provisioned nodes need only Azure.

The Solution Builder Extension is **opt-in**. The role never sets or implies an SBE: with no `hardware.sbe` in `infrastructure.yml` the Sbe and Drivers steps are not applicable, and with one nothing is copied to the nodes unless you set `hardware.sbe.delivery` (`winrm_copy` or `node_pull`) in that file. The default step list (`azurelocal_os_configuration_steps: []`) therefore delivers nothing by itself.

The `infrastructure.yml` and the ZTP handoff files are paths **on the runner**.

## Run it

```bash
cd ansible/os-configuration
cp inventory/hosts.yml.example inventory/hosts.yml        # edit: infrastructure file, handoff path
ansible-playbook os-configuration.yml --check             # Plan only. Reads the nodes, changes nothing.
ansible-playbook os-configuration.yml                     # Plan, pause for approval, Apply
```

1. **Plan** runs `-Mode Plan` (read only). The play prints the wrapper's `summary.md` and the storage wipe list.
2. **Approval.** The play pauses and shows the same summary and wipe list. Only the answer `yes` continues; anything else, or the timeout
   (`azurelocal_os_configuration_approval_timeout_minutes`), fails the run with nothing changed. Set
   `azurelocal_os_configuration_approved: true` to skip the pause on an unattended run.
3. **Apply** runs `-Mode Apply`. The wrapper plans each node again before it changes it, so it never acts on a stale plan, then verifies
   with another Plan pass.

**Check mode (`--check`) is the Plan only**, whatever `azurelocal_os_configuration_phase` says. The Plan is read only, so it really runs in
check mode; Apply never does.

### In AWX

`ansible.builtin.pause` needs a terminal, so in AWX split the run into a workflow: job template 1 with
`azurelocal_os_configuration_phase: plan`, an **approval node**, then job template 2 with `azurelocal_os_configuration_phase: apply` and
`azurelocal_os_configuration_approved: true` (the apply phase refuses to start without it). The plan job publishes the summary and wipe
list as the play output and the exit codes, report folder and node lists as workflow artifacts (`set_stats`). The execution environment
needs `pwsh` and the modules above; the project is a checkout of this whole repository.

## The node credential

Needed only for ISO-installed nodes reached over WinRM. For ZTP nodes, and when both values below are empty, the wrapper reads
`identity.local_admin` from the Key Vault as always.

The credential is **never a command line argument, a file or a log line**. It reaches the wrapper only through the environment of the one task that
starts `pwsh`, and that task has `no_log: true`:

| Source | How |
| --- | --- |
| ansible-vault | Copy `inventory/vault.yml.example` to `inventory/group_vars/os_config_runner/vault.yml`, fill it, run `ansible-vault encrypt` on it, and set `azurelocal_os_configuration_node_admin_user` and `azurelocal_os_configuration_node_admin_password: "{{ vault_azl_node_admin_password }}"`. Run with `--ask-vault-pass` or `--vault-password-file`. |
| Environment variable | `AZL_NODE_ADMIN_USER` and `AZL_NODE_ADMIN_PASSWORD` in the environment of `ansible-playbook` (in AWX, a custom credential type that injects them). The role's defaults read them. |

The launcher turns them into the wrapper's `-Credential` and removes the password from its own environment before the wrapper starts, so no
child process inherits it. The task is `no_log`, so the wrapper's console output is not shown by Ansible; the play shows `summary.md`,
`wipe-list.txt` and, on failure, the errors from `report.json` instead. Do not run with `ANSIBLE_DEBUG=1` on a real run: debug output is
not covered by `no_log`. Keep `inventory/hosts.yml` and `inventory/group_vars/` out of Git (this folder's `.gitignore` does).

## ZTP or ISO: the wrapper decides

The play does not look at handoff files, Arc machines or WinRM. `-Method Auto` and `-Transport Auto` (the defaults) let the wrapper work
out, per node, whether it was provisioned by ZTP (Arc Run Command) or installed from an ISO (WinRM), from `scenario.os_install` in
`infrastructure.yml` and from what answers. A cluster can mix both. The result is in the report per node and is surfaced as the fact
`azurelocal_os_configuration_node_methods`. Set `azurelocal_os_configuration_method: Ztp|Iso` or `azurelocal_os_configuration_transport:
ArcRunCommand|WinRM` only to force it for every node, exactly as `-Method` and `-Transport` do.

## Variables

Each role variable passes one wrapper parameter. Empty values are left out, so the wrapper's own defaults apply.

| Wrapper parameter | Role variable | Default |
| --- | --- | --- |
| `-InfrastructureFile` | `azurelocal_os_configuration_infrastructure_file` | required |
| `-HandoffPath` | `azurelocal_os_configuration_handoff_path` | `[]` |
| `-Node` | `azurelocal_os_configuration_nodes` | `[]` (every node) |
| `-Step` | `azurelocal_os_configuration_steps` | `[]` (the steps of each node's method) |
| `-Mode` | set by the phase: `Plan`, then `Apply` | |
| `-ReportDirectory` | `<report_root>/<UTC time>/plan` and `.../apply` on the runner | `/var/tmp/azurelocal-os-configuration` |
| `-ContinueOnNodeFailure` | `azurelocal_os_configuration_continue_on_node_failure` | `true` |
| `-Transport` | `azurelocal_os_configuration_transport` | `Auto` |
| `-Method` | `azurelocal_os_configuration_method` | `Auto` |
| `-ClearStorage` | `azurelocal_os_configuration_clear_storage` | `false` |
| `-ConfirmWipeDeployedCluster` | `azurelocal_os_configuration_confirm_wipe_deployed_cluster` (Apply phase only) | `false` |
| `-ApprovedWipeList` | `azurelocal_os_configuration_approved_wipe_list` | empty (in the phase `both`: this play's Plan `wipe-list.json`) |
| `-ApprovedBootstrap` | `azurelocal_os_configuration_approved_bootstrap` (Apply phase only) | `false` |
| `-EventLogPath` | `azurelocal_os_configuration_event_log_path` | empty (`os-configuration-events.jsonl` in the report folder of the phase) |
| `-FailOnPendingChanges` | `azurelocal_os_configuration_fail_on_pending_changes` (Plan phase only) | `false` |
| `-ConfigPath` | `azurelocal_os_configuration_config_path` | empty |
| `-Settings` | `azurelocal_os_configuration_settings` | `{}` |
| `-NodeAddress` | `azurelocal_os_configuration_node_address` | `{}` |
| `-SkipValidation` | `azurelocal_os_configuration_skip_validation` | `false` |
| `-Credential` | the environment variables above (never a variable in a file) | none |

Run control and runner: `azurelocal_os_configuration_phase` (`both`, `plan`, `apply`), `azurelocal_os_configuration_approved`,
`azurelocal_os_configuration_approval_timeout_minutes`, `azurelocal_os_configuration_toolkit_root`, `azurelocal_os_configuration_pwsh`,
`azurelocal_os_configuration_azure_auth` (`None` or `ManagedIdentity`), `azurelocal_os_configuration_report_root`. The role validates them
with `meta/argument_specs.yml`, which carries the same allowed values as the wrapper's `ValidateSet`.

## Result: exit codes and facts

The play fails when the wrapper's exit code is not 0, with the wrapper's meaning (the play never continues from a failed Plan to Apply):

| Exit code | Meaning |
| --- | --- |
| 0 | Apply: every node converged. Plan: every node could be read and nothing is blocked (pending changes are expected). |
| 1 | A node failed, is blocked or did not converge; or the nodes do not see the same SAN disks. |
| 2 | Bad input or nothing reachable. Nothing was changed. |

The failure message also carries the wrapper's message, the cluster problems, the node errors and the report folder. Facts set on the runner
(also when the run fails, before the failure): `azurelocal_os_configuration_exit_code`, `azurelocal_os_configuration_exit_codes` (by phase),
`azurelocal_os_configuration_report` (the last `report.json`, parsed), `azurelocal_os_configuration_reports` (`plan` and `apply`),
`azurelocal_os_configuration_summary`, `azurelocal_os_configuration_wipe_list`, `azurelocal_os_configuration_nodes_converged`,
`azurelocal_os_configuration_nodes_not_converged`, `azurelocal_os_configuration_node_methods`, `azurelocal_os_configuration_report_directory`.

## Checks

```powershell
Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/ansible      # YAML parses, no_log, no secrets, parameters match the wrapper
```

```bash
cd ansible/os-configuration
yamllint .
ansible-lint
ansible-playbook os-configuration.yml --syntax-check
```

The Pester test parses the files and runs the launcher against a stub wrapper; it does not run Ansible. `.yamllint` and `.ansible-lint` here
apply to this folder only. The older `src/ansible` tree is a separate, Windows-host oriented set of roles and is not used by this front end.
