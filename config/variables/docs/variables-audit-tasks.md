# Variables final audit: tasks left in the scripts

**Registry version:** 5.0.13 (infrastructure schema 5.6.3). The registry (`config/variables/schema/master-registry.yaml`) is master;
this page lists what the scripts must change to follow it. Nothing below is a registry task: the registry already says what is true.

## 1. The `deployment` block of the file accepts more keys than the registry lists

`Get-AzlArmRunSetting` (`scripts/common/arm-deployment/AzlArmDeploymentRun.psm1`) applies **every** key of the `deployment` block of the file
(snake_case turned into camelCase), so `poll_factor`, `transient_error_limit`, `revalidate`, `allow_revalidate`, `install_environment_checker`,
`keep_environment_checker`, `require_validated_parameter_hash`, `os_report_max_age_hours`, `stale_skew_minutes` and `known_issues_file` are accepted
by the code. The registry (and so the schema, which has `additionalProperties: false` on `deployment`) lists them as `-Settings` / `-SettingsFile`
only. Change the function to apply only the keys the registry lists for the file (20), and keep the rest for `-Settings` and `-SettingsFile`.
(`skip_pre_cluster_verification` is already refused from a file.)

## 2. `Invoke-HardwareDiscovery.ps1`: certificate switch is never passed on

Line 158 passes `-VerifyCertificate:$Shared.Verify`, but the shared object (line 153) holds `VerifyCertificate`. Under `Set-StrictMode -Version Latest`
this reads a property that does not exist. Use `$Shared.VerifyCertificate`.

## 3. Scripts that still declare `#Requires -Version 5.1`

HCS scripting standard: PowerShell 7. Node-side payload strings legitimately run in Windows PowerShell 5.1 and are not in this list (no `.psm1`
payload declares a version in its here-string). The files below declare 5.1. Do **not** edit them in a mass change: move each to 7 together
with its task, and keep a payload (a script copied to a node and run there) separate.

Orchestrators (run on the jump server or in a pipeline: must be 7):

- phase-03-os-configuration and phase-04-arc-registration: done in registry 5.0.57. The `Invoke-*-Orchestrated.ps1` scripts of both phases are placeholders now (PowerShell 7, exit code 3) and their work is done by `Set-AzureLocalNodeConfiguration.ps1` and `Invoke-AzureLocalOsConfiguration.ps1`.
- phase-06-post-deployment: none left (`Invoke-VerifyPostDeployment.ps1` is PowerShell 7)

Task scripts that run on a node or on the jump server (decide per script; a node-side script copied to a machine without PowerShell 7 stays 5.1):

- phase-03-os-configuration: none left (the node scripts are removed; the RemoteManagement and Network steps of `Set-AzureLocalNodeConfiguration.ps1` do their work).
- phase-06-post-deployment: none left (the Standalone scripts are removed)

## 4. Tool parameters that are not registered

`Test-ToolParameterRegistration.ps1 -ReportUnregisteredScripts` reports no registry group for the older foundation scripts of
`phase-03-os-configuration` (`az-*.ps1`, `*-Orchestrated.ps1`, `Test-DnsConfiguration.ps1`, ...), `phase-05-cluster-deployment`
(`Deploy-AzureLocalCluster*.ps1`, `Invoke-Verify*-Orchestrated.ps1`, `Monitor-*.ps1`, `Test-ADDomainStatus.ps1`, ...) and
`phase-01-hardware-provisioning/.../az-discover-hardware.ps1`. The main entry scripts are registered: `Invoke-AzureLocalArmDeployment.ps1`,
`Invoke-AzureLocalPreClusterVerification.ps1`, `Set-AzureLocalNodeConfiguration.ps1`, `Invoke-HardwareDiscovery.ps1` (three parameters added in
5.0.13), `Start-AzlSonar.ps1` and the azurelocal-ztp scripts. Register the foundation scripts' parameters when they are brought under the standard.
