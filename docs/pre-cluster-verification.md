# Pre-cluster verification (the gate before the ARM Validate)

The pre-cluster verification is a stage of its own between the OS configuration and the cluster ARM Validate. It checks, read only, everything that
Microsoft Learn (`view=azloc-2610`) and the azurelocal.cloud documentation list as a prerequisite of an Azure Local deployment, so that an ARM Validate does not
fail for something the toolkit could have caught. The ARM run (`Invoke-AzureLocalArmDeployment.ps1`, Mode Validate or Deploy) refuses to go on without a passing,
current result of this gate for the same infrastructure file.

- Entry point: `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalPreClusterVerification.ps1`
- Engine: `scripts/common/arm-deployment/AzlPreClusterVerification.psm1`; the contract the ARM run reads: `AzlPreClusterGate.psm1`
- Check modules (harvested validators): `scripts/common/arm-deployment/verification/AzlVerification.*.psm1`
- Tests (fakes only): `tests/pre-cluster-verification`, `tests/arm-deployment/ArmDeploymentRun.PreClusterVerification.Tests.ps1`

## Run it

```powershell
# 1. What would be checked (offline, reads nothing, writes plan.json and plan.md):
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile D:\Data\azl-ztp\tplabs\infrastructure.yml

# 2. Check (read only against Azure, Active Directory and the nodes; writes the result the ARM run reads):
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile <infrastructure.yml> -OsConfigurationReport <osconfig report directory> -Mode Verify

# 3. Optional: also register the mandatory resource providers that are not registered (Azure side only):
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile <infrastructure.yml> -Mode Verify -Fix

# 4. The ARM Validate then goes ahead:
./Invoke-AzureLocalArmDeployment.ps1 -InfrastructureFile <infrastructure.yml> -Mode Validate
```

Exit codes: 0 Plan done, or Verify with the verdict Pass; 1 Verify with the verdict Fail; 2 bad input.

### Prerequisites for running it

| Needed | Why |
| --- | --- |
| PowerShell 7.0 or later, and the repository | the gate is PowerShell 7 |
| `Connect-AzAccount` done (the tool never signs in), with the tenant and subscription of the file | the AZURE checks; Reader is enough for the reads, Owner or Contributor for `-Fix` |
| Key Vault access (Get on secrets) to the vault of the file | the local administrator, the LCM user and the user name secret are read into memory, never written |
| WinRM (5985 or 5986) from this host to the management address of every node | the NODES, NETWORK and STORAGE checks; the same transport and the same Read payload as the OS configuration. A transient script file is written under `C:\ProgramData\AzureLocal\osconfig` on the node and removed again; nothing else on the node is touched |
| LDAP (TCP 389) from this host to a domain controller (`identity.active_directory.domain_controllers`) | the IDENTITY checks; the LCM credential from Key Vault, search filters only |
| DNS (UDP/TCP 53) from this host to the DNS servers of the file | the DNS record checks |
| For READINESS: Windows PowerShell 5.1 on this host with the module `AzStackHci.EnvironmentChecker` | Learn: run the Environment Checker from a workstation or staging server and uninstall it from the nodes. The gate never installs it; without it RDY-001 to RDY-006 are Skipped (and block until you accept them) |

A check that cannot be asked (for example Active Directory from a host that cannot reach a domain controller) is **Skipped** with the reason, and a Skipped check blocks the
verdict: it is never read as fine. Run the gate from a host that can ask, or accept the ids you cannot ask with `-AcceptSkipped` (the report records that you did).

## Statuses and the verdict

| Status | Meaning | Blocks the verdict |
| --- | --- | --- |
| Passed | the requirement is met | no |
| Failed | the requirement is not met, or the check could not run (the exception text is the message) | yes, for a blocking check |
| Warning | a finding that does not stop the deployment | no |
| Skipped | the check could not run here (no sign-in, no domain controller, the node could not be read, a module is missing) | yes, unless its id is named in `-AcceptSkipped` |
| NotApplicable | the check does not apply to this design (for example the Active Directory checks for local identity) | no |
| Fixed | `-Fix` repaired it | no |

