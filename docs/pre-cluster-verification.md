# Pre-cluster verification (the gate before the ARM Validate)

The pre-cluster verification is a stage of its own between the OS configuration and the cluster ARM Validate. It checks, read only, everything that
Microsoft Learn (`view=azloc-2610`) and the azurelocal.cloud documentation list as a prerequisite of an Azure Local deployment, so that an ARM Validate does not
fail for something the toolkit could have caught. The ARM run (`Invoke-AzureLocalArmDeployment.ps1`, Mode Validate or Deploy) refuses to go on without a passing,
current result of this gate for the same infrastructure file.

- Entry point: `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalPreClusterVerification.ps1`
- Engine: `scripts/common/arm-deployment/AzlPreClusterVerification.psm1` (modules, adapters, runner, `-Fix`, report and feed); the contract the ARM run reads: `AzlPreClusterGate.psm1`
- The documented endpoint list (one source for AZ-023, NW-005 and ID-DNS-003): `scripts/common/arm-deployment/verification/AzlVerification.Endpoints.psm1`
- Check modules (the catalog below): `scripts/common/arm-deployment/verification/AzlVerification.*.psm1`; the one check the engine owns is `ARM-001`
- Tests (fakes only): `tests/pre-cluster-verification` (the engine with a fake module, and each module), `tests/arm-deployment/ArmDeploymentRun.PreClusterVerification.Tests.ps1`

## Run it

```powershell
# 1. What would be checked (offline, reads nothing, writes plan.json and plan.md):
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile D:\Data\azl-ztp\iic\infrastructure.yml

# 2. Check (read only against Azure, Active Directory and the nodes; writes the result the ARM run reads):
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile <infrastructure.yml> -OsConfigurationReport <osconfig report directory> -Mode Verify

# 3. Optional: also register the mandatory resource providers that are not registered (Azure side only):
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile <infrastructure.yml> -Mode Verify -Fix

# 4. Optional: put the Environment Checker on the nodes for this run (removed again at the end), so RD-002 to RD-005 can run:
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile <infrastructure.yml> -Mode Verify -InstallEnvironmentChecker

# 4b. Optional: accept a Validate on an instance whose deployment failed (the license-sync risk Learn names; AZ-018 becomes a Warning that records it):
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile <infrastructure.yml> -Mode Verify -AllowRevalidate

# 5. The ARM Validate then goes ahead:
./Invoke-AzureLocalArmDeployment.ps1 -InfrastructureFile <infrastructure.yml> -Mode Validate
```

Exit codes: 0 Plan done, or Verify of all categories with the verdict Pass; 1 Verify with the verdict Fail, or a run that failed after it started (the feed still ends with `RunCompleted`, verdict `Error`);
2 bad input; 3 a **partial** run (`-Category`) with no blocking result: it is not a pass and never satisfies the ARM precondition.

### Prerequisites for running it

| Needed | Why |
| --- | --- |
| PowerShell 7.0 or later, and the repository | the gate is PowerShell 7 |
| `Connect-AzAccount` done (the tool never signs in), with the tenant and subscription of the file | the AZURE checks; Reader is enough for the reads, Owner or Contributor for `-Fix` |
| Key Vault access (Get on secrets) to the vault of the file | the local administrator, the LCM user and the user name secret are read into memory, never written |
| WinRM (5985 or 5986) from this host to the management address of every node | the NODES, NETWORK and STORAGE checks; the same transport as the OS configuration. A transient script file is written under `C:\ProgramData\AzureLocal\osconfig` on the node and removed again; nothing else on the node is touched |
| LDAP (TCP 389) from this host to a domain controller (`identity.active_directory.domain_controllers`) | the IDENTITY checks; the LCM credential from Key Vault, search filters only |
| DNS (UDP/TCP 53) from this host to the DNS servers of the file | the DNS record checks |
| For READINESS (RD-002 to RD-005): the module `AzStackHci.EnvironmentChecker` on the nodes | see "The Environment Checker" below |

A check that cannot be asked (for example Active Directory from a host that cannot reach a domain controller, or a node section whose read failed) is **Skipped** with the reason, and a Skipped check blocks the
verdict: it is never read as fine. Run the gate from a host that can ask, or accept the ids you cannot ask with `-AcceptSkipped` (the report records that you did, and the ARM run shows it).

### The Environment Checker

Learn says to run the Environment Checker before the deployment and to uninstall it from the nodes before the deployment starts. The readiness checks RD-002 to RD-005 run its validators on the nodes, so the gate
**never installs it by default**: without the module those checks are Skipped (and block until you accept them). With `-InstallEnvironmentChecker` the gate installs the module on every node for this run only and
removes it again in a `finally` block at the end, also when the run fails; `-KeepEnvironmentChecker` skips the removal. `report.json` (`environmentChecker`) and `summary.md` say whether the module was installed, removed or
kept, and on which nodes. The nodes need to reach the PowerShell Gallery. Only an explicit success status of a validator counts as a pass; ERROR, SKIPPED or an unknown status never does.

## Statuses and the verdict

| Status | Meaning | Blocks the verdict |
| --- | --- | --- |
| Passed | the requirement was read and is met | no |
| Failed | the requirement is not met, or the check could not run (the exception text is the message) | yes, for a blocking check |
| Warning | a real finding that was verified and does not stop the deployment | no |
| Skipped | the check could not verify it here (no sign-in, no domain controller, the node or one section of its read failed, a module is missing, a value could not be compared) | yes, unless its id is named in `-AcceptSkipped` |
| NotApplicable | the check does not apply to this design (for example the Active Directory checks for local identity) | no |
| Fixed | `-Fix` repaired it | no |

"Could not verify" is never a Warning and never a Pass. The verdict is **Pass** only when no result blocks. Every result carries the check id, the node (`*` when it is not about one node), the message (never
truncated), the remedy with the exact command and the source URL.

`-Fix` (Verify only) registers the mandatory resource providers that are not registered and waits until they are Registered (check `AZ-004`). It never changes a node, Active Directory or DNS.
Without `-Fix`, and in Plan, nothing is changed anywhere.

## Output

The report directory is `-ReportDirectory`, else `deployment.pre_cluster_verification_report_directory`, else `arm-report\verification\live` in the **environment data folder**: the folder
that holds `provisioning.simplified.evidence_path` (for example `D:\Data\azl-ztp\iic\evidence` gives `D:\Data\azl-ztp\iic\arm-report\verification\live`), else the one that holds
`media_path`, else the folder of the infrastructure file. Sonar follows `precluster-verification-events.jsonl` there.

