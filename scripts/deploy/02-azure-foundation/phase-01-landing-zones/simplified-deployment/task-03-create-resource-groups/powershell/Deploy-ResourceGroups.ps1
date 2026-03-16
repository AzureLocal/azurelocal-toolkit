# ============================================================================
# Script: Deploy-ResourceGroups-az.ps1
# Execution: Run directly on target node (console/RDP session)
# Prerequisites: Azure PowerShell modules, authenticated to Azure
# ============================================================================

#Requires -Modules Az.Resources

# Load configuration
$config = Get-Content "./infrastructure.yml" | ConvertFrom-Yaml

# Extract values
$SubscriptionId    = $config.azure_platform.subscriptions.lab.id
$ResourceGroupName = $config.azure_platform.resource_group_name
$Location          = $config.compute.azure_local.cluster_location

Write-Host "Creating resource group: $ResourceGroupName" -ForegroundColor Cyan

# Set subscription context
Set-AzContext -SubscriptionId $SubscriptionId

# Create resource group
New-AzResourceGroup `
    -Name     $ResourceGroupName `
    -Location $Location

Write-Host "Resource group created successfully: $ResourceGroupName" -ForegroundColor Green
