<#
.SYNOPSIS
    Provides operational management functions for Azure Local clusters.

.DESCRIPTION
    This script provides day-to-day operational functions including:
    - Cluster health monitoring
    - Node maintenance mode management
    - Live migration operations
    - Storage rebalancing
    - Capacity monitoring
    - Alert management

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER Action
    Action to perform: HealthCheck, MaintenanceMode, LiveMigrate, Rebalance, Capacity, Alerts

.PARAMETER NodeName
    Node name for node-specific operations.

.PARAMETER Enable
    Enable maintenance mode (used with MaintenanceMode action).

.PARAMETER OutputPath
    Path to save operation reports.

.EXAMPLE
    .\Invoke-ClusterOperations.ps1 -ClusterName "azl-cluster-01" -Action HealthCheck

.EXAMPLE
    .\Invoke-ClusterOperations.ps1 -ClusterName "azl-cluster-01" -Action MaintenanceMode -NodeName "node-01" -Enable

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("HealthCheck", "MaintenanceMode", "LiveMigrate", "Rebalance", "Capacity", "Alerts")]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$NodeName,

    [Parameter(Mandatory = $false)]
    [switch]$Enable,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# Import helpers
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

function Invoke-HealthCheck {
    Write-Log -Message "Running comprehensive health check..." -Level "INFO"
    Write-Host ""
    
    $healthReport = @{
        Timestamp = Get-Date
        OverallHealth = "Healthy"
        Components = @{}
    }
    
    # Cluster status
    Write-Log -Message "Cluster Status:" -Level "INFO"
    try {
        $cluster = Get-Cluster -Name $ClusterName
        $nodes = Get-ClusterNode -Cluster $ClusterName
        
        $upNodes = ($nodes | Where-Object { $_.State -eq "Up" }).Count
        $totalNodes = $nodes.Count
        
        if ($upNodes -eq $totalNodes) {
            Write-Host "  All nodes online ($upNodes/$totalNodes)" -ForegroundColor Green
        }
        else {
            Write-Host "  Nodes: $upNodes/$totalNodes online" -ForegroundColor Yellow
            $healthReport.OverallHealth = "Warning"
        }
        
        foreach ($node in $nodes) {
            $status = if ($node.State -eq "Up") { "Green" } else { "Red" }
            Write-Host "    $($node.Name): $($node.State)" -ForegroundColor $status
        }
        
        $healthReport.Components.Cluster = @{
            Status = "OK"
            NodesUp = $upNodes
            NodesTotal = $totalNodes
        }
    }
    catch {
        Write-Log -Message "  Failed to check cluster: $_" -Level "ERROR"
        $healthReport.OverallHealth = "Critical"
    }
    
    Write-Host ""
    
    # Storage health
    Write-Log -Message "Storage Health:" -Level "INFO"
    try {
        $pools = Get-StoragePool -CimSession $ClusterName | Where-Object { $_.IsPrimordial -eq $false }
        $vDisks = Get-VirtualDisk -CimSession $ClusterName
        
        $healthyPools = ($pools | Where-Object { $_.HealthStatus -eq "Healthy" }).Count
        $healthyVDisks = ($vDisks | Where-Object { $_.HealthStatus -eq "Healthy" }).Count
        
        if ($healthyPools -eq $pools.Count -and $healthyVDisks -eq $vDisks.Count) {
            Write-Host "  Storage Pools: All healthy ($($pools.Count))" -ForegroundColor Green
            Write-Host "  Virtual Disks: All healthy ($($vDisks.Count))" -ForegroundColor Green
        }
        else {
            Write-Host "  Storage Pools: $healthyPools/$($pools.Count) healthy" -ForegroundColor Yellow
            Write-Host "  Virtual Disks: $healthyVDisks/$($vDisks.Count) healthy" -ForegroundColor Yellow
            $healthReport.OverallHealth = "Warning"
        }
        
        $healthReport.Components.Storage = @{
            PoolsHealthy = $healthyPools
            PoolsTotal = $pools.Count
            VDisksHealthy = $healthyVDisks
            VDisksTotal = $vDisks.Count
        }
    }
    catch {
        Write-Log -Message "  Failed to check storage: $_" -Level "ERROR"
    }
    
    Write-Host ""
    
    # Network health
    Write-Log -Message "Network Health:" -Level "INFO"
    try {
        $networks = Get-ClusterNetwork -Cluster $ClusterName
        $upNetworks = ($networks | Where-Object { $_.State -eq "Up" }).Count
        
        if ($upNetworks -eq $networks.Count) {
            Write-Host "  Cluster Networks: All up ($($networks.Count))" -ForegroundColor Green
        }
        else {
            Write-Host "  Cluster Networks: $upNetworks/$($networks.Count) up" -ForegroundColor Yellow
            $healthReport.OverallHealth = "Warning"
        }
        
        $healthReport.Components.Network = @{
            NetworksUp = $upNetworks
            NetworksTotal = $networks.Count
        }
    }
    catch {
        Write-Log -Message "  Failed to check networks: $_" -Level "ERROR"
    }
    
    Write-Host ""
    
    # Arc status
    Write-Log -Message "Azure Arc Status:" -Level "INFO"
    try {
        $node = ($nodes | Where-Object { $_.State -eq "Up" } | Select-Object -First 1).Name
        $arcStatus = Invoke-Command -ComputerName $node -ScriptBlock {
            $agent = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            if (Test-Path $agent) {
                $status = & $agent show --json 2>&1 | ConvertFrom-Json
                return $status.status
            }
            return "Not Installed"
        }
        
        if ($arcStatus -eq "Connected") {
            Write-Host "  Arc Agent: Connected" -ForegroundColor Green
        }
        else {
            Write-Host "  Arc Agent: $arcStatus" -ForegroundColor Yellow
            $healthReport.OverallHealth = "Warning"
        }
        
        $healthReport.Components.Arc = @{
            Status = $arcStatus
        }
    }
    catch {
        Write-Log -Message "  Failed to check Arc: $_" -Level "ERROR"
    }
    
    Write-Host ""
    Write-Log -Message "Overall Health: $($healthReport.OverallHealth)" -Level $(if ($healthReport.OverallHealth -eq "Healthy") { "SUCCESS" } else { "WARN" })
    
    # Save report if requested
    if ($OutputPath) {
        $reportPath = Join-Path $OutputPath "health-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $healthReport | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath
        Write-Log -Message "Report saved: $reportPath" -Level "INFO"
    }
}

