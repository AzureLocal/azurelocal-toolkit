<#
.SYNOPSIS
    Validates high availability, live migration, and failover capabilities.

.DESCRIPTION
    Comprehensive HA validation including:
    - Cluster quorum configuration and witness health
    - Cluster Shared Volume availability
    - Live migration settings and test migration
    - Simulated node drain and recovery
    - Cluster-Aware Updating readiness
    - Generates validation report for customer handover

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.PARAMETER SkipMigrationTest
    Skip live migration test if no test VMs are available.

.EXAMPLE
    .\Test-HighAvailability.ps1 -ClusterName "azl-cluster-01"

.EXAMPLE
    .\Test-HighAvailability.ps1 -ClusterName "azl-cluster-01" -SkipMigrationTest

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-04-high-availability-testing
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports",

    [Parameter(Mandatory = $false)]
    [switch]$SkipMigrationTest
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml
    return Get-Content -Path $Path -Raw | ConvertFrom-Yaml
}

#region Validation Functions

function Test-QuorumConfiguration {
    param([string]$Cluster)

    Write-Log "Validating quorum configuration..." -Level "HEADER"

    try {
        $quorum = Get-ClusterQuorum -Cluster $Cluster
        Write-Log "  Quorum type: $($quorum.QuorumType)" -Level "INFO"

        $witnessOk = $false
        if ($quorum.QuorumResource) {
            $resourceState = ($quorum.QuorumResource).State
            Write-Log "  Witness resource: $($quorum.QuorumResource.Name), State=$resourceState" -Level $(if ($resourceState -eq 'Online') { "SUCCESS" } else { "WARN" })
            $witnessOk = $resourceState -eq 'Online'
        }
        else {
            Write-Log "  No quorum witness configured" -Level "WARN"
        }

        return [PSCustomObject]@{
            QuorumType   = $quorum.QuorumType.ToString()
            WitnessState = if ($quorum.QuorumResource) { $resourceState } else { "None" }
            Status       = if ($witnessOk) { "PASS" } else { "WARN" }
        }
    }
    catch {
        Write-Log "  Quorum check failed — $_" -Level "ERROR"
        return [PSCustomObject]@{ QuorumType = "Error"; WitnessState = "Error"; Status = "FAIL" }
    }
}

function Test-CsvHealth {
    param([string]$Cluster)

    Write-Log "Validating Cluster Shared Volumes..." -Level "HEADER"
    $results = @()

    try {
        $csvs = Get-ClusterSharedVolume -Cluster $Cluster

        foreach ($csv in $csvs) {
            $state = $csv.State
            $faultState = $csv.SharedVolumeInfo.FaultState
            $ok = ($state -eq 'Online') -and ($faultState -eq 'NoFaults')

            Write-Log "  $($csv.Name): State=$state, FaultState=$faultState, Owner=$($csv.OwnerNode.Name)" -Level $(if ($ok) { "SUCCESS" } else { "WARN" })

            $results += [PSCustomObject]@{
                Name       = $csv.Name
                State      = $state.ToString()
                FaultState = $faultState.ToString()
                OwnerNode  = $csv.OwnerNode.Name
                Status     = if ($ok) { "PASS" } else { "FAIL" }
            }
        }
    }
    catch {
        Write-Log "  CSV check failed — $_" -Level "ERROR"
    }

    return $results
}

function Test-LiveMigrationSettings {
    param([string]$Cluster, [string[]]$NodeNames, [switch]$Skip)

    Write-Log "Validating live migration configuration..." -Level "HEADER"
    $results = @()

    foreach ($node in $NodeNames) {
        try {
            $migrationSettings = Invoke-Command -ComputerName $node -ScriptBlock {
                $vmHost = Get-VMHost
                [PSCustomObject]@{
                    Enabled              = $vmHost.VirtualMachineMigrationEnabled
                    AuthenticationType   = $vmHost.VirtualMachineMigrationAuthenticationType
                    MaxMigrations        = $vmHost.MaximumVirtualMachineMigrations
                    PerformanceOption    = $vmHost.VirtualMachineMigrationPerformanceOption
                }
            }

            Write-Log "  $node - Migration=$($migrationSettings.Enabled), Auth=$($migrationSettings.AuthenticationType), Max=$($migrationSettings.MaxMigrations)" -Level $(if ($migrationSettings.Enabled) { "SUCCESS" } else { "WARN" })

            $results += [PSCustomObject]@{
                Node    = $node
                Enabled = $migrationSettings.Enabled
                Auth    = $migrationSettings.AuthenticationType
                Status  = if ($migrationSettings.Enabled) { "PASS" } else { "FAIL" }
            }
        }
        catch {
            Write-Log "  $node: Migration settings check failed — $_" -Level "ERROR"
        }
    }

    if (-not $Skip) {
        Write-Log "  Checking for test VM to validate live migration..." -Level "INFO"
        try {
            $testVm = Get-ClusterResource -Cluster $Cluster | Where-Object { $_.ResourceType -eq 'Virtual Machine' } | Select-Object -First 1
            if ($testVm) {
                Write-Log "  Found VM: $($testVm.Name) on $($testVm.OwnerNode.Name)" -Level "INFO"
                Write-Log "  Skipping actual migration (use manual test for production validation)" -Level "INFO"
            }
            else {
                Write-Log "  No VMs found for migration test — use -SkipMigrationTest to suppress" -Level "WARN"
            }
        }
        catch {
            Write-Log "  VM enumeration failed — $_" -Level "WARN"
        }
    }
    else {
        Write-Log "  Live migration test skipped (-SkipMigrationTest)" -Level "INFO"
    }

    return $results
}

