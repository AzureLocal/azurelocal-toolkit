<#
.SYNOPSIS
    Configures VNet DNS settings to use domain controllers and sets up DNS forwarders on DCs.

.DESCRIPTION
    This script performs the following:
    1. Updates VNet DNS settings to point to domain controllers (10.1.0.10, 10.1.0.11)
    2. Configures DNS forwarders on both DCs to Azure recursive resolver (168.63.129.16)
    3. Sets forwarder timeout to 5 seconds (required for Azure DNS)
    4. Restarts DNS service on DCs
    5. Renews DHCP leases on all VMs in the VNet

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers"

.PARAMETER ManagementSubscriptionId
    Azure subscription ID for management resources.

.PARAMETER NetworkResourceGroup
    Resource group containing the VNet.

.PARAMETER ComputeResourceGroup
    Resource group containing the compute resources.

.PARAMETER VNetName
    Virtual network name.

.PARAMETER DC01IP
    Primary DC IP address.

.PARAMETER DC02IP
    Replica DC IP address.

.PARAMETER AdminUsername
    VM administrator username.

.PARAMETER AdminPassword
    VM administrator password.

.EXAMPLE
    # Using solution configuration
    .\Configure-VnetDns.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Configure-VnetDns.ps1 -ManagementSubscriptionId "your-sub-id" -NetworkResourceGroup "rg-network"
    
