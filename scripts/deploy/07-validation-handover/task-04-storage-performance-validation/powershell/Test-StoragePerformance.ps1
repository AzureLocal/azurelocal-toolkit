#Requires -Version 7.0
<#
.SYNOPSIS
    Tests Azure Local storage performance and configuration.

.DESCRIPTION
    This script performs storage validation including:
    - Storage pool health and capacity
    - Virtual disk health and resiliency
    - Physical disk health
    - CSV ownership, state and usage
    - Disk I/O latency measurements (only with -RunPerformanceTest)

    Run it from a machine that can reach the cluster with PowerShell remoting. It asks for nothing: the cluster name is a
    parameter, and every limit it applies is a parameter too.

    Exit codes: 0 when no check logged an error, 1 when a check or the run failed.

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER VolumeNames
    Optional. Specific CSV volume names to test. If not specified, tests all CSVs.

.PARAMETER RunPerformanceTest
    Switch to run disk performance tests (I/O benchmark).

.PARAMETER DurationSeconds
    Duration of performance test in seconds, split evenly between the write test and the read test. At least 2. Default: 60

.PARAMETER CsvUsageWarningPercent
    A CSV that is fuller than this share, in percent, is reported as a warning. Default: 85

.PARAMETER MaxAvgWriteLatencyMs
    Average write latency, in milliseconds, above which the performance test reports a warning. Default: 10

.PARAMETER MaxAvgReadLatencyMs
    Average read latency, in milliseconds, above which the performance test reports a warning. Default: 5

.PARAMETER OutputPath
    Folder to save the test results (a JSON file) in. Created when it does not exist. Nothing is saved when it is not given.

.EXAMPLE
    .\Test-StoragePerformance.ps1 -ClusterName "iic-azl-01"

.EXAMPLE
    .\Test-StoragePerformance.ps1 -ClusterName "iic-azl-01" -RunPerformanceTest -DurationSeconds 120

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.1.0
    Created: 2026-02-01

    Running performance tests will generate I/O on the cluster.
    Consider running during maintenance windows for production clusters.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string[]]$VolumeNames,

    [Parameter(Mandatory = $false)]
    [switch]$RunPerformanceTest,

    [Parameter(Mandatory = $false)]
    [ValidateRange(2, [int]::MaxValue)]
    [int]$DurationSeconds = 60,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$CsvUsageWarningPercent = 85,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxAvgWriteLatencyMs = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxAvgReadLatencyMs = 5,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# These define the benchmark itself, not a deployment: the size of one I/O, the share of latencies the 99th percentile
# is read at, and the scratch folder and file the benchmark creates on the volume and removes again.
$IoSizeBytes = 4KB
$PercentileFraction = 0.99
$ScratchFolderName = 'StorageTest'
$ScratchFileName = 'iobench.dat'

$script:ErrorCount = 0

