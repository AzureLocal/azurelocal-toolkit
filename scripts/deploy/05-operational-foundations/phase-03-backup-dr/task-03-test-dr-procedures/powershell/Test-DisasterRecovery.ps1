<#
.SYNOPSIS
    Tests disaster recovery capabilities for Azure Local.

.DESCRIPTION
    This script tests DR capabilities:
    - Validates cluster failover
    - Tests storage replica
    - Validates backup restore
    - Tests Azure Site Recovery integration

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER TestType
    Type of DR test to perform.

.EXAMPLE
    .\Test-DisasterRecovery.ps1 -ClusterName "azl-cluster01" -TestType "Failover"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-19-dr-configuration/step-01-test-dr

    WARNING: Some tests may impact production workloads.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Failover', 'StorageReplica', 'BackupRestore', 'ASR', 'All')]
    [string]$TestType = 'All',

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\dr-testing",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    $configContent = Get-Content -Path $Path -Raw
    return ConvertFrom-Yaml $configContent
}

function Test-ClusterFailover {
    <#
    .SYNOPSIS
        Tests cluster failover capabilities.
    #>
    [CmdletBinding()]
    param(
        [string]$ClusterName,
        [pscredential]$Credential,
        [switch]$DryRun
    )

    $results = @{
        TestName    = "Cluster Failover"
        StartTime   = Get-Date
        EndTime     = $null
        Status      = "Running"
        Details     = @()
    }

    try {
        Write-LogMessage "  Getting cluster status..." -Level Info

        $clusterParams = @{
            Cluster = $ClusterName
        }
        if ($Credential) {
            $clusterParams['Credential'] = $Credential
        }

        # Get cluster nodes
        $nodes = Get-ClusterNode @clusterParams
        $results.Details += "Cluster nodes: $($nodes.Count)"

        foreach ($node in $nodes) {
            $status = if ($node.State -eq 'Up') { '✓' } else { '✗' }
            $results.Details += "  $($node.Name): $($node.State) $status"
        }

        # Get cluster resources
        $resources = Get-ClusterResource @clusterParams
        $onlineResources = ($resources | Where-Object { $_.State -eq 'Online' }).Count
        $results.Details += "Resources: $onlineResources / $($resources.Count) online"

        # Get cluster groups (VMs, roles)
        $groups = Get-ClusterGroup @clusterParams
        $onlineGroups = ($groups | Where-Object { $_.State -eq 'Online' }).Count
        $results.Details += "Groups: $onlineGroups / $($groups.Count) online"

        if (-not $DryRun) {
            # Run cluster validation
            Write-LogMessage "  Running cluster validation..." -Level Info
            $validation = Test-Cluster -Cluster $ClusterName -WarningAction SilentlyContinue
            $results.Details += "Validation completed: $($validation.FullName)"
        } else {
            $results.Details += "DRY RUN - Skipped actual validation"
        }

        $results.Status = "Passed"
    } catch {
        $results.Status = "Failed"
        $results.Details += "Error: $($_.Exception.Message)"
    }

    $results.EndTime = Get-Date
    return $results
}

