<#
.SYNOPSIS
    Deploy-AzureLocalCluster-Standalone.ps1
    Validates or deploys an Azure Local cluster via ARM template with inline variables.

.DESCRIPTION
    Standalone script (Option 5). No infrastructure.yml or generation script dependency.
    All values are set as inline variables. Edit the CONFIGURATION section below before running.

    Requires:
      - Az.Resources module (New-AzResourceGroupDeployment)
      - Authenticated Azure session (Connect-AzAccount)
      - Pre-built parameters file (azuredeploy.parameters.*.json)

.PARAMETER DeploymentMode
    Validate or Deploy. Default: Validate.

.EXAMPLE
    .\Deploy-AzureLocalCluster-Standalone.ps1 -DeploymentMode Validate

.EXAMPLE
    .\Deploy-AzureLocalCluster-Standalone.ps1 -DeploymentMode Deploy

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Script Type:  Standalone (Option 5 — no config dependency)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Validate", "Deploy")]
    [string]$DeploymentMode = "Validate"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION — Edit these values before running

$subscriptionId = "<SUBSCRIPTION_ID>"                              # azure_platform.azure_tenants[0].aztenant_subscription_id
$resourceGroup  = "<RESOURCE_GROUP>"                               # compute.azure_local.resource_group
$parametersFile = ".\azuredeploy.parameters.local-identity.json"   # Path to your parameters file
$templateUri    = "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json"

#endregion CONFIGURATION

# Verify Azure context
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) { throw "Not authenticated to Azure. Run Connect-AzAccount first." }

# Set subscription
Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
Write-Host "Subscription: $subscriptionId" -ForegroundColor Cyan
Write-Host "Resource Group: $resourceGroup" -ForegroundColor Cyan

# Verify parameters file exists
if (-not (Test-Path $parametersFile)) {
    throw "Parameters file not found: $parametersFile"
}

# Set deploymentMode in parameters
$paramsJson = Get-Content -Path $parametersFile -Raw | ConvertFrom-Json
$paramsJson.parameters.deploymentMode.value = $DeploymentMode
$paramsJson | ConvertTo-Json -Depth 20 | Set-Content -Path $parametersFile -Encoding UTF8
Write-Host "deploymentMode: $DeploymentMode" -ForegroundColor Cyan

# Deploy
$deploymentName = "azl-$($DeploymentMode.ToLower())-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Deployment name: $deploymentName" -ForegroundColor Cyan
Write-Host ""

if ($PSCmdlet.ShouldProcess("$resourceGroup", "ARM Template $DeploymentMode")) {
    $deployment = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $resourceGroup `
        -TemplateUri $templateUri `
        -TemplateParameterFile $parametersFile `
        -Verbose

    Write-Host ""
    Write-Host "State: $($deployment.ProvisioningState)" -ForegroundColor $(
        if ($deployment.ProvisioningState -eq "Succeeded") { "Green" } else { "Red" }
    )

    if ($deployment.ProvisioningState -eq "Succeeded" -and $DeploymentMode -eq "Validate") {
        Write-Host ""
        Write-Host "Validation passed. Re-run with -DeploymentMode Deploy to deploy." -ForegroundColor Green
    }
}
