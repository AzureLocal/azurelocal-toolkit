<#
.SYNOPSIS
    Creates Network Security Group (NSG) for Opengear Lighthouse VM with restrictive security rules.

.DESCRIPTION
    This script creates an NSG specifically for the Lighthouse VM.
    The NSG implements a deny-by-default outbound policy, allowing only:
    - Outbound HTTPS (443) for Lighthouse Service Portal (LSP) communication
    - Outbound DNS (53) for name resolution
    - Outbound NTP (123) for time synchronization
    - Inbound TCP 8443 for management UI access
    - Inbound TCP 443 for HTTPS web UI access (local management)
    - Inbound TCP 22 for SSH access (administrative)

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers"

.PARAMETER SubscriptionId
    Azure subscription ID where resources are deployed.

.PARAMETER ResourceGroupName
    Resource group containing the Lighthouse VM.

.PARAMETER Location
    Azure region.

.PARAMETER NsgName
    Name of the NSG to create.

.PARAMETER NicName
    Name of the NIC to attach NSG to.

.EXAMPLE
    # Using solution configuration
    .\Deploy-LighthouseNsg.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-LighthouseNsg.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-infra"

.EXAMPLE
    .\Deploy-LighthouseNsg.ps1 -Solution "azure-local" -WhatIf

.NOTES
    Author: Infrastructure Team
    Version: 1.1.0
    Last Updated: 2025-12-07
    
    Security Rationale:
    - Lighthouse VM has public IP and requires internet access for LSP communication
    - Default deny-all outbound prevents unauthorized internet access
    - Only essential ports opened for Lighthouse functionality
    - Management UI (8443) restricted to authorized sources
    - HTTPS (443) inbound for local web management
    - SSH (22) for administrative access
    
    Opengear Lighthouse Service Portal (LSP) Requirements:
    - HTTPS (443) outbound to lighthouse.opengear.com and related cloud endpoints
    - DNS (53) for hostname resolution
    - NTP (123) for time synchronization (critical for SSL/TLS)
    
    Management Access:
    - TCP 8443: Lighthouse management UI (external access)
    - TCP 443: HTTPS web UI (local management)
    - TCP 22: SSH administrative access
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$Location,
    
    [Parameter(Mandatory = $false)]
    [string]$NsgName,
    
    [Parameter(Mandatory = $false)]
    [string]$NicName
)

