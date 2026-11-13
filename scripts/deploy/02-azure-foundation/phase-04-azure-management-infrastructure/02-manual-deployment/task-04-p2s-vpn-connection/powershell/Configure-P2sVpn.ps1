#Requires -Version 7.0
#Requires -Modules Az.Network
<#
.SYNOPSIS
    Configure Point-to-Site (P2S) VPN on an Azure Virtual Network Gateway.
.DESCRIPTION
    Loads configuration from config/variables.yml, reads the root certificate from its
    secret reference (azure.vpn_gateway.root_cert_secret_name must hold a secret reference,
    read by the toolkit's secret resolver), and configures the VPN gateway with P2S client address pool,
    protocols, and root certificate.
.PARAMETER ConfigPath
    Path to the YAML variables file. Defaults to ./config/variables.yml.
.PARAMETER WhatIf
    Preview changes without making them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "./config/variables.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config   = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$azure    = $config.azure
$vpnCfg   = $azure.vpn_gateway

Write-Host "Configuring P2S VPN on gateway: $($vpnCfg.name)" -ForegroundColor Cyan

# ── Get VPN Gateway ───────────────────────────────────────────────────────────
Write-Host "  Retrieving VPN gateway..."
$gateway = Get-AzVirtualNetworkGateway `
    -Name              $vpnCfg.name `
    -ResourceGroupName $azure.resource_group

if (-not $gateway) {
    throw "VPN gateway '$($vpnCfg.name)' not found in resource group '$($azure.resource_group)'."
}

# ── Read the root certificate from its secret reference ───────────────────────
Write-Host "  Reading the root certificate from its secret reference..."
$rootCertData = Get-AzlSecretPlainText -Reference ([string]$vpnCfg.root_cert_secret_name) -Infrastructure $config

if (-not $rootCertData) {
    throw "The root certificate secret '$($vpnCfg.root_cert_secret_name)' is empty."
}

# Build VPN client root certificate object
$rootCert = New-AzVpnClientRootCertificate `
    -Name            $vpnCfg.root_cert_name `
    -PublicCertData  $rootCertData

# ── Configure P2S settings ────────────────────────────────────────────────────
Write-Host "  Applying P2S configuration..."
Write-Host "    Client address pool : $($vpnCfg.client_address_pool)"
Write-Host "    Protocols           : $($vpnCfg.protocols -join ', ')"

if ($PSCmdlet.ShouldProcess($vpnCfg.name, "Configure P2S VPN")) {
    Set-AzVirtualNetworkGateway `
        -VirtualNetworkGateway   $gateway `
        -VpnClientAddressPool    $vpnCfg.client_address_pool `
        -VpnClientProtocol       $vpnCfg.protocols `
        -VpnClientRootCertificates $rootCert

    Write-Host "  [DONE] P2S VPN configured successfully." -ForegroundColor Green
}

Write-Host "`nP2S VPN configuration complete." -ForegroundColor Cyan
Write-Host "Distribute the VPN client package to users from the Azure portal."
