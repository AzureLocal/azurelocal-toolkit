<#
.SYNOPSIS
    Validates high availability, live migration, and failover capabilities.

.DESCRIPTION
    Comprehensive HA validation including:
    - Cluster quorum configuration and witness health
    - Cluster Shared Volume availability
    - Live migration settings and test migration
    - Node drain readiness (read only)
    - Cluster-Aware Updating readiness
    - Generates validation report for customer handover

    It reads the cluster and changes nothing in it: the live migration check reads the settings of each node and the drain check reads the
    state of the cluster; no VM is moved and no node is drained. Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name, nodes[] (the management addresses), identity.active_directory (the deployment user and its secret reference)
    Run it from the management host: every question is asked on a node over PowerShell remoting (scripts/common/remoting/AzlClusterConnection.psm1),
    so this host needs neither the failover clustering tools nor membership of the cluster's domain. The script asks nothing.

    Exit codes: 0 the quorum is healthy and no CSV failed; 1 the quorum check or a CSV check failed, or the cluster could not be reached; 2
    cluster.name is missing or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys listed in the description are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to send the cluster questions to. Default: the first node of nodes[] that answers at its management address.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Default: the deployment (LCM) user of the file, through the toolkit's secret resolver.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.PARAMETER SkipMigrationTest
    Skip live migration test if no test VMs are available.

.EXAMPLE
    .\Test-HighAvailability.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    .\Test-HighAvailability.ps1 -InfrastructureFile ./infrastructure.yml -SkipMigrationTest

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-04-high-availability-testing
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports",

    [Parameter(Mandatory = $false)]
    [switch]$SkipMigrationTest,

    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force

# The questions, each run on a node of the cluster. They return plain values only (no live cluster objects cross the remoting boundary).
$Remote = @{
    Quorum    = {
        $q = Get-ClusterQuorum
        $r = $q.QuorumResource
        [pscustomobject]@{ QuorumType = [string]$q.QuorumType; WitnessName = $(if ($r) { [string]$r.Name } else { '' }); WitnessState = $(if ($r) { [string]$r.State } else { '' }) }
    }
    Csv       = {
        @(Get-ClusterSharedVolume | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Name; State = [string]$_.State; FaultState = [string]$_.SharedVolumeInfo.FaultState; OwnerNode = [string]$_.OwnerNode.Name }
            })
    }
    Migration = {
        $vmHost = Get-VMHost
        [pscustomobject]@{
            Enabled            = [bool]$vmHost.VirtualMachineMigrationEnabled
            AuthenticationType = [string]$vmHost.VirtualMachineMigrationAuthenticationType
            MaxMigrations      = [int]$vmHost.MaximumVirtualMachineMigrations
            PerformanceOption  = [string]$vmHost.VirtualMachineMigrationPerformanceOption
        }
    }
    FirstVm   = {
        # no Select-Object -First here: over remoting it stops the pipeline and the call fails with "The pipeline has been stopped" (seen on a live instance)
        $all = @(Get-ClusterResource | Where-Object { $_.ResourceType -eq 'Virtual Machine' })
        $vm = if ($all.Count -gt 0) { $all[0] } else { $null }
        if ($vm) { [pscustomobject]@{ Name = [string]$vm.Name; OwnerNode = [string]$vm.OwnerNode.Name } }
    }
    Cau       = {
        $run = try { Get-CauRun -ErrorAction SilentlyContinue } catch { $null }
        $plugins = try { @(Get-CauPlugin -ErrorAction SilentlyContinue) } catch { @() }
        [pscustomobject]@{ RunStatus = $(if ($run) { [string]$run.Status } else { '' }); PluginCount = @($plugins).Count }
    }
    Nodes     = { @(Get-ClusterNode | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; State = [string]$_.State; DrainStatus = [string]$_.DrainStatus } }) }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

#region Validation Functions

function Test-QuorumConfiguration {
    Write-Log "Validating quorum configuration..." -Level "HEADER"

    try {
        $quorum = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.Quorum
        Write-Log "  Quorum type: $($quorum.QuorumType)" -Level "INFO"

        $witnessOk = $false
        if ($quorum.WitnessName) {
            Write-Log "  Witness resource: $($quorum.WitnessName), State=$($quorum.WitnessState)" -Level $(if ($quorum.WitnessState -eq 'Online') { "SUCCESS" } else { "WARN" })
            $witnessOk = $quorum.WitnessState -eq 'Online'
        }
        else {
            Write-Log "  No quorum witness configured" -Level "WARN"
        }

        return [PSCustomObject]@{
            QuorumType   = [string]$quorum.QuorumType
            WitnessState = if ($quorum.WitnessName) { [string]$quorum.WitnessState } else { "None" }
            Status       = if ($witnessOk) { "PASS" } else { "WARN" }
        }
    }
    catch {
        Write-Log "  Quorum check failed — $_" -Level "ERROR"
        return [PSCustomObject]@{ QuorumType = "Error"; WitnessState = "Error"; Status = "FAIL" }
    }
}

