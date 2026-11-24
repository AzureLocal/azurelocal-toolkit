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

    Run it from the management host. Every question is asked over PowerShell remoting on a node (the performance test on the node that
    owns the volume, at its management address of the file), so this host needs neither the failover clustering tools nor membership of
    the cluster's domain, and the cluster name need not resolve from it. It asks for nothing: the cluster is cluster.name of
    infrastructure.yml, and every limit it applies is a parameter. Without -RunPerformanceTest it changes nothing.

    Exit codes: 0 when no check logged an error, 1 when a check or the run failed, 2 when cluster.name is missing or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name (the cluster to test), nodes[] (the management addresses to connect to) and
    identity.active_directory (the deployment user and its secret reference); the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to send the cluster questions to. Default: the first node of nodes[] that answers on WinRM at its management
    address; cluster.name when the file has no node address.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Default: the deployment (LCM) user of the file, its secret read through the
    toolkit's secret resolver; the account that runs the script when the file has none or the secret cannot be read.

.PARAMETER VolumeNames
    Optional. Specific CSV volume names to test. If not specified, tests all CSVs.

.PARAMETER RunPerformanceTest
    Switch to run disk performance tests (I/O benchmark) on every online CSV, or on those of -VolumeNames. The infrastructure volume of the
    instance (Infrastructure_1) is only tested when -VolumeNames names it.

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
    .\Test-StoragePerformance.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    .\Test-StoragePerformance.ps1 -InfrastructureFile ./infrastructure.yml -RunPerformanceTest -DurationSeconds 120

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.1.0
    Created: 2026-02-01

    Running performance tests will generate I/O on the cluster.
    Consider running during maintenance windows for production clusters.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read by the functions of the script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names of the check functions inside the script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The values are passed to the remote script blocks with -ArgumentList.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

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

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Error "Cannot read the infrastructure file: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
$ClusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $ClusterName) { Write-Error 'cluster.name is missing in the infrastructure file. It is the name of the cluster to test.' -ErrorAction Continue; exit 2 }
$connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $ComputerName -Credential $Credential -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }

