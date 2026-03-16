<#
.SYNOPSIS
    Configures storage for Azure Local cluster.

.DESCRIPTION
    This script configures Storage Spaces Direct including:
    - Storage pool creation and optimization
    - Virtual disk creation with tiering
    - Cluster Shared Volumes (CSV) creation
    - Storage QoS policies

.PARAMETER ClusterName
    The name of the Azure Local cluster.

.PARAMETER PoolName
    Name for the storage pool (default: S2D on <ClusterName>).

.PARAMETER VolumePrefix
    Prefix for volume names.

.PARAMETER VolumeCount
    Number of volumes to create.

.PARAMETER VolumeSizeGB
    Size of each volume in GB.

.PARAMETER ConfigFile
    Optional path to configuration file.

.EXAMPLE
    .\Set-StorageConfiguration.ps1 -ClusterName "AZL-CLUSTER01" -VolumeCount 4 -VolumeSizeGB 1024

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Requires: Storage Spaces Direct enabled, elevated privileges
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$PoolName,

    [Parameter(Mandatory = $false)]
    [string]$VolumePrefix = "Volume",

    [Parameter(Mandatory = $false)]
    [int]$VolumeCount = 1,

    [Parameter(Mandatory = $false)]
    [int]$VolumeSizeGB = 1024,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Mirror", "Parity", "MirrorAcceleratedParity")]
    [string]$ResiliencyType = "Mirror",

    [Parameter(Mandatory = $false)]
    [switch]$EnableDeduplication,

    [Parameter(Mandatory = $false)]
    [switch]$EnableCompression,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile
)

$ErrorActionPreference = "Stop"

# Import helper functions
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
} else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }
}

#region Storage Functions

function Get-StoragePoolInfo {
    param([string]$ClusterName)

    Write-Log -Message "Getting storage pool information..." -Level "INFO"

    $pool = Get-StoragePool -CimSession $ClusterName | 
        Where-Object { $_.FriendlyName -notlike "Primordial*" }

    if ($pool) {
        Write-Log -Message "Found storage pool: $($pool.FriendlyName)" -Level "INFO"
        Write-Log -Message "  Size: $([math]::Round($pool.Size / 1TB, 2)) TB" -Level "INFO"
        Write-Log -Message "  Allocated: $([math]::Round($pool.AllocatedSize / 1TB, 2)) TB" -Level "INFO"
        Write-Log -Message "  Health: $($pool.HealthStatus)" -Level "INFO"
    }

    return $pool
}

function New-ClusterVolume {
    param(
        [string]$ClusterName,
        [string]$VolumeName,
        [int64]$SizeBytes,
        [string]$ResiliencyType,
        [string]$FileSystem = "CSVFS_ReFS"
    )

    Write-Log -Message "Creating volume: $VolumeName ($([math]::Round($SizeBytes / 1GB, 0)) GB)" -Level "INFO"

    # Check if volume exists
    $existingVolume = Get-VirtualDisk -CimSession $ClusterName -FriendlyName $VolumeName -ErrorAction SilentlyContinue
    if ($existingVolume) {
        Write-Log -Message "Volume $VolumeName already exists" -Level "INFO"
        return $existingVolume
    }

    # Create the volume
    $params = @{
        CimSession = $ClusterName
        FriendlyName = $VolumeName
        Size = $SizeBytes
        FileSystem = $FileSystem
    }

    switch ($ResiliencyType) {
        "Mirror" {
            $params.Add("ResiliencySettingName", "Mirror")
        }
        "Parity" {
            $params.Add("ResiliencySettingName", "Parity")
        }
        "MirrorAcceleratedParity" {
            # MAP requires specific configuration
            $params.Add("StorageTierFriendlyNames", @("MirrorOnSSD", "ParityOnHDD"))
            $params.Add("StorageTierSizes", @([int64]($SizeBytes * 0.2), [int64]($SizeBytes * 0.8)))
        }
    }

    try {
        $volume = New-Volume @params
        Write-Log -Message "Volume created successfully: $VolumeName" -Level "SUCCESS"
        return $volume
    } catch {
        Write-Log -Message "Failed to create volume: $_" -Level "ERROR"
        throw
    }
}

