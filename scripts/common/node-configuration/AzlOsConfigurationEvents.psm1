#Requires -Version 7.0
<#
.SYNOPSIS
    The OS configuration event feed: one JSON object per line that tells a viewer (azurelocal-sonar) what an OS configuration run is doing.

.DESCRIPTION
    The format is JSON Lines, UTF-8 without a byte-order mark, one event per line, appended as the run goes. It has the same shape the
    azurelocal-ztp event file has, so one reader follows both:

        timestamp   UTC, ISO-8601 round-trip format ('o': 2026-11-07T19:01:59.5360000Z)
        node        the node's name, or '*' for an event about the whole run
        stage       always 'OsConfiguration'
        step        the step the event is about (RemoteManagement, Network, ...), '' for node and run events
        state       what happened (the tables below)
        evidence    one line of plain text a person can read: what was found, changed or failed
        level       Info | Warning | Error
        nextAction  what to do next, '' when nothing
        method      'Ztp' | 'Iso' | '' (not known yet, or a run event)
        transport   'ArcRunCommand' | 'WinRM' | ''
        payloadVersion  the version of the node payload (the result format the nodes answer in)
        schemaVersion   the master file's _metadata.schema_version

    Optional fields, present when they apply: nodes (RunStarted: array of node names), mode (Plan|Apply), cluster, exitCode,
    converged, total (RunCompleted), action (StepPlanned: Ok|Change|Blocked|Info), item, current, desired (StepPlanned, StepFailed),
    try, tries, waitSeconds (NodeRetry), wipe (WipeListPublished: array of { node, disks }), wipeCount.

    The contract is section 6 of pmo/azure-local/os-configuration-design.md. Run events (node '*'): RunStarted, PlanCompleted,
    WipeListPublished, RunCompleted. Node events: NodeStarted, MethodResolved, TransportResolved, NodeRetry, NodeRestarting, NodeConverged,
    NodeFailed, NodeBlocked, NodeReconnecting, NodeReconnected. Step events: StepPlanned, StepApplying, StepApplied, StepFailed, StepSkipped,
    StepVerified. Domain join (step DomainJoin, Active Directory designs): DomainJoinPlanned, DomainJoinApplying, DomainJoined,
    DomainAdminsConfigured (the LCM user or the listed principals were added to the node's local Administrators), DomainJoinFailed (evidence: the AD error). Guarded change events (step Network): NetworkChangeStaged, NetworkChangeVerifying, NetworkChangeAwaitingConfirm,
    NetworkChangeCommitted, NetworkChangeRepaired, NetworkChangeRolledBack, NetworkChangeRefused; they may carry changeId, rung,
    reason, confirmMinutes and confirmBy (UTC time the confirmation window ends).

    Writing the feed never fails the run: a path that can't be written is skipped (Write-Verbose says why).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The 12 steps of the OS configuration, in the order a reader shows them, and the Arc registration an ISO-installed machine also gets.
$script:StepOrder = @('RemoteManagement', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe', 'Drivers', 'ArcRegistration')
$script:EventMaxText = 2000
$script:EventState = [ordered]@{
    Run     = @('RunStarted', 'PlanCompleted', 'WipeListPublished', 'RunCompleted')
    Node    = @('NodeStarted', 'MethodResolved', 'TransportResolved', 'NodeRetry', 'NodeRestarting', 'NodeConverged', 'NodeFailed', 'NodeBlocked', 'NodeReconnecting', 'NodeReconnected')
    Step    = @('StepPlanned', 'StepSkipped', 'StepApplying', 'StepApplied', 'StepFailed', 'StepVerified')
    DomainJoin = @('DomainJoinPlanned', 'DomainJoinApplying', 'DomainJoined', 'DomainAdminsConfigured', 'DomainJoinFailed')
    Guarded = @('NetworkChangeStaged', 'NetworkChangeVerifying', 'NetworkChangeAwaitingConfirm', 'NetworkChangeCommitted', 'NetworkChangeRepaired', 'NetworkChangeRolledBack', 'NetworkChangeRefused')
}

function Get-AzlOsConfigurationEventState {
    <#
    .SYNOPSIS
        The event states of the feed by level: Run, Node, Step, DomainJoin and Guarded (the guarded network change).
    #>
    [CmdletBinding()]
    param()
    return $script:EventState
}

function Get-AzlOsConfigurationStepOrder {
    <#
    .SYNOPSIS
        The steps in display order: the 12 steps, then ArcRegistration (ISO path only).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]$script:StepOrder
}

function Get-AzlOsEventTimestamp {
    # UTC, ISO-8601 round-trip ('o'), invariant culture.
    [OutputType([string])]
    param([datetime]$Now = [datetime]::UtcNow)
    return $Now.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture)
}

function Limit-AzlOsEventText([string]$Text, [int]$Max = $script:EventMaxText) {
    if ($null -eq $Text) { return '' }
    $one = ($Text -replace '\s*[\r\n]+\s*', ' ').Trim()
    if ($one.Length -gt $Max) { return $one.Substring(0, $Max - 3) + '...' }
    return $one
}