# The blocks that run on a node (Windows PowerShell): read only, plain values back, so nothing depends on the storage or failover clustering tools of this host.
$ReadPools = { @(Get-StoragePool -IsPrimordial $false -ErrorAction Stop | ForEach-Object { @{ FriendlyName = [string]$_.FriendlyName; HealthStatus = [string]$_.HealthStatus; OperationalStatus = [string]$_.OperationalStatus; Size = [double]$_.Size; AllocatedSize = [double]$_.AllocatedSize } }) }
$ReadVirtualDisks = { @(Get-VirtualDisk -ErrorAction Stop | ForEach-Object { @{ FriendlyName = [string]$_.FriendlyName; HealthStatus = [string]$_.HealthStatus; OperationalStatus = [string]$_.OperationalStatus; ResiliencySettingName = [string]$_.ResiliencySettingName; FaultDomainAwareness = [string]$_.FaultDomainAwareness; Size = [double]$_.Size; FootprintOnPool = [double]$_.FootprintOnPool } }) }
# The disks of the pool (Get-StoragePool | Get-PhysicalDisk): the boot device and the SAN LUNs of a node are not pool disks.
$ReadPhysicalDisks = { @(Get-StoragePool -IsPrimordial $false -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { @{ FriendlyName = [string]$_.FriendlyName; SerialNumber = [string]$_.SerialNumber; MediaType = [string]$_.MediaType; BusType = [string]$_.BusType; HealthStatus = [string]$_.HealthStatus; OperationalStatus = [string]$_.OperationalStatus } }) }
$ReadCsv = {
    @(Get-ClusterSharedVolume -ErrorAction Stop | ForEach-Object {
            $info = @($_.SharedVolumeInfo)[0]
            @{ Name = [string]$_.Name; State = [string]$_.State; OwnerNode = [string]$_.OwnerNode.Name; FriendlyVolumeName = [string]$info.FriendlyVolumeName; Size = [double]$info.Partition.Size; FreeSpace = [double]$info.Partition.FreeSpace }
        })
}
$ReadNodeCount = { @(Get-ClusterNode -ErrorAction Stop).Count }

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
        $pools = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadPools)

        $poolResults = @()
        foreach ($pool in $pools) {
            $healthStatus = [string]$pool.HealthStatus
            $operationalStatus = [string]$pool.OperationalStatus

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
        $vDisks = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadVirtualDisks)

        $vDiskResults = @()
        foreach ($vDisk in $vDisks) {
            $result = @{
                Name                  = $vDisk.FriendlyName
                HealthStatus          = [string]$vDisk.HealthStatus
                OperationalStatus     = [string]$vDisk.OperationalStatus
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
        $pDisks = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadPhysicalDisks)

        $healthySSD = @($pDisks | Where-Object { $_.MediaType -eq 'SSD' -and $_.HealthStatus -eq 'Healthy' }).Count
        $healthyHDD = @($pDisks | Where-Object { $_.MediaType -eq 'HDD' -and $_.HealthStatus -eq 'Healthy' }).Count
        $unhealthyDisks = @($pDisks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        $unhealthy = $unhealthyDisks.Count

        Write-StorageLog -Message "  Physical disks of the pool: $($pDisks.Count) total ($healthySSD healthy SSD, $healthyHDD healthy HDD)" -Level 'INFO'
        if ($pDisks.Count -eq 0) { Write-StorageLog -Message '  The storage pool has no physical disk' -Level 'ERROR' }

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
        $csvs = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadCsv)

        if ($VolumeNames) {
            $csvs = @($csvs | Where-Object { $VolumeNames -contains $_.Name })
            foreach ($missing in @($VolumeNames | Where-Object { $_ -notin @($csvs | ForEach-Object { $_.Name }) })) { Write-StorageLog -Message "  CSV: '$missing' (-VolumeNames) is not a Cluster Shared Volume of the cluster" -Level 'ERROR' }
        }

        $csvResults = @()
        foreach ($csv in $csvs) {
            $result = @{
                Name               = $csv.Name
                State              = $csv.State
                OwnerNode          = $csv.OwnerNode
                FriendlyVolumeName = $csv.FriendlyVolumeName
                Size               = [math]::Round($csv.Size / 1TB, 2)
                FreeSpace          = [math]::Round($csv.FreeSpace / 1GB, 2)
                UsagePercent       = $(if ($csv.Size -gt 0) { [math]::Round((($csv.Size - $csv.FreeSpace) / $csv.Size) * 100, 1) } else { 0 })
            }

            $csvResults += $result

            if ($csv.State -eq 'Online') {
                if ($result.UsagePercent -gt $CsvUsageWarningPercent) {
                    Write-StorageLog -Message "  CSV: $($csv.Name) - Online (WARNING: $($result.UsagePercent)% used, limit $CsvUsageWarningPercent%)" -Level 'WARN'
                }
                else {
                    Write-StorageLog -Message "  CSV: $($csv.Name) - Online ($($result.UsagePercent)% used, Owner: $($csv.OwnerNode))" -Level 'SUCCESS'
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
        $csvs = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadCsv | Where-Object { $_.State -eq 'Online' })

        if ($VolumeNames) {
            $csvs = @($csvs | Where-Object { $VolumeNames -contains $_.Name })
        }
        else {
            # The infrastructure volume of the instance is not a workload volume: it is only tested when -VolumeNames names it.
            foreach ($skipped in @($csvs | Where-Object { (Split-Path -Leaf $_.FriendlyVolumeName) -like 'Infrastructure_*' })) { Write-StorageLog -Message "  Skipping the infrastructure volume $($skipped.Name) (name it in -VolumeNames to test it)" -Level 'INFO' }
            $csvs = @($csvs | Where-Object { (Split-Path -Leaf $_.FriendlyVolumeName) -notlike 'Infrastructure_*' })
        }
        if ($csvs.Count -eq 0) { Write-StorageLog -Message '  No online Cluster Shared Volume to test' -Level 'ERROR' }

        foreach ($csv in $csvs) {
            $testPath = Join-Path $csv.FriendlyVolumeName $ScratchFolderName
            $ownerNode = $csv.OwnerNode

            Write-StorageLog -Message "  Testing: $($csv.Name) on $ownerNode" -Level 'INFO'

            # Run performance test on owner node
            $perfResults = Invoke-AzlClusterCommand -Connection $connection -Node $ownerNode -ScriptBlock {
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
            } -ArgumentList $testPath, $DurationSeconds, $ScratchFileName, $IoSizeBytes, $PercentileFraction

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
        $vDisks = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadVirtualDisks)
        $nodes = [int](Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadNodeCount)

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
    Write-StorageLog -Message (Format-AzlClusterConnection -Connection $connection) -Level 'INFO'
    foreach ($note in $connection.Notes) { Write-StorageLog -Message $note -Level 'WARN' }
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
    exit 0
}
catch {
    Write-StorageLog -Message "Storage validation failed: $_" -Level 'ERROR'
    exit 1
}
