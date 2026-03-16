<#
.SYNOPSIS
    Deploys Azure Domain Controller VMs for hybrid identity.

.DESCRIPTION
    This script deploys domain controller VMs in Azure:
    - Creates VM(s) for Active Directory Domain Services
    - Configures networking and DNS settings
    - Prepares VM for DC promotion (manual step required)

.PARAMETER ResourceGroupName
    Azure resource group for the domain controller.

.PARAMETER VmName
    Name for the domain controller VM.

.PARAMETER VirtualNetworkName
    Name of the virtual network.

.PARAMETER SubnetName
    Name of the subnet for the DC.

.PARAMETER VmSize
    Azure VM size for the domain controller.

.PARAMETER AdminUsername
    Administrator username for the VM.

.EXAMPLE
    .\New-DomainController.ps1 -VmName "dc01" -AdminUsername "azadmin"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 03-azure-foundation
    Step: stage-06-azure-management-infrastructure/step-09-domain-controllers
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VmName = "dc01",

    [Parameter(Mandatory = $false)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $false)]
    [string]$SubnetName = "snet-identity",

    [Parameter(Mandatory = $false)]
    [string]$VmSize = "Standard_D2s_v5",

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername = "azadmin",

    [Parameter(Mandatory = $false)]
    [securestring]$AdminPassword,

    [Parameter(Mandatory = $false)]
    [string]$PrivateIpAddress,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

#Requires -Version 7.0
#Requires -Modules Az.Compute, Az.Network, Az.Resources

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
    Write-LogMessage "Azure Domain Controller VM Deployment" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
    }

    # Get parameters from config if not provided
    if (-not $ResourceGroupName) {
        $ResourceGroupName = $config.azure_platform.resource_groups.identity ?? $config.azure_platform.resource_groups.management
        if (-not $ResourceGroupName) {
            throw "ResourceGroupName is required"
        }
    }

    if (-not $VirtualNetworkName) {
        $VirtualNetworkName = $config.networking.azure.hub_spoke.vnet_name ?? "vnet-management"
    }

    $location = $config.azure_platform.location ?? "eastus"

    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info
    Write-LogMessage "VM Name: $VmName" -Level Info
    Write-LogMessage "VM Size: $VmSize" -Level Info
    Write-LogMessage "Subnet: $SubnetName" -Level Info

    if ($WhatIf) {
        Write-LogMessage "WhatIf mode - no changes will be made" -Level Warning
        return
    }

    # Check for existing VM
    $existingVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Write-LogMessage "VM already exists: $VmName" -Level Warning
        return $existingVm
    }

    # Prompt for password if not provided
    if (-not $AdminPassword) {
        $AdminPassword = Read-Host -Prompt "Enter admin password for $AdminUsername" -AsSecureString
    }

    # Get subnet
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VirtualNetworkName -ErrorAction Stop
    $subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName -ErrorAction Stop

    Write-LogMessage "  VNet found: $($vnet.Name)" -Level Success
    Write-LogMessage "  Subnet found: $($subnet.Name)" -Level Success

    # Create NIC with static IP
    $nicName = "$VmName-nic"
    Write-LogMessage "Creating NIC: $nicName" -Level Info

    $nicParams = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $nicName
        Location          = $location
        SubnetId          = $subnet.Id
    }

    if ($PrivateIpAddress) {
        $nicParams['PrivateIpAddress'] = $PrivateIpAddress
    }

    $nic = New-AzNetworkInterface @nicParams
    Write-LogMessage "  NIC created: $($nic.IpConfigurations[0].PrivateIpAddress)" -Level Success

    # Create VM configuration
    Write-LogMessage "Creating VM configuration..." -Level Info

    $credential = New-Object System.Management.Automation.PSCredential($AdminUsername, $AdminPassword)

    $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize

    $vmConfig = Set-AzVMOperatingSystem `
        -VM $vmConfig `
        -Windows `
        -ComputerName $VmName `
        -Credential $credential `
        -ProvisionVMAgent `
        -EnableAutoUpdate

    $vmConfig = Set-AzVMSourceImage `
        -VM $vmConfig `
        -PublisherName 'MicrosoftWindowsServer' `
        -Offer 'WindowsServer' `
        -Skus '2022-datacenter-azure-edition' `
        -Version 'latest'

    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

    # Add data disk for AD database
    $vmConfig = Add-AzVMDataDisk `
        -VM $vmConfig `
        -Name "$VmName-data" `
        -DiskSizeInGB 64 `
        -Lun 0 `
        -CreateOption 'Empty' `
        -StorageAccountType 'Premium_LRS'

    # Disable boot diagnostics for simplicity
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

    # Create VM
    Write-LogMessage "Creating VM (this may take a few minutes)..." -Level Info

    $vm = New-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Location $location `
        -VM $vmConfig

    Write-LogMessage "  VM created successfully" -Level Success

    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Domain Controller VM Deployment Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  VM Name: $VmName" -Level Info
    Write-LogMessage "  Private IP: $($nic.IpConfigurations[0].PrivateIpAddress)" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "NEXT STEPS:" -Level Warning
    Write-LogMessage "  1. Connect to VM via Bastion or VPN" -Level Info
    Write-LogMessage "  2. Initialize and format the data disk (F:)" -Level Info
    Write-LogMessage "  3. Install AD DS role: Install-WindowsFeature AD-Domain-Services -IncludeManagementTools" -Level Info
    Write-LogMessage "  4. Promote to domain controller or create new forest" -Level Info
    Write-LogMessage "  5. Update VNet DNS settings to point to this DC" -Level Info

    return $vm

} catch {
    Write-LogMessage "Domain Controller deployment failed: $_" -Level Error
    throw
}

#endregion Main
