# OS configuration and ARM Validate/Deploy: prerequisites and run guide

This page covers the two steps that run after azurelocal-ztp (or an ISO install) has handed off provisioned machines:

1. **OS configuration** (Phase 03): `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1` runs it for the whole instance in one go (plan, apply, verify, one report); it calls `Set-AzureLocalNodeConfiguration.ps1` in the same folder once per node, which you can also run on its own
2. **ARM Validate, then Deploy** (Phase 05): `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalClusterDeployment.ps1`, with `New-AzureLocalArmParameters.ps1` for the parameter file alone.

Both read the one environment file, `infrastructure.yml` (schema 5). This page doesn't repeat what each key means: see the [schema-wide variables reference](../config/infrastructure/VARIABLES.md) and `config/infrastructure/README.md`. What it adds is what must be true before you run, and which of it the code checks.

In the tables, **Checked** says what happens if the item is missing:

- **Code**: the script checks it and stops (or blocks the node) with a message.
- **Azure**: the script doesn't check it, but the Azure call fails and the script reports Azure's error.
- **You**: nothing checks it. You make it true before the run.

## What runs where

| Step | Command (plan: reads, changes nothing) | Add `-Execute` to |
| --- | --- | --- |
| OS configuration | `Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json` | change the nodes. Re-running on a configured node changes nothing. |
| OS configuration, the whole instance in one run | `Invoke-AzureLocalOsConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffPath ./ztp-state -Mode Plan` | use `-Mode Apply`. See [Run it in one go](#run-it-in-one-go). Also runs unchanged in GitHub Actions and GitLab CI. |
| ARM parameters only | `New-AzureLocalArmParameters.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath <report>` | (reads files only; always safe) |
| ARM Validate | `Invoke-AzureLocalClusterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath <report>` | submit `deploymentMode Validate` to the resource group, wait, report the validation steps. |
| ARM Deploy | the same with `-Mode Deploy` | submit the real deployment. A separate, explicit run; needs a successful Validate. |

The OS configuration plan reads each node through Azure Arc Run Command, which creates and deletes one transient `runCommands` resource per read; nothing on the node changes. `-SpecOnly` reads no node and no Azure resource: it prints what each node should look like. The ARM plan (no `-Execute`) reads files only, unless you add `-Preflight`.

Order: ZTP hand-off (or an ISO install), OS configuration (`Invoke-AzureLocalOsConfiguration.ps1 -Mode Plan`, review the plan and the wipe list, then `-Mode Apply`; it writes a JSON report), then ARM Validate, review, then ARM Deploy.

![Azure Local OS configuration: from the ZTP handoff through the management address modes and each step to ARM Validate and Deploy](./diagrams/os-configuration-flow.png)

The diagram source is [`diagrams/os-configuration-flow.drawio`](diagrams/os-configuration-flow.drawio). It follows one run: the ZTP handoff (schema 2) and `infrastructure.yml` are read and validated; each node's management address mode (A DHCP with reservation, B static with DHCP on management, C static without management DHCP) decides what the Network step does; then the steps run in the order the script runs them, with a tag on each that says whether it skips when already correct, only reads, or only runs on request; the SBE package is delivered last by the route `hardware.sbe.delivery` names; the node is read again until it matches, and the report feeds ARM Validate and then ARM Deploy (Phase 05). The diagram draws the node script, `Set-AzureLocalNodeConfiguration.ps1`; the one-run command described next wraps it.

**The whole flow, in one place.**

1. `Invoke-AzureLocalOsConfiguration.ps1` reads `infrastructure.yml` and every ZTP handoff, and works out each node's **method** (ZTP or ISO) from the file and from what answers: see [Which method?](#which-method).
2. **Plan** for all nodes, read only. The plan lists every item per node (the diagram's steps, in that order, the Sbe step last), and, when `os_configuration.clear_storage` is on, the disks that would be wiped ([Storage wipe](#storage-wipe-os_configurationclear_storage)). A person approves this output.
3. **Apply**, node by node. Each node's steps run in the order in the diagram. The SBE package is delivered last, by the route `hardware.sbe.delivery` names ([How the package reaches the nodes](#how-the-package-reaches-the-nodes)); a package that can't be delivered never stops the other steps.
4. **Verify** with a Plan pass; a node is converged only when nothing is left to change.
5. **Report** (`report.json`, `summary.md`) and exit code. `report.json` feeds ARM Validate, then ARM Deploy.
The full cross-tool matrix is in the toolkit's [access-and-connectivity page](access-and-connectivity.md).

## Run it in one go

`Invoke-AzureLocalOsConfiguration.ps1` (same folder as `Set-AzureLocalNodeConfiguration.ps1`) does the whole OS configuration phase for the whole instance in one run: every handoff file, every node, plan, apply, verification, one report. The same command runs on an operator's workstation and, unchanged, in a pipeline; there is nothing pipeline-specific in it. It calls `Set-AzureLocalNodeConfiguration.ps1` once per node and adds the parts around it.

```powershell
# Plan: reads every node, changes nothing, writes the plan report and the wipe list
./scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1 `
    -InfrastructureFile ./infrastructure.yml -HandoffPath ./ztp-state -Mode Plan -ReportDirectory ./osconfig-report

# Apply: the same command with -Mode Apply
./scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1 `
    -InfrastructureFile ./infrastructure.yml -HandoffPath ./ztp-state -Mode Apply -ReportDirectory ./osconfig-report
```

| Parameter | Meaning |
| --- | --- |
| `-InfrastructureFile` | The master `infrastructure.yml`. Required. |
| `-HandoffPath` | A handoff file, several files, or a directory. Every `*.ztp-handoff.json` found is merged into one node-to-handoff map. A node in two files is an error that names both files. Optional: a cluster installed from ISO has no handoff. |
| `-Node`, `-Step` | Limit the run to some nodes or steps. |
| `-Mode` | `Plan` (default) or `Apply`. |
| `-ReportDirectory` | Where `plan-report.json`, `report.json`, `summary.md`, `wipe-list.txt` and `node-reports/` go. |
| `-ContinueOnNodeFailure` | Default `$true`: a node that fails does not stop the others. `-ContinueOnNodeFailure:$false` stops at the first failure and marks the rest skipped. |
| `-Transport`, `-Method` | `Auto` (default) works both out per node; force `ArcRunCommand`/`WinRM` or `Ztp`/`Iso` for all nodes. |
| `-Credential`, `-NodeAddress` | The local administrator for WinRM (default: `identity.local_admin`, password from the Key Vault) and the address to reach a node on when the installer's address is not in the file. Used for ISO-installed nodes, and, on a ZTP node reached over Arc, only to copy the SBE package when `hardware.sbe.delivery` is `winrm_copy`. |
| `-ClearStorage` | Forces the storage wipe on (see below). |
| `-ConfigPath`, `-Settings` | Optional run settings (JSON file, then a hashtable that wins): `retryTries`, `retryDelaySeconds`, `maxPasses`, `noRestart`, `failOnPendingChanges`, `nodeAddress`. |
| `-FailOnPendingChanges` | Plan mode: exit 1 when any change is pending (drift detection). |

### What the run does, in order

1. **Validate the inputs.** The master file, the handoff map, the method and transport of every node, the Azure sign-in, and for ISO nodes the route, the credentials and the OS build. A failure here stops the run with exit code 2 before anything is changed.
2. **Plan for all nodes** (read only). Writes `plan-report.json` and `wipe-list.txt`.
3. **Apply** (`-Mode Apply`), node by node, each node's steps in the order of the diagram with the SBE package last. With an Active Directory design the order is Network, Dns, Time, Hostname, UnusedAdapters, **DomainJoin** (see [Joining the domain](#joining-the-domain)), LocalAdmin, MPIO, then the rest. A node whose plan says the package is NOT DELIVERED (`hardware.sbe.delivery` is `skip`) is not failed; its record carries a warning.
4. **Verify**: a Plan pass on every node that was changed. A node is *converged* only when this pass finds nothing left to change. The status of the commands that did the work does not decide it. A node with nothing to change in the plan is converged by the plan itself and is not read again.
5. **Report**: `report.json` (per node: method and evidence, steps, plan, changes, errors, converged, restarted), `summary.md` and a table on the console.

### Which method?

OS configuration always starts after the OS is installed, however it was installed. Each node is resolved on its own, so a cluster can mix both.

- **Declared**: `scenario.os_install` (`iso` or `simplified`) in the master file.
- **Evidence**: (a) a ZTP handoff for the node that says `ready`, (b) an Arc machine for the node that is `Connected` (found by the handoff's resource ID, else by host name in `azure.resource_group`), (c) the node answers on WinRM (TCP 5985) at `nodes[].management.ip_address` or `maintenance_address` (`-NodeAddress` overrides). (c) is tried only when (a) and (b) are missing.

| Declared | Evidence | Path | |
| --- | --- | --- | --- |
| simplified | ready handoff, or a Connected Arc machine | ZTP | |
| iso | ready handoff | ZTP | warning naming both; fix `scenario.os_install` |
| iso | Connected Arc machine, no handoff | ISO, reached over Arc | already registered |
| iso | answers on WinRM | ISO, reached over WinRM | |
| simplified | no ready handoff, no Arc machine, answers on WinRM | ISO | warning naming both |
| any | nothing reachable | none | exit 2 with what was tried |
| any | a handoff for another subscription or resource group than the master file | none | exit 2: contradictory evidence |

The result is in the report, per node (`method.declared`, `method.resolved`, `method.source`, `evidence`), and printed at the start. `-Method Ztp|Iso` forces it.

| | ZTP path | ISO path |
| --- | --- | --- |
| Reached with | Azure Arc Run Command (ARM only; no network path to the nodes) | WinRM with the local administrator from the master file, from a host that reaches the node's management address (or Arc Run Command when the machine is already a Connected Arc machine) |
| Verified, not redone | OS build, Arc machine connected, the computer name ZTP gave, the handoff's `ready` | |
| Done | management static address by MAC, DHCP off on the other ports, DNS, NTP, unused ports, local admin, RDP/ICMP, OEM drivers, MPIO and SAN verification, storage wipe when on, and last the SBE package (by `hardware.sbe.delivery`) | all of those, plus the computer name (restart), and Azure Arc registration |
| Up front | | route to TCP 5985, credentials, OS caption and build 25398 or later; each failure names the node and says what to fix |

Arc registration on the ISO path runs `Invoke-AzStackHciArcInitialization` on the node with the ARM token of the run's own Azure sign-in (passed as a secret; never written), into `azure.resource_group`, with the Arc gateway from `networking.outbound.arc_gateway` when the outbound path uses one. It then waits for the Arc machine to be Connected. The older Phase 04 registration scripts take a different, interactive configuration, so they are not used here. WinRM from a Linux runner needs the PSWSMan module for Negotiate authentication.

### Storage wipe: `os_configuration.clear_storage`

Leftover local storage (storage pools, virtual disks, the data on local disks) is wiped only when the master file says so:

```yaml
os_configuration:
  clear_storage: true   # default false
```

`-ClearStorage` forces it on. The wipe happens only in Apply mode, and only to what the plan listed. Boot, system, SAN (Fibre Channel, iSCSI) and USB disks are never touched. With `clear_storage` on, the run prints, before anything is applied, exactly which disks on which node will be wiped, taken from the plan, and writes the same list to `wipe-list.txt` and the end of `summary.md`:

```text
STORAGE WIPE (os_configuration.clear_storage in the master file). Local disks that WOULD BE WIPED if you apply. ...
  tplabs-azl-n01: 1 pool(s), 2 virtual disk(s), disks: 3 (1000 GB) ...
```

With it off, leftover storage is reported as blocking (exit 1) and nothing is wiped.

### Joining the domain

With `scenario.identity: active_directory` the OS configuration joins every node to the domain, into the OU from the file, **before** the ARM validation and the deployment (the `DomainJoin` step). With `local_identity` the step reports one item, `not applicable: local identity`, and does nothing.

**What it does.** For each node, in the order of the run: Network, Dns, Time and Hostname first (the join needs the domain controllers reachable by name, clocks within 5 minutes and the final computer name), then `DomainJoin`, then LocalAdmin, MPIO and the rest. Both methods run it (ZTP nodes are named by ZTP; ISO nodes get their name from the Hostname step first). On an ISO node it runs **before** the Arc registration: registration does not need the join, and the join restarts the node, so the registration waits for it. The step:

1. **Reads** (plan, nothing changed): `PartOfDomain` and `Domain`, the computer's distinguished name when joined (so its OU), DNS resolution of the domain and the domain controller SRV record, a TCP check of the controllers, the clock difference to a controller, `Test-ComputerSecureChannel` when joined, the computer name against the file, whether the node is already in a cluster, the local Administrators group, and (with the join credential, over LDAP from the node) the OU itself: that it exists, whether Group Policy inheritance is blocked (`gPOptions`), and which GPO links above it are Enforced.
2. **Compares**: joined to the right domain and OU = Ok; not joined = Change; a different domain, a different computer name, DNS that cannot resolve the domain, no domain controller, a clock more than 5 minutes apart, an OU that does not exist or does not block inheritance (in `dev`, `production` and `dmz`) = **Blocked**, with every reason in the note. An earlier step that still has a change makes the join wait (Skipped); the next pass of the same run does it.
3. **Joins**: `Add-Computer -DomainName <domain_fqdn> -OUPath <ou_path> -Credential <account> -Restart:$false` on the node, in Windows PowerShell 5.1. The credential is built on the node from a secure string made from the secret, which the run read from Key Vault. Then the **guarded restart**: a durable marker (`C:\ProgramData\AzureLocal\osconfig\domainjoin-state.json`, written to a temporary file, flushed to disk, renamed) says a restart is expected; a one-time startup task resumes and verifies after the restart even if the run has died; the node refuses to restart without the marker; the run reconnects over the same transport (the WinRM address from the file, or Arc) and verifies **PartOfDomain true, the right domain, `Test-ComputerSecureChannel`, the right OU**, then completes the marker.
4. **Adds the local administrators**: the principals of `identity.active_directory.local_admin_members` (default: the `security_groups` entry whose `purpose` says it administers the instance, and the LCM user) are added to the node's local Administrators group, idempotently, after the join and the restart. A domain account is not a local administrator by default; the deployment adds the LCM user itself later. This is what lets Kerberos remoting and Sonar's log access use a domain account.

**The account.** The default is the **LCM user** (`identity.active_directory.lcm_user`, password by `keyvault://` reference). Microsoft's Active Directory preparation gives it the right to create and delete computer objects in the dedicated OU, and it is the account used for domain-join actions such as repairing or adding a node. To use another account set `identity.active_directory.domain_join_account` (username and password reference); it needs the same rights on `ou_path`. What the account needs on the OU (Microsoft, [Custom Active Directory configuration](https://learn.microsoft.com/azure/azure-local/plan/configure-custom-settings-active-directory)):

| On the OU and its descendants | Permission |
| --- | --- |
| Computer objects | List contents, read all properties, read permissions, **create** computer objects, **delete** computer objects |
| `msFVE-RecoveryInformation` objects below it | Full control (the BitLocker recovery keys; set with PowerShell, the delegation wizard cannot) |
| Resetting the password and writing `dNSHostName` and `servicePrincipalName` | Needed when a computer object already exists in the OU (pre-staged, or from an earlier join) |

`New-HciAdObjectsPreCreation` sets this up for the LCM user. The LCM user also needs *Log on as a batch job* and interactive logon (the default domain policy must not deny them); that is checked by the deployment, not here.

**The OU.** Azure Local requires a dedicated OU with Group Policy inheritance **blocked**; `New-HciAdObjectsPreCreation` creates it. The plan reads it:

| Finding | `dev`, `production`, `dmz` | `lab`, `test` |
| --- | --- | --- |
| OU does not exist | Blocked | Blocked |
| Inheritance not blocked | **Blocked** (nothing is joined) | warning, the join goes ahead |
| GPO links marked **Enforced** above the OU | warning | warning |

The class is `scenario.environment_class`; missing means `production`. Block Inheritance does not stop **Enforced** GPOs, so the plan names them and suggests what Microsoft suggests: a WMI filter on those GPOs that excludes the Azure Local machine accounts. (Microsoft's own at-scale advice links an Enforced GPO on the parent OU on purpose, for example to nest a domain group in the local administrators; then the warning is expected.) The characters `& " ' < >` are not allowed anywhere in `ou_path` (rule AZL-051).

**If the join fails.** The node stays in its workgroup and the report carries the exact error text from `Add-Computer`, its code and what to do. The join is **not retried in the same run** (a wrong password must not be sent twice; it would lock the account). The usual errors:

| Code | Meaning | What to do |
| --- | --- | --- |
| 1326 | the user name or password is wrong | check the account and the Key Vault secret; do not run again with the same values |
| 1355 | the domain does not exist or no controller answers | the management DNS servers must be the domain controllers (`domain_controllers`, rule AZL-052); check the route |
| 2224 | a computer object with that name already exists | delete it, or move it into `ou_path`; a pre-staged object **in** `ou_path` is fine if the account may reset its password |
| 5 | access denied | delegate the rights above on `ou_path` |
| 53, 1722 | network path not found, RPC server unavailable | routing and firewalls to the controllers (TCP 135, 389, 445 and the dynamic RPC range) |
| clock skew | more than 5 minutes from the controller | fix the Time step first |
| 1909, 1331 | account locked out or disabled | unlock or enable it |
| other | not mapped | the exact text is reported; look the code up in Microsoft Learn |

**Events** (the run's event feed, `os-configuration-events.jsonl`, step `DomainJoin`): `DomainJoinPlanned`, `DomainJoinApplying`, `NodeRestarting`, `NodeReconnected`, `DomainJoined`, `DomainAdminsConfigured`, `DomainJoinFailed` (with the AD error and the next action). `DomainJoined` is when Sonar switches the credential it uses for the node to the domain account. The password is in none of them, nor in the report.

**A node in the wrong OU, and how to move one.** A node already in the domain but in another OU than `ou_path` is **Blocked**, never moved by default. Microsoft states that moving the computer objects to a different OU **after the deployment is not supported**, so a node that is already part of a cluster is blocked whatever the file says: correct `ou_path` to where the objects are, or follow Microsoft's repair or add-node procedure. **Before the deployment** you can set `identity.active_directory.join_options.allow_ou_move: true`; the next Apply moves the computer object into `ou_path` (ADSI, with the join account) and the plan then shows Ok. A node joined to a **different domain** is Blocked and is never unjoined by the toolkit: run `Remove-Computer` on it yourself if that is what you want. A rename after the join is refused (`join_options.rename_after_join` is fixed to `false`).

**What was not tested.** The scripts and the comparison are tested with mocks only. Nothing here was run against a domain controller; run the first node as a canary.

**Note for the azurelocal.cloud automation guide.** Where the guide describes the one-run OS configuration, add: *"With an Active Directory design the OS configuration also joins each node to the domain and the dedicated OU (step DomainJoin, after Network, DNS, Time and Hostname, before the ARM validation), using the LCM user from `infrastructure.yml` unless `domain_join_account` is set. The plan checks that the OU exists and blocks Group Policy inheritance, and warns about Enforced GPOs; a node in another OU is blocked (Microsoft does not support moving computer objects after deployment). The nodes' local Administrators group gets `local_admin_members`. Events: DomainJoinPlanned, DomainJoinApplying, DomainJoined, DomainJoinFailed, DomainAdminsConfigured, NodeRestarting, NodeReconnected."* The Implementation guide keeps the manual route (Prepare Active Directory, then the join in the deployment).

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Apply: every node converged. Plan: every node could be read and nothing is blocked (pending changes are expected; `-FailOnPendingChanges` makes them exit 1). |
| 1 | A node failed, is blocked, or did not converge; or the nodes do not see the same SAN disks. |
| 2 | Bad input or nothing reachable: a missing file, a node in two handoffs, contradictory evidence, no sign-in for Arc, a precondition of the ISO path. Nothing was changed. |

### A run command that ends in state Unknown

Arc Run Command can end in state `Unknown` when the node's agent briefly loses its connection (for example while its network changes). The script on the node is safe to run again, so the run is retried with a growing pause (default 3 tries, 15 s, 45 s, then 120 s; `retryTries`, `retryDelaySeconds`). After the last try the node is **read again** and the next step is decided from what the read shows. If an Apply ended in `Unknown`, the report lists a change with status `unknown`, and the node is converged if the read (and the verification pass) shows it matches. A restart that ends in `Unknown` is not a failure: the run waits for a new boot time.

### How the plan and the approval gate work

The plan changes nothing, so it can run unattended. Its output is what a person approves: the plan table per node, the method and transport per node, and the wipe list. In a pipeline the Plan job publishes `plan-report.json` and `wipe-list.txt` as an artifact and puts `summary.md` (with the wipe list) in the job summary. The Apply job waits for an approval: a GitHub environment (`azure-local-os-configuration`) with required reviewers, or a GitLab manual job. Apply then re-plans each node itself, so it never acts on a stale plan.

### In a pipeline

| Platform | File | Gate |
| --- | --- | --- |
| GitHub Actions | `pipelines/github/os-configuration.yml` (copy to `.github/workflows/`) | Environment `azure-local-os-configuration` with required reviewers on the `apply` job |
| GitLab CI | `pipelines/gitlab/os-configuration.gitlab-ci.yml` | `when: manual` on the apply job; `resource_group` allows one run at a time |

Both run `pwsh -File .../Invoke-AzureLocalOsConfiguration.ps1 -InfrastructureFile ... -HandoffPath ... -Mode Plan|Apply -ReportDirectory ...` and nothing else; the logic is the script's. The runner is a self-hosted Linux runner with PowerShell 7 and the `powershell-yaml`, `Az.Accounts` and `Az.KeyVault` modules. ZTP-provisioned nodes need only Azure from the runner (with `hardware.sbe.delivery: node_pull` or `skip`); ISO-installed nodes, and the `winrm_copy` route of the SBE package, need a runner that reaches the nodes' management addresses on TCP 5985.

**Where the files come from.** The master `infrastructure.yml` is a path in the repository (`infrastructure_file` / `INFRASTRUCTURE_FILE`). The handoff files, `<node>.ztp-handoff.json` (one per ZTP run: nodes 1 and 2 may share a file, node 3 has its own), are either committed to the repository path `handoff_path` / `HANDOFF_PATH`, or published by the ZTP run as an artifact named `ztp-handoff`; the GitHub workflow takes the ZTP run's ID (`handoff_run_id`) and downloads it, and in GitLab the job lists the ZTP job in `needs`/`dependencies`. Point `-HandoffPath` at the folder: every handoff in it is merged. A handoff file holds the subscription ID and resource IDs of your environment, so keep it in a private repository or artifact.

**Permissions of the pipeline identity** (the federated app registration, or the runner's managed identity). The cross-tool matrix is in [access-and-connectivity](access-and-connectivity.md).

| Needed for | Role or permission | Scope |
| --- | --- | --- |
| Arc Run Command on the nodes (plan and apply) | Azure Connected Machine Resource Administrator (`Microsoft.HybridCompute/machines/runCommands/*`, `machines/read`) | The resource group of the Azure Local instance |
| The local administrator's password | Key Vault Secrets User (secret `get`) | The vault in `identity.local_admin.password` |
| Arc registration of ISO nodes | Azure Connected Machine Onboarding, and the rights the Arc initialization needs in `azure.resource_group` | The resource group |
| SBE package, `node_pull` | none for the pipeline identity: the nodes read `hardware.sbe.node_pull_url` themselves, so the location needs no Azure role (there is no storage account in this design) | |

No secret is stored in a pipeline file. IDs are variable names (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`).

## Operator host

| Tool | Version tested | Needed for | Checked |
| --- | --- | --- | --- |
| PowerShell | 7.4 or later (tested on 7.6) | everything; the scripts say `#Requires -Version 7.0` | Code |
| powershell-yaml | 0.4.12 | reading `infrastructure.yml` | Code |
| Az.Accounts | 5.5 | every Azure call (`Invoke-AzRestMethod`); `Connect-AzAccount` first | Code (stops if not signed in) |
| Az.KeyVault | 6.6 | reading the `keyvault://` secrets | Azure |
| Az.Resources | 10.2 | looking up the Azure Local resource provider's object ID (`Get-AzADServicePrincipal`), only if `azure.hci_resource_provider_object_id` is empty | Azure |
| Pester 5.9.1 | 5.9.1 | running the tests only. Import it explicitly (`Import-Module Pester -RequiredVersion 5.9.1`): Pester 6 runs zero tests here | You |
| PSScriptAnalyzer | 1.25 | linting only | You |

Network from the operator host: HTTPS to `management.azure.com`, `login.microsoftonline.com`, `*.vault.azure.net`, and (ARM execute only) `raw.githubusercontent.com` for Microsoft's quickstart template; `aka.ms` for the OEM's SBE manifest (skip with `-OfflineManifest`). **No path to the nodes' management subnet is needed** for the Arc transport, which reaches the nodes through Azure, with `hardware.sbe.delivery` `node_pull` or `skip`. `-Transport WinRM` (ISO-installed nodes) and the `winrm_copy` route of the SBE package are for a host that does have one.

The Azure CLI is not used.

## Azure roles

| Who | Role | Scope | Why | Checked |
| --- | --- | --- | --- | --- |
| Operator running OS configuration (Arc transport) | `Azure Connected Machine Resource Administrator` (includes `Microsoft.HybridCompute/machines/runCommands/write`) | the Arc machines' resource group | create, read and delete the Run Command that carries each node script | Azure |
| same | `Reader` | the Arc machines' resource group | find machines by name, read their status | Azure |
| Operator reading secrets | `Key Vault Secrets User` (RBAC vault) or an access policy with `get` | the management vault named in `key_vaults` | read `identity.local_admin` and the LCM user's passwords | Azure |
| Operator running ARM Validate/Deploy | `Azure Stack HCI Administrator` and `Reader` | the resource group of the Arc machines (`azure.resource_group`) | Microsoft's required roles for the person who deploys | Azure |
| same | `Key Vault Data Access Administrator`, `Key Vault Secrets Officer`, `Key Vault Contributor` | the same resource group | manage and write the deployment's own Key Vault (`cluster.key_vault`) | Azure |
| same | `Storage Account Contributor` | the same resource group | create the witness and diagnostics storage accounts | Azure |
| whoever registered the machines with Arc | `Azure Connected Machine Onboarding` and `Azure Connected Machine Resource Administrator` | the same resource group | done by ZTP or by hand before this step | You |
| subscription owner | contributor or owner, to register the providers | the subscription | `Microsoft.HybridCompute`, `GuestConfiguration`, `HybridConnectivity`, `AzureStackHCI`, `Kubernetes`, `KubernetesConfiguration`, `ExtendedLocation`, `ResourceConnector`, `HybridContainerService`, `Attestation`, `Storage`, `Insights`, `KeyVault` (Phase 02). Without `Microsoft.Insights` validation fails on the diagnostics account | You |

Source: [Assign required permissions for Azure Local deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions) and [Run command on Azure Arc-enabled servers](https://learn.microsoft.com/azure/azure-arc/servers/run-command).

Also for Arc Run Command: the Connected Machine agent on each node is version 1.33 or later, the node shows `Connected` (the script warns if not), and nothing blocks the Run Command extension (`azcmagent config get extensions.blocklist`). Azure Policy mustn't block extensions or the resource types the deployment creates in the resource group.

### Azure Policy and Defender during provisioning and deployment

Policies assigned at a management group or subscription with the **deployIfNotExists** or **modify** effect act on
new Arc machines as soon as they appear: they install extensions and agents or change machine settings (for example
"Configure periodic checking for missing system updates on Azure Arc-enabled servers"). That can collide with the
provisioning service and with OS configuration's Arc Run Command. Exempt the deployment resource groups from those
policies until the cluster is deployed, then remove the exemptions:

```powershell
# List what reaches the groups and what would be exempted (only deployIfNotExists and modify; audit and deny stay on)
./scripts/common/utilities/tools/Set-AzlDeploymentPolicyExemption.ps1 -SubscriptionId <sub> -ResourceGroupName <cluster-rg>,<AzLocal-ManagedResources-rg>
# Before provisioning: create the exemptions (category Waiver, expire after 7 days by default)
./scripts/common/utilities/tools/Set-AzlDeploymentPolicyExemption.ps1 -SubscriptionId <sub> -ResourceGroupName <cluster-rg>,<AzLocal-ManagedResources-rg> -Execute
# After the deployment succeeds: remove them
./scripts/common/utilities/tools/Set-AzlDeploymentPolicyExemption.ps1 -SubscriptionId <sub> -ResourceGroupName <cluster-rg>,<AzLocal-ManagedResources-rg> -Remove -Execute
```

- **Who can run it:** exempting an assignment needs `Microsoft.Authorization/policyAssignments/exempt/action` at the
  **assignment's** scope, not only the resource group's. For a policy assigned at a management group (often the tenant
  root group) that means Resource Policy Contributor or Owner on that management group; otherwise Azure answers
  "There was a problem while evaluating linked access checks". Ask the management group's policy owner if you lack it.
- **Defender for Servers is not a policy.** With the Defender for Servers plan on, Defender for Cloud installs the
  Defender for Endpoint extension (MDE.Windows) on new Arc machines by itself; an exemption doesn't stop it. If it
  interferes with provisioning (an extension install queued ahead of Arc Run Command), exclude the machines with
  Defender for Cloud resource-level pricing, or agree a window with whoever owns the plan. The script reports the plan.
- Exemptions expire on their own (`-ExpiresInDays`), so one forgotten after the deployment doesn't stay for good.

## Key Vault secrets

Secrets are never values in `infrastructure.yml`. Each is a `keyvault://<vault>/<secret>` reference, and the vault is listed under `key_vaults`.

| Secret (example name) | Referenced by | Rule | Used by | Checked |
| --- | --- | --- | --- | --- |
| `local-admin-password` | `identity.local_admin.password` | at least 14 characters with lower case, upper case, a digit and a special character | OS configuration creates the account; ARM `localAdminPassword` | Code (the schema checks the form; the account refuses the name `Administrator` or `Guest`) |
| `lcm-password` | `identity.active_directory.lcm_user.password` | same complexity; AD path only | ARM `AzureStackLCMAdminPassword` | Code (form), You (the account exists in AD) |

The deployment's local administrator is not the built-in Administrator: the deployment renames the account, and the vault's administrator can't be used. The scripts read the two secrets into memory and send them as Arc protected parameters and secure ARM parameters. They never reach the parameter file, the report or the log. `New-AzureLocalArmParameters.ps1 -SecretMode KeyVaultReference` writes ARM Key Vault references instead; that needs "Azure Resource Manager for template deployment" enabled on the vault.

## Active Directory (the AD path)

| Prepare | Detail | Checked |
| --- | --- | --- |
| A dedicated OU, not at the top of the domain, with Group Policy inheritance blocked | `identity.active_directory.ou_path`, for example `OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud`; none of `& " ' < >` in it | Code (the form, AZL-051; the plan reads that the OU exists and blocks inheritance), You (the OU) |
| The LCM user, in that OU | `lcm_user.username`: the name only, no domain, **20 characters or fewer** | Code (length), You (the account) |
| Microsoft's pre-creation tool | `Install-Module AsHciADArtifactsPreCreationTool`, then `New-HciAdObjectsPreCreation` with the LCM credential and the OU. It creates the OU's objects and the LCM user and sets the delegation. See [Prepare Active Directory](https://learn.microsoft.com/azure/azure-local/deploy/deployment-prep-active-directory) | You |
| Names | cluster name up to 15 characters and not a node name; node names up to 15 characters; `naming_prefix` is the prefix of the objects the deployment creates | Code |
| DNS resolves the domain from the nodes | the management DNS servers (`networking.management.dns_servers`) resolve AD, including the domain controllers' SRV records. **They can't change after deployment.** OS configuration sets them on the management port, and the DomainJoin step reads whether they resolve the domain and a controller SRV record (Blocked if not). | Code |
| Time | `networking.ntp_servers` reachable from the nodes; Kerberos needs clocks within 5 minutes | Code (sets and reports the source), You (reachable) |

**Local identity** is the alternative: no AD, secrets in the cluster Key Vault. Set `scenario.identity: local_identity` and `identity.local_identity` (`dns_server_config`: `use_dns_server` or `use_forwarder`, `dns_zone`, `dns_forwarders`). The generator then uses Microsoft's `create-adless-cluster-external-dns-public-preview` (Storage Spaces Direct) or `create-cluster-adless-san` (Fibre Channel). See [Local identity with Key Vault](https://learn.microsoft.com/azure/azure-local/deploy/deployment-local-identity-with-key-vault).

## What the deployment creates, and the names it needs free

| Item | Key | Detail | Checked |
| --- | --- | --- | --- |
| Cluster Key Vault | `cluster.key_vault.name`, `create_new`, `soft_delete_retention_days` | The deployment creates it (`create_new: true`) and keeps the instance's secrets there, one per instance. Name 3 to 24 characters, globally unique. Retention 7 to 90 days and can't be changed later. With `create_new: false` it must exist and the deployer needs the roles above | Azure |
| Witness storage account | `cluster.witness.type: cloud`, `storage_account` | Required for two machines and rack aware. The template creates it; the name is 3 to 24 lower-case letters and digits, globally unique. `file_share` is for disconnected operations and isn't generated | Code (type), Azure (name) |
| Diagnostics storage account | `cluster.diagnostics.storage_account` | Holds Key Vault audit logs (LRS, locked) | Azure |
| Infrastructure IP pool | `networking.management.infrastructure_pool.start`, `end` | **At least 6 contiguous addresses** in the management subnet, outside every node address and the gateway, and outside 10.244.0.0/16 and 10.96.0.0/24 (the Arc resource bridge). Unused and unrouted elsewhere | Code (the schema validator, rules AZL-005 and AZL-006) |
| Custom location | `azure.custom_location` | Created by the deployment; default `<cluster>-cl` | Azure |
| Azure Local resource provider object ID | `azure.hci_resource_provider_object_id` | Object ID of application `1412d89f-b8a8-4111-b4fd-e82905cbd85d` in your tenant. Empty: looked up when executing (needs to read the directory) | Azure |

## SBE (the OEM's Solution Builder Extension)

| Prepare | Detail | Checked |
| --- | --- | --- |
| A folder outside any repository | `hardware.sbe.bundle_path`, for example `D:\sbe\dell`: one `SBE_*.zip`, its `SBE_*.xml` and `SBE_Discovery_*.xml`, as downloaded from the OEM | Code |
| The package matches the OEM's hash | SHA-256 against the OEM's published discovery manifest (`config/oem/<vendor>.json`), else against the folder's own `SBE_Discovery_*.xml` | Code (a mismatch stops the run) |
| The OEM entry | `config/oem/dell.json` names the folders inside the zip that hold network drivers (`DriversGE/Network`). HPE and Lenovo are placeholders to fill before use | You |
| It reaches `C:\SBE` on every node | By `hardware.sbe.delivery` (schema 5.4.2), see **How the package reaches the nodes** below. A node that already holds the right files (SHA-256) needs no delivery. There is no storage account route | Code |
| ARM values | `sbeVersion`, `sbeFamily`, `sbePublisher`, `sbeManifestSource`, `sbeManifestCreationDate` come from `hardware.sbe.*`, else from the folder | Code |

Dell says the SBE can't install drivers or firmware during the deployment, which is why OS configuration installs the network drivers first.

### How the package reaches the nodes

Azure Arc Run Command carries a script and its parameters, not a file, and the operator host usually has no path to the nodes' management subnet (WinRM 5985 is not reachable from it). So the 916 MB package does not go through Azure and there is no staging storage account. `hardware.sbe.delivery` chooses the route:

| `hardware.sbe.delivery` | What happens | What you provide | Checked |
| --- | --- | --- | --- |
| `skip` (default, also when the key is absent) | Nothing is delivered. The plan and the run say **NOT DELIVERED** for each node, the OEM drivers are skipped ("decided after the SBE is on the node"), and every other step runs normally. Exit code and `Converged` are not affected | The package on the node by other means (for example ZTP put it there), or choose a route | Code |
| `winrm_copy` | The script opens a WinRM session to each node's management address and copies the three files to `C:\SBE` (to a `.part` file, SHA-256 checked on the node, then renamed). The other steps stay on Arc | The script must run on a host that reaches the nodes' management subnet on TCP 5985: the operator host if it can, otherwise a runner or jump host. Pass `-Credential` (the nodes' local administrator) | Code (the SHA-256), You (the path). A failed connection is reported once per node and does not stop the other steps |
| `node_pull` | The node downloads each file itself, in the same Run Command that carries the other node actions, from `hardware.sbe.node_pull_url` (`https://host/sbe/dell`, or a UNC folder `\\files\sbe\dell`), checks free space, downloads to a `.part` file, checks the SHA-256 and renames it | A read-only location the **nodes** can reach, serving the three files by name, with no credential in the address. The operator host needs no path to it | Code (the SHA-256, the address form: rule AZL-030), You (the server and the path) |

The Sbe step runs **last**. Delivering a 900 MB package is the step most likely to fail (it needs a route to the node that the other steps do not), and it must not stop the others. The drivers install from the package, so they run in the pass after the package has landed; with `skip` and no package on the node they are skipped. A route that is configured and fails leaves the node not converged (exit code 1, "NOT READY") with the reason in the report; a route that is `skip` does not. The report (`-ReportPath`) records `sbeDelivery` and `sbeNotDelivered`. In the one-run command the same route applies: a ZTP node is reached over Arc, and for `winrm_copy` the run gives the node script the local administrator (`identity.local_admin`, or `-Credential`) for the copy only; the node record of a `skip` run carries a warning that the package is NOT DELIVERED.

## SAN (Fibre Channel or iSCSI)

For `storage_architecture: san` (disaggregated):

| Prepare | Detail | Checked |
| --- | --- | --- |
| FC HBAs seated, drivers present | each port shows in `Get-InitiatorPort`; the WWPNs go in `nodes[].san.hbas[].ports[].wwpn` | Code (blocks if a listed WWPN isn't seen; lists the ones the file lacks) |
| **Zoning and LUN masking done before Validate** | the fabric administrator zones each node's WWPNs to the array's target ports; the array presents the LUNs to every node with the same LUN IDs. A disaggregated deployment needs the infrastructure LUN (250 GB or more) and the performance history LUN (20 GB or more) visible. OS configuration does not touch the fabric or the array | Code (reads: blocks if a LUN isn't visible on a node, is too small, or has fewer than 2 paths) |
| The LUNs stay RAW | don't initialize the infrastructure or performance history LUN; the deployment fails if you do | Code (blocks) |
| MPIO | the MultipathIO feature, the array's MSDSM hardware ID, load balance policy `RR`, and the vendor's MPIO timers where Microsoft names them (Dell PowerStore). Table: `config/san/msdsm-vendors.json` (Dell PowerStore, Pure FlashArray, Hitachi, HPE Alletra/3PAR, NetApp). A new hardware ID needs a restart before MPIO claims the LUNs | Code (sets what differs), You (a vendor not in the table) |
| LUN identifiers for ARM | `storage.san.infra_volume_lun_id` and `performance_history_lun_id` are LUN numbers. The ARM parameters (`infraVolLunId`, `infraPerfLunId`) take the disk's UniqueId (or serial number). The generator translates by reading the OS configuration report | Code |
| Cluster networks | `networking.cluster_networks` (name, adapter, VLAN, subnet) on standalone ports, one per fabric: ARM `sanNetworkList` | Code (the schema) |

For `hybrid` the cluster is deployed with Storage Spaces Direct and the SAN is connected afterwards. Microsoft says not to zone the HBAs until after that deployment, so the LUN checks are skipped; MPIO and MSDSM are still prepared. For `iscsi`, OS configuration enables the MSiSCSI service and MSDSM auto-claim only: connecting to targets and CHAP are not automated, and the ARM generator stops with a message (Microsoft's iSCSI template takes a different node list). See [Connect an external storage array](https://learn.microsoft.com/azure/azure-local/deploy/enable-external-storage).

## The ZTP hand-off file

`ztp-handoff.json`, written by azurelocal-ztp's `New-ZtpHandoff.ps1` when every machine is ready to cluster. **Schema 2** is required; an older file stops the run. It holds what Azure generated, and since the per-port detail (`networkAdapters[]`) what Azure reports for each port after the install; the expected addresses and MACs always come from `infrastructure.yml`. Keep it out of source control: it holds Azure resource IDs.

| Field read | Used for |
| --- | --- |
| `nodes[].arcMachineResourceId` | the Arc Run Command target; ARM `arcNodeResourceIds`. Without a handoff the Arc machine is found by `arc_machine_name` (default the node name) in `azure.resource_group` |
| `nodes[].managementAddressVerified`, `managementAddressReason`, `managementMode.mode` | shown next to the management-address change when ZTP couldn't verify it (in Modes B and C that is the normal case: the OS install reset the static). The script always verifies by MAC itself |
| `solution.vsrVersion` | compared with `provisioning.os_version`; a difference is reported |
| `nodes[].name`, `arcMachineName` | matching the entry to the node |

The OS configuration's own **report** (`-ReportPath`, JSON, no secrets) feeds the ARM step: the OS adapter names by MAC (Network ATC needs the real names, `Port0` to `Port6`, the same on every node) and the SAN disks by LUN.

### The Network step, per management address mode

The management port is the port the file gives role `management` (with an `ip_assignment` other than `none`), found on the node by its MAC, whatever its OS name, card or slot. What the Network step does with it follows the mode ([Management address modes](../config/infrastructure/README.md#management-address-modes)):

| `ip_assignment` | Mode | The management port after ZTP | What the Network step does |
| --- | --- | --- | --- |
| `dhcp_reservation` | A, Reserved (recommended) | Its reserved address | Leaves DHCP on and verifies the address (`ip_address`; without it, any DHCP address). Info when it differs: check the reservation for the MAC |
| `static` | B, Static with DHCP | A DHCP address: the OS install reset the static | Sets the static by MAC (`nic-static`: DHCP off, the address, the gateway), then DNS |
| `static` | C, Static without management DHCP | No address; Arc reaches the node over the provisioning port | The same, over Arc, and **before** any other port loses DHCP: the management port is handled first |
| `dhcp` | none | A DHCP address that can change | Leaves it alone |
| `preconfigured` | none | What the operator set | Leaves it alone |
| `none` (any other port) | every mode | DHCP and often a default gateway, from the install | Turns DHCP off and removes the address and the gateway (`nic-clean`) |

A port the file lists as `dhcp` or `dhcp_reservation` keeps DHCP; if it holds a second default gateway the step is Blocked. A port the file doesn't list is Blocked when it holds a gateway, and left alone otherwise.

## What each part checks (summary)

| Check | Where | Result |
| --- | --- | --- |
| infrastructure.yml schema 5 and the toolkit's rules | `Import-AzlInfrastructure` | stops on errors (`-SkipValidation` to override) |
| SBE package hash | `Get-AzlSbeBundle` | stops |
| Ports found by MAC; no second default gateway | Compare | Blocked |
| Built-in Administrator as the deployment account | OS configuration and ARM | Blocked / stops |
| Generated parameters against the template's parameter list (none unknown, none missing, types, allowed values) | ARM plan, and against the live template when executing | stops |
| Arc machines exist and are `Connected` | ARM with `-Preflight` or `-Execute` | stops |
| Validate after a failed deployment | ARM | refused (Microsoft: it resets system properties and can break license sync) |
| Deploy without a successful Validate | ARM | refused |
| Same adapter name on every node | ARM | stops |
| Domain join: joined to another domain, name differs, DNS/SRV/controller/clock, OU missing or not blocking inheritance | DomainJoin step (Plan) | Blocked |

## Values table: every `infrastructure.yml` key these scripts read

Required: **yes** (the script stops or the step can't run without it), **if** (when the condition holds), **no** (optional; the default is shown). Step: **OS** is OS configuration; **ARM** is the parameter file and the deployment.

| Key | Required | Example | Where to get it | Step |
| --- | --- | --- | --- | --- |
| `scenario.identity` | yes | `active_directory` | your design | ARM (template) |
| `scenario.storage_architecture` | yes | `san` | your design | OS (SAN steps), ARM (template) |
| `scenario.storage_connectivity` | yes | `switched` | your design | ARM (`networkingType`, `storageConnectivitySwitchless`) |
| `scenario.topology` | yes | `standard` | your design | ARM (template, zones) |
| `scenario.cloud`, `scenario.connectivity` | yes | `public`, `connected` | your design | ARM (template) |
| `azure.subscription_id` | yes | GUID | Azure portal | OS (Arc lookup), ARM |
| `azure.resource_group` | yes | `rg-iic-azl-01` | the group holding the Arc machines | OS, ARM |
| `azure.tenant_id` | yes | GUID | Microsoft Entra ID, Properties | ARM `tenantId` |
| `azure.location` | yes | `eastus` | your region | ARM `location` |
| `azure.hci_resource_provider_object_id` | no | GUID | `(Get-AzADServicePrincipal -ApplicationId 1412d89f-b8a8-4111-b4fd-e82905cbd85d).Id`; empty: looked up | ARM |
| `azure.custom_location` | no (`<cluster>-cl`) | `cl-iic-azl-01` | your naming | ARM `customLocation` |
| `key_vaults[].name`, `.subscription_id`, `.resource_group` | yes, for each vault a reference names | `kv-iic-mgmt-01` | the management vault | OS (secrets), ARM (secrets, Key Vault references) |
| `cluster.name` | yes | `iic-clus01` | your naming; up to 15 characters, not a node name | ARM `clusterName` |
| `cluster.naming_prefix` | no (`hci`) | `iicazl01` | your naming | ARM `namingPrefix` |
| `cluster.deployment_mode` | no (`validate`) | `validate` | overridden by `-Mode` | ARM `deploymentMode` |
| `cluster.witness.type` | yes | `cloud` | two machines and rack aware need `cloud` | ARM `witnessType` |
| `cluster.witness.storage_account` | if `cloud` | `stiicazl01wit` | a free, globally unique name | ARM `clusterWitnessStorageAccountName` |
| `cluster.key_vault.name` | yes | `kv-iic-azl-01` | a free, globally unique name | ARM `keyVaultName` |
| `cluster.key_vault.create_new` | no (`true`) | `true` | `false` to reuse one | ARM `createNewKeyVault` |
| `cluster.key_vault.soft_delete_retention_days` | no (30) | `30` | 7 to 90 | ARM `softDeleteRetentionDays` |
| `cluster.diagnostics.storage_account` | yes | `stiicazl01diag` | a free, globally unique name | ARM `diagnosticStorageAccountName` |
| `cluster.diagnostics.logs_retention_days`, `.storage_account_type` | no (30, `Standard_LRS`) | `30`, `Standard_LRS` | your policy | ARM |
| `nodes[].name` | yes | `iic-n01` | the host name; up to 15 characters | OS (host name), ARM (`physicalNodesSettings`) |
| `nodes[].arc_machine_name` | no (the node name) | `iic-n01` | the Arc machine's name | OS, ARM (lookup) |
| `nodes[].network_adapters[].mac_address` | yes (management port); recommended on all | `00:00:5E:00:53:10` | iDRAC or the ZTP discovery | OS (finds every port by MAC), ARM (name translation) |
| `nodes[].network_adapters[].name` | yes | `Port0` | the OS name, or a label (then the OS report maps it) | OS, ARM (`intentList`, networks) |
| `nodes[].network_adapters[].roles` | yes | `[management, compute]` | your design; `unused` ports are disabled | OS |
| `nodes[].network_adapters[].ip_assignment` | yes | `static` | `none` turns DHCP off on the port | OS |
| `nodes[].network_adapters[].ip_address`, `.prefix_length` | if `static` | `192.0.2.11`, `24` | your IP plan | OS, ARM (`physicalNodesSettings`) |
| `nodes[].management.*` | no | (legacy 5.0 form of the management port) | use `network_adapters` | OS, ARM |
| `nodes[].zone` | if rack aware | `ZoneA` | your racks | ARM `localAvailabilityZones` |
| `nodes[].storage_ips` | if `networking.storage.auto_ip: false` | `[10.0.1.11, 10.0.2.11]` | your storage IP plan | ARM `storageNetworkList` |
| `nodes[].san.hbas[].ports[].wwpn` | if FC | `10:00:00:00:00:00:00:11` | `Get-InitiatorPort` on the node (the OS configuration report lists them) | OS (verifies) |
| `hardware.vendor` | yes | `Dell` | the OEM | OS (`config/oem/<vendor>.json`) |
| `hardware.sbe.bundle_path` | no (no SBE step) | `D:\sbe\dell` | the OEM's download, outside any repository | OS, ARM (values) |
| `hardware.sbe.delivery` | no (`skip`) | `node_pull` | `winrm_copy`, `node_pull` or `skip`: how the package reaches the nodes (schema 5.4.2) | OS |
| `scenario.os_install` | yes | `simplified` | `iso` or `simplified`: the declared install method; the one-run command checks it against what answers (see Which method?) | OS (one-run) |
| `os_configuration.clear_storage` | no (`false`) | `true` | `true` lets the one-run command wipe leftover local storage in Apply mode (schema 5.4.3); SAN, USB, boot and system disks are never touched | OS (one-run) |
| `hardware.sbe.node_pull_url` | with `node_pull` | `https://sbe.iic.example/sbe/dell` | a read-only location the nodes can reach; no credential in it | OS |
| `hardware.sbe.version`, `.family`, `.publisher`, `.manifest_source`, `.manifest_creation_date` | no (read from the folder) | `5.0.1` | the SBE's discovery XML | ARM `sbe*` |
| `networking.management.subnet` | yes | `192.0.2.0/24` | your IP plan | OS (prefix), ARM (`subnetMask`) |
| `networking.management.gateway` | yes | `192.0.2.1` | your IP plan | OS, ARM `defaultGateway` |
| `networking.management.vlan_id` | no (0) | `0` | your switch; reported, not set | OS (note) |
| `networking.management.dns_servers` | yes | `[192.0.2.4, 192.0.2.5]` | DNS that resolves AD; can't change after deployment | OS, ARM `dnsServers` |
| `networking.management.infrastructure_pool.start`, `.end` | yes | `192.0.2.20`, `.29` | 6 or more free contiguous addresses | ARM |
| `networking.management.use_dhcp` | no (`false`) | `false` | DHCP for host and cluster addresses | ARM `useDhcp` |
| `networking.ntp_servers` | yes | `[192.0.2.4]` | your time sources | OS |
| `networking.intents[]` (`name`, `traffic`, `adapters`, `overrides`) | yes | `mgmt_compute`, `[management, compute]`, `[Port0, Port1]` | your design | ARM `intentList`, `networkingPattern` |
| `networking.storage.auto_ip`, `.networks[]` | if S2D | `true`; `StorageNetwork1`, `Port2`, 711 | your design | ARM `enableStorageAutoIp`, `storageNetworkList` |
| `networking.cluster_networks[]` | if SAN | `clusterNetwork-A`, `Port2`, 711, `198.51.100.0/26` | your fabric design | ARM `sanNetworkList` |
| `identity.local_admin.username` | yes | `azl-admin` | not `Administrator` | OS, ARM `localAdminUserName` |
| `identity.local_admin.password` | yes | `keyvault://kv-iic-mgmt-01/local-admin-password` | create the secret first | OS, ARM |
| `identity.active_directory.domain_fqdn`, `.ou_path` | if AD | `improbability.cloud`, `OU=...` | your directory | ARM `domainFqdn`, `adouPath` |
| `identity.active_directory.lcm_user.username`, `.password` | if AD | `lcm-iic-clus01`, `keyvault://.../lcm-password` | the pre-creation tool; also the account that joins the nodes | OS (DomainJoin), ARM |
| `identity.active_directory.domain_join_account.username`, `.password` | no | `svc-azl-join`, `keyvault://.../domain-join-password` | override of the LCM user for the join; same rights on the OU | OS (DomainJoin) |
| `identity.active_directory.join_options.allow_ou_move` | no (`false`) | `false` | `true` moves a node found in another OU into `ou_path`, before the deployment only | OS (DomainJoin) |
| `identity.active_directory.join_options.rename_after_join` | no (fixed `false`) | `false` | never rename after the join | OS (DomainJoin) |
| `identity.active_directory.local_admin_members` | no (instance administrators group, LCM user) | `[sg-iic-azl-01-admins]` | domain principals added to the nodes' local Administrators | OS (DomainJoin) |
| `identity.active_directory.domain_controllers` | no | `[192.0.2.4, 192.0.2.5]` | must be the management port's DNS servers (AZL-052); the join tests them | OS (DomainJoin) |
| `scenario.environment_class` | no (`production`) | `lab` | decides whether an OU without blocked inheritance blocks the join (`dev`, `production`, `dmz`) or only warns (`lab`, `test`) | OS (DomainJoin) |
| `identity.local_identity.dns_server_config`, `.dns_zone`, `.dns_forwarders` | if local identity | `use_dns_server`, `improbability.cloud` | your DNS design | ARM `dnsServerConfig`, `dnsZones` |
| `storage.configuration_mode` | no (`express`; `infra_only` for SAN) | `infra_only` | your design | ARM `configurationMode` |
| `storage.san.type` | if SAN | `fibre_channel` | your SAN | OS, ARM (template) |
| `storage.san.array.vendor`, `.model` | if SAN | `Dell`, `PowerStore 1200T` | your SAN; picks the MSDSM entry | OS |
| `storage.san.infra_volume_lun_id`, `.performance_history_lun_id` | if disaggregated | `0`, `1` | the array | OS (verifies), ARM `infraVolLunId`, `infraPerfLunId` |
| `security.level`, `.drift_control`, `.credential_guard`, `.smb_signing`, `.smb_cluster_encryption`, `.bitlocker_boot_volume`, `.bitlocker_data_volumes`, `.wdac` | no (Microsoft's recommended) | `recommended` | your policy | ARM `securityLevel` and the flags |
| `security.telemetry.streaming_data`, `.episodic_data_upload`, `.eu_location` | no (true, true, false) | `true` | your policy | ARM |
| `provisioning.os_version` | no | `12.2610.1004.50` | the build you pinned | OS (compared with the handoff) |

Not in schema 5, so the scripts take a default or a parameter: the SAN's MPIO and MSDSM values (`config/san/msdsm-vendors.json`), the OEM driver folders (`config/oem/<vendor>.json`), the `sanNetworkList` adapter properties (Microsoft's sample values), and the choice of UniqueId or serial number for the LUN identifiers (`-SanLunIdSource`).
