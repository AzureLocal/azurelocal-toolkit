# Ansible for Azure Local

Ansible roles and playbooks for the on-premises steps of an Azure Local deployment: the domain controllers, Active Directory preparation, node OS configuration, Azure Arc registration and the monitoring agent, and the self-hosted CI/CD runners. They are an alternative route to the PowerShell scripts in `scripts/deploy` for the same tasks. Do not run both routes for the same step.

The values come from `infrastructure.yml` (owner directive D121). The roles have no values of their own for the facts of an environment (names, addresses, domain, cloud, versions): `config/variables/scripts/New-IacVariableFiles.ps1` writes the inventories and the variable files from the file, and the registry says, for every variable, which key it comes from. `tests/variables/AnsibleValues.Tests.ps1` fails when a deployment value is written into the code.

## Quick start

```powershell
# 1. Write the inventories and the variable files from infrastructure.yml, into the inventory folder (git ignores them there).
pwsh config/variables/scripts/New-IacVariableFiles.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory D:\work\iac -Target Ansible
```

```bash
# 2. Install the collections.
ansible-galaxy collection install -r src/ansible/collections/requirements.yml

# 3. Put the generated files in the inventory folder: hosts.yml, cicd-runners.yml, group_vars/ and host_vars/.
cp -r D:/work/iac/ansible/inventory/* src/ansible/inventory/

# 4. Pass the secrets at run time, then run all playbooks in order. Phase 3 needs the infrastructure file itself.
ansible-playbook -i src/ansible/inventory/hosts.yml src/ansible/playbooks/site.yml -e @vault.yml \
  -e azurelocal_os_configuration_infrastructure_file=./infrastructure.yml
```

`inventory/hosts.yml.example` and `inventory/cicd-runners.yml.example` are the generator's output for `config/variables/examples/infrastructure.example.yml`, and `tests/variables/fixtures/ansible/inventory/` holds its `group_vars` and `host_vars`; a test keeps them current. `inventory/hosts.yml`, `inventory/cicd-runners.yml`, `inventory/group_vars/` and `inventory/host_vars/` are git-ignored.

## Secrets

No secret is in a variable file, and no role generates a password. The LCM user password and the DSRM password are read on the controller from the Key Vault secrets that `identity.active_directory.lcm_user.password` and `landing_zone.virtual_machines[].dsrm_password` reference (the same secrets the deployment reads). The variables below are never written. Pass them with Ansible Vault (`-e @vault.yml`) or the environment at run time:

| Variable | The file holds the reference at |
| --- | --- |
| `domain_admin_password` | `identity.active_directory.domain_join_account.password`, or `identity.active_directory.lcm_user.password` |
| `spn_client_secret` | `devops.authentication.client_secret` |
| `lcm_password`, `dc_dsrm_password` | only when the reference is not `keyvault://` |
| `ansible_password` (Windows runners), `ansible_ssh_private_key_file` (Linux runners, `--private-key`) | |
| `cicd_runner_registration_token` | (only with `cicd_runner_token_source: variable`) |

```bash
ansible-vault create vault.yml     # domain_admin_password, spn_client_secret
```

## Where each variable comes from

Every variable of the inventories, `group_vars/all.yml`, `host_vars`, and the role `defaults` and `vars` is registered in `config/variables/schema/master-registry.yaml` (`tools.ansible.variables`) with its class, source, `infrastructure_key` and `target`. See [Terraform and Ansible variable files](../../config/variables/docs/infrastructure-file.md#terraform-and-ansible-variable-files-schema-5617). A test fails when a variable is declared and not registered, registered and not declared, or when the registry default differs from the role default.

## Structure

```
src/ansible/
├── ansible.cfg                  # no become method: the plays set become themselves
├── collections/requirements.yml
├── inventory/
│   ├── hosts.yml.example        # generated: nodes[] and landing_zone.virtual_machines[] (also grouped by role)
│   └── cicd-runners.yml.example # generated: devops.runners[]
├── roles/
│   ├── ad-preparation/          # the OU and the LCM user (New-HciAdObjectsPreCreation), security groups, computer objects
│   ├── arc-registration/        # Azure Arc registration of the nodes
│   ├── monitoring-agents/       # Azure Monitor Agent extension, Azure Local Insights step
│   ├── domain-controller/       # AD DS promotion of management VMs, DNS forwarders
│   ├── wac-server/              # Windows Admin Center: deferred, no playbook runs it
│   ├── syslog-receiver/         # syslog forwarding: parked, no playbook runs it
│   └── cicd_runner/             # self-hosted CI/CD runner on an existing host
└── playbooks/                   # 00-cicd-runner, 01-ad-preparation, 02-os-configuration, 03-arc-registration, 04-monitoring-setup, 05-management-vms, site
```

## Roles

- **domain-controller** (playbook 05): installs AD DS and promotes the VM as a new forest or a replica (`landing_zone.virtual_machines[].dc_promotion`), with the functional levels of `identity.active_directory` and the DSRM password from Key Vault. DNS forwarders: `identity.active_directory.dns_forwarders`; when empty, Azure DNS for a VM in Azure only.
- **ad-preparation** (playbook 01): runs Microsoft's `New-HciAdObjectsPreCreation` for the one dedicated OU (`identity.active_directory.ou_path`) and the LCM user, creates the security groups of `identity.active_directory.security_groups` in that OU with their members, the computer objects when `precreate_computer_objects` is true, and the conditional forwarders of the Azure Arc zones on a domain controller in Azure.
- **OS configuration** (playbook 02): runs the role of `ansible/os-configuration`, the front end of `Invoke-AzureLocalOsConfiguration.ps1`, on the controller. The wrapper reads `infrastructure.yml` itself. There is no second implementation in `src/ansible`.
- **arc-registration**: checks the endpoints of the cloud (`scenario.cloud`) and runs `Invoke-AzStackHciArcInitialization` on each node.
- **monitoring-agents**: installs the Azure Monitor Agent extension on each node and notes the Azure Local Insights step. It creates no data collection rule: the rule Insights uses is the one the portal creates (`operations.monitoring.data_collection_rule`).
- **wac-server**, **syslog-receiver**: out of scope (class d); kept, not run.
- **cicd_runner**: configures an existing Linux or Windows host as a runner. See `playbooks/00-cicd-runner.yml` and the generated `inventory/cicd-runners.yml`.

## Collections

| Collection | Version | Purpose |
| --- | --- | --- |
| `azure.azcollection` | >= 2.4.0 | Azure resource management, Key Vault secrets |
| `microsoft.ad` | >= 1.5.0 | Active Directory (groups, computers, domain controllers) |
| `ansible.windows` | >= 2.3.0 | Core Windows modules |
| `community.windows` | >= 2.2.0 | Extended Windows modules |
| `community.general` | >= 9.0.0 | General utilities |

## Prerequisites

- Control node: Linux or macOS with Ansible 2.15 or later and Python 3.10 or later, signed in to Azure (the Key Vault secrets are read there). PowerShell 7 for playbook 02.
- Targets: WinRM with Kerberos, reachable on port 5986.
- Credentials: a domain account and the Azure service principal, passed at run time.