The verdict is **Pass** only when no result blocks. Every result carries the check id, the node (`*` when it is not about one node), the message (never truncated), the remedy with the
exact command and the source URL.

`-Fix` (Verify only) registers the mandatory resource providers that are not registered and waits until they are Registered. It never changes a node, Active Directory or DNS.
Without `-Fix`, and in Plan, nothing is changed anywhere.

## Output

The report directory is `-ReportDirectory`, else `deployment.pre_cluster_verification_report_directory`, else `arm-report\verification\live` in the **environment data folder**: the folder
that holds `provisioning.simplified.evidence_path` (for example `D:\Data\azl-ztp\tplabs\evidence` gives `D:\Data\azl-ztp\tplabs\arm-report\verification\live`), else the one that holds
`media_path`, else the folder of the infrastructure file. Sonar follows `precluster-verification-events.jsonl` there.

| File | Content |
| --- | --- |
| `precluster-verification-events.jsonl` | one single-line JSON object per line, written as the run goes: `RunStarted`, one `Check` per result, `RunCompleted` |
| `report.json` | the whole result: verdict, counts, per-category counts, `fileHash`, `expiresUtc`, `partial`, the accepted skips, the modules loaded, every check |
| `summary.md` | for a person and a pipeline job summary: verdict, a breakdown per category, what blocks with the fix, all checks |
| `plan.json`, `plan.md` | Mode Plan only; never counted by the ARM run |

Event line (every line has every field; `checkId`, `category`, `title`, `status`, `remedy`, `source` are empty on `RunStarted` and `RunCompleted`, `node` is `*`):

```json
{"schema":1,"runId":"411102be14a9","seq":14,"ts":"2026-11-08T12:00:03.2114Z","type":"Check","checkId":"AZR-004","category":"azure","title":"All 13 mandatory resource providers are registered","status":"Failed","node":"*","message":"Mandatory resource providers not registered: Microsoft.KeyVault (NotRegistered). ...","remedy":"Register-AzResourceProvider -ProviderNamespace Microsoft.KeyVault","source":"https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610","blocking":true}
```

`type` is `RunStarted`, `Check` or `RunCompleted`; `category` is `azure`, `identity`, `nodes`, `network`, `storage` or `readiness`; `status` is one of the six statuses; `blocking` is true when this result keeps
the verdict at Fail (a Failed blocking check, or a blocking Skipped check that was not accepted). `RunCompleted` adds `verdict` (`Pass` or `Fail`), `counts` (per status), `fileHash` (SHA-256 of the
infrastructure file) and `expiresUtc` (completion time plus `deployment.pre_cluster_verification_max_age_hours`, default 4). The feed of a run replaces the feed of the run before; while a run is in progress
the previous `report.json` is moved to `report.previous.json`, so a half-finished run can never be read as a pass. No secret is written to any file; values read from Key Vault are replaced by `***`.

### What the ARM run does with it

The precondition `PreClusterVerification` of Mode Validate and Deploy **fails** unless the latest `report.json` in the report directory (a) was made by `-Mode Verify`, (b) covers all six
categories (no `-Category`), (c) has the verdict `Pass`, (d) has the `fileHash` of the infrastructure file as it is now, and (e) has not expired. The failure names the reason and the exact command.
In Mode Plan it is a Warning and never blocks. The only way past it is the explicit switch `-SkipPreClusterVerification` of `Invoke-AzureLocalArmDeployment.ps1`: it is warned loudly, recorded in
`report.json` (`preClusterVerification.status` is `Bypassed`), in the summary and in the ARM event feed. There is no infrastructure.yml key for it, and `skip_preconditions` does not apply to it.

## Settings (registry first)

