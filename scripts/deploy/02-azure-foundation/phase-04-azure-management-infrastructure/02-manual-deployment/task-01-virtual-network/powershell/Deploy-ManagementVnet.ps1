<#
.SYNOPSIS
    Creates VNet in Management subscription for infrastructure VMs.

.DESCRIPTION
    Since NICs cannot reference subnets across subscriptions without VNet peering,
    this script creates a dedicated VNet in the Management subscription for:
    - Domain Controllers
    - Jump Server  
    - Lighthouse Server
    
    This VNet will be peered with the Connectivity VNet.

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "azure-arc-servers"

.PARAMETER ManagementSubscriptionId
    Management subscription ID.

.PARAMETER ResourceGroup
    Resource group name for network resources.

.PARAMETER VNetName
    VNet name.

.PARAMETER Location
    Azure region.

.PARAMETER VNetPrefix
    VNet address prefix.

.PARAMETER InfraSubnetName
    Infrastructure subnet name.

.PARAMETER InfraSubnetPrefix
    Infrastructure subnet prefix.

.PARAMETER NsgName
    Network Security Group name.

.EXAMPLE
    # Using solution configuration
    .\Deploy-ManagementVnet.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-ManagementVnet.ps1 -ManagementSubscriptionId "your-sub-id" -VNetName "vnet-infra"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$ManagementSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$VNetName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$VNetPrefix,

    [Parameter(Mandatory = $false)]
    [string]$InfraSubnetName,

    [Parameter(Mandatory = $false)]
    [string]$InfraSubnetPrefix,

    [Parameter(Mandatory = $false)]
    [string]$NsgName
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
    if (-not $ManagementSubscriptionId) { $ManagementSubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscription.id' }
    if (-not $ResourceGroup) { $ResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.network.name' }
    if (-not $VNetName) { $VNetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.vnet.name' }
    if (-not $Location) { $Location = Get-ConfigValue -Config $config -Path 'azure.location' }
    if (-not $VNetPrefix) { $VNetPrefix = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.vnet.address_prefix' }
    if (-not $InfraSubnetName) { $InfraSubnetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.subnets.infrastructure.name' }
    if (-not $InfraSubnetPrefix) { $InfraSubnetPrefix = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.subnets.infrastructure.address_prefix' }
    if (-not $NsgName) { $NsgName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.nsgs.infrastructure.name' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $ManagementSubscriptionId) { $missingParams += 'ManagementSubscriptionId' }
if (-not $ResourceGroup) { $missingParams += 'ResourceGroup' }
if (-not $VNetName) { $missingParams += 'VNetName' }
if (-not $Location) { $missingParams += 'Location' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

# Apply defaults for optional parameters if not provided
if (-not $VNetPrefix) { $VNetPrefix = "10.1.0.0/16" }
if (-not $InfraSubnetName) { $InfraSubnetName = "snet-infra-001" }
if (-not $InfraSubnetPrefix) { $InfraSubnetPrefix = "10.1.0.0/24" }
if (-not $NsgName) { $NsgName = "nsg-infra-001" }

Write-Host "=== Management VNet Deployment ===" -ForegroundColor Cyan
Write-Host "Subscription: $ManagementSubscriptionId" -ForegroundColor Gray
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "VNet: $VNetName ($VNetPrefix)" -ForegroundColor Gray
Write-Host "Subnet: $InfraSubnetName ($InfraSubnetPrefix)" -ForegroundColor Gray
Write-Host ""

# Set subscription context
Write-Host "[1/4] Setting subscription context to Management..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
Write-Host "✓ Subscription context set: Management" -ForegroundColor Green

# Create resource group
Write-Host "[2/4] Creating resource group..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($ResourceGroup, "Create resource group")) {
    $rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $rg) {
        New-AzResourceGroup -Name $ResourceGroup -Location $Location -Tag @{
            "Environment" = "Production"
            "Purpose" = "Infrastructure"
            "ManagedBy" = "PowerShell"
        } | Out-Null
        Write-Host "✓ Resource group created: $ResourceGroup" -ForegroundColor Green
    } else {
        Write-Host "✓ Resource group already exists: $ResourceGroup" -ForegroundColor Yellow
    }
}

# Create NSG
Write-Host "[3/4] Creating Network Security Group..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($NsgName, "Create NSG")) {
    $existingNsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    
    if ($existingNsg) {
        Write-Host "✓ NSG already exists: $NsgName" -ForegroundColor Yellow
        $nsg = $existingNsg
    } else {
        # Create NSG rules
        $nsgRules = @(
            New-AzNetworkSecurityRuleConfig -Name "AllowRdpFromVNet" -Priority 100 `
                -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
                -DestinationAddressPrefix "*" -DestinationPortRange 3389 `
                -Access Allow -Protocol Tcp -Direction Inbound `
                -Description "Allow RDP from VNet"
            
            New-AzNetworkSecurityRuleConfig -Name "AllowSshFromVNet" -Priority 110 `
                -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
                -DestinationAddressPrefix "*" -DestinationPortRange 22 `
                -Access Allow -Protocol Tcp -Direction Inbound `
                -Description "Allow SSH from VNet"
            
            New-AzNetworkSecurityRuleConfig -Name "AllowDns" -Priority 120 `
                -SourceAddressPrefix "*" -SourcePortRange "*" `
                -DestinationAddressPrefix @("10.1.0.10", "10.1.0.11") -DestinationPortRange 53 `
                -Access Allow -Protocol "*" -Direction Inbound `
                -Description "Allow DNS to domain controllers"
            
            New-AzNetworkSecurityRuleConfig -Name "AllowLdap" -Priority 130 `
                -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
                -DestinationAddressPrefix @("10.1.0.10", "10.1.0.11") -DestinationPortRange @(389, 636, 3268, 3269) `
                -Access Allow -Protocol Tcp -Direction Inbound `
                -Description "Allow LDAP to domain controllers"
            
            New-AzNetworkSecurityRuleConfig -Name "AllowKerberos" -Priority 140 `
                -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
                -DestinationAddressPrefix @("10.1.0.10", "10.1.0.11") -DestinationPortRange @(88, 464) `
                -Access Allow -Protocol "*" -Direction Inbound `
                -Description "Allow Kerberos to domain controllers"
            
            New-AzNetworkSecurityRuleConfig -Name "AllowAdReplication" -Priority 150 `
                -SourceAddressPrefix @("10.1.0.10", "10.1.0.11") -SourcePortRange "*" `
                -DestinationAddressPrefix @("10.1.0.10", "10.1.0.11") -DestinationPortRange @(135, 445) `
                -Access Allow -Protocol Tcp -Direction Inbound `
                -Description "Allow AD replication between DCs"
        )
        
        $nsg = New-AzNetworkSecurityGroup `
            -ResourceGroupName $ResourceGroup `
            -Name $NsgName `
            -Location $Location `
            -SecurityRules $nsgRules `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Infrastructure"
                "ManagedBy" = "PowerShell"
            }
        
        Write-Host "✓ NSG created: $NsgName with 6 rules" -ForegroundColor Green
    }
}

# Create VNet with subnet
Write-Host "[4/4] Creating VNet and subnet..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($VNetName, "Create VNet")) {
    $existingVNet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    
    if ($existingVNet) {
        Write-Host "✓ VNet already exists: $VNetName" -ForegroundColor Yellow
    } else {
        # Create subnet configuration
        $subnetConfig = New-AzVirtualNetworkSubnetConfig `
            -Name $InfraSubnetName `
            -AddressPrefix $InfraSubnetPrefix `
            -NetworkSecurityGroup $nsg
        
        # Create VNet
        $vnet = New-AzVirtualNetwork `
            -ResourceGroupName $ResourceGroup `
            -Name $VNetName `
            -Location $Location `
            -AddressPrefix $VNetPrefix `
            -Subnet $subnetConfig `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Infrastructure"
                "ManagedBy" = "PowerShell"
            }
        
        Write-Host "✓ VNet created: $VNetName ($VNetPrefix)" -ForegroundColor Green
        Write-Host "✓ Subnet created: $InfraSubnetName ($InfraSubnetPrefix)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== Management VNet Deployment Complete ===" -ForegroundColor Green
Write-Host "VNet: $VNetName ($VNetPrefix)" -ForegroundColor Gray
Write-Host "Subnet: $InfraSubnetName ($InfraSubnetPrefix)" -ForegroundColor Gray
Write-Host "NSG: $NsgName" -ForegroundColor Gray
Write-Host ""
Write-Host "Next: Update 02-deploy-domain-controllers.ps1 to use this VNet" -ForegroundColor Cyan
