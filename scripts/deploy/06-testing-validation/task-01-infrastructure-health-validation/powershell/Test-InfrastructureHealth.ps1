<#
.SYNOPSIS
    Validates Azure Local cluster infrastructure health.

.DESCRIPTION
    Comprehensive infrastructure health validation including:
    - Test-Cluster validation suite
    - Health Service status and faults
    - Arc connectivity verification
    - Storage Spaces Direct health
    - Network connectivity checks
    - Generates validation report for customer handover

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.EXAMPLE
    .\Test-InfrastructureHealth.ps1 -ClusterName "azl-cluster-01"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-01-infrastructure-health-validation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports"
)

#Requires -Version 7.0
#Requires -Modules FailoverClusters

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml
    return Get-Content -Path $Path -Raw | ConvertFrom-Yaml
}

#region Validation Functions

function Test-ClusterValidation {
    Write-Log "Running Test-Cluster validation suite..." -Level "HEADER"

    $results = @{ Passed = 0; Failed = 0; Warnings = 0; Details = @() }
    try {
        $testResult = Test-Cluster -Cluster $ClusterName -Include "System Configuration", "Inventory", "Network", "Storage" -ErrorAction Stop

        foreach ($item in $testResult) {
            $status = switch ($item.Status) {
                0 { "PASS" }
                1 { "WARN" }
                2 { "FAIL" }
                default { "UNKNOWN" }
            }

            $results.Details += [PSCustomObject]@{
                Test   = $item.Name
                Status = $status
                Detail = $item.Description
            }

            switch ($status) {
                "PASS" { $results.Passed++; Write-Log "  PASS: $($item.Name)" -Level "SUCCESS" }
                "WARN" { $results.Warnings++; Write-Log "  WARN: $($item.Name)" -Level "WARN" }
                "FAIL" { $results.Failed++; Write-Log "  FAIL: $($item.Name)" -Level "ERROR" }
            }
        }
    }
    catch {
        Write-Log "  Test-Cluster failed: $_" -Level "ERROR"
        $results.Failed++
    }
    return $results
}

function Test-HealthServiceStatus {
    Write-Log "Checking Health Service status..." -Level "HEADER"

    $results = @{ Healthy = $true; Faults = @() }
    try {
        $healthService = Get-HealthFault -CimSession $ClusterName -ErrorAction Stop

        if ($healthService.Count -eq 0) {
            Write-Log "  No health faults detected" -Level "SUCCESS"
        }
        else {
            $results.Healthy = $false
            foreach ($fault in $healthService) {
                $results.Faults += [PSCustomObject]@{
                    FaultType   = $fault.FaultType
                    Description = $fault.Description
                    Severity    = $fault.Severity
                }
                Write-Log "  FAULT: $($fault.FaultType) — $($fault.Description)" -Level "WARN"
            }
        }
    }
    catch {
        Write-Log "  Health Service check failed: $_" -Level "ERROR"
        $results.Healthy = $false
    }
    return $results
}

function Test-StorageHealth {
    Write-Log "Checking Storage Spaces Direct health..." -Level "HEADER"

    $results = @{ Healthy = $true; Details = @() }
    try {
        # Check storage pool
        $pool = Get-StoragePool -CimSession $ClusterName -IsPrimordial $false -ErrorAction Stop
        foreach ($p in $pool) {
            $healthy = $p.HealthStatus -eq 'Healthy'
            if (-not $healthy) { $results.Healthy = $false }
            Write-Log "  Pool '$($p.FriendlyName)': $($p.HealthStatus) (Operational: $($p.OperationalStatus))" -Level $(if ($healthy) { "SUCCESS" } else { "ERROR" })
        }

        # Check virtual disks
        $vDisks = Get-VirtualDisk -CimSession $ClusterName -ErrorAction Stop
        foreach ($vd in $vDisks) {
            $healthy = $vd.HealthStatus -eq 'Healthy'
            if (-not $healthy) { $results.Healthy = $false }
            Write-Log "  VDisk '$($vd.FriendlyName)': $($vd.HealthStatus) ($($vd.ResiliencySettingName))" -Level $(if ($healthy) { "SUCCESS" } else { "WARN" })
        }

        # Check physical disks
        $pDisks = Get-PhysicalDisk -CimSession $ClusterName -ErrorAction Stop
        $unhealthy = $pDisks | Where-Object { $_.HealthStatus -ne 'Healthy' }
        Write-Log "  Physical disks: $($pDisks.Count) total, $($unhealthy.Count) unhealthy" -Level $(if ($unhealthy.Count -eq 0) { "SUCCESS" } else { "ERROR" })
    }
    catch {
        Write-Log "  Storage health check failed: $_" -Level "ERROR"
        $results.Healthy = $false
    }
    return $results
}