| Setting | infrastructure.yml key | Default |
| --- | --- | --- |
| `preClusterVerificationMaxAgeHours` | `deployment.pre_cluster_verification_max_age_hours` | 4 |
| `preClusterVerificationReportDirectory` | `deployment.pre_cluster_verification_report_directory` | the environment data folder, `arm-report\verification\live` |
| `skipPreClusterVerification` | none, on purpose | switch `-SkipPreClusterVerification` |
| user name secret | `identity.local_admin.username_secret` (optional) | `local-admin-username` in the vault of the password |

## Verification modules (the contract for harvested checks)

Every `scripts/common/arm-deployment/verification/AzlVerification.*.psm1` is imported by the engine. A module exports:

```powershell
Get-AzlVerificationCheckDefinition   # array of @{ Id; Category; Title; Source; Blocking; Applies = { param($Context) }; Run = { param($Context) } }
Get-AzlVerificationAdapterDefault    # optional: a table of read only scriptblocks the module's checks call through $Context.Adapters
```

- `Category` is `azure`, `identity`, `nodes`, `network`, `storage` or `readiness`. `Blocking` defaults to true.
- `Applies` returns `$true`, or `$false` / a reason string (the check is then NotApplicable with that text).
- `Run` returns one or more results, as hashtables or objects: `@{ Status = 'Passed'|'Failed'|'Warning'|'Skipped'|'NotApplicable'; Node = '*'; Message; Remedy; Evidence }`. `Evidence` (a string or a list)
  is appended to the message in full. Return one result per node for a per-node check. Never return a secret.
- `$Context` is a hashtable: `Infrastructure` (the parsed file), `Handoff`, `OsReport`, `Settings` (the run settings), `Adapters` (below), and `Cluster`, `Nodes`, `Subscription`,
  `ResourceGroup`, `Identity`, `Architecture`, `Fix`, `Mode`, `Cache`.
- `Adapters` is the engine's adapter (Azure ARM, Key Vault, LDAP, DNS, node reads, the Environment Checker, the clock) plus the members of every module's `Get-AzlVerificationAdapterDefault` that the
  engine does not have yet. A module default never replaces an engine member. Tests override any member. A check reads Azure, Active Directory and the nodes only through `Adapters`, never directly.
- A check that throws is Failed with the exception text; the run goes on. A module that does not load, or a definition that is unusable, becomes a failing check (`EXT-<name>`), never a silent gap.
- A definition with the Id of a built-in check replaces it.

## Where Learn and the azurelocal.cloud pages differ

Learn wins; the differences are listed in `docs-2610-audit.md` of the documentation repository.

- Resource providers: 13, with `Microsoft.KeyVault` (the azurelocal.cloud prerequisites page lists 12).
- Nodes and the domain: Learn supports a domain join before the deployment from version 2604 (the deployment user in the local Administrators group); the nodes may also stay in a workgroup, and are
  joined during the deployment. IDN-012 encodes exactly that; for local identity IDN-024 requires a workgroup.
- KDS root key: Learn 2610 does not list one for Azure Local (IDN-007 says so and is NotApplicable).
- DNS: public resolvers are not supported; CNO and VCO host records are required only when the DNS server has no secure dynamic update (IDN-009 treats domain controllers as the DNS servers that have it).
- Storage MTU: 9216 on the switch with 9014 on the host (NET-004), not 9174. RDMA and jumbo frames belong to the storage traffic; management and compute are RDMA off, 1514 (NET-003, NET-004).
- Hybrid Fibre Channel: do not zone the HBA WWNs until after the deployment (STO-011), with the workarounds (MPIO claims the array first, or disable the HBA for the deployment window).

## Failures Azure returned in this project, and the check that catches each

