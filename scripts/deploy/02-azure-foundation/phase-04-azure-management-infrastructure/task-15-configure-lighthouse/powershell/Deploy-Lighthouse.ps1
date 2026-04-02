<#
.SYNOPSIS
    Deploys Lighthouse server VM for Phoenix Azure Local infrastructure.

.DESCRIPTION
    This script creates:
    - Lighthouse server VM with static private IP and public IP for Opengear Lighthouse.
    
    VM is Ubuntu 22.04 LTS with static private IP and public IP for Opengear Lighthouse.

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "azure-arc-servers"

.PARAMETER ManagementSubscriptionId
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group name for compute resources.

.PARAMETER NetworkResourceGroup
    Resource group name for network resources.

.PARAMETER Location
    Azure region.

.PARAMETER SubnetName
    Infrastructure subnet name.

.PARAMETER VNetName
    Virtual network name.

.PARAMETER AdminUsername
    VM administrator username.

.PARAMETER AdminPassword
    VM administrator password.

.EXAMPLE
    # Using solution configuration
    .\Deploy-Lighthouse.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-Lighthouse.ps1 -ManagementSubscriptionId "your-sub-id" -ResourceGroup "rg-infra"
    
.EXAMPLE
    .\Deploy-Lighthouse.ps1 -Solution "azure-local" -WhatIf
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
    [string]$NetworkResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$SubnetName,

    [Parameter(Mandatory = $false)]
    [string]$VNetName,

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername,

    [Parameter(Mandatory = $false)]
    [string]$AdminPassword
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
    if (-not $ResourceGroup) { $ResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.compute.name' }
    if (-not $NetworkResourceGroup) { $NetworkResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.network.name' }
    if (-not $Location) { $Location = Get-ConfigValue -Config $config -Path 'azure.location' }
    if (-not $SubnetName) { $SubnetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.subnets.infrastructure.name' }
    if (-not $VNetName) { $VNetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.vnet.name' }
    if (-not $AdminUsername) { $AdminUsername = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.admin_username' }
    if (-not $AdminPassword) { $AdminPassword = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.admin_password' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $ManagementSubscriptionId) { $missingParams += 'ManagementSubscriptionId' }
if (-not $ResourceGroup) { $missingParams += 'ResourceGroup' }
if (-not $NetworkResourceGroup) { $missingParams += 'NetworkResourceGroup' }
if (-not $Location) { $missingParams += 'Location' }
if (-not $SubnetName) { $missingParams += 'SubnetName' }
if (-not $VNetName) { $missingParams += 'VNetName' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

Write-Host "=== Lighthouse Server Deployment ===" -ForegroundColor Cyan
Write-Host "Management Subscription: $ManagementSubscriptionId" -ForegroundColor Gray
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "Location: $Location" -ForegroundColor Gray
Write-Host ""

# Set context to Management subscription
Write-Host "[1/6] Setting subscription context to Management..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
Write-Host "✓ Subscription context set: Management" -ForegroundColor Green

# Get subnet from Management VNet
Write-Host "[2/6] Getting subnet from Management VNet..." -ForegroundColor Yellow
$vnet = Get-AzVirtualNetwork -ResourceGroupName $NetworkResourceGroup -Name $VNetName
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName
$subnetId = $subnet.Id
Write-Host "✓ Subnet ID: $subnetId" -ForegroundColor Green

# Create public IP
Write-Host "[3/6] Creating public IP for Lighthouse..." -ForegroundColor Yellow
$publicIpName = "pip-local-lighthouse-eastus2-001"

if ($PSCmdlet.ShouldProcess($publicIpName, "Create public IP")) {
    $publicIp = New-AzPublicIpAddress `
        -ResourceGroupName $ResourceGroup `
        -Name $publicIpName `
        -Location $Location `
        -AllocationMethod Static `
        -Sku Standard `
        -IpAddressVersion IPv4 `
        -Tag @{
            "Environment" = "Production"
            "Purpose" = "Lighthouse"
            "Role" = "Management"
        }
    
    Write-Host "✓ Public IP created: $publicIpName ($($publicIp.IpAddress))" -ForegroundColor Green
}

# Create NSG with security rules
Write-Host "[4/7] Creating Network Security Group for Lighthouse..." -ForegroundColor Yellow
$nsgName = "nsg-local-lighthouse-eastus2-001"

if ($PSCmdlet.ShouldProcess($nsgName, "Create NSG")) {
    # Check if NSG already exists
    $existingNsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    
    if ($existingNsg) {
        Write-Host "  NSG already exists, using existing: $nsgName" -ForegroundColor Yellow
        $nsg = $existingNsg
    } else {
        # Create NSG
        $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroup -Location $Location -Tag @{
            "Environment" = "Production"
            "Purpose" = "Lighthouse"
            "Role" = "Security"
        }
        
        # INBOUND RULES
        
        # Allow TCP 8443 for Lighthouse management UI
        # TODO: Restrict source to specific management IP range
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Inbound-LighthouseUI-8443" `
            -Description "Allow inbound HTTPS on port 8443 for Lighthouse management UI" `
            -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
            -SourceAddressPrefix "*" -SourcePortRange "*" `
            -DestinationAddressPrefix "*" -DestinationPortRange 8443 | Out-Null
        
        # Allow TCP 443 for HTTPS web UI (from VNet only)
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Inbound-HTTPS-443" `
            -Description "Allow inbound HTTPS on port 443 for web UI" `
            -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 `
            -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
            -DestinationAddressPrefix "*" -DestinationPortRange 443 | Out-Null
        
        # Allow TCP 22 for SSH (from VNet only)
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Inbound-SSH-22" `
            -Description "Allow inbound SSH for administrative access" `
            -Access Allow -Protocol Tcp -Direction Inbound -Priority 120 `
            -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
            -DestinationAddressPrefix "*" -DestinationPortRange 22 | Out-Null
        
        # Deny all other inbound internet traffic (VirtualNetwork/on-prem traffic remains open)
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Deny-Inbound-Internet" `
            -Description "Deny all other inbound traffic from internet (VirtualNetwork and on-prem traffic allowed by default)" `
            -Access Deny -Protocol "*" -Direction Inbound -Priority 4000 `
            -SourceAddressPrefix "Internet" -SourcePortRange "*" `
            -DestinationAddressPrefix "*" -DestinationPortRange "*" | Out-Null
        
        # OUTBOUND RULES
        
        # Allow HTTPS (443) for Lighthouse Service Portal (LSP)
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-HTTPS-LSP" `
            -Description "Allow outbound HTTPS for Lighthouse Service Portal (LSP) communication" `
            -Access Allow -Protocol Tcp -Direction Outbound -Priority 100 `
            -SourceAddressPrefix "*" -SourcePortRange "*" `
            -DestinationAddressPrefix "Internet" -DestinationPortRange 443 | Out-Null
        
        # Allow DNS (53) for name resolution
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-DNS" `
            -Description "Allow outbound DNS for name resolution" `
            -Access Allow -Protocol "*" -Direction Outbound -Priority 110 `
            -SourceAddressPrefix "*" -SourcePortRange "*" `
            -DestinationAddressPrefix "Internet" -DestinationPortRange 53 | Out-Null
        
        # Allow NTP (123) for time synchronization
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-NTP" `
            -Description "Allow outbound NTP for time synchronization (required for SSL/TLS)" `
            -Access Allow -Protocol "Udp" -Direction Outbound -Priority 120 `
            -SourceAddressPrefix "*" -SourcePortRange "*" `
            -DestinationAddressPrefix "Internet" -DestinationPortRange 123 | Out-Null
        
        # Allow HTTP (80) for package updates
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-Outbound-HTazl-Updates" `
            -Description "Allow outbound HTTP for Ubuntu package updates (apt)" `
            -Access Allow -Protocol Tcp -Direction Outbound -Priority 130 `
            -SourceAddressPrefix "*" -SourcePortRange "*" `
            -DestinationAddressPrefix "Internet" -DestinationPortRange 80 | Out-Null
        
        # Deny all other outbound internet traffic (VirtualNetwork/on-prem traffic remains open)
        $nsg | Add-AzNetworkSecurityRuleConfig -Name "Deny-Outbound-Internet" `
            -Description "Deny all other outbound traffic to internet (VirtualNetwork and on-prem traffic allowed by default)" `
            -Access Deny -Protocol "*" -Direction Outbound -Priority 4000 `
            -SourceAddressPrefix "*" -SourcePortRange "*" `
            -DestinationAddressPrefix "Internet" -DestinationPortRange "*" | Out-Null
        
        # Apply all rules
        $nsg | Set-AzNetworkSecurityGroup | Out-Null
        Write-Host "✓ NSG created with security rules: $nsgName" -ForegroundColor Green
    }
}

# Create NIC with NSG attached
Write-Host "[5/7] Creating NIC for Lighthouse..." -ForegroundColor Yellow
$nicName = "nic-local-lighthouse-eastus2-001"
$privateIp = "10.1.0.30"

if ($PSCmdlet.ShouldProcess($nicName, "Create NIC")) {
    $publicIp = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $publicIpName
    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroup
    
    $nicParams = @{
        ResourceGroupName = $ResourceGroup
        Name = $nicName
        Location = $Location
        SubnetId = $subnetId
        PrivateIpAddress = $privateIp
        PublicIpAddressId = $publicIp.Id
        NetworkSecurityGroupId = $nsg.Id
        Tag = @{
            "Environment" = "Production"
            "Purpose" = "Lighthouse"
            "Role" = "Management"
        }
    }
    $nic = New-AzNetworkInterface @nicParams
    Write-Host "✓ NIC created with NSG attached: $nicName ($privateIp)" -ForegroundColor Green
}

# Create VM
Write-Host "[6/7] Creating VM for Lighthouse..." -ForegroundColor Yellow
$vmName = "vm-local-lighthouse-eastus2-001"
$computerName = "local-lighthouse01"

if ($PSCmdlet.ShouldProcess($vmName, "Create VM")) {
    $securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($AdminUsername, $securePassword)
    
    $vmConfig = New-AzVMConfig -VMName $vmName -VMSize "Standard_D2s_v5"
    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $computerName -Credential $cred -DisablePasswordAuthentication:$false
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "Canonical" -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest"
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable
    
    New-AzVM -ResourceGroupName $ResourceGroup -Location $Location -VM $vmConfig -Tag @{
        "Environment" = "Production"
        "Purpose" = "Lighthouse"
        "Role" = "Management"
    } | Out-Null
    Write-Host "✓ VM created: $vmName ($computerName)" -ForegroundColor Green
}

# Verify VM
Write-Host "[7/7] Verifying VM deployment..." -ForegroundColor Yellow
if (-not $WhatIfPreference) {
    $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $vmName -Status).Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -ExpandProperty DisplayStatus
    Write-Host "✓ VM Status: $vmStatus" -ForegroundColor Green
    
    $publicIp = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $publicIpName
    $publicIpAddress = $publicIp.IpAddress
} else {
    Write-Host "✓ Verification skipped in WhatIf mode" -ForegroundColor Green
    $publicIpAddress = "<will be assigned>"
}

Write-Host ""
Write-Host "=== Lighthouse Server Deployment Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "VM Created:" -ForegroundColor Cyan
Write-Host "  - $vmName ($computerName)" -ForegroundColor Gray
Write-Host "  - Private IP: $privateIp" -ForegroundColor Gray
Write-Host "  - Public IP: $publicIpAddress" -ForegroundColor Gray
Write-Host "  - NSG: $nsgName (attached)" -ForegroundColor Gray
Write-Host ""
Write-Host "NSG Security Rules:" -ForegroundColor Cyan
Write-Host "  Inbound:" -ForegroundColor Gray
Write-Host "    - TCP 8443: Lighthouse management UI (from ANY - restrict this!)" -ForegroundColor Yellow
Write-Host "    - TCP 443: HTTPS web UI (from VNet only)" -ForegroundColor Gray
Write-Host "    - TCP 22: SSH administrative access (from VNet only)" -ForegroundColor Gray
Write-Host "    - All VNet/on-prem traffic: ALLOWED (wide open)" -ForegroundColor Green
Write-Host "  Outbound:" -ForegroundColor Gray
Write-Host "    - TCP 443: HTTPS for LSP communication (lighthouse.opengear.com)" -ForegroundColor Gray
Write-Host "    - UDP/TCP 53: DNS for name resolution" -ForegroundColor Gray
Write-Host "    - UDP 123: NTP for time synchronization" -ForegroundColor Gray
Write-Host "    - TCP 80: HTTP for Ubuntu package updates" -ForegroundColor Gray
Write-Host "    - All VNet/on-prem traffic: ALLOWED (wide open)" -ForegroundColor Green
Write-Host "    - All other internet traffic: DENIED" -ForegroundColor Gray
Write-Host ""
Write-Host "⚠️  SECURITY WARNING:" -ForegroundColor Yellow
Write-Host "  TCP 8443 is currently open from ANY (*). Update the NSG rule to restrict" -ForegroundColor Yellow
Write-Host "  source to specific management IP range (corporate VPN, jump box, etc.)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. All infrastructure VMs deployed!" -ForegroundColor Gray
Write-Host "  2. RDP to DC01 via Bastion and run .\ad-config\01-promote-primary-dc.ps1" -ForegroundColor Gray
Write-Host "  3. RDP to DC02 via Bastion and run .\ad-config\02-promote-replica-dc.ps1" -ForegroundColor Gray
Write-Host "  4. SSH to Lighthouse and install Opengear Lighthouse" -ForegroundColor Gray
Write-Host ""
Write-Host "Connect via Azure Portal Bastion:" -ForegroundColor Cyan
Write-Host "  - Navigate to $vmName in Azure Portal" -ForegroundColor Gray
Write-Host "  - Click Connect -> Bastion" -ForegroundColor Gray
Write-Host "  - Username: $AdminUsername" -ForegroundColor Gray
Write-Host ""
Write-Host "    --resource-group $ResourceGroup \" -ForegroundColor Gray
Write-Host "    --target-resource-id /subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName \" -ForegroundColor Gray
Write-Host "    --auth-type password --username $AdminUsername" -ForegroundColor Gray
Write-Host ""
Write-Host "Or SSH directly to public IP:" -ForegroundColor Cyan
Write-Host "  ssh $AdminUsername@$publicIpAddress" -ForegroundColor Gray
