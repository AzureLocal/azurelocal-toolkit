<#
.SYNOPSIS
    Deploys Network Device Management (NDM) server VM.

.DESCRIPTION
    This script deploys a Network Device Management server:
    - Creates VM for network device management tools
    - Configures networking for access to network devices
    - Installs base management tooling

.PARAMETER ResourceGroupName
    Azure resource group for the NDM server.

.PARAMETER VmName
    Name for the NDM server VM.

.PARAMETER VirtualNetworkName
    Name of the virtual network.

.PARAMETER SubnetName
    Name of the subnet for the NDM server.

.PARAMETER VmSize
    Azure VM size.

.EXAMPLE
    .\New-NdmServer.ps1 -VmName "ndm01" -AdminUsername "azadmin"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 03-azure-foundation
    Step: stage-06-azure-management-infrastructure/step-11-ndm-server
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VmName = "ndm01",

    [Parameter(Mandatory = $false)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $false)]
    [string]$SubnetName = "snet-management",

    [Parameter(Mandatory = $false)]
    [string]$VmSize = "Standard_D2s_v5",

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername = "azadmin",

    [Parameter(Mandatory = $false)]
    [securestring]$AdminPassword,

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
    Write-LogMessage "Network Device Management Server Deployment" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
    }

    # Get parameters from config if not provided
    if (-not $ResourceGroupName) {
        $ResourceGroupName = $config.azure_platform.resource_groups.management
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

    # Create NIC
    $nicName = "$VmName-nic"
    Write-LogMessage "Creating NIC: $nicName" -Level Info

    $nic = New-AzNetworkInterface `
        -ResourceGroupName $ResourceGroupName `
        -Name $nicName `
        -Location $location `
        -SubnetId $subnet.Id

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

    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

    # Create VM
    Write-LogMessage "Creating VM (this may take a few minutes)..." -Level Info

    $vm = New-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Location $location `
        -VM $vmConfig

    Write-LogMessage "  VM created successfully" -Level Success

    # Create custom script extension for NDM tools installation
    $ndmSetupScript = @"

# Install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Install common network management tools
choco install -y putty
choco install -y winscp
choco install -y wireshark
choco install -y nmap
choco install -y curl
choco install -y git
choco install -y vscode

# Enable SSH client
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

Write-Host "NDM tools installation complete"
"@

    # Note: Custom Script Extension could be added here
    # For now, provide manual instructions

    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "NDM Server Deployment Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  VM Name: $VmName" -Level Info
    Write-LogMessage "  Private IP: $($nic.IpConfigurations[0].PrivateIpAddress)" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "NEXT STEPS:" -Level Warning
    Write-LogMessage "  1. Connect to VM via Bastion or VPN" -Level Info
    Write-LogMessage "  2. Install network management tools:" -Level Info
    Write-LogMessage "     - PuTTY for SSH/Telnet access" -Level Info
    Write-LogMessage "     - WinSCP for file transfers" -Level Info
    Write-LogMessage "     - Wireshark for packet capture" -Level Info
    Write-LogMessage "     - Nmap for network scanning" -Level Info
    Write-LogMessage "  3. Configure network device access" -Level Info

    return $vm

} catch {
    Write-LogMessage "NDM Server deployment failed: $_" -Level Error
    throw
}

#endregion Main