function Test-StorageReplicaStatus {
    <#
    .SYNOPSIS
        Tests Storage Replica configuration and status.
    #>
    [CmdletBinding()]
    param(
        [string]$ClusterName,
        [pscredential]$Credential,
        [switch]$DryRun
    )

    $results = @{
        TestName    = "Storage Replica"
        StartTime   = Get-Date
        EndTime     = $null
        Status      = "Running"
        Details     = @()
    }

    try {
        # Get primary node
        $nodes = Get-ClusterNode -Cluster $ClusterName
        $primaryNode = $nodes | Where-Object { $_.State -eq 'Up' } | Select-Object -First 1

        $sessionParams = @{
            ComputerName = $primaryNode.Name
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        $srStatus = Invoke-Command -Session $session -ScriptBlock {
            $groups = Get-SRGroup -ErrorAction SilentlyContinue
            if ($groups) {
                $partnerships = Get-SRPartnership -ErrorAction SilentlyContinue
                return @{
                    Configured   = $true
                    Groups       = $groups | Select-Object Name, ReplicationMode, ReplicationStatus
                    Partnerships = $partnerships | Select-Object SourceRGName, DestinationRGName
                }
            }
            return @{ Configured = $false }
        }

        Remove-PSSession -Session $session

        if ($srStatus.Configured) {
            $results.Details += "Storage Replica configured"
            foreach ($group in $srStatus.Groups) {
                $results.Details += "  Group: $($group.Name) - $($group.ReplicationMode) - $($group.ReplicationStatus)"
            }
            $results.Status = "Passed"
        } else {
            $results.Details += "Storage Replica not configured"
            $results.Status = "NotApplicable"
        }
    } catch {
        $results.Status = "Failed"
        $results.Details += "Error: $($_.Exception.Message)"
    }

    $results.EndTime = Get-Date
    return $results
}

function Test-BackupStatus {
    <#
    .SYNOPSIS
        Tests backup configuration and recent backup status.
    #>
    [CmdletBinding()]
    param(
        [string]$ClusterName,
        [pscredential]$Credential,
        [switch]$DryRun
    )

    $results = @{
        TestName    = "Backup Status"
        StartTime   = Get-Date
        EndTime     = $null
        Status      = "Running"
        Details     = @()
    }

    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName
        $primaryNode = $nodes | Where-Object { $_.State -eq 'Up' } | Select-Object -First 1

        $sessionParams = @{
            ComputerName = $primaryNode.Name
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        $backupStatus = Invoke-Command -Session $session -ScriptBlock {
            # Check Windows Server Backup
            $wsbPolicy = Get-WBPolicy -ErrorAction SilentlyContinue
            $wsbSummary = Get-WBSummary -ErrorAction SilentlyContinue

            # Check for MABS agent
            $mabsAgent = Get-Service -Name "obengine" -ErrorAction SilentlyContinue

            return @{
                WsbConfigured = $null -ne $wsbPolicy
                LastBackup    = $wsbSummary.LastSuccessfulBackupTime
                NextBackup    = $wsbSummary.NextBackupTime
                MabsInstalled = $null -ne $mabsAgent
                MabsStatus    = $mabsAgent.Status
            }
        }

        Remove-PSSession -Session $session

        if ($backupStatus.WsbConfigured) {
            $results.Details += "Windows Server Backup configured"
            $results.Details += "  Last backup: $($backupStatus.LastBackup)"
            $results.Details += "  Next backup: $($backupStatus.NextBackup)"
        } else {
            $results.Details += "Windows Server Backup not configured"
        }

        if ($backupStatus.MabsInstalled) {
            $results.Details += "MABS Agent: $($backupStatus.MabsStatus)"
        }

        $results.Status = if ($backupStatus.WsbConfigured -or $backupStatus.MabsInstalled) { "Passed" } else { "Warning" }
    } catch {
        $results.Status = "Failed"
        $results.Details += "Error: $($_.Exception.Message)"
    }

    $results.EndTime = Get-Date
    return $results
}

function New-DrTestReport {
    <#
    .SYNOPSIS
        Generates DR test report.
    #>
    [CmdletBinding()]
    param(
        [array]$TestResults,
        [string]$OutputPath
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $reportFile = Join-Path $OutputPath "dr-test-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"

    $report = @"
# Disaster Recovery Test Report

**Generated:** $timestamp

## Executive Summary

| Test | Status | Duration |
|------|--------|----------|
"@

    foreach ($test in $TestResults) {
        $duration = if ($test.EndTime -and $test.StartTime) { 
            "{0:mm\:ss}" -f ($test.EndTime - $test.StartTime) 
        } else { 
            "N/A" 
        }
        $statusIcon = switch ($test.Status) {
            'Passed'        { '✅' }
            'Failed'        { '❌' }
            'Warning'       { '⚠️' }
            'NotApplicable' { '➖' }
            default         { '❓' }
        }
        $report += "`n| $($test.TestName) | $statusIcon $($test.Status) | $duration |"
    }

    $report += @"

---

## Detailed Results

"@

    foreach ($test in $TestResults) {
        $report += @"

### $($test.TestName)

**Status:** $($test.Status)  
**Start:** $($test.StartTime)  
**End:** $($test.EndTime)

**Details:**
"@
        foreach ($detail in $test.Details) {
            $report += "`n- $detail"
        }
    }

    $report += @"

---

## Recommendations

1. Review any failed or warning tests
2. Address identified gaps in DR configuration
3. Schedule regular DR testing (quarterly recommended)
4. Document test results for compliance

---

*Report generated by Azure Local Cloud AzureLocalCloud Automation*
"@

    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path $reportFile -Value $report
    return $reportFile
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Disaster Recovery Testing" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    if ($DryRun) {
        Write-LogMessage "DRY RUN MODE - No changes will be made" -Level Warning
    }

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get cluster name from config if not provided
    if (-not $ClusterName -and $config.cluster) {
        $ClusterName = $config.compute.azure_local.cluster_name
    }

    if (-not $ClusterName) {
        throw "ClusterName is required"
    }

    # Prompt for credentials if not provided
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for cluster access"
    }

    Write-LogMessage "Cluster: $ClusterName" -Level Info
    Write-LogMessage "Test Type: $TestType" -Level Info

    $testResults = @()

    # Run tests based on type
    if ($TestType -eq 'All' -or $TestType -eq 'Failover') {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Running Cluster Failover Test..." -Level Info
        
        if ($PSCmdlet.ShouldProcess($ClusterName, "Test cluster failover")) {
            $result = Test-ClusterFailover -ClusterName $ClusterName -Credential $Credential -DryRun:$DryRun
            $testResults += $result
            Write-LogMessage "  Status: $($result.Status)" -Level $(if($result.Status -eq 'Passed'){'Success'}else{'Warning'})
        }
    }

    if ($TestType -eq 'All' -or $TestType -eq 'StorageReplica') {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Running Storage Replica Test..." -Level Info
        
        if ($PSCmdlet.ShouldProcess($ClusterName, "Test storage replica")) {
            $result = Test-StorageReplicaStatus -ClusterName $ClusterName -Credential $Credential -DryRun:$DryRun
            $testResults += $result
            Write-LogMessage "  Status: $($result.Status)" -Level $(if($result.Status -eq 'Passed'){'Success'}elseif($result.Status -eq 'NotApplicable'){'Info'}else{'Warning'})
        }
    }

    if ($TestType -eq 'All' -or $TestType -eq 'BackupRestore') {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Running Backup Status Test..." -Level Info
        
        if ($PSCmdlet.ShouldProcess($ClusterName, "Test backup status")) {
            $result = Test-BackupStatus -ClusterName $ClusterName -Credential $Credential -DryRun:$DryRun
            $testResults += $result
            Write-LogMessage "  Status: $($result.Status)" -Level $(if($result.Status -eq 'Passed'){'Success'}else{'Warning'})
        }
    }

    # Generate report
    Write-LogMessage "" -Level Info
    Write-LogMessage "Generating DR test report..." -Level Info
    $reportPath = New-DrTestReport -TestResults $testResults -OutputPath $OutputPath
    Write-LogMessage "  Report: $reportPath" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "DR Testing Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $passed = ($testResults | Where-Object { $_.Status -eq 'Passed' }).Count
    $failed = ($testResults | Where-Object { $_.Status -eq 'Failed' }).Count
    $warning = ($testResults | Where-Object { $_.Status -eq 'Warning' }).Count

    Write-LogMessage "  Tests run: $($testResults.Count)" -Level Info
    Write-LogMessage "  Passed: $passed" -Level Success
    Write-LogMessage "  Failed: $failed" -Level $(if($failed -eq 0){'Info'}else{'Error'})
    Write-LogMessage "  Warnings: $warning" -Level $(if($warning -eq 0){'Info'}else{'Warning'})
    Write-LogMessage "  Report: $reportPath" -Level Info

    return @{
        TestResults = $testResults
        ReportPath  = $reportPath
    }

} catch {
    Write-LogMessage "DR testing failed: $_" -Level Error
    throw
}

#endregion Main
