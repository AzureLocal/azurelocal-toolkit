#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone: verifies all Phase 06 post-deployment tasks. No external dependencies.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 08 — Post-Deployment Verification

    Self-contained verification script. All configuration values are defined in the
    #region CONFIGURATION block. No infrastructure.yml, config-loader, or toolkit
    helpers required. Copy, edit the CONFIGURATION block, and run from any workstation
    with PSRemoting access to cluster nodes.

    Checks: WAC port (01), cluster quorum (02), security groups (03), SSH (04),
    storage pool and CSVs (05). Azure-side items (06, 07) are flagged for portal review.

.NOTES
    Run from any workstation with PSRemoting access to cluster nodes.
    Requires: FailoverClusters module (available on cluster nodes or installable on mgmt server)
#>

#region CONFIGURATION -----------------------------------------------------------

# ─── Cluster ────────────────────────────────────────────────────────────────────
$cluster_name = "iic-clus01"                     # Azure Local cluster name

# ─── Nodes ──────────────────────────────────────────────────────────────────────
# List every node hostname for per-node checks (security groups, SSH)
$node_names   = @(
    "iic-01-n01",
    "iic-01-n02"
)

# ─── Windows Admin Center ───────────────────────────────────────────────────────
# Leave empty "" to skip WAC checks
$wac_server   = "iic-wac01.improbability.cloud"  # FQDN or IP of WAC server (or "" to skip)

#endregion CONFIGURATION --------------------------------------------------------

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host " Task 08 — Post-Deployment Verification (Standalone)"   -ForegroundColor Cyan
Write-Host " Cluster: $cluster_name"                                 -ForegroundColor Cyan
Write-Host " Nodes:   $($node_names -join ', ')"                     -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

$passCount = 0
$failCount = 0
$skipCount = 0

function Write-Check {
    param([bool]$Pass, [string]$Message, [string]$Detail = "")
    $ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $level  = if ($Pass) { "PASS" } else { "FAIL" }
    $color  = if ($Pass) { "Green" } else { "Red" }
    $detStr = if ($Detail) { " — $Detail" } else { "" }
    Write-Host "  [$ts] [$level] $Message$detStr" -ForegroundColor $color
    if ($Pass) { $script:passCount++ } else { $script:failCount++ }
}

function Write-Skip {
    param([string]$Message, [string]$Reason = "")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "  [$ts] [SKIP] $Message$(if ($Reason) { " — $Reason" })" -ForegroundColor Yellow
    $script:skipCount++
}

# ── Task 01: Windows Admin Center ───────────────────────────────────────────
Write-Host "Task 01 — Windows Admin Center" -ForegroundColor Yellow
if ([string]::IsNullOrEmpty($wac_server)) {
    Write-Skip "WAC checks" "wac_server not configured"
} else {
    $wacPort = Test-NetConnection -ComputerName $wac_server -Port 443 -WarningAction SilentlyContinue
    Write-Check -Pass $wacPort.TcpTestSucceeded -Message "WAC port 443 reachable" -Detail $wac_server
}

# ── Task 02: Cluster Quorum ──────────────────────────────────────────────────
Write-Host ""
Write-Host "Task 02 — Cluster Quorum" -ForegroundColor Yellow
try {
    $quorum      = Get-ClusterQuorum -Cluster $cluster_name -ErrorAction Stop
    $quorumState = (Get-Cluster -Name $cluster_name).QuorumState
    Write-Check -Pass ($null -ne $quorum.QuorumType) -Message "Quorum type configured"  -Detail $quorum.QuorumType
    Write-Check -Pass ($quorumState -eq "Normal")    -Message "Quorum state Normal"     -Detail $quorumState
} catch {
    Write-Check -Pass $false -Message "Cluster quorum query failed" -Detail $_
}

# ── Task 03: Security Groups ─────────────────────────────────────────────────
Write-Host ""
Write-Host "Task 03 — Security Groups" -ForegroundColor Yellow
foreach ($node in $node_names) {
    try {
        $groups = Invoke-Command -ComputerName $node -ErrorAction Stop -ScriptBlock {
            @{
                AdminGroups = (Get-LocalGroupMember -Group "Administrators"          | Where-Object ObjectClass -eq "Group").Count
                RmGroups    = (Get-LocalGroupMember -Group "Remote Management Users" | Where-Object ObjectClass -eq "Group").Count
            }
        }
        Write-Check -Pass ($groups.AdminGroups -gt 0) -Message "$node — Administrators AD groups"          -Detail "$($groups.AdminGroups) group(s)"
        Write-Check -Pass ($groups.RmGroups    -gt 0) -Message "$node — Remote Management Users AD groups" -Detail "$($groups.RmGroups) group(s)"
    } catch {
        Write-Check -Pass $false -Message "$node — security group check failed" -Detail $_
    }
}

# ── Task 04: SSH Connectivity ────────────────────────────────────────────────
Write-Host ""
Write-Host "Task 04 — SSH Connectivity" -ForegroundColor Yellow
foreach ($node in $node_names) {
    try {
        $sshSvc = Invoke-Command -ComputerName $node -ErrorAction Stop -ScriptBlock {
            Get-Service sshd -ErrorAction SilentlyContinue
        }
        Write-Check -Pass ($sshSvc.Status -eq "Running") -Message "$node — sshd service" -Detail $sshSvc.Status
    } catch {
        Write-Check -Pass $false -Message "$node — sshd service check failed" -Detail $_
    }
    $sshPort = Test-NetConnection -ComputerName $node -Port 22 -WarningAction SilentlyContinue
    Write-Check -Pass $sshPort.TcpTestSucceeded -Message "$node — port 22 reachable"
}

# ── Task 05: Storage ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Task 05 — Storage" -ForegroundColor Yellow
try {
    $pool = Get-StoragePool -CimSession $cluster_name | Where-Object IsPrimordial -eq $false
    if ($pool) {
        Write-Check -Pass ($pool.HealthStatus -eq "Healthy") -Message "Storage pool health" -Detail $pool.HealthStatus
    } else {
        Write-Check -Pass $false -Message "Storage pool" -Detail "Not found"
    }
    $csvVolumes = Get-ClusterSharedVolume -Cluster $cluster_name
    Write-Check -Pass ($csvVolumes.Count -gt 0) -Message "CSV volumes mounted" -Detail "$($csvVolumes.Count) volume(s)"
    foreach ($csv in $csvVolumes) {
        Write-Check -Pass ($csv.State -eq "Online") -Message "  $($csv.Name)" -Detail $csv.State
    }
} catch {
    Write-Check -Pass $false -Message "Storage check failed" -Detail $_
}

# ── Tasks 06-07: Azure Portal ────────────────────────────────────────────────
Write-Host ""
Write-Host "Tasks 06-07 — Azure Portal (manual)" -ForegroundColor Yellow
Write-Skip "Task 06 — VM images"        "Verify in Azure Portal: Azure Local → iic-clus01 → VM images (Succeeded expected)"
Write-Skip "Task 07 — Logical networks" "Verify in Azure Portal: Azure Local → iic-clus01 → Logical networks (Succeeded expected)"

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host " Summary"                                                 -ForegroundColor Cyan
Write-Host "   Passed  : $passCount"                                  -ForegroundColor Green
Write-Host "   Failed  : $failCount"                                  -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host "   Skipped : $skipCount"                                  -ForegroundColor Yellow
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "[FAIL] $failCount check(s) failed. Resolve issues before proceeding to Phase 17." -ForegroundColor Red
} else {
    Write-Host "[PASS] All automated checks passed. Review skipped items in Azure Portal." -ForegroundColor Green
}
Write-Host ""
