# Variables final audit: tasks left in the scripts

**Registry version:** 5.0.13 (infrastructure schema 5.6.3). The registry (`config/variables/schema/master-registry.yaml`) is master;
this page lists what the scripts must change to follow it. Nothing below is a registry task: the registry already says what is true.

## 1. Logical networks: the creation task reads other key names than the registry

`scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-08-logical-network-creation/powershell/Invoke-LogicalNetworks-Orchestrated.ps1`
reads `networking.logical_networks[]`, but with the names of the 4.0 form (`networking.onprem.logical_networks[]`). Evidence that the registry is the truth:

- the schema of `infrastructure.yml` (generated from the registry) and the worked examples use `gateway` and `ip_pool`; a file with `default_gateway`
  or `ip_pools` is rejected as an unknown key;
- the other readers of the list (`AzlVerification.Network.psm1`, `AzlInfrastructure.psm1`, `AzlRemotingProfile.psm1`) read `name`, `vlan_id`,
  `address_prefix` and `purpose`, which the script and the registry share;
- `az stack-hci-vm network lnet create` takes one pool (`--ip-pool-start`, `--ip-pool-end`), so one `ip_pool` is the right shape; the script itself only
  uses the first entry of `ip_pools`.

| The script reads | The registry key | Change in the script |
| --- | --- | --- |
| `default_gateway` | `gateway` | read `gateway`; no gateway still means `--no-gateway` |
| `ip_pools[0].start`, `.end`, `.type` | `ip_pool.start`, `ip_pool.end` | read `ip_pool`; the pool type stays `vm` |
| `enabled`, `ip_allocation_method`, `nsg_name` | the same (registered in 5.0.13, since 5.6.3) | none |

Also: the script header says "Task 07" and its log folder `task-07-logical-network-creation`, while the folder is `task-08`.

## 2. The `deployment` block of the file accepts more keys than the registry lists

`Get-AzlArmRunSetting` (`scripts/common/arm-deployment/AzlArmDeploymentRun.psm1`) applies **every** key of the `deployment` block of the file
(snake_case turned into camelCase), so `poll_factor`, `transient_error_limit`, `revalidate`, `allow_revalidate`, `install_environment_checker`,
`keep_environment_checker`, `require_validated_parameter_hash`, `os_report_max_age_hours`, `stale_skew_minutes` and `known_issues_file` are accepted
by the code. The registry (and so the schema, which has `additionalProperties: false` on `deployment`) lists them as `-Settings` / `-ConfigPath`
only. Change the function to apply only the keys the registry lists for the file (20), and keep the rest for `-Settings` and `-ConfigPath`.
(`skip_pre_cluster_verification` is already refused from a file.)

## 3. `Invoke-HardwareDiscovery.ps1`: certificate switch is never passed on

Line 158 passes `-VerifyCertificate:$Shared.Verify`, but the shared object (line 153) holds `VerifyCertificate`. Under `Set-StrictMode -Version Latest`
this reads a property that does not exist. Use `$Shared.VerifyCertificate`.

## 4. Scripts that still declare `#Requires -Version 5.1`

HCS scripting standard: PowerShell 7. Node-side payload strings legitimately run in Windows PowerShell 5.1 and are not in this list (no `.psm1`
payload declares a version in its here-string). These 25 files declare 5.1 on line 1. Do **not** edit them in a mass change: move each to 7 together
with its task, and keep a payload (a script copied to a node and run there) separate.

Orchestrators (run on the jump server or in a pipeline: must be 7):

- phase-03-os-configuration: `Invoke-DisableDHCP-Orchestrated.ps1`, `Invoke-ConfigureDNS-Orchestrated.ps1`, `Invoke-DisableAdapters-Orchestrated.ps1`,
  `Invoke-ConfigureHostname-Orchestrated.ps1`, `Invoke-ClearStorage-Orchestrated.ps1`, `Invoke-Phase03OsConfiguration-Orchestrated.ps1`,
  `Start-Phase03OsConfiguration.ps1`, `Invoke-Phase03Verification-Orchestrated.ps1`
- phase-04-arc-registration: `Invoke-ArcPrerequisites-Orchestrated.ps1`, `Invoke-ArcRegistration-Orchestrated.ps1`, `Start-ArcRegistrationWithMonitor.ps1`,
  `Invoke-BootstrapMonitor-Orchestrated.ps1`, `Invoke-ArcVerification-Orchestrated.ps1`
- phase-06-post-deployment: `Invoke-VerifyPostDeployment.ps1`

Task scripts that run on a node or on the jump server (decide per script; a node-side script copied to a machine without PowerShell 7 stays 5.1):

- phase-03-os-configuration: `Enable-RDP.ps1`, `Set-StaticIPAddress.ps1`, `Disable-DHCPOnAllAdapters.ps1`, `Set-DnsServers.ps1`
- phase-06-post-deployment: `Invoke-SSHConnectivity-Standalone.ps1`, `New-StorageCSV-Standalone.ps1`, `New-StoragePaths-Standalone.ps1`,
  `Set-StorageVolumesConfig.ps1`, `New-MarketplaceImages-Standalone.ps1`, `New-LogicalNetworks-Standalone.ps1`, `Test-PostDeployment-Standalone.ps1`

## 5. Tool parameters that are not registered

`Test-ToolParameterRegistration.ps1 -ReportUnregisteredScripts` reports no registry group for the older foundation scripts of
`phase-03-os-configuration` (`az-*.ps1`, `*-Orchestrated.ps1`, `Test-DnsConfiguration.ps1`, ...), `phase-05-cluster-deployment`
(`Deploy-AzureLocalCluster*.ps1`, `Invoke-Verify*-Orchestrated.ps1`, `Monitor-*.ps1`, `Test-ADDomainStatus*.ps1`, ...) and
`phase-01-hardware-provisioning/.../az-discover-hardware.ps1`. The main entry scripts are registered: `Invoke-AzureLocalArmDeployment.ps1`,
`Invoke-AzureLocalPreClusterVerification.ps1`, `Set-AzureLocalNodeConfiguration.ps1`, `Invoke-HardwareDiscovery.ps1` (three parameters added in
5.0.13), `Start-AzlSonar.ps1` and the azurelocal-ztp scripts. Register the foundation scripts' parameters when they are brought under the standard.
