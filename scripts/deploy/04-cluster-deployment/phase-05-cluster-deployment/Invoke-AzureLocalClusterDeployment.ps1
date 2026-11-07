#Requires -Version 7.0
<#
.SYNOPSIS
    ARM Validate, then Deploy, of an Azure Local instance from infrastructure.yml (schema 5).

.DESCRIPTION
    Without -Execute this is a plan: it generates the full parameter set (New-AzureLocalArmParameters.ps1's logic), checks it
    against the template's parameter list, writes the parameter file, and prints what it would submit. It reads files only,
    unless -Preflight, which adds read-only Azure checks (the resource group, each Arc machine Connected, the instance's current
    deployment state).

    -Execute -Mode Validate   submits the template with deploymentMode Validate, waits (about 10 to 30 minutes), and reports every
                              validation step with its status and errors.
    -Execute -Mode Deploy     the real deployment. A separate, explicit run. It needs a Validate that succeeded (the cluster's
                              deploymentSettings reports validation Succeeded) unless -SkipValidationCheck. It takes 2.5 to 3 hours.

    Microsoft's rules, enforced: Validate is refused when the instance is in a failed deployment state (a second Validate resets
    the system properties and can break license sync); the deployment's local administrator is not the built-in Administrator.

    The secrets (identity.local_admin and the LCM user's passwords, as keyvault:// references) are read from Key Vault into
    memory and sent as secure parameters. They are never written to the parameter file or the result.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2): the Arc machine resource IDs.
.PARAMETER NodeReportPath
    The JSON report of Set-AzureLocalNodeConfiguration: port names by MAC, SAN disks by LUN.
.PARAMETER Mode
    Validate (default) or Deploy.
.PARAMETER TemplateFile
    A local copy of the quickstart template, instead of downloading it from GitHub.
.PARAMETER DeploymentSettingsApiVersion
    Patch the template's deploymentSettings api-version (for example 2026-10-01). Microsoft's own template decides the default.
.PARAMETER OutputFolder
    Where the parameter file and the result JSON go. Default: the temp folder. Keep it out of the repository.
.PARAMETER Execute
    Submit to Azure. Without it nothing is created.
.EXAMPLE
    ./Invoke-AzureLocalClusterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath ./osconfig-report.json
.EXAMPLE
    ./Invoke-AzureLocalClusterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath ./osconfig-report.json -Mode Validate -Execute
.EXAMPLE
    ./Invoke-AzureLocalClusterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath ./osconfig-report.json -Mode Deploy -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string]$NodeReportPath,
    [ValidateSet('Validate', 'Deploy')][string]$Mode = 'Validate',
    [string]$TemplateFile,
    [string]$DeploymentSettingsApiVersion,
    [string]$OutputFolder,
    [ValidateSet('UniqueId', 'SerialNumber')][string]$SanLunIdSource = 'UniqueId',
    [string]$HciResourceProviderObjectId,
    [int]$TimeoutMinutes,
    [switch]$Preflight,
    [switch]$NoWait,
    [switch]$AllowRevalidate,
    [switch]$SkipValidationCheck,
    [switch]$OfflineManifest,
    [switch]$SkipValidation,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot '..\..\..\common'
Import-Module (Join-Path $common 'infrastructure\AzlInfrastructure.psm1') -Force
Import-Module (Join-Path $common 'azure-local\AzlAzure.psm1') -Force
Import-Module (Join-Path $common 'node-configuration\AzlNodeConfiguration.psm1') -Force
Import-Module (Join-Path $common 'arm-deployment\AzlArmDeployment.psm1') -Force

function Write-Line([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }

$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation:$SkipValidation
$handoff = if ($HandoffFile) { Read-AzlHandoff -Path $HandoffFile } else { $null }
$report = if ($NodeReportPath) { Get-Content -LiteralPath $NodeReportPath -Raw | ConvertFrom-Json -Depth 20 } else { $null }
$subscription = [string](Get-AzlProp $infra 'azure.subscription_id')
$resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group')
$clusterName = [string](Get-AzlProp $infra 'cluster.name')

$sbe = $null
$bundlePath = Get-AzlProp $infra 'hardware.sbe.bundle_path'
if ($bundlePath -and (Test-Path -LiteralPath $bundlePath -PathType Container)) {
    $oem = Get-AzlOemConfig -Vendor ([string](Get-AzlProp $infra 'hardware.vendor' 'Dell'))
    $sbe = (Get-AzlSbeBundle -Path $bundlePath -ManifestUrl ([string]$oem.sbe.discoveryManifestUrl) -OfflineManifest:$OfflineManifest).Deployment
}

if ($Execute) {
    if (-not (Get-AzContext)) { throw 'Not signed in to Azure. Run Connect-AzAccount.' }
    if ((Get-AzContext).Subscription.Id -ne $subscription) { $null = Set-AzContext -Subscription $subscription }
    if (-not $HciResourceProviderObjectId -and -not (Get-AzlProp $infra 'azure.hci_resource_provider_object_id')) { $HciResourceProviderObjectId = Get-AzlHciResourceProviderObjectId }
}

$arguments = @{ Infrastructure = $infra; Handoff = $handoff; Mode = $Mode; SanLunIdSource = $SanLunIdSource; AllowUnresolvedSanLun = (-not $Execute) }
if ($HciResourceProviderObjectId) { $arguments.HciResourceProviderObjectId = $HciResourceProviderObjectId }
if ($sbe) { $arguments.SbeDeployment = $sbe }
if ($report) { $arguments.AdapterMap = Get-AzlAdapterMapFromReport -Report $report; $arguments.NodeReport = @($report.nodes) }
$set = New-AzlArmParameterSet @arguments

# ---- the template: a local file, or Microsoft's, downloaded when executing
$template = $null
if ($TemplateFile) { $template = Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json -Depth 100 }
elseif ($Execute) { $template = Invoke-RestMethod -Uri $set.Template.Uri }
$definitions = if ($template) { Get-AzlTemplateParameterDefinition -Template $template } else { (Get-AzlArmTemplateCatalog).templates[$set.Template.Name].parameters }
$problems = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions)

