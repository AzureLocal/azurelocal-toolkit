<#
.SYNOPSIS
    Checks which Azure Local updates the cluster has discovered and what to do with each, read only. Run it after the deployment and then on a schedule.

.DESCRIPTION
    Day 2, stage 08 task 01 (owner directive D74: check for updates after a deployment and periodically). A freshly deployed cluster does not show its first
    update on its own until later, so the toolkit always checks, then shows what Azure offers. The script connects to the cluster with PowerShell remoting and,
    the way Microsoft Learn describes it (Update Azure Local by using PowerShell; Solution Builder Extension updates):

      1. reads the update environment (Get-SolutionUpdateEnvironment): the installed solution and SBE version, the update state, the health state and
         LastChecked, the time the update service last checked for updates;
      2. polls discovery with Get-SolutionUpdate. Learn names no command that forces a check: the Lifecycle Manager discovers updates by itself (it queries the
         online SBE manifest of the hardware vendor and the Microsoft catalogue), the update agent checks once a day, and "repeat the Get-SolutionUpdate command to
         rediscover the updates". Azure Update Manager has a "Check for updates" button for the same purpose. With -WaitMinutes the script repeats the read until an
         update is offered or the time is over, so a script that runs straight after the deployment can wait for the first update. The wait ends at once, with the verdict
         AttentionNeeded, when an update is in a failed state or needs a prerequisite, when the health of the update environment is Failure, Error or Warning, or when the
         update environment state is UpdateFailed, NeedsAttention or PreparationFailed: waiting longer does not fix any of them;
      3. says, for each update that is not finished, what is next: Ready or ReadyToInstall (start it: task 02), AdditionalContentRequired (import the SBE files
         first: stage 04, phase 06, task 11, then check again), Downloading, Preparing, HealthChecking or Installing (follow it), or a failed state (look at it).

    It changes nothing: no update is started, nothing is imported, nothing is written on the cluster. It reads no secret and signs in nowhere; it connects as the
    account that runs it, or as -Credential (Learn: use the deployment user account). The Azure side of the same question (the update summary and the updates
    that Azure shows for the cluster resource) is read by the Azure CLI variant, Get-AvailableSolutionUpdate.azcli.ps1, which needs no access to a node.

    Output: one table row per update that is not Installed, Obsolete, Invalid or Recalled, and a summary line. With -OutputPath the whole report (cluster,
    versions, health, every update, the verdict) is also written as JSON, for a schedule or a monitor.

    Verdict:
      UpToDate                   no update is offered and none is running
      UpdateAvailable            at least one update is Ready or ReadyToInstall
      AdditionalContentRequired  an update waits for SBE content from the hardware vendor (nothing is ready to start)
      UpdateRunning              an update is Downloading, Preparing, HealthChecking or Installing
      AttentionNeeded            an update is in a failed state, needs a prerequisite, or the health of the update environment is Failure, Error or Warning
                                 (Learn: review the HealthState before you proceed), or the update environment state is UpdateFailed, NeedsAttention or PreparationFailed

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name                                  the cluster to connect to (unless -ComputerName is given)
        operations.updates.target_version             optional: latest (default) or a solution version of four numbers; the report says whether that version is offered

    Exit codes: 0 the cluster was read and nothing needs attention (an update may be offered: see the verdict); 1 the cluster could not be read, or the verdict
    is AttentionNeeded; 2 a value in the file is missing or not usable. Nothing is sent to the cluster on exit code 2.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to connect to instead of cluster.name, for example one node when the cluster name does not resolve from where you run this.

.PARAMETER Credential
    Optional. The account for the remoting session, the deployment user. Without it the account that runs the script is used.

.PARAMETER WaitMinutes
    Optional. When no update is offered yet, read again every -PollSeconds until one is offered or this many minutes have passed (0 to 240). The wait stops at once when something needs attention (a failed update, a blocking health state, a failed update environment): the verdict is AttentionNeeded. Default: 0 (read once).