function Write-AzlOsConfigurationEvent {
    <#
    .SYNOPSIS
        Appends one event line to the feed. Never throws: a failure to write is reported with Write-Verbose and the run goes on.
    .DESCRIPTION
        The line is built whole and written with one append (the file is opened with FileShare ReadWrite, so a reader can follow it).
        Returns $true when the line was written, $false when it wasn't (no path, or the write failed).
    .PARAMETER Data
        Extra fields (nodes, action, current, desired, exitCode, ...) added after the standard ones.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$State,
        [string]$Step = '',
        [string]$Evidence = '',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$NextAction = '',
        [ValidateSet('', 'Ztp', 'Iso')][string]$Method = '',
        [ValidateSet('', 'ArcRunCommand', 'WinRM')][string]$Transport = '',
        [string]$PayloadVersion = '',
        [string]$SchemaVersion = '',
        [System.Collections.IDictionary]$Data,
        [datetime]$Now = [datetime]::UtcNow
    )
    if (-not $Path) { return $false }
    try {
        $entry = [ordered]@{
            timestamp  = Get-AzlOsEventTimestamp -Now $Now
            node       = $Node
            stage      = 'OsConfiguration'
            step       = $Step
            state      = $State
            evidence   = Limit-AzlOsEventText $Evidence
            level      = $Level
            nextAction = Limit-AzlOsEventText $NextAction
            method     = $Method
            transport  = $Transport
            payloadVersion = $PayloadVersion
            schemaVersion  = $SchemaVersion
        }
        if ($Data) {
            foreach ($key in $Data.Keys) {
                if ($entry.Contains([string]$key)) { continue }
                $value = $Data[$key]
                if ($value -is [string]) { $entry[[string]$key] = Limit-AzlOsEventText $value } else { $entry[[string]$key] = $value }
            }
        }
        $line = (ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n"
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
        $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
        finally { $stream.Dispose() }
        return $true
    }
    catch {
        Write-Verbose "OS configuration event not written to ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Get-AzlOsStepPlan {
    <#
    .SYNOPSIS
        Folds the plan items of each step into one entry per step: the action (Blocked, Change, Info or Ok), the evidence text and the
        current and desired values.
    .DESCRIPTION
        The plan items are those of Set-AzureLocalNodeConfiguration (Step, Item, Current, Desired, Action, Note). A step with a
        Blocked item is Blocked, else with a Change item Change, else with an Info item (or an item the script skipped) Info, else Ok.
        The evidence names the items that decide the action (all of them, at most four) as 'item: current -> desired'.
    .OUTPUTS
        Step, Action, Evidence, Current, Desired, Item, Count (items in the step), Note.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Plan = @())
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($Plan | Where-Object { $_ -and $_.Step } | Group-Object -Property Step)) {
        $items = @($group.Group)
        $actionOf = { param($i) $a = [string]$i.Action; if ($a -in 'Ok', 'Change', 'Blocked') { $a } else { 'Info' } }
        $action = if (@($items | Where-Object { (& $actionOf $_) -eq 'Blocked' }).Count) { 'Blocked' }
        elseif (@($items | Where-Object { (& $actionOf $_) -eq 'Change' }).Count) { 'Change' }
        elseif (@($items | Where-Object { (& $actionOf $_) -eq 'Info' }).Count) { 'Info' }
        else { 'Ok' }
        $deciding = @($items | Where-Object { (& $actionOf $_) -eq $action })
        $shown = @($deciding | Select-Object -First 4)
        $parts = foreach ($i in $shown) {
            $text = "$($i.Item): $($i.Current)"
            if ($action -in 'Change', 'Blocked' -and "$($i.Desired)") { $text += " -> $($i.Desired)" }
            $text
        }
        $evidence = ($parts -join '; ')
        if ($deciding.Count -gt $shown.Count) { $evidence += "; and $($deciding.Count - $shown.Count) more" }
        if ($action -eq 'Ok' -and $items.Count -gt 1) { $evidence = "$($items.Count) items match: $evidence" }
        $notes = @($shown | Where-Object { $_.Note } | ForEach-Object { [string]$_.Note } | Select-Object -Unique)
        if ($action -eq 'Blocked' -and $notes) { $evidence += " ($($notes -join ' '))" }
        $result.Add([pscustomobject]@{
                Step     = [string]$group.Name
                Action   = $action
                Evidence = $evidence
                Current  = Limit-AzlOsEventText (($shown | ForEach-Object { [string]$_.Current }) -join '; ') 600
                Desired  = Limit-AzlOsEventText (($shown | ForEach-Object { [string]$_.Desired }) -join '; ') 600
                Item     = Limit-AzlOsEventText (($shown | ForEach-Object { [string]$_.Item }) -join '; ') 300
                Count    = $items.Count
                Note     = ($notes -join ' ')
            })
    }
    return $result.ToArray()
}

function ConvertFrom-AzlOsRetryWarning {
    <#
    .SYNOPSIS
        Reads the warning Invoke-AzlNodeScript writes before it tries a run command again (state Unknown): returns Node, Try, Tries and
        WaitSeconds, or $null when the text is anything else.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    $m = [regex]::Match($Message, '^(?<node>\S+?):\s+the run command ended in state Unknown \(try (?<try>\d+) of (?<max>\d+);.*?Trying again in (?<wait>\d+) s\.?\s*$', 'Singleline')
    if (-not $m.Success) { return $null }
    [pscustomobject]@{
        Node        = $m.Groups['node'].Value
        Try         = [int]$m.Groups['try'].Value
        Tries       = [int]$m.Groups['max'].Value
        WaitSeconds = [int]$m.Groups['wait'].Value
    }
}

Export-ModuleMember -Function Get-AzlOsConfigurationEventState, Get-AzlOsConfigurationStepOrder, Get-AzlOsEventTimestamp, Write-AzlOsConfigurationEvent, Get-AzlOsStepPlan, ConvertFrom-AzlOsRetryWarning
