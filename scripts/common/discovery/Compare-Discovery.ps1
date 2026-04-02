<#
.SYNOPSIS
    Compares discovery JSON files with current infrastructure.yml.

.DESCRIPTION
    Reads a discovery JSON file and compares it against the current
    infrastructure.yml, reporting:
    - New data found in discovery
    - Changed values (conflicts)
    - Data in infrastructure.yml not in discovery (unchanged/manual)

.PARAMETER DiscoveryFile
    Path to the discovery JSON file to compare.

.PARAMETER InfrastructureFile
    Path to infrastructure.yml. Defaults to repository root.

.PARAMETER OutputFormat
    Output format: Console, YAML, or JSON.

.EXAMPLE
    .\Compare-Discovery.ps1 -DiscoveryFile "discovery/azure-inventory-20251205.json"
    
.EXAMPLE
    .\Compare-Discovery.ps1 -DiscoveryFile "discovery/idrac-DWX3664-20251205.json" -OutputFormat YAML
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$DiscoveryFile,
    
    [Parameter()]
    [string]$InfrastructureFile = (Join-Path $PSScriptRoot "..\..\infrastructure.yml"),
    
    [Parameter()]
    [ValidateSet("Console", "YAML", "JSON")]
    [string]$OutputFormat = "Console"
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# CANONICAL FIELD MAPPINGS
# ==============================================================================
# Maps discovery JSON paths to infrastructure.yml paths
# This ensures consistent field naming across sources

$AzureDiscoveryMappings = @{
    # Tenant
    "Tenant.TenantId" = "azure.tenant.id"
    "Tenant.DisplayName" = "azure.tenant.name"
    "Tenant.DefaultDomain" = "azure.tenant.default_domain"
    
    # Active Directory (from discovery)
    "ActiveDirectory.Domain" = "active_directory.domain"
    "ActiveDirectory.NetBIOS" = "active_directory.netbios"
    "ActiveDirectory.DNS_Servers" = "active_directory.dns_servers"
    
    # VMs are handled specially - need to match by name
}