.PARAMETER PollSeconds
    Seconds between two reads while -WaitMinutes waits (5 to 600). Default: 60.

.PARAMETER OutputPath
    Optional. Also write the report as JSON to this file. Keep it out of the repository.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Get-AvailableSolutionUpdate.ps1 -InfrastructureFile ./infrastructure.yml

    Reads the update state of the cluster once and prints the table and the verdict.

.EXAMPLE
    ./Get-AvailableSolutionUpdate.ps1 -InfrastructureFile ./infrastructure.yml -WaitMinutes 120 -OutputPath ./update-check.json

    Straight after a deployment: waits up to two hours for the first update to be offered and writes the JSON report.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [ValidateRange(0, 240)][int]$WaitMinutes = 0,
    [ValidateRange(5, 600)][int]$PollSeconds = 60,
    [string]$OutputPath,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath
$remoteCredential = $Credential

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# The states of an update that Learn names (Understand update phases of Azure Local; the Updates REST API lists the same states).
$StartableState = 'Ready', 'ReadyToInstall', 'HealthCheckExpired'
$RunningState = 'Downloading', 'Preparing', 'HealthChecking', 'Installing'
$DoneState = 'Installed', 'Obsolete', 'Invalid', 'Recalled'
$WaitState = 'ScanInProgress', 'NotApplicableBecauseAnotherUpdateIsInProgress', 'PendingOEMValidation'
$BlockingHealth = 'Failure', 'Error', 'Warning'
$BadEnvironmentState = 'UpdateFailed', 'NeedsAttention', 'PreparationFailed'
$StateAdvice = @{
    AdditionalContentRequired = 'Import the SBE files from the hardware vendor first (stage 04, phase 06, task 11, Get-AzureLocalSbeImportPlan.ps1), then check again.'
    HasPrerequisite           = 'It needs another update installed first (see its Prerequisites in Get-SolutionUpdate).'
    DownloadFailed            = 'The download failed (Get-SolutionUpdateRun, Learn: Troubleshoot updates).'
    PreparationFailed         = 'The preparation failed (Get-SolutionUpdateRun, Learn: Troubleshoot updates).'
    HealthCheckFailed         = 'The readiness checks failed (Get-SolutionHealthSummary, Learn: Troubleshoot readiness checks).'
    InstallationFailed        = 'The installation failed. Look at the failure (Get-SolutionUpdateRun), then resume it with Start-SolutionUpdate (Learn: Troubleshoot updates).'
    ScanFailed                = 'The scan for update content failed (Learn: Troubleshoot updates).'
}

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function ConvertTo-UpdateVersion([string]$Text) {
    $parsed = $null
    if ([version]::TryParse($Text, [ref]$parsed)) { return $parsed }
    $null
}

# The one command that runs on the cluster: read only.
$ReadState = {
    $environment = Get-SolutionUpdateEnvironment -ErrorAction Stop
    $lastChecked = ''
    if ($environment.LastChecked -and ([datetime]$environment.LastChecked).Year -gt 1) { $lastChecked = ([datetime]$environment.LastChecked).ToUniversalTime().ToString('o') }
    @{
        CurrentVersion    = [string]$environment.CurrentVersion
        CurrentSbeVersion = [string]$environment.CurrentSbeVersion
        State             = [string]$environment.State
        HealthState       = [string]$environment.HealthState
        LastChecked       = $lastChecked
        HardwareModel     = [string]$environment.HardwareModel
        Updates           = @(Get-SolutionUpdate -ErrorAction Stop | ForEach-Object {
                @{
                    ResourceId = [string]$_.ResourceId; Version = [string]$_.Version; SbeVersion = [string]$_.SbeVersion; State = [string]$_.State
                    PackageType = [string]$_.PackageType; DisplayName = [string]$_.DisplayName; UpdateStateProperties = [string]$_.UpdateStateProperties
                }
            })
    }
}
function Read-Cluster {
    $call = @{ ComputerName = $script:target; ScriptBlock = $ReadState; ErrorAction = 'Stop' }
    if ($remoteCredential) { $call.Credential = $remoteCredential }
    Invoke-Command @call
}

