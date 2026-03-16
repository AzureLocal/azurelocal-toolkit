<#
.SYNOPSIS
    Deploys Azure NAT Gateway for outbound connectivity.

.DESCRIPTION
    This script deploys and configures an Azure NAT Gateway:
    - Creates Public IP for NAT Gateway
    - Creates NAT Gateway resource
    - Associates NAT Gateway with subnets

.PARAMETER ResourceGroupName
    Azure resource group for the NAT Gateway.

.PARAMETER NatGatewayName
    Name for the NAT Gateway.

.PARAMETER VirtualNetworkName
    Name of the virtual network.

.PARAMETER SubnetNames
    Array of subnet names to associate with NAT Gateway.

.EXAMPLE
    .\New-NatGateway.ps1 -ResourceGroupName "rg-mgmt" -SubnetNames @("snet-compute", "snet-management")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 03-azure-foundation
    Step: stage-06-azure-management-infrastructure/step-05-nat-gateway
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$NatGatewayName = "natgw-outbound",

    [Parameter(Mandatory = $false)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $false)]
    [string[]]$SubnetNames,

    [Parameter(Mandatory = $false)]
    [int]$IdleTimeoutMinutes = 10,

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

    if (-not (Test-Path $Path)) { return $null }

    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    $configContent = Get-Content -Path $Path -Raw
    return ConvertFrom-Yaml $configContent
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Azure NAT Gateway Deployment" -Level Info
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

    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info
    Write-LogMessage "NAT Gateway Name: $NatGatewayName" -Level Info
    Write-LogMessage "Virtual Network: $VirtualNetworkName" -Level Info

    if ($WhatIf) {
        Write-LogMessage "WhatIf mode - no changes will be made" -Level Warning
        return
    }

    # Check for existing NAT Gateway
    $existingNatGw = Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName -ErrorAction SilentlyContinue
    if ($existingNatGw) {
        Write-LogMessage "NAT Gateway already exists: $NatGatewayName" -Level Warning
        return $existingNatGw
    }

    # Create Public IP for NAT Gateway
    $pipName = "$NatGatewayName-pip"
    Write-LogMessage "Creating Public IP: $pipName" -Level Info

    $existingPip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $pipName -ErrorAction SilentlyContinue
    if (-not $existingPip) {
        $pip = New-AzPublicIpAddress `
            -ResourceGroupName $ResourceGroupName `
            -Name $pipName `
            -Location $location `
            -AllocationMethod 'Static' `
            -Sku 'Standard' `
            -Zone @('1', '2', '3')
        Write-LogMessage "  Public IP created: $($pip.IpAddress)" -Level Success
    } else {
        $pip = $existingPip
        Write-LogMessage "  Public IP exists: $($pip.IpAddress)" -Level Info
    }

    # Create NAT Gateway
    Write-LogMessage "Creating NAT Gateway..." -Level Info

    $natGateway = New-AzNatGateway `
        -ResourceGroupName $ResourceGroupName `
        -Name $NatGatewayName `
        -Location $location `
        -Sku 'Standard' `
        -IdleTimeoutInMinutes $IdleTimeoutMinutes `
        -PublicIpAddress $pip

    Write-LogMessage "  NAT Gateway created" -Level Success

    # Associate with subnets if specified
    if ($SubnetNames -and $SubnetNames.Count -gt 0) {
        Write-LogMessage "Associating NAT Gateway with subnets..." -Level Info
        
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VirtualNetworkName

        foreach ($subnetName in $SubnetNames) {
            $subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $subnetName -ErrorAction SilentlyContinue
            
            if (-not $subnet) {
                Write-LogMessage "  Subnet not found: $subnetName" -Level Warning
                continue
            }

            Set-AzVirtualNetworkSubnetConfig `
                -VirtualNetwork $vnet `
                -Name $subnetName `
                -AddressPrefix $subnet.AddressPrefix `
                -NatGateway $natGateway | Out-Null

            Write-LogMessage "  Associated: $subnetName" -Level Success
        }

        $vnet | Set-AzVirtualNetwork | Out-Null
    }

    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "NAT Gateway Deployment Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  NAT Gateway: $NatGatewayName" -Level Info
    Write-LogMessage "  Public IP: $($pip.IpAddress)" -Level Info
    Write-LogMessage "  Idle Timeout: $IdleTimeoutMinutes minutes" -Level Info

    return $natGateway

} catch {
    Write-LogMessage "NAT Gateway deployment failed: $_" -Level Error
    throw
}

#endregion Main