function Set-MaintenanceMode {
    if (-not $NodeName) {
        Write-Log -Message "NodeName parameter required" -Level "ERROR"
        return
    }
    
    if ($Enable) {
        Write-Log -Message "Entering maintenance mode for $NodeName..." -Level "INFO"
        
        try {
            # Drain roles from node
            Write-Log -Message "  Draining cluster roles..." -Level "INFO"
            Suspend-ClusterNode -Name $NodeName -Cluster $ClusterName -Drain -Wait -ErrorAction Stop
            
            # Pause storage repair
            Write-Log -Message "  Pausing storage repair jobs..." -Level "INFO"
            Invoke-Command -ComputerName $NodeName -ScriptBlock {
                Get-StorageSubSystem -FriendlyName "Clustered*" | Set-StorageHealthSetting -Name "System.Storage.PhysicalDisk.AutoReplace.Enabled" -Value "False"
            } -ErrorAction SilentlyContinue
            
            Write-Log -Message "Node $NodeName is now in maintenance mode" -Level "SUCCESS"
            Write-Log -Message "  - VMs have been live migrated to other nodes" -Level "INFO"
            Write-Log -Message "  - Storage repair is paused" -Level "INFO"
            Write-Log -Message "  - Node can be safely updated/rebooted" -Level "INFO"
        }
        catch {
            Write-Log -Message "Failed to enter maintenance mode: $_" -Level "ERROR"
        }
    }
    else {
        Write-Log -Message "Exiting maintenance mode for $NodeName..." -Level "INFO"
        
        try {
            # Resume node
            Write-Log -Message "  Resuming cluster node..." -Level "INFO"
            Resume-ClusterNode -Name $NodeName -Cluster $ClusterName -Failback Immediate -ErrorAction Stop
            
            # Re-enable storage repair
            Write-Log -Message "  Enabling storage repair..." -Level "INFO"
            Invoke-Command -ComputerName $NodeName -ScriptBlock {
                Get-StorageSubSystem -FriendlyName "Clustered*" | Set-StorageHealthSetting -Name "System.Storage.PhysicalDisk.AutoReplace.Enabled" -Value "True"
            } -ErrorAction SilentlyContinue
            
            Write-Log -Message "Node $NodeName has exited maintenance mode" -Level "SUCCESS"
        }
        catch {
            Write-Log -Message "Failed to exit maintenance mode: $_" -Level "ERROR"
        }
    }
}

