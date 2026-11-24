<#
.SYNOPSIS
    Validates Azure Local cluster infrastructure health.

.DESCRIPTION
    Comprehensive infrastructure health validation including:
    - Test-Cluster validation suite
    - Health Service status and faults
    - Arc connectivity verification
    - Storage Spaces Direct health
    - Network connectivity checks
    - Generates validation report for customer handover

    Read only: it changes nothing on the cluster. Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name, nodes[] (the management addresses), identity.active_directory (the deployment user and its secret reference)
    Run it from the management host: every question is asked on a node over PowerShell remoting (scripts/common/remoting/AzlClusterConnection.psm1),
    so this host needs neither the failover clustering tools nor membership of the cluster's domain. The script asks nothing.

    Exit codes: 0 every section is healthy; 1 a node is down, Test-Cluster failed a test, the Health Service reports a fault or the storage is not healthy;
    2 cluster.name is missing or the file cannot be read. The cluster that cannot be reached is exit code 1.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys listed in the description are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to send the cluster questions to. Default: the first node of nodes[] that answers at its management address.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Default: the deployment (LCM) user of the file, through the toolkit's secret resolver.

.PARAMETER TestClusterTimeoutMinutes
    How long to wait for Test-Cluster, which runs as a one-shot scheduled task on the node (see the TestCluster block). Default: 60.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.EXAMPLE
    .\Test-InfrastructureHealth.ps1 -InfrastructureFile ./infrastructure.yml

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-01-infrastructure-health-validation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports",

    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 240)]
    [int]$TestClusterTimeoutMinutes = 60
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

#region Validation Functions