# What is next for one update.
function Get-Next($Update) {
    $state = [string]$Update.State
    if ($StartableState -contains $state) {
        if ($Update.PackageType -eq 'SBE') { return @('Start', 'A standalone SBE update. Learn recommends the combined solution update; install this one only when the vendor says it is urgent (Get-SolutionUpdate -Id <ResourceId> | Start-SolutionUpdate on a machine).') }
        return @('Start', 'Start it: task 02, Start-AzureLocalSolutionUpdate.ps1 -Mode OnDemand (add -PrepareOnly to download and check it first).')
    }
    if ($state -eq 'AdditionalContentRequired') { return @('ImportSbe', $StateAdvice[$state]) }
    if ($RunningState -contains $state) { return @('Follow', 'It is running. Check again with this script, or watch it in Get-SolutionUpdate or Update Manager.') }
    if ($WaitState -contains $state) { return @('Wait', 'The update service is busy; check again later.') }
    if ($StateAdvice.ContainsKey($state)) { return @('Attention', $StateAdvice[$state]) }
    @('None', '')
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$targetRaw = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'operations.updates.target_version')).Trim()
if (-not $targetRaw) { $targetRaw = 'latest' }
$targetVersion = $null
if ($targetRaw -ine 'latest') {
    if ($targetRaw -notmatch '^\d+\.\d+\.\d+\.\d+$') { Exit-InputProblem "operations.updates.target_version must be latest or a solution version of four numbers, for example 12.2611.1004.9; found '$targetRaw'." }
    $targetVersion = ConvertTo-UpdateVersion $targetRaw
    if (-not $targetVersion) { Exit-InputProblem "operations.updates.target_version '$targetRaw' is not a version number." }
}
$target = if ($ComputerName) { $ComputerName.Trim() } else { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim() }
if (-not $target) { Exit-InputProblem 'cluster.name is missing. It is the cluster the script connects to (or give -ComputerName).' }

# ---- the cluster as it is (read only), repeated while -WaitMinutes waits for the first update
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$readCount = 0
do {
    Write-Line "Cluster '$target': reading the update environment and polling discovery (Get-SolutionUpdate)"
    try { $state = Read-Cluster }
    catch { Exit-Failed "The cluster '$target' could not be read: $($_.Exception.Message)" }
    $readCount++
    $updates = @(@($state.Updates) | Sort-Object { ConvertTo-UpdateVersion $_.Version } -Descending)
    $offered = @($updates | Where-Object { $StartableState -contains $_.State -or $_.State -eq 'AdditionalContentRequired' -or $RunningState -contains $_.State })
    # Something that waiting does not fix ends the wait at once: a failed update, a blocking health state, a failed update environment.
    $needsAttention = @($updates | Where-Object { (Get-Next $_)[0] -eq 'Attention' }).Count -gt 0 -or $BlockingHealth -contains [string]$state.HealthState -or $BadEnvironmentState -contains [string]$state.State
    if ($WaitMinutes -gt 0 -and $needsAttention -and $offered.Count -eq 0) { Write-Line 'Something needs attention (a failed update, the health of the update environment, or its state): the wait ends here.' }
    $again = $WaitMinutes -gt 0 -and $offered.Count -eq 0 -and -not $needsAttention -and (Get-Date) -lt $deadline
    if ($again) {
        Write-Line "No update is offered yet (the update service last checked: $(if ($state.LastChecked) { $state.LastChecked } else { 'not reported' })). Reading again in $PollSeconds seconds, until $($deadline.ToUniversalTime().ToString('HH:mm')) UTC."
        Start-Sleep -Seconds $PollSeconds
    }
} while ($again)

