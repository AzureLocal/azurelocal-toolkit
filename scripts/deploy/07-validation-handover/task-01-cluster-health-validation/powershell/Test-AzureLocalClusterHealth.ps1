<#
.SYNOPSIS
    Validates Azure Local cluster health and configuration.

.DESCRIPTION
    This script performs comprehensive cluster health validation including:
    - Cluster service status
    - Node health and connectivity
    - Storage Spaces Direct health
    - Network adapter status
    - Azure Arc connection status

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name (the cluster to validate); the whole file is not validated here.

.PARAMETER OutputFormat
    Output format: Console, JSON, or HTML. Default: Console

.PARAMETER OutputPath
    Path to save the validation report (for JSON/HTML output).

.EXAMPLE
    .\Test-AzureLocalClusterHealth.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    .\Test-AzureLocalClusterHealth.ps1 -InfrastructureFile ./infrastructure.yml -OutputFormat HTML -OutputPath "C:\Reports"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Must be run from a cluster node or management server with RSAT tools installed.
#>
#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read by the functions of the script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names of the check functions inside the script.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Console", "JSON", "HTML")]
    [string]$OutputFormat = "Console",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$script:ErrorCount = 0
function Write-Line {
    param([string]$Message, [string]$Level = 'INFO')
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } default { 'White' } }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Error "Cannot read the infrastructure file: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
$ClusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $ClusterName) { Write-Error 'cluster.name is missing in the infrastructure file. It is the name of the cluster to validate.' -ErrorAction Continue; exit 2 }

# Initialize results collection
$ValidationResults = @{
    Timestamp        = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    ClusterName      = $ClusterName
    OverallStatus    = "Unknown"
    Checks           = @()
}

function Add-ValidationResult {
    param(
        [string]$Category,
        [string]$Check,
        [string]$Status,
        [string]$Message,
        [object]$Details = $null
    )
    
    $result = @{
        Category = $Category
        Check    = $Check
        Status   = $Status
        Message  = $Message
        Details  = $Details
    }
    
    $script:ValidationResults.Checks += $result
    
    $statusColor = switch ($Status) {
        "PASSED" { "Green" }
        "FAILED" { "Red" }
        "WARNING" { "Yellow" }
        default { "White" }
    }
    
    if ($OutputFormat -eq "Console") {
        Write-Host "  [$Status] $Category - $Check" -ForegroundColor $statusColor
        if ($Message) {
            Write-Host "         $Message" -ForegroundColor Gray
        }
    }
}

function Test-ClusterService {
    Write-Line -Message "Checking cluster service status..." -Level "INFO"
    
    try {
        $cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
        
        Add-ValidationResult -Category "Cluster" -Check "Cluster Service" `
            -Status "PASSED" -Message "Cluster '$($cluster.Name)' is online" `
            -Details @{ Name = $cluster.Name; Domain = $cluster.Domain }
    }
    catch {
        Add-ValidationResult -Category "Cluster" -Check "Cluster Service" `
            -Status "FAILED" -Message "Cannot connect to cluster: $($_.Exception.Message)"
        return $false
    }
    
    return $true
}

function Test-ClusterNodes {
    Write-Line -Message "Checking cluster node health..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop
        
        foreach ($node in $nodes) {
            if ($node.State -eq "Up") {
                Add-ValidationResult -Category "Nodes" -Check "Node: $($node.Name)" `
                    -Status "PASSED" -Message "State: $($node.State)" `
                    -Details @{ Name = $node.Name; State = $node.State.ToString() }
            }
            else {
                Add-ValidationResult -Category "Nodes" -Check "Node: $($node.Name)" `
                    -Status "FAILED" -Message "State: $($node.State)" `
                    -Details @{ Name = $node.Name; State = $node.State.ToString() }
            }
        }
    }
    catch {
        Add-ValidationResult -Category "Nodes" -Check "Node Health" `
            -Status "FAILED" -Message "Cannot retrieve node information: $($_.Exception.Message)"
    }
}

