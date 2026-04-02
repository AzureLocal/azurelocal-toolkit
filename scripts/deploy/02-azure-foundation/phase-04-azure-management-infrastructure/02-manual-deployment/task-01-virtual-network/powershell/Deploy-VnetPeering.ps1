<#
.SYNOPSIS
    Creates VNet peering between Management and Connectivity VNets.

.DESCRIPTION
    Implements hub-and-spoke topology per CAF/WAF Landing Zone best practices:
    - Hub: Connectivity VNet - VPN Gateway, Bastion
    - Spoke: Management VNet - Infrastructure VMs
    
    Creates bi-directional peering with:
    - Gateway transit enabled (spoke uses hub gateway for VPN)
    - Bastion connectivity (RDP to spoke VMs via hub Bastion)

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "azure-arc-servers"

.PARAMETER ConnectivitySubscriptionId
    Connectivity subscription ID.

.PARAMETER ManagementSubscriptionId
    Management subscription ID.

.PARAMETER ConnectivityVNetName
    Connectivity hub VNet name.

.PARAMETER ConnectivityResourceGroup
    Connectivity resource group name.

.PARAMETER ManagementVNetName
    Management VNet name.

.PARAMETER ManagementResourceGroup
    Management network resource group name.

.EXAMPLE
    # Using solution configuration
    .\Deploy-VnetPeering.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-VnetPeering.ps1 -ConnectivitySubscriptionId "sub-id" -ManagementSubscriptionId "sub-id"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$ConnectivitySubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ManagementSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ConnectivityVNetName,

    [Parameter(Mandatory = $false)]
    [string]$ConnectivityResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$ManagementVNetName,

    [Parameter(Mandatory = $false)]
    [string]$ManagementResourceGroup
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
if ($Solution) {
    Write-Host "[Config] Loading solution configuration for: $Solution" -ForegroundColor Cyan
    . "$PSScriptRoot\..\..\..\utilities\helpers\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters - only if not explicitly provided
    if (-not $ConnectivitySubscriptionId) { $ConnectivitySubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscriptions.connectivity.id' }
    if (-not $ManagementSubscriptionId) { $ManagementSubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscription.id' }
    if (-not $ConnectivityVNetName) { $ConnectivityVNetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.hub_vnet.name' }
    if (-not $ConnectivityResourceGroup) { $ConnectivityResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.connectivity.name' }
    if (-not $ManagementVNetName) { $ManagementVNetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.vnet.name' }
    if (-not $ManagementResourceGroup) { $ManagementResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.network.name' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $ConnectivitySubscriptionId) { $missingParams += 'ConnectivitySubscriptionId' }
if (-not $ManagementSubscriptionId) { $missingParams += 'ManagementSubscriptionId' }
if (-not $ConnectivityVNetName) { $missingParams += 'ConnectivityVNetName' }
if (-not $ConnectivityResourceGroup) { $missingParams += 'ConnectivityResourceGroup' }
if (-not $ManagementVNetName) { $missingParams += 'ManagementVNetName' }
if (-not $ManagementResourceGroup) { $missingParams += 'ManagementResourceGroup' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

Write-Host "=== VNet Peering Configuration ===" -ForegroundColor Cyan
Write-Host "Hub VNet: $ConnectivityVNetName (Connectivity sub)" -ForegroundColor Gray
Write-Host "Spoke VNet: $ManagementVNetName (Management sub)" -ForegroundColor Gray
Write-Host ""

# Get Hub VNet
Write-Host "[1/4] Getting Hub VNet from Connectivity subscription..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ConnectivitySubscriptionId | Out-Null
$hubVNet = Get-AzVirtualNetwork -Name $ConnectivityVNetName -ResourceGroupName $ConnectivityResourceGroup
Write-Host "✓ Hub VNet: $($hubVNet.Id)" -ForegroundColor Green

# Get Spoke VNet
Write-Host "[2/4] Getting Spoke VNet from Management subscription..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
$spokeVNet = Get-AzVirtualNetwork -Name $ManagementVNetName -ResourceGroupName $ManagementResourceGroup
Write-Host "✓ Spoke VNet: $($spokeVNet.Id)" -ForegroundColor Green

# Create Hub → Spoke peering (in Connectivity sub)
Write-Host "[3/4] Creating Hub → Spoke peering..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ConnectivitySubscriptionId | Out-Null

$hubToSpokePeeringName = "peer-hub-to-mgmt-infra"
$existingPeering = Get-AzVirtualNetworkPeering -VirtualNetworkName $ConnectivityVNetName -ResourceGroupName $ConnectivityResourceGroup -Name $hubToSpokePeeringName -ErrorAction SilentlyContinue

if ($existingPeering) {
    Write-Host "✓ Peering already exists: $hubToSpokePeeringName" -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess($hubToSpokePeeringName, "Create peering")) {
        Add-AzVirtualNetworkPeering `
            -Name $hubToSpokePeeringName `
            -VirtualNetwork $hubVNet `
            -RemoteVirtualNetworkId $spokeVNet.Id `
            -AllowForwardedTraffic `
            -AllowGatewayTransit | Out-Null
        
        Write-Host "✓ Hub → Spoke peering created with gateway transit enabled" -ForegroundColor Green
    }
}

# Create Spoke → Hub peering (in Management sub)
Write-Host "[4/4] Creating Spoke → Hub peering..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null

$spokeToHubPeeringName = "peer-mgmt-infra-to-hub"
$existingPeering = Get-AzVirtualNetworkPeering -VirtualNetworkName $ManagementVNetName -ResourceGroupName $ManagementResourceGroup -Name $spokeToHubPeeringName -ErrorAction SilentlyContinue

if ($existingPeering) {
    Write-Host "✓ Peering already exists: $spokeToHubPeeringName" -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess($spokeToHubPeeringName, "Create peering")) {
        Add-AzVirtualNetworkPeering `
            -Name $spokeToHubPeeringName `
            -VirtualNetwork $spokeVNet `
            -RemoteVirtualNetworkId $hubVNet.Id `
            -AllowForwardedTraffic `
            -UseRemoteGateways | Out-Null
        
        Write-Host "✓ Spoke → Hub peering created with remote gateway usage enabled" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== VNet Peering Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Connectivity:" -ForegroundColor Cyan
Write-Host "  ✓ VMs in Management VNet can access resources in Connectivity VNet" -ForegroundColor Gray
Write-Host "  ✓ Bastion in Connectivity VNet can RDP to VMs in Management VNet" -ForegroundColor Gray
Write-Host "  ✓ VPN Gateway in Connectivity VNet provides on-prem access for Management VMs" -ForegroundColor Gray
Write-Host ""
Write-Host "Next: Deploy VMs with .\02-deploy-domain-controllers.ps1" -ForegroundColor Cyan