# Set error action preference
$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
if ($Solution) {
    Write-Host "[Config] Loading solution configuration for: $Solution" -ForegroundColor Cyan
    . "$PSScriptRoot\..\..\..\utilities\helpers\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters - only if not explicitly provided
    if (-not $SubscriptionId) { $SubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscription.id' }
    if (-not $ResourceGroupName) { $ResourceGroupName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.compute.name' }
    if (-not $Location) { $Location = Get-ConfigValue -Config $config -Path 'azure.location' }
    if (-not $NsgName) { $NsgName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.nsgs.lighthouse.name' }
    if (-not $NicName) { $NicName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.lighthouse.nic_name' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $SubscriptionId) { $missingParams += 'SubscriptionId' }
if (-not $ResourceGroupName) { $missingParams += 'ResourceGroupName' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

# Apply defaults for optional parameters
if (-not $Location) { $Location = "eastus2" }
if (-not $NsgName) { $NsgName = "nsg-local-lighthouse-eastus2-001" }
if (-not $NicName) { $NicName = "nic-local-lighthouse-eastus2-001" }

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  Create Lighthouse NSG" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# Authenticate to Azure
Write-Host "[1/5] Authenticating to Azure..." -ForegroundColor Yellow
Connect-AzAccount -Subscription $SubscriptionId | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Host "  ✓ Connected to subscription: $SubscriptionId" -ForegroundColor Green

# Verify resource group exists
Write-Host "[2/5] Verifying resource group exists..." -ForegroundColor Yellow
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    throw "Resource group '$ResourceGroupName' not found. Please create it first."
}
Write-Host "  ✓ Resource group '$ResourceGroupName' found" -ForegroundColor Green

# Create NSG with security rules
Write-Host "[3/5] Creating Network Security Group with rules..." -ForegroundColor Yellow

# Check if NSG already exists
$existingNsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($existingNsg) {
    Write-Host "  ! NSG '$NsgName' already exists. Updating rules..." -ForegroundColor Yellow
    $nsg = $existingNsg
} else {
    # Create new NSG
    if ($PSCmdlet.ShouldProcess($NsgName, "Create Network Security Group")) {
        $nsg = New-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -Location $Location
        Write-Host "  ✓ Created NSG '$NsgName'" -ForegroundColor Green
    }
}

# Define security rules
Write-Host "  Adding security rules..." -ForegroundColor Cyan

# INBOUND RULES

# Allow TCP 8443 for Lighthouse management UI (restricted to specific source - update as needed)
# TODO: Replace * with specific management IP range (e.g., corporate VPN range)
if ($PSCmdlet.ShouldProcess("Allow-Inbound-LighthouseUI-8443", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Inbound-LighthouseUI-8443" `
        -Description "Allow inbound HTTPS on port 8443 for Lighthouse management UI" `
        -Access Allow `
        -Protocol Tcp `
        -Direction Inbound `
        -Priority 100 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange 8443 | Out-Null
    Write-Host "    ✓ Added rule: Allow-Inbound-LighthouseUI-8443 (Priority 100)" -ForegroundColor Green
}

# Allow TCP 443 for HTTPS web UI (local management)
if ($PSCmdlet.ShouldProcess("Allow-Inbound-HTTPS-443", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Inbound-HTTPS-443" `
        -Description "Allow inbound HTTPS on port 443 for web UI" `
        -Access Allow `
        -Protocol Tcp `
        -Direction Inbound `
        -Priority 110 `
        -SourceAddressPrefix "VirtualNetwork" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange 443 | Out-Null
    Write-Host "    ✓ Added rule: Allow-Inbound-HTTPS-443 (Priority 110)" -ForegroundColor Green
}

# Allow TCP 22 for SSH administrative access
if ($PSCmdlet.ShouldProcess("Allow-Inbound-SSH-22", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Inbound-SSH-22" `
        -Description "Allow inbound SSH for administrative access" `
        -Access Allow `
        -Protocol Tcp `
        -Direction Inbound `
        -Priority 120 `
        -SourceAddressPrefix "VirtualNetwork" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange 22 | Out-Null
    Write-Host "    ✓ Added rule: Allow-Inbound-SSH-22 (Priority 120)" -ForegroundColor Green
}

# Deny all other inbound internet traffic (VirtualNetwork/on-prem traffic remains open via default rules)
if ($PSCmdlet.ShouldProcess("Deny-Inbound-Internet", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Deny-Inbound-Internet" `
        -Description "Deny all other inbound traffic from internet (VirtualNetwork and on-prem traffic allowed by default)" `
        -Access Deny `
        -Protocol "*" `
        -Direction Inbound `
        -Priority 4000 `
        -SourceAddressPrefix "Internet" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange "*" | Out-Null
    Write-Host "    ✓ Added rule: Deny-Inbound-Internet (Priority 4000)" -ForegroundColor Green
}

# OUTBOUND RULES

# Allow HTTPS (443) outbound for Lighthouse Service Portal (LSP) communication
if ($PSCmdlet.ShouldProcess("Allow-Outbound-HTTPS-LSP", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-HTTPS-LSP" `
        -Description "Allow outbound HTTPS for Lighthouse Service Portal (LSP) communication to lighthouse.opengear.com" `
        -Access Allow `
        -Protocol Tcp `
        -Direction Outbound `
        -Priority 100 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "Internet" `
        -DestinationPortRange 443 | Out-Null
    Write-Host "    ✓ Added rule: Allow-Outbound-HTTPS-LSP (Priority 100)" -ForegroundColor Green
}

# Allow DNS (53) outbound for name resolution
if ($PSCmdlet.ShouldProcess("Allow-Outbound-DNS", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-DNS" `
        -Description "Allow outbound DNS for name resolution" `
        -Access Allow `
        -Protocol "*" `
        -Direction Outbound `
        -Priority 110 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "Internet" `
        -DestinationPortRange 53 | Out-Null
    Write-Host "    ✓ Added rule: Allow-Outbound-DNS (Priority 110)" -ForegroundColor Green
}

# Allow NTP (123) outbound for time synchronization (critical for SSL/TLS)
if ($PSCmdlet.ShouldProcess("Allow-Outbound-NTP", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-NTP" `
        -Description "Allow outbound NTP for time synchronization (required for SSL/TLS)" `
        -Access Allow `
        -Protocol "Udp" `
        -Direction Outbound `
        -Priority 120 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "Internet" `
        -DestinationPortRange 123 | Out-Null
    Write-Host "    ✓ Added rule: Allow-Outbound-NTP (Priority 120)" -ForegroundColor Green
}

# Allow HTTP (80) outbound for package updates (Ubuntu apt)
if ($PSCmdlet.ShouldProcess("Allow-Outbound-HTazl-Updates", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-HTazl-Updates" `
        -Description "Allow outbound HTTP for Ubuntu package updates (apt)" `
        -Access Allow `
        -Protocol Tcp `
        -Direction Outbound `
        -Priority 130 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "Internet" `
        -DestinationPortRange 80 | Out-Null
    Write-Host "    ✓ Added rule: Allow-Outbound-HTazl-Updates (Priority 130)" -ForegroundColor Green
}

# Deny all other outbound internet traffic (VirtualNetwork/on-prem traffic remains open via default rules)
if ($PSCmdlet.ShouldProcess("Deny-Outbound-Internet", "Add NSG rule")) {
    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Deny-Outbound-Internet" `
        -Description "Deny all other outbound traffic to internet (VirtualNetwork and on-prem traffic allowed by default)" `
        -Access Deny `
        -Protocol "*" `
        -Direction Outbound `
        -Priority 4000 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "Internet" `
        -DestinationPortRange "*" | Out-Null
    Write-Host "    ✓ Added rule: Deny-Outbound-Internet (Priority 4000)" -ForegroundColor Green
}

# Update NSG with all rules
if ($PSCmdlet.ShouldProcess($NsgName, "Update Network Security Group with rules")) {
    $nsg | Set-AzNetworkSecurityGroup | Out-Null
    Write-Host "  ✓ Updated NSG '$NsgName' with security rules" -ForegroundColor Green
}

# Attach NSG to Lighthouse NIC
Write-Host "[4/5] Attaching NSG to Lighthouse NIC..." -ForegroundColor Yellow

$nic = Get-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $nic) {
    Write-Host "  ! NIC '$NicName' not found. NSG created but not attached." -ForegroundColor Yellow
    Write-Host "  ! Run this script again after creating the NIC, or attach manually." -ForegroundColor Yellow
} else {
    # Check if NIC already has an NSG
    if ($nic.NetworkSecurityGroup) {
        Write-Host "  ! NIC '$NicName' already has an NSG attached: $($nic.NetworkSecurityGroup.Id)" -ForegroundColor Yellow
        Write-Host "  ! Replacing with new NSG..." -ForegroundColor Yellow
    }
    
    if ($PSCmdlet.ShouldProcess($NicName, "Attach NSG to NIC")) {
        $nic.NetworkSecurityGroup = $nsg
        $nic | Set-AzNetworkInterface | Out-Null
        Write-Host "  ✓ Attached NSG '$NsgName' to NIC '$NicName'" -ForegroundColor Green
    }
}

# Summary
Write-Host ""
Write-Host "[5/5] Summary" -ForegroundColor Yellow
Write-Host "  NSG Name: $NsgName" -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Cyan
Write-Host "  Location: $Location" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Inbound Rules:" -ForegroundColor Cyan
Write-Host "    - Priority 100: Allow TCP 8443 (Lighthouse management UI)" -ForegroundColor White
Write-Host "    - Priority 110: Allow TCP 443 (HTTPS web UI from VNet)" -ForegroundColor White
Write-Host "    - Priority 120: Allow TCP 22 (SSH from VNet)" -ForegroundColor White
Write-Host "    - Priority 4000: Deny all other inbound internet traffic" -ForegroundColor White
Write-Host ""
Write-Host "  Outbound Rules:" -ForegroundColor Cyan
Write-Host "    - Priority 100: Allow TCP 443 (HTTPS for LSP communication)" -ForegroundColor White
Write-Host "    - Priority 110: Allow UDP/TCP 53 (DNS)" -ForegroundColor White
Write-Host "    - Priority 120: Allow UDP 123 (NTP)" -ForegroundColor White
Write-Host "    - Priority 130: Allow TCP 80 (HTTP for apt updates)" -ForegroundColor White
Write-Host "    - Priority 4000: Deny all other outbound internet traffic" -ForegroundColor White
Write-Host ""
Write-Host "  ⚠️  SECURITY NOTE:" -ForegroundColor Yellow
Write-Host "    - TCP 8443 inbound is currently allowed from ANY (*)" -ForegroundColor Yellow
Write-Host "    - Update rule 'Allow-Inbound-LighthouseUI-8443' to restrict source IP" -ForegroundColor Yellow
Write-Host "    - Recommended: Use specific corporate IP range or VPN gateway IP" -ForegroundColor Yellow
Write-Host ""

if ($WhatIf) {
    Write-Host "✓ WhatIf mode: No changes were made" -ForegroundColor Green
} else {
    Write-Host "✓ NSG creation and attachment completed successfully!" -ForegroundColor Green
}

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Review NSG rules in Azure Portal" -ForegroundColor White
Write-Host "  2. Update TCP 8443 source restriction to specific IP range" -ForegroundColor White
Write-Host "  3. Test Lighthouse connectivity to LSP (lighthouse.opengear.com)" -ForegroundColor White
Write-Host "  4. Verify management UI access on port 8443" -ForegroundColor White
Write-Host "  5. Monitor NSG flow logs for blocked traffic" -ForegroundColor White
Write-Host ""