function Write-StorageLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
    $color = switch ($Level) {
        'INFO' { 'White' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'SUCCESS' { 'Green' }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

# Initialize results
$TestResults = @{
    Timestamp          = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
    ClusterName        = $ClusterName
    StorageHealth      = @{}
    VolumeTests        = @()
    PerformanceResults = @()
}

function Test-StoragePoolHealth {
    Write-StorageLog -Message 'Checking storage pool health...' -Level 'INFO'

    try {
        # Get all non-primordial storage pools
        $pools = @(Get-StoragePool -CimSession $ClusterName | Where-Object { $_.IsPrimordial -eq $false })

        $poolResults = @()
        foreach ($pool in $pools) {
            $healthStatus = $pool.HealthStatus.ToString()
            $operationalStatus = $pool.OperationalStatus.ToString()

            $result = @{
                Name              = $pool.FriendlyName
                HealthStatus      = $healthStatus
                OperationalStatus = $operationalStatus
                Size              = [math]::Round($pool.Size / 1TB, 2)
                AllocatedSize     = [math]::Round($pool.AllocatedSize / 1TB, 2)
                FreeSpaceGB       = [math]::Round(($pool.Size - $pool.AllocatedSize) / 1GB, 2)
                UsagePercent      = [math]::Round(($pool.AllocatedSize / $pool.Size) * 100, 1)
            }

            $poolResults += $result

            if ($healthStatus -eq 'Healthy') {
                Write-StorageLog -Message "  Pool: $($pool.FriendlyName) - Healthy ($($result.UsagePercent)% used)" -Level 'SUCCESS'
            }
            elseif ($healthStatus -eq 'Warning') {
                Write-StorageLog -Message "  Pool: $($pool.FriendlyName) - Warning: $operationalStatus" -Level 'WARN'
            }
            else {
                Write-StorageLog -Message "  Pool: $($pool.FriendlyName) - ${healthStatus}: $operationalStatus" -Level 'ERROR'
            }
        }

        $TestResults.StorageHealth.Pools = $poolResults
    }
    catch {
        Write-StorageLog -Message "Failed to check storage pools: $_" -Level 'ERROR'
    }
}

function Test-VirtualDiskHealth {
    Write-StorageLog -Message 'Checking virtual disk health...' -Level 'INFO'

    try {
        $vDisks = @(Get-VirtualDisk -CimSession $ClusterName)

        $vDiskResults = @()
        foreach ($vDisk in $vDisks) {
            $result = @{
                Name                  = $vDisk.FriendlyName
                HealthStatus          = $vDisk.HealthStatus.ToString()
                OperationalStatus     = $vDisk.OperationalStatus.ToString()
                ResiliencySettingName = $vDisk.ResiliencySettingName
                Size                  = [math]::Round($vDisk.Size / 1TB, 2)
                FootprintOnPool       = [math]::Round($vDisk.FootprintOnPool / 1TB, 2)
            }

            $vDiskResults += $result

            if ($vDisk.HealthStatus -eq 'Healthy') {
                Write-StorageLog -Message "  VDisk: $($vDisk.FriendlyName) - Healthy (Resiliency: $($vDisk.ResiliencySettingName))" -Level 'SUCCESS'
            }
            else {
                Write-StorageLog -Message "  VDisk: $($vDisk.FriendlyName) - $($vDisk.HealthStatus)" -Level 'ERROR'
            }
        }

        $TestResults.StorageHealth.VirtualDisks = $vDiskResults
    }
    catch {
        Write-StorageLog -Message "Failed to check virtual disks: $_" -Level 'ERROR'
    }
}

function Test-PhysicalDiskHealth {
    Write-StorageLog -Message 'Checking physical disk health...' -Level 'INFO'

    try {
        $pDisks = @(Get-PhysicalDisk -CimSession $ClusterName | Where-Object { $_.Usage -ne 'AutoSelect' -or $_.CanPool -eq $false })

        $healthySSD = @($pDisks | Where-Object { $_.MediaType -eq 'SSD' -and $_.HealthStatus -eq 'Healthy' }).Count
        $healthyHDD = @($pDisks | Where-Object { $_.MediaType -eq 'HDD' -and $_.HealthStatus -eq 'Healthy' }).Count
        $unhealthyDisks = @($pDisks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        $unhealthy = $unhealthyDisks.Count

        Write-StorageLog -Message "  Physical Disks: $($pDisks.Count) total ($healthySSD SSD, $healthyHDD HDD)" -Level 'INFO'

        if ($unhealthy -gt 0) {
            Write-StorageLog -Message "  WARNING: $unhealthy disk(s) not healthy!" -Level 'WARN'
            foreach ($disk in $unhealthyDisks) {
                Write-StorageLog -Message "    - $($disk.FriendlyName): $($disk.HealthStatus) / $($disk.OperationalStatus)" -Level 'ERROR'
            }
        }
        else {
            Write-StorageLog -Message '  All physical disks healthy' -Level 'SUCCESS'
        }

        $TestResults.StorageHealth.PhysicalDisks = @{
            Total      = $pDisks.Count
            HealthySSD = $healthySSD
            HealthyHDD = $healthyHDD
            Unhealthy  = $unhealthy
        }
    }
    catch {
        Write-StorageLog -Message "Failed to check physical disks: $_" -Level 'ERROR'
    }
}

function Test-ClusterSharedVolumes {
    Write-StorageLog -Message 'Checking Cluster Shared Volumes...' -Level 'INFO'

    try {
        $csvs = @(Get-ClusterSharedVolume -Cluster $ClusterName)

        if ($VolumeNames) {
            $csvs = @($csvs | Where-Object { $VolumeNames -contains $_.Name })
        }

        $csvResults = @()
        foreach ($csv in $csvs) {
            $csvInfo = $csv.SharedVolumeInfo[0]
            $partition = $csvInfo.Partition

            $result = @{
                Name               = $csv.Name
                State              = $csv.State.ToString()
                OwnerNode          = $csv.OwnerNode.Name
                FriendlyVolumeName = $csvInfo.FriendlyVolumeName
                Size               = [math]::Round($partition.Size / 1TB, 2)
                FreeSpace          = [math]::Round($partition.FreeSpace / 1GB, 2)
                UsagePercent       = [math]::Round((($partition.Size - $partition.FreeSpace) / $partition.Size) * 100, 1)
            }

            $csvResults += $result

            if ($csv.State -eq 'Online') {
                if ($result.UsagePercent -gt $CsvUsageWarningPercent) {
                    Write-StorageLog -Message "  CSV: $($csv.Name) - Online (WARNING: $($result.UsagePercent)% used, limit $CsvUsageWarningPercent%)" -Level 'WARN'
                }
                else {
                    Write-StorageLog -Message "  CSV: $($csv.Name) - Online ($($result.UsagePercent)% used, Owner: $($csv.OwnerNode.Name))" -Level 'SUCCESS'
                }
            }
            else {
                Write-StorageLog -Message "  CSV: $($csv.Name) - $($csv.State)" -Level 'ERROR'
            }
        }

        $TestResults.VolumeTests = $csvResults
    }
    catch {
        Write-StorageLog -Message "Failed to check CSVs: $_" -Level 'ERROR'
    }
}

function Test-StoragePerformanceIO {
    if (-not $RunPerformanceTest) {
        Write-StorageLog -Message 'Skipping performance test (use -RunPerformanceTest to enable)' -Level 'INFO'
        return
    }

    Write-StorageLog -Message "Running storage performance test (${DurationSeconds}s duration)..." -Level 'INFO'
    Write-StorageLog -Message 'This will generate I/O on the cluster' -Level 'WARN'

    try {
        $csvs = @(Get-ClusterSharedVolume -Cluster $ClusterName)

        if ($VolumeNames) {
            $csvs = @($csvs | Where-Object { $VolumeNames -contains $_.Name })
        }

        foreach ($csv in $csvs) {
            $testPath = Join-Path $csv.SharedVolumeInfo[0].FriendlyVolumeName $ScratchFolderName
            $ownerNode = $csv.OwnerNode.Name

            Write-StorageLog -Message "  Testing: $($csv.Name) on $ownerNode" -Level 'INFO'

            # Run performance test on owner node
            $perfResults = Invoke-Command -ComputerName $ownerNode -ScriptBlock {
                param($testPath, $duration, $fileName, $ioSize, $percentile)

                # Create test directory
                if (-not (Test-Path $testPath)) {
                    New-Item -Path $testPath -ItemType Directory -Force | Out-Null
                }

                $testFile = Join-Path $testPath $fileName
                $writeLatencyMs = [System.Collections.Generic.List[double]]::new()
                $readLatencyMs = [System.Collections.Generic.List[double]]::new()

                # Write test (sequential writes of one I/O size, flushed to disk)
                $sw = [System.Diagnostics.Stopwatch]::new()
                $endTime = [datetime]::Now.AddSeconds($duration / 2)
                $writeCount = 0

                $buffer = [byte[]]::new($ioSize)
                [System.Random]::new().NextBytes($buffer)

                $fs = [System.IO.File]::Open($testFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)

                while ([datetime]::Now -lt $endTime) {
                    $sw.Restart()
                    $fs.Write($buffer, 0, $buffer.Length)
                    $fs.Flush($true)
                    $sw.Stop()
                    $writeLatencyMs.Add($sw.Elapsed.TotalMilliseconds)
                    $writeCount++
                }
                $fs.Close()

                # Read test (random reads of one I/O size)
                $endTime = [datetime]::Now.AddSeconds($duration / 2)
                $readCount = 0

                $fs = [System.IO.File]::Open($testFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
                $fileLen = $fs.Length
                $random = [System.Random]::new()

                while ([datetime]::Now -lt $endTime) {
                    $position = $random.Next(0, [int]($fileLen / $ioSize)) * $ioSize
                    $fs.Position = $position
                    $sw.Restart()
                    $fs.Read($buffer, 0, $buffer.Length) | Out-Null
                    $sw.Stop()
                    $readLatencyMs.Add($sw.Elapsed.TotalMilliseconds)
                    $readCount++
                }
                $fs.Close()

                # Cleanup
                Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $testPath -Force -ErrorAction SilentlyContinue

                # Calculate statistics
                $avgWrite = 0
                $p99Write = 0
                if ($writeLatencyMs.Count -gt 0) {
                    $avgWrite = [math]::Round(($writeLatencyMs | Measure-Object -Average).Average, 2)
                    $p99Write = [math]::Round(($writeLatencyMs | Sort-Object)[[math]::Min([int]($writeLatencyMs.Count * $percentile), $writeLatencyMs.Count - 1)], 2)
                }
                $avgRead = 0
                $p99Read = 0
                if ($readLatencyMs.Count -gt 0) {
                    $avgRead = [math]::Round(($readLatencyMs | Measure-Object -Average).Average, 2)
                    $p99Read = [math]::Round(($readLatencyMs | Sort-Object)[[math]::Min([int]($readLatencyMs.Count * $percentile), $readLatencyMs.Count - 1)], 2)
                }
                @{
                    WriteOps          = $writeCount
                    ReadOps           = $readCount
                    AvgWriteLatencyMs = $avgWrite
                    AvgReadLatencyMs  = $avgRead
                    P99WriteLatencyMs = $p99Write
                    P99ReadLatencyMs  = $p99Read
                }
            } -ArgumentList $testPath, $DurationSeconds, $ScratchFileName, $IoSizeBytes, $PercentileFraction -ErrorAction Stop

            $perfResult = @{
                Volume            = $csv.Name
                Node              = $ownerNode
                DurationSeconds   = $DurationSeconds
                WriteOps          = $perfResults.WriteOps
                ReadOps           = $perfResults.ReadOps
                AvgWriteLatencyMs = $perfResults.AvgWriteLatencyMs
                AvgReadLatencyMs  = $perfResults.AvgReadLatencyMs
                P99WriteLatencyMs = $perfResults.P99WriteLatencyMs
                P99ReadLatencyMs  = $perfResults.P99ReadLatencyMs
            }

            $TestResults.PerformanceResults += $perfResult

            Write-StorageLog -Message "    Write: $($perfResults.WriteOps) ops, Avg: $($perfResults.AvgWriteLatencyMs)ms, P99: $($perfResults.P99WriteLatencyMs)ms" -Level 'INFO'
            Write-StorageLog -Message "    Read:  $($perfResults.ReadOps) ops, Avg: $($perfResults.AvgReadLatencyMs)ms, P99: $($perfResults.P99ReadLatencyMs)ms" -Level 'INFO'

            # Assess results
            if ($perfResults.AvgWriteLatencyMs -gt $MaxAvgWriteLatencyMs -or $perfResults.AvgReadLatencyMs -gt $MaxAvgReadLatencyMs) {
                Write-StorageLog -Message "    Performance below expected thresholds (write $MaxAvgWriteLatencyMs ms, read $MaxAvgReadLatencyMs ms)" -Level 'WARN'
            }
            else {
                Write-StorageLog -Message '    Performance within expected thresholds' -Level 'SUCCESS'
            }
        }
    }
    catch {
        Write-StorageLog -Message "Performance test failed: $_" -Level 'ERROR'
    }
}

function Test-StorageResiliency {
    Write-StorageLog -Message 'Checking storage resiliency configuration...' -Level 'INFO'

    try {
        $vDisks = @(Get-VirtualDisk -CimSession $ClusterName)
        $nodes = @(Get-ClusterNode -Cluster $ClusterName).Count

        foreach ($vDisk in $vDisks) {
            $resiliency = $vDisk.ResiliencySettingName
            $faultDomainAwareness = $vDisk.FaultDomainAwareness

            # Check if resiliency matches cluster size
            if ($resiliency -eq 'Mirror' -and $nodes -ge 2) {
                Write-StorageLog -Message "  $($vDisk.FriendlyName): Mirror resiliency OK (Fault Domain: $faultDomainAwareness)" -Level 'SUCCESS'
            }
            elseif ($resiliency -eq 'Parity' -and $nodes -ge 3) {
                Write-StorageLog -Message "  $($vDisk.FriendlyName): Parity resiliency OK (Fault Domain: $faultDomainAwareness)" -Level 'SUCCESS'
            }
            else {
                Write-StorageLog -Message "  $($vDisk.FriendlyName): Review resiliency ($resiliency with $nodes nodes)" -Level 'WARN'
            }
        }
    }
    catch {
        Write-StorageLog -Message "Failed to check resiliency: $_" -Level 'ERROR'
    }
}

function Export-StorageTestResults {
    if ($OutputPath) {
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        $reportPath = Join-Path $OutputPath "storage-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $TestResults | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath
        Write-StorageLog -Message "Results saved to: $reportPath" -Level 'INFO'
    }
}

# Main execution
try {
    Write-StorageLog -Message '========================================' -Level 'INFO'
    Write-StorageLog -Message 'Storage Performance and Health Validation' -Level 'INFO'
    Write-StorageLog -Message "Cluster: $ClusterName" -Level 'INFO'
    Write-StorageLog -Message '========================================' -Level 'INFO'
    Write-Host ''

    # Run all tests
    Test-StoragePoolHealth
    Write-Host ''

    Test-VirtualDiskHealth
    Write-Host ''

    Test-PhysicalDiskHealth
    Write-Host ''

    Test-ClusterSharedVolumes
    Write-Host ''

    Test-StorageResiliency
    Write-Host ''

    Test-StoragePerformanceIO
    Write-Host ''

    # Export results
    Export-StorageTestResults

    Write-StorageLog -Message '========================================' -Level 'INFO'
    if ($script:ErrorCount -gt 0) {
        Write-StorageLog -Message "Storage validation finished with $($script:ErrorCount) error(s)" -Level 'WARN'
        exit 1
    }
    Write-StorageLog -Message 'Storage validation complete' -Level 'SUCCESS'
}
catch {
    Write-StorageLog -Message "Storage validation failed: $_" -Level 'ERROR'
    exit 1
}