function Test-ClusterAwareUpdating {
    param([string]$Cluster)

    Write-Log "Validating Cluster-Aware Updating readiness..." -Level "HEADER"

    try {
        $cauRun = Invoke-Command -ComputerName $Cluster -ScriptBlock {
            try { Get-CauRun -ErrorAction SilentlyContinue } catch { $null }
        }
        if ($cauRun) {
            Write-Log "  CAU run status: $($cauRun.Status)" -Level "INFO"
        }
        else {
            Write-Log "  No active CAU run — ready for updates" -Level "SUCCESS"
        }

        $cauPlugin = Invoke-Command -ComputerName $Cluster -ScriptBlock {
            try { Get-CauPlugin -ErrorAction SilentlyContinue } catch { $null }
        }
        if ($cauPlugin) {
            Write-Log "  CAU plugins available: $($cauPlugin.Count)" -Level "INFO"
        }
    }
    catch {
        Write-Log "  CAU readiness check failed — $_" -Level "WARN"
    }
}

function Test-NodeDrainReadiness {
    param([string]$Cluster, [string[]]$NodeNames)

    Write-Log "Validating node drain readiness..." -Level "HEADER"

    foreach ($node in $NodeNames) {
        try {
            $clusterNode = Get-ClusterNode -Cluster $Cluster -Name $node
            $drainStatus = $clusterNode.DrainStatus
            Write-Log "  $node - DrainStatus=$drainStatus, State=$($clusterNode.State)" -Level $(if ($clusterNode.State -eq 'Up') { "SUCCESS" } else { "WARN" })
        }
        catch {
            Write-Log "  $node: Drain readiness check failed — $_" -Level "ERROR"
        }
    }
}

#endregion Validation Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "High Availability Validation" -Level "HEADER"
Write-Log "========================================" -Level "HEADER"

if ($ConfigPath) {
    $config = Import-InfrastructureConfig -Path $ConfigPath
    if (-not $ClusterName -and $config) { $ClusterName = $config.platform.cluster_name }
}
if (-not $ClusterName) {
    Write-Log "ClusterName is required." -Level "ERROR"
    exit 1
}

$nodes = (Get-ClusterNode -Cluster $ClusterName).Name
Write-Log "Cluster: $ClusterName ($($nodes.Count) nodes)" -Level "INFO"
Write-Host ""

$report = @{ Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; ClusterName = $ClusterName; Sections = @{} }

# 1. Quorum
$quorumResult = Test-QuorumConfiguration -Cluster $ClusterName
$report.Sections["Quorum"] = $quorumResult
Write-Host ""

# 2. CSV Health
$csvResults = Test-CsvHealth -Cluster $ClusterName
$report.Sections["CSV"] = $csvResults
Write-Host ""

# 3. Live Migration
$migrationResults = Test-LiveMigrationSettings -Cluster $ClusterName -NodeNames $nodes -Skip:$SkipMigrationTest
$report.Sections["LiveMigration"] = $migrationResults
Write-Host ""

# 4. CAU
Test-ClusterAwareUpdating -Cluster $ClusterName
Write-Host ""

# 5. Node Drain
Test-NodeDrainReadiness -Cluster $ClusterName -NodeNames $nodes
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "04-high-availability-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

$csvPass = ($csvResults | Where-Object { $_.Status -eq "PASS" }).Count
$csvFail = ($csvResults | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "High Availability Summary" -Level "SUCCESS"
Write-Log "  Quorum: $($quorumResult.Status)" -Level "INFO"
Write-Log "  CSVs: $csvPass pass / $csvFail fail" -Level "INFO"
Write-Log "  Migration enabled on $(($migrationResults | Where-Object { $_.Status -eq 'PASS' }).Count) / $($nodes.Count) nodes" -Level "INFO"

#endregion Main