| Failure | Check |
| --- | --- |
| ValidateArcIntegration, `AzStackHci_ArcIntegration_MandatoryRPRegistration_Check` (HybridContainerService) | AZR-004 |
| Wrong Azure tenant context | AZR-001 |
| Active Directory preparation skipped (OU, LCM user) | IDN-003, IDN-004, IDN-005, IDN-006; a gate that cannot ask is Skipped and blocks |
| DNS and AD name resolution, ADWS 9389 | IDN-011, NET-012 |
| Cluster validation: RDMA operational on a management intent | NET-003 |
| Test-Cluster "Two disks ... cannot be distinguished" (SAN LUNs seen once per path, not declared or not claimed) | STO-004, STO-006, STO-007, STO-011 |
| Step 0.60 environment checker: SBE not validated with the solution, or an SBE left in `C:\SBE` | NOD-014, NOD-015 |
| `RoleAssignmentExists` after a portal attempt; zombie role assignments | AZR-015, AZR-014 |
| `arc-device-id-name` (Deploy step 0.41) | AZR-011 |
| Another Validate after a failed deployment (license sync) | AZR-013 |
| `unsupported-os-version` | NOD-003, NOD-004 |
| Local administrator mismatch (vault says `Administrator`, file says `azl-admin`) | IDN-015, IDN-016, IDN-017 |

## The catalog

Blocking = a Failed (or unaccepted Skipped) result blocks the verdict. Sources are Microsoft Learn pages at `view=azloc-2610`, or repository files.

### AZURE

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| AZR-001 | Signed in to the tenant and subscription the file names | the Az context | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZR-002 | Subscription is enabled and the region is one Azure Local supports | ARM: the subscription | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610) |
| AZR-003 | Resource group of the instance exists | ARM: the resource group | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZR-004 | All 13 mandatory resource providers are registered | ARM: the resource providers (-Fix registers) | yes, -Fix | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZR-005 | Subscription roles: Contributor and User Access Administrator (or Owner) | ARM: role assignments of the signed-in identity | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZR-006 | Effective permissions on the resource group include role assignment, deployment, cluster, Key Vault and storage writes | ARM: effective permissions of the resource group | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZR-007 | The roles Learn lists for the deployment user on the resource group | ARM: role assignments of the signed-in identity | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZR-008 | Every Key Vault secret the deployment reads exists and can be read | Key Vault: secret metadata | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZR-009 | Names of the cloud witness storage account, diagnostics storage account and Key Vault are free | ARM: name availability | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZR-010 | Arc machines exist, are Connected and are in the resource group of the file | ARM: the Arc machines | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZR-011 | Arc machines are named after the host (known issue arc-device-id-name) | ARM: the Arc machines | yes | config/known-issues/arm-deployment.json |
| AZR-012 | No node is Arc-enabled twice or in another resource group | ARM: Arc machines of the subscription | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) (Arc integration validator) |
| AZR-013 | No leftover failed or running deployment on the instance | ARM: the cluster resource and its deployment settings | yes | config/known-issues/arm-deployment.json (license-sync-after-failed-validate) |
| AZR-014 | No zombie role assignments (identity not found) in the resource group | ARM: role assignments of the resource group | yes | config/known-issues/arm-deployment.json (role-assignment-zombie) |
| AZR-015 | No role assignment left by an earlier (portal) deployment that the template would create again | ARM: the cluster resource and the role assignments of the resource group | yes | config/known-issues/arm-deployment.json (role-assignment-already-exists) |
| AZR-016 | No Windows update extension on the Arc machines (updates install during the deployment) | ARM: extensions of the Arc machines | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| AZR-017 | The ARM parameters can be generated from the file and match the template | the file (and the OS configuration report for adapter names) | yes | [Learn: deploy/deployment-azure-resource-manager-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610) |
| AZR-018 | The Arc gateway resource exists (outbound path with an Arc gateway) | ARM: the Arc gateway | yes | [Learn: deploy/deployment-without-azure-arc-gateway](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-without-azure-arc-gateway?view=azloc-2610) |

