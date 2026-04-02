#Requires -Modules Az.Compute, Az.Network, Az.KeyVault
<#
.SYNOPSIS
    Deploy management VMs (DC01, DC02, Utility, NDM, Lighthouse) to Azure.
.DESCRIPTION
    Creates NICs with static IPs and VMs for each management role, sourcing
    credentials and configuration from config/variables.yml and Key Vault.
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

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$azure  = $config.azure
$rg     = $azure.resource_group
$kvName = $azure.key_vault.name
$vms    = $azure.management_vms

Write-Host "Deploying management VMs..." -ForegroundColor Cyan

# ── Retrieve local admin credentials from Key Vault ───────────────────────────
Write-Host "  Retrieving admin credentials from Key Vault..."
$adminUser  = Get-AzKeyVaultSecret -VaultName $kvName -Name "vm-admin-username" -AsPlainText
$adminPass  = Get-AzKeyVaultSecret -VaultName $kvName -Name "vm-admin-password" -AsPlainText |
              ConvertTo-SecureString -AsPlainText -Force
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
