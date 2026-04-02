<#
.SYNOPSIS
    Generate cluster-config.md from infrastructure.yml.

.DESCRIPTION
    Reads infrastructure.yml and generates a human-readable cluster-config.md
    document with all configuration organized by logical sections.
    Supports solution-based configuration or direct file paths.

    Run this script:
    - After updating infrastructure.yml
    - After running Update-InfrastructureFromDiscovery.ps1
    - Before deployment to verify configuration

.PARAMETER Solution
    Solution name to load configuration from (e.g., "azure-local").
    When specified, paths are derived from solution configuration.

.PARAMETER InfrastructurePath
    Path to infrastructure.yml. Default: repository root.

.PARAMETER OutputPath
    Path for cluster-config.md. Default: repository root.

.EXAMPLE
    # Using solution configuration
    .\Generate-ClusterConfigMD.ps1 -Solution "azure-local"

.EXAMPLE
    .\Generate-ClusterConfigMD.ps1

.EXAMPLE
    .\Generate-ClusterConfigMD.ps1 -InfrastructurePath ".\infrastructure.yml"

.NOTES
    File: Generate-ClusterConfigMD.ps1
    Author: Azure Local Documentation Team
    Version: 1.1.0
    Created: 2025-12-05
    
    Requires: powershell-yaml module
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$InfrastructurePath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

# Repository root detection
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $RepoRoot

# Load configuration if Solution specified
if ($Solution) {
    . "$PSScriptRoot\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Derive paths from solution
    if (-not $InfrastructurePath) {
        $InfrastructurePath = Join-Path $RepoRoot "solutions\$Solution\config\infrastructure.yml"
    }
    if (-not $OutputPath) {
        $OutputPath = Join-Path $RepoRoot "solutions\$Solution\docs\cluster-config.md"
    }
}

# Set default paths if still not set
if (-not $InfrastructurePath) {
    $InfrastructurePath = Join-Path $RepoRoot "infrastructure.yml"
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $RepoRoot "cluster-config.md"
}

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Generate Cluster Config Markdown                          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`nSource: $InfrastructurePath" -ForegroundColor White
Write-Host "Output: $OutputPath" -ForegroundColor White
Write-Host ""

# Check for powershell-yaml module
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "✗ powershell-yaml module not found" -ForegroundColor Red
    Write-Host "  Install with: Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

Import-Module powershell-yaml -ErrorAction Stop

# Check if infrastructure.yml exists
if (-not (Test-Path $InfrastructurePath)) {
    Write-Host "✗ infrastructure.yml not found: $InfrastructurePath" -ForegroundColor Red
    exit 1
}

# Load infrastructure.yml
Write-Host "[1/2] Loading infrastructure.yml..." -ForegroundColor Cyan

try {
    $YamlContent = Get-Content -Path $InfrastructurePath -Raw
    $Config = ConvertFrom-Yaml -Yaml $YamlContent -Ordered
    Write-Host "  ✓ Loaded infrastructure configuration" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Error loading infrastructure.yml: $_" -ForegroundColor Red
    exit 1
}

# Helper function to generate markdown table
function Generate-Table {
    param(
        [array]$Fields,
        [hashtable]$Data
    )
    
    $table = "| Variable | Value |`n|----------|-------|"
    foreach ($field in $Fields) {
        $value = $Data[$field.Key]
        if ($null -eq $value -or $value -eq "") { 
            $value = "(not set)" 
        }
        $table += "`n| $($field.Name) | $value |"
    }
    return $table
}

# Helper to safely get nested value
function Get-NestedValue {
    param($Object, [string]$Path)
    
    $parts = $Path -split '\.'
    $current = $Object
    
    foreach ($part in $parts) {
        if ($null -eq $current) { return $null }
        $current = $current[$part]
    }
    
    return $current
}

Write-Host "`n[2/2] Generating cluster-config.md..." -ForegroundColor Cyan

# Extract site code
$SiteCode = $Config.site.code

# Build markdown content
$MDContent = @"
# Cluster Configuration for $SiteCode Site

**Generated from infrastructure.yml**

**Date:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

**Source:** infrastructure.yml (Single Source of Truth)