### IDENTITY

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| IDN-001 | Active Directory settings in the file follow Learn (OU path, LCM user name, domain) | the file | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| IDN-002 | A domain controller answers and accepts the LCM credential | Active Directory (LDAP 389) with the LCM credential from Key Vault | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| IDN-003 | The dedicated OU exists | Active Directory (LDAP) | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| IDN-004 | The LCM user exists, is enabled, not locked, not expired and may log on interactively | Active Directory (LDAP) | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| IDN-005 | The LCM user can create and delete computer objects in the OU | Active Directory (LDAP): the OU security descriptor | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610) |
| IDN-006 | Group policy inheritance is blocked on the OU; enforced GPOs above it are handled | Active Directory (LDAP): gPOptions and gPLink of the OU and its parents | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| IDN-007 | KDS root key (not required by Learn 2610 for Azure Local) | nothing | no | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| IDN-008 | DNS host (A) records of the nodes resolve to their management addresses | DNS servers of the file | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610) |
| IDN-009 | Cluster (CNO) and client access point (VCO) DNS records exist when DNS has no secure dynamic update | DNS servers of the file | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610) |
| IDN-010 | AD computer objects of the nodes and the cluster, if they exist, are in the OU | Active Directory (LDAP) | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| IDN-011 | Nodes resolve the domain with their DNS servers and reach the domain controllers (ADWS 9389, LDAP 389, Kerberos 88) | the nodes (WinRM) | yes | [Learn: concepts/firewall-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements?view=azloc-2610) |
| IDN-012 | Nodes are in a workgroup, or joined to the file's domain in the OU with the LCM user in local Administrators (Learn: 2604 and later) | the nodes (WinRM) and Active Directory (LDAP) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| IDN-013 | Disjoint namespace: a joined node's DNS suffix matches the domain | the nodes (WinRM) | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610) |
| IDN-014 | LCM and local administrator passwords meet Azure's length and complexity rule | Key Vault: the passwords (never shown) | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| IDN-015 | The dedicated local administrator of the file exists on every node, is enabled, is in Administrators and is not the built-in Administrator | the nodes (WinRM) | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610); [Learn: deploy/deployment-azure-resource-manager-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610) (localAdminUserName) |
| IDN-016 | The Key Vault secret that holds the local administrator user name is readable and equals identity.local_admin.username | Key Vault: the user name secret | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610); [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) (Local administrator credentials) |
| IDN-017 | The local administrator password secret opens a session as that account on every node | the nodes (WinRM) and Key Vault | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) (Local administrator credentials identical on all machines) |
| IDN-020 | Local identity settings: DNS zone, DNS server configuration, local administrator is not the built-in account | the file | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610) |
| IDN-021 | Local identity: static IP addresses only (no DHCP) | the file and the nodes (WinRM) | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610) |
| IDN-022 | Local identity: A records for every node and for the system (first infrastructure address) in the zone | DNS servers of the file | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610) |
| IDN-023 | Local identity: SSH (sshd) is enabled on every node | the nodes (WinRM) | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610) |
| IDN-024 | Local identity: the nodes are in a workgroup (the local administrator is IDN-015 to IDN-017) | the nodes (WinRM) | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610) |