.EXAMPLE
    .\Configure-VnetDns.ps1 -Solution "azure-local" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$ManagementSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$NetworkResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$ComputeResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$VNetName,

    [Parameter(Mandatory = $false)]
    [string]$DC01IP,

    [Parameter(Mandatory = $false)]
    [string]$DC02IP,

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
    if (-not $NetworkResourceGroup) { $NetworkResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.network.name' }
    if (-not $ComputeResourceGroup) { $ComputeResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.compute.name' }
    if (-not $VNetName) { $VNetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.vnet.name' }
    if (-not $DC01IP) { $DC01IP = Get-ConfigValue -Config $config -Path 'azure_infrastructure.domain_controllers.dc01.ip_address' }
    if (-not $DC02IP) { $DC02IP = Get-ConfigValue -Config $config -Path 'azure_infrastructure.domain_controllers.dc02.ip_address' }
    if (-not $AdminUsername) { $AdminUsername = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.admin_username' }
    if (-not $AdminPassword) { $AdminPassword = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.admin_password' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $ManagementSubscriptionId) { $missingParams += 'ManagementSubscriptionId' }
if (-not $NetworkResourceGroup) { $missingParams += 'NetworkResourceGroup' }
if (-not $ComputeResourceGroup) { $missingParams += 'ComputeResourceGroup' }
if (-not $VNetName) { $missingParams += 'VNetName' }
if (-not $DC01IP) { $missingParams += 'DC01IP' }
if (-not $DC02IP) { $missingParams += 'DC02IP' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

Write-Host "=== VNet DNS Configuration for Domain Controllers ===" -ForegroundColor Cyan
Write-Host "Management Subscription: $ManagementSubscriptionId" -ForegroundColor Gray
Write-Host "VNet: $VNetName" -ForegroundColor Gray
Write-Host "Primary DC: $DC01IP" -ForegroundColor Gray
Write-Host "Replica DC: $DC02IP" -ForegroundColor Gray
Write-Host ""

# Set subscription context
Write-Host "[1/5] Setting Azure subscription context..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
Write-Host "✓ Context set to Management subscription" -ForegroundColor Green

# Update VNet DNS settings
Write-Host "[2/5] Updating VNet DNS settings to use domain controllers..." -ForegroundColor Yellow
$vnet = Get-AzVirtualNetwork -ResourceGroupName $NetworkResourceGroup -Name $VNetName

if ($PSCmdlet.ShouldProcess($VNetName, "Update DNS servers to [$DC01IP, $DC02IP]")) {
    $vnet.DhcpOptions.DnsServers = @($DC01IP, $DC02IP)
    Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
    Write-Host "✓ VNet DNS servers configured: $DC01IP (primary), $DC02IP (secondary)" -ForegroundColor Green
}

# Configure DNS forwarders on DC01
Write-Host "[3/5] Configuring DNS forwarder on DC01..." -ForegroundColor Yellow
$dc01ConfigScript = @'
# Configure DNS forwarder to Azure recursive resolver
$azureDns = "168.63.129.16"
$existingForwarders = Get-DnsServerForwarder | Select-Object -ExpandProperty IPAddress

if ($existingForwarders.IPAddressToString -notcontains $azureDns) {
    Add-DnsServerForwarder -IPAddress $azureDns -PassThru | Out-Null
    Write-Host "Added Azure DNS forwarder: $azureDns"
} else {
    Write-Host "Azure DNS forwarder already configured: $azureDns"
}

# Set forwarder timeout to 5 seconds (required for Azure DNS)
Set-DnsServerForwarder -Timeout 5 -UseRootHint $false
Write-Host "Forwarder timeout set to 5 seconds"

# Restart DNS service
Restart-Service -Name DNS -Force
Write-Host "DNS service restarted"
'@

if ($PSCmdlet.ShouldProcess("DC01", "Configure DNS forwarder")) {
    $securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($AdminUsername, $securePassword)
    
    # Note: VM name should come from solution config (e.g., vm-dc01)
    Invoke-AzVMRunCommand -ResourceGroupName $ComputeResourceGroup -VMName "vm-dc01" `
        -CommandId 'RunPowerShellScript' -ScriptString $dc01ConfigScript | Out-Null
    Write-Host "✓ DNS forwarder configured on DC01" -ForegroundColor Green
}

# Configure DNS forwarders on DC02
Write-Host "[4/5] Configuring DNS forwarder on DC02..." -ForegroundColor Yellow
$dc02ConfigScript = @'
# Configure DNS forwarder to Azure recursive resolver
$azureDns = "168.63.129.16"
$existingForwarders = Get-DnsServerForwarder | Select-Object -ExpandProperty IPAddress

if ($existingForwarders.IPAddressToString -notcontains $azureDns) {
    Add-DnsServerForwarder -IPAddress $azureDns -PassThru | Out-Null
    Write-Host "Added Azure DNS forwarder: $azureDns"
} else {
    Write-Host "Azure DNS forwarder already configured: $azureDns"
}

# Set forwarder timeout to 5 seconds (required for Azure DNS)
Set-DnsServerForwarder -Timeout 5 -UseRootHint $false
Write-Host "Forwarder timeout set to 5 seconds"

# Restart DNS service
Restart-Service -Name DNS -Force
Write-Host "DNS service restarted"
'@

if ($PSCmdlet.ShouldProcess("DC02", "Configure DNS forwarder")) {
    # Note: VM name should come from solution config (e.g., vm-dc02)
    Invoke-AzVMRunCommand -ResourceGroupName $ComputeResourceGroup -VMName "vm-dc02" `
        -CommandId 'RunPowerShellScript' -ScriptString $dc02ConfigScript | Out-Null
    Write-Host "✓ DNS forwarder configured on DC02" -ForegroundColor Green
}

# Renew DHCP leases on all VMs
Write-Host "[5/5] Renewing DHCP leases on all VMs in VNet..." -ForegroundColor Yellow
$renewScript = @'
ipconfig /renew
Write-Host "DHCP lease renewed"
'@

if ($PSCmdlet.ShouldProcess("All VMs", "Renew DHCP leases")) {
    $vms = Get-AzVM -ResourceGroupName $ComputeResourceGroup | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Windows" }
    
    foreach ($vm in $vms) {
        Write-Host "  Renewing DHCP lease on $($vm.Name)..." -ForegroundColor Gray
        Invoke-AzVMRunCommand -ResourceGroupName $ComputeResourceGroup -VMName $vm.Name `
            -CommandId 'RunPowerShellScript' -ScriptString $renewScript | Out-Null
    }
    Write-Host "✓ DHCP leases renewed on all VMs" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== VNet DNS Configuration Complete ===" -ForegroundColor Green
Write-Host "VNet DNS servers: $DC01IP, $DC02IP" -ForegroundColor Green
Write-Host "DNS forwarder on DCs: 168.63.129.16 (Azure recursive resolver)" -ForegroundColor Green
Write-Host "Forwarder timeout: 5 seconds" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Verify DNS resolution from VMs: nslookup LOCAL-DC01.hybrid.mgmt" -ForegroundColor Gray
Write-Host "2. Verify Azure DNS resolution: nslookup www.microsoft.com" -ForegroundColor Gray
Write-Host "3. Check NSG rules allow port 53 (UDP/TCP) to DCs" -ForegroundColor Gray