function Test-NodeConnectivity {
    Write-Log "Checking node connectivity..." -Level "HEADER"

    $nodes = Get-ClusterNode -Cluster $ClusterName
    $allUp = $true

    foreach ($node in $nodes) {
        $status = $node.State
        if ($status -eq 'Up') {
            Write-Log "  $($node.Name): UP" -Level "SUCCESS"
        }
        else {
            Write-Log "  $($node.Name): $status" -Level "ERROR"
            $allUp = $false
        }
    }
    return $allUp
}

function Test-ArcConnectivity {
    Write-Log "Checking Azure Arc connectivity..." -Level "HEADER"

    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName
        foreach ($node in $nodes) {
            $arcAgent = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                & "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe" show 2>&1
            } -ErrorAction Stop

            $status = ($arcAgent | Select-String "Agent Status").ToString() -replace '.*:\s*', ''
            $connected = $status -eq 'Connected'
            Write-Log "  $($node.Name): Arc Agent $status" -Level $(if ($connected) { "SUCCESS" } else { "ERROR" })
        }
    }
    catch {
        Write-Log "  Arc connectivity check failed: $_" -Level "ERROR"
    }
}

#endregion Validation Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "Infrastructure Health Validation" -Level "HEADER"
Write-Log "========================================" -Level "HEADER"

# Load config
if ($ConfigPath) {
    $config = Import-InfrastructureConfig -Path $ConfigPath
    if (-not $ClusterName -and $config) {
        $ClusterName = $config.platform.cluster_name
    }
}
if (-not $ClusterName) {
    Write-Log "ClusterName is required." -Level "ERROR"
    exit 1
}

Write-Log "Cluster: $ClusterName" -Level "INFO"
Write-Host ""

$report = @{
    Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ClusterName     = $ClusterName
    Sections        = @{}
}

# 1. Node connectivity
$nodesUp = Test-NodeConnectivity
$report.Sections["NodeConnectivity"] = @{ AllUp = $nodesUp }
Write-Host ""

# 2. Test-Cluster suite
$clusterResults = Test-ClusterValidation
$report.Sections["TestCluster"] = $clusterResults
Write-Host ""

# 3. Health Service
$healthResults = Test-HealthServiceStatus
$report.Sections["HealthService"] = $healthResults
Write-Host ""

# 4. Storage health
$storageResults = Test-StorageHealth
$report.Sections["Storage"] = $storageResults
Write-Host ""

# 5. Arc connectivity
Test-ArcConnectivity
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "01-infrastructure-health-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "Infrastructure Health Summary" -Level "SUCCESS"
Write-Log "  All nodes up: $nodesUp" -Level "INFO"
Write-Log "  Test-Cluster: $($clusterResults.Passed) pass / $($clusterResults.Failed) fail / $($clusterResults.Warnings) warn" -Level "INFO"
Write-Log "  Health Service: $(if ($healthResults.Healthy) { 'No faults' } else { "$($healthResults.Faults.Count) faults" })" -Level "INFO"
Write-Log "  Storage: $(if ($storageResults.Healthy) { 'Healthy' } else { 'Issues detected' })" -Level "INFO"

#endregion Main
