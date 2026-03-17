<#
.SYNOPSIS
    Deploy-AzureLocalCluster.ps1
    Validates or deploys an Azure Local cluster via ARM template using parameters
    generated from infrastructure.yml.

.DESCRIPTION
    Config-driven script (Option 2). Reads infrastructure.yml, calls
    Generate-AzureLocal-Parameters.ps1 to produce the parameters file, then executes
    New-AzResourceGroupDeployment against the Microsoft quickstart ARM template.

    Supports two modes:
      - Validate: Runs the full deployment pipeline but stops before provisioning.
                  Always run this first.
      - Deploy:   Full deployment. Run only after validation passes.

    infrastructure.yml paths used:
      azure_platform.azure_tenants[0].aztenant_subscription_id  - Subscription
      compute.azure_local.resource_group                        - Resource group
      cluster_arm_deployment.arm_mode                           - Validate or Deploy

    The generation script (Generate-AzureLocal-Parameters.ps1) reads all 54 ARM
    parameter values from the config. This script orchestrates generation + deployment.

    Requires:
      - Az.Resources module (New-AzResourceGroupDeployment)
      - powershell-yaml module (for Generate-AzureLocal-Parameters.ps1)
      - Authenticated Azure session (Connect-AzAccount)

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-discovers infrastructure*.yml if not provided.

.PARAMETER AuthType
    Authentication type: AD or LocalIdentity. Determines which parameters template
    is used and whether domainFqdn/adouPath are populated.

.PARAMETER DeploymentMode
    Validate or Deploy. Overrides cluster_arm_deployment.arm_mode in infrastructure.yml.
    Default: reads from config (typically "Validate").

.PARAMETER ParametersFile
    Path to a pre-built parameters file. When provided, skips generation and uses
    this file directly. Useful when parameters have been manually reviewed.

.PARAMETER TemplateUri
    Override the ARM template URI. Defaults to the Microsoft quickstart template.

.PARAMETER LogPath
    Override log file path. Default: .\logs\task-01-initiate-deployment-via-arm-template\<timestamp>.log

.PARAMETER WhatIf
    Dry-run mode — shows what would happen without deploying.

.EXAMPLE
    .\Deploy-AzureLocalCluster.ps1 -ConfigPath .\configs\infrastructure.yml -AuthType LocalIdentity -DeploymentMode Validate

.EXAMPLE
    .\Deploy-AzureLocalCluster.ps1 -ConfigPath .\configs\infrastructure.yml -AuthType AD -DeploymentMode Deploy

.EXAMPLE
    .\Deploy-AzureLocalCluster.ps1 -ParametersFile .\azuredeploy.parameters.ad.json -DeploymentMode Validate

.EXAMPLE
    .\Deploy-AzureLocalCluster.ps1 -ConfigPath .\configs\infrastructure.yml -AuthType LocalIdentity -WhatIf

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-01-initiate-deployment-via-arm-template
    Execution:    Run from management/jump box (authenticated to Azure)
    Script Type:  Config-driven (Option 2 — Azure PowerShell)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("AD", "LocalIdentity")]
    [string]$AuthType = "LocalIdentity",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Validate", "Deploy")]
    [string]$DeploymentMode = "",

    [Parameter(Mandatory = $false)]
    [string]$ParametersFile = "",

    [Parameter(Mandatory = $false)]
    [string]$TemplateUri = "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region HELPERS

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "SUCCESS" { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }

    if ($script:LogFile) {
        "[$ts] [$Level] $Message" | Add-Content -Path $script:LogFile -ErrorAction SilentlyContinue
    }
}

function Resolve-ConfigPath {
    param([string]$Provided)

    if ($Provided -ne "" -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }

    $searchPaths = @(
        (Join-Path (Get-Location).Path "configs"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\..\configs"),
        "C:\configs",
        "C:\AzureLocal\configs"
    )

    $found = @()
    foreach ($dir in $searchPaths) {
        if (Test-Path $dir) {
            $found += Get-ChildItem -Path $dir -Filter "infrastructure*.yml" -File -ErrorAction SilentlyContinue
        }
    }

    $found = @($found | Sort-Object FullName -Unique)

    if ($found.Count -eq 0) {
        throw "No infrastructure*.yml found. Pass -ConfigPath or place it in a standard location."
    }

    if ($found.Count -eq 1) {
        Write-Log "Config: $($found[0].FullName)"
        return $found[0].FullName
    }

    Write-Log "Multiple config files found:" "WARN"
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host "  [$($i+1)] $($found[$i].FullName)" -ForegroundColor Yellow
    }
    $choice = Read-Host "Select config [1-$($found.Count)]"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $found.Count) { throw "Invalid selection." }
    return $found[$idx].FullName
}

#endregion HELPERS

#region LOGGING

$taskFolderName = "task-01-initiate-deployment-via-arm-template"
if ($LogPath -ne "") {
    $script:LogFile = $LogPath
}
else {
    $logDir = Join-Path (Get-Location).Path "logs\$taskFolderName"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $script:LogFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd')_$(Get-Date -Format 'HHmmss')_Deploy-AzureLocalCluster.log"
}

#endregion LOGGING

#region MAIN

Write-Log "========================================" "HEADER"
Write-Log " Azure Local Cluster — ARM Template Deployment" "HEADER"
Write-Log "========================================" "HEADER"

# --- Verify Azure context ---
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    throw "Not authenticated to Azure. Run Connect-AzAccount first."
}
Write-Log "Azure context: $($ctx.Account.Id) / Tenant: $($ctx.Tenant.Id)"

# --- Resolve config ---
$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Using config: $configFile"

# --- Load YAML for subscription and resource group ---
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "Module 'powershell-yaml' is required. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop

