#Requires -Version 5.1
<#
.SYNOPSIS
    Standalone: creates S2D CSV volumes on the local cluster node.

.DESCRIPTION
    Phase 06 — Post-Deployment | Task 05 — Storage Configuration (Section 2)

    Run this script directly ON a cluster node (console, RDP, or Arc SSH).
    Fill in the #region CONFIGURATION block with your environment values.
    No infrastructure.yml dependency.

.NOTES
    Must be run on (or remoted into) a cluster node with FailoverClusters
    and Storage modules available.
    Run as a domain or local administrator.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION -----------------------------------------------------------
# Replace all values below with your environment. Do not use real internal names
# in examples — see IIC / IMPROBABLE below for the naming convention.

$ClusterName = "iic-clus01"                 # Cluster name (pool = "S2D on $ClusterName")

$Volumes = @(
    [PSCustomObject]@{
        VolumeName  = "csv-iic01-clus01-m2-vmstore-prd-01"
        SizeGB      = 2000
        Filesystem  = "ReFS"
        Resiliency  = "Mirror"               # Mirror | Parity | MirrorAcceleratedParity
        Purpose     = "VM storage"
    }
    [PSCustomObject]@{
        VolumeName  = "csv-iic01-clus01-m2-vmstore-prd-02"
        SizeGB      = 2000
        Filesystem  = "ReFS"
        Resiliency  = "Mirror"
        Purpose     = "VM storage"
    }
)
#endregion ----------------------------------------------------------------------

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) { "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; default { "Cyan" } }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

Write-Status "CSV Volume Creation — $ClusterName"
Write-Status "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verify required modules
foreach ($mod in @("FailoverClusters", "Storage")) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        Write-Status "Required module missing: $mod" -Level "ERROR"
        throw "Install-WindowsFeature RSAT-Clustering-PowerShell, RSAT-Hyper-V-Tools"
    }
}

# Resolve storage pool name
$poolName = "S2D on $ClusterName"
$pool = Get-StoragePool -FriendlyName $poolName -ErrorAction SilentlyContinue
if (-not $pool) {
    Write-Status "Storage pool '$poolName' not found. Ensure S2D is enabled and the cluster name is correct." -Level "ERROR"
    throw "Storage pool not found: $poolName"
}

Write-Status ("Pool : {0}  Health: {1}  Available: {2} GB" -f $pool.FriendlyName, $pool.HealthStatus, [math]::Round(($pool.Size - $pool.AllocatedSize)/1GB, 0))

foreach ($vol in $Volumes) {
    Write-Status "Processing volume: $($vol.VolumeName)"

    $existing = Get-VirtualDisk -FriendlyName $vol.VolumeName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Status "  Already exists (State: $($existing.OperationalStatus)) — skipping" -Level "WARN"
        continue
    }

    try {
        $fsParam = if ($vol.Filesystem -eq "ReFS") { "CSVFS_ReFS" } else { "CSVFS_NTFS" }

        New-Volume `
            -FriendlyName            $vol.VolumeName `
            -StoragePoolFriendlyName $poolName `
            -Size                    ($vol.SizeGB * 1GB) `
            -ProvisioningType        Thin `
            -ResiliencySettingName   $vol.Resiliency `
            -FileSystem              $fsParam `
            -ErrorAction             Stop | Out-Null

        Write-Status "  Created: $($vol.SizeGB) GB  $($vol.Resiliency)  $($vol.Filesystem)" -Level "OK"
    }
    catch {
        Write-Status "  Failed: $_" -Level "ERROR"
    }
}

Write-Status "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Status "Current CSV state:"
Get-ClusterSharedVolume | ForEach-Object {
    $state = ($_ | Get-ClusterSharedVolumeState).StateInfo
    Write-Status "  $($_.Name)  →  $state" -Level "OK"
}