| File | Content |
| --- | --- |
| `precluster-verification-events.jsonl` | one single-line JSON object per line, written as the run goes: `RunStarted`, one `Check` per result, `RunCompleted` (always, also when the run fails: verdict `Error`) |
| `report.json` | the whole result: verdict, counts, per-category counts, `fileHash`, `completedUtc`, `expiresUtc`, `partial`, the accepted skips, the Environment Checker statement, the modules loaded, every check |
| `summary.md` | for a person and a pipeline job summary: verdict, a breakdown per category, what blocks with the fix, all checks |
| `plan.json`, `plan.md` | Mode Plan only; never counted by the ARM run |

Event line (every line has every field; `checkId`, `category`, `title`, `status`, `remedy`, `source` are empty on `RunStarted` and `RunCompleted`, `node` is `*`):

```json
{"schema":1,"runId":"411102be14a9","seq":14,"ts":"2026-11-08T12:00:03.2114Z","type":"Check","checkId":"AZ-004","category":"azure","title":"All 13 mandatory resource providers are registered","status":"Failed","node":"*","message":"Mandatory resource providers not registered: Microsoft.KeyVault (NotRegistered). ...","remedy":"Register-AzResourceProvider -ProviderNamespace Microsoft.KeyVault","source":"https://learn.microsoft.com/...","blocking":true}
```

`type` is `RunStarted`, `Check` or `RunCompleted`; `category` is `azure`, `identity`, `nodes`, `network`, `storage` or `readiness`; `status` is one of the six statuses; `blocking` is true when this result keeps
the verdict at Fail (a Failed blocking check, or a blocking Skipped check that was not accepted). `RunCompleted` adds `verdict` (`Pass`, `Fail` or `Error`), `counts` (per status), `fileHash` (SHA-256 of the
infrastructure file) and `expiresUtc` (completion time plus `deployment.pre_cluster_verification_max_age_hours`, default 4). The feed of a run replaces the feed of the run before; while a run is in progress
the previous `report.json` is moved to `report.previous.json`, so a half-finished run can never be read as a pass. `summary.md` is written first and `report.json` last, each through a temporary file; if any output
cannot be written the run ends with exit code 1 and no `report.json`. No secret is written to any file; values read from Key Vault are replaced by `***`.

### What the ARM run does with it

The precondition `PreClusterVerification` of Mode Validate and Deploy **fails** unless the latest `report.json` in the report directory
(a) was made by `-Mode Verify`, (b) covers all six categories (no `-Category`), (c) has the verdict `Pass`, **and its own checks agree**: some checks, all six categories, no Failed or blocking check, no Skipped check
that was not accepted, `summary.md` next to it, (d) has the `fileHash` of the infrastructure file as it is now **and as it was when the ARM run parsed it**, and (e) is not older than the ARM run allows
(`deployment.pre_cluster_verification_max_age_hours`, enforced by the ARM run itself from `completedUtc`) and has not expired (`expiresUtc`, at most 168 hours after `completedUtc`; a result dated in the future is refused).
The failure names the reason (with the ids of the blocking checks) and the exact command, which is never cut. Checks that stayed Skipped with `-AcceptSkipped` are shown in the evidence, the ARM report and its summary.
In Mode Plan it is a Warning and never blocks.

The only way past it is the explicit switch `-SkipPreClusterVerification` of `Invoke-AzureLocalArmDeployment.ps1`: it is warned loudly, recorded in `report.json` (`preClusterVerification.status` is `Bypassed`), in the
summary and in the ARM event feed. There is no infrastructure.yml key for it, a settings file or a `-Settings` table that carries it is refused (exit code 2), and `skip_preconditions` does not apply to it.

## Settings (registry first)

| Setting | infrastructure.yml key | Default |
| --- | --- | --- |
| `preClusterVerificationMaxAgeHours` | `deployment.pre_cluster_verification_max_age_hours` | 4 (1 to 168) |
| `preClusterVerificationReportDirectory` | `deployment.pre_cluster_verification_report_directory` | the environment data folder, `arm-report\verification\live` |
| `skipPreClusterVerification` | none, on purpose | switch `-SkipPreClusterVerification` only |
| `installEnvironmentChecker`, `keepEnvironmentChecker` | none, on purpose | false, false (switches `-InstallEnvironmentChecker`, `-KeepEnvironmentChecker`) |
| `verificationMinMemoryGiB` | `deployment.verification_min_memory_gib` | 32 (Learn) |
| `verificationMinBootDiskGB` | `deployment.verification_min_boot_disk_gb` | 200 (Learn) |
| `verificationMinDataDiskGB` | `deployment.verification_min_data_disk_gb` | 500 (Learn) |
| `verificationMinLinkGbps` | `deployment.verification_min_link_gbps` | 10 (Learn, storage) |
| `verificationMaxClockSkewSeconds` | `deployment.verification_max_clock_skew_seconds` | 300 (Kerberos) |
| `verificationLdapTimeoutSeconds` | none, on purpose (a limit of the tool, not a property of the site) | 20 seconds for one directory query; raise it for a slow directory |
| `verificationEndpointTimeoutSeconds` | none, on purpose | 5 seconds for one TCP connect from a node to an endpoint |
| `verificationRemoteCallSeconds` | none, on purpose | 180 seconds for one read only call to a node |
| `verificationSessionOpenSeconds`, `verificationSessionOperationSeconds` | none, on purpose | 20 and 60 seconds for the default WinRM session of the identity checks |
| `verificationPortTimeoutSeconds` | none, on purpose | 3 seconds for one TCP connect to a domain controller port |
| `verificationWebTimeoutSeconds` | none, on purpose | 6 seconds for one web request from a node |
| `verificationResultFutureToleranceMinutes` | none, on purpose | 5 minutes: how far ahead of this clock a gate result may be dated |
| `verificationAdvisedFeatures` | none, on purpose | `FS-Data-Deduplication`, `RSAT-AD-PowerShell`, `RSAT-Clustering-PowerShell`: the features the node check only advises (a warning) |
| `providerRegistrationTimeoutMinutes`, `providerRegistrationPollSeconds` | none, on purpose | 15 minutes and 10 seconds: the wait of `-RegisterResourceProviders` and of the gate's `-Fix` |
| `reportDirectoryPrefix` | none, on purpose | `azl-arm`: without `-ReportDirectory` the report folder is `<temp folder>/<prefix>-<cluster name>` |
| `deploymentNamePrefix` | none, on purpose | `azl`: the ARM deployments are named `<prefix>-validate-<hash>` and `<prefix>-deploy-<hash>` |
| `allowRevalidate` | `deployment.allow_revalidate` | false (switch `-AllowRevalidate`, also on the ARM Validate) |
| `secretMode` | none, on purpose (how the parameter file is made, not a property of the site) | `Placeholder`. Give `-Settings @{ secretMode = KeyVaultReference }` when the parameter file is made with `New-AzureLocalArmParameters.ps1 -SecretMode KeyVaultReference`: Azure Resource Manager then reads the secrets and can read only `keyvault://` references, so AZ-010, AZ-011 and AZ-012 fail for an `env://`, `file://` or `command://` reference. In `Placeholder` mode every provider is fine. |
| user name secret | `identity.local_admin.username_secret` (optional) | `local-admin-username` in the vault of the password |

