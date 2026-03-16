<#
.SYNOPSIS
    Deploys Azure VPN Gateway for hybrid connectivity.

.DESCRIPTION
    This script deploys and configures an Azure VPN Gateway:
    - Creates Gateway Subnet
    - Deploys Public IP for VPN Gateway
    - Creates VPN Gateway (may take 30-45 minutes)
    - Configures gateway settings

.PARAMETER ResourceGroupName
    Azure resource group for the VPN Gateway.

.PARAMETER VirtualNetworkName
    Name of the existing virtual network.

.PARAMETER GatewayName
    Name for the VPN Gateway.

.PARAMETER GatewaySku
    SKU for the VPN Gateway: VpnGw1, VpnGw2, VpnGw3, etc.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\New-VpnGateway.ps1 -ResourceGroupName "rg-mgmt" -VirtualNetworkName "vnet-mgmt" -GatewayName "vpngw-onprem"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 03-azure-foundation
    Step: stage-06-azure-management-infrastructure/step-02-vpn-gateway
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $false)]
    [string]$GatewayName = "vpngw-onprem",

    [Parameter(Mandatory = $false)]
    [ValidateSet('VpnGw1', 'VpnGw2', 'VpnGw3', 'VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ')]
    [string]$GatewaySku = "VpnGw1",

    [Parameter(Mandatory = $false)]
    [string]$GatewaySubnetPrefix = "10.0.255.0/27",

    [Parameter(Mandatory = $false)]
    [ValidateSet('RouteBased', 'PolicyBased')]
    [string]$VpnType = "RouteBased",

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

#Requires -Version 7.0
#Requires -Modules Az.Network, Az.Resources

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    $configContent = Get-Content -Path $Path -Raw
    return ConvertFrom-Yaml $configContent
}

function New-GatewaySubnet {
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$VirtualNetworkName,
        [string]$AddressPrefix
    )

    Write-LogMessage "Checking for GatewaySubnet..." -Level Info

    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VirtualNetworkName
    $gatewaySubnet = $vnet.Subnets | Where-Object { $_.Name -eq 'GatewaySubnet' }

    if ($gatewaySubnet) {
        Write-LogMessage "  GatewaySubnet already exists: $($gatewaySubnet.AddressPrefix)" -Level Info
        return $gatewaySubnet
    }

    Write-LogMessage "  Creating GatewaySubnet with prefix: $AddressPrefix" -Level Info

    Add-AzVirtualNetworkSubnetConfig `
        -Name 'GatewaySubnet' `
        -VirtualNetwork $vnet `
        -AddressPrefix $AddressPrefix | Out-Null

    $vnet | Set-AzVirtualNetwork | Out-Null

    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VirtualNetworkName
    $gatewaySubnet = $vnet.Subnets | Where-Object { $_.Name -eq 'GatewaySubnet' }

    Write-LogMessage "  GatewaySubnet created successfully" -Level Success
    return $gatewaySubnet
}

function New-VpnGatewayPublicIp {
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$Name,
        [string]$Location,
        [bool]$ZoneRedundant
    )

    Write-LogMessage "Creating Public IP for VPN Gateway..." -Level Info

    $existingPip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existingPip) {
        Write-LogMessage "  Public IP already exists" -Level Info
        return $existingPip
    }

    $pipParams = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $Name
        Location          = $Location
        AllocationMethod  = 'Static'
        Sku               = 'Standard'
    }

    if ($ZoneRedundant) {
        $pipParams['Zone'] = @('1', '2', '3')
    }

    $pip = New-AzPublicIpAddress @pipParams

    Write-LogMessage "  Public IP created: $($pip.IpAddress)" -Level Success
    return $pip
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Azure VPN Gateway Deployment" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
    }

    # Get parameters from config if not provided
    if (-not $ResourceGroupName) {
        $ResourceGroupName = $config.azure_platform.resource_groups.network ?? $config.azure_platform.resource_groups.management
        if (-not $ResourceGroupName) {
            throw "ResourceGroupName is required"
        }
    }

    if (-not $VirtualNetworkName) {
        $VirtualNetworkName = $config.networking.azure.hub_spoke.vnet_name ?? "vnet-management"
    }

    $location = $config.azure_platform.location ?? "eastus"
    $isZoneRedundant = $GatewaySku -like '*AZ'

    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info
    Write-LogMessage "Virtual Network: $VirtualNetworkName" -Level Info
    Write-LogMessage "Gateway Name: $GatewayName" -Level Info
    Write-LogMessage "Gateway SKU: $GatewaySku" -Level Info

    if ($WhatIf) {
        Write-LogMessage "WhatIf mode - no changes will be made" -Level Warning
        return
    }

    # Verify VNet exists
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VirtualNetworkName -ErrorAction Stop
    Write-LogMessage "  VNet found: $($vnet.Name)" -Level Success

    # Create Gateway Subnet
    $gatewaySubnet = New-GatewaySubnet `
        -ResourceGroupName $ResourceGroupName `
        -VirtualNetworkName $VirtualNetworkName `
        -AddressPrefix $GatewaySubnetPrefix

    # Create Public IP
    $pipName = "$GatewayName-pip"
    $pip = New-VpnGatewayPublicIp `
        -ResourceGroupName $ResourceGroupName `
        -Name $pipName `
        -Location $location `
        -ZoneRedundant $isZoneRedundant

    # Check if gateway already exists
    $existingGateway = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $GatewayName -ErrorAction SilentlyContinue
    if ($existingGateway) {
        Write-LogMessage "VPN Gateway already exists: $GatewayName" -Level Warning
        Write-LogMessage "  Provisioning State: $($existingGateway.ProvisioningState)" -Level Info
        return $existingGateway
    }

    # Create IP Configuration
    Write-LogMessage "Creating VPN Gateway (this may take 30-45 minutes)..." -Level Info
    Write-LogMessage "  Started at: $(Get-Date -Format 'HH:mm:ss')" -Level Info

    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VirtualNetworkName
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet

    $ipConfig = New-AzVirtualNetworkGatewayIpConfig `
        -Name 'gwipconfig' `
        -SubnetId $subnet.Id `
        -PublicIpAddressId $pip.Id

    # Create VPN Gateway
    $gateway = New-AzVirtualNetworkGateway `
        -ResourceGroupName $ResourceGroupName `
        -Name $GatewayName `
        -Location $location `
        -IpConfigurations $ipConfig `
        -GatewayType 'Vpn' `
        -VpnType $VpnType `
        -GatewaySku $GatewaySku `
        -EnableBgp $false `
        -AsJob

    Write-LogMessage "  VPN Gateway deployment started as background job" -Level Info
    Write-LogMessage "  Use 'Get-Job' to monitor progress" -Level Info
    Write-LogMessage "  Use 'Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $GatewayName' to check status" -Level Info

    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "VPN Gateway deployment initiated" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    return $gateway

} catch {
    Write-LogMessage "VPN Gateway deployment failed: $_" -Level Error
    throw
}

#endregion Main
