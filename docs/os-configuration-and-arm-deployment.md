# OS configuration and ARM Validate/Deploy: prerequisites and run guide

This page covers the two steps that run after azurelocal-ztp (or an ISO install) has handed off provisioned machines:

1. **OS configuration** (Phase 03): `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Set-AzureLocalNodeConfiguration.ps1`
2. **ARM Validate, then Deploy** (Phase 05): `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalClusterDeployment.ps1`, with `New-AzureLocalArmParameters.ps1` for the parameter file alone.

Both read the one environment file, `infrastructure.yml` (schema 5). This page doesn't repeat what each key means: see the [schema-wide variables reference](infrastructure-variables.md) and `config/infrastructure/README.md`. What it adds is what must be true before you run, and which of it the code checks.

In the tables, **Checked** says what happens if the item is missing:

- **Code**: the script checks it and stops (or blocks the node) with a message.
- **Azure**: the script doesn't check it, but the Azure call fails and the script reports Azure's error.
- **You**: nothing checks it. You make it true before the run.

## What runs where

| Step | Command (plan: reads, changes nothing) | Add `-Execute` to |
| --- | --- | --- |
| OS configuration | `Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json` | change the nodes. Re-running on a configured node changes nothing. |
| ARM parameters only | `New-AzureLocalArmParameters.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath <report>` | (reads files only; always safe) |
| ARM Validate | `Invoke-AzureLocalClusterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath <report>` | submit `deploymentMode Validate` to the resource group, wait, report the validation steps. |
| ARM Deploy | the same with `-Mode Deploy` | submit the real deployment. A separate, explicit run; needs a successful Validate. |

The OS configuration plan reads each node through Azure Arc Run Command, which creates and deletes one transient `runCommands` resource per read; nothing on the node changes. `-SpecOnly` reads no node and no Azure resource: it prints what each node should look like. The ARM plan (no `-Execute`) reads files only, unless you add `-Preflight`.

Order: ZTP hand-off, OS configuration with `-Execute` (it writes a JSON report), then ARM Validate, review, then ARM Deploy.

## Operator host

| Tool | Version tested | Needed for | Checked |
| --- | --- | --- | --- |
| PowerShell | 7.4 or later (tested on 7.6) | everything; the scripts say `#Requires -Version 7.0` | Code |
| powershell-yaml | 0.4.12 | reading `infrastructure.yml` | Code |
| Az.Accounts | 5.5 | every Azure call (`Invoke-AzRestMethod`); `Connect-AzAccount` first | Code (stops if not signed in) |
| Az.KeyVault | 6.6 | reading the `keyvault://` secrets | Azure |
| Az.Resources | 10.2 | looking up the Azure Local resource provider's object ID (`Get-AzADServicePrincipal`), only if `azure.hci_resource_provider_object_id` is empty | Azure |
| Az.Storage | 9.7 | staging the SBE package to nodes over Arc (`-StagingStorageAccount`) | Azure |
| Pester 5.9.1 | 5.9.1 | running the tests only. Import it explicitly (`Import-Module Pester -RequiredVersion 5.9.1`): Pester 6 runs zero tests here | You |
| PSScriptAnalyzer | 1.25 | linting only | You |

Network from the operator host: HTTPS to `management.azure.com`, `login.microsoftonline.com`, `*.vault.azure.net`, and (ARM execute only) `raw.githubusercontent.com` for Microsoft's quickstart template; `aka.ms` for the OEM's SBE manifest (skip with `-OfflineManifest`). **No path to the nodes' management subnet is needed**: the Arc transport reaches the nodes through Azure. `-Transport WinRM` is for a host that does have one.

The Azure CLI is not used.

## Azure roles