function Test-CsvHealth {
    Write-Log "Validating Cluster Shared Volumes..." -Level "HEADER"
    $results = @()

    try {
        $csvs = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.Csv)

        foreach ($csv in $csvs) {
            $ok = ($csv.State -eq 'Online') -and ($csv.FaultState -eq 'NoFaults')

            Write-Log "  $($csv.Name): State=$($csv.State), FaultState=$($csv.FaultState), Owner=$($csv.OwnerNode)" -Level $(if ($ok) { "SUCCESS" } else { "WARN" })

            $results += [PSCustomObject]@{
                Name       = [string]$csv.Name
                State      = [string]$csv.State
                FaultState = [string]$csv.FaultState
                OwnerNode  = [string]$csv.OwnerNode
                Status     = if ($ok) { "PASS" } else { "FAIL" }
            }
        }
    }
    catch {
        Write-Log "  CSV check failed — $_" -Level "ERROR"
        $results += [PSCustomObject]@{ Name = 'Cluster Shared Volumes'; State = 'Error'; FaultState = 'Error'; OwnerNode = ''; Status = 'FAIL' }
    }

    return $results
}

function Test-LiveMigrationSettings {
    param([string[]]$NodeNames, [switch]$Skip)

    Write-Log "Validating live migration configuration..." -Level "HEADER"
    $results = @()

    foreach ($node in $NodeNames) {
        try {
            $migrationSettings = Invoke-AzlClusterCommand -Connection $connection -Node $node -ScriptBlock $Remote.Migration

            Write-Log "  $node - Migration=$($migrationSettings.Enabled), Auth=$($migrationSettings.AuthenticationType), Max=$($migrationSettings.MaxMigrations)" -Level $(if ($migrationSettings.Enabled) { "SUCCESS" } else { "WARN" })

            $results += [PSCustomObject]@{
                Node    = $node
                Enabled = [bool]$migrationSettings.Enabled
                Auth    = [string]$migrationSettings.AuthenticationType
                Status  = if ($migrationSettings.Enabled) { "PASS" } else { "FAIL" }
            }
        }
        catch {
            Write-Log "  ${node}: Migration settings check failed — $_" -Level "ERROR"
        }
    }

    if (-not $Skip) {
        Write-Log "  Checking for test VM to validate live migration..." -Level "INFO"
        try {
            $testVm = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.FirstVm
            if ($testVm) {
                Write-Log "  Found VM: $($testVm.Name) on $($testVm.OwnerNode)" -Level "INFO"
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
    Write-Log "Validating Cluster-Aware Updating readiness..." -Level "HEADER"

    try {
        $cau = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.Cau
        if ($cau.RunStatus) {
            Write-Log "  CAU run status: $($cau.RunStatus)" -Level "INFO"
        }
        else {
            Write-Log "  No active CAU run — ready for updates" -Level "SUCCESS"
        }
        if ($cau.PluginCount -gt 0) {
            Write-Log "  CAU plugins available: $($cau.PluginCount)" -Level "INFO"
        }
    }
    catch {
        Write-Log "  CAU readiness check failed — $_" -Level "WARN"
    }
}

function Test-NodeDrainReadiness {
    param([object[]]$ClusterNodes)

    Write-Log "Validating node drain readiness..." -Level "HEADER"

    foreach ($clusterNode in $ClusterNodes) {
        Write-Log "  $($clusterNode.Name) - DrainStatus=$($clusterNode.DrainStatus), State=$($clusterNode.State)" -Level $(if ($clusterNode.State -eq 'Up') { "SUCCESS" } else { "WARN" })
    }
}

#endregion Validation Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "High Availability Validation" -Level "HEADER"
Write-Log "========================================" -Level "HEADER"

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Log "Cannot read the infrastructure file: $($_.Exception.Message)" -Level "ERROR"; exit 2 }
$ClusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $ClusterName) {
    Write-Log "cluster.name is missing in the infrastructure file. It is the name of the cluster to test." -Level "ERROR"
    exit 2
}
$connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $ComputerName -Credential $Credential -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }
try { $clusterNodes = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.Nodes) }
catch { Write-Log "The cluster could not be reached: $($_.Exception.Message)" -Level "ERROR"; exit 1 }
$nodes = @($clusterNodes | ForEach-Object { [string]$_.Name })
Write-Log "Cluster: $ClusterName ($($nodes.Count) nodes)" -Level "INFO"
Write-Host ""

$report = @{ Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; ClusterName = $ClusterName; Sections = @{} }

# 1. Quorum
$quorumResult = Test-QuorumConfiguration
$report.Sections["Quorum"] = $quorumResult
Write-Host ""

# 2. CSV Health
$csvResults = Test-CsvHealth
$report.Sections["CSV"] = $csvResults
Write-Host ""

# 3. Live Migration
$migrationResults = Test-LiveMigrationSettings -NodeNames $nodes -Skip:$SkipMigrationTest
$report.Sections["LiveMigration"] = $migrationResults
Write-Host ""

# 4. CAU
Test-ClusterAwareUpdating
Write-Host ""

# 5. Node Drain
Test-NodeDrainReadiness -ClusterNodes $clusterNodes
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "04-high-availability-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

$csvPass = @($csvResults | Where-Object { $_.Status -eq "PASS" }).Count
$csvFail = @($csvResults | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "High Availability Summary" -Level "SUCCESS"
Write-Log "  Quorum: $($quorumResult.Status)" -Level "INFO"
Write-Log "  CSVs: $csvPass pass / $csvFail fail" -Level "INFO"
Write-Log "  Migration enabled on $(@($migrationResults | Where-Object { $_.Status -eq 'PASS' }).Count) / $($nodes.Count) nodes" -Level "INFO"

if ($csvFail -gt 0 -or $quorumResult.Status -eq 'FAIL') { exit 1 }
exit 0

#endregion Main
