<#
.SYNOPSIS
    Deploys VMFleet for storage performance testing on Azure Local.

.DESCRIPTION
    This script manages VMFleet storage performance testing:
    - Installs VMFleet module if not present
    - Creates VMFleet storage volume and VM fleet
    - Runs predefined workload profiles (random read, sequential write, mixed)
    - Collects IOPS, throughput, and latency metrics
    - Generates performance baseline report for customer handover

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER VmCount
    Number of VMs per node to deploy. Default: 4.

.PARAMETER DurationSeconds
    Duration of each test run in seconds. Default: 300.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER OutputPath
    Path to save performance reports. Default: .\logs\validation-reports\

.EXAMPLE
    .\Invoke-VmFleetStorageTest.ps1 -ClusterName "azl-cluster-01" -VmCount 4 -DurationSeconds 300

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-02-vmfleet-storage-testing
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [int]$VmCount = 4,

    [Parameter(Mandatory = $false)]
    [int]$DurationSeconds = 300,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports"
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

#region Functions

function Install-VMFleetModule {
    Write-Log "Checking VMFleet module..." -Level "INFO"

    $installed = Get-Module -Name VMFleet -ListAvailable
    if (-not $installed) {
        if ($PSCmdlet.ShouldProcess("VMFleet", "Install module")) {
            Install-Module -Name VMFleet -Force -Scope CurrentUser
            Write-Log "  VMFleet module installed" -Level "SUCCESS"
        }
    }
    else {
        Write-Log "  VMFleet module version $($installed.Version) found" -Level "SUCCESS"
    }
    Import-Module VMFleet
}

function Initialize-VMFleetEnvironment {
    Write-Log "Initializing VMFleet environment..." -Level "HEADER"

    # Create collect volume for VMFleet
    $collectVolume = Get-ClusterSharedVolume -Cluster $ClusterName | Where-Object { $_.Name -match 'Collect' }
    if (-not $collectVolume) {
        Write-Log "  Creating Collect volume for VMFleet..." -Level "INFO"
        New-Volume -CimSession $ClusterName -FriendlyName "Collect" -Size 50GB -StoragePoolFriendlyName "S2D*" -FileSystem CSVFS_ReFS
        Write-Log "  Collect volume created" -Level "SUCCESS"
    }

    # Initialize VMFleet
    $nodes = (Get-ClusterNode -Cluster $ClusterName).Name
    Write-Log "  Setting up VMFleet for $($nodes.Count) nodes, $VmCount VMs each..." -Level "INFO"

    Set-Fleet -Cluster $ClusterName -VMs $VmCount -AdminPass (Read-Host "Enter VM admin password" -AsSecureString) -ConnectUser $env:USERNAME
    Write-Log "  VMFleet initialized with $($nodes.Count * $VmCount) total VMs" -Level "SUCCESS"
}

function Invoke-WorkloadProfile {
    param(
        [string]$ProfileName,
        [string]$Description,
        [hashtable]$DiskSpdParams
    )

    Write-Log "Running workload: $Description..." -Level "HEADER"

    $params = @{
        Cluster  = $ClusterName
        Duration = $DurationSeconds
    }
    $params += $DiskSpdParams

    Start-Fleet @params
    Start-Sleep -Seconds ($DurationSeconds + 10)

    $results = Get-FleetResultLog -Cluster $ClusterName -Last 1

    $summary = [PSCustomObject]@{
        Profile      = $ProfileName
        Description  = $Description
        Duration     = $DurationSeconds
        TotalIOPS    = [math]::Round(($results | Measure-Object -Property IOPS -Sum).Sum, 0)
        AvgLatencyMs = [math]::Round(($results | Measure-Object -Property AvgLatency -Average).Average, 2)
        TotalMBps    = [math]::Round(($results | Measure-Object -Property MBps -Sum).Sum, 2)
    }

    Write-Log "  IOPS: $($summary.TotalIOPS) | Latency: $($summary.AvgLatencyMs)ms | Throughput: $($summary.TotalMBps) MB/s" -Level "SUCCESS"
    return $summary
}

#endregion Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "VMFleet Storage Performance Testing" -Level "HEADER"
Write-Log "========================================" -Level "HEADER"

if ($ConfigPath) {
    $config = Import-InfrastructureConfig -Path $ConfigPath
    if (-not $ClusterName -and $config) { $ClusterName = $config.platform.cluster_name }
}
if (-not $ClusterName) {
    Write-Log "ClusterName is required." -Level "ERROR"
    exit 1
}

Write-Log "Cluster: $ClusterName" -Level "INFO"
Write-Log "VMs per node: $VmCount" -Level "INFO"
Write-Log "Test duration: ${DurationSeconds}s per workload" -Level "INFO"
Write-Host ""

# Install and initialize
Install-VMFleetModule
Initialize-VMFleetEnvironment
Write-Host ""

# Define workload profiles
$workloads = @(
    @{
        ProfileName  = "RandomRead4K"
        Description  = "4K Random Read (100% read, 4K block, random)"
        DiskSpdParams = @{ BlockSize = 4096; RandomPercent = 100; WritePercent = 0; Threads = 2; Outstanding = 16 }
    },
    @{
        ProfileName  = "SequentialWrite256K"
        Description  = "256K Sequential Write (100% write, 256K block, sequential)"
        DiskSpdParams = @{ BlockSize = 262144; RandomPercent = 0; WritePercent = 100; Threads = 2; Outstanding = 8 }
    },
    @{
        ProfileName  = "MixedWorkload"
        Description  = "Mixed Workload (70% read, 8K block, 70% random)"
        DiskSpdParams = @{ BlockSize = 8192; RandomPercent = 70; WritePercent = 30; Threads = 4; Outstanding = 16 }
    }
)

$allResults = @()
foreach ($wl in $workloads) {
    $result = Invoke-WorkloadProfile @wl
    $allResults += $result
    Write-Host ""
}

# Cleanup
Write-Log "Cleaning up VMFleet VMs..." -Level "INFO"
if ($PSCmdlet.ShouldProcess("VMFleet VMs", "Remove test fleet")) {
    Remove-Fleet -Cluster $ClusterName
    Write-Log "  VMFleet VMs removed" -Level "SUCCESS"
}

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "02-vmfleet-storage-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$reportData = @{
    Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ClusterName = $ClusterName
    VmCount     = $VmCount
    Duration    = $DurationSeconds
    Results     = $allResults
}
$reportData | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "VMFleet Storage Performance Summary" -Level "SUCCESS"
foreach ($r in $allResults) {
    Write-Log "  $($r.Profile): $($r.TotalIOPS) IOPS / $($r.AvgLatencyMs)ms / $($r.TotalMBps) MB/s" -Level "INFO"
}

#endregion Main