### NODES

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| NOD-001 | Every node answers over WinRM to the local administrator from the Key Vault secret | the nodes (WinRM) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| NOD-002 | Computer name equals the node name in the file and is a valid name (no underscore, 15 characters at most) | the nodes (WinRM) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| NOD-003 | All nodes run exactly the same OS build | the nodes (WinRM) | yes | [Learn: deploy/deployment-azure-resource-manager-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610); config/known-issues/arm-deployment.json (unsupported-os-version) |
| NOD-004 | The OS build is the one the target solution version ships with | the nodes (WinRM) and the file | yes | [Learn: whats-new](https://learn.microsoft.com/en-us/azure/azure-local/whats-new?view=azloc-2610); config/known-issues/arm-deployment.json (unsupported-os-version) |
| NOD-005 | Time: a real NTP source (not the CMOS clock), the same on every node, in step with this host | the nodes (WinRM) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| NOD-006 | DNS servers on the nodes equal the file's, are the same on every node and are not public resolvers | the nodes (WinRM) | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (DNS server considerations) |
| NOD-007 | Required Windows features are installed (Hyper-V, Failover Clustering, Data Center Bridging, Network ATC, BitLocker) | the nodes (WinRM) | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610) |
| NOD-008 | No pending restart | the nodes (WinRM) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| NOD-009 | Processors and memory: identical processors on all nodes, at least 32 GB memory, virtualization enabled, at least what the file declares | the nodes (WinRM) | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610) |
| NOD-010 | Secure Boot on, TPM 2.0 present and ready, the same BIOS version on all nodes | the nodes (WinRM) | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610); [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) (hardware validator) |
| NOD-011 | Boot disk is at least 200 GB | the nodes (WinRM) | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610) |
| NOD-012 | The node is not already a member of a cluster | the nodes (WinRM) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) (clean the machines before deployment) |
| NOD-013 | The Environment Checker module is not installed on the nodes | the nodes (WinRM) | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) (Uninstall environment checker) |
| NOD-014 | C:\SBE matches the file: nothing there when no SBE is configured, the package when one is | the nodes (WinRM) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610); config/known-issues/arm-deployment.json (sbe-referenced-but-not-configured) |
| NOD-015 | The configured SBE is validated by the OEM with the target solution version (Azure step 0.60) | the SBE discovery catalog (file) and the nodes (WinRM) | yes | config/known-issues/arm-deployment.json (unvalidated-solution-sbe-combination) |