# The questions, each run on a node of the cluster. They return plain values only (no live cluster objects cross the remoting boundary).
$Remote = @{
    # Test-Cluster reaches every node of the cluster. In a remoting session that uses a credential (NTLM to an address) that is a second hop,
    # and the cmdlet fails with "You do not have administrative privileges on the server <node>" (seen on a live instance). So it runs in a
    # one-shot scheduled task on the node, as the account of the session (logon with its password, highest run level), which is a local
    # logon with network access. The task is removed afterwards. Test-Cluster returns the report file and writes one warning per test that
    # warned or failed, and the overall result ("Test Result: ..."); those lines are returned. The password is never written to disk.
    TestCluster = {
        param($Step, [pscredential]$RunAs, [int]$TimeoutMinutes)
        $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = Join-Path $env:SystemRoot "Temp\azl-test-cluster-$id"
        $null = New-Item -ItemType Directory -Path $dir -Force
        $resultFile = Join-Path $dir 'result.json'
        $script = @'
$ErrorActionPreference = 'Stop'
$warnings = @()
$result = @{ Report = ''; Warnings = @(); Error = '' }
try {
    $report = Test-Cluster -Include 'System Configuration', 'Inventory', 'Network', 'Storage' -ReportName (Join-Path $PSScriptRoot 'validation') -WarningVariable warnings -WarningAction SilentlyContinue
    $result.Report = [string]$report.FullName
}
catch { $result.Error = $_.Exception.Message }
$result.Warnings = @($warnings | ForEach-Object { [string]$_ })
# written under another name and renamed, so the reader never sees half a file
$result | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.tmp') -Encoding UTF8
Move-Item -LiteralPath (Join-Path $PSScriptRoot 'result.tmp') -Destination (Join-Path $PSScriptRoot 'result.json') -Force
'@
        Set-Content -LiteralPath (Join-Path $dir 'run.ps1') -Value $script -Encoding UTF8
        $name = "azl-test-cluster-$id"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\run.ps1`""
        $user = $RunAs.UserName
        try {
            $null = Register-ScheduledTask -TaskName $name -Action $action -User $user -Password $RunAs.GetNetworkCredential().Password -RunLevel Highest -Force
            Start-ScheduledTask -TaskName $name
            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            do {
                Start-Sleep -Seconds 10
                if (Test-Path -LiteralPath $resultFile) { break }
                # a task that ended without a result (no batch logon right, a start failure) is reported at once, not after the timeout
                $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                if ($task -and [string]$task.State -eq 'Ready') {
                    $info = Get-ScheduledTaskInfo -TaskName $name
                    if ($info.LastRunTime -gt [datetime]'2000-01-01' -and -not (Test-Path -LiteralPath $resultFile)) { throw "The Test-Cluster task $name ended without a result (last result $($info.LastTaskResult))." }
                }
            } while ((Get-Date) -lt $deadline)
            if (-not (Test-Path -LiteralPath $resultFile)) { throw "Test-Cluster did not finish within $TimeoutMinutes minutes (scheduled task $name)." }
            $answer = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
            [pscustomobject]@{ Report = [string]$answer.Report; Warnings = @($answer.Warnings | ForEach-Object { [string]$_ }); Error = [string]$answer.Error }
        }
        finally {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $dir 'run.ps1'), $resultFile -Force -ErrorAction SilentlyContinue
        }
    }
    Faults      = {
        @(Get-HealthFault -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ FaultType = [string]$_.FaultType; Description = [string]$_.Description; Severity = [string]$_.Severity } })
    }
    Storage     = {
        [pscustomobject]@{
            Pools         = @(Get-StoragePool -IsPrimordial $false -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ FriendlyName = [string]$_.FriendlyName; HealthStatus = [string]$_.HealthStatus; OperationalStatus = [string]$_.OperationalStatus } })
            VirtualDisks  = @(Get-VirtualDisk -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ FriendlyName = [string]$_.FriendlyName; HealthStatus = [string]$_.HealthStatus; ResiliencySettingName = [string]$_.ResiliencySettingName } })
            PhysicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ FriendlyName = [string]$_.FriendlyName; HealthStatus = [string]$_.HealthStatus } })
        }
    }
    Nodes       = { @(Get-ClusterNode | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; State = [string]$_.State } }) }
    ArcAgent    = { & "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe" show 2>&1 | ForEach-Object { [string]$_ } }
}

function Test-ClusterValidation {
    Write-Log "Running Test-Cluster validation suite..." -Level "HEADER"

    $results = @{ Passed = 0; Failed = 0; Warnings = 0; Details = @() }
    try {
        if (-not $connection.Credential) { throw 'Test-Cluster needs the account of the remoting session (the deployment user of the file or -Credential): it runs as a scheduled task on the node with that account.' }
        $answer = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.TestCluster -ArgumentList @('TestCluster', $connection.Credential, $TestClusterTimeoutMinutes)
        if ($answer.Error) { throw $answer.Error }
        if ($answer.Report) { Write-Log "  Report on $($connection.Target): $($answer.Report)" -Level "INFO" }

        # Test-Cluster writes one warning per test that warned or failed ("<category> - <test>: The test reported some warnings.." or "..failed")
        # and the overall result last ("Test Result:" ClusterApproved, ClusterConditionallyApproved or a result with NotApproved/Failed).
        $overall = ''
        foreach ($line in @($answer.Warnings)) {
            $text = ([string]$line).Trim()
            if (-not $text) { continue }
            # one warning record can span lines: 'Test Result:' then the result on the next line, then a sentence and the report path
            if ($text -match '(?s)^Test Result:\s*(.+)$') { $overall = (($Matches[1] -split '\r?\n')[0]).Trim(); continue }
            $status = if ($text -match 'failed') { 'FAIL' } elseif ($text -match 'warning') { 'WARN' } else { 'INFO' }
            $testName = ($text -split ':\s', 2)[0]
            $results.Details += [PSCustomObject]@{ Test = $testName; Status = $status; Detail = $text }
            switch ($status) {
                'WARN' { $results.Warnings++; Write-Log "  WARN: $text" -Level "WARN" }
                'FAIL' { $results.Failed++; Write-Log "  FAIL: $text" -Level "ERROR" }
                default { Write-Log "  $text" -Level "INFO" }
            }
        }
        $results.Overall = $overall
        if ($overall -match 'NotApproved|Fail') {
            if ($results.Failed -eq 0) { $results.Failed++ }
            Write-Log "  Test-Cluster result: $overall" -Level "ERROR"
        }
        elseif ($overall) {
            $results.Passed++
            Write-Log "  Test-Cluster result: $overall" -Level $(if ($results.Warnings -gt 0) { "WARN" } else { "SUCCESS" })
        }
        else { $results.Passed++; Write-Log "  Test-Cluster finished with no warning" -Level "SUCCESS" }
    }
    catch {
        Write-Log "  Test-Cluster failed: $_" -Level "ERROR"
        $results.Failed++
    }
    return $results
}

function Test-HealthServiceStatus {
    Write-Log "Checking Health Service status..." -Level "HEADER"

    $results = @{ Healthy = $true; Faults = @() }
    try {
        $healthService = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.Faults)

        if ($healthService.Count -eq 0) {
            Write-Log "  No health faults detected" -Level "SUCCESS"
        }
        else {
            $results.Healthy = $false
            foreach ($fault in $healthService) {
                $results.Faults += [PSCustomObject]@{
                    FaultType   = $fault.FaultType
                    Description = $fault.Description
                    Severity    = $fault.Severity
                }
                Write-Log "  FAULT: $($fault.FaultType) — $($fault.Description)" -Level "WARN"
            }
        }
    }
    catch {
        Write-Log "  Health Service check failed: $_" -Level "ERROR"
        $results.Healthy = $false
    }
    return $results
}

function Test-StorageHealth {
    Write-Log "Checking Storage Spaces Direct health..." -Level "HEADER"

    $results = @{ Healthy = $true; Details = @() }
    try {
        $storage = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.Storage
        foreach ($p in @($storage.Pools)) {
            $healthy = $p.HealthStatus -eq 'Healthy'
            if (-not $healthy) { $results.Healthy = $false }
            Write-Log "  Pool '$($p.FriendlyName)': $($p.HealthStatus) (Operational: $($p.OperationalStatus))" -Level $(if ($healthy) { "SUCCESS" } else { "ERROR" })
        }

        foreach ($vd in @($storage.VirtualDisks)) {
            $healthy = $vd.HealthStatus -eq 'Healthy'
            if (-not $healthy) { $results.Healthy = $false }
            Write-Log "  VDisk '$($vd.FriendlyName)': $($vd.HealthStatus) ($($vd.ResiliencySettingName))" -Level $(if ($healthy) { "SUCCESS" } else { "WARN" })
        }

        $pDisks = @($storage.PhysicalDisks)
        $unhealthy = @($pDisks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        Write-Log "  Physical disks: $($pDisks.Count) total, $($unhealthy.Count) unhealthy" -Level $(if ($unhealthy.Count -eq 0) { "SUCCESS" } else { "ERROR" })
    }
    catch {
        Write-Log "  Storage health check failed: $_" -Level "ERROR"
        $results.Healthy = $false
    }
    return $results
}

function Test-NodeConnectivity {
    Write-Log "Checking node connectivity..." -Level "HEADER"

    $allUp = $true
    foreach ($node in $script:ClusterNodes) {
        if ($node.State -eq 'Up') {
            Write-Log "  $($node.Name): UP" -Level "SUCCESS"
        }
        else {
            Write-Log "  $($node.Name): $($node.State)" -Level "ERROR"
            $allUp = $false
        }
    }
    return $allUp
}

function Test-ArcConnectivity {
    Write-Log "Checking Azure Arc connectivity..." -Level "HEADER"

    foreach ($node in @($script:ClusterNodes | Where-Object { $_.State -eq 'Up' })) {
        try {
            # each node is asked at its own management address (no second hop)
            $arcAgent = @(Invoke-AzlClusterCommand -Connection $connection -Node $node.Name -ScriptBlock $Remote.ArcAgent)
            $line = @($arcAgent | Select-String "Agent Status") | Select-Object -First 1
            $status = if ($line) { $line.ToString() -replace '.*:\s*', '' } else { 'unknown' }
            $connected = $status -eq 'Connected'
            Write-Log "  $($node.Name): Arc Agent $status" -Level $(if ($connected) { "SUCCESS" } else { "ERROR" })
        }
        catch {
            Write-Log "  $($node.Name): Arc connectivity check failed: $_" -Level "ERROR"
        }
    }
}

#endregion Validation Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "Infrastructure Health Validation" -Level "HEADER"
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
try { $script:ClusterNodes = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $Remote.Nodes) }
catch { Write-Log "The cluster could not be reached: $($_.Exception.Message)" -Level "ERROR"; exit 1 }
Write-Log "Cluster: $ClusterName" -Level "INFO"
Write-Host ""

$report = @{
    Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ClusterName     = $ClusterName
    Sections        = @{}
}

# 1. Node connectivity
$nodesUp = Test-NodeConnectivity
$report.Sections["NodeConnectivity"] = @{ AllUp = $nodesUp }
Write-Host ""

# 2. Test-Cluster suite
$clusterResults = Test-ClusterValidation
$report.Sections["TestCluster"] = $clusterResults
Write-Host ""

# 3. Health Service
$healthResults = Test-HealthServiceStatus
$report.Sections["HealthService"] = $healthResults
Write-Host ""

# 4. Storage health
$storageResults = Test-StorageHealth
$report.Sections["Storage"] = $storageResults
Write-Host ""

# 5. Arc connectivity
Test-ArcConnectivity
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "01-infrastructure-health-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "Infrastructure Health Summary" -Level "SUCCESS"
Write-Log "  All nodes up: $nodesUp" -Level "INFO"
Write-Log "  Test-Cluster: $($clusterResults.Passed) pass / $($clusterResults.Failed) fail / $($clusterResults.Warnings) warn" -Level "INFO"
Write-Log "  Health Service: $(if ($healthResults.Healthy) { 'No faults' } else { "$($healthResults.Faults.Count) faults" })" -Level "INFO"
Write-Log "  Storage: $(if ($storageResults.Healthy) { 'Healthy' } else { 'Issues detected' })" -Level "INFO"

if (-not $nodesUp -or $clusterResults.Failed -gt 0 -or -not $healthResults.Healthy -or -not $storageResults.Healthy) { exit 1 }
exit 0

#endregion Main
