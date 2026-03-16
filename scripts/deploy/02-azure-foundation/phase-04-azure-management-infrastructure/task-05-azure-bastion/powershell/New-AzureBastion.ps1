<#
.SYNOPSIS
    Creates an Azure Bastion for secure management access.

.DESCRIPTION
    This script creates an Azure Bastion Host in the AzureBastionSubnet
    for secure RDP/SSH access to Azure VMs without exposing public IPs.

.PARAMETER BastionName
    Name of the Bastion host.

.PARAMETER ResourceGroupName
    Name of the resource group.

.PARAMETER VNetName
    Name of the Virtual Network containing AzureBastionSubnet.

.PARAMETER Location
    Azure region. Default: eastus

.PARAMETER Sku
    Bastion SKU: Basic or Standard. Default: Standard

.EXAMPLE
    .\New-AzureBastion.ps1 -BastionName "bas-azl-prd-eus" -ResourceGroupName "rg-azlmgmt-prd-eus-01" -VNetName "vnet-azrl-mgmt-01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Prerequisites:
    - AzureBastionSubnet must exist with /26 or larger CIDR
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BastionName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VNetName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Basic", "Standard")]
    [string]$Sku = "Standard",

    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{}
)

#Requires -Modules Az.Network

# Import logging helper
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

try {
    Write-Log -Message "Starting Azure Bastion Creation" -Level "INFO"

    # Check if Bastion already exists
    $existingBastion = Get-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName -ErrorAction SilentlyContinue
    if ($existingBastion) {
        Write-Log -Message "Bastion '$BastionName' already exists" -Level "WARN"
        return $existingBastion
    }

    # Get VNet and verify AzureBastionSubnet exists
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    $bastionSubnet = $vnet.Subnets | Where-Object { $_.Name -eq "AzureBastionSubnet" }
    
    if (-not $bastionSubnet) {
        Write-Log -Message "AzureBastionSubnet not found in VNet '$VNetName'" -Level "ERROR"
        Write-Log -Message "Create the subnet first using New-VirtualNetwork.ps1" -Level "ERROR"
        exit 1
    }

    Write-Log -Message "Found AzureBastionSubnet: $($bastionSubnet.AddressPrefix)" -Level "INFO"

    # Create Public IP for Bastion
    $pipName = "pip-$BastionName"
    Write-Log -Message "Creating Public IP: $pipName" -Level "INFO"

    $pipParams = @{
        Name              = $pipName
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        AllocationMethod  = "Static"
        Sku               = "Standard"
        Zone              = @("1", "2", "3")
    }

    $pip = New-AzPublicIpAddress @pipParams

    # Build tags
    $defaultTags = @{
        "Environment"  = "Production"
        "Application"  = "Azure Local"
        "ManagedBy"    = "Azure Local Cloud"
        "CreatedDate"  = (Get-Date -Format "yyyy-MM-dd")
    }
    $allTags = $defaultTags + $Tags

    # Create Bastion
    Write-Log -Message "Creating Azure Bastion (this may take 5-10 minutes)..." -Level "INFO"
    Write-Log -Message "  Name: $BastionName" -Level "INFO"
    Write-Log -Message "  SKU: $Sku" -Level "INFO"
    Write-Log -Message "  VNet: $VNetName" -Level "INFO"

    $bastionParams = @{
        Name              = $BastionName
        ResourceGroupName = $ResourceGroupName
        VirtualNetworkId  = $vnet.Id
        PublicIpAddressId = $pip.Id
        Sku               = $Sku
        Tag               = $allTags
    }

    # Add Standard SKU features
    if ($Sku -eq "Standard") {
        $bastionParams.Add("EnableCopyPaste", $true)
        $bastionParams.Add("EnableFileCopy", $true)
        $bastionParams.Add("EnableIpConnect", $true)
        $bastionParams.Add("EnableShareableLink", $false)
        $bastionParams.Add("EnableTunneling", $true)
        $bastionParams.Add("ScaleUnit", 2)
    }

    $bastion = New-AzBastion @bastionParams

    Write-Log -Message "Azure Bastion created successfully" -Level "SUCCESS"

    # Output details
    Write-Host ""
    Write-Log -Message "Bastion Details:" -Level "INFO"
    Write-Host "  Name: $($bastion.Name)"
    Write-Host "  SKU: $Sku"
    Write-Host "  Public IP: $($pip.IpAddress)"
    Write-Host "  DNS Name: $($bastion.DnsName)"
    
    if ($Sku -eq "Standard") {
        Write-Host ""
        Write-Log -Message "Standard SKU Features Enabled:" -Level "INFO"
        Write-Host "  - Copy/Paste: Yes"
        Write-Host "  - File Copy: Yes"
        Write-Host "  - IP Connect: Yes"
        Write-Host "  - Native Client Tunneling: Yes"
    }

    return $bastion
}
catch {
    Write-Log -Message "Failed to create Azure Bastion: $_" -Level "ERROR"
    throw
}
