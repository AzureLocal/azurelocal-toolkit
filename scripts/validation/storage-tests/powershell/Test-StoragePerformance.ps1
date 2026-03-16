<#
.SYNOPSIS
    Tests Azure Local storage performance and configuration.

.DESCRIPTION
    This script performs storage validation including:
    - Storage pool health and capacity
    - Virtual disk performance testing
    - CSV ownership and status
    - Disk I/O latency measurements
    - Storage resiliency verification

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER VolumeNames
    Optional. Specific CSV volume names to test. If not specified, tests all CSVs.

.PARAMETER RunPerformanceTest
    Switch to run disk performance tests (I/O benchmark).

.PARAMETER DurationSeconds
    Duration of performance test in seconds. Default: 60

.PARAMETER OutputPath
    Path to save test results.

.EXAMPLE
    .\Test-StoragePerformance.ps1 -ClusterName "azl-cluster-01"

.EXAMPLE
    .\Test-StoragePerformance.ps1 -ClusterName "azl-cluster-01" -RunPerformanceTest -DurationSeconds 120

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
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
    [int]$DurationSeconds = 60,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# Import logging helper
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

# Initialize results
$TestResults = @{
    Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    ClusterName = $ClusterName
    StorageHealth = @{}
    VolumeTests = @()
    PerformanceResults = @()
}

function Test-StoragePoolHealth {
    Write-Log -Message "Checking storage pool health..." -Level "INFO"
    
    try {
        # Get all non-primordial storage pools
        $pools = Get-StoragePool -CimSession $ClusterName | Where-Object { $_.IsPrimordial -eq $false }
        
        $poolResults = @()
        foreach ($pool in $pools) {
            $healthStatus = $pool.HealthStatus.ToString()
            $operationalStatus = $pool.OperationalStatus.ToString()
            
            $result = @{
                Name = $pool.FriendlyName
                HealthStatus = $healthStatus
                OperationalStatus = $operationalStatus
                Size = [math]::Round($pool.Size / 1TB, 2)
                AllocatedSize = [math]::Round($pool.AllocatedSize / 1TB, 2)
                FreeSpaceGB = [math]::Round(($pool.Size - $pool.AllocatedSize) / 1GB, 2)
                UsagePercent = [math]::Round(($pool.AllocatedSize / $pool.Size) * 100, 1)
            }
            
            $poolResults += $result
            
            if ($healthStatus -eq "Healthy") {
                Write-Log -Message "  Pool: $($pool.FriendlyName) - Healthy ($($result.UsagePercent)% used)" -Level "SUCCESS"
            }
            elseif ($healthStatus -eq "Warning") {
                Write-Log -Message "  Pool: $($pool.FriendlyName) - Warning: $operationalStatus" -Level "WARN"
            }
            else {
                Write-Log -Message "  Pool: $($pool.FriendlyName) - $healthStatus: $operationalStatus" -Level "ERROR"
            }
        }
        
        $TestResults.StorageHealth.Pools = $poolResults
    }
    catch {
        Write-Log -Message "Failed to check storage pools: $_" -Level "ERROR"
    }
}

function Test-VirtualDiskHealth {
    Write-Log -Message "Checking virtual disk health..." -Level "INFO"
    
    try {
        $vDisks = Get-VirtualDisk -CimSession $ClusterName
        
        $vDiskResults = @()
        foreach ($vDisk in $vDisks) {
            $result = @{
                Name = $vDisk.FriendlyName
                HealthStatus = $vDisk.HealthStatus.ToString()
                OperationalStatus = $vDisk.OperationalStatus.ToString()
                ResiliencySettingName = $vDisk.ResiliencySettingName
                Size = [math]::Round($vDisk.Size / 1TB, 2)
                FootprintOnPool = [math]::Round($vDisk.FootprintOnPool / 1TB, 2)
            }
            
            $vDiskResults += $result
            
            if ($vDisk.HealthStatus -eq "Healthy") {
                Write-Log -Message "  VDisk: $($vDisk.FriendlyName) - Healthy (Resiliency: $($vDisk.ResiliencySettingName))" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  VDisk: $($vDisk.FriendlyName) - $($vDisk.HealthStatus)" -Level "ERROR"
            }
        }
        
        $TestResults.StorageHealth.VirtualDisks = $vDiskResults
    }
    catch {
        Write-Log -Message "Failed to check virtual disks: $_" -Level "ERROR"
    }
}