$yamlContent = Get-Content -Path $configFile -Raw | ConvertFrom-Yaml
$subscriptionId = $yamlContent.azure_platform.azure_tenants[0].aztenant_subscription_id   # azure_platform.azure_tenants[0].aztenant_subscription_id
$resourceGroup  = $yamlContent.compute.azure_local.resource_group                          # compute.azure_local.resource_group
$clusterName    = $yamlContent.cluster_arm_deployment.cluster_name                         # cluster_arm_deployment.cluster_name

Write-Log "Subscription:   $subscriptionId"
Write-Log "Resource Group: $resourceGroup"
Write-Log "Cluster Name:   $clusterName"
Write-Log "Auth Type:      $AuthType"

# --- Resolve deployment mode ---
if ($DeploymentMode -eq "") {
    $configMode = $yamlContent.cluster_arm_deployment.arm_mode                              # cluster_arm_deployment.arm_mode
    if ($configMode -eq "deploy") {
        $DeploymentMode = "Deploy"
    }
    else {
        $DeploymentMode = "Validate"
    }
    Write-Log "Deployment mode from config: $DeploymentMode"
}
else {
    Write-Log "Deployment mode (override): $DeploymentMode"
}

# --- Set subscription context ---
Write-Log "Setting Azure context to subscription: $subscriptionId"
Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null

# --- Generate or use provided parameters file ---
if ($ParametersFile -ne "" -and (Test-Path $ParametersFile)) {
    $paramsPath = (Resolve-Path $ParametersFile).Path
    Write-Log "Using provided parameters file: $paramsPath"
}
else {
    # Locate the generation script
    $generatorPaths = @(
        (Join-Path (Get-Location).Path "configs\Generate-AzureLocal-Parameters.ps1"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\..\configs\Generate-AzureLocal-Parameters.ps1")
    )

    $generatorScript = $null
    foreach ($gp in $generatorPaths) {
        if (Test-Path $gp) { $generatorScript = (Resolve-Path $gp).Path; break }
    }

    if (-not $generatorScript) {
        throw "Generate-AzureLocal-Parameters.ps1 not found. Pass -ParametersFile with a pre-built file, or ensure the generator is in config/."
    }

    Write-Log "Generator script: $generatorScript"

    $authSuffix = if ($AuthType -eq "AD") { "ad" } else { "local-identity" }
    $paramsPath = Join-Path (Split-Path $configFile) "azuredeploy.parameters.$authSuffix.generated.json"

    Write-Log "Generating parameters file: $paramsPath"

    & $generatorScript `
        -ConfigPath $configFile `
        -AuthType $AuthType `
        -OutputPath $paramsPath

    if (-not (Test-Path $paramsPath)) {
        throw "Parameter generation failed — output file not created: $paramsPath"
    }

    Write-Log "Parameters file generated: $paramsPath" "SUCCESS"
}

# --- Set deploymentMode in generated parameters ---
Write-Log "Setting deploymentMode to '$DeploymentMode' in parameters file..."
$paramsJson = Get-Content -Path $paramsPath -Raw | ConvertFrom-Json
$paramsJson.parameters.deploymentMode.value = $DeploymentMode
$paramsJson | ConvertTo-Json -Depth 20 | Set-Content -Path $paramsPath -Encoding UTF8
Write-Log "deploymentMode set to: $DeploymentMode" "SUCCESS"

# --- Deploy ---
$deploymentName = "azl-$($DeploymentMode.ToLower())-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Log "Deployment name: $deploymentName"
Write-Log "Template URI:    $TemplateUri"
Write-Log ""

if ($PSCmdlet.ShouldProcess("$resourceGroup/$clusterName", "ARM Template $DeploymentMode")) {
    Write-Log "Starting $DeploymentMode..." "HEADER"

    $deployment = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $resourceGroup `
        -TemplateUri $TemplateUri `
        -TemplateParameterFile $paramsPath `
        -Verbose

    $state = $deployment.ProvisioningState
    Write-Log ""
    Write-Log "Deployment: $deploymentName" "HEADER"
    Write-Log "State:      $state" $(if ($state -eq "Succeeded") { "SUCCESS" } else { "ERROR" })
    Write-Log "Timestamp:  $($deployment.Timestamp)"

    if ($state -ne "Succeeded") {
        Write-Log "Deployment did not succeed. Check Azure Portal → Resource Group → Deployments for details." "ERROR"
        Write-Log "  az deployment group show --name $deploymentName --resource-group $resourceGroup --query properties.error" "INFO"
    }
    elseif ($DeploymentMode -eq "Validate") {
        Write-Log "" "INFO"
        Write-Log "Validation passed. To deploy, re-run with -DeploymentMode Deploy:" "SUCCESS"
        Write-Log "  .\Deploy-AzureLocalCluster.ps1 -ConfigPath `"$configFile`" -AuthType $AuthType -DeploymentMode Deploy" "INFO"
    }
    else {
        Write-Log "" "INFO"
        Write-Log "Deployment initiated. Monitor progress with:" "SUCCESS"
        Write-Log "  .\Monitor-Deployment.ps1 or check Azure Portal → Deployments" "INFO"
    }
}
else {
    Write-Log "[WhatIf] Would run New-AzResourceGroupDeployment:" "WARN"
    Write-Log "  Name:           $deploymentName" "WARN"
    Write-Log "  ResourceGroup:  $resourceGroup" "WARN"
    Write-Log "  TemplateUri:    $TemplateUri" "WARN"
    Write-Log "  ParametersFile: $paramsPath" "WARN"
    Write-Log "  DeploymentMode: $DeploymentMode" "WARN"
}

Write-Log "========================================" "HEADER"
Write-Log " Complete" "HEADER"
Write-Log "========================================" "HEADER"
Write-Log "Log: $($script:LogFile)"

#endregion MAIN