function Invoke-LiveMigration {
    if (-not $NodeName) {
        Write-Log -Message "Draining all VMs from all nodes is not supported. Specify a NodeName." -Level "ERROR"
        return
    }
    
    Write-Log -Message "Live migrating VMs from $NodeName..." -Level "INFO"
    
    try {
        $vms = Get-VM -ComputerName $NodeName
        
        if ($vms.Count -eq 0) {
            Write-Log -Message "No VMs on $NodeName" -Level "INFO"
            return
        }
        
        Write-Log -Message "  Found $($vms.Count) VM(s) to migrate" -Level "INFO"
        
        # Get available target nodes
        $targetNodes = Get-ClusterNode -Cluster $ClusterName | 
                       Where-Object { $_.State -eq "Up" -and $_.Name -ne $NodeName }
        
        if ($targetNodes.Count -eq 0) {
            Write-Log -Message "No available target nodes" -Level "ERROR"
            return
        }
        
        foreach ($vm in $vms) {
            # Select target with least VMs
            $targetNode = $targetNodes | ForEach-Object {
                $node = $_
                $vmCount = (Get-VM -ComputerName $node.Name).Count
                [PSCustomObject]@{ Name = $node.Name; VMCount = $vmCount }
            } | Sort-Object VMCount | Select-Object -First 1
            
            Write-Log -Message "  Migrating $($vm.Name) to $($targetNode.Name)..." -Level "INFO"
            
            Move-VM -Name $vm.Name -ComputerName $NodeName -DestinationHost $targetNode.Name -ErrorAction Stop
            
            Write-Log -Message "    Migration complete" -Level "SUCCESS"
        }
        
        Write-Log -Message "All VMs migrated from $NodeName" -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Live migration failed: $_" -Level "ERROR"
    }
}

function Invoke-StorageRebalance {
    Write-Log -Message "Rebalancing storage across cluster..." -Level "INFO"
    
    try {
        # Get CSV ownership
        $csvs = Get-ClusterSharedVolume -Cluster $ClusterName
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        # Count CSVs per node
        $ownershipCount = @{}
        foreach ($node in $nodes) {
            $ownershipCount[$node.Name] = ($csvs | Where-Object { $_.OwnerNode.Name -eq $node.Name }).Count
        }
        
        Write-Log -Message "Current CSV ownership:" -Level "INFO"
        foreach ($kv in $ownershipCount.GetEnumerator()) {
            Write-Host "  $($kv.Key): $($kv.Value) CSV(s)"
        }
        
        # Calculate ideal distribution
        $idealCount = [math]::Ceiling($csvs.Count / $nodes.Count)
        
        Write-Host ""
        Write-Log -Message "Ideal distribution: ~$idealCount CSVs per node" -Level "INFO"
        
        # Identify imbalance
        $overloaded = $ownershipCount.GetEnumerator() | Where-Object { $_.Value -gt ($idealCount + 1) }
        $underloaded = $ownershipCount.GetEnumerator() | Where-Object { $_.Value -lt ($idealCount - 1) }
        
        if ($overloaded.Count -eq 0) {
            Write-Log -Message "Storage ownership is balanced" -Level "SUCCESS"
            return
        }
        
        Write-Log -Message "Rebalancing needed..." -Level "INFO"
        
        # Move CSVs from overloaded to underloaded
        foreach ($over in $overloaded) {
            $csvsToMove = $csvs | Where-Object { $_.OwnerNode.Name -eq $over.Key } | 
                          Select-Object -First ($over.Value - $idealCount)
            
            foreach ($csv in $csvsToMove) {
                $target = ($underloaded | Sort-Object Value | Select-Object -First 1).Key
                
                if ($target) {
                    Write-Log -Message "  Moving $($csv.Name) from $($over.Key) to $target" -Level "INFO"
                    Move-ClusterSharedVolume -Name $csv.Name -Node $target -ErrorAction SilentlyContinue
                }
            }
        }
        
        Write-Log -Message "Storage rebalance complete" -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Storage rebalance failed: $_" -Level "ERROR"
    }
}