function Test-PhysicalDiskHealth {
    Write-Log -Message "Checking physical disk health..." -Level "INFO"
    
    try {
        $pDisks = Get-PhysicalDisk -CimSession $ClusterName | Where-Object { $_.Usage -ne "AutoSelect" -or $_.CanPool -eq $false }
        
        $healthySSD = ($pDisks | Where-Object { $_.MediaType -eq "SSD" -and $_.HealthStatus -eq "Healthy" }).Count
        $healthyHDD = ($pDisks | Where-Object { $_.MediaType -eq "HDD" -and $_.HealthStatus -eq "Healthy" }).Count
        $unhealthy = ($pDisks | Where-Object { $_.HealthStatus -ne "Healthy" }).Count
        
        Write-Log -Message "  Physical Disks: $($pDisks.Count) total ($healthySSD SSD, $healthyHDD HDD)" -Level "INFO"
        
        if ($unhealthy -gt 0) {
            Write-Log -Message "  WARNING: $unhealthy disk(s) not healthy!" -Level "WARN"
            foreach ($disk in ($pDisks | Where-Object { $_.HealthStatus -ne "Healthy" })) {
                Write-Log -Message "    - $($disk.FriendlyName): $($disk.HealthStatus) / $($disk.OperationalStatus)" -Level "ERROR"
            }
        }
        else {
            Write-Log -Message "  All physical disks healthy" -Level "SUCCESS"
        }
        
        $TestResults.StorageHealth.PhysicalDisks = @{
            Total = $pDisks.Count
            HealthySSD = $healthySSD
            HealthyHDD = $healthyHDD
            Unhealthy = $unhealthy
        }
    }
    catch {
        Write-Log -Message "Failed to check physical disks: $_" -Level "ERROR"
    }
}

function Test-ClusterSharedVolumes {
    Write-Log -Message "Checking Cluster Shared Volumes..." -Level "INFO"
    
    try {
        $csvs = Get-ClusterSharedVolume -Cluster $ClusterName
        
        if ($VolumeNames) {
            $csvs = $csvs | Where-Object { $VolumeNames -contains $_.Name }
        }
        
        $csvResults = @()
        foreach ($csv in $csvs) {
            $csvInfo = $csv.SharedVolumeInfo[0]
            $partition = $csvInfo.Partition
            
            $result = @{
                Name = $csv.Name
                State = $csv.State.ToString()
                OwnerNode = $csv.OwnerNode.Name
                FriendlyVolumeName = $csvInfo.FriendlyVolumeName
                Size = [math]::Round($partition.Size / 1TB, 2)
                FreeSpace = [math]::Round($partition.FreeSpace / 1GB, 2)
                UsagePercent = [math]::Round((($partition.Size - $partition.FreeSpace) / $partition.Size) * 100, 1)
            }
            
            $csvResults += $result
            
            if ($csv.State -eq "Online") {
                if ($result.UsagePercent -gt 85) {
                    Write-Log -Message "  CSV: $($csv.Name) - Online (WARNING: $($result.UsagePercent)% used)" -Level "WARN"
                }
                else {
                    Write-Log -Message "  CSV: $($csv.Name) - Online ($($result.UsagePercent)% used, Owner: $($csv.OwnerNode.Name))" -Level "SUCCESS"
                }
            }
            else {
                Write-Log -Message "  CSV: $($csv.Name) - $($csv.State)" -Level "ERROR"
            }
        }
        
        $TestResults.VolumeTests = $csvResults
    }
    catch {
        Write-Log -Message "Failed to check CSVs: $_" -Level "ERROR"
    }
}