This document provides a human-readable view of the cluster configuration, organized by logical sections.

---

## Site and Cluster Basics

| Variable | Value |
|----------|-------|
| Site Code | $($Config.site.code) |
| Site Name | $($Config.site.name) |
| Location | $($Config.site.location) |
| Environment | $($Config.site.environment) |
| Owner | $($Config.site.owner) |
| Cluster Name | $($config.compute.azure_local.cluster_name) |
| Cluster IP | N/A (removed in v4.0.0 — use infrastructure_pool_start/end) |
| Virtual IP | N/A (removed in v4.0.0 — not applicable to Azure Local) |
| Node Count | $($config.compute.azure_local.cluster_node_count) |

## Azure Configuration

| Variable | Value |
|----------|-------|
| Tenant ID | $($config.azure_platform.tenant.id) |
| Tenant Name | $($config.azure_platform.tenant.name) |
| Default Domain | $($config.azure_platform.tenant.default_domain) |

### Subscriptions

"@

# Add subscriptions
if ($config.azure_platform.subscriptions) {
    foreach ($subKey in $config.azure_platform.subscriptions.Keys) {
        $sub = $config.azure_platform.subscriptions[$subKey]
        $MDContent += @"

#### $subKey
| Variable | Value |
|----------|-------|
| Subscription ID | $($sub.id) |
| Subscription Name | $($sub.name) |

"@
    }
}

$MDContent += @"

## Active Directory

| Variable | Value |
|----------|-------|
| Domain FQDN | $($config.identity.active_directory.fqdn) |
| NetBIOS Name | $($config.identity.active_directory.ad_netbios_name) |
| OU Path | $($config.identity.active_directory.ad_ou_path) |
| DNS Server 1 | $(($config.networking.onprem.dhcp.management_compute.dns_primary | Select-Object -First 1)) |
| DNS Server 2 | $(($config.networking.onprem.dhcp.management_compute.dns_primary | Select-Object -Skip 1 -First 1)) |

### Domain Controllers

"@

# Add domain controllers
if ($config.compute.azure_vms) {
    foreach ($dcKey in $config.compute.azure_vms.Keys) {
        $dc = $config.compute.azure_vms[$dcKey]
        $MDContent += @"

#### $dcKey
| Variable | Value |
|----------|-------|
| Name | $($dc.name) |
| FQDN | $($dc.fqdn) |
| IP Address | $($dc.ip) |
| Role | $($dc.role) |

"@
    }
}

$MDContent += @"

## Network Configuration


### VLANs

"@

# Add VLANs
if ($config.networking.onprem.vlans) {
    foreach ($vlanKey in $config.networking.onprem.vlans.Keys) {
        $vlan = $config.networking.onprem.vlans[$vlanKey]
        $MDContent += @"

#### VLAN: $vlanKey (ID: $($vlan.id))
| Variable | Value |
|----------|-------|
| Name | $($vlan.name) |
| CIDR | $($vlan.cidr) |
| Gateway | $($vlan.gateway) |
| Purpose | $($vlan.purpose) |

"@
    }
}

$MDContent += @"

## Cluster Configuration

| Variable | Value |
|----------|-------|
| Cluster Name | $($config.compute.azure_local.cluster_name) |
| Cluster IP | N/A (removed in v4.0.0 — use infrastructure_pool_start/end) |
| Virtual IP | N/A (removed in v4.0.0 — not applicable to Azure Local) |
| Management VLAN | $($config.networking.onprem.vlans.management.id) |
| Node Count | $($config.compute.azure_local.cluster_node_count) |

### Network Intents

"@

# Add network intents
if ($config.compute.azure_local.network_intents) {
    foreach ($intent in $config.compute.azure_local.network_intents) {
        $MDContent += @"

#### $($intent.name)
| Variable | Value |
|----------|-------|
| Traffic Types | $($intent.traffic_types -join '; ') |
| Adapters | $($intent.adapters -join ', ') |

"@
    }
}

$MDContent += @"

### Logical Networks

"@

