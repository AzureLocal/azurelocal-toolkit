<#
.SYNOPSIS
    Creates a Site-to-Site VPN connection to on-premises network.

.DESCRIPTION
    This script creates a VPN connection between Azure and on-premises:
    - Creates Local Network Gateway (represents on-prem network)
    - Creates VPN Connection with shared key
    - Configures connection settings

.PARAMETER ResourceGroupName
    Azure resource group for the VPN resources.

.PARAMETER VpnGatewayName
    Name of the existing VPN Gateway.

.PARAMETER LocalGatewayName
    Name for the Local Network Gateway.

.PARAMETER OnPremGatewayIp
    Public IP address of the on-premises VPN device.

.PARAMETER OnPremAddressPrefixes
    Array of on-premises network address prefixes.

.PARAMETER SharedKey
    Pre-shared key for the VPN connection.

.EXAMPLE
    .\New-VpnConnection.ps1 -VpnGatewayName "vpngw-onprem" -OnPremGatewayIp "203.0.113.1" -OnPremAddressPrefixes @("192.168.0.0/16")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 03-azure-foundation
    Step: stage-06-azure-management-infrastructure/step-02a-vpn-connection
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VpnGatewayName = "vpngw-onprem",

    [Parameter(Mandatory = $false)]
    [string]$LocalGatewayName = "lgw-onprem",

    [Parameter(Mandatory = $true)]
    [string]$OnPremGatewayIp,

    [Parameter(Mandatory = $true)]
    [string[]]$OnPremAddressPrefixes,

    [Parameter(Mandatory = $false)]
    [string]$ConnectionName = "conn-onprem",

    [Parameter(Mandatory = $false)]
    [securestring]$SharedKey,

    [Parameter(Mandatory = $false)]
    [ValidateSet('IKEv1', 'IKEv2')]
    [string]$IkeVersion = 'IKEv2',

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

function New-LocalNetworkGatewayResource {
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$Name,
        [string]$Location,
        [string]$GatewayIpAddress,
        [string[]]$AddressPrefixes
    )

    Write-LogMessage "Creating Local Network Gateway..." -Level Info

    $existing = Get-AzLocalNetworkGateway -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LogMessage "  Local Network Gateway already exists" -Level Info
        return $existing
    }

    $lgw = New-AzLocalNetworkGateway `
        -ResourceGroupName $ResourceGroupName `
        -Name $Name `
        -Location $Location `
        -GatewayIpAddress $GatewayIpAddress `
        -AddressPrefix $AddressPrefixes

    Write-LogMessage "  Local Network Gateway created" -Level Success
    return $lgw
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Azure VPN Connection Deployment" -Level Info
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

    $location = $config.azure_platform.location ?? "eastus"

    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info
    Write-LogMessage "VPN Gateway: $VpnGatewayName" -Level Info
    Write-LogMessage "On-Prem Gateway IP: $OnPremGatewayIp" -Level Info
    Write-LogMessage "On-Prem Prefixes: $($OnPremAddressPrefixes -join ', ')" -Level Info

    if ($WhatIf) {
        Write-LogMessage "WhatIf mode - no changes will be made" -Level Warning
        return
    }

    # Get VPN Gateway
    $vpnGateway = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $VpnGatewayName -ErrorAction Stop
    Write-LogMessage "  VPN Gateway found: $($vpnGateway.ProvisioningState)" -Level Success

    # Create Local Network Gateway
    $localGateway = New-LocalNetworkGatewayResource `
        -ResourceGroupName $ResourceGroupName `
        -Name $LocalGatewayName `
        -Location $location `
        -GatewayIpAddress $OnPremGatewayIp `
        -AddressPrefixes $OnPremAddressPrefixes

    # Check for existing connection
    $existingConn = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroupName -Name $ConnectionName -ErrorAction SilentlyContinue
    if ($existingConn) {
        Write-LogMessage "VPN Connection already exists: $ConnectionName" -Level Warning
        Write-LogMessage "  Status: $($existingConn.ConnectionStatus)" -Level Info
        return $existingConn
    }

    # Prompt for shared key if not provided
    if (-not $SharedKey) {
        $SharedKey = Read-Host -Prompt "Enter VPN Shared Key" -AsSecureString
    }

    $sharedKeyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SharedKey)
    )

    # Create VPN Connection
    Write-LogMessage "Creating VPN Connection..." -Level Info

    $connection = New-AzVirtualNetworkGatewayConnection `
        -ResourceGroupName $ResourceGroupName `
        -Name $ConnectionName `
        -Location $location `
        -VirtualNetworkGateway1 $vpnGateway `
        -LocalNetworkGateway2 $localGateway `
        -ConnectionType 'IPsec' `
        -SharedKey $sharedKeyPlain `
        -ConnectionProtocol $IkeVersion

    Write-LogMessage "  VPN Connection created" -Level Success

    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "VPN Connection Summary" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  Connection Name: $ConnectionName" -Level Info
    Write-LogMessage "  Status: $($connection.ConnectionStatus)" -Level Info
    Write-LogMessage "  Protocol: $IkeVersion" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "IMPORTANT: Configure matching settings on your on-premises VPN device" -Level Warning

    return $connection

} catch {
    Write-LogMessage "VPN Connection deployment failed: $_" -Level Error
    throw
}

#endregion Main