## Verification modules (the contract for checks)

Every `scripts/common/arm-deployment/verification/AzlVerification.*.psm1` is imported by the engine. A module exports:

```powershell
Get-AzlVerificationCheckDefinition   # array of @{ Id; Category; Title; Source; Blocking; Applies = { param($Context) }; Run = { param($Context) } }
Get-AzlVerificationAdapterDefault    # optional: a table of read only scriptblocks the module's checks call through $Context.Adapters
```

- `Category` is `azure`, `identity`, `nodes`, `network`, `storage` or `readiness`. `Blocking` defaults to true. (The SBE package checks SB- sit in `nodes`.)
- `Applies` returns `$true`, or `$false` / a reason string (the check is then NotApplicable with that text).
- `Run` returns one or more results, as hashtables or objects: `@{ Status = 'Passed'|'Failed'|'Warning'|'Skipped'|'NotApplicable'; Node = '*'; Message; Remedy; Evidence }`. `Evidence` (a string or a list)
  is appended to the message in full. Return one result per node for a per-node check. Never return a secret.
- `$Context` is a hashtable built once per run and shared: `Infrastructure` (the parsed file), `Handoff`, `OsReport`, `Settings` (the run settings, including the thresholds), `Adapters` (below), and `Cluster`, `Nodes`,
  `Subscription`, `ResourceGroup`, `Identity`, `Architecture`, `Fix`, `Mode`, `Cache`, `Remoting`.
- `Adapters` is the engine's adapter (Azure ARM, Key Vault, the clock, the flat members used by `ARM-001` and `-Fix`) plus the members of every module's `Get-AzlVerificationAdapterDefault` that the engine does
  not have yet. Priority: a test's fake, then the engine, then a module default. A check reads Azure, Active Directory and the nodes only through `Adapters`, never directly.
