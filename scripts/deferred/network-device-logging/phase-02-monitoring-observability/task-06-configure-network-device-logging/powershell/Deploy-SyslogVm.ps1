#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy Ubuntu syslog/SNMP collector VM for Azure Local infrastructure

.DESCRIPTION
    Creates a Ubuntu 24.04 LTS VM in the infrastructure resource group
    to serve as centralized syslog and SNMP trap collector.

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "azure-arc-servers"

.PARAMETER SubscriptionName
    Azure subscription name.

.PARAMETER ResourceGroup
    Resource group name for compute resources.

.PARAMETER NetworkResourceGroup
    Resource group name for network resources.

.PARAMETER Location
    Azure region.

.PARAMETER VmName
    Name of the VM to create.

.PARAMETER VNetName
    Virtual network name.

.PARAMETER SubnetName
    Subnet name.

.PARAMETER PrivateIP
    Private IP address for the VM.

.PARAMETER AdminUsername
    VM administrator username.

.PARAMETER AdminPassword
    VM administrator password.

.EXAMPLE
    # Using solution configuration
    .\Deploy-SyslogVm.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters (legacy)
    .\Deploy-SyslogVm.ps1

.NOTES
    Created: 2025-12-03
    Updated: 2025-12-07 - Added Solution parameter support
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$NetworkResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$VNetName,

    [Parameter(Mandatory = $false)]
    [string]$SubnetName,

    [Parameter(Mandatory = $false)]
    [string]$PrivateIP,

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername,

    [Parameter(Mandatory = $false)]
    [string]$AdminPassword
)

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
if ($Solution) {
    Write-Host "[Config] Loading solution configuration for: $Solution" -ForegroundColor Cyan
    . "$PSScriptRoot\..\..\..\utilities\helpers\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters - only if not explicitly provided
    if (-not $SubscriptionName) { $SubscriptionName = Get-ConfigValue -Config $config -Path 'azure.subscription.name' }
    if (-not $ResourceGroup) { $ResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.compute.name' }
    if (-not $NetworkResourceGroup) { $NetworkResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.network.name' }
    if (-not $Location) { $Location = Get-ConfigValue -Config $config -Path 'azure.location' }
    if (-not $VmName) { $VmName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.syslog.name' }
    if (-not $VNetName) { $VNetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.vnet.name' }
    if (-not $SubnetName) { $SubnetName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.networking.subnets.infrastructure.name' }
    if (-not $PrivateIP) { $PrivateIP = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.syslog.ip_address' }
    if (-not $AdminUsername) { $AdminUsername = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.admin_username' }
    if (-not $AdminPassword) { $AdminPassword = Get-ConfigValue -Config $config -Path 'azure_infrastructure.virtual_machines.admin_password' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
} else {
    # No defaults - require explicit parameters
    Write-Host "[ERROR] -Solution parameter is required, or provide all parameters explicitly" -ForegroundColor Red
    Write-Host "Required parameters when not using -Solution:" -ForegroundColor Yellow
    Write-Host "  -SubscriptionName, -ResourceGroup, -NetworkResourceGroup" -ForegroundColor Gray
    Write-Host "  -Location, -VmName, -VNetName, -SubnetName" -ForegroundColor Gray
    Write-Host "  -PrivateIP, -AdminUsername, -AdminPassword" -ForegroundColor Gray
    throw "Missing required parameters. Use -Solution or provide all parameters."
}

# Validate required parameters
$missingParams = @()
if (-not $SubscriptionName) { $missingParams += 'SubscriptionName' }
if (-not $ResourceGroup) { $missingParams += 'ResourceGroup' }
if (-not $VmName) { $missingParams += 'VmName' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

# Derived variables
$computerName = "local-syslog01"
$vmSize = "Standard_D2s_v5"
$osDiskSize = 128
$dataDiskSize = 256
$dataDiskName = "${VmName}-datadisk-001"
$nicName = "${VmName}-nic"
$nsgName = "${VmName}-nsg"

# Ubuntu 24.04 LTS image details
$imagePublisher = "Canonical"
$imageOffer = "ubuntu-24_04-lts"
$imageSku = "server"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Ubuntu Syslog/SNMP Collector VM Deployment" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Set subscription context
Write-Host "[1/8] Setting subscription context..." -ForegroundColor Yellow
az account set --subscription $subscriptionName
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to set subscription context" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Subscription: $subscriptionName" -ForegroundColor Green

# Create Network Security Group
Write-Host ""
Write-Host "[2/8] Creating Network Security Group..." -ForegroundColor Yellow
az network nsg create `
    --resource-group $resourceGroup `
    --name $nsgName `
    --location $location `
    --tags "Purpose=Syslog-SNMP-Collector" "ManagedBy=HybridCloudSolutions" "Environment=Production"

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create NSG" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ NSG created: $nsgName" -ForegroundColor Green

# Add NSG rules
Write-Host ""
Write-Host "[3/8] Configuring NSG rules..." -ForegroundColor Yellow

# Syslog UDP 514
az network nsg rule create `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name "Allow-Syslog-UDP" `
    --priority 100 `
    --source-address-prefixes "192.168.100.0/24" "192.168.150.0/24" "192.168.200.0/24" "10.1.0.0/24" `
    --destination-port-ranges 514 `
    --protocol Udp `
    --access Allow `
    --direction Inbound `
    --description "Allow syslog traffic from infrastructure networks"

# SNMP Traps UDP 162
az network nsg rule create `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name "Allow-SNMP-Traps-UDP" `
    --priority 110 `
    --source-address-prefixes "192.168.100.0/24" "192.168.150.0/24" "192.168.200.0/24" "10.1.0.0/24" `
    --destination-port-ranges 162 `
    --protocol Udp `
    --access Allow `
    --direction Inbound `
    --description "Allow SNMP traps from infrastructure networks"

# SSH TCP 22
az network nsg rule create `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name "Allow-SSH-TCP" `
    --priority 120 `
    --source-address-prefixes "10.1.0.0/24" `
    --destination-port-ranges 22 `
    --protocol Tcp `
    --access Allow `
    --direction Inbound `
    --description "Allow SSH from Azure management subnet"

# Optional: Syslog-ng TLS TCP 601
az network nsg rule create `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name "Allow-Syslog-TLS-TCP" `
    --priority 130 `
    --source-address-prefixes "10.1.0.0/24" `
    --destination-port-ranges 601 `
    --protocol Tcp `
    --access Allow `
    --direction Inbound `
    --description "Allow syslog TLS from Azure management subnet"

Write-Host "  ✓ NSG rules configured" -ForegroundColor Green

# Create Network Interface
Write-Host ""
Write-Host "[4/8] Creating Network Interface..." -ForegroundColor Yellow

# Get subnet ID from the network resource group
$subnetId = az network vnet subnet show `
    --resource-group $networkResourceGroup `
    --vnet-name $vnetName `
    --name $subnetName `
    --query id `
    --output tsv

az network nic create `
    --resource-group $resourceGroup `
    --name $nicName `
    --location $location `
    --subnet $subnetId `
    --private-ip-address $privateIP `
    --network-security-group $nsgName `
    --ip-forwarding false `
    --tags "Purpose=Syslog-SNMP-Collector" "ManagedBy=HybridCloudSolutions"

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create NIC" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ NIC created: $nicName (IP: $privateIP)" -ForegroundColor Green

# Create VM
Write-Host ""
Write-Host "[5/8] Creating Ubuntu VM..." -ForegroundColor Yellow
Write-Host "  VM Name: $vmName" -ForegroundColor Cyan
Write-Host "  Computer Name: $computerName" -ForegroundColor Cyan
Write-Host "  Size: $vmSize" -ForegroundColor Cyan
Write-Host "  OS Disk: $osDiskSize GB Premium SSD" -ForegroundColor Cyan

az vm create `
    --resource-group $resourceGroup `
    --name $vmName `
    --location $location `
    --size $vmSize `
    --nics $nicName `
    --image "${imagePublisher}:${imageOffer}:${imageSku}:latest" `
    --admin-username $adminUsername `
    --admin-password $adminPassword `
    --computer-name $computerName `
    --os-disk-size-gb $osDiskSize `
    --os-disk-name "${vmName}-osdisk" `
    --storage-sku Premium_LRS `
    --tags "Purpose=Syslog-SNMP-Collector" "ManagedBy=HybridCloudSolutions" "Environment=Production" "OS=Ubuntu-24.04-LTS"

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create VM" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ VM created successfully" -ForegroundColor Green

# Create and attach data disk
Write-Host ""
Write-Host "[6/8] Creating and attaching data disk..." -ForegroundColor Yellow
az vm disk attach `
    --resource-group $resourceGroup `
    --vm-name $vmName `
    --name $dataDiskName `
    --size-gb $dataDiskSize `
    --sku Premium_LRS `
    --new

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create/attach data disk" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Data disk attached: $dataDiskSize GB Premium SSD" -ForegroundColor Green

# Get VM details
Write-Host ""
Write-Host "[7/8] Retrieving VM details..." -ForegroundColor Yellow
$vmDetails = az vm show --resource-group $resourceGroup --name $vmName --query "{Name:name, ComputerName:osProfile.computerName, Size:hardwareProfile.vmSize, PrivateIP:'$privateIP'}" -o json | ConvertFrom-Json

Write-Host ""
Write-Host "=====================================" -ForegroundColor Green
Write-Host "Deployment Complete!" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green
Write-Host ""
Write-Host "VM Details:" -ForegroundColor Cyan
Write-Host "  Name: $($vmDetails.Name)" -ForegroundColor White
Write-Host "  Computer Name: $($vmDetails.ComputerName)" -ForegroundColor White
Write-Host "  Size: $($vmDetails.Size)" -ForegroundColor White
Write-Host "  Private IP: $($vmDetails.PrivateIP)" -ForegroundColor White
Write-Host "  Admin Username: $adminUsername" -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. SSH to the VM: ssh ${adminUsername}@${privateIP}" -ForegroundColor White
Write-Host "  2. Configure data disk (partition, format, mount to /var/log/remote)" -ForegroundColor White
Write-Host "  3. Install rsyslog/syslog-ng and snmptrapd" -ForegroundColor White
Write-Host "  4. Install Azure Monitor Agent (AMA)" -ForegroundColor White
Write-Host "  5. Configure syslog sources (UDM, Opengear, iDRACs, etc.)" -ForegroundColor White
Write-Host "  6. Update hosts file: Add '10.1.0.40 vm-local-syslog-eastus2-001 local-syslog01'" -ForegroundColor White
Write-Host ""