# ---- the report
$rows = [System.Collections.Generic.List[object]]::new()
$attention = [System.Collections.Generic.List[string]]::new()
foreach ($update in ($updates | Where-Object { $DoneState -notcontains $_.State })) {
    $next = Get-Next $update
    if ($next[0] -eq 'Attention') { $attention.Add("$($update.Version) is $($update.State)") }
    $rows.Add([pscustomobject][ordered]@{
            Update = $update.Version; Type = $update.PackageType; State = $update.State; Next = $next[0]
            Detail = (@($next[1], $update.UpdateStateProperties) | Where-Object { $_ }) -join ' '
        })
}
if ($BlockingHealth -contains [string]$state.HealthState) { $attention.Add("the health of the update environment is $($state.HealthState) (Learn: Troubleshoot readiness checks)") }
if ($BadEnvironmentState -contains [string]$state.State) { $attention.Add("the update environment state is $($state.State)") }

$verdict = if ($attention.Count -gt 0) { 'AttentionNeeded' }
elseif (@($rows | Where-Object Next -EQ 'Follow').Count -gt 0) { 'UpdateRunning' }
elseif (@($rows | Where-Object Next -EQ 'Start').Count -gt 0) { 'UpdateAvailable' }
elseif (@($rows | Where-Object Next -EQ 'ImportSbe').Count -gt 0) { 'AdditionalContentRequired' }
else { 'UpToDate' }

$targetNote = ''
if ($targetVersion) {
    $match = @($updates | Where-Object { (ConvertTo-UpdateVersion $_.Version) -eq $targetVersion -and $_.PackageType -eq 'Solution' }) | Select-Object -First 1
    $current = ConvertTo-UpdateVersion ([string]$state.CurrentVersion)
    $targetNote = if ($current -and $current -ge $targetVersion) { "operations.updates.target_version $targetRaw is installed or older than the installed version." }
    elseif ($match) { "operations.updates.target_version $targetRaw is offered (state $($match.State))." }
    else { "operations.updates.target_version $targetRaw is not offered yet (it can take a week after the release before a feature update is visible)." }
}

$report = [ordered]@{
    Cluster           = $target
    CheckedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
    Reads             = $readCount
    CurrentVersion    = [string]$state.CurrentVersion
    CurrentSbeVersion = [string]$state.CurrentSbeVersion
    HardwareModel     = [string]$state.HardwareModel
    EnvironmentState  = [string]$state.State
    HealthState       = [string]$state.HealthState
    LastChecked       = [string]$state.LastChecked
    TargetVersion     = $targetRaw
    TargetNote        = $targetNote
    Verdict           = $verdict
    Attention         = @($attention)
    Updates           = @($updates | ForEach-Object { $n = Get-Next $_; [ordered]@{ ResourceId = $_.ResourceId; Version = $_.Version; SbeVersion = $_.SbeVersion; Type = $_.PackageType; State = $_.State; Next = $n[0]; DisplayName = $_.DisplayName } })
}

Write-Line "Installed solution version $($state.CurrentVersion) (SBE $($state.CurrentSbeVersion)), update environment state $($state.State), health $($state.HealthState), last checked $(if ($state.LastChecked) { $state.LastChecked } else { 'not reported' })"
if ($targetNote) { Write-Line $targetNote }
if ($rows.Count -eq 0) { Write-Line 'No update is offered or running.' }
foreach ($item in $attention) { Write-Line "[attention] $item" }
Write-Line "Verdict: $verdict"

if ($OutputPath) {
    try {
        $folder = Split-Path -Path $OutputPath -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        Set-Content -LiteralPath $OutputPath -Value ($report | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
        Write-Line "Report written to $OutputPath"
    }
    catch { Exit-Failed "The report could not be written to ${OutputPath}: $($_.Exception.Message)" }
}

$rows
if ($verdict -eq 'AttentionNeeded') { exit 1 }
exit 0
