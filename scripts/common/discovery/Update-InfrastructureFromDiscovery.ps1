<#
.SYNOPSIS
    Update and add to infrastructure.yml with discovered hardware and Azure data.

.DESCRIPTION
    Reads discovery JSON files and updates infrastructure.yml using targeted
    string replacements to preserve formatting and comments:
    - idrac-inventory.json → nodes section (hardware specs, MACs, serial numbers)
    - azure-inventory.json → azure.subscriptions, azure_vms, 
      azure_infrastructure.key_vaults, network.azure_vnets sections
    
    CAPABILITIES:
    - UPDATE existing entries with new values from discovery
    - ADD new entries discovered in Azure/iDRAC that aren't in YAML
    - REPORT undocumented resources for manual review
    
    Updates the _metadata section with discovery timestamps.
    Creates a backup of infrastructure.yml before updating.

.PARAMETER Azure
    Import Azure discovery data only

.PARAMETER iDRAC
    Import iDRAC/hardware discovery data only

.PARAMETER All
    Import all discovery sources (default if no source specified)

.PARAMETER AddNew
    Add newly discovered resources to infrastructure.yml (subscriptions, VMs, VNets, Key Vaults)
    Default: $true. Use -AddNew:$false to only update existing entries.

.PARAMETER ExcludeCICDVNets
    Exclude CI/CD runner VNets (vnet-cicd-runners-*) from being added.
    Default: $true (they are auto-provisioned by GitLab runner module)

.PARAMETER DiscoveryPath
    Path to discovery folder. Default: "discovery/"

.PARAMETER InfrastructurePath
    Path to infrastructure.yml. Default: "infrastructure.yml"

.PARAMETER Force
    Skip confirmation prompt

.PARAMETER WhatIf
    Show what would be updated without making changes

.EXAMPLE
    .\Update-InfrastructureFromDiscovery.ps1 -Azure
    # Import only Azure discovery data (updates AND adds)

.EXAMPLE
    .\Update-InfrastructureFromDiscovery.ps1 -Azure -AddNew:$false
    # Import Azure data but only update existing entries, don't add new ones

.EXAMPLE
    .\Update-InfrastructureFromDiscovery.ps1 -All -WhatIf
    # Preview all changes (updates and additions)

