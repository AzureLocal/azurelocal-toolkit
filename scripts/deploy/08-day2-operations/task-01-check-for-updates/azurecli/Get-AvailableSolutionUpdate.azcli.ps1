<#
.SYNOPSIS
    Reads what Azure shows for the updates of the Azure Local cluster resource (the update summary and the updates), with the Azure CLI, read only.

.DESCRIPTION
    Day 2, stage 08 task 01 (owner directive D74: check for updates after a deployment and periodically), Azure CLI variant of Get-AvailableSolutionUpdate.ps1.
    It answers the Azure side of the question and needs no access to a node, so it runs from a pipeline agent or an administrator's workstation on a schedule.
    The update agent checks the cluster for updates once a day and reports to the cluster resource (Learn: Use Azure Update Manager to update Azure Local), so
    this is what Azure Update Manager and the Azure Local resource page show. Two reads with az rest (the Azure CLI has no az stack-hci update command;
    Learn documents the two REST operations of the Microsoft.AzureStackHCI resource provider):

      1. Update Summaries - Get:  .../clusters/<cluster>/updateSummaries/default   the installed solution and SBE version, the overall update state
         (AppliedSuccessfully, UpdateAvailable, UpdateInProgress, UpdateFailed, NeedsAttention, PreparationInProgress, PreparationFailed), lastChecked, and the
         health check results of the update environment;
      2. Updates - List:  .../clusters/<cluster>/updates   every update the cluster reports, with its state, version, package type and update state properties.

    The script changes nothing in Azure and does not start an update: that is task 02 (PowerShell on the cluster) or Azure Update Manager in the portal. It does not
    sign in: run "az login" to the tenant in azure.tenant_id first. It selects azure.subscription_id with "az account set" and puts the earlier subscription back
    at the end. The signed-in identity needs read access to the cluster resource (the role Azure Stack HCI Administrator, or Reader).

    Output, verdict and the two checks that raise AttentionNeeded are the same as in the PowerShell variant, plus one for Azure: the update service has not checked
    for more than -MaxCheckAgeHours hours (the agent should check daily, so a cluster that did not report for days is not looking for updates). With -OutputPath
    the whole report is also written as JSON.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure): azure.tenant_id, azure.subscription_id, azure.resource_group, cluster.name.

    Exit codes: 0 Azure was read and nothing needs attention (an update may be offered: see the verdict); 1 an az call failed, a precondition failed (az missing,
    not signed in, wrong tenant), the cluster resource was not found, or the verdict is AttentionNeeded; 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read.

.PARAMETER MaxCheckAgeHours
    The longest time since the update service last checked for updates before the report says AttentionNeeded (1 to 720). Default: 48.

.PARAMETER OutputPath
    Optional. Also write the report as JSON to this file. Keep it out of the repository.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Get-AvailableSolutionUpdate.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Prints the Azure view of the updates of the cluster and the verdict.

.EXAMPLE
    ./Get-AvailableSolutionUpdate.azcli.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath ./update-check-azure.json

    The same, and writes the JSON report. Exit code 1 means the cluster needs attention: use it as the alert of a scheduled run.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [ValidateRange(1, 720)][int]$MaxCheckAgeHours = 48,
    [string]$OutputPath,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
# The Azure CLI is started through a command file on Windows. These characters would be read as commands there, so no value that holds one is sent.
$UnsafeArgument = '[&|<>^%"`\r\n]'
# Fixed by Microsoft (Learn REST API reference, Azure Stack HCI: Update Summaries - Get, Updates - List): the provider and the stable API version.
$ProviderPath = 'Microsoft.AzureStackHCI/clusters'
$ApiVersion = '2024-04-01'
$ArmEndpoint = 'https://management.azure.com'
$StartableState = 'Ready', 'ReadyToInstall', 'HealthCheckExpired'
$RunningState = 'Downloading', 'Preparing', 'HealthChecking', 'Installing'
$DoneState = 'Installed', 'Obsolete', 'Invalid', 'Recalled'
$WaitState = 'ScanInProgress', 'NotApplicableBecauseAnotherUpdateIsInProgress'
$BadSummaryState = 'UpdateFailed', 'NeedsAttention', 'PreparationFailed'
$StateAdvice = @{
    AdditionalContentRequired = 'Import the SBE files from the hardware vendor first (stage 04, phase 06, task 10), then check again.'
    HasPrerequisite           = 'It needs another update installed first.'
    DownloadFailed            = 'The download failed (Learn: Troubleshoot updates).'
    PreparationFailed         = 'The preparation failed (Learn: Troubleshoot updates).'
    HealthCheckFailed         = 'The readiness checks failed (Learn: Troubleshoot readiness checks).'
    InstallationFailed        = 'The installation failed. Look at the failure, then resume it (Learn: Troubleshoot updates).'
    ScanFailed                = 'The scan for update content failed (Learn: Troubleshoot updates).'
}

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Prop($Object, [string[]]$Path) {
    $node = $Object
    foreach ($part in $Path) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) { if ($node.Contains($part)) { $node = $node[$part] } else { return $null } }
        elseif ($node.PSObject.Properties[$part]) { $node = $node.PSObject.Properties[$part].Value }
        else { return $null }
    }
    $node
}