function Test-StoragePerformanceIO {
    if (-not $RunPerformanceTest) {
        Write-Log -Message "Skipping performance test (use -RunPerformanceTest to enable)" -Level "INFO"
        return
    }
    
    Write-Log -Message "Running storage performance test (${DurationSeconds}s duration)..." -Level "INFO"
    Write-Log -Message "This will generate I/O on the cluster" -Level "WARN"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        $csvs = Get-ClusterSharedVolume -Cluster $ClusterName
        
        if ($VolumeNames) {
            $csvs = $csvs | Where-Object { $VolumeNames -contains $_.Name }
        }
        
        foreach ($csv in $csvs) {
            $testPath = Join-Path $csv.SharedVolumeInfo[0].FriendlyVolumeName "StorageTest"
            $ownerNode = $csv.OwnerNode.Name
            
            Write-Log -Message "  Testing: $($csv.Name) on $ownerNode" -Level "INFO"
            
            # Run performance test on owner node
            $perfResults = Invoke-Command -ComputerName $ownerNode -ScriptBlock {
                param($testPath, $duration)
                
                # Create test directory
                if (-not (Test-Path $testPath)) {
                    New-Item -Path $testPath -ItemType Directory -Force | Out-Null
                }
                
                $testFile = Join-Path $testPath "iobench.dat"
                $results = @{
                    WriteLatencyMs = @()
                    ReadLatencyMs = @()
                }
                
                # Write test (4KB random writes)
                $sw = [System.Diagnostics.Stopwatch]::new()
                $endTime = [datetime]::Now.AddSeconds($duration / 2)
                $writeCount = 0
                
                $buffer = [byte[]]::new(4KB)
                [System.Random]::new().NextBytes($buffer)
                
                $fs = [System.IO.File]::Open($testFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
                
                while ([datetime]::Now -lt $endTime) {
                    $sw.Restart()
                    $fs.Write($buffer, 0, $buffer.Length)
                    $fs.Flush($true)
                    $sw.Stop()
                    $results.WriteLatencyMs += $sw.Elapsed.TotalMilliseconds
                    $writeCount++
                }
                $fs.Close()
                
                # Read test (4KB random reads)
                $endTime = [datetime]::Now.AddSeconds($duration / 2)
                $readCount = 0
                
                $fs = [System.IO.File]::Open($testFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
                $fileLen = $fs.Length
                $random = [System.Random]::new()
                
                while ([datetime]::Now -lt $endTime) {
                    $position = $random.Next(0, [int]($fileLen / 4KB)) * 4KB
                    $fs.Position = $position
                    $sw.Restart()
                    $fs.Read($buffer, 0, $buffer.Length) | Out-Null
                    $sw.Stop()
                    $results.ReadLatencyMs += $sw.Elapsed.TotalMilliseconds
                    $readCount++
                }
                $fs.Close()
                
                # Cleanup
                Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $testPath -Force -ErrorAction SilentlyContinue
                
                # Calculate statistics
                @{
                    WriteOps = $writeCount
                    ReadOps = $readCount
                    AvgWriteLatencyMs = if ($results.WriteLatencyMs.Count -gt 0) { 
                        [math]::Round(($results.WriteLatencyMs | Measure-Object -Average).Average, 2) 
                    } else { 0 }
                    AvgReadLatencyMs = if ($results.ReadLatencyMs.Count -gt 0) { 
                        [math]::Round(($results.ReadLatencyMs | Measure-Object -Average).Average, 2) 
                    } else { 0 }
                    P99WriteLatencyMs = if ($results.WriteLatencyMs.Count -gt 0) { 
                        [math]::Round(($results.WriteLatencyMs | Sort-Object)[[int]($results.WriteLatencyMs.Count * 0.99)], 2) 
                    } else { 0 }
                    P99ReadLatencyMs = if ($results.ReadLatencyMs.Count -gt 0) { 
                        [math]::Round(($results.ReadLatencyMs | Sort-Object)[[int]($results.ReadLatencyMs.Count * 0.99)], 2) 
                    } else { 0 }
                }
            } -ArgumentList $testPath, $DurationSeconds -ErrorAction Stop
            
            $perfResult = @{
                Volume = $csv.Name
                Node = $ownerNode
                DurationSeconds = $DurationSeconds
                WriteOps = $perfResults.WriteOps
                ReadOps = $perfResults.ReadOps
                AvgWriteLatencyMs = $perfResults.AvgWriteLatencyMs
                AvgReadLatencyMs = $perfResults.AvgReadLatencyMs
                P99WriteLatencyMs = $perfResults.P99WriteLatencyMs
                P99ReadLatencyMs = $perfResults.P99ReadLatencyMs
            }
            
            $TestResults.PerformanceResults += $perfResult
            
            Write-Log -Message "    Write: $($perfResults.WriteOps) ops, Avg: $($perfResults.AvgWriteLatencyMs)ms, P99: $($perfResults.P99WriteLatencyMs)ms" -Level "INFO"
            Write-Log -Message "    Read:  $($perfResults.ReadOps) ops, Avg: $($perfResults.AvgReadLatencyMs)ms, P99: $($perfResults.P99ReadLatencyMs)ms" -Level "INFO"
            
            # Assess results
            if ($perfResults.AvgWriteLatencyMs -gt 10 -or $perfResults.AvgReadLatencyMs -gt 5) {
                Write-Log -Message "    Performance below expected thresholds" -Level "WARN"
            }
            else {
                Write-Log -Message "    Performance within expected thresholds" -Level "SUCCESS"
            }
        }
    }
    catch {
        Write-Log -Message "Performance test failed: $_" -Level "ERROR"
    }
}

function Test-StorageResiliency {
    Write-Log -Message "Checking storage resiliency configuration..." -Level "INFO"
    
    try {
        $vDisks = Get-VirtualDisk -CimSession $ClusterName
        
        foreach ($vDisk in $vDisks) {
            $resiliency = $vDisk.ResiliencySettingName
            $faultDomainAwareness = $vDisk.FaultDomainAwareness
            
            # Check if resiliency matches cluster size
            $nodes = (Get-ClusterNode -Cluster $ClusterName).Count
            
            if ($resiliency -eq "Mirror" -and $nodes -ge 2) {
                Write-Log -Message "  $($vDisk.FriendlyName): Mirror resiliency OK (Fault Domain: $faultDomainAwareness)" -Level "SUCCESS"
            }
            elseif ($resiliency -eq "Parity" -and $nodes -ge 3) {
                Write-Log -Message "  $($vDisk.FriendlyName): Parity resiliency OK (Fault Domain: $faultDomainAwareness)" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $($vDisk.FriendlyName): Review resiliency ($resiliency with $nodes nodes)" -Level "WARN"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check resiliency: $_" -Level "ERROR"
    }
}

function Export-StorageTestResults {
    if ($OutputPath) {
        $reportPath = Join-Path $OutputPath "storage-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $TestResults | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath
        Write-Log -Message "Results saved to: $reportPath" -Level "INFO"
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Storage Performance and Health Validation" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    # Run all tests
    Test-StoragePoolHealth
    Write-Host ""
    
    Test-VirtualDiskHealth
    Write-Host ""
    
    Test-PhysicalDiskHealth
    Write-Host ""
    
    Test-ClusterSharedVolumes
    Write-Host ""
    
    Test-StorageResiliency
    Write-Host ""
    
    Test-StoragePerformanceIO
    Write-Host ""
    
    # Export results
    Export-StorageTestResults
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Storage validation complete" -Level "SUCCESS"
}
catch {
    Write-Log -Message "Storage validation failed: $_" -Level "ERROR"
    exit 1
}