function Set-VolumeDeduplication {
    param(
        [string]$ClusterName,
        [string]$VolumeName
    )

    Write-Log -Message "Enabling deduplication on: $VolumeName" -Level "INFO"

    try {
        # Get the CSV path
        $csv = Get-ClusterSharedVolume -Cluster $ClusterName | 
            Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -like "*$VolumeName*" }

        if ($csv) {
            $path = $csv.SharedVolumeInfo.FriendlyVolumeName
            
            # Enable deduplication
            Enable-DedupVolume -Volume $path -UsageType HyperV -CimSession $ClusterName

            Write-Log -Message "Deduplication enabled on: $path" -Level "SUCCESS"
        }
    } catch {
        Write-Log -Message "Failed to enable deduplication: $_" -Level "WARN"
    }
}

function Set-StorageQoSPolicy {
    param(
        [string]$ClusterName,
        [string]$PolicyName,
        [int64]$MinimumIOPS = 0,
        [int64]$MaximumIOPS = 0,
        [int64]$MinimumBandwidthMBps = 0,
        [int64]$MaximumBandwidthMBps = 0
    )

    Write-Log -Message "Creating Storage QoS policy: $PolicyName" -Level "INFO"

    # Check if policy exists
    $existingPolicy = Get-StorageQosPolicy -CimSession $ClusterName -Name $PolicyName -ErrorAction SilentlyContinue
    if ($existingPolicy) {
        Write-Log -Message "QoS policy already exists: $PolicyName" -Level "INFO"
        return $existingPolicy
    }

    $params = @{
        CimSession = $ClusterName
        Name = $PolicyName
        PolicyType = "Aggregated"
    }

    if ($MinimumIOPS -gt 0) { $params.Add("MinimumIops", $MinimumIOPS) }
    if ($MaximumIOPS -gt 0) { $params.Add("MaximumIops", $MaximumIOPS) }
    if ($MinimumBandwidthMBps -gt 0) { $params.Add("MinimumBandwidth", $MinimumBandwidthMBps * 1MB) }
    if ($MaximumBandwidthMBps -gt 0) { $params.Add("MaximumBandwidth", $MaximumBandwidthMBps * 1MB) }

    try {
        $policy = New-StorageQosPolicy @params
        Write-Log -Message "QoS policy created: $PolicyName" -Level "SUCCESS"
        return $policy
    } catch {
        Write-Log -Message "Failed to create QoS policy: $_" -Level "WARN"
    }
}

function Get-StorageSummary {
    param([string]$ClusterName)

    Write-Log -Message "Storage Configuration Summary" -Level "INFO"
    Write-Log -Message "=============================" -Level "INFO"

    # Pool info
    $pool = Get-StoragePool -CimSession $ClusterName | 
        Where-Object { $_.FriendlyName -notlike "Primordial*" }

    if ($pool) {
        $totalSize = [math]::Round($pool.Size / 1TB, 2)
        $allocatedSize = [math]::Round($pool.AllocatedSize / 1TB, 2)
        $freeSize = [math]::Round(($pool.Size - $pool.AllocatedSize) / 1TB, 2)

        Write-Log -Message "Storage Pool: $($pool.FriendlyName)" -Level "INFO"
        Write-Log -Message "  Total: $totalSize TB" -Level "INFO"
        Write-Log -Message "  Allocated: $allocatedSize TB" -Level "INFO"
        Write-Log -Message "  Free: $freeSize TB" -Level "INFO"
    }

    # Volume info
    $volumes = Get-VirtualDisk -CimSession $ClusterName | 
        Where-Object { $_.FriendlyName -notlike "ClusterPerformanceHistory*" }

    Write-Log -Message "Volumes:" -Level "INFO"
    foreach ($vol in $volumes) {
        $sizeGB = [math]::Round($vol.Size / 1GB, 0)
        Write-Log -Message "  $($vol.FriendlyName): $sizeGB GB - $($vol.HealthStatus)" -Level "INFO"
    }

    # CSV info
    $csvs = Get-ClusterSharedVolume -Cluster $ClusterName
    Write-Log -Message "Cluster Shared Volumes: $($csvs.Count)" -Level "INFO"
}

