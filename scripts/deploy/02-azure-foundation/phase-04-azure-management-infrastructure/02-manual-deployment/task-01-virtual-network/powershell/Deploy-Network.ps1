<#
.SYNOPSIS
    Creates infrastructure subnet and NSG for Phoenix Azure Local infrastructure VMs.

.DESCRIPTION
    This script creates:
    - Infrastructure subnet
    - Network Security Group with baseline rules
    - NSG association to subnet

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "azure-arc-servers"

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group name.

.PARAMETER VNetName
    Virtual network name.

.PARAMETER SubnetName
    Infrastructure subnet name.

.PARAMETER SubnetPrefix
    Infrastructure subnet CIDR.

.PARAMETER NsgName
    Network Security Group name.

.PARAMETER Location
    Azure region.

.EXAMPLE
    # Using solution configuration
    .\Deploy-Network.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-Network.ps1 -SubscriptionId "your-sub-id" -VNetName "vnet-hub"
    
.EXAMPLE
    .\Deploy-Network.ps1 -Solution "azure-local" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$VNetName,

    [Parameter(Mandatory = $false)]
    [string]$SubnetName,

    [Parameter(Mandatory = $false)]
    [string]$SubnetPrefix,

    [Parameter(Mandatory = $false)]
    [string]$NsgName,

    [Parameter(Mandatory = $false)]
    [string]$Location
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
if ($Solution) {
    Write-Host "[Config] Loading solution configuration for: $Solution" -ForegroundColor Cyan
    . "$PSScriptRoot\..\..\..\utilities\helpers\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters - only if not explicitly provided
    if (-not $SubscriptionId) { $SubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscriptions.connectivity.id' }
    if (-not $ResourceGroup) { $ResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.connectivity.name' }
    if (-not $VNetName) { $VNetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.hub_vnet.name' }
    if (-not $SubnetName) { $SubnetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.subnets.infrastructure.name' }
    if (-not $SubnetPrefix) { $SubnetPrefix = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.subnets.infrastructure.address_prefix' }
    if (-not $NsgName) { $NsgName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.nsgs.infrastructure.name' }
    if (-not $Location) { $Location = Get-ConfigValue -Config $config -Path 'azure.location' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $SubscriptionId) { $missingParams += 'SubscriptionId' }
if (-not $ResourceGroup) { $missingParams += 'ResourceGroup' }
if (-not $VNetName) { $missingParams += 'VNetName' }
if (-not $Location) { $missingParams += 'Location' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

# Apply defaults for optional parameters
if (-not $SubnetName) { $SubnetName = "snet-infra-001" }
if (-not $SubnetPrefix) { $SubnetPrefix = "10.0.20.0/24" }
if (-not $NsgName) { $NsgName = "nsg-infra-001" }

Write-Host "=== Infrastructure Network Deployment ===" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionId" -ForegroundColor Gray
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "VNet: $VNetName" -ForegroundColor Gray
Write-Host "Subnet: $SubnetName ($SubnetPrefix)" -ForegroundColor Gray
Write-Host "NSG: $NsgName" -ForegroundColor Gray
Write-Host ""

# Set subscription context to Connectivity
Write-Host "[1/5] Setting subscription context to Connectivity..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Host "✓ Subscription context set: Connectivity" -ForegroundColor Green

# Create NSG
Write-Host "[2/5] Creating Network Security Group..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($NsgName, "Create NSG")) {
    # Check if NSG already exists
    $existingNsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    
    if ($existingNsg) {
        Write-Host "✓ NSG already exists: $NsgName" -ForegroundColor Yellow
        $nsg = $existingNsg
    } else {
        $nsg = New-AzNetworkSecurityGroup `
            -ResourceGroupName $ResourceGroup `
            -Name $NsgName `
            -Location $Location `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Infrastructure"
                "ManagedBy" = "PowerShell"
            }
        
        Write-Host "✓ NSG created: $NsgName" -ForegroundColor Green
    }
}

# Create NSG rules
Write-Host "[3/5] Creating NSG rules..." -ForegroundColor Yellow

# Get current NSG to check for existing rules
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $NsgName

# Check if rules already exist
$existingRuleNames = $nsg.SecurityRules | ForEach-Object { $_.Name }
$rulesNeeded = @("AllowRdpFromVNet", "AllowSshFromVNet", "AllowDns", "AllowLdap", "AllowKerberos", "AllowAdReplication")
$missingRules = $rulesNeeded | Where-Object { $_ -notin $existingRuleNames }

if ($missingRules.Count -eq 0) {
    Write-Host "✓ All NSG rules already exist (6 rules)" -ForegroundColor Yellow
} else {
    Write-Host "Adding $($missingRules.Count) missing NSG rules..." -ForegroundColor Cyan
    
    $nsgRules = @()

    if ("AllowRdpFromVNet" -in $missingRules) {
        $nsgRules += New-AzNetworkSecurityRuleConfig `
            -Name "AllowRdpFromVNet" `
            -Priority 100 `
            -SourceAddressPrefix "VirtualNetwork" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix "*" `
            -DestinationPortRange 3389 `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Description "Allow RDP from VNet"
    }

    if ("AllowSshFromVNet" -in $missingRules) {
        $nsgRules += New-AzNetworkSecurityRuleConfig `
            -Name "AllowSshFromVNet" `
            -Priority 110 `
            -SourceAddressPrefix "VirtualNetwork" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix "*" `
            -DestinationPortRange 22 `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Description "Allow SSH from VNet"
    }

    if ("AllowDns" -in $missingRules) {
        $nsgRules += New-AzNetworkSecurityRuleConfig `
            -Name "AllowDns" `
            -Priority 120 `
            -SourceAddressPrefix "*" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix @("10.0.20.10", "10.0.20.11") `
            -DestinationPortRange 53 `
            -Access Allow `
            -Protocol "*" `
            -Direction Inbound `
            -Description "Allow DNS to domain controllers"
    }

    if ("AllowLdap" -in $missingRules) {
        $nsgRules += New-AzNetworkSecurityRuleConfig `
            -Name "AllowLdap" `
            -Priority 130 `
            -SourceAddressPrefix "VirtualNetwork" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix @("10.0.20.10", "10.0.20.11") `
            -DestinationPortRange @(389, 636, 3268, 3269) `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Description "Allow LDAP to domain controllers"
    }

    if ("AllowKerberos" -in $missingRules) {
        $nsgRules += New-AzNetworkSecurityRuleConfig `
            -Name "AllowKerberos" `
            -Priority 140 `
            -SourceAddressPrefix "VirtualNetwork" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix @("10.0.20.10", "10.0.20.11") `
            -DestinationPortRange @(88, 464) `
            -Access Allow `
            -Protocol "*" `
            -Direction Inbound `
            -Description "Allow Kerberos to domain controllers"
    }

    if ("AllowAdReplication" -in $missingRules) {
        $nsgRules += New-AzNetworkSecurityRuleConfig `
            -Name "AllowAdReplication" `
            -Priority 150 `
            -SourceAddressPrefix @("10.0.20.10", "10.0.20.11") `
            -SourcePortRange "*" `
            -DestinationAddressPrefix @("10.0.20.10", "10.0.20.11") `
            -DestinationPortRange @(135, 445) `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Description "Allow AD replication between DCs"
    }

    if ($PSCmdlet.ShouldProcess($NsgName, "Add NSG rules") -and $nsgRules.Count -gt 0) {
        foreach ($rule in $nsgRules) {
            $nsg.SecurityRules.Add($rule)
        }
        Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
        Write-Host "✓ NSG rules created: $($nsgRules.Count) rules" -ForegroundColor Green
    }
}

# Get VNet and create subnet
Write-Host "[4/5] Creating infrastructure subnet..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($SubnetName, "Create subnet")) {
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $VNetName
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $NsgName
    
    # Check if subnet already exists
    $existingSubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName -ErrorAction SilentlyContinue
    
    if ($existingSubnet) {
        Write-Host "✓ Subnet already exists: $SubnetName ($($existingSubnet.AddressPrefix[0]))" -ForegroundColor Green
        
        # Update NSG association if needed
        if ($existingSubnet.NetworkSecurityGroup.Id -ne $nsg.Id) {
            Write-Host "  Updating NSG association..." -ForegroundColor Yellow
            $existingSubnet.NetworkSecurityGroup = $nsg
            Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
            Write-Host "  ✓ NSG association updated" -ForegroundColor Green
        }
    } else {
        Add-AzVirtualNetworkSubnetConfig `
            -Name $SubnetName `
            -VirtualNetwork $vnet `
            -AddressPrefix $SubnetPrefix `
            -NetworkSecurityGroup $nsg | Out-Null
        
        Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
        Write-Host "✓ Subnet created: $SubnetName ($SubnetPrefix)" -ForegroundColor Green
    }
}

# Verify deployment
Write-Host "[5/5] Verifying deployment..." -ForegroundColor Yellow
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $VNetName) -Name $SubnetName
Write-Host "✓ Subnet ID: $($subnet.Id)" -ForegroundColor Green

Write-Host ""
Write-Host "=== Network Deployment Complete ===" -ForegroundColor Green
Write-Host "NSG: $NsgName" -ForegroundColor Gray
Write-Host "Subnet: $SubnetName ($SubnetPrefix)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next: Run .\02-deploy-domain-controllers.ps1" -ForegroundColor Cyan
