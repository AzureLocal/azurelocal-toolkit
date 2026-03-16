<#
.SYNOPSIS
    Manages Windows and Azure Local updates for the cluster.

.DESCRIPTION
    This script provides update management including:
    - Checking for available updates
    - Scheduling update installation
    - Managing Cluster-Aware Updating (CAU)
    - Tracking update compliance
    - Azure Local solution updates

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER Action
    Action to perform: Check, Install, Schedule, Status, History

.PARAMETER UpdateType
    Type of updates: All, Security, Critical, AzureLocal

.PARAMETER MaintenanceWindow
    Scheduled maintenance window (e.g., "Saturday 02:00")

.PARAMETER Force
    Force installation without prompts.

.EXAMPLE
    .\Invoke-ClusterUpdates.ps1 -ClusterName "azl-cluster-01" -Action Check

.EXAMPLE
    .\Invoke-ClusterUpdates.ps1 -ClusterName "azl-cluster-01" -Action Install -UpdateType Security -Force

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires Cluster-Aware Updating feature and appropriate permissions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Check", "Install", "Schedule", "Status", "History")]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [ValidateSet("All", "Security", "Critical", "AzureLocal")]
    [string]$UpdateType = "All",

    [Parameter(Mandatory = $false)]
    [string]$MaintenanceWindow,

    [Parameter(Mandatory = $false)]
    [switch]$Force
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

function Get-AvailableUpdates {
    Write-Log -Message "Checking for available updates..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        $allUpdates = @()
        
        foreach ($node in $nodes) {
            Write-Log -Message "  Scanning node: $($node.Name)" -Level "INFO"
            
            $updates = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                param($type)
                
                # Create update session
                $session = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                
                # Build search criteria
                $criteria = "IsInstalled=0"
                if ($type -eq "Security") {
                    $criteria += " and CategoryIDs contains 'E6CF1350-C01B-414D-A61F-263D14D133B4'"
                }
                elseif ($type -eq "Critical") {
                    $criteria += " and MsrcSeverity='Critical'"
                }
                
                $searchResult = $searcher.Search($criteria)
                
                $searchResult.Updates | ForEach-Object {
                    @{
                        Title = $_.Title
                        KB = if ($_.KBArticleIDs) { "KB$($_.KBArticleIDs[0])" } else { "N/A" }
                        Size = [math]::Round($_.MaxDownloadSize / 1MB, 2)
                        Severity = $_.MsrcSeverity
                        Categories = ($_.Categories | ForEach-Object { $_.Name }) -join ", "
                        RebootRequired = $_.RebootRequired
                    }
                }
            } -ArgumentList $UpdateType -ErrorAction Stop
            
            foreach ($update in $updates) {
                $update.Node = $node.Name
                $allUpdates += $update
            }
        }
        
        if ($allUpdates.Count -eq 0) {
            Write-Log -Message "No updates available" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "Found $($allUpdates.Count) update(s)" -Level "INFO"
            Write-Host ""
            
            # Group by update title
            $grouped = $allUpdates | Group-Object Title
            
            foreach ($group in $grouped) {
                $update = $group.Group[0]
                $nodes = ($group.Group.Node | Select-Object -Unique) -join ", "
                
                $severity = if ($update.Severity) { $update.Severity } else { "N/A" }
                $reboot = if ($update.RebootRequired) { "Yes" } else { "No" }
                
                Write-Host "  $($update.Title)" -ForegroundColor Cyan
                Write-Host "    KB: $($update.KB) | Size: $($update.Size) MB | Severity: $severity | Reboot: $reboot"
                Write-Host "    Nodes: $nodes"
                Write-Host ""
            }
        }
        
        return $allUpdates
    }
    catch {
        Write-Log -Message "Failed to check updates: $_" -Level "ERROR"
        throw
    }
}

function Install-ClusterUpdates {
    Write-Log -Message "Installing updates via Cluster-Aware Updating..." -Level "INFO"
    
    if (-not $Force) {
        Write-Host ""
        Write-Log -Message "WARNING: This will update cluster nodes one at a time with possible reboots." -Level "WARN"
        $confirm = Read-Host "Continue? (y/N)"
        if ($confirm -ne "y") {
            Write-Log -Message "Update cancelled by user" -Level "INFO"
            return
        }
    }
    
    try {
        # Check CAU prerequisites
        Write-Log -Message "Validating CAU prerequisites..." -Level "INFO"
        
        $cauReady = Test-CauSetup -ClusterName $ClusterName -ErrorAction Stop
        
        if ($cauReady) {
            Write-Log -Message "  CAU prerequisites: OK" -Level "SUCCESS"
        }
        
        # Configure CAU options
        $cauParams = @{
            ClusterName = $ClusterName
            Force = $true
            EnableFirewallRules = $true
            MaxRetriesPerNode = 3
            RebootTimeoutMinutes = 15
            RequireAllNodesOnline = $true
        }
        
        # Filter by update type if needed
        if ($UpdateType -eq "Security") {
            $cauParams.Add("IncludeRecommendedUpdates", $false)
        }
        
        Write-Log -Message "Starting CAU run..." -Level "INFO"
        Write-Host ""
        
        # Start CAU
        $cauRun = Invoke-CauRun @cauParams -ErrorAction Stop
        
        # Monitor progress
        do {
            Start-Sleep -Seconds 10
            $status = Get-CauRun -ClusterName $ClusterName
            
            if ($status) {
                $phase = $status.RunPhase
                $node = if ($status.CurrentNode) { $status.CurrentNode } else { "N/A" }
                Write-Log -Message "  Phase: $phase | Node: $node" -Level "INFO"
            }
        } while ($status -and $status.RunPhase -ne "Completed" -and $status.RunPhase -ne "Failed")
        
        # Get final report
        $report = Get-CauReport -ClusterName $ClusterName -Last -ErrorAction SilentlyContinue
        
        if ($report -and $report.RunResult -eq "Succeeded") {
            Write-Host ""
            Write-Log -Message "CAU completed successfully" -Level "SUCCESS"
            Write-Log -Message "  Updates installed: $($report.UpdatesInstalledCount)" -Level "INFO"
            Write-Log -Message "  Duration: $($report.Duration)" -Level "INFO"
        }
        elseif ($report) {
            Write-Log -Message "CAU completed with status: $($report.RunResult)" -Level "WARN"
        }
    }
    catch {
        Write-Log -Message "Failed to install updates: $_" -Level "ERROR"
        throw
    }
}

