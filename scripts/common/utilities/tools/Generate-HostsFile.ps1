<#
.SYNOPSIS
    Generate Windows hosts file entries from infrastructure.yml.

.DESCRIPTION
    Generates hosts file entries for Azure Local nodes, domain controllers,
    and Azure VMs based on infrastructure.yml or solution configuration.

.PARAMETER Solution
    Solution name to load configuration from (e.g., "azure-local").

.PARAMETER HostsPath
    Path to the hosts file. Default: C:\Windows\System32\drivers\etc\hosts

.PARAMETER OutputOnly
    Only display entries, do not write to hosts file.

.EXAMPLE
    .\Generate-HostsFile.ps1 -Solution "azure-local"
    
.EXAMPLE
    .\Generate-HostsFile.ps1 -Solution "azure-local" -OutputOnly

.NOTES
    Run this script as Administrator to modify the hosts file.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$HostsPath = "C:\Windows\System32\drivers\etc\hosts",

    [Parameter(Mandatory = $false)]
    [switch]$OutputOnly
)

# Load configuration
if ($Solution) {
    . "$PSScriptRoot\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Build entries from config
    $entries = @"

# Azure Local Environment - Added $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# Generated from solution: $Solution
"@
    
    # Add nodes
    if ($config.compute.cluster_nodes) {
        $entries += "`n# Azure Local Nodes`n"
        foreach ($node in $config.compute.cluster_nodes.PSObject.Properties) {
            $nodeData = $node.Value
            $entries += "$($nodeData.management_ip)    $($nodeData.hostname).$($config.identity.active_directory.fqdn) $($nodeData.hostname)`n"
        }
    }
    
    # Add iDRACs
    if ($config.compute.cluster_nodes) {
        $entries += "`n# Node iDRACs`n"
        foreach ($node in $config.compute.cluster_nodes.PSObject.Properties) {
            $nodeData = $node.Value
            if ($nodeData.idrac_ip) {
                $entries += "$($nodeData.idrac_ip)    $($nodeData.hostname)-idrac.$($config.identity.active_directory.fqdn) $($nodeData.hostname)-idrac`n"
            }
        }
    }
} else {
    # Fallback to hardcoded example entries
    $entries = @"

# Azure Local Test Site - Added $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# Generated from solution configuration
# Domain Controllers
# NOTE: This file contains example entries.
# For production use, load values from solution.yaml:
#   $config = Get-SolutionConfig -Solution "azure-local"
#   $dcNodes = $config.infrastructure_vms | Where-Object { $_.role -eq 'domain-controller' }

# Example Domain Controllers
10.1.0.10    DC01.azurelocal.mgmt DC01
10.1.0.11    DC02.azurelocal.mgmt DC02

# Azure Local Cluster (load from solution.yaml: azure_local.cluster_name)
192.168.150.20    cluster01.azurelocal.mgmt cluster01
192.168.150.21    cluster01-vco.azurelocal.mgmt cluster01-vco

# Azure Local Nodes
192.168.150.11    node01.azurelocal.mgmt node01
192.168.150.12    node02.azurelocal.mgmt node02

# Node iDRACs
192.168.200.251    node01-idrac.azurelocal.mgmt node01-idrac
192.168.200.252    node02-idrac.azurelocal.mgmt node02-idrac

"@
}

if ($OutputOnly) {
    Write-Host $entries
} elseif ($PSCmdlet.ShouldProcess($HostsPath, "Add hosts entries")) {
    Add-Content -Path $HostsPath -Value $entries
    Write-Host "Hosts file updated successfully!" -ForegroundColor Green
    Write-Host "`nVerifying entries:" -ForegroundColor Cyan
    Get-Content $HostsPath | Select-String -Pattern "Azure Local" -Context 0,12
}
