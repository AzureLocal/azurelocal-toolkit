<#
.SYNOPSIS
    Creates the Azure Virtual Network and subnets for Azure Local management infrastructure.

.DESCRIPTION
    This script creates the management VNet with all required subnets:
    - GatewaySubnet (for VPN Gateway)
    - AzureBastionSubnet (for Azure Bastion)
    - Management subnet (for VMs)
    - Endpoints subnet (for Private Endpoints)

.PARAMETER ResourceGroupName
    Name of the resource group where the VNet will be created.

.PARAMETER VNetName
    Name of the Virtual Network. Default uses naming convention.

.PARAMETER Location
    Azure region for deployment. Default: eastus

.PARAMETER AddressPrefix
    VNet address space. Default: 10.250.1.0/24

.PARAMETER ConfigFile
    Path to infrastructure.yml for automated configuration.

.EXAMPLE
    .\New-VirtualNetwork.ps1 -ResourceGroupName "rg-azlmgmt-prd-eus-01" -Location "eastus"

.EXAMPLE
    .\New-VirtualNetwork.ps1 -ConfigFile "config/infrastructure.yml"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VNetName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$AddressPrefix = "10.250.1.0/24",

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{}
)

#Requires -Modules Az.Network

# Script root and imports
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

# Import helpers if available
if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }
            "WARN" { "Yellow" }
            "ERROR" { "Red" }
            "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

# Default subnet configuration (based on /24 address space)
$DefaultSubnets = @(
    @{
        Name          = "GatewaySubnet"
        AddressPrefix = "10.250.1.0/27"
        Description   = "VPN Gateway (required name)"
    },
    @{
        Name          = "snet-azrl-mgmt-01"
        AddressPrefix = "10.250.1.32/27"
        Description   = "Management VMs"
    },
    @{
        Name          = "AzureBastionSubnet"
        AddressPrefix = "10.250.1.64/26"
        Description   = "Azure Bastion (required name, minimum /26)"
    },
    @{
        Name          = "snet-endpoints-01"
        AddressPrefix = "10.250.1.128/27"
        Description   = "Private Endpoints"
    }
)

function New-SubnetConfigurations {
    [CmdletBinding()]
    param(
        [string]$BaseAddress
    )

    # Parse base address to adjust subnet ranges if needed
    $subnets = @()
    
    foreach ($subnetDef in $DefaultSubnets) {
        Write-Log -Message "Creating subnet config: $($subnetDef.Name) ($($subnetDef.AddressPrefix))" -Level "INFO"
        
        $subnetConfig = New-AzVirtualNetworkSubnetConfig `
            -Name $subnetDef.Name `
            -AddressPrefix $subnetDef.AddressPrefix
        
        $subnets += $subnetConfig
    }
    
    return $subnets
}

try {
    Write-Log -Message "Starting Virtual Network Creation" -Level "INFO"

    # Load configuration if provided
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        Write-Log -Message "Loading configuration from: $ConfigFile" -Level "INFO"
        . (Join-Path $HelpersPath "config-loader.ps1")
        $config = Get-Configuration -Path $ConfigFile
        
        # Extract values from config
        # (Add config parsing logic as needed)
    }

    # Validate required parameters
    if (-not $ResourceGroupName) {
        Write-Log -Message "ResourceGroupName is required" -Level "ERROR"
        exit 1
    }

    # Set default VNet name if not provided
    if (-not $VNetName) {
        $VNetName = "vnet-azrl-mgmt-01"
    }

    # Check if VNet already exists
    $existingVNet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existingVNet) {
        Write-Log -Message "VNet '$VNetName' already exists" -Level "WARN"
        Write-Log -Message "  Address Space: $($existingVNet.AddressSpace.AddressPrefixes -join ', ')" -Level "INFO"
        Write-Log -Message "  Subnets: $($existingVNet.Subnets.Count)" -Level "INFO"
        
        $response = Read-Host "Do you want to add missing subnets to the existing VNet? (y/n)"
        if ($response -ne 'y') {
            Write-Log -Message "Operation cancelled" -Level "INFO"
            exit 0
        }
        
        # Add missing subnets to existing VNet
        foreach ($subnetDef in $DefaultSubnets) {
            $existing = $existingVNet.Subnets | Where-Object { $_.Name -eq $subnetDef.Name }
            if (-not $existing) {
                Write-Log -Message "Adding subnet: $($subnetDef.Name)" -Level "INFO"
                Add-AzVirtualNetworkSubnetConfig `
                    -Name $subnetDef.Name `
                    -AddressPrefix $subnetDef.AddressPrefix `
                    -VirtualNetwork $existingVNet | Out-Null
            }
            else {
                Write-Log -Message "Subnet '$($subnetDef.Name)' already exists" -Level "INFO"
            }
        }
        
        # Apply changes
        $existingVNet | Set-AzVirtualNetwork | Out-Null
        Write-Log -Message "VNet updated successfully" -Level "SUCCESS"
        exit 0
    }

    # Create subnet configurations
    Write-Log -Message "Creating subnet configurations..." -Level "INFO"
    $subnetConfigs = New-SubnetConfigurations -BaseAddress $AddressPrefix

    # Create VNet with all subnets
    Write-Log -Message "Creating Virtual Network: $VNetName" -Level "INFO"
    Write-Log -Message "  Resource Group: $ResourceGroupName" -Level "INFO"
    Write-Log -Message "  Location: $Location" -Level "INFO"
    Write-Log -Message "  Address Space: $AddressPrefix" -Level "INFO"

    $defaultTags = @{
        "Environment"  = "Production"
        "Application"  = "Azure Local"
        "ManagedBy"    = "Azure Local Cloud"
        "CreatedDate"  = (Get-Date -Format "yyyy-MM-dd")
    }
    $allTags = $defaultTags + $Tags

    $vnet = New-AzVirtualNetwork `
        -Name $VNetName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -AddressPrefix $AddressPrefix `
        -Subnet $subnetConfigs `
        -Tag $allTags

    Write-Log -Message "Virtual Network created successfully" -Level "SUCCESS"

    # Output results
    Write-Host ""
    Write-Log -Message "VNet Details:" -Level "INFO"
    Write-Host "  Name: $($vnet.Name)"
    Write-Host "  Resource Group: $ResourceGroupName"
    Write-Host "  Location: $($vnet.Location)"
    Write-Host "  Address Space: $($vnet.AddressSpace.AddressPrefixes -join ', ')"
    Write-Host ""
    Write-Log -Message "Subnets Created:" -Level "INFO"
    
    foreach ($subnet in $vnet.Subnets) {
        Write-Host "  - $($subnet.Name): $($subnet.AddressPrefix)"
    }

    # Return VNet object
    return $vnet
}
catch {
    Write-Log -Message "Failed to create Virtual Network: $_" -Level "ERROR"
    throw
}