function Test-StorageSpacesDirect {
    Write-Line -Message "Checking Storage Spaces Direct health..." -Level "INFO"
    
    try {
        # Check S2D status
        $s2d = Get-ClusterStorageSpacesDirect -CimSession $ClusterName -ErrorAction Stop
        
        if ($s2d.State -eq "Enabled") {
            Add-ValidationResult -Category "Storage" -Check "Storage Spaces Direct" `
                -Status "PASSED" -Message "S2D is enabled and running" `
                -Details @{ State = $s2d.State.ToString() }
        }
        else {
            Add-ValidationResult -Category "Storage" -Check "Storage Spaces Direct" `
                -Status "FAILED" -Message "S2D state: $($s2d.State)" `
                -Details @{ State = $s2d.State.ToString() }
        }
        
        # Check storage pools
        $pools = Get-StoragePool -CimSession $ClusterName | Where-Object { $_.IsPrimordial -eq $false }
        
        foreach ($pool in $pools) {
            if ($pool.HealthStatus -eq "Healthy") {
                Add-ValidationResult -Category "Storage" -Check "Pool: $($pool.FriendlyName)" `
                    -Status "PASSED" -Message "Health: $($pool.HealthStatus)" `
                    -Details @{ Name = $pool.FriendlyName; Health = $pool.HealthStatus.ToString() }
            }
            else {
                Add-ValidationResult -Category "Storage" -Check "Pool: $($pool.FriendlyName)" `
                    -Status "FAILED" -Message "Health: $($pool.HealthStatus)" `
                    -Details @{ Name = $pool.FriendlyName; Health = $pool.HealthStatus.ToString() }
            }
        }
        
        # Check virtual disks
        $vDisks = Get-VirtualDisk -CimSession $ClusterName | Where-Object { $_.HealthStatus -ne "Healthy" }
        
        if (@($vDisks).Count -eq 0) {
            Add-ValidationResult -Category "Storage" -Check "Virtual Disks" `
                -Status "PASSED" -Message "All virtual disks are healthy"
        }
        else {
            Add-ValidationResult -Category "Storage" -Check "Virtual Disks" `
                -Status "FAILED" -Message "$(@($vDisks).Count) unhealthy virtual disk(s)" `
                -Details @($vDisks | Select-Object FriendlyName, HealthStatus)
        }
    }
    catch {
        Add-ValidationResult -Category "Storage" -Check "Storage Spaces Direct" `
            -Status "FAILED" -Message "Cannot check S2D: $($_.Exception.Message)"
    }
}

function Test-ClusterNetworks {
    Write-Line -Message "Checking cluster network health..." -Level "INFO"
    
    try {
        $networks = Get-ClusterNetwork -Cluster $ClusterName -ErrorAction Stop
        
        foreach ($network in $networks) {
            if ($network.State -eq "Up") {
                Add-ValidationResult -Category "Network" -Check "Network: $($network.Name)" `
                    -Status "PASSED" -Message "State: $($network.State), Role: $($network.Role)" `
                    -Details @{ Name = $network.Name; State = $network.State.ToString(); Role = $network.Role.ToString() }
            }
            else {
                Add-ValidationResult -Category "Network" -Check "Network: $($network.Name)" `
                    -Status "FAILED" -Message "State: $($network.State)" `
                    -Details @{ Name = $network.Name; State = $network.State.ToString() }
            }
        }
    }
    catch {
        Add-ValidationResult -Category "Network" -Check "Cluster Networks" `
            -Status "FAILED" -Message "Cannot check networks: $($_.Exception.Message)"
    }
}

function Test-ClusterQuorum {
    Write-Line -Message "Checking cluster quorum..." -Level "INFO"
    
    try {
        $quorum = Get-ClusterQuorum -Cluster $ClusterName -ErrorAction Stop
        
        Add-ValidationResult -Category "Quorum" -Check "Quorum Configuration" `
            -Status "PASSED" -Message "Type: $($quorum.QuorumType)" `
            -Details @{ Type = $quorum.QuorumType.ToString(); Resource = $quorum.QuorumResource.Name }
    }
    catch {
        Add-ValidationResult -Category "Quorum" -Check "Quorum Configuration" `
            -Status "FAILED" -Message "Cannot check quorum: $($_.Exception.Message)"
    }
}

function Test-ArcConnection {
    Write-Line -Message "Checking Azure Arc connection status..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName
        
        foreach ($node in $nodes) {
            $arcStatus = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                $agentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
                if (Test-Path $agentPath) {
                    $status = & $agentPath show --json 2>$null | ConvertFrom-Json
                    return @{
                        Installed = $true
                        Status    = $status.status
                        LastHeartbeat = $status.lastHeartbeat
                    }
                }
                else {
                    return @{ Installed = $false }
                }
            } -ErrorAction SilentlyContinue
            
            if ($null -eq $arcStatus) {
                Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" -Status "FAILED" -Message "The Arc agent status could not be read from the node"
            }
            elseif ($arcStatus.Installed -and $arcStatus.Status -eq "Connected") {
                Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" `
                    -Status "PASSED" -Message "Arc agent connected" `
                    -Details $arcStatus
            }
            elseif ($arcStatus.Installed) {
                Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" `
                    -Status "WARNING" -Message "Arc agent status: $($arcStatus.Status)" `
                    -Details $arcStatus
            }
            else {
                Add-ValidationResult -Category "Azure Arc" -Check "Node: $($node.Name)" `
                    -Status "FAILED" -Message "Arc agent not installed"
            }
        }
    }
    catch {
        Add-ValidationResult -Category "Azure Arc" -Check "Arc Connection" `
            -Status "FAILED" -Message "Cannot check Arc status: $($_.Exception.Message)"
    }
}

function Export-Results {
    # Calculate overall status
    $failedCount = @($ValidationResults.Checks | Where-Object { $_.Status -eq "FAILED" }).Count
    $warningCount = @($ValidationResults.Checks | Where-Object { $_.Status -eq "WARNING" }).Count
    
    if ($failedCount -gt 0) {
        $ValidationResults.OverallStatus = "FAILED"
    }
    elseif ($warningCount -gt 0) {
        $ValidationResults.OverallStatus = "WARNING"
    }
    else {
        $ValidationResults.OverallStatus = "PASSED"
    }
    
    switch ($OutputFormat) {
        "JSON" {
            $jsonPath = if ($OutputPath) { 
                Join-Path $OutputPath "cluster-health-$(Get-Date -Format 'yyyyMMdd-HHmmss').json" 
            } else { 
                "cluster-health-$(Get-Date -Format 'yyyyMMdd-HHmmss').json" 
            }
            $ValidationResults | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath
            Write-Line -Message "Report saved to: $jsonPath" -Level "INFO"
        }
        "HTML" {
            # Generate HTML report
            $htmlPath = if ($OutputPath) { 
                Join-Path $OutputPath "cluster-health-$(Get-Date -Format 'yyyyMMdd-HHmmss').html" 
            } else { 
                "cluster-health-$(Get-Date -Format 'yyyyMMdd-HHmmss').html" 
            }
            # Simplified HTML generation
            $html = "<html><head><title>Cluster Health Report</title></head><body>"
            $html += "<h1>Cluster Health Report: $ClusterName</h1>"
            $html += "<p>Generated: $($ValidationResults.Timestamp)</p>"
            $html += "<p>Overall Status: <strong>$($ValidationResults.OverallStatus)</strong></p>"
            $html += "<table border='1'><tr><th>Category</th><th>Check</th><th>Status</th><th>Message</th></tr>"
            foreach ($check in $ValidationResults.Checks) {
                $color = switch ($check.Status) { "PASSED" { "green" }; "FAILED" { "red" }; default { "orange" } }
                $html += "<tr><td>$($check.Category)</td><td>$($check.Check)</td><td style='color:$color'>$($check.Status)</td><td>$($check.Message)</td></tr>"
            }
            $html += "</table></body></html>"
            $html | Set-Content -Path $htmlPath
            Write-Line -Message "Report saved to: $htmlPath" -Level "INFO"
        }
    }
}

# Main execution
try {
    Write-Line -Message "Starting Cluster Health Validation" -Level "INFO"
    Write-Line -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Line -Message "========================================" -Level "INFO"
    
    # Run all validation checks
    $clusterOk = Test-ClusterService
    
    if ($clusterOk) {
        Test-ClusterNodes
        Test-StorageSpacesDirect
        Test-ClusterNetworks
        Test-ClusterQuorum
        Test-ArcConnection
    }
    
    # Export results
    Export-Results
    
    # Summary
    Write-Host ""
    Write-Line -Message "========================================" -Level "INFO"
    
    $passed = @($ValidationResults.Checks | Where-Object { $_.Status -eq "PASSED" }).Count
    $failed = @($ValidationResults.Checks | Where-Object { $_.Status -eq "FAILED" }).Count
    $warnings = @($ValidationResults.Checks | Where-Object { $_.Status -eq "WARNING" }).Count
    
    Write-Line -Message "Validation Complete" -Level "INFO"
    Write-Host "  Passed:   $passed" -ForegroundColor Green
    Write-Host "  Warnings: $warnings" -ForegroundColor Yellow
    Write-Host "  Failed:   $failed" -ForegroundColor Red
    
    if ($failed -gt 0) {
        Write-Line -Message "Overall Status: FAILED" -Level "ERROR"
        exit 1
    }
    elseif ($warnings -gt 0) {
        Write-Line -Message "Overall Status: WARNING" -Level "WARN"
        exit 0
    }
    else {
        Write-Line -Message "Overall Status: PASSED" -Level "SUCCESS"
        exit 0
    }
}
catch {
    Write-Line -Message "Validation failed: $_" -Level "ERROR"
    exit 1
}
