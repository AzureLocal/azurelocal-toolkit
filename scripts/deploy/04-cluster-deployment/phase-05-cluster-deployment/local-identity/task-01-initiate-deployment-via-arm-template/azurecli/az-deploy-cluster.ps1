<#
.SYNOPSIS
    az-deploy-cluster.ps1
    Validates or deploys an Azure Local cluster via ARM template using Azure CLI.

.DESCRIPTION
    Config-driven script (Option 3 — Azure CLI in PowerShell). Reads infrastructure.yml,
    calls Generate-AzureLocal-Parameters.ps1 to produce the parameters file, then executes
    az deployment group create against the Microsoft quickstart ARM template.

    infrastructure.yml paths used:
      azure_platform.azure_tenants[0].aztenant_subscription_id  - Subscription
      compute.azure_local.resource_group                        - Resource group
      cluster_arm_deployment.arm_mode                           - Validate or Deploy

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-discovers if not provided.

.PARAMETER AuthType
    AD or LocalIdentity.

.PARAMETER DeploymentMode
    Validate or Deploy. Overrides cluster_arm_deployment.arm_mode.

.PARAMETER ParametersFile
    Path to a pre-built parameters file. Skips generation when provided.

.EXAMPLE
    .\az-deploy-cluster.ps1 -ConfigPath .\configs\infrastructure.yml -AuthType LocalIdentity -DeploymentMode Validate

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Script Type:  Config-driven (Option 3 — Azure CLI in PowerShell)
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [ValidateSet("AD", "LocalIdentity")][string]$AuthType = "LocalIdentity",
    [ValidateSet("Validate", "Deploy")][string]$DeploymentMode = "Validate",
    [string]$ParametersFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$templateUri = "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json"

# --- Load config ---
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "Module 'powershell-yaml' is required. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop

if ($ConfigPath -eq "") {
    $candidates = Get-ChildItem -Path ".\configs" -Filter "infrastructure*.yml" -ErrorAction SilentlyContinue
    if ($candidates.Count -eq 0) { throw "No infrastructure*.yml found. Pass -ConfigPath." }
    $ConfigPath = $candidates[0].FullName
}

$yaml = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Yaml
$subscriptionId = $yaml.azure_platform.azure_tenants[0].aztenant_subscription_id   # azure_platform.azure_tenants[0].aztenant_subscription_id
$resourceGroup  = $yaml.compute.azure_local.resource_group                          # compute.azure_local.resource_group

Write-Host "Subscription:   $subscriptionId" -ForegroundColor Cyan
Write-Host "Resource Group: $resourceGroup" -ForegroundColor Cyan
Write-Host "Mode:           $DeploymentMode" -ForegroundColor Cyan

# --- Set subscription ---
az account set --subscription $subscriptionId

# --- Generate parameters if needed ---
if ($ParametersFile -ne "" -and (Test-Path $ParametersFile)) {
    $paramsPath = (Resolve-Path $ParametersFile).Path
}
else {
    $generatorScript = Join-Path (Get-Location).Path "configs\Generate-AzureLocal-Parameters.ps1"
    if (-not (Test-Path $generatorScript)) { throw "Generator not found: $generatorScript" }

    $authSuffix = if ($AuthType -eq "AD") { "ad" } else { "local-identity" }
    $paramsPath = Join-Path (Split-Path $ConfigPath) "azuredeploy.parameters.$authSuffix.generated.json"

    & $generatorScript -ConfigPath $ConfigPath -AuthType $AuthType -OutputPath $paramsPath
    if (-not (Test-Path $paramsPath)) { throw "Generation failed." }
}

# --- Set deploymentMode in parameters ---
$paramsJson = Get-Content -Path $paramsPath -Raw | ConvertFrom-Json
$paramsJson.parameters.deploymentMode.value = $DeploymentMode
$paramsJson | ConvertTo-Json -Depth 20 | Set-Content -Path $paramsPath -Encoding UTF8

# --- Deploy via Azure CLI ---
$deploymentName = "azl-$($DeploymentMode.ToLower())-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Deploying: $deploymentName" -ForegroundColor Cyan

az deployment group create `
    --name $deploymentName `
    --resource-group $resourceGroup `
    --template-uri $templateUri `
    --parameters "@$paramsPath" `
    --verbose

$exitCode = $LASTEXITCODE
if ($exitCode -eq 0) {
    Write-Host "$DeploymentMode succeeded." -ForegroundColor Green
    if ($DeploymentMode -eq "Validate") {
        Write-Host "Re-run with -DeploymentMode Deploy to deploy." -ForegroundColor Green
    }
}
else {
    Write-Host "$DeploymentMode failed (exit code $exitCode)." -ForegroundColor Red
}