- `Adapters.Remote.Invoke` is supplied by the engine and serves both call forms the modules use: `Invoke(node, scriptblock [, argumentList])` returns what the script block output and throws when the call fails
  (the local administrator comes from Key Vault, the addresses from the file, the WinRM options are the toolkit's); `Invoke(request)` returns `Ok`, `Address`, `Result`, `Error`, `AuthFailed`.
- A node read is complete or it is not: when a section of the node script failed (`err.<section>`), checks that need that section are Skipped for that node with the reason, never Passed on empty data.
- A check that throws is Failed with the exception text; the run goes on. A module that does not load, a definition that is unusable, a **missing** module (the folder, or one of the seven modules of the
  repository) and an id defined by two modules each become a failing check (`EXT-<name>`), never a silent gap. A module that exports neither function is a library (`AzlVerification.NodeCommon.psm1`).
- A definition with the Id of a built-in check (`ARM-001`) replaces it.

## The VLAN plan and the switch ports

The file is the authority for the gate; the lab's `pmo/azure-local/vlan-inventory.md` is the human source the file is written from (the gate does not read it). The gate cannot read a switch, so it checks the plan inside the file and
what it can read on the nodes, and lists what a person must verify on each switch.

- **NW-015, the VLAN plan:** `networking.vlans[]` (name, id, subnet, purpose) has no VLAN id, name or subnet twice and no overlapping subnets; `networking.management.subnet` belongs to exactly one entry (its id is the management VLAN); the
  management ports agree with it (`vlan_mode` access = the host sends untagged, so the NIC VLAN must be 0; tagged = the host tags `vlan_id`, which must be the management VLAN) and so does `networking.management.vlan_id`; on the node the NIC VLAN
  of each management port is what the file says the host tags; every storage network (`networking.storage.networks[]`, `networking.cluster_networks[]`) uses a VLAN of the plan, distinct per network, not the management VLAN, with purpose storage;
  the node addresses, the gateway and the infrastructure pool are inside the management subnet (DNS and domain controllers outside it only warn: they may be routed). The compute VLANs (vlans[] and logical networks whose purpose is compute)
  must be allowed on the compute ports: `nodes[].network_adapters[].allowed_vlans` (optional list of VLAN ids, registry 5.0.11) says what a trunk port allows. A compute port that is tagged but has no `allowed_vlans` makes the check **Skipped**
  (blocking unless accepted), never Passed. The lab: management 711, storage 712 and 713, compute 717 only, so `allowed_vlans: [717]` on the two compute ports of each node; nothing else is expected.
- **NW-016, the switch port checklist:** one NotApplicable line per used port that has `switch_port` data, "switch trunk/access config is not readable from here; verify against <switch> <port>", with the expected mode and VLANs and where each comes from.
  The same rows are in `report.json` (`switchPortChecklist`: switch, port, node, filePort, mac, roles, expectedMode, expectedVlans, hostTag, source) and as a table in `summary.md`.
- **NW-013, NW-014:** the ports and the storage adapters, see below.

## What the first lab run taught us

The first run on the lab (3 nodes, hybrid with a Fibre Channel SAN) gave 22 blocking results. Most were the gate being wrong, not the lab. What was fixed, and the rule behind each:

| What the run showed | What was wrong | The rule now |
| --- | --- | --- |
| AZ-023, NW-005 and ID-DNS-003 failed for `eastus.his.arc.azure.com` and `dp.kubernetesconfiguration.azure.com` | The hosts were made up. The Arc hybrid identity endpoint uses a short code of the region (`eus`), not `eastus`; the Kubernetes data plane host carries the region (`eastus.dp.kubernetesconfiguration.azure.com`) | One list, `AzlVerification.Endpoints.psm1`, taken from Learn (Firewall requirements for Azure Local, the consolidated endpoint lists of each region, and the Arc agent network requirements). The region is substituted exactly where Learn shows it; the short code only for the regions Learn lists (eastus eus, westeurope weu, australiaeast ae, canadacentral cc, centralindia pn, southeastasia sea, japaneast je, southcentralus scus). A host that does not resolve is Failed only if it is in the list; wildcards cannot be tested and are named in the result as not tested; CRL and OCSP hosts on port 80 and the entries Learn marks conditional are Warnings |
| ID-AD-007 said the LCM user lacks create and delete computer objects although it had the entries | The check compared entries of the OU with the LCM user, and this host cannot translate SIDs of another domain | Entries are matched by SID only (the user's `objectSid` and its `tokenGroups`); the failure now names the SID and the entries it compared |
| ND-010 failed for `NetworkATC` | Network ATC is installed by the deployment; on the lab it is only Available before it | ND-010 requires what the OS carries before the deployment (Hyper-V, Failover Clustering, Data Center Bridging, BitLocker) and never lists Network ATC |
| AZ-005, AZ-007 and AZ-008 Skipped with "Parameter set cannot be resolved" | `Get-AzRoleAssignment` cannot take `-Scope` with `-ExpandPrincipalGroups` | The roles are listed through ARM REST (`roleAssignments?$filter=assignedTo('{objectId}')` on the scope: transitive over groups, includes what is inherited from management groups); the object id comes from `Get-AzADUser`, else Graph `/me`, or the service principal |
| RD-004 and RD-005 Skipped | The readiness adapter never received the local administrator credential | The engine gives `Adapters.Readiness` the credential it already uses for Remote.Invoke (`.\user`) and the node addresses |
| AZ-018 Failed on a failed deployment state | Correct by default, but the operator could not accept the risk | `-AllowRevalidate` (also on the ARM Validate) makes it a Warning that records the accepted license-sync risk; the remedy names it |
| AZ-016 Failed for Arc machines named after the device ID | The claim that this breaks Deploy step 0.41 was seen on a prerelease build in another environment and not reproduced here | A non-blocking Warning in every phase, with the reported-not-reproduced wording and the remedies from Learn: the Arc resource name is fixed at onboarding, so set it to the host name at provisioning (simplified machine provisioning, pencil, step 3.4), with `--resource-name <hostname>` when registering, or `azcmagent disconnect` and connect again. The file keeps `nodes[].arc_machine_name`, so the ARM parameters point at the real resource whatever it is called. No check depends on this naming being a defect |
| Azure Validate step 50, `AzureLocal_Network_Test_StorageAdapterReadiness`: "Adapter has the following VLANID configured: [ 712 ]" | The storage NICs still carried a VLAN ID from an earlier attempt; the OS configuration never set it, and no check looked | NW-014: every storage-intent adapter (found by MAC from the file) must have no NIC VLAN ID (advanced property `VlanID` and `Get-NetAdapter` both 0 or absent), no manual or DHCP IPv4 address (APIPA is fine), no default gateway, and there must be no duplicate adapter names on the node. The remedy is `Set-NetAdapterAdvancedProperty -Name <adapter> -RegistryKeyword VlanID -RegistryValue 0` and `Restart-NetAdapter`. The file's `vlan_id` and `vlan_mode` on a node adapter are switch port metadata, not a NIC setting: Network ATC applies the storage VLANs itself (`networking.storage.networks[].vlan_id`) |
| ST-008 said Test-Cluster fails | The LUNs were visible but MPIO already showed each once | The message says what is true now: LUNs visible, claimed once each, and that Learn still advises not zoning before the deployment |
| RD-003 (Environment Checker, `VlanID` inconsistent values) | A legitimate warning | Stays a Warning |

Ports are never assumed to have a name. NW-013 reads only what the file says (`nodes[].network_adapters[]`: its name, MAC, roles, slot; `networking.intents[].adapters`; `networking.cluster_networks[]`), finds each port on the node by MAC, and
shows the file name next to the OS name. The same file port must have the same OS name on every node, every intent adapter must exist on every node, and the node's name must be the one the OS configuration report carries for that MAC.
Names such as `Port1`, `Slot 3 Port 1`, `NIC1` or `Embedded NIC 2` are all the same to it.

The adapter model behind it: `mac_address` is the identity of a port; `slot`, `port_index`, `pci_location`, `vendor`, `model`, `speed_gbps` and `rdma` say which connector it is and what it can do (hardware discovery writes them from the BMC, for any vendor, through the same keys). Intents and storage networks refer to `nodes[].network_adapters[].name`, the key of the port in the file. The OS adapter name is never assumed: it is read from the node by MAC.

When the same file port has different OS names on different nodes, NW-013 fails (Network ATC needs one adapter name per intent adapter on every node) and the remedy gives the two ways out: install the nodes consistently so the OS names the adapter alike everywhere, or set `nodes[].network_adapters[].os_name_override` for the port (the same value on every node) and run the OS configuration `NicNames` step, which finds each adapter by MAC and renames it. The rename is opt-in: without `os_name_override` nothing is renamed. A port that has an `os_name_override` the node does not carry yet is Failed on that node with the same remedy. A different PCI location on the node than `pci_location` in the file is reported by the OS configuration, never by this gate as a failure.

## Where Learn and the azurelocal.cloud pages differ

Learn wins; the differences are listed in `docs-2610-audit.md` of the documentation repository.

- Resource providers: 13, with `Microsoft.KeyVault` (the azurelocal.cloud prerequisites page lists 12) - AZ-004.
- Nodes and the domain: Learn supports a domain join before the deployment from version 2604 (the deployment user in the local Administrators group); the nodes may also stay in a workgroup, and are
  joined during the deployment. ID-AD-010 encodes exactly that; for local identity ID-LI-004 requires a workgroup.
- KDS root key: Learn 2610 does not list one for Azure Local (ID-AD-012 says so; it only matters for gMSA, `identity.active_directory.use_gmsa`).
- DNS: public resolvers are not supported; CNO and VCO host records are required only when the DNS server has no secure dynamic update (ID-DNS-002; `identity.active_directory.dns_secure_dynamic_updates`).
- Storage MTU: 9216 on the switch with 9014 on the host, not 9174. RDMA and jumbo frames belong to the storage traffic; management and compute are RDMA off, 1514 (NW-002, NW-012).
- Hybrid Fibre Channel: do not zone the HBA WWNs until after the deployment (ST-008, ST-011), with the workarounds (MPIO claims the array first, or disable the HBA for the deployment window).
  ST-006 follows the OS configuration: the array must be multipathed in `Get-MPIOAvailableHW`, registered with MSDSM, and in MPIO's own list (`MPDEV\MPIOSupportedDeviceList`, written by `mpclaim -n -i -d`).

## Failures Azure returned in this project, and the check that catches each

| Failure | Check |
| --- | --- |
| ValidateArcIntegration, `AzStackHci_ArcIntegration_MandatoryRPRegistration_Check` (HybridContainerService) | AZ-004 |
| Wrong Azure tenant context | AZ-001, AZ-002 |
| Active Directory preparation skipped (OU, LCM user) | ID-AD-003, ID-AD-004, ID-AD-005, ID-AD-007; a gate that cannot ask is Skipped and blocks |
| DNS and AD name resolution, ADWS 9389 | ID-AD-009, ID-DNS-001, ID-DNS-003 |
| Cluster validation: RDMA operational on a management intent | NW-002 |
| Test-Cluster "Two disks ... cannot be distinguished" (SAN LUNs seen once per path, not declared or not claimed) | ST-004, ST-006, ST-007, ST-011 |
| Step 0.60 environment checker: SBE not validated with the solution, or an SBE left in `C:\SBE` | ND-004, RD-003 |
| `RoleAssignmentExists` after a portal attempt; zombie role assignments | AZ-020, AZ-019 |
| `arc-device-id-name` (Deploy step 0.41; reported on a prerelease build in another environment, not reproduced here) | AZ-016, a Warning only |
| Another Validate after a failed deployment (license sync) | AZ-018 |
| `unsupported-os-version` | ND-003, ND-004 |
| Local administrator mismatch (vault says `Administrator`, file says `azl-admin`) | AZ-013, ID-LA-001, ID-LA-003, ID-LA-004 |

## The catalog

Generated from the effective catalog (`Get-AzlPclCatalog`): the built-in `ARM-001` and the seven modules. Blocking = a Failed (or unaccepted Skipped) result blocks the verdict. Sources are Microsoft Learn pages at
`view=azloc-2610`, or repository files. `-Fix` can repair only `AZ-004`.

### AZURE

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| ARM-001 | The ARM parameters can be generated from the file and match the template | the file (and the OS configuration report for adapter names) | yes | [Learn: deploy/deployment-azure-resource-manager-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610) |
| AZ-001 | Signed in to the tenant and subscription the file names | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZ-002 | Subscription is enabled and in the tenant of the file | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZ-003 | Resource group of the instance exists | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZ-004 | All 13 mandatory resource providers are registered (`-Fix`) | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610; https://azurelocal.cloud/docs/implementation/02-azure-foundation/phase-02-resource-providers/task-02-verify-provider-registration) |
| AZ-005 | Subscription roles: Contributor and User Access Administrator (or Owner) | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610; https://azurelocal.cloud/docs/implementation/02-azure-foundation/phase-03-rbac-permissions/task-02-assign-rbac-roles) |
| AZ-006 | Effective permissions on the resource group include role assignment, deployment, cluster, Key Vault and storage writes | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610) |
| AZ-007 | The roles Learn lists for the deploying user on the resource group | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610 (Assign Azure permissions for deployment)) |
| AZ-008 | The roles Learn lists for registering the machines with Azure Arc (Azure Connected Machine Onboarding and Resource Administrator) | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610 (Verify permissions)) |
| AZ-009 | The Azure Local resource provider service principal exists, matches the file and holds its role | verification module AzlVerification.Azure | no | [Learn: deploy/deployment-azure-resource-manager-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610 (Get the object ID for Azure Local Resource Provider); https://github.com/Azure/bicep-registry-modules/blob/main/avm/res/azure-stack-hci/cluster/README.md) |
| AZ-010 | The secret references of the local administrator and LCM user are valid; a keyvault:// reference names a listed vault that exists | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZ-011 | Every Key Vault secret the deployment parameters reference exists | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZ-012 | The local administrator and LCM password secrets can be read (any provider) and are not empty | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZ-013 | The vault's local-admin username secret equals identity.local_admin.username | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610; config/known-issues/arm-deployment.json (built-in Administrator is refused)) |
| AZ-014 | Names of the cloud witness storage account, diagnostics storage account and new Key Vault are free | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| AZ-015 | Arc machines exist, are Connected and are in the resource group of the file | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-arc-register-server-permissions](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610; https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-04-arc-registration/task-04-verify-arc-registration-and-connectivity; https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-04-arc-registration/task-01-pre-registration-validation) |
| AZ-016 | Arc machines are named after the host (known issue arc-device-id-name) | verification module AzlVerification.Azure | yes | config/known-issues/arm-deployment.json (arc-device-id-name) |
| AZ-017 | No node is Arc-enabled twice or in another resource group | verification module AzlVerification.Azure | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (Arc integration validator)) |
| AZ-018 | No leftover failed or running deployment on the instance | verification module AzlVerification.Azure | yes | config/known-issues/arm-deployment.json (license-sync-after-failed-validate) |
| AZ-019 | No zombie role assignments (Identity not found) in the resource group | verification module AzlVerification.Azure | yes | config/known-issues/arm-deployment.json (role-assignment-zombie) |
| AZ-020 | No role assignment left by an earlier (portal) deployment that the template would create again | verification module AzlVerification.Azure | yes | config/known-issues/arm-deployment.json (role-assignment-already-exists); [Learn: deploy/deployment-azure-resource-manager-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610) (known issues) |
| AZ-021 | No Windows update extension on the Arc machines (updates install during the deployment) | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| AZ-022 | The Arc gateway resource exists (outbound path with an Arc gateway) | verification module AzlVerification.Azure | yes | [Learn: deploy/deployment-without-azure-arc-gateway](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-without-azure-arc-gateway?view=azloc-2610) |
| AZ-023 | Nodes reach the Azure Arc endpoints on 443 (probed from each node) | verification module AzlVerification.Azure | yes | [Learn: concepts/firewall-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements?view=azloc-2610; https://azurelocal.cloud/docs/implementation/04-cluster-deployment/phase-04-arc-registration/task-01-pre-registration-validation (Test-ArcConnectivity.ps1)) |

### IDENTITY

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| ID-AD-001 | Active Directory settings in the file follow Learn (domain, OU path, LCM user name) | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610) |
| ID-AD-002 | A domain controller answers on LDAP and accepts the LCM credential | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610; azl-toolkit Test-ADConfiguration.ps1 (LDAP connectivity)) |
| ID-AD-003 | The dedicated OU exists | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610; azl-toolkit Test-ADConfiguration.ps1 (Cluster OU)) |
| ID-AD-004 | The LCM user exists, is enabled, not locked, not expired, may log on interactively and is in the OU | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610 (Deployment user requirements); azl-toolkit Test-ADConfiguration.ps1 (LCM user exists, enabled, in cluster OU)) |
| ID-AD-005 | LCM password policy: at least 14 characters with lower, upper, digit and special character; user name is not admin | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610 (Active Directory preparation module, AzureStackLCMUserCredential)) |
| ID-AD-006 | Group policy inheritance is blocked on the OU (Block Inheritance); enforced GPOs above it are reported | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610 (note on enforced GPOs); https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610) |
| ID-AD-007 | The LCM user holds Learn's delegated rights on the OU: list, read all properties, read permissions, create and delete computer objects | verification module AzlVerification.Identity | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610 (Required permissions)) |
| ID-AD-008 | Computer objects of the nodes and the cluster that already exist (pre-created) are in the OU | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610 (moving computer objects to another OU after deployment isn't supported); https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610) |
| ID-DNS-001 | DNS host (A) records of every node exist and match the management address | verification module AzlVerification.Identity | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610 (Required DNS records); https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (Configure DNS server)) |
| ID-DNS-002 | Cluster name (CNO) and client access point (VCO) host A records exist when DNS has no secure dynamic updates | verification module AzlVerification.Identity | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610 (Required DNS records; Cluster aware updating)) |
| ID-AD-009 | Nodes resolve the domain and its domain controllers with the file's DNS servers, and reach ADWS (9389), LDAP (389) and Kerberos (88) | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610 (firewall); https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements?view=azloc-2610; azl-toolkit Test-DnsClientConfig.ps1) |
| ID-AD-010 | Domain join state of the nodes: workgroup, or joined to the file's domain (supported from 2604) with the deployment user in local Administrators | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-install-os-disaggregated](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610 (Domain join before deployment); azl-toolkit Test-ADPrerequisites-Standalone.ps1 (secure channel)) |
| ID-AD-011 | Disjoint namespace: the primary DNS suffix of a joined node matches the domain | verification module AzlVerification.Identity | yes | [Learn: plan/configure-custom-settings-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/plan/configure-custom-settings-active-directory?view=azloc-2610 (Disjoint namespace)) |
| ID-AD-012 | KDS root key (Learn 2610 does not require it for Azure Local; only for gMSA) | verification module AzlVerification.Identity | no | [Learn: deploy/deployment-prep-active-directory](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610; azl-toolkit Test-ADConfiguration.ps1 (KDS Root Key, not a Learn requirement)) |
| ID-LI-001 | Local identity settings: DNS zone, DNS server configuration and the template parameters they feed are present | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault-template?view=azloc-2610 (ARM template parameters reference); https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610) |
| ID-LI-002 | Local identity: static IP addresses only (no DHCP) for the nodes | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (Prerequisites 4)) |
| ID-LI-003 | Local identity: A records for every node and for the system (first infrastructure address) in the zone | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (Configure DNS server for Azure Local, steps 2 and 3)) |
| ID-LI-004 | Local identity: nodes are in a workgroup and resolve the node names of the zone with the file's DNS servers | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (Prerequisites 5; Configure DNS server, steps 3 and 6); azl-toolkit Test-LocalIdentityConfig.ps1 (WORKGROUP)) |
| ID-LI-005 | Local identity: SSH (sshd) is enabled on every node | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (Prerequisites 6)) |
| ID-LA-001 | The dedicated local administrator in the file is named, is not the built-in Administrator and differs from the LCM user | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (Prerequisites 2); https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2610 (the LCM name can't equal the local admin)) |
| ID-LA-002 | Local administrator password policy: at least 14 characters with lower, upper, digit and special character | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610 (Local administrator credentials); https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610) |
| ID-LA-003 | The Key Vault password opens a WinRM session as the dedicated local administrator on every node | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (identical credentials on every node); https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) |
| ID-LA-004 | On every node the dedicated local administrator exists, is enabled, is in local Administrators and is not the built-in Administrator | verification module AzlVerification.Identity | yes | [Learn: deploy/deployment-local-identity-with-key-vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault?view=azloc-2610 (Prerequisites 2.1); azl-toolkit Deploy-CreateLocalAdmin.ps1, Test-LocalIdentityConfig.ps1) |
| ID-DNS-003 | The DNS servers on the nodes are the file's, and the nodes resolve the Azure endpoints with them | verification module AzlVerification.Identity | yes | azl-toolkit Test-DnsClientConfig.ps1 (DNS servers, Azure endpoint resolution); [Learn: deploy/deployment-prerequisites](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-prerequisites?view=azloc-2610) (DNS server must resolve the AD domain; can't be changed after deployment) |