function Set-UpdateSchedule {
    Write-Log -Message "Configuring CAU schedule..." -Level "INFO"
    
    if (-not $MaintenanceWindow) {
        Write-Log -Message "MaintenanceWindow parameter required (e.g., 'Saturday 02:00')" -Level "ERROR"
        return
    }
    
    try {
        # Parse maintenance window
        $parts = $MaintenanceWindow -split " "
        $dayOfWeek = $parts[0]
        $time = $parts[1]
        
        # Create CAU scheduled task
        $cauSchedule = @{
            ClusterName = $ClusterName
            DaysOfWeek = $dayOfWeek
            WeeksInterval = 1
            StartTime = $time
            EnableFirewallRules = $true
            MaxRetriesPerNode = 3
        }
        
        # Enable CAU self-updating role
        Add-CauClusterRole @cauSchedule -Force -ErrorAction Stop
        
        Write-Log -Message "CAU schedule configured: $dayOfWeek at $time" -Level "SUCCESS"
        
        # Display current settings
        $settings = Get-CauClusterRole -ClusterName $ClusterName
        Write-Host ""
        Write-Host "  Days: $($settings.DaysOfWeek)"
        Write-Host "  Time: $($settings.StartTime)"
        Write-Host "  Interval: Every $($settings.WeeksInterval) week(s)"
    }
    catch {
        Write-Log -Message "Failed to configure schedule: $_" -Level "ERROR"
        throw
    }
}

function Get-UpdateStatus {
    Write-Log -Message "Getting current update status..." -Level "INFO"
    
    try {
        # Check for running CAU
        $running = Get-CauRun -ClusterName $ClusterName -ErrorAction SilentlyContinue
        
        if ($running) {
            Write-Host ""
            Write-Host "  CAU Status: Running" -ForegroundColor Yellow
            Write-Host "  Phase: $($running.RunPhase)"
            Write-Host "  Current Node: $($running.CurrentNode)"
            Write-Host "  Started: $($running.StartTime)"
        }
        else {
            Write-Log -Message "  No CAU run in progress" -Level "INFO"
        }
        
        # Get scheduled settings
        $scheduled = Get-CauClusterRole -ClusterName $ClusterName -ErrorAction SilentlyContinue
        
        if ($scheduled) {
            Write-Host ""
            Write-Host "  Scheduled Updates: Enabled" -ForegroundColor Green
            Write-Host "  Schedule: $($scheduled.DaysOfWeek) at $($scheduled.StartTime)"
            Write-Host "  Next Run: $($scheduled.NextScheduledRunTime)"
        }
        else {
            Write-Host ""
            Write-Log -Message "  Scheduled Updates: Not configured" -Level "INFO"
        }
        
        # Get node update status
        Write-Host ""
        Write-Log -Message "Node Compliance:" -Level "INFO"
        
        $nodes = Get-ClusterNode -Cluster $ClusterName
        foreach ($node in $nodes) {
            $lastReboot = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
            } -ErrorAction SilentlyContinue
            
            Write-Host "  $($node.Name): Last Reboot: $($lastReboot)"
        }
    }
    catch {
        Write-Log -Message "Failed to get status: $_" -Level "ERROR"
        throw
    }
}

function Get-UpdateHistory {
    Write-Log -Message "Getting update history..." -Level "INFO"
    
    try {
        $reports = Get-CauReport -ClusterName $ClusterName -Last 10 -ErrorAction SilentlyContinue
        
        if ($reports) {
            Write-Host ""
            Write-Host "  Recent CAU Runs:" -ForegroundColor Cyan
            Write-Host ""
            
            foreach ($report in $reports) {
                $resultColor = if ($report.RunResult -eq "Succeeded") { "Green" } 
                               elseif ($report.RunResult -eq "Failed") { "Red" } 
                               else { "Yellow" }
                
                Write-Host "  [$($report.StartTime.ToString('yyyy-MM-dd HH:mm'))] " -NoNewline
                Write-Host "$($report.RunResult)" -ForegroundColor $resultColor -NoNewline
                Write-Host " - $($report.UpdatesInstalledCount) updates, Duration: $($report.Duration)"
            }
        }
        else {
            Write-Log -Message "No CAU history found" -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "Failed to get history: $_" -Level "ERROR"
        throw
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Cluster Update Management" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "Action: $Action" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    switch ($Action) {
        "Check" {
            Get-AvailableUpdates
        }
        "Install" {
            Install-ClusterUpdates
        }
        "Schedule" {
            Set-UpdateSchedule
        }
        "Status" {
            Get-UpdateStatus
        }
        "History" {
            Get-UpdateHistory
        }
    }
    
    Write-Host ""
    Write-Log -Message "Update management operation complete" -Level "SUCCESS"
}
catch {
    Write-Log -Message "Update management failed: $_" -Level "ERROR"
    exit 1
}