#endregion

#region Main Execution

try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Azure Local Storage Configuration" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"

    # Load configuration if provided
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        $config = Get-Content $ConfigFile | ConvertFrom-Yaml
        Write-Log -Message "Configuration loaded from: $ConfigFile" -Level "INFO"
    }

    # Step 1: Verify S2D is enabled
    Write-Log -Message "Step 1: Verify Storage Spaces Direct" -Level "INFO"
    $s2d = Get-ClusterStorageSpacesDirect -CimSession $ClusterName -ErrorAction SilentlyContinue
    if (-not $s2d) {
        throw "Storage Spaces Direct is not enabled on this cluster"
    }
    Write-Log -Message "Storage Spaces Direct is enabled" -Level "SUCCESS"

    # Step 2: Get storage pool info
    Write-Log -Message "Step 2: Storage Pool Information" -Level "INFO"
    $pool = Get-StoragePoolInfo -ClusterName $ClusterName

    if (-not $pool) {
        throw "No storage pool found. Ensure S2D is properly configured."
    }

    # Step 3: Create volumes
    Write-Log -Message "Step 3: Create Volumes" -Level "INFO"
    $sizeBytes = [int64]$VolumeSizeGB * 1GB

    for ($i = 1; $i -le $VolumeCount; $i++) {
        $volumeName = "$VolumePrefix$i"
        New-ClusterVolume -ClusterName $ClusterName -VolumeName $volumeName `
            -SizeBytes $sizeBytes -ResiliencyType $ResiliencyType
    }

    # Step 4: Enable deduplication if requested
    if ($EnableDeduplication) {
        Write-Log -Message "Step 4: Enable Deduplication" -Level "INFO"
        for ($i = 1; $i -le $VolumeCount; $i++) {
            $volumeName = "$VolumePrefix$i"
            Set-VolumeDeduplication -ClusterName $ClusterName -VolumeName $volumeName
        }
    } else {
        Write-Log -Message "Step 4: Deduplication (SKIPPED)" -Level "INFO"
    }

    # Step 5: Create default QoS policies
    Write-Log -Message "Step 5: Storage QoS Policies" -Level "INFO"
    Set-StorageQoSPolicy -ClusterName $ClusterName -PolicyName "HighPerformance" -MinimumIOPS 10000
    Set-StorageQoSPolicy -ClusterName $ClusterName -PolicyName "Standard" -MinimumIOPS 1000 -MaximumIOPS 50000
    Set-StorageQoSPolicy -ClusterName $ClusterName -PolicyName "LowPriority" -MaximumIOPS 5000

    # Step 6: Summary
    Write-Log -Message "Step 6: Configuration Summary" -Level "INFO"
    Get-StorageSummary -ClusterName $ClusterName

    Write-Log -Message "========================================" -Level "SUCCESS"
    Write-Log -Message "Storage configuration complete!" -Level "SUCCESS"
    Write-Log -Message "Volumes created: $VolumeCount" -Level "INFO"
    Write-Log -Message "Resiliency: $ResiliencyType" -Level "INFO"
    Write-Log -Message "========================================" -Level "SUCCESS"

} catch {
    Write-Log -Message "Storage configuration failed: $_" -Level "ERROR"
    Write-Log -Message $_.ScriptStackTrace -Level "ERROR"
    exit 1
}

#endregion