### NODES

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| ND-001 | Every node answers over WinRM and the read of it is complete | verification module AzlVerification.Nodes | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610; azl-toolkit phase-02-os-installation Test-OsDeployment.ps1 (reachable)) |
| ND-002 | Computer name equals the node name in the file and is a valid name | verification module AzlVerification.Nodes | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610; azl-toolkit phase-03-os-configuration task-10 Set-NodeHostname / task-13 Task10_Hostname) |
| ND-003 | All nodes run exactly the same OS build | verification module AzlVerification.Nodes | yes | [Learn: deploy/deployment-azure-resource-manager-template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (software validator: same OS version)) |
| ND-004 | The OS build is the one the target solution version ships with | verification module AzlVerification.Nodes | yes | [Learn: whats-new](https://learn.microsoft.com/en-us/azure/azure-local/whats-new?view=azloc-2610; config/known-issues/arm-deployment.json (unsupported-os-version)) |
| ND-005 | Time: a real NTP source (not the CMOS clock), the same on every node, in step with this host | verification module AzlVerification.Nodes | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610; azl-toolkit phase-03-os-configuration task-07 Set-NTPConfiguration / task-13 Task07_NTP; Learn software validator (same NTP on all nodes)) |
| ND-006 | DNS client: the nodes use the DNS servers of the file, the same on every node, none of them public | verification module AzlVerification.Nodes | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (DNS server considerations); azl-toolkit phase-03-os-configuration task-06 Test-DnsClientConfig.ps1) |
| ND-007 | No pending restart on any node | verification module AzlVerification.Nodes | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610; azl-toolkit phase-04-arc-registration pre-registration checks) |
| ND-008 | Processors and memory: identical processors, at least the minimum memory, virtualization on, at least what the file declares | verification module AzlVerification.Nodes | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610 (Machine and storage requirements); Learn hardware validator (Processor, Memory)) |
| ND-009 | Boot disk is at least the minimum size (the BOSS card is the boot device) | verification module AzlVerification.Nodes | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610 (Boot drive: at least 200 GB)) |
| ND-010 | Required Windows features are installed before the deployment (Hyper-V, Failover Clustering, Data Center Bridging, BitLocker); the deployment installs Network ATC itself | verification module AzlVerification.Nodes | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610; azl-toolkit phase-02-os-installation Test-OsDeployment.ps1 (Get-RequiredWindowsFeatures)) |
| ND-011 | Secure Boot on, TPM 2.0 present and ready, the same BIOS version on all nodes | verification module AzlVerification.Nodes | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (hardware validator: Firmware tests)) |
| ND-012 | No node is already a member of a cluster | verification module AzlVerification.Nodes | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610 (clean the machines before the deployment); azl-toolkit phase-03-os-configuration task-11 Clear-StorageConfiguration) |