# Add logical networks
if ($config.compute.azure_local.logical_networks) {
    foreach ($lnet in $config.compute.azure_local.logical_networks) {
        $MDContent += @"

#### $($lnet.name)
| Variable | Value |
|----------|-------|
| Display Name | $($lnet.display_name) |
| VLAN | $($lnet.vlan) |
| CIDR | $($lnet.cidr) |
| Gateway | $($lnet.gateway) |
| DNS Servers | $($lnet.dns_servers -join ', ') |
| IP Pool | $($lnet.ip_pool_start) - $($lnet.ip_pool_end) |
| Purpose | $($lnet.purpose) |

"@
    }
}

$MDContent += @"

## Nodes

"@

# Add nodes
if ($config.compute.cluster_nodes) {
    $nodeIndex = 1
    foreach ($nodeKey in $config.compute.cluster_nodes.Keys) {
        $node = $config.compute.cluster_nodes[$nodeKey]
        $MDContent += @"

### Node $nodeIndex`: $($node.name)

| Variable | Value |
|----------|-------|
| Hostname | $($node.name) |
| FQDN | $($node.fqdn) |
| Management IP | $($node.management_ip) |
| iDRAC IP | $($node.idrac_ip) |
| Service Tag | $($node.service_tag) |
| Serial Number | $($node.serial_number) |
| Model | $($node.model) |
| Management VLAN | $($node.management_vlan) |

"@
        
        if ($node.hardware) {
            $MDContent += @"

#### Hardware
| Variable | Value |
|----------|-------|
| CPU | $($node.hardware.cpu) |
| Cores | $($node.hardware.cores) |
| Memory | $($node.hardware.memory) |

"@
        }

        if ($node.network_adapters) {
            $MDContent += @"

#### Network Adapters
| Port | MAC Address |
|------|-------------|
"@
            foreach ($adapterKey in $node.network_adapters.Keys) {
                $adapter = $node.network_adapters[$adapterKey]
                $MDContent += "| $adapterKey | $($adapter.mac) |`n"
            }
            $MDContent += "`n"
        }

        $nodeIndex++
    }
}

$MDContent += @"

## Network Devices

"@

# Add network devices
if ($config.networking.onprem.network_devices) {
    foreach ($deviceKey in $config.networking.onprem.network_devices.Keys) {
        $device = $config.networking.onprem.network_devices[$deviceKey]
        $MDContent += @"

### $deviceKey`: $($device.name)

| Variable | Value |
|----------|-------|
| Model | $($device.model) |
| Management IP | $($device.management_ip) |
| VLAN | $($device.vlan) |
| Purpose | $($device.purpose) |

"@
    }
}

$MDContent += @"

## Azure VMs

"@

# Add Azure VMs
if ($config.compute.azure_vms) {
    foreach ($vmKey in $config.compute.azure_vms.Keys) {
        $vm = $config.compute.azure_vms[$vmKey]
        $MDContent += @"

### $vmKey`: $($vm.name)

| Variable | Value |
|----------|-------|
| Name | $($vm.name) |
| Private IP | $($vm.private_ip) |
| FQDN | $($vm.fqdn) |
| Role | $($vm.role) |
| Resource Group | $($vm.resource_group) |
| Location | $($vm.location) |
| Subscription | $($vm.subscription) |

"@
    }
}

$MDContent += @"

---

## Metadata

| Variable | Value |
|----------|-------|
| Schema Version | $($Config._metadata.schema_version) |
| Last Manual Edit | $($Config._metadata.last_manual_edit) |
| iDRAC Discovery | $($Config._metadata.discovery.idrac.last_run) |
| Azure Discovery | $($Config._metadata.discovery.azure.last_run) |

---

**Note:** This document is auto-generated from infrastructure.yml. 
Edit infrastructure.yml and regenerate this file with:

``````powershell
.\scripts\docs\Generate-ClusterConfigMD.ps1
``````

"@

# Save markdown file
try {
    Set-Content -Path $OutputPath -Value $MDContent -Force
    Write-Host "  ✓ Generated: $($OutputPath | Split-Path -Leaf)" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Error saving markdown: $_" -ForegroundColor Red
    exit 1
}

# Summary
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Cluster Config Markdown Generated Successfully            ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`nOutput: $OutputPath" -ForegroundColor Cyan
Write-Host ""