.NOTES
    File: Update-InfrastructureFromDiscovery.ps1
    Author: Azure Local Documentation Team
    Version: 5.0.0
    Created: 2025-12-05
    Updated: 2025-12-05
    
    This version preserves YAML formatting and comments by using targeted
    string replacements instead of full YAML serialization.
    
    v5.0.0: Enhanced VM discovery with comprehensive fields (vm_size, os_disk, data_disks, 
            networking details, image reference, boot diagnostics, managed identity)
    v4.0.0: Added support for ADDING new resources (subscriptions, VMs, VNets, Key Vaults)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [switch]$Azure,

    [Parameter(Mandatory = $false)]
    [switch]$iDRAC,

    [Parameter(Mandatory = $false)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [bool]$AddNew = $true,

    [Parameter(Mandatory = $false)]
    [bool]$ExcludeCICDVNets = $true,

    [Parameter(Mandatory = $false)]
    [string]$DiscoveryPath,

    [Parameter(Mandatory = $false)]
    [string]$InfrastructurePath,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# If no source specified, default to All
if (-not $Azure -and -not $iDRAC -and -not $All) {
    $All = $true
}

# If -All specified, enable both sources
if ($All) {
    $Azure = $true
    $iDRAC = $true
}

# Repository root detection
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $RepoRoot

# Set default paths
if (-not $DiscoveryPath) {
    $DiscoveryPath = Join-Path $RepoRoot "discovery"
}

if (-not $InfrastructurePath) {
    $InfrastructurePath = Join-Path $RepoRoot "infrastructure.yml"
}

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Update Infrastructure from Discovery                      ║" -ForegroundColor Cyan
Write-Host "║  (Format-Preserving Mode + Add New Resources)              ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`nDiscovery Path: $DiscoveryPath" -ForegroundColor White
Write-Host "Infrastructure: $InfrastructurePath" -ForegroundColor White
Write-Host "Sources:        $(if($iDRAC){'iDRAC '})$(if($Azure){'Azure'})" -ForegroundColor White
Write-Host "Add New:        $(if($AddNew){'Yes'}else{'No (update only)'})" -ForegroundColor White
Write-Host ""

# Check paths exist
if (-not (Test-Path $DiscoveryPath)) {
    Write-Host "✗ Discovery folder not found: $DiscoveryPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $InfrastructurePath)) {
    Write-Host "✗ infrastructure.yml not found: $InfrastructurePath" -ForegroundColor Red
    exit 1
}

# =============================================================================
# STEP 1: Load infrastructure.yml as raw text
# =============================================================================
Write-Host "[1/5] Loading infrastructure.yml..." -ForegroundColor Cyan

try {
    $YamlContent = Get-Content -Path $InfrastructurePath -Raw
    $OriginalLength = $YamlContent.Length
    Write-Host "  ✓ Loaded infrastructure.yml ($OriginalLength bytes)" -ForegroundColor Green
    
    # Also load as YAML for comparison purposes (not for saving)
    Import-Module powershell-yaml -ErrorAction SilentlyContinue
    if (Get-Module powershell-yaml) {
        $Infrastructure = ConvertFrom-Yaml -Yaml $YamlContent -Ordered
    }
}
catch {
    Write-Host "  ✗ Error loading infrastructure.yml: $_" -ForegroundColor Red
    exit 1
}

# =============================================================================
# STEP 2: Find and load iDRAC discovery file
# =============================================================================

$DiscoveredNodes = @{}
$iDRACLastRun = $null

if ($iDRAC) {
    Write-Host "`n[2/5] Loading iDRAC discovery file..." -ForegroundColor Cyan

    # Look for consolidated idrac-inventory.json
    $iDRACFile = Join-Path $DiscoveryPath "idrac-inventory.json"
    
    if (Test-Path $iDRACFile) {
        Write-Host "  Processing: idrac-inventory.json (consolidated)" -ForegroundColor White
        
        try {
            $iDRACData = Get-Content -Path $iDRACFile -Raw | ConvertFrom-Json
            $iDRACLastRun = $iDRACData.Metadata.LastUpdated
            
            # Process each node in the consolidated inventory
            foreach ($NodeEntry in $iDRACData.Nodes.PSObject.Properties) {
                $NodeKey = $NodeEntry.Name
                $NodeData = $NodeEntry.Value
                
                $ServiceTag = $NodeData.ServiceTag
                if (-not $ServiceTag) { $ServiceTag = $NodeKey }
                
                $DiscoveredNodes[$ServiceTag] = @{
                    service_tag     = $ServiceTag
                    serial_number   = $NodeData.SerialNumber
                    model           = $NodeData.Model
                    idrac_ip        = $NodeData.iDRACIP
                    idrac_mac       = $NodeData.iDRACMAC
                    cpu_model       = $NodeData.CPU.Model
                    cpu_cores       = $NodeData.CPU.Cores
                    cpu_threads     = $NodeData.CPU.Threads
                    memory_gb       = $NodeData.MemoryGB
                    collection_time = $NodeData.LastDiscovered
                    port1_mac       = $NodeData.NetworkPorts.Port1
                    port2_mac       = $NodeData.NetworkPorts.Port2
                    port3_mac       = $NodeData.NetworkPorts.Port3
                    port4_mac       = $NodeData.NetworkPorts.Port4
                }
                
                Write-Host "    ✓ $ServiceTag - $($NodeData.Model)" -ForegroundColor Green
            }
            
            Write-Host "  Found $($DiscoveredNodes.Count) node(s) in consolidated inventory" -ForegroundColor Gray
        }
        catch {
            Write-Host "    ✗ Error parsing consolidated file: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  ⚠ No iDRAC discovery file found" -ForegroundColor Yellow
        Write-Host "    Run: .\\scripts\\discovery\\Get-DellServerInventory-FromiDRAC.ps1" -ForegroundColor Gray
    }
}
else {
    Write-Host "`n[2/5] Skipping iDRAC discovery (not selected)" -ForegroundColor Gray
}

# =============================================================================
# STEP 3: Find and load Azure discovery file
# =============================================================================

$AzureData = $null
$AzureLastRun = $null
$AzureFile = $null

if ($Azure) {
    Write-Host "`n[3/5] Loading Azure discovery file..." -ForegroundColor Cyan

    $AzureFile = Get-ChildItem -Path $DiscoveryPath -Filter "*azure-inventory*.json" -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($AzureFile) {
        Write-Host "  Processing: $($AzureFile.Name)" -ForegroundColor White
        
        try {
            $AzureData = Get-Content -Path $AzureFile.FullName -Raw | ConvertFrom-Json
            $AzureLastRun = if ($AzureData.Metadata.CompletedAt) { $AzureData.Metadata.CompletedAt } else { $AzureData.CollectionTimestamp }
            
            # Support both old (flat) and new (nested) JSON structure
            $VMCount = if ($AzureData.Compute.VirtualMachines) { $AzureData.Compute.VirtualMachines.Count } else { $AzureData.VirtualMachines.Count }
            $VNetCount = if ($AzureData.Networking.VirtualNetworks) { $AzureData.Networking.VirtualNetworks.Count } else { $AzureData.VirtualNetworks.Count }
            
            Write-Host "    ✓ Loaded Azure inventory" -ForegroundColor Green
            Write-Host "    VMs: $VMCount" -ForegroundColor Gray
            Write-Host "    VNets: $VNetCount" -ForegroundColor Gray
            
        }
        catch {
            Write-Host "    ✗ Error parsing: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  ⚠ No Azure discovery file found" -ForegroundColor Yellow
        Write-Host "    Run: .\\scripts\\discovery\\Inventory-AzureTenant.ps1" -ForegroundColor Gray
    }
}
else {
    Write-Host "`n[3/5] Skipping Azure discovery (not selected)" -ForegroundColor Gray
}

# =============================================================================
# STEP 4: Compare and identify changes
# =============================================================================
Write-Host "`n[4/5] Comparing discovery data with infrastructure.yml..." -ForegroundColor Cyan

$Changes = @()

# Build a map of service_tag to node key from the YAML
$NodeServiceTagMap = @{}
if ($Infrastructure -and $Infrastructure.nodes) {
    foreach ($NodeKey in $Infrastructure.nodes.Keys) {
        $Node = $Infrastructure.nodes[$NodeKey]
        if ($Node.service_tag) {
            $NodeServiceTagMap[$Node.service_tag] = $NodeKey
        }
    }
}

# Compare nodes from iDRAC discovery
if ($DiscoveredNodes.Count -gt 0 -and $Infrastructure -and $Infrastructure.nodes) {
    foreach ($ServiceTag in $DiscoveredNodes.Keys) {
        $Discovered = $DiscoveredNodes[$ServiceTag]
        
        # Find the node key for this service tag
        $NodeKey = $NodeServiceTagMap[$ServiceTag]
        if (-not $NodeKey) { continue }
        
        $Node = $Infrastructure.nodes[$NodeKey]
        
        # Check each field that can be updated
        # Maps discovery field name → YAML field name (they may differ)
        $FieldMappings = @{
            'serial_number' = @{ YamlKey = 'serial_number'; YamlField = 'serial_number' }
            'model'         = @{ YamlKey = 'model'; YamlField = 'model' }
            'idrac_ip'      = @{ YamlKey = 'idrac_ip'; YamlField = 'idrac_ip' }
            'cpu_model'     = @{ YamlKey = 'cpu'; YamlField = 'cpu' }  # discovery:cpu_model → yaml:cpu
            'cpu_cores'     = @{ YamlKey = 'cores'; YamlField = 'cores' }  # discovery:cpu_cores → yaml:cores
            'memory_gb'     = @{ YamlKey = 'memory_gb'; YamlField = 'memory_gb' }
        }
        
        foreach ($Field in $FieldMappings.Keys) {
            $Mapping = $FieldMappings[$Field]
            $YamlFieldName = $Mapping.YamlField
            $CurrentValue = $Node.$YamlFieldName
            $NewValue = $Discovered[$Field]
            
            if ($NewValue -and "$CurrentValue" -ne "$NewValue") {
                $Changes += @{
                    NodeKey  = $NodeKey
                    Field    = $YamlFieldName  # Use YAML field name for display
                    YamlKey  = $Mapping.YamlKey
                    OldValue = if ($CurrentValue) { "$CurrentValue" } else { "(empty)" }
                    NewValue = "$NewValue"
                }
            }
        }
    }
}

# Compare Arc node resource IDs from Azure discovery
if ($AzureData -and $Infrastructure -and $Infrastructure.nodes) {
    Write-Host "`n  Comparing Arc node resource IDs..." -ForegroundColor White
    
    # Build a map of Arc machines from Resources array
    $ArcMachines = @{}
    if ($AzureData.Resources) {
        foreach ($Resource in $AzureData.Resources) {
            if ($Resource.ResourceType -eq "Microsoft.HybridCompute/machines") {
                $ArcMachines[$Resource.Name] = $Resource.ResourceId
            }
        }
    }
    
    # Check each node in infrastructure.yml
    foreach ($NodeKey in $Infrastructure.nodes.Keys) {
        $Node = $Infrastructure.nodes[$NodeKey]
        $NodeHostname = $Node.hostname
        
        # Check if there's a matching Arc machine
        if ($ArcMachines.ContainsKey($NodeHostname)) {
            $ArcResourceId = $ArcMachines[$NodeHostname]
            $CurrentArcId = $Node.arc_resource_id
            
            if (-not $CurrentArcId -or "$CurrentArcId" -ne "$ArcResourceId") {
                $Changes += @{
                    NodeKey  = $NodeKey
                    Field    = 'arc_resource_id'
                    YamlKey  = 'arc_resource_id'
                    OldValue = if ($CurrentArcId) { "$CurrentArcId" } else { "(not set)" }
                    NewValue = "$ArcResourceId"
                }
                Write-Host "    ✓ Found Arc resource ID for: $NodeHostname" -ForegroundColor Green
            }
        }
        else {
            Write-Host "    ⚠ No Arc registration found for: $NodeHostname" -ForegroundColor Yellow
        }
    }
}

# Compare Azure VMs from discovery
$Additions = @()  # Track new resources to add

if ($AzureData -and $Infrastructure -and $Infrastructure.azure_vms) {
    Write-Host "`n  Comparing Azure VMs..." -ForegroundColor White
    
    # Build a map of VM names from discovery using VirtualMachineDetails (more comprehensive)
    $DiscoveredVMs = @{}
    $VMDetails = if ($AzureData.Compute.VirtualMachineDetails) { $AzureData.Compute.VirtualMachineDetails } 
    elseif ($AzureData.VirtualMachineDetails) { $AzureData.VirtualMachineDetails }
    elseif ($AzureData.Compute.VirtualMachines) { $AzureData.Compute.VirtualMachines }
    else { $AzureData.VirtualMachines }
    
    foreach ($VM in $VMDetails) {
        # Extract subnet name from SubnetId
        $SubnetName = $null
        if ($VM.NetworkInterfaces -and $VM.NetworkInterfaces[0].SubnetId) {
            $SubnetName = ($VM.NetworkInterfaces[0].SubnetId -split '/')[-1]
        }
        
        # Extract NIC name
        $NicName = $null
        if ($VM.NetworkInterfaces -and $VM.NetworkInterfaces[0].Name) {
            $NicName = $VM.NetworkInterfaces[0].Name
        }
        
        # Extract accelerated networking
        $AcceleratedNetworking = $false
        if ($VM.NetworkInterfaces -and $VM.NetworkInterfaces[0].EnableAcceleratedNetworking) {
            $AcceleratedNetworking = $VM.NetworkInterfaces[0].EnableAcceleratedNetworking
        }
        
        # Determine OS type from OsDisk or ImageReference
        $OsType = if ($VM.OsType -and $VM.OsType -ne "Unknown") { $VM.OsType }
        elseif ($VM.OsDisk -and $VM.OsDisk.OsType -and $VM.OsDisk.OsType -ne "Unknown") { $VM.OsDisk.OsType }
        elseif ($VM.ImageReference -and $VM.ImageReference.Publisher -match "Windows") { "Windows" }
        elseif ($VM.ImageReference -and $VM.ImageReference.Publisher -match "Canonical") { "Linux" }
        else { "Unknown" }
        
        $DiscoveredVMs[$VM.Name] = @{
            Name                  = $VM.Name
            ResourceGroup         = $VM.ResourceGroupName
            Location              = $VM.Location
            Subscription          = $VM.SubscriptionName
            Tags                  = $VM.Tags
            # Compute
            VmSize                = $VM.VmSize
            AvailabilityZone      = if ($VM.Zones) { $VM.Zones[0] } else { $null }
            ComputerName          = $VM.ComputerName
            # OS
            OsType                = $OsType
            ImagePublisher        = if ($VM.ImageReference) { $VM.ImageReference.Publisher } else { $null }
            ImageOffer            = if ($VM.ImageReference) { $VM.ImageReference.Offer } else { $null }
            ImageSku              = if ($VM.ImageReference) { $VM.ImageReference.Sku } else { $null }
            # Networking
            PrivateIp             = if ($VM.PrivateIpAddresses -and $VM.PrivateIpAddresses.Count -gt 0) { $VM.PrivateIpAddresses[0] } else { $null }
            PublicIp              = if ($VM.PublicIpAddresses -and $VM.PublicIpAddresses.Count -gt 0) { $VM.PublicIpAddresses[0] } else { $null }
            Subnet                = $SubnetName
            NicName               = $NicName
            AcceleratedNetworking = $AcceleratedNetworking
            # Storage
            OsDiskName            = if ($VM.OsDisk) { $VM.OsDisk.Name } else { $null }
            OsDiskSizeGB          = if ($VM.OsDisk) { $VM.OsDisk.SizeGB } else { $null }
            OsDiskType            = if ($VM.OsDisk) { $VM.OsDisk.StorageAccountType } else { $null }
            DataDisks             = if ($VM.DataDisks) { $VM.DataDisks } else { @() }
            DataDiskCount         = if ($VM.DataDiskCount) { $VM.DataDiskCount } else { 0 }
            # Management
            BootDiagnostics       = if ($VM.BootDiagnostics) { $VM.BootDiagnostics.Enabled } else { $false }
            Identity              = $VM.Identity
        }
    }
    
    # Check each VM in infrastructure.yml
    $AzureVMMatches = 0
    $AzureVMMissing = @()
    
    foreach ($VMKey in $Infrastructure.azure_vms.Keys) {
        $ConfiguredVM = $Infrastructure.azure_vms[$VMKey]
        $VMName = $ConfiguredVM.name
        
        if ($DiscoveredVMs.ContainsKey($VMName)) {
            $AzureVMMatches++
            $DiscoveredVM = $DiscoveredVMs[$VMName]
            
            # Compare resource group (case-insensitive)
            if ($ConfiguredVM.resource_group -and $DiscoveredVM.ResourceGroup) {
                if ($ConfiguredVM.resource_group.ToLower() -ne $DiscoveredVM.ResourceGroup.ToLower()) {
                    $Changes += @{
                        Section  = "azure_vms"
                        VMKey    = $VMKey
                        Field    = "resource_group"
                        YamlKey  = "resource_group"
                        OldValue = $ConfiguredVM.resource_group
                        NewValue = $DiscoveredVM.ResourceGroup
                        Type     = "azure_vm"
                    }
                }
            }
            
            # Compare VM size
            if ($DiscoveredVM.VmSize -and $ConfiguredVM.vm_size -ne $DiscoveredVM.VmSize) {
                $Changes += @{
                    Section  = "azure_vms"
                    VMKey    = $VMKey
                    Field    = "vm_size"
                    YamlKey  = "vm_size"
                    OldValue = $ConfiguredVM.vm_size
                    NewValue = $DiscoveredVM.VmSize
                    Type     = "azure_vm"
                }
            }
            
            # Compare location
            if ($DiscoveredVM.Location -and $ConfiguredVM.location -ne $DiscoveredVM.Location) {
                $Changes += @{
                    Section  = "azure_vms"
                    VMKey    = $VMKey
                    Field    = "location"
                    YamlKey  = "location"
                    OldValue = $ConfiguredVM.location
                    NewValue = $DiscoveredVM.Location
                    Type     = "azure_vm"
                }
            }
            
            # Compare hostname/computer name
            if ($DiscoveredVM.ComputerName -and $ConfiguredVM.hostname -ne $DiscoveredVM.ComputerName) {
                $Changes += @{
                    Section  = "azure_vms"
                    VMKey    = $VMKey
                    Field    = "hostname"
                    YamlKey  = "hostname"
                    OldValue = $ConfiguredVM.hostname
                    NewValue = $DiscoveredVM.ComputerName
                    Type     = "azure_vm"
                }
            }
            
            # Compare private IP
            if ($DiscoveredVM.PrivateIp -and $ConfiguredVM.private_ip -ne $DiscoveredVM.PrivateIp) {
                $Changes += @{
                    Section  = "azure_vms"
                    VMKey    = $VMKey
                    Field    = "private_ip"
                    YamlKey  = "private_ip"
                    OldValue = $ConfiguredVM.private_ip
                    NewValue = $DiscoveredVM.PrivateIp
                    Type     = "azure_vm"
                }
            }
            
            # Compare public IP
            $CurrentPublicIp = if ($ConfiguredVM.public_ip) { $ConfiguredVM.public_ip } else { $null }
            if ($DiscoveredVM.PublicIp -ne $CurrentPublicIp) {
                $Changes += @{
                    Section  = "azure_vms"
                    VMKey    = $VMKey
                    Field    = "public_ip"
                    YamlKey  = "public_ip"
                    OldValue = $CurrentPublicIp
                    NewValue = $DiscoveredVM.PublicIp
                    Type     = "azure_vm"
                }
            }
            
            # Compare OS disk size
            if ($DiscoveredVM.OsDiskSizeGB -and $ConfiguredVM.os_disk -and $ConfiguredVM.os_disk.size_gb -ne $DiscoveredVM.OsDiskSizeGB) {
                $Changes += @{
                    Section  = "azure_vms"
                    VMKey    = $VMKey
                    Field    = "os_disk.size_gb"
                    YamlKey  = "os_disk.size_gb"
                    OldValue = $ConfiguredVM.os_disk.size_gb
                    NewValue = $DiscoveredVM.OsDiskSizeGB
                    Type     = "azure_vm_nested"
                }
            }
        }
        else {
            $AzureVMMissing += $VMName
        }
    }
    
    Write-Host "    ✓ $AzureVMMatches VMs found in Azure" -ForegroundColor Gray
    if ($AzureVMMissing.Count -gt 0) {
        Write-Host "    ⚠ $($AzureVMMissing.Count) VM(s) in YAML not found in Azure:" -ForegroundColor Yellow
        foreach ($Missing in $AzureVMMissing) {
            Write-Host "      - $Missing" -ForegroundColor Yellow
        }
    }
    
    # Check for VMs in Azure not in infrastructure.yml
    $UndocumentedVMs = @()
    foreach ($VMName in $DiscoveredVMs.Keys) {
        $Found = $false
        foreach ($VMKey in $Infrastructure.azure_vms.Keys) {
            if ($Infrastructure.azure_vms[$VMKey].name -eq $VMName) {
                $Found = $true
                break
            }
        }
        if (-not $Found) {
            $UndocumentedVMs += $DiscoveredVMs[$VMName]
        }
    }
    
    if ($UndocumentedVMs.Count -gt 0) {
        Write-Host "    📋 $($UndocumentedVMs.Count) VM(s) in Azure not in infrastructure.yml:" -ForegroundColor Cyan
        foreach ($Undoc in $UndocumentedVMs) {
            Write-Host "      + $($Undoc.Name)" -ForegroundColor Cyan
            if ($AddNew) {
                $Additions += @{
                    Type    = "vm"
                    Section = "azure_vms"
                    Name    = $Undoc.Name
                    Data    = $Undoc
                }
            }
        }
    }
}

# =============================================================================
# Compare and identify ADDITIONS for Azure resources
# =============================================================================

if ($AzureData -and $AddNew) {
    
    # --- SUBSCRIPTIONS ---
    Write-Host "`n  Comparing Azure Subscriptions..." -ForegroundColor White
    
    $ExistingSubIds = @()
    if ($Infrastructure.azure -and $Infrastructure.azure.subscriptions) {
        foreach ($SubKey in $Infrastructure.azure.subscriptions.Keys) {
            $ExistingSubIds += $Infrastructure.azure.subscriptions[$SubKey].id
        }
    }
    
    $NewSubscriptions = @()
    foreach ($Sub in $AzureData.Subscriptions) {
        if ($Sub.SubscriptionId -notin $ExistingSubIds) {
            $NewSubscriptions += $Sub
            Write-Host "    + $($Sub.Name) ($($Sub.SubscriptionId))" -ForegroundColor Cyan
            $Additions += @{
                Type    = "subscription"
                Section = "azure.subscriptions"
                Name    = $Sub.Name
                Data    = @{
                    Id    = $Sub.SubscriptionId
                    Name  = $Sub.Name
                    State = $Sub.State
                    Tags  = $Sub.Tags
                }
            }
        }
    }
    
    if ($NewSubscriptions.Count -eq 0) {
        Write-Host "    ✓ All subscriptions documented" -ForegroundColor Gray
    }
    else {
        Write-Host "    📋 $($NewSubscriptions.Count) subscription(s) to add" -ForegroundColor Cyan
    }
    
    # --- VIRTUAL NETWORKS ---
    Write-Host "`n  Comparing Azure Virtual Networks..." -ForegroundColor White
    
    # Get existing VNets from YAML
    $ExistingVNetNames = @()
    if ($Infrastructure.network -and $Infrastructure.network.azure_vnet) {
        $ExistingVNetNames += $Infrastructure.network.azure_vnet.name
    }
    # Also check azure_vnets array if it exists
    if ($Infrastructure.network -and $Infrastructure.network.azure_vnets) {
        foreach ($VNet in $Infrastructure.network.azure_vnets) {
            $ExistingVNetNames += $VNet.name
        }
    }
    
    $VNets = if ($AzureData.Networking.VirtualNetworks) { $AzureData.Networking.VirtualNetworks } else { $AzureData.VirtualNetworks }
    $NewVNets = @()
    $SkippedCICDVNets = 0
    
    foreach ($VNet in $VNets) {
        # Skip CI/CD runner VNets if configured
        if ($ExcludeCICDVNets -and $VNet.Name -match "^vnet-cicd-runners-") {
            $SkippedCICDVNets++
            continue
        }
        
        if ($VNet.Name -notin $ExistingVNetNames) {
            $NewVNets += $VNet
            Write-Host "    + $($VNet.Name)" -ForegroundColor Cyan
            
            # Build VNet data with detailed configuration
            $VNetData = @{
                Name          = $VNet.Name
                ResourceGroup = $VNet.ResourceGroupName
                Location      = $VNet.Location
                Subscription  = $VNet.SubscriptionName
            }
            
            # Add address space if available
            if ($VNet.AddressSpace -and $VNet.AddressSpace.AddressPrefixes) {
                $VNetData.AddressSpace = $VNet.AddressSpace.AddressPrefixes
            }
            
            # Add subnets if available
            if ($VNet.Subnets -and $VNet.Subnets.Count -gt 0) {
                $VNetData.Subnets = @()
                foreach ($Subnet in $VNet.Subnets) {
                    $SubnetData = @{
                        Name          = $Subnet.Name
                        AddressPrefix = $Subnet.AddressPrefix
                    }
                    if ($Subnet.RouteTable) {
                        $SubnetData.RouteTable = $Subnet.RouteTable.Id
                    }
                    if ($Subnet.NetworkSecurityGroup) {
                        $SubnetData.NSG = $Subnet.NetworkSecurityGroup.Id
                    }
                    $VNetData.Subnets += $SubnetData
                }
            }
            
            # Add VNet peerings if available
            if ($VNet.VirtualNetworkPeerings -and $VNet.VirtualNetworkPeerings.Count -gt 0) {
                $VNetData.Peerings = @()
                foreach ($Peering in $VNet.VirtualNetworkPeerings) {
                    $PeeringData = @{
                        Name       = $Peering.Name
                        State      = $Peering.PeeringState
                        RemoteVNet = $Peering.RemoteVirtualNetwork.Id
                    }
                    if ($null -ne $Peering.AllowGatewayTransit) {
                        $PeeringData.AllowGatewayTransit = $Peering.AllowGatewayTransit
                    }
                    if ($null -ne $Peering.UseRemoteGateways) {
                        $PeeringData.UseRemoteGateways = $Peering.UseRemoteGateways
                    }
                    $VNetData.Peerings += $PeeringData
                }
            }
            
            # Add DNS servers if configured
            if ($VNet.DhcpOptions -and $VNet.DhcpOptions.DnsServers -and $VNet.DhcpOptions.DnsServers.Count -gt 0) {
                $VNetData.DnsServers = $VNet.DhcpOptions.DnsServers
            }
            
            $Additions += @{
                Type    = "vnet"
                Section = "network.azure_vnets"
                Name    = $VNet.Name
                Data    = $VNetData
            }
        }
    }
    
    if ($SkippedCICDVNets -gt 0) {
        Write-Host "    ⊘ Skipped $SkippedCICDVNets CI/CD runner VNet(s)" -ForegroundColor Gray
    }
    if ($NewVNets.Count -eq 0) {
        Write-Host "    ✓ All VNets documented" -ForegroundColor Gray
    }
    else {
        Write-Host "    📋 $($NewVNets.Count) VNet(s) to add" -ForegroundColor Cyan
    }
    
    # --- KEY VAULTS ---
    Write-Host "`n  Comparing Azure Key Vaults..." -ForegroundColor White
    
    $ExistingKVNames = @()
    if ($Infrastructure.azure_infrastructure -and $Infrastructure.azure_infrastructure.key_vaults) {
        foreach ($KVKey in $Infrastructure.azure_infrastructure.key_vaults.Keys) {
            $ExistingKVNames += $Infrastructure.azure_infrastructure.key_vaults[$KVKey].name
        }
    }
    
    $KeyVaults = if ($AzureData.Security.KeyVaults) { $AzureData.Security.KeyVaults } else { $AzureData.KeyVaults }
    $NewKeyVaults = @()
    
    if ($KeyVaults) {
        foreach ($KV in $KeyVaults) {
            if ($KV.Name -notin $ExistingKVNames) {
                $NewKeyVaults += $KV
                Write-Host "    + $($KV.Name)" -ForegroundColor Cyan
                $Additions += @{
                    Type    = "keyvault"
                    Section = "azure_infrastructure.key_vaults"
                    Name    = $KV.Name
                    Data    = @{
                        Name          = $KV.Name
                        ResourceGroup = $KV.ResourceGroupName
                        Location      = $KV.Location
                        Subscription  = $KV.SubscriptionName
                    }
                }
            }
        }
    }
    
    if ($NewKeyVaults.Count -eq 0) {
        Write-Host "    ✓ All Key Vaults documented" -ForegroundColor Gray
    }
    else {
        Write-Host "    📋 $($NewKeyVaults.Count) Key Vault(s) to add" -ForegroundColor Cyan
    }
}

# Show changes (updates to existing entries)
if ($Changes.Count -gt 0) {
    Write-Host "`n  Updates to existing entries:" -ForegroundColor Cyan
    foreach ($Change in $Changes) {
        if ($Change.Type -eq "azure_vm") {
            $DisplayPath = "azure_vms.$($Change.VMKey).$($Change.Field)"
        }
        else {
            $DisplayPath = "nodes.$($Change.NodeKey).$($Change.Field)"
        }
        if ($Change.OldValue -eq "(empty)") {
            Write-Host "    $DisplayPath`: $($Change.NewValue) (NEW)" -ForegroundColor Green
        }
        else {
            Write-Host "    $DisplayPath`: $($Change.OldValue) → $($Change.NewValue)" -ForegroundColor Yellow
        }
    }
}

# Show additions (new resources to add)
if ($Additions.Count -gt 0) {
    Write-Host "`n  New resources to add:" -ForegroundColor Cyan
    
    $SubsToAdd = @($Additions | Where-Object { $_.Type -eq "subscription" })
    $VNetsToAdd = @($Additions | Where-Object { $_.Type -eq "vnet" })
    $KVsToAdd = @($Additions | Where-Object { $_.Type -eq "keyvault" })
    $VMsToAdd = @($Additions | Where-Object { $_.Type -eq "vm" })
    
    if ($SubsToAdd.Count -gt 0) {
        Write-Host "    Subscriptions: $($SubsToAdd.Count)" -ForegroundColor Green
        foreach ($Item in $SubsToAdd) {
            Write-Host "      + $($Item.Name)" -ForegroundColor Green
        }
    }
    if ($VNetsToAdd.Count -gt 0) {
        Write-Host "    Virtual Networks: $($VNetsToAdd.Count)" -ForegroundColor Green
        foreach ($Item in $VNetsToAdd) {
            Write-Host "      + $($Item.Name)" -ForegroundColor Green
        }
    }
    if ($KVsToAdd.Count -gt 0) {
        Write-Host "    Key Vaults: $($KVsToAdd.Count)" -ForegroundColor Green
        foreach ($Item in $KVsToAdd) {
            Write-Host "      + $($Item.Name)" -ForegroundColor Green
        }
    }
    if ($VMsToAdd.Count -gt 0) {
        Write-Host "    Virtual Machines: $($VMsToAdd.Count)" -ForegroundColor Green
        foreach ($Item in $VMsToAdd) {
            Write-Host "      + $($Item.Name)" -ForegroundColor Green
        }
    }
}

if ($Changes.Count -eq 0 -and $Additions.Count -eq 0) {
    Write-Host "`n  ✓ No changes detected - infrastructure.yml is up to date" -ForegroundColor Green
}

# Show metadata updates
Write-Host "`n  Metadata updates:" -ForegroundColor Cyan
if ($iDRACLastRun) {
    Write-Host "    _metadata.discovery.idrac.last_run: $iDRACLastRun" -ForegroundColor Gray
}
if ($AzureLastRun) {
    Write-Host "    _metadata.discovery.azure.last_run: $AzureLastRun" -ForegroundColor Gray
}

# =============================================================================
# STEP 5: Apply changes using targeted string replacement
# =============================================================================
if ($WhatIfPreference) {
    Write-Host "`n[5/5] WhatIf mode - no changes applied" -ForegroundColor Yellow
    Write-Host "`n  Summary of what would be applied:" -ForegroundColor Yellow
    Write-Host "    Updates: $($Changes.Count)" -ForegroundColor White
    Write-Host "    Additions: $($Additions.Count)" -ForegroundColor White
    exit 0
}

if ($Changes.Count -eq 0 -and $Additions.Count -eq 0 -and -not $iDRACLastRun -and -not $AzureLastRun) {
    Write-Host "`n✓ Nothing to update" -ForegroundColor Green
    exit 0
}

# Confirm
if (-not $Force -and ($Changes.Count -gt 0 -or $Additions.Count -gt 0)) {
    Write-Host ""
    $Confirm = Read-Host "Apply $($Changes.Count) updates and $($Additions.Count) additions to infrastructure.yml? (Y/N)"
    if ($Confirm -ne "Y" -and $Confirm -ne "y") {
        Write-Host "✗ Cancelled by user" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`n[5/5] Updating infrastructure.yml (preserving formatting)..." -ForegroundColor Cyan

# Create backup in backups/ folder
$BackupFolder = Join-Path $RepoRoot "backups"
if (-not (Test-Path $BackupFolder)) {
    New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
}
$BackupFileName = "infrastructure_backup_$(Get-Date -Format 'yyyyMMdd-HHmmss').yml"
$BackupPath = Join-Path $BackupFolder $BackupFileName
try {
    Copy-Item -Path $InfrastructurePath -Destination $BackupPath -Force
    Write-Host "  ✓ Backup created: backups/$BackupFileName" -ForegroundColor Gray
}
catch {
    Write-Host "  ✗ Error creating backup: $_" -ForegroundColor Red
    exit 1
}

# Apply each change using targeted string replacement
$UpdatedContent = $YamlContent
$AppliedCount = 0

foreach ($Change in $Changes) {
    $NodeKey = $Change.NodeKey
    $YamlKey = $Change.YamlKey
    $NewValue = $Change.NewValue
    $SectionPath = $Change.SectionPath
    
    # Format the value for YAML
    $FormattedValue = $NewValue
    if ($NewValue -match '[\s:@#\[\]{}|>-]' -or $NewValue -eq "") {
        $FormattedValue = "`"$NewValue`""
    }
    
    # Build a specific pattern for this node and field
    # We look for the node key first, then the field within that node's block
    
    if ($SectionPath) {
        # Nested field like hardware.cpu
        # Pattern: Find within the node's hardware section
        $Pattern = "(?ms)(  $NodeKey`:.*?$SectionPath`:.*?)($YamlKey`:)\s*[^\r\n]*"
        $Replacement = "`$1`$2 $FormattedValue"
    }
    else {
        # Direct field like cpu_model
        # Pattern: Find within the node's section (4 spaces indent)
        $Pattern = "(?ms)(  $NodeKey`:.*?)(    $YamlKey`:)\s*[^\r\n]*"
        $Replacement = "`$1`$2 $FormattedValue"
    }
    
    $NewContent = $UpdatedContent -replace $Pattern, $Replacement
    
    if ($NewContent -ne $UpdatedContent) {
        $UpdatedContent = $NewContent
        Write-Host "  ✓ Updated: nodes.$NodeKey.$($Change.Field)" -ForegroundColor Gray
        $AppliedCount++
    }
    else {
        Write-Host "  ⚠ Could not update: nodes.$NodeKey.$($Change.Field) (pattern not matched)" -ForegroundColor Yellow
    }
}

# =============================================================================
# Apply ADDITIONS - Insert new resources into appropriate YAML sections
# =============================================================================
$AddedCount = 0

if ($Additions.Count -gt 0) {
    Write-Host "`n  Adding new resources to infrastructure.yml..." -ForegroundColor Cyan
    
    # --- ADD SUBSCRIPTIONS ---
    $SubsToAdd = @($Additions | Where-Object { $_.Type -eq "subscription" })
    if ($SubsToAdd.Count -gt 0) {
        foreach ($SubAdd in $SubsToAdd) {
            # Generate a key from the subscription name (lowercase, replace spaces/dashes)
            $SubKey = ($SubAdd.Name -replace '[^a-zA-Z0-9]', '_').ToLower()
            $SubData = $SubAdd.Data
            
            # Generate YAML block for the subscription with trailing newline
            $SubYaml = "    ${SubKey}:`r`n      id: `"$($SubData.Id)`"`r`n      name: `"$($SubData.Name)`"`r`n      state: `"$($SubData.State)`"`r`n"
            
            # Find the subscriptions section and insert before "  region:" (which follows subscriptions)
            if ($UpdatedContent -match "(\r?\n  region:)") {
                $UpdatedContent = $UpdatedContent -replace "(\r?\n  region:)", "$SubYaml`$1"
                Write-Host "  ✓ Added: azure.subscriptions.$SubKey" -ForegroundColor Green
                $AddedCount++
            }
            else {
                Write-Host "  ⚠ Could not add subscription: $($SubAdd.Name) (region: not found)" -ForegroundColor Yellow
            }
        }
    }
    
    # --- ADD VIRTUAL NETWORKS ---
    $VNetsToAdd = @($Additions | Where-Object { $_.Type -eq "vnet" })
    if ($VNetsToAdd.Count -gt 0) {
        # Check if azure_vnets array exists, if not we need to add to the network section differently
        if ($UpdatedContent -match "azure_vnets:") {
            # Add to existing azure_vnets array
            foreach ($VNetAdd in $VNetsToAdd) {
                $VNetData = $VNetAdd.Data
                
                # Build base VNet YAML
                $VNetYaml = @"
    - name: "$($VNetData.Name)"
      resource_group: "$($VNetData.ResourceGroup)"
      location: "$($VNetData.Location)"
      subscription: "$($VNetData.Subscription)"
"@
                
                # Add address space if available
                if ($VNetData.AddressSpace -and $VNetData.AddressSpace.Count -gt 0) {
                    $VNetYaml += "`n      address_space:"
                    foreach ($Prefix in $VNetData.AddressSpace) {
                        $VNetYaml += "`n        - `"$Prefix`""
                    }
                }
                
                # Add DNS servers if available
                if ($VNetData.DnsServers -and $VNetData.DnsServers.Count -gt 0) {
                    $VNetYaml += "`n      dns_servers:"
                    foreach ($DnsServer in $VNetData.DnsServers) {
                        $VNetYaml += "`n        - `"$DnsServer`""
                    }
                }
                
                # Add subnets if available
                if ($VNetData.Subnets -and $VNetData.Subnets.Count -gt 0) {
                    $VNetYaml += "`n      subnets:"
                    foreach ($Subnet in $VNetData.Subnets) {
                        $VNetYaml += "`n        - name: `"$($Subnet.Name)`""
                        $VNetYaml += "`n          address_prefix: `"$($Subnet.AddressPrefix)`""
                        if ($Subnet.RouteTable) {
                            $VNetYaml += "`n          route_table: `"$($Subnet.RouteTable)`""
                        }
                        if ($Subnet.NSG) {
                            $VNetYaml += "`n          nsg: `"$($Subnet.NSG)`""
                        }
                    }
                }
                
                # Add peerings if available
                if ($VNetData.Peerings -and $VNetData.Peerings.Count -gt 0) {
                    $VNetYaml += "`n      peerings:"
                    foreach ($Peering in $VNetData.Peerings) {
                        $VNetYaml += "`n        - name: `"$($Peering.Name)`""
                        $VNetYaml += "`n          state: `"$($Peering.State)`""
                        $VNetYaml += "`n          remote_vnet: `"$($Peering.RemoteVNet)`""
                        if ($null -ne $Peering.AllowGatewayTransit) {
                            $VNetYaml += "`n          allow_gateway_transit: $($Peering.AllowGatewayTransit.ToString().ToLower())"
                        }
                        if ($null -ne $Peering.UseRemoteGateways) {
                            $VNetYaml += "`n          use_remote_gateways: $($Peering.UseRemoteGateways.ToString().ToLower())"
                        }
                    }
                }
                
                # Find end of azure_vnets section and append
                if ($UpdatedContent -match "(?ms)(azure_vnets:.*?)(\r?\n  # |\r?\n  [a-z_]+:)") {
                    $UpdatedContent = $UpdatedContent -replace "(?ms)(azure_vnets:.*?)(\r?\n  # |\r?\n  [a-z_]+:)", "`$1`n$VNetYaml`$2"
                    Write-Host "  ✓ Added: network.azure_vnets.$($VNetData.Name)" -ForegroundColor Green
                    $AddedCount++
                }
            }
        }
        else {
            # Add azure_vnets section before "  # VPN Configuration"
            $AllVNetYaml = "`n  # Additional Azure Virtual Networks discovered`n  azure_vnets:"
            foreach ($VNetAdd in $VNetsToAdd) {
                $VNetData = $VNetAdd.Data
                
                # Build base VNet YAML
                $AllVNetYaml += @"

    - name: "$($VNetData.Name)"
      resource_group: "$($VNetData.ResourceGroup)"
      location: "$($VNetData.Location)"
      subscription: "$($VNetData.Subscription)"
"@
                
                # Add address space if available
                if ($VNetData.AddressSpace -and $VNetData.AddressSpace.Count -gt 0) {
                    $AllVNetYaml += "`n      address_space:"
                    foreach ($Prefix in $VNetData.AddressSpace) {
                        $AllVNetYaml += "`n        - `"$Prefix`""
                    }
                }
                
                # Add DNS servers if available
                if ($VNetData.DnsServers -and $VNetData.DnsServers.Count -gt 0) {
                    $AllVNetYaml += "`n      dns_servers:"
                    foreach ($DnsServer in $VNetData.DnsServers) {
                        $AllVNetYaml += "`n        - `"$DnsServer`""
                    }
                }
                
                # Add subnets if available
                if ($VNetData.Subnets -and $VNetData.Subnets.Count -gt 0) {
                    $AllVNetYaml += "`n      subnets:"
                    foreach ($Subnet in $VNetData.Subnets) {
                        $AllVNetYaml += "`n        - name: `"$($Subnet.Name)`""
                        $AllVNetYaml += "`n          address_prefix: `"$($Subnet.AddressPrefix)`""
                        if ($Subnet.RouteTable) {
                            $AllVNetYaml += "`n          route_table: `"$($Subnet.RouteTable)`""
                        }
                        if ($Subnet.NSG) {
                            $AllVNetYaml += "`n          nsg: `"$($Subnet.NSG)`""
                        }
                    }
                }
                
                # Add peerings if available
                if ($VNetData.Peerings -and $VNetData.Peerings.Count -gt 0) {
                    $AllVNetYaml += "`n      peerings:"
                    foreach ($Peering in $VNetData.Peerings) {
                        $AllVNetYaml += "`n        - name: `"$($Peering.Name)`""
                        $AllVNetYaml += "`n          state: `"$($Peering.State)`""
                        $AllVNetYaml += "`n          remote_vnet: `"$($Peering.RemoteVNet)`""
                        if ($null -ne $Peering.AllowGatewayTransit) {
                            $AllVNetYaml += "`n          allow_gateway_transit: $($Peering.AllowGatewayTransit.ToString().ToLower())"
                        }
                        if ($null -ne $Peering.UseRemoteGateways) {
                            $AllVNetYaml += "`n          use_remote_gateways: $($Peering.UseRemoteGateways.ToString().ToLower())"
                        }
                    }
                }
            }
            
            # Insert before the VPN Configuration section
            if ($UpdatedContent -match "(  # VPN Configuration)") {
                $UpdatedContent = $UpdatedContent -replace "(  # VPN Configuration)", "$AllVNetYaml`n`n`$1"
                Write-Host "  ✓ Added: network.azure_vnets section with $($VNetsToAdd.Count) VNet(s)" -ForegroundColor Green
                $AddedCount += $VNetsToAdd.Count
            }
            else {
                Write-Host "  ⚠ Could not add azure_vnets section (VPN section not found)" -ForegroundColor Yellow
            }
        }
    }
    
    # --- ADD KEY VAULTS ---
    $KVsToAdd = @($Additions | Where-Object { $_.Type -eq "keyvault" })
    if ($KVsToAdd.Count -gt 0) {
        foreach ($KVAdd in $KVsToAdd) {
            # Generate a key from the Key Vault name
            $KVKey = ($KVAdd.Name -replace '[^a-zA-Z0-9]', '_').ToLower()
            $KVData = $KVAdd.Data
            
            $KVYaml = @"
    $KVKey`:
      name: "$($KVData.Name)"
      resource_group: "$($KVData.ResourceGroup)"
      location: "$($KVData.Location)"
      subscription: "$($KVData.Subscription)"
"@
            
            # Insert before log_analytics: which follows key_vaults section
            if ($UpdatedContent -match "(  log_analytics:)") {
                $UpdatedContent = $UpdatedContent -replace "(  log_analytics:)", "$KVYaml`n`$1"
                Write-Host "  ✓ Added: azure_infrastructure.key_vaults.$KVKey" -ForegroundColor Green
                $AddedCount++
            }
            else {
                Write-Host "  ⚠ Could not add Key Vault: $($KVAdd.Name) (log_analytics section not found)" -ForegroundColor Yellow
            }
        }
    }
    
    # --- ADD VIRTUAL MACHINES ---
    $VMsToAdd = @($Additions | Where-Object { $_.Type -eq "vm" })
    if ($VMsToAdd.Count -gt 0) {
        foreach ($VMAdd in $VMsToAdd) {
            # Generate a key from the VM name
            $VMKey = ($VMAdd.Name -replace '[^a-zA-Z0-9]', '_').ToLower()
            $VMData = $VMAdd.Data
            
            # Build data disks YAML if present
            $DataDisksYaml = "    data_disks: []"
            if ($VMData.DataDisks -and $VMData.DataDisks.Count -gt 0) {
                $DataDisksYaml = "    data_disks:"
                foreach ($Disk in $VMData.DataDisks) {
                    $DataDisksYaml += "`n      - name: `"$($Disk.Name)`""
                    $DataDisksYaml += "`n        lun: $($Disk.Lun)"
                    $DataDisksYaml += "`n        size_gb: $($Disk.SizeGB)"
                    $DataDisksYaml += "`n        type: `"$($Disk.StorageAccountType)`""
                }
            }
            
            # Determine public IP value
            $PublicIpValue = if ($VMData.PublicIp) { "`"$($VMData.PublicIp)`"" } else { "null" }
            $AvailabilityZoneValue = if ($VMData.AvailabilityZone) { "$($VMData.AvailabilityZone)" } else { "null" }
            $IdentityValue = if ($VMData.Identity) { "`"$($VMData.Identity)`"" } else { "null" }
            $BootDiagValue = if ($VMData.BootDiagnostics) { "true" } else { "false" }
            $AccelNetValue = if ($VMData.AcceleratedNetworking) { "true" } else { "false" }
            
            $VMYaml = @"
  $VMKey`:
    # Identity
    name: "$($VMData.Name)"
    hostname: "$($VMData.ComputerName)"
    resource_group: "$($VMData.ResourceGroup)"
    location: "$($VMData.Location)"
    subscription: "$($VMData.Subscription)"
    role: ""
    # Compute
    vm_size: "$($VMData.VmSize)"
    availability_zone: $AvailabilityZoneValue
    # OS
    os_type: "$($VMData.OsType)"
    os: ""
    image:
      publisher: "$($VMData.ImagePublisher)"
      offer: "$($VMData.ImageOffer)"
      sku: "$($VMData.ImageSku)"
    # Networking
    private_ip: "$($VMData.PrivateIp)"
    public_ip: $PublicIpValue
    subnet: "$($VMData.Subnet)"
    nic_name: "$($VMData.NicName)"
    accelerated_networking: $AccelNetValue
    # Storage
    os_disk:
      name: "$($VMData.OsDiskName)"
      size_gb: $($VMData.OsDiskSizeGB)
      type: "$($VMData.OsDiskType)"
$DataDisksYaml
    # Management
    boot_diagnostics: $BootDiagValue
    managed_identity: $IdentityValue
    tags: {}
"@
            
            # Find the end of azure_vms section (before next major section)
            if ($UpdatedContent -match "(?ms)(azure_vms:.*?)((\r?\n)+# =+|\r?\nazure_infrastructure:)") {
                $UpdatedContent = $UpdatedContent -replace "(?ms)(azure_vms:.*?)((\r?\n)+# =+|\r?\nazure_infrastructure:)", "`$1`n$VMYaml`$2"
                Write-Host "  ✓ Added: azure_vms.$VMKey" -ForegroundColor Green
                $AddedCount++
            }
            else {
                Write-Host "  ⚠ Could not add VM: $($VMAdd.Name) (section not found)" -ForegroundColor Yellow
            }
        }
    }
}

# Update _metadata.discovery section with timestamps and source files
# Using targeted regex replacements to preserve formatting

# Update last_manual_edit timestamp
$Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
if ($UpdatedContent -match "last_manual_edit:") {
    $UpdatedContent = $UpdatedContent -replace "(last_manual_edit:)\s*[^\r\n]*", "`$1 `"$Timestamp`""
    Write-Host "  ✓ Updated: _metadata.last_manual_edit" -ForegroundColor Gray
}

# Update iDRAC discovery metadata
if ($iDRACLastRun) {
    # Convert timestamp to ISO format if needed
    $iDRACTimestamp = $iDRACLastRun
    if ($iDRACLastRun -notmatch "T") {
        # Convert "2025-12-05 19:48:43" to "2025-12-05T19:48:43Z"
        $iDRACTimestamp = $iDRACLastRun -replace " ", "T"
        if ($iDRACTimestamp -notmatch "Z$") { $iDRACTimestamp += "Z" }
    }
    
    # Update idrac.last_run
    if ($UpdatedContent -match "(?ms)discovery:.*?idrac:.*?last_run:") {
        $UpdatedContent = $UpdatedContent -replace "(idrac:\s*\r?\n\s*last_run:)\s*[^\r\n]*", "`$1 `"$iDRACTimestamp`""
        Write-Host "  ✓ Updated: _metadata.discovery.idrac.last_run" -ForegroundColor Gray
    }
    
    # Update idrac.source_file (singular, for consolidated file)
    $iDRACSourceFile = "discovery/idrac-inventory.json"
    if ($UpdatedContent -match "(?ms)idrac:.*?source_file:") {
        $UpdatedContent = $UpdatedContent -replace "(idrac:.*?source_file:)\s*[^\r\n]*", "`$1 `"$iDRACSourceFile`""
        Write-Host "  ✓ Updated: _metadata.discovery.idrac.source_file" -ForegroundColor Gray
    }
}

# Update Azure discovery metadata
if ($AzureLastRun) {
    # Convert timestamp to ISO format if needed
    $AzureTimestamp = $AzureLastRun -replace " UTC$", "Z" -replace " ", "T"
    if ($AzureTimestamp -notmatch "[TZ]") {
        $AzureTimestamp = $AzureLastRun -replace " ", "T"
    }
    if ($AzureTimestamp -notmatch "Z$" -and $AzureTimestamp -notmatch "\+") { 
        $AzureTimestamp += "Z" 
    }
    
    # Update azure.last_run
    if ($UpdatedContent -match "(?ms)discovery:.*?azure:.*?last_run:") {
        $UpdatedContent = $UpdatedContent -replace "(azure:\s*\r?\n\s*last_run:)\s*[^\r\n]*", "`$1 `"$AzureTimestamp`""
        Write-Host "  ✓ Updated: _metadata.discovery.azure.last_run" -ForegroundColor Gray
    }
    
    # Update azure.source_file
    if ($AzureFile -and $UpdatedContent -match "(?ms)azure:.*?source_file:") {
        $AzureSourceFile = "discovery/$($AzureFile.Name)"
        $UpdatedContent = $UpdatedContent -replace "(azure:.*?source_file:)\s*[^\r\n]*", "`$1 `"$AzureSourceFile`""
        Write-Host "  ✓ Updated: _metadata.discovery.azure.source_file" -ForegroundColor Gray
    }
}

# Save the updated content
try {
    Set-Content -Path $InfrastructurePath -Value $UpdatedContent -NoNewline
    $NewLength = (Get-Content -Path $InfrastructurePath -Raw).Length
    Write-Host "  ✓ Saved infrastructure.yml ($NewLength bytes)" -ForegroundColor Green
    
    # Verify the file wasn't corrupted
    if ([Math]::Abs($NewLength - $OriginalLength) -gt 500) {
        Write-Host "  ⚠ File size changed significantly. Please verify the output." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  ✗ Error saving: $_" -ForegroundColor Red
    Write-Host "  Backup available at: $BackupPath" -ForegroundColor Yellow
    exit 1
}

# Summary
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Infrastructure Updated Successfully                       ║" -ForegroundColor Green
Write-Host "║  (Format & Comments Preserved)                             ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Fields updated: $AppliedCount of $($Changes.Count)" -ForegroundColor White
Write-Host "  Resources added: $AddedCount of $($Additions.Count)" -ForegroundColor White
Write-Host "  Backup: backups/$BackupFileName" -ForegroundColor White
Write-Host ""