#### The SBE package (SB-, category NODES)

The OEM Solution Builder Extension package is a **requirement**: downloaded and available on a share the automation can read (`hardware.sbe.source_path`), for the first cluster update at the latest.
The six checks read the share, read only, from the machine that runs the gate (they read a node only for the model it reports, through the snapshot the NODES checks already take). The side-load
to the nodes during the build is a separate opt-in (`hardware.sbe.delivery`, default `skip`) and is not checked here. Anything a check cannot read is **Skipped** (blocking unless accepted), never Passed;
a package that is there but wrong is **Failed** with the exact reason. A share that answers but has no such folder (`NotFound`) or refuses the credential (`AccessDenied`) is Failed; one that cannot be reached
from this host is Skipped, because another host may reach it.

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| SB-001 | The SBE package is required and its source (a share the automation can read) is configured, or the file declares it not applicable with a reason | verification module AzlVerification.Sbe | yes | https://learn.microsoft.com/en-us/azure/azure-local/update/solution-builder-extension?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/update/update-via-powershell-23h2?view=azloc-2610#step-3-import-and-rediscover-updates |
| SB-002 | The SBE source is reachable from this host with the configured credential (read only) | verification module AzlVerification.Sbe | yes | https://learn.microsoft.com/en-us/azure/azure-local/update/solution-builder-extension?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/update/update-via-powershell-23h2?view=azloc-2610#step-3-import-and-rediscover-updates |
| SB-003 | The three package files are there: SBE_Discovery_<Vendor>.xml, SBE_<Vendor>_<Family>_<Version>.xml and SBE_<Vendor>_<Family>_<Version>.zip | verification module AzlVerification.Sbe | yes | https://learn.microsoft.com/en-us/azure/azure-local/update/solution-builder-extension?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/update/update-via-powershell-23h2?view=azloc-2610#step-3-import-and-rediscover-updates |
| SB-004 | The package files agree: names match the discovery entry, sizes above zero, SHA-256 matches the manifest (and the hash pinned in the file) | verification module AzlVerification.Sbe | yes | https://learn.microsoft.com/en-us/azure/azure-local/update/solution-builder-extension?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/update/update-via-powershell-23h2?view=azloc-2610#step-3-import-and-rediscover-updates |
| SB-005 | The package family matches the hardware model of EVERY node (SupportedModels of the package's own discovery manifest) | verification module AzlVerification.Sbe | yes | https://learn.microsoft.com/en-us/azure/azure-local/update/solution-builder-extension?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/update/update-via-powershell-23h2?view=azloc-2610#step-3-import-and-rediscover-updates |
| SB-006 | The SBE version is validated for the target solution version (the validated solution versions of the package's discovery manifest) | verification module AzlVerification.Sbe | yes | https://learn.microsoft.com/en-us/azure/azure-local/update/solution-builder-extension?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/update/update-via-powershell-23h2?view=azloc-2610#step-3-import-and-rediscover-updates |

- **SB-001** decides from `hardware.sbe.requirement`: `required`, or `not_applicable` with `not_applicable_reason` (NotApplicable; without the reason it is Failed). Absent, the vendor catalog (`config/oem/<vendor>.json`, `sbe.acquisition` and `requiredByDefault`) decides: `required` for a manual download (Dell, HPE, DataON), a Warning asking you to state it where the cluster downloads the package itself (Lenovo Premier), Skipped for a vendor the catalog does not know. The catalog cells other than Dell are marked unverified.
- **SB-005** takes the family-to-model mapping from the `SupportedModels` of the package's own `SBE_Discovery_<Vendor>.xml` entry; no model is written in the toolkit. Models are compared as letters and digits (`AX-760` is `AX760`). It checks the file's `hardware.model` and the model each node reports. For the 17G-Intel zip on AX-760 nodes it fails with the family's supported models, the node model, and the package that does list the model and is validated with the target solution.
- **SB-006** reads the validated solution versions from the same entry (`12.*.1004.*` patterns, `MinVersionRequired`); the target is `deployment.solution_version` (run setting `solutionVersion`), else the ZTP handoff, else `provisioning.os_version`.
- A share can hold several packages: `hardware.sbe.family` and `version` choose one, else the one whose `SupportedModels` list the file's model; otherwise SB-003 fails and says to choose.
### NETWORK

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| NW-001 | Intents against adapters: every adapter of every intent exists under the same name on every node, link up, at least two per intent | verification module AzlVerification.Network | yes | [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Decision 6, 7); azl-toolkit phase-03-os-configuration task-03 Set-StaticIPAddress / task-13 Task0304_StaticIP) |
| NW-002 | RDMA (Network Direct) only on the storage intent, on adapters that are RDMA capable; never required on management or compute | verification module AzlVerification.Network | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Decision 6: Network Direct); https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610; lab failure: RDMA operational check failed on a management intent) |
| NW-003 | Link speed: at least 10 Gbps for compute and storage, the adapters of an intent run at one speed on every node | verification module AzlVerification.Network | yes | [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Decision 6)) |
| NW-004 | Management network: the management adapter has the file's address, a static IP and the default gateway, and the gateway and DNS servers answer | verification module AzlVerification.Network | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Node and cluster IP assignment, DNS server and Management IP pool considerations); azl-toolkit phase-03-os-configuration task-03/04 and task-13 Task0304_StaticIP) |
| NW-005 | Nodes reach the documented outbound endpoints (443, and 80 for revocation lists), directly or through the proxy | verification module AzlVerification.Network | yes | [Learn: concepts/firewall-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements?view=azloc-2610 (consolidated endpoint list of the region); https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (connectivity validator, RD-002, covers them again); AzlVerification.Endpoints.psm1) |
| NW-006 | Proxy: the node's proxy settings follow the file (none for a direct path; the file's proxy for a proxy path; no PAC, no credentials) | verification module AzlVerification.Network | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Proxy requirements); https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements?view=azloc-2610) |
| NW-007 | Cluster service does not exclude adapters (ClusSvc exclusion registry values) | verification module AzlVerification.Network | no | [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610; lab finding (ClusSvc\Parameters Exclude* values)) |
| NW-008 | Remote NDIS device (BMC USB NIC) is noted and kept out of the way of the management network | verification module AzlVerification.Network | no | azl-toolkit phase-03-os-configuration task-04 Disable-DHCPOnAllAdapters.ps1 (Remote NDIS keeps DHCP); lab finding |
| NW-009 | Intent adapters use the OEM driver, not the inbox Microsoft driver | verification module AzlVerification.Network | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Decision 6); https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610) |
| NW-010 | No Network ATC intent and no stray virtual switch left from an earlier attempt | verification module AzlVerification.Network | yes | config/known-issues/arm-deployment.json (vmswitch-not-bound); [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610) |
| NW-011 | Unused adapters that are disconnected are disabled | verification module AzlVerification.Network | no | azl-toolkit phase-03-os-configuration task-09 Disable-UnusedAdapters.ps1 / task-13 Task09_Adapters |
| NW-012 | Jumbo frames only for storage, the same MTU setting for an adapter on all nodes | verification module AzlVerification.Network | no | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Decision 6: Jumbo Packets)) |
| NW-013 | Physical ports against the file, per node: every used port of the file is a real NIC (found by MAC), Up, at speed, not virtual, with one OS name on every node; intents and storage networks point at them | verification module AzlVerification.Network | yes | [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610; https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (Decision 6, 7); the file: nodes[].network_adapters, networking.intents[].adapters, networking.cluster_networks[]) |
| NW-014 | Storage adapters are bare: no VLAN ID on the NIC, no manual or DHCP IPv4 address, no default gateway, no duplicate adapter names on the node | verification module AzlVerification.Network | yes | [Learn: concepts/host-network-requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610; Azure ARM Validate step AzureLocal_Network_Test_StorageAdapterReadiness (lab failure: 'Adapter has the following VLANID configured: [ 712 ]')) |
| NW-015 | The VLAN plan of the file: unique VLANs and subnets, management and storage VLANs consistent with the ports, compute VLANs allowed on the compute ports, addresses inside the management subnet | verification module AzlVerification.Network | yes | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610 (VLAN and subnet planning, Decision 6, 7); https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements?view=azloc-2610; the file: networking.vlans[], networking.management, networking.storage.networks[], nodes[].network_adapters[].vlan_id, vlan_mode, allowed_vlans (the lab VLAN inventory is the human source, the file the authority)) |
| NW-016 | Switch port checklist: what the file expects on each switch port (the gate cannot read a switch) | verification module AzlVerification.Network | no | [Learn: plan/cloud-deployment-network-considerations](https://learn.microsoft.com/en-us/azure/azure-local/plan/cloud-deployment-network-considerations?view=azloc-2610; the file: nodes[].network_adapters[].switch_port, vlan_id, vlan_mode, allowed_vlans, networking.vlans[]) |

### STORAGE

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| ST-001 | Storage Spaces Direct: at least two local data disks of the minimum size per node, the same number and size on every node | verification module AzlVerification.Storage | yes | [Learn: concepts/system-requirements-23h2](https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610 (Machine and storage requirements)) |
| ST-002 | Local data disks are eligible for Storage Spaces Direct: clean, poolable, no partitions (the boot device is excluded) | verification module AzlVerification.Storage | yes | [Learn: deploy/deployment-install-os](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os?view=azloc-2610 (Clean all the non-OS drives); azl-toolkit phase-03-os-configuration task-11 Clear-StorageConfiguration.ps1 / task-13 Task11_Storage; https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (hardware validator)) |
| ST-003 | No storage pool or virtual disk left on the nodes | verification module AzlVerification.Storage | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (hardware validator: No storage pools exist, Critical); azl-toolkit task-13 Task11_Storage) |
| ST-004 | Each SAN LUN is one disk: no Fibre Channel or iSCSI LUN is visible more than once (the Test-Cluster failure "Two disks ... cannot be distinguished") | verification module AzlVerification.Storage | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610 (Verify SAN disks); Azure Test-Cluster 'List Disks'; lab failure 2026-11-08 (Pure FlashArray, 2 LUNs x 4 paths = 8 disks)) |
| ST-005 | Multipath I/O (MultipathIO feature) is on wherever SAN LUNs are declared or visible | verification module AzlVerification.Storage | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610 (Step 1.1: Verify Multipath I/O); azl-toolkit phase-03-os-configuration MPIO task) |
| ST-006 | The array is claimed by MPIO: Get-MPIOAvailableHW shows IsMultipathed and the MSDSM supported hardware lists the vendor and product | verification module AzlVerification.Storage | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610 (Step 2.2: Register vendor device with MSDSM); config/san/msdsm-vendors.json) |
| ST-007 | mpclaim -s -d shows one MPIO disk per SAN LUN | verification module AzlVerification.Storage | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610 (Step 7: Verify SAN disks); azl-toolkit phase-03-os-configuration MPIO / SAN LUN tasks) |
| ST-008 | Hybrid: do not zone the Fibre Channel HBAs until after the deployment (LUNs must not be visible before it) | verification module AzlVerification.Storage | no | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610 (Fibre Channel prerequisites: Important)) |
| ST-009 | Every node sees the same SAN LUNs, with the same LUN IDs | verification module AzlVerification.Storage | yes | [Learn: deploy/enable-external-storage](https://learn.microsoft.com/en-us/azure/azure-local/deploy/enable-external-storage?view=azloc-2610 (consistent LUN IDs; Step 7)) |
| ST-010 | Disaggregated: the infrastructure LUN (250 GB) and the performance history LUN (20 GB) are visible on every node and still RAW | verification module AzlVerification.Storage | yes | [Learn: deploy/deployment-install-os-disaggregated](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610 (Prerequisites, Connect to SAN); https://learn.microsoft.com/en-us/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610) |
| ST-011 | Fibre Channel: the HBA ports of the file are present on the nodes | verification module AzlVerification.Storage | no | [Learn: deploy/deployment-install-os-disaggregated](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-install-os-disaggregated?view=azloc-2610 (Connect to SAN, Fibre Channel)) |

### READINESS

| Id | Check | Reads | Blocking | Source |
| --- | --- | --- | --- | --- |
| RD-001 | The Environment Checker module (AzStackHci.EnvironmentChecker) is installed on every node | verification module AzlVerification.Nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (Install Environment Checker); https://azurelocal.cloud/docs/implementation/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness) |
| RD-002 | Environment Checker, connectivity validator: outbound connectivity to the Azure endpoints (Invoke-AzStackHciConnectivityValidation) | verification module AzlVerification.Nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (Connectivity validator); https://azurelocal.cloud/docs/implementation/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness) |
| RD-003 | Environment Checker, hardware validator: processors, memory, adapters, disks, no storage pool, Secure Boot, TPM 2.0 (Invoke-AzStackHciHardwareValidation) | verification module AzlVerification.Nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (Hardware validator); https://azurelocal.cloud/docs/implementation/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness) |
| RD-004 | Environment Checker, software validator: same NTP, same OS version, resolvable local Administrators (Invoke-AzStackHciSoftwareValidation -Exclude Test-IsNotPartofDomain) | verification module AzlVerification.Nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (Software validator); https://azurelocal.cloud/docs/implementation/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness) |
| RD-005 | Environment Checker, network validator: IP ranges free, adapters, storage connection (Invoke-AzStackHciNetworkValidation) | verification module AzlVerification.Nodes | yes | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (Network validator); https://azurelocal.cloud/docs/implementation/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness) |
| RD-006 | Environment Checker, Active Directory validator (Invoke-AzStackHciExternalActiveDirectoryValidation) | verification module AzlVerification.Nodes | no | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (ActiveDirectory validator); https://azurelocal.cloud/docs/implementation/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness) |
| RD-007 | Environment Checker, Arc integration validator: no name clash, region valid, resource and role assignment limits (Invoke-AzStackHciArcIntegrationValidation) | verification module AzlVerification.Nodes | no | [Learn: manage/use-environment-checker](https://learn.microsoft.com/en-us/azure/azure-local/manage/use-environment-checker?view=azloc-2610 (ArcIntegration validator); https://azurelocal.cloud/docs/implementation/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness) |