if (-not $OutputFolder) { $OutputFolder = Join-Path ([IO.Path]::GetTempPath()) 'azl-arm' }
$null = New-Item -ItemType Directory -Path $OutputFolder -Force
$parameterFile = Join-Path $OutputFolder "$clusterName.$($Mode.ToLowerInvariant()).parameters.json"
ConvertTo-AzlArmParameterFile -ParameterSet $set -Infrastructure $infra | Set-Content -LiteralPath $parameterFile -Encoding utf8NoBOM

Write-Line "Instance:   $clusterName in $resourceGroup"
Write-Line "Template:   $($set.Template.Name) ($($set.Template.Uri))"
Write-Line "Mode:       $Mode$(if ($Execute) { '  EXECUTE: this submits to Azure' } else { '  (plan: nothing is submitted)' })"
Write-Line "Parameters: $($set.Parameters.Count), written to $parameterFile (secrets are null in the file)"
Write-Line "deploymentSettings api-version in the template: $($set.DeploymentSettingsApiVersion)$(if ($DeploymentSettingsApiVersion) { " -> patched to $DeploymentSettingsApiVersion" })"
$summary = foreach ($k in $set.Parameters.Keys) {
    $v = $set.Parameters[$k]
    [pscustomobject]@{ Parameter = $k; Value = $(if ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) { "secret $($v.KeyVault)" } elseif ($v -is [string]) { $v } else { ($v | ConvertTo-Json -Depth 6 -Compress) }) }
}
Write-Line (($summary | Format-Table -Wrap -AutoSize | Out-String -Width 200))
foreach ($w in $set.Warnings) { Write-Warning $w }
foreach ($p in $problems) { Write-Warning "PROBLEM: $p" }
if ($problems.Count) { throw "$($problems.Count) problem(s) in the parameter set; nothing was submitted." }

# ---- read-only checks of Azure
if ($Execute -or $Preflight) {
    if (-not (Get-AzContext)) { throw 'Not signed in to Azure. Run Connect-AzAccount.' }
    $null = Invoke-AzlArm -Method GET -Path "/subscriptions/$subscription/resourceGroups/$resourceGroup" -ApiVersion '2024-03-01'
    foreach ($id in $set.Parameters['arcNodeResourceIds']) {
        $m = Find-AzlArcMachine -ArcMachineName ($id.Split('/')[-1]) -SubscriptionId $subscription -ResourceGroup $resourceGroup -ResourceId $id
        if (-not $m) { throw "Arc machine not found: $id" }
        if ($m.Status -ne 'Connected') { throw "Arc machine $($m.Name) is '$($m.Status)', not Connected." }
        Write-Line "Arc machine $($m.Name): Connected"
    }
    $state = Get-AzlDeploymentState -SubscriptionId $subscription -ResourceGroup $resourceGroup -ClusterName $clusterName
    Write-Line "Instance now: $(if ($state) { "provisioning $($state.ProvisioningState), validation '$($state.ValidationStatus)', deployment '$($state.DeploymentStatus)'" } else { 'no cluster resource yet' })"
}

if (-not $Execute) {
    Write-Line "Plan only. To submit: add -Execute (Mode $Mode)."
    return [pscustomobject]@{ Mode = $Mode; Template = $set.Template.Name; ParameterFile = $parameterFile; ParameterCount = $set.Parameters.Count; Submitted = $false }
}

$arguments = @{ ParameterSet = $set; Template = $template; SubscriptionId = $subscription; ResourceGroup = $resourceGroup; Mode = $Mode; NoWait = $NoWait; AllowRevalidate = $AllowRevalidate; SkipValidationCheck = $SkipValidationCheck }
if ($DeploymentSettingsApiVersion) { $arguments.DeploymentSettingsApiVersion = $DeploymentSettingsApiVersion }
if ($TimeoutMinutes) { $arguments.TimeoutMinutes = $TimeoutMinutes }
$result = Invoke-AzlArmDeployment @arguments

Write-Line "Deployment $($result.DeploymentName): $($result.ProvisioningState)"
if ($result.ValidationStatus) { Write-Line "Validation status: $($result.ValidationStatus)" }
if ($result.ValidationSteps) { Write-Line (($result.ValidationSteps | Format-Table @{ n = 'Step'; e = { ('  ' * $_.Depth) + $_.Name } }, Status, Description -Wrap | Out-String -Width 200)) }
foreach ($f in $result.FailedSteps) { Write-Warning "FAILED: $($f.Name): $($f.Errors -join ' | ')" }
if ($result.Error) { Write-Warning "ARM error: $($result.Error)" }
$resultFile = Join-Path $OutputFolder "$clusterName.$($Mode.ToLowerInvariant()).result.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding utf8NoBOM
Write-Line "Result: $resultFile"
if ($result.ProvisioningState -ne 'Succeeded' -or $result.FailedSteps.Count) {
    Write-Line "$Mode did not succeed. Do not run Validate again after a failed deployment (Microsoft); read the failed steps above."
    exit 1
}
if ($Mode -eq 'Validate') { Write-Line 'Validation succeeded. Review it, then run the deployment as a separate step: -Mode Deploy -Execute.' }
$result