function Get-CapacityReport {
    Write-Log -Message "Generating capacity report..." -Level "INFO"
    Write-Host ""
    
    try {
        # Storage capacity
        Write-Log -Message "Storage Capacity:" -Level "INFO"
        $pools = Get-StoragePool -CimSession $ClusterName | Where-Object { $_.IsPrimordial -eq $false }
        
        foreach ($pool in $pools) {
            $usedTB = [math]::Round($pool.AllocatedSize / 1TB, 2)
            $totalTB = [math]::Round($pool.Size / 1TB, 2)
            $freeTB = [math]::Round(($pool.Size - $pool.AllocatedSize) / 1TB, 2)
            $usedPct = [math]::Round(($pool.AllocatedSize / $pool.Size) * 100, 1)
            
            $color = if ($usedPct -gt 85) { "Red" } elseif ($usedPct -gt 70) { "Yellow" } else { "Green" }
            
            Write-Host "  $($pool.FriendlyName):" -ForegroundColor Cyan
            Write-Host "    Used: $usedTB TB / $totalTB TB ($usedPct%)" -ForegroundColor $color
            Write-Host "    Free: $freeTB TB"
        }
        
        Write-Host ""
        
        # Compute capacity
        Write-Log -Message "Compute Capacity:" -Level "INFO"
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $vmInfo = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                $vms = Get-VM
                $totalMemGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1)
                $usedMemGB = [math]::Round(($vms | Measure-Object -Property MemoryAssigned -Sum).Sum / 1GB, 1)
                $cpuCount = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
                $usedCPU = ($vms | Measure-Object -Property ProcessorCount -Sum).Sum
                
                @{
                    VMCount = $vms.Count
                    TotalMemGB = $totalMemGB
                    UsedMemGB = $usedMemGB
                    TotalCPU = $cpuCount
                    UsedCPU = $usedCPU
                }
            }
            
            $memPct = [math]::Round(($vmInfo.UsedMemGB / $vmInfo.TotalMemGB) * 100, 1)
            $cpuPct = [math]::Round(($vmInfo.UsedCPU / $vmInfo.TotalCPU) * 100, 1)
            
            Write-Host "  $($node.Name): $($vmInfo.VMCount) VMs" -ForegroundColor Cyan
            Write-Host "    Memory: $($vmInfo.UsedMemGB) GB / $($vmInfo.TotalMemGB) GB ($memPct%)"
            Write-Host "    vCPU: $($vmInfo.UsedCPU) / $($vmInfo.TotalCPU) ($cpuPct%)"
        }
    }
    catch {
        Write-Log -Message "Capacity report failed: $_" -Level "ERROR"
    }
}

function Get-ClusterAlerts {
    Write-Log -Message "Checking for cluster alerts..." -Level "INFO"
    Write-Host ""
    
    try {
        # Check storage health actions
        Write-Log -Message "Storage Alerts:" -Level "INFO"
        $healthActions = Get-StorageHealthAction -CimSession $ClusterName -ErrorAction SilentlyContinue
        
        if ($healthActions) {
            foreach ($action in $healthActions) {
                Write-Host "  [$($action.ActionState)] $($action.DeviceDescription): $($action.Reason)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  No storage health alerts" -ForegroundColor Green
        }
        
        Write-Host ""
        
        # Check cluster events (last 24 hours, critical/warning)
        Write-Log -Message "Recent Cluster Events (Critical/Warning):" -Level "INFO"
        $startTime = (Get-Date).AddHours(-24)
        
        $events = Get-WinEvent -ComputerName ($nodes | Select-Object -First 1).Name -FilterHashtable @{
            LogName = 'Microsoft-Windows-FailoverClustering/Operational'
            Level = 1,2,3  # Critical, Error, Warning
            StartTime = $startTime
        } -MaxEvents 20 -ErrorAction SilentlyContinue
        
        if ($events) {
            foreach ($event in $events) {
                $level = switch ($event.Level) { 1 { "CRITICAL" }; 2 { "ERROR" }; 3 { "WARNING" } }
                $color = switch ($event.Level) { 1 { "Red" }; 2 { "Red" }; 3 { "Yellow" } }
                Write-Host "  [$($event.TimeCreated.ToString('MM-dd HH:mm'))] [$level] $($event.Message.Substring(0, [Math]::Min(80, $event.Message.Length)))..." -ForegroundColor $color
            }
        }
        else {
            Write-Host "  No critical/warning events in last 24 hours" -ForegroundColor Green
        }
    }
    catch {
        Write-Log -Message "Failed to get alerts: $_" -Level "ERROR"
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Cluster Operations Management" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "Action: $Action" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    switch ($Action) {
        "HealthCheck" {
            Invoke-HealthCheck
        }
        "MaintenanceMode" {
            Set-MaintenanceMode
        }
        "LiveMigrate" {
            Invoke-LiveMigration
        }
        "Rebalance" {
            Invoke-StorageRebalance
        }
        "Capacity" {
            Get-CapacityReport
        }
        "Alerts" {
            Get-ClusterAlerts
        }
    }
    
    Write-Host ""
    Write-Log -Message "Operation complete" -Level "SUCCESS"
}
catch {
    Write-Log -Message "Operation failed: $_" -Level "ERROR"
    exit 1
}