| Who | Role | Scope | Why | Checked |
| --- | --- | --- | --- | --- |
| Operator running OS configuration (Arc transport) | `Azure Connected Machine Resource Administrator` (includes `Microsoft.HybridCompute/machines/runCommands/write`) | the Arc machines' resource group | create, read and delete the Run Command that carries each node script | Azure |
| same | `Reader` | the Arc machines' resource group | find machines by name, read their status | Azure |
| same, only when a node doesn't hold the SBE yet | `Storage Blob Data Contributor` and `Storage Blob Delegator` | the staging storage account | upload the SBE package and issue a read-only SAS the node downloads from | Azure |
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
| A dedicated OU, not at the top of the domain | `identity.active_directory.ou_path`, for example `OU=iic-clus01,OU=AzureLocal,DC=improbability,DC=cloud` | You (the schema checks the form) |
| The LCM user, in that OU | `lcm_user.username`: the name only, no domain, **20 characters or fewer** | Code (length), You (the account) |
| Microsoft's pre-creation tool | `Install-Module AsHciADArtifactsPreCreationTool`, then `New-HciAdObjectsPreCreation` with the LCM credential and the OU. It creates the OU's objects and the LCM user and sets the delegation. See [Prepare Active Directory](https://learn.microsoft.com/azure/azure-local/deploy/deployment-prep-active-directory) | You |
| Names | cluster name up to 15 characters and not a node name; node names up to 15 characters; `naming_prefix` is the prefix of the objects the deployment creates | Code |
| DNS resolves the domain from the nodes | the management DNS servers (`networking.management.dns_servers`) resolve AD, including the domain controllers' SRV records. **They can't change after deployment.** OS configuration sets them on the management port; it doesn't test that they resolve AD. | Code (sets), You (resolves) |
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
| It reaches `C:\SBE` on every node | WinRM: copied. Arc: uploaded to the staging storage account and downloaded by the node with a read-only SAS (`-StagingStorageAccount`). A node that already holds the right files needs neither | Code |
| ARM values | `sbeVersion`, `sbeFamily`, `sbePublisher`, `sbeManifestSource`, `sbeManifestCreationDate` come from `hardware.sbe.*`, else from the folder | Code |

Dell says the SBE can't install drivers or firmware during the deployment, which is why OS configuration installs the network drivers first.

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

`ztp-handoff.json`, written by azurelocal-ztp's `New-ZtpHandoff.ps1` when every machine is ready to cluster. **Schema 2** is required; an older file stops the run. It holds only what Azure generated, so addresses and MACs always come from `infrastructure.yml`. Keep it out of source control: it holds Azure resource IDs.

| Field read | Used for |
| --- | --- |
| `nodes[].arcMachineResourceId` | the Arc Run Command target; ARM `arcNodeResourceIds`. Without a handoff the Arc machine is found by `arc_machine_name` (default the node name) in `azure.resource_group` |
| `nodes[].managementAddressVerified`, `managementAddressReason` | shown next to the management-address change when ZTP couldn't verify it. The script always verifies by MAC itself |
| `solution.vsrVersion` | compared with `provisioning.os_version`; a difference is reported |
| `nodes[].name`, `arcMachineName` | matching the entry to the node |

The OS configuration's own **report** (`-ReportPath`, JSON, no secrets) feeds the ARM step: the OS adapter names by MAC (Network ATC needs the real names, `Port0` to `Port6`, the same on every node) and the SAN disks by LUN.

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
| `identity.active_directory.lcm_user.username`, `.password` | if AD | `lcm-iic-clus01`, `keyvault://.../lcm-password` | the pre-creation tool | ARM |
| `identity.local_identity.dns_server_config`, `.dns_zone`, `.dns_forwarders` | if local identity | `use_dns_server`, `improbability.cloud` | your DNS design | ARM `dnsServerConfig`, `dnsZones` |
| `storage.configuration_mode` | no (`express`; `infra_only` for SAN) | `infra_only` | your design | ARM `configurationMode` |
| `storage.san.type` | if SAN | `fibre_channel` | your SAN | OS, ARM (template) |
| `storage.san.array.vendor`, `.model` | if SAN | `Dell`, `PowerStore 1200T` | your SAN; picks the MSDSM entry | OS |
| `storage.san.infra_volume_lun_id`, `.performance_history_lun_id` | if disaggregated | `0`, `1` | the array | OS (verifies), ARM `infraVolLunId`, `infraPerfLunId` |
| `security.level`, `.drift_control`, `.credential_guard`, `.smb_signing`, `.smb_cluster_encryption`, `.bitlocker_boot_volume`, `.bitlocker_data_volumes`, `.wdac` | no (Microsoft's recommended) | `recommended` | your policy | ARM `securityLevel` and the flags |
| `security.telemetry.streaming_data`, `.episodic_data_upload`, `.eu_location` | no (true, true, false) | `true` | your policy | ARM |
| `provisioning.os_version` | no | `12.2610.1004.50` | the build you pinned | OS (compared with the handoff) |

Not in schema 5, so the scripts take a default or a parameter: the staging storage account for the SBE over Arc (`-StagingStorageAccount`), the SAN's MPIO and MSDSM values (`config/san/msdsm-vendors.json`), the OEM driver folders (`config/oem/<vendor>.json`), the `sanNetworkList` adapter properties (Microsoft's sample values), and the choice of UniqueId or serial number for the LUN identifiers (`-SanLunIdSource`).
