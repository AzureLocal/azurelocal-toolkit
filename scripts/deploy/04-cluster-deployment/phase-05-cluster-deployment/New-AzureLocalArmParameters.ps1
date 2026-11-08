#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the full ARM parameter file for Microsoft's Azure Local quickstart template from infrastructure.yml (schema 5).

.DESCRIPTION
    Picks the template for the design (Active Directory or local identity, Storage Spaces Direct or a Fibre Channel SAN, rack
    aware), fills every parameter it declares, and checks the result against the template's parameter list. Reads only
    files: no Azure call. No secret goes into the file: the local administrator's and the LCM user's passwords are null
    (the deployment script reads them from Key Vault into memory) or, with -SecretMode KeyVaultReference, Key Vault references.

    What feeds each part:
      identity, cluster name, witness, Key Vault, diagnostics, intents, storage networks, infrastructure pool, security,
      custom location                 infrastructure.yml
      SBE values                      hardware.sbe, only when it has a version (the SBE is opt-in; without one none of the seven
                                      SBE parameters is written and the template defaults apply). hardware.sbe.bundle_path fills the
                                      values hardware.sbe leaves empty.
      arcNodeResourceIds              the ZTP handoff (schema 2), else the Arc machine name in azure.resource_group
      adapter names                   infrastructure.yml's port names translated to the OS names by MAC, from the OS
                                      configuration report (-NodeReportPath)
      SAN                             sanNetworkList from networking.cluster_networks; infraVolLunId and infraPerfLunId from
                                      storage.san, a LUN number translated to the disk's UniqueId by the same report

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2), for the Arc machine resource IDs.
.PARAMETER NodeReportPath
    The JSON report of Set-AzureLocalNodeConfiguration: OS port names by MAC and the SAN disks by LUN.
.PARAMETER Mode
    Validate (default) or Deploy: the file's deploymentMode. Default: cluster.deployment_mode.
.PARAMETER OutputPath
    Where to write the parameter file. Default: the temp folder. Keep it out of the repository.
.PARAMETER SecretMode
    Placeholder (secrets null; the deployment fills them) or KeyVaultReference.
.EXAMPLE
    ./New-AzureLocalArmParameters.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath ./osconfig-report.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string]$NodeReportPath,
    [ValidateSet('Validate', 'Deploy')][string]$Mode,
    [string]$OutputPath,
    [ValidateSet('Placeholder', 'KeyVaultReference')][string]$SecretMode = 'Placeholder',
    [string]$HciResourceProviderObjectId,
    [ValidateSet('UniqueId', 'SerialNumber')][string]$SanLunIdSource = 'UniqueId',
    [string]$TemplateFile,
    [switch]$OfflineManifest,
    [switch]$SkipValidation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common')
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'azure-local', 'AzlAzure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'node-configuration', 'AzlNodeConfiguration.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'arm-deployment', 'AzlArmDeployment.psm1')) -Force

$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation:$SkipValidation
$handoff = if ($HandoffFile) { Read-AzlHandoff -Path $HandoffFile } else { $null }
$report = if ($NodeReportPath) { Get-Content -LiteralPath $NodeReportPath -Raw | ConvertFrom-Json -Depth 20 } else { $null }

$sbe = $null
$bundlePath = Get-AzlProp $infra 'hardware.sbe.bundle_path'
if ($bundlePath -and (Test-Path -LiteralPath $bundlePath -PathType Container)) {
    $oem = Get-AzlOemConfig -Vendor ([string](Get-AzlProp $infra 'hardware.vendor' 'Dell'))
    $sbe = (Get-AzlSbeBundle -Path $bundlePath -ManifestUrl ([string]$oem.sbe.discoveryManifestUrl) -OfflineManifest:$OfflineManifest).Deployment
}

$arguments = @{ Infrastructure = $infra; Handoff = $handoff; SanLunIdSource = $SanLunIdSource; AllowUnresolvedSanLun = $true }
if ($Mode) { $arguments.Mode = $Mode }
if ($HciResourceProviderObjectId) { $arguments.HciResourceProviderObjectId = $HciResourceProviderObjectId }
if ($sbe) { $arguments.SbeDeployment = $sbe }
if ($report) { $arguments.AdapterMap = Get-AzlAdapterMapFromReport -Report $report; $arguments.NodeReport = @($report.nodes) }
$set = New-AzlArmParameterSet @arguments

$definitions = if ($TemplateFile) { Get-AzlTemplateParameterDefinition -Template (Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json -Depth 100) } else { (Get-AzlArmTemplateCatalog).templates[$set.Template.Name].parameters }
$problems = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions)

if (-not $OutputPath) { $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ("azl-arm-{0}-{1}.parameters.json" -f (Get-AzlProp $infra 'cluster.name' 'cluster'), $set.Parameters['deploymentMode'].ToLowerInvariant()) }
$folder = Split-Path -Parent $OutputPath
if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
ConvertTo-AzlArmParameterFile -ParameterSet $set -Infrastructure $infra -SecretMode $SecretMode | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM

Write-Information -InformationAction Continue -MessageData "Template:   $($set.Template.Name)"
Write-Information -InformationAction Continue -MessageData "Parameters: $($set.Parameters.Count) written to $OutputPath ($SecretMode secrets, no secret value in the file)"
Write-Information -InformationAction Continue -MessageData "deploymentSettings api-version in that template: $($set.DeploymentSettingsApiVersion)"
$sbeNote = if ($set.Parameters.Contains('sbeVersion') -and $set.Parameters['sbeVersion']) { "SBE $($set.Parameters['sbeFamily']) $($set.Parameters['sbeVersion'])" } else { 'no SBE configured (no SBE parameter written)' }
Write-Information -InformationAction Continue -MessageData "SBE:        $sbeNote"
foreach ($w in $set.Warnings) { Write-Warning $w }
foreach ($p in $problems) { Write-Warning "PROBLEM: $p" }
if ($problems.Count) { Write-Error "$($problems.Count) problem(s) in the parameter set." -ErrorAction Continue; exit 1 }
[pscustomobject]@{ Template = $set.Template.Name; OutputPath = $OutputPath; ParameterCount = $set.Parameters.Count; Warnings = $set.Warnings }