### NETWORK

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| NET-001 | Every adapter of every intent exists on every node under the same name, with link up | the nodes (WinRM) and the file | yes | [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610); [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Decision 6, 7) |
| NET-002 | Link speed: at least 10 Gbps for storage, adapters of an intent and of the same name on all nodes are symmetric | the nodes (WinRM) | yes | [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610); [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Decision 6) |
| NET-003 | RDMA matches the intent: off for management and compute, on and capable for storage | the nodes (WinRM) and the ARM intent list | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Decision 6: Network Direct); [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610) |
| NET-004 | Jumbo frames only for storage; values valid; the same MTU on all nodes | the ARM intent list and the nodes (WinRM) | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Decision 6: Jumbo Packets) |
| NET-005 | Management network: one management IP and one default gateway per node, matching the file | the nodes (WinRM) and the file | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Node and cluster IP assignment) |
| NET-006 | Infrastructure IP pool: at least 6 contiguous addresses in the management subnet, free of nodes, gateway and active hosts | the file and the nodes (ICMP from the nodes) | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Management IP pool); [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) (network validator) |
| NET-007 | DNS servers: at least one, not public, not inside the instance, not in the reserved Kubernetes ranges | the file | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (DNS server considerations) |
| NET-008 | No node, pool, gateway, DNS, proxy or logical network address in the reserved Kubernetes ranges (10.96.0.0/24 and 12, 10.244.0.0/16) | the file | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Reserved IP ranges to avoid) |
| NET-009 | Storage network plan: valid unique VLANs, distinct subnets, at least two storage adapters, switchless limits | the file | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Decision 5) |
| NET-010 | Nodes reach the required Azure endpoints on 443 (directly or through the proxy) without TLS inspection | the nodes (HTTPS probes) | yes | [Learn: concepts/firewall-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements?view=azloc-2610); [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) (connectivity validator, RDY-001, covers all endpoints) |
| NET-011 | Proxy settings follow Learn: no PAC, no .local, no credentials, no CIDR in the bypass list; node, cluster and pool covered | the file | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Proxy requirements) |
| NET-012 | Nodes reach every DNS server (TCP 53) and the default gateway (ICMP) | the nodes (probes) | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (DNS server and Management IP pool considerations) |
| NET-013 | Intent adapters use the OEM driver, not the inbox Microsoft driver | the nodes (WinRM) | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) (Decision 6); [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| NET-014 | No Network ATC intent and no stray virtual switch left from an earlier attempt | the nodes (WinRM) | yes | config/known-issues/arm-deployment.json (vmswitch-not-bound) |

### STORAGE

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| STO-001 | Storage Spaces Direct: at least two data disks of at least 500 GB per node, the same number and size on every node | the nodes (WinRM) | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610) |
| STO-002 | Local data disks are clean: poolable, no partitions, nothing but the boot disk in use | the nodes (WinRM) | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) (Clean all the non-OS drives); [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) (hardware validator) |
| STO-003 | No storage pool or virtual disk left on the nodes | the nodes (WinRM) | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) (hardware validator: No storage pools exist, Critical) |
| STO-004 | The SAN the file declares is the SAN the nodes see (no undeclared SAN LUNs) | the nodes (WinRM) | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610); [Learn: deploy/deployment-install-os-disaggregated](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610) |
| STO-005 | Multipath I/O is enabled on the nodes | the nodes (WinRM) | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610) (Step 1.1: Verify Multipath I/O) |
| STO-006 | The array's vendor and product are claimed by MPIO (MSDSM hardware ID registered) | the nodes (WinRM) and config/san/msdsm-vendors.json | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610) (Step 2.2: Register vendor device with MSDSM); config/san/msdsm-vendors.json |
| STO-007 | Each SAN LUN is visible exactly once by UniqueId on every node (no duplicate paths) | the nodes (WinRM) | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610) (Step 7: Verify SAN Disks); Azure Test-Cluster 'List Disks' |
| STO-008 | Every node sees the same LUNs, with the same LUN IDs | the nodes (WinRM) | yes | https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610 (Step 4: consistent LUN IDs; Step 7) |
| STO-009 | The infrastructure LUN (250 GB) and performance history LUN (20 GB) are visible on every node and still RAW | the nodes (WinRM) and the file | yes | https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610 (Prerequisites; Connect to SAN); [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610) (SAN) |
| STO-010 | Fibre Channel: the HBA ports of the file are present on the nodes | the nodes (WinRM) and the file | yes | [Learn: deploy/deployment-install-os-disaggregated](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610) (Connect to SAN, FC) |
| STO-011 | Hybrid Fibre Channel: do not zone the HBA WWNs until after the deployment | the nodes (WinRM) | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610) (Fibre Channel prerequisites: Important) |
| STO-012 | iSCSI: dedicated adapters with OEM drivers; the iSCSI service state matches the solution version (2610: the wizard enables it) | the nodes (WinRM) and the file | yes | [Learn: deploy/deployment-install-os-disaggregated](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610) (Connect to SAN, iSCSI); [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610) (iSCSI prerequisites) |

### READINESS

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| RDY-001 | Environment Checker, connectivity validator: outbound connectivity to the Azure endpoints | the Environment Checker, run from this host against the nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) |
| RDY-002 | Environment Checker, hardware validator: processors, memory, adapters, disks, no storage pool, Secure Boot, TPM 2.0 | the Environment Checker, run from this host against the nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) |
| RDY-003 | Environment Checker, software validator: same NTP, same OS version, resolvable local Administrators (run with -Exclude Test-IsNotPartofDomain) | the Environment Checker, run from this host against the nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) |
| RDY-004 | Environment Checker, Active Directory validator (Invoke-AzStackHciExternalActiveDirectoryValidation) | the Environment Checker, run from this host against Active Directory | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) |
| RDY-005 | Environment Checker, network validator: IP ranges free, adapters, storage connection (Invoke-AzStackHciNetworkValidation) | the Environment Checker, run from this host against the nodes, with the ARM intent list | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) |
| RDY-006 | Environment Checker, Arc integration validator: no name clash, region valid, resource and role assignment limits | the Environment Checker with the Az context, run from this host | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610) |