$iDRACDiscoveryMappings = @{
    "ServiceTag" = "service_tag"
    "SerialNumber" = "serial_number"
    "Model" = "model"
    "Processors[0].Model" = "cpu"
    "Processors[0].TotalCores" = "cores"
    "MemorySummary.TotalSystemMemoryGiB" = "memory_gb"
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Get-DiscoveryType {
    param([string]$FileName)
    
    $baseName = [System.IO.Path]::GetFileName($FileName)
    
    if ($baseName -match '^azure-') { return "Azure" }
    if ($baseName -match '^idrac-') { return "iDRAC" }
    if ($baseName -match '^switch-') { return "Switch" }
    if ($baseName -match '^unifi-') { return "UniFi" }
    
    return "Unknown"
}

function Compare-Values {
    param(
        [object]$Current,
        [object]$Discovered,
        [string]$Path
    )
    
    $results = @()
    
    # Handle null cases
    if ($null -eq $Current -and $null -eq $Discovered) {
        return $results
    }
    
    if ($null -eq $Current -and $null -ne $Discovered) {
        $results += [PSCustomObject]@{
            Path = $Path
            ChangeType = "NEW"
            CurrentValue = $null
            DiscoveredValue = $Discovered
        }
        return $results
    }
    
    if ($null -ne $Current -and $null -eq $Discovered) {
        # Discovery doesn't have this - that's OK, keep current
        return $results
    }
    
    # Compare based on type
    if ($Current -is [hashtable] -or $Current -is [System.Collections.IDictionary]) {
        if ($Discovered -is [hashtable] -or $Discovered -is [System.Collections.IDictionary]) {
            # Compare each key
            $allKeys = @($Current.Keys) + @($Discovered.Keys) | Select-Object -Unique
            foreach ($key in $allKeys) {
                $childPath = if ($Path) { "$Path.$key" } else { $key }
                $results += Compare-Values -Current $Current[$key] -Discovered $Discovered[$key] -Path $childPath
            }
        }
        else {
            $results += [PSCustomObject]@{
                Path = $Path
                ChangeType = "TYPE_MISMATCH"
                CurrentValue = $Current.GetType().Name
                DiscoveredValue = $Discovered.GetType().Name
            }
        }
    }
    elseif ($Current -is [array]) {
        if ($Discovered -is [array]) {
            $currentStr = ($Current | Sort-Object) -join ","
            $discoveredStr = ($Discovered | Sort-Object) -join ","
            if ($currentStr -ne $discoveredStr) {
                $results += [PSCustomObject]@{
                    Path = $Path
                    ChangeType = "CHANGED"
                    CurrentValue = $Current
                    DiscoveredValue = $Discovered
                }
            }
        }
        else {
            $results += [PSCustomObject]@{
                Path = $Path
                ChangeType = "TYPE_MISMATCH"
                CurrentValue = "Array"
                DiscoveredValue = $Discovered.GetType().Name
            }
        }
    }
    else {
        # Scalar comparison
        if ($Current.ToString() -ne $Discovered.ToString()) {
            $results += [PSCustomObject]@{
                Path = $Path
                ChangeType = "CHANGED"
                CurrentValue = $Current
                DiscoveredValue = $Discovered
            }
        }
    }
    
    return $results
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Discovery Comparison" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Resolve paths
if (-not [System.IO.Path]::IsPathRooted($DiscoveryFile)) {
    $DiscoveryFile = Join-Path (Get-Location) $DiscoveryFile
}

if (-not [System.IO.Path]::IsPathRooted($InfrastructureFile)) {
    $InfrastructureFile = Join-Path (Get-Location) $InfrastructureFile
}

# Check files exist
if (-not (Test-Path $DiscoveryFile)) {
    Write-Host "ERROR: Discovery file not found: $DiscoveryFile" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $InfrastructureFile)) {
    Write-Host "ERROR: Infrastructure file not found: $InfrastructureFile" -ForegroundColor Red
    exit 1
}

$discoveryType = Get-DiscoveryType -FileName $DiscoveryFile

Write-Host "Discovery Type: $discoveryType" -ForegroundColor Gray
Write-Host "Discovery File: $DiscoveryFile" -ForegroundColor Gray
Write-Host "Infrastructure: $InfrastructureFile" -ForegroundColor Gray
Write-Host ""

# Load discovery JSON
try {
    $discovery = Get-Content -Path $DiscoveryFile -Raw | ConvertFrom-Json -AsHashtable
}
catch {
    Write-Host "ERROR: Failed to parse discovery JSON: $_" -ForegroundColor Red
    exit 1
}

# Load infrastructure YAML
try {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host "ERROR: powershell-yaml module required" -ForegroundColor Red
        Write-Host "Install with: Install-Module -Name powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
    
    Import-Module powershell-yaml
    $infraContent = Get-Content -Path $InfrastructureFile -Raw
    $infrastructure = ConvertFrom-Yaml -Yaml $infraContent
}
catch {
    Write-Host "ERROR: Failed to parse infrastructure YAML: $_" -ForegroundColor Red
    exit 1
}

# Perform comparison based on discovery type
$changes = @()
$newItems = @()
$conflicts = @()

switch ($discoveryType) {
    "Azure" {
        Write-Host "Comparing Azure discovery data..." -ForegroundColor Yellow
        
        # Compare tenant info
        if ($discovery.Tenant) {
            $changes += Compare-Values -Current $infrastructure.azure.tenant -Discovered @{
                id = $discovery.Tenant.TenantId
                name = $discovery.Tenant.DisplayName
                default_domain = $discovery.Tenant.DefaultDomain
            } -Path "azure.tenant"
        }
        
        # Compare Active Directory
        if ($discovery.ActiveDirectory) {
            $changes += Compare-Values -Current $infrastructure.active_directory -Discovered @{
                domain = $discovery.ActiveDirectory.Domain
                netbios = $discovery.ActiveDirectory.NetBIOS
                dns_servers = $discovery.ActiveDirectory.DNS_Servers
            } -Path "active_directory"
        }
        
        # Compare VMs
        if ($discovery.Resources) {
            $discoveredVMs = $discovery.Resources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }
            
            foreach ($vm in $discoveredVMs) {
                # Find matching VM in infrastructure by name
                $vmKey = $null
                foreach ($key in $infrastructure.azure_vms.Keys) {
                    if ($infrastructure.azure_vms[$key].name -eq $vm.Name) {
                        $vmKey = $key
                        break
                    }
                }
                
                if ($vmKey) {
                    # Compare existing VM
                    $changes += Compare-Values -Current $infrastructure.azure_vms[$vmKey] -Discovered @{
                        name = $vm.Name
                        resource_group = $vm.ResourceGroupName
                        location = $vm.Location
                    } -Path "azure_vms.$vmKey"
                }
                else {
                    # New VM discovered
                    $newItems += [PSCustomObject]@{
                        Type = "Azure VM"
                        Name = $vm.Name
                        ResourceGroup = $vm.ResourceGroupName
                        Location = $vm.Location
                    }
                }
            }
        }
    }
    
    "iDRAC" {
        Write-Host "Comparing iDRAC discovery data..." -ForegroundColor Yellow
        
        # Find node by service tag
        $serviceTag = $discovery.ServiceTag
        $nodeKey = $null
        
        foreach ($key in $infrastructure.nodes.Keys) {
            if ($infrastructure.nodes[$key].service_tag -eq $serviceTag) {
                $nodeKey = $key
                break
            }
        }
        
        if ($nodeKey) {
            $discoveredData = @{
                service_tag = $discovery.ServiceTag
                serial_number = $discovery.SerialNumber
                model = $discovery.Model
            }
            
            # Add hardware specs if available
            if ($discovery.Processors -and $discovery.Processors.Count -gt 0) {
                $discoveredData.cpu = $discovery.Processors[0].Model
                $discoveredData.cores = $discovery.Processors[0].TotalCores
            }
            
            if ($discovery.MemorySummary) {
                $discoveredData.memory_gb = $discovery.MemorySummary.TotalSystemMemoryGiB
            }
            
            $changes += Compare-Values -Current $infrastructure.nodes[$nodeKey] -Discovered $discoveredData -Path "nodes.$nodeKey"
        }
        else {
            $newItems += [PSCustomObject]@{
                Type = "Cluster Node"
                ServiceTag = $serviceTag
                Model = $discovery.Model
            }
        }
    }
    
    default {
        Write-Host "Unknown discovery type. Manual review required." -ForegroundColor Yellow
    }
}

