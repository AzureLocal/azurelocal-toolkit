<#
.SYNOPSIS
    Test-ClusterHealth.ps1
    Verifies Azure Local cluster health directly on this node.

.DESCRIPTION
    Run this script directly ON a cluster node (via RDP or console session).
    Checks cluster state, node state, and storage pool health. No PSRemoting
    or infrastructure.yml required — runs in local context.

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-03-verify-deployment-completion
    Execution:    Run directly ON a cluster node (console/RDP)
    Run after:    Portal deployment completes

.EXAMPLE
    .\Test-ClusterHealth.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "`n=== Cluster Health Verification — $env:COMPUTERNAME ===" -ForegroundColor Cyan

# ── Cluster status ────────────────────────────────────────────────────────────
Write-Host "`n--- Cluster Status ---" -ForegroundColor Cyan
$cluster = Get-Cluster -ErrorAction Stop
$cluster | Format-List Name, SharedVolumesRoot

# ── Node status ───────────────────────────────────────────────────────────────
Write-Host "`n--- Node Status ---" -ForegroundColor Cyan
Get-ClusterNode | Format-Table Name, State -AutoSize

$downNodes = @(Get-ClusterNode | Where-Object { $_.State -ne 'Up' })
if ($downNodes.Count -gt 0) {
    Write-Host "[WARN] $($downNodes.Count) node(s) not in 'Up' state:" -ForegroundColor Yellow
    $downNodes | ForEach-Object { Write-Host "  - $($_.Name): $($_.State)" -ForegroundColor Yellow }
} else {
    Write-Host "[PASS] All nodes are Up" -ForegroundColor Green
}

# ── Storage pool ──────────────────────────────────────────────────────────────
Write-Host "`n--- Storage Pool ---" -ForegroundColor Cyan
$pools = @(Get-StoragePool | Where-Object { -not $_.IsPrimordial })
if ($pools.Count -eq 0) {
    Write-Host "[WARN] No S2D storage pool found" -ForegroundColor Yellow
} else {
    $pools | Format-Table FriendlyName, HealthStatus, OperationalStatus, Size -AutoSize
    $unhealthy = @($pools | Where-Object { $_.HealthStatus -ne 'Healthy' })
    if ($unhealthy.Count -gt 0) {
        Write-Host "[WARN] $($unhealthy.Count) pool(s) not Healthy" -ForegroundColor Yellow
    } else {
        Write-Host "[PASS] Storage pool healthy" -ForegroundColor Green
    }
}

# ── Cluster shared volumes ─────────────────────────────────────────────────────
Write-Host "`n--- Cluster Shared Volumes ---" -ForegroundColor Cyan
$csvs = @(Get-ClusterSharedVolume -ErrorAction SilentlyContinue)
if ($csvs.Count -eq 0) {
    Write-Host "[INFO] No Cluster Shared Volumes found" -ForegroundColor Yellow
} else {
    $csvs | Format-Table Name, State -AutoSize
}

Write-Host "`n[DONE] Cluster health check complete on $env:COMPUTERNAME" -ForegroundColor Cyan
