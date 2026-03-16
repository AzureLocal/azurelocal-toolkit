<#
.SYNOPSIS
    Inventories on-premises servers and clusters.

.DESCRIPTION
    Discovers on-premises Windows servers, failover clusters, and related 
    infrastructure. Outputs inventory for use in automation.

.PARAMETER Domain
    The Active Directory domain to query.

.PARAMETER OUPath
    Optional. Specific OU to search.

.PARAMETER OutputPath
    Optional. Path to save output as JSON.

.EXAMPLE
    .\Get-OnPremInventory.ps1 -Domain "hybrid.mgmt"

.EXAMPLE
    .\Get-OnPremInventory.ps1 -Domain "hybrid.mgmt" -OUPath "OU=Servers,DC=hybrid,DC=mgmt" -OutputPath "inventory.json"

.NOTES
    Requires Active Directory PowerShell module and appropriate permissions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$Domain,

    [Parameter(Mandatory = $false)]
    [string]$OUPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# Import shared utilities
$scriptRoot = Split-Path -Parent $PSScriptRoot
. "$scriptRoot\utilities\helpers\logging.ps1"

Write-Log -Level Info -Message "Starting on-premises inventory for domain: $Domain"

try {
    # Check AD module
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log -Level Error -Message "ActiveDirectory module not found. Install RSAT tools."
        exit 1
    }

    Import-Module ActiveDirectory

    $inventory = @{
        Domain = $Domain
        DiscoveryDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Servers = @()
        Clusters = @()
    }

    # Build search parameters
    $searchParams = @{
        Filter = 'OperatingSystem -like "*Server*"'
        Properties = @('Name', 'OperatingSystem', 'IPv4Address', 'Enabled', 'LastLogonDate')
    }
    
    if ($OUPath) {
        $searchParams.SearchBase = $OUPath
    }

    # Get servers
    Write-Log -Level Info -Message "Discovering servers..."
    $servers = Get-ADComputer @searchParams

    foreach ($server in $servers) {
        $inventory.Servers += @{
            Name = $server.Name
            OperatingSystem = $server.OperatingSystem
            IPAddress = $server.IPv4Address
            Enabled = $server.Enabled
            LastLogon = $server.LastLogonDate
        }
    }
    Write-Log -Level Info -Message "Found $($inventory.Servers.Count) server(s)"

    # Try to discover clusters (requires FailoverClusters module on discovery machine or remote query)
    try {
        Write-Log -Level Info -Message "Discovering failover clusters..."
        $clusterObjects = Get-ADComputer -Filter 'ServicePrincipalNames -like "*MSClusterVirtualServer*"' -Properties ServicePrincipalNames
        
        foreach ($cluster in $clusterObjects) {
            $inventory.Clusters += @{
                Name = $cluster.Name
                Type = "FailoverCluster"
            }
        }
        Write-Log -Level Info -Message "Found $($inventory.Clusters.Count) cluster(s)"
    }
    catch {
        Write-Log -Level Warning -Message "Could not discover clusters: $_"
    }

    # Output results
    $output = $inventory | ConvertTo-Json -Depth 10

    if ($OutputPath) {
        $output | Set-Content -Path $OutputPath
        Write-Log -Level Info -Message "Output saved to: $OutputPath"
    } else {
        Write-Output $output
    }

    Write-Log -Level Info -Message "On-premises inventory complete"
}
catch {
    Write-Log -Level Error -Message "Inventory failed: $_"
    throw
}
