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

    It creates a Collect volume and a fleet of VMs on the cluster and removes the fleet when the runs are done. Use -WhatIf to see the plan first.
    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): cluster.name, storage.pool.name.
    The script does not sign in and never prompts: the administrator account of the fleet VMs is the parameter -FleetAdminCredential, which
    the caller passes (for example built from a secret with scripts/common/secrets/AzlSecret.psm1).

    Exit codes: 0 the runs finished (or the plan is shown under -WhatIf); 1 a run failed; 2 cluster.name is missing, the file cannot be read, or
    -FleetAdminCredential is missing.

.PARAMETER VmCount
    Number of VMs per node to deploy. Default: 4.

.PARAMETER DurationSeconds
    Duration of each test run in seconds. Default: 300.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). The script reads cluster.name and storage.pool.name (the pool of the Collect volume; without it the one
    pool of the cluster is used). Only these keys are read; the whole file is not validated here.

.PARAMETER CollectVolumeSizeGiB
    Size of the Collect volume VMFleet writes its results to, in GiB. Default: 50.

.PARAMETER VmFleetModuleVersion
    Optional. The version of the VMFleet module to install when it is missing. Without it the latest version is installed.

.PARAMETER FleetAdminCredential
    The administrator account of the fleet VMs (VMFleet -AdminPass). Required unless -WhatIf. The script never prompts for it.

.PARAMETER OutputPath
    Path to save performance reports. Default: .\logs\validation-reports\

.EXAMPLE
    .\Invoke-VmFleetStorageTest.ps1 -InfrastructureFile ./infrastructure.yml -FleetAdminCredential $fleetCredential -VmCount 4 -DurationSeconds 300

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-02-vmfleet-storage-testing
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [int]$VmCount = 4,

    [Parameter(Mandatory = $false)]
    [int]$DurationSeconds = 300,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports",

    [Parameter(Mandatory = $false)]
    [int]$CollectVolumeSizeGiB = 50,

    [Parameter(Mandatory = $false)]
    [string]$VmFleetModuleVersion,

    [Parameter(Mandatory = $false)]
    [pscredential]$FleetAdminCredential
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
$StoragePoolName = $null   # from storage.pool.name

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

#region Functions

function Install-VMFleetModule {
    Write-Log "Checking VMFleet module..." -Level "INFO"

    $installed = Get-Module -Name VMFleet -ListAvailable
    if (-not $installed) {
        if ($PSCmdlet.ShouldProcess("VMFleet", "Install module")) {
            $installArguments = @{ Name = 'VMFleet'; Force = $true; Scope = 'CurrentUser' }
            if ($VmFleetModuleVersion) { $installArguments.RequiredVersion = $VmFleetModuleVersion }
            Install-Module @installArguments
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
        $poolName = $StoragePoolName
        if (-not $poolName) {
            $pools = @(Get-StoragePool -CimSession $ClusterName | Where-Object IsPrimordial -eq $false)
            if ($pools.Count -ne 1) { throw "The cluster has $($pools.Count) storage pools. Set storage.pool.name in the infrastructure file." }
            $poolName = $pools[0].FriendlyName
        }
        New-Volume -CimSession $ClusterName -FriendlyName "Collect" -Size ($CollectVolumeSizeGiB * 1GB) -StoragePoolFriendlyName $poolName -FileSystem CSVFS_ReFS
        Write-Log "  Collect volume created" -Level "SUCCESS"
    }

    # Initialize VMFleet
    $nodes = @((Get-ClusterNode -Cluster $ClusterName).Name)
    Write-Log "  Setting up VMFleet for $($nodes.Count) nodes, $VmCount VMs each..." -Level "INFO"

    Set-Fleet -Cluster $ClusterName -VMs $VmCount -AdminPass $(if ($FleetAdminCredential) { $FleetAdminCredential.Password }) -ConnectUser $env:USERNAME
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

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Log "Cannot read the infrastructure file: $($_.Exception.Message)" -Level "ERROR"; exit 2 }
$ClusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
$poolFromFile = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'storage.pool.name')).Trim()   # storage.pool.name
if ($poolFromFile) { $StoragePoolName = $poolFromFile }
if (-not $ClusterName) {
    Write-Log "cluster.name is missing in the infrastructure file. It is the name of the cluster to test." -Level "ERROR"
    exit 2
}

if (-not $FleetAdminCredential -and -not $WhatIfPreference) {
    # never prompt: the account comes from the caller (for example from a secret through scripts/common/secrets)
    Write-Log '-FleetAdminCredential is required: the administrator account of the fleet VMs. Pass it as a [pscredential]. The script never prompts.' -Level 'ERROR'
    exit 2
}

Write-Log "Cluster: $ClusterName" -Level "INFO"
Write-Log "VMs per node: $VmCount" -Level "INFO"
Write-Log "Test duration: ${DurationSeconds}s per workload" -Level "INFO"
Write-Host ""

# Install and initialize
Install-VMFleetModule
Initialize-VMFleetEnvironment
Write-Host ""

# The three predefined workload profiles (DiskSpd settings of Start-Fleet): a small-block random read, a large-block sequential write and a
# mixed workload, the usual set for a storage baseline. They define this test; they are not a choice of the deployment.
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