# Filter results
$actualChanges = $changes | Where-Object { $_.ChangeType -eq "CHANGED" }
$actualNew = $changes | Where-Object { $_.ChangeType -eq "NEW" }

# Output results
Write-Host "`n----------------------------------------" -ForegroundColor Gray
Write-Host "COMPARISON RESULTS" -ForegroundColor Cyan
Write-Host "----------------------------------------`n" -ForegroundColor Gray

if ($actualChanges.Count -eq 0 -and $actualNew.Count -eq 0 -and $newItems.Count -eq 0) {
    Write-Host "No differences found. Infrastructure is up to date." -ForegroundColor Green
}
else {
    if ($actualChanges.Count -gt 0) {
        Write-Host "CONFLICTS (require review):" -ForegroundColor Yellow
        foreach ($change in $actualChanges) {
            Write-Host "  $($change.Path):" -ForegroundColor White
            Write-Host "    Current:    $($change.CurrentValue)" -ForegroundColor Red
            Write-Host "    Discovered: $($change.DiscoveredValue)" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    if ($actualNew.Count -gt 0) {
        Write-Host "NEW DATA (can be added):" -ForegroundColor Green
        foreach ($new in $actualNew) {
            Write-Host "  $($new.Path): $($new.DiscoveredValue)" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    if ($newItems.Count -gt 0) {
        Write-Host "NEW RESOURCES (require manual addition):" -ForegroundColor Cyan
        foreach ($item in $newItems) {
            Write-Host "  Type: $($item.Type)" -ForegroundColor Cyan
            $item.PSObject.Properties | Where-Object { $_.Name -ne "Type" } | ForEach-Object {
                Write-Host "    $($_.Name): $($_.Value)" -ForegroundColor White
            }
        }
        Write-Host ""
    }
}

Write-Host "----------------------------------------" -ForegroundColor Gray
Write-Host "Summary: $($actualChanges.Count) conflicts, $($actualNew.Count) new fields, $($newItems.Count) new resources" -ForegroundColor Cyan
Write-Host "----------------------------------------`n" -ForegroundColor Gray

# Return structured output if requested
if ($OutputFormat -eq "JSON") {
    @{
        Conflicts = $actualChanges
        NewFields = $actualNew
        NewResources = $newItems
    } | ConvertTo-Json -Depth 10
}
elseif ($OutputFormat -eq "YAML") {
    if (Get-Module -ListAvailable -Name powershell-yaml) {
        @{
            Conflicts = $actualChanges
            NewFields = $actualNew
            NewResources = $newItems
        } | ConvertTo-Yaml
    }
}
