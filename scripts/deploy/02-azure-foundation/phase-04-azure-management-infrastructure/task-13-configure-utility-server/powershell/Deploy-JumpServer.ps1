<#
.SYNOPSIS
    Deploys jump server VM for Azure Local infrastructure.

.DESCRIPTION
    This script creates:
    - Jump server VM with static IP address
    
    VM is Windows Server 2025 with static IP address.

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
    .\Deploy-JumpServer.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-JumpServer.ps1 -ManagementSubscriptionId "your-sub-id" -ResourceGroup "rg-infra"
    
.EXAMPLE
    .\Deploy-JumpServer.ps1 -Solution "azure-local" -WhatIf
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

Write-Host "=== Jump Server Deployment ===" -ForegroundColor Cyan
Write-Host "Management Subscription: $ManagementSubscriptionId" -ForegroundColor Gray
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "Location: $Location" -ForegroundColor Gray
Write-Host ""

# Set context to Management subscription
Write-Host "[1/5] Setting subscription context to Management..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
Write-Host "✓ Subscription context set: Management" -ForegroundColor Green

# Get subnet from Management VNet
Write-Host "[2/5] Getting subnet from Management VNet..." -ForegroundColor Yellow
$vnet = Get-AzVirtualNetwork -ResourceGroupName $NetworkResourceGroup -Name $VNetName
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName
$subnetId = $subnet.Id
Write-Host "✓ Subnet ID: $subnetId" -ForegroundColor Green

# Create NIC
Write-Host "[3/5] Creating NIC for jump server..." -ForegroundColor Yellow
$nicName = "nic-local-jump-eastus2-001"
$privateIp = "10.1.0.20"

if ($PSCmdlet.ShouldProcess($nicName, "Create NIC")) {
    $nicParams = @{
        ResourceGroupName = $ResourceGroup
        Name = $nicName
        Location = $Location
        SubnetId = $subnetId
        PrivateIpAddress = $privateIp
        Tag = @{
            "Environment" = "Production"
            "Purpose" = "JumpServer"
            "Role" = "Management"
        }
    }
    $nic = New-AzNetworkInterface @nicParams
    Write-Host "✓ NIC created: $nicName ($privateIp)" -ForegroundColor Green
}

# Create VM
Write-Host "[4/5] Creating VM for jump server..." -ForegroundColor Yellow
$vmName = "vm-local-jump-eastus2-001"
$computerName = "LOCAL-JUMP01"

if ($PSCmdlet.ShouldProcess($vmName, "Create VM")) {
    $securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($AdminUsername, $securePassword)
    
    $vmConfig = New-AzVMConfig -VMName $vmName -VMSize "Standard_D2s_v5"
    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $computerName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Skus "2025-datacenter-azure-edition" -Version "latest"
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable
    
    New-AzVM -ResourceGroupName $ResourceGroup -Location $Location -VM $vmConfig -LicenseType "Windows_Server" -Tag @{
        "Environment" = "Production"
        "Purpose" = "JumpServer"
        "Role" = "Management"
    } | Out-Null
    Write-Host "✓ VM created: $vmName ($computerName)" -ForegroundColor Green
}

# Verify VM
Write-Host "[5/5] Verifying VM deployment..." -ForegroundColor Yellow
if (-not $WhatIfPreference) {
    $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $vmName -Status).Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -ExpandProperty DisplayStatus
    Write-Host "✓ VM Status: $vmStatus" -ForegroundColor Green
} else {
    Write-Host "✓ Verification skipped in WhatIf mode" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Jump Server Deployment Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "VM Created:" -ForegroundColor Cyan
Write-Host "  - $vmName ($computerName) - $privateIp" -ForegroundColor Gray
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Run .\04-deploy-lighthouse.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Bastion RDP Command:" -ForegroundColor Cyan
Write-Host "  az network bastion rdp --name bas-local-connectivity-hub-eastus2-001 \" -ForegroundColor Gray
Write-Host "    --resource-group $ResourceGroup \" -ForegroundColor Gray
Write-Host "    --target-resource-id /subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName" -ForegroundColor Gray