# The one place the Azure CLI is called. Arguments go as an array, never as a command string. A character that the Windows command file would read as a
# command stops the call. Returns the exit code, the text of standard output and of standard error.
function Invoke-AzCli([string[]]$Arguments) {
    foreach ($argument in $Arguments) {
        if ($argument -match $UnsafeArgument) { throw "An argument holds a character that is not sent to the Azure CLI (& | < > ^ % or a quote): $argument" }
    }
    $all = @(& az @Arguments 2>&1)
    $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err; Detail = $(if ($err) { $err.Trim() } else { $out.Trim() }) }
}
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 20 } }
function ConvertTo-UpdateVersion([string]$Text) {
    $parsed = $null
    if ([version]::TryParse($Text, [ref]$parsed)) { return $parsed }
    $null
}
function Get-Next($Update) {
    $state = [string]$Update.State
    if ($StartableState -contains $state) {
        if ($Update.PackageType -eq 'SBE') { return @('Start', 'A standalone SBE update. Learn recommends the combined solution update; install this one only when the vendor says it is urgent.') }
        return @('Start', 'Start it: task 02 (Start-AzureLocalSolutionUpdate.ps1 -Mode OnDemand) on the cluster, or Azure Update Manager in the portal.')
    }
    if ($state -eq 'AdditionalContentRequired') { return @('ImportSbe', $StateAdvice[$state]) }
    if ($RunningState -contains $state) { return @('Follow', 'It is running. Check again later, or watch it in the History of Azure Update Manager.') }
    if ($WaitState -contains $state) { return @('Wait', 'The update service is busy; check again later.') }
    if ($StateAdvice.ContainsKey($state)) { return @('Attention', $StateAdvice[$state]) }
    @('None', '')
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$resourceGroup = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder. It is the subscription of the cluster resource.' }
if (-not $resourceGroup) { Exit-InputProblem 'azure.resource_group is missing. It is the resource group of the cluster resource.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the name of the cluster resource.' }
foreach ($pair in @(@('azure.resource_group', $resourceGroup), @('cluster.name', $clusterName))) {
    if ($pair[1] -match $UnsafeArgument -or $pair[1] -match '[/?#\s]') { Exit-InputProblem "$($pair[0]) '$($pair[1])' holds a character that is not allowed in an Azure resource name or that the Azure CLI cannot take." }
}
$clusterUrl = "$ArmEndpoint/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/$ProviderPath/$clusterName"

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Get-AvailableSolutionUpdate.ps1 on a cluster machine.' }
$account = Invoke-AzCli @('account', 'show', '--query', '[tenantId,id]', '--output', 'tsv')
if ($account.ExitCode -ne 0) { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
$accountParts = @($account.Output -split '\s+' | Where-Object { $_ })
if ($accountParts.Count -lt 1 -or $accountParts[0] -ne $tenantId) { Exit-Failed "Signed in to tenant $(if ($accountParts.Count) { $accountParts[0] } else { '(unknown)' }), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalSubscription = if ($accountParts.Count -gt 1) { $accountParts[1] } else { '' }

$report = $null
$verdict = 'UpToDate'
$rows = [System.Collections.Generic.List[object]]::new()
try {
    $set = Invoke-AzCli @('account', 'set', '--subscription', $subscriptionId)
    if ($set.ExitCode -ne 0) { throw "The subscription could not be selected: $($set.Detail)" }

    Write-Line "Cluster resource '$clusterName' in resource group '$resourceGroup': reading the update summary and the updates"
    $summaryResult = Invoke-AzCli @('rest', '--method', 'get', '--url', "$clusterUrl/updateSummaries/default?api-version=$ApiVersion", '--output', 'json', '--only-show-errors')
    if ($summaryResult.ExitCode -ne 0) {
        if ($summaryResult.Detail -match 'ResourceNotFound|NotFound|could not be found|\b404\b') { throw "The cluster resource '$clusterName' was not found in resource group '$resourceGroup' (or it has no update summary yet). Check azure.resource_group and cluster.name, and that the cluster is registered." }
        throw "The update summary could not be read: $($summaryResult.Detail)"
    }
    $summary = ConvertFrom-AzJson $summaryResult.Output
    $listResult = Invoke-AzCli @('rest', '--method', 'get', '--url', "$clusterUrl/updates?api-version=$ApiVersion", '--output', 'json', '--only-show-errors')
    if ($listResult.ExitCode -ne 0) { throw "The updates could not be read: $($listResult.Detail)" }
    $list = ConvertFrom-AzJson $listResult.Output
    $values = @(Get-Prop $list @('value'))
    $more = [bool](Get-Prop $list @('nextLink'))

    $attention = [System.Collections.Generic.List[string]]::new()
    $updates = @(foreach ($item in $values) {
            if ($null -eq $item) { continue }
            [pscustomobject]@{
                Name        = [string](Get-Prop $item @('name'))
                Version     = [string](Get-Prop $item @('properties', 'version'))
                State       = [string](Get-Prop $item @('properties', 'state'))
                PackageType = [string](Get-Prop $item @('properties', 'packageType'))
                DisplayName = [string](Get-Prop $item @('properties', 'displayName'))
                Notify      = [string](Get-Prop $item @('properties', 'updateStateProperties', 'notifyMessage'))
            }
        }) | Sort-Object { ConvertTo-UpdateVersion $_.Version } -Descending
    foreach ($update in ($updates | Where-Object { $DoneState -notcontains $_.State })) {
        $next = Get-Next $update
        if ($next[0] -eq 'Attention') { $attention.Add("$($update.Version) is $($update.State)") }
        $rows.Add([pscustomobject][ordered]@{ Update = $update.Version; Type = $update.PackageType; State = $update.State; Next = $next[0]; Detail = (@($next[1], $update.Notify) | Where-Object { $_ }) -join ' ' })
    }

    $summaryState = [string](Get-Prop $summary @('properties', 'state'))
    $rawChecked = Get-Prop $summary @('properties', 'lastChecked')
    $lastChecked = if ($rawChecked -is [datetime]) { $rawChecked.ToUniversalTime().ToString('o') } else { [string]$rawChecked }
    $healthState = [string](Get-Prop $summary @('properties', 'healthState'))
    if ($BadSummaryState -contains $summaryState) { $attention.Add("the update state of the cluster is $summaryState") }
    $failedChecks = @(@(Get-Prop $summary @('properties', 'healthCheckResult')) | Where-Object { $_ -and [string](Get-Prop $_ @('status')) -eq 'Failed' -and [string](Get-Prop $_ @('severity')) -in 'Critical', 'Warning' })
    foreach ($check in $failedChecks) { $attention.Add("readiness check '$([string](Get-Prop $check @('title')))' failed ($([string](Get-Prop $check @('severity'))))") }
    $lastCheckedAge = $null
    if ($lastChecked) {
        $parsedAt = [datetimeoffset]::MinValue
        $style = [Globalization.DateTimeStyles]::AssumeUniversal
        if ([datetimeoffset]::TryParse($lastChecked, [Globalization.CultureInfo]::InvariantCulture, $style, [ref]$parsedAt)) {
            $lastCheckedAge = [math]::Round(([datetimeoffset]::UtcNow - $parsedAt).TotalHours, 1)
            if ($lastCheckedAge -gt $MaxCheckAgeHours) { $attention.Add("the update service last checked for updates $lastCheckedAge hours ago (more than $MaxCheckAgeHours): the cluster is not looking for updates") }
        }
    }
    else { Write-Line 'The update summary reports no lastChecked time yet (a new cluster: the first check can take a day).' }
    if ($more) { Write-Line 'The list of updates has more than one page; only the first page was read.' }

    $verdict = if ($attention.Count -gt 0) { 'AttentionNeeded' }
    elseif (@($rows | Where-Object Next -EQ 'Follow').Count -gt 0 -or $summaryState -in 'UpdateInProgress', 'PreparationInProgress') { 'UpdateRunning' }
    elseif (@($rows | Where-Object Next -EQ 'Start').Count -gt 0) { 'UpdateAvailable' }
    elseif (@($rows | Where-Object Next -EQ 'ImportSbe').Count -gt 0) { 'AdditionalContentRequired' }
    else { 'UpToDate' }

    $report = [ordered]@{
        Cluster           = $clusterName
        ResourceGroup     = $resourceGroup
        CheckedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
        CurrentVersion    = [string](Get-Prop $summary @('properties', 'currentVersion'))
        CurrentSbeVersion = [string](Get-Prop $summary @('properties', 'currentSbeVersion'))
        HardwareModel     = [string](Get-Prop $summary @('properties', 'hardwareModel'))
        SummaryState      = $summaryState
        HealthState       = $healthState
        LastChecked       = $lastChecked
        LastCheckedAgeHours = $lastCheckedAge
        Verdict           = $verdict
        Attention         = @($attention)
        Updates           = @($updates | ForEach-Object { $n = Get-Next $_; [ordered]@{ Name = $_.Name; Version = $_.Version; Type = $_.PackageType; State = $_.State; Next = $n[0]; DisplayName = $_.DisplayName } })
    }
    Write-Line "Installed solution version $($report.CurrentVersion) (SBE $($report.CurrentSbeVersion)), update state $summaryState, last checked $(if ($lastChecked) { $lastChecked } else { 'not reported' })"
    if ($rows.Count -eq 0) { Write-Line 'Azure shows no update that is offered or running.' }
    foreach ($item in $attention) { Write-Line "[attention] $item" }
    Write-Line "Verdict: $verdict"
}
catch { Exit-Failed "The update check stopped: $($_.Exception.Message)" }
finally {
    if ($originalSubscription -and $originalSubscription -ne $subscriptionId) {
        $back = Invoke-AzCli @('account', 'set', '--subscription', $originalSubscription)
        if ($back.ExitCode -ne 0) { Write-Verbose "Could not restore the original subscription: $($back.Detail)" }
    }
}

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
