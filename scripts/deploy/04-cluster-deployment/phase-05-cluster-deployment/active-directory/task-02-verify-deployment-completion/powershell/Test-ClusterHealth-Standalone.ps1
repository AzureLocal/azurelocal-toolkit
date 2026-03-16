<#
.SYNOPSIS
    Test-ClusterHealth-Standalone.ps1
    Verifies Azure Local cluster health via PSRemoting from any machine.

.DESCRIPTION
    Self-contained script. Run from any machine (workstation, jump box, etc.)
    with network access to the cluster nodes. No infrastructure.yml or toolkit
    dependencies required. Define all variables in #region CONFIGURATION.

    Connects to a cluster node via PSRemoting and checks cluster state,
    node state, and storage pool health.

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-03-verify-deployment-completion
    Execution:    Run from any machine with network access to the cluster nodes
    Run after:    Portal deployment completes

.EXAMPLE
    .\Test-ClusterHealth-Standalone.ps1
#>

#region CONFIGURATION
$NodeIP = "REPLACE_NODE_01_IP"   # compute.cluster_nodes[*].management_ip — IP of any cluster node
#endregion CONFIGURATION

if ($NodeIP -match '^REPLACE_') {
    throw "Edit the REPLACE_ variables in #region CONFIGURATION before running."
}

$cred = Get-Credential -Message "Enter local admin credentials for $NodeIP"

Write-Host "`n=== Cluster Health Verification — $NodeIP ===" -ForegroundColor Cyan

Invoke-Command -ComputerName $NodeIP -Credential $cred -ScriptBlock {
    Write-Host "`n--- Cluster Status ---" -ForegroundColor Cyan
    Get-Cluster | Format-List Name, SharedVolumesRoot

    Write-Host "`n--- Node Status ---" -ForegroundColor Cyan
    Get-ClusterNode | Format-Table Name, State -AutoSize

    $downNodes = @(Get-ClusterNode | Where-Object { $_.State -ne 'Up' })
    if ($downNodes.Count -gt 0) {
        Write-Host "[WARN] $($downNodes.Count) node(s) not in 'Up' state:" -ForegroundColor Yellow
        $downNodes | ForEach-Object { Write-Host "  - $($_.Name): $($_.State)" -ForegroundColor Yellow }
    } else {
        Write-Host "[PASS] All nodes are Up" -ForegroundColor Green
    }

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

    Write-Host "`n--- Cluster Shared Volumes ---" -ForegroundColor Cyan
    $csvs = @(Get-ClusterSharedVolume -ErrorAction SilentlyContinue)
    if ($csvs.Count -eq 0) {
        Write-Host "[INFO] No Cluster Shared Volumes found" -ForegroundColor Yellow
    } else {
        $csvs | Format-Table Name, State -AutoSize
    }
}

Write-Host "`n[DONE] Cluster health check complete" -ForegroundColor Cyan
