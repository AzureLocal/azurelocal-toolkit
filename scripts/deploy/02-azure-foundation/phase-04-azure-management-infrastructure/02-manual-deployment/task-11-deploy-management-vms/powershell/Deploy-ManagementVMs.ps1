#Requires -Version 7.0
#Requires -Modules Az.Compute, Az.Network
<#
.SYNOPSIS
    Deploy management VMs (DC01, DC02, Utility, NDM, Lighthouse) to Azure.
.DESCRIPTION
    Creates NICs with static IPs and VMs for each management role, sourcing
    configuration from config/variables.yml and the administrator credentials from the secret reference of the first entry of
    landing_zone.virtual_machines (admin_username, admin_password), read by the toolkit's secret resolver.
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
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$azure  = $config.azure
$rg     = $azure.resource_group
$vms    = $azure.management_vms

Write-Host "Deploying management VMs..." -ForegroundColor Cyan

# ── Local admin credentials: the secret reference in the infrastructure file ───
Write-Host "  Reading the admin credentials from the secret reference..."
$vmAdmin = @($config.landing_zone.virtual_machines) | Where-Object { $_ } | Select-Object -First 1
if (-not $vmAdmin -or -not $vmAdmin.admin_username -or -not $vmAdmin.admin_password) {
    throw "landing_zone.virtual_machines needs an entry with admin_username and admin_password (a secret reference) in $ConfigPath."
}
$adminUser  = [string]$vmAdmin.admin_username
$adminPass  = Get-AzlSecretValue -Reference ([string]$vmAdmin.admin_password) -Infrastructure $config
$adminCreds = New-Object System.Management.Automation.PSCredential($adminUser, $adminPass)

# ── Get subnet ────────────────────────────────────────────────────────────────
$vnet   = Get-AzVirtualNetwork -Name $azure.vnet_name -ResourceGroupName $rg
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $azure.management_subnet_name -VirtualNetwork $vnet

# ── VM definitions ────────────────────────────────────────────────────────────
$vmDefinitions = @(
    @{ Name = "dc01";      Role = "Domain Controller Primary";  StaticIp = $vms.dc01.ip;      Size = $vms.dc01.size }
    @{ Name = "dc02";      Role = "Domain Controller Secondary"; StaticIp = $vms.dc02.ip;     Size = $vms.dc02.size }
    @{ Name = "utility";   Role = "Utility Server";             StaticIp = $vms.utility.ip;   Size = $vms.utility.size }
    @{ Name = "ndm";       Role = "Network Device Management";  StaticIp = $vms.ndm.ip;       Size = $vms.ndm.size }
    @{ Name = "lighthouse";Role = "Azure Lighthouse";           StaticIp = $vms.lighthouse.ip; Size = $vms.lighthouse.size }
)

foreach ($def in $vmDefinitions) {
    $vmName = "$($azure.prefix)-$($def.Name)"
    Write-Host ""
    Write-Host "  Deploying: $vmName ($($def.Role))..." -ForegroundColor Cyan

    # Check if VM already exists
    $existing = Get-AzVM -Name $vmName -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "    [SKIP] VM '$vmName' already exists." -ForegroundColor Yellow
        continue
    }

    if ($PSCmdlet.ShouldProcess($vmName, "Create VM")) {
        # Create NIC with static IP
        $nicName = "$vmName-nic"
        $nic = New-AzNetworkInterface `
            -Name              $nicName `
            -ResourceGroupName $rg `
            -Location          $azure.location `
            -SubnetId          $subnet.Id `
            -PrivateIpAddress  $def.StaticIp

        # Build VM config
        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $def.Size |
            Set-AzVMOperatingSystem `
                -Windows `
                -ComputerName  $vmName `
                -Credential    $adminCreds `
                -ProvisionVMAgent `
                -EnableAutoUpdate |
            Set-AzVMSourceImage `
                -PublisherName "MicrosoftWindowsServer" `
                -Offer         "WindowsServer" `
                -Skus          "2022-Datacenter" `
                -Version       "latest" |
            Set-AzVMOSDisk `
                -Name         "$vmName-osdisk" `
                -CreateOption "FromImage" `
                -StorageAccountType "Premium_LRS" |
            Add-AzVMNetworkInterface -Id $nic.Id

        New-AzVM -ResourceGroupName $rg -Location $azure.location -VM $vmConfig
        Write-Host "    [DONE] $vmName deployed." -ForegroundColor Green
    }
}

Write-Host "`nManagement VM deployment complete." -ForegroundColor Cyan
