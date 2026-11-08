#Requires -Version 7.0
<#
.SYNOPSIS
    The OS configuration event feed: one JSON object per line that tells a viewer (azurelocal-sonar) what an OS configuration run is doing.

.DESCRIPTION
    The format is JSON Lines, UTF-8 without a byte-order mark, one event per line, appended as the run goes. It has the same shape the
    azurelocal-ztp event file has, so one reader follows both:

        timestamp   UTC, ISO-8601 round-trip format ('o': 2026-11-07T19:01:59.5360000Z)
        runId       the id of the run that wrote the line (UTC start time and six hex digits). A feed path that is reused keeps the lines of every run; the run id tells
                    them apart, so an old RunCompleted is never taken for the current run's. The writer takes it from -RunId, else from AZL_OSCONFIG_RUN_ID.
        seq         1, 2, 3 ... within one run id in one feed file: a reader sees a line that is missing, and the order the lines were written in
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

    Free text (evidence, nextAction and every text value in the extra fields) goes through a redaction pass before it is written: passwords, tokens, bearer headers,
    SAS signatures, account keys, private keys and node result lines become ***.

    The contract is section 6 of pmo/azure-local/os-configuration-design.md. The one registry of states is Get-AzlOsConfigurationEventState (Test-AzlOsConfigurationEventState
    asks it); every state any module sends is in it. Run events (node '*'): RunStarted, PlanCompleted,
    WipeListPublished, WipeListApproved, WipeListRejected (the Apply was bound to the approved wipe list, or refused for it), RunCompleted.
    Transport (step Transport): StaleRunCommandDeleted, NodeCallAttempt (one per attempt of a call to a node: payload, durationSeconds, address, callState, error, timeoutSeconds), SbeDeliveryProgress (the SBE package copy, every 5 percent: file, percent, sentBytes, totalBytes). Node events: NodeStarted, MethodResolved, TransportResolved, NodeRetry, NodeRestarting, NodeConverged,
    NodeFailed, NodeBlocked, NodeReconnecting, NodeReconnected, NodeWaiting (a heartbeat every 60 seconds while the host waits for a node; waiting, phase and elapsedSeconds say what for). Step events: StepPlanned, StepApplying, StepApplied, StepFailed, StepSkipped,
    StepVerified. Domain join (step DomainJoin, Active Directory designs): DomainJoinPlanned, DomainJoinApplying, DomainJoined,
    DomainAdminsConfigured (the LCM user or the listed principals were added to the node's local Administrators), DomainJoinFailed (evidence: the AD error). Guarded change events (step Network): NetworkChangeStaged, NetworkChangeVerifying, NetworkChangeAwaitingConfirm,
    NetworkChangeCommitted, NetworkChangeRepaired, NetworkChangeRolledBack, NetworkChangeRefused, ObservedCommitted (the guard's status could not be read, but a Read of the node shows the change's items in place); they may carry changeId, rung,
    reason, confirmMinutes and confirmBy (UTC time the confirmation window ends).

    Writing the feed never fails the run: a path that can't be written is skipped (Write-Verbose says why).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The 13 steps of the OS configuration (DomainJoin does something only in Active Directory designs), in the order a reader shows them, and the Arc registration an ISO-installed machine also gets.
$script:StepOrder = @('RemoteManagement', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe', 'Drivers', 'ArcRegistration')
$script:EventMaxText = 2000
$script:EventState = [ordered]@{
    Run     = @('RunStarted', 'PlanCompleted', 'WipeListPublished', 'WipeListApproved', 'WipeListRejected', 'RunCompleted')
    Node    = @('NodeStarted', 'MethodResolved', 'TransportResolved', 'NodeRetry', 'NodeRestarting', 'NodeConverged', 'NodeFailed', 'NodeBlocked', 'NodeReconnecting', 'NodeReconnected', 'NodeWaiting')
    Step    = @('StepPlanned', 'StepSkipped', 'StepApplying', 'StepApplied', 'StepFailed', 'StepVerified')
    DomainJoin = @('DomainJoinPlanned', 'DomainJoinApplying', 'DomainJoined', 'DomainAdminsConfigured', 'DomainJoinFailed')
    Guarded = @('NetworkChangeStaged', 'NetworkChangeVerifying', 'NetworkChangeAwaitingConfirm', 'NetworkChangeCommitted', 'NetworkChangeRepaired', 'NetworkChangeRolledBack', 'NetworkChangeRefused', 'ObservedCommitted')
    Transport = @('StaleRunCommandDeleted', 'NodeCallAttempt', 'SbeDeliveryProgress')
}
# The next sequence number per feed file and run id, for a feed that can't be read back.
$script:EventSeq = @{}

function Get-AzlOsConfigurationEventState {
    <#
    .SYNOPSIS
        The one registry of event states, by group: Run, Node, Step, DomainJoin, Guarded (the guarded network change) and Transport.
    #>
    [CmdletBinding()]
    param()
    return $script:EventState
}

function Test-AzlOsConfigurationEventState {
    <#
    .SYNOPSIS
        Whether a state is in the registry. A state that is not stays out of the feed (the guard keeps it in the report only).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$State)
    foreach ($group in $script:EventState.Keys) { if ($State -in $script:EventState[$group]) { return $true } }
    return $false
}

function Get-AzlOsConfigurationStepOrder {
    <#
    .SYNOPSIS
        The steps in display order: the 13 steps, then ArcRegistration (ISO path only).
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

function Protect-AzlOsEventText {
    <#
    .SYNOPSIS
        The redaction pass over free text: what looks like a secret becomes ***. Passwords and keys after = or :, bearer headers, JWTs, SAS signatures, private keys, a node
        result line (AZLRESULT:) and any long base64 run. Ordinary evidence is returned as it was.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|$)', '***private key***')
    $t = [regex]::Replace($t, '(?i)\b(password|passwd|pwd|secret|client[-_]?secret|api[-_]?key|access[-_]?key|account[-_]?key|shared[-_]?access[-_]?key|token|credential)\b(\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s;,&"'']+)', '$1$2***')
    $t = [regex]::Replace($t, '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}', 'Bearer ***')
    $t = [regex]::Replace($t, '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*', '***jwt***')
    $t = [regex]::Replace($t, '(?i)([?&;]\s*(?:sig|signature|sas|sv|st|se)=)[^&\s;]+', '$1***')
    $t = [regex]::Replace($t, 'AZLRESULT:[A-Za-z0-9+/=]{16,}', 'AZLRESULT:***')
    $t = [regex]::Replace($t, '[A-Za-z0-9+/]{120,}={0,2}', '***base64***')
    return $t
}

function Limit-AzlOsEventText([string]$Text, [int]$Max = $script:EventMaxText) {
    if ($null -eq $Text) { return '' }
    $one = (Protect-AzlOsEventText -Text ($Text -replace '\s*[\r\n]+\s*', ' ')).Trim()
    if ($one.Length -gt $Max) { return $one.Substring(0, $Max - 3) + '...' }
    return $one
}

function Protect-AzlOsEventValue {
    # An extra field of an event with its text redacted and limited: strings, and the strings in lists, dictionaries and objects (to a depth of six).
    param([AllowNull()][object]$Value, [int]$Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Limit-AzlOsEventText $Value) }
    if ($Value -is [ValueType] -or $Depth -ge 6) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in $Value.Keys) { $copy[[string]$k] = Protect-AzlOsEventValue -Value $Value[$k] -Depth ($Depth + 1) }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) { return , @(foreach ($v in $Value) { Protect-AzlOsEventValue -Value $v -Depth ($Depth + 1) }) }
    $copy = [ordered]@{}
    foreach ($p in $Value.PSObject.Properties) { if ($p.MemberType -in 'NoteProperty', 'Property') { $copy[$p.Name] = Protect-AzlOsEventValue -Value $p.Value -Depth ($Depth + 1) } }
    return $copy
}

function Get-AzlOsEventNextSeq {
    # The sequence number of the next line of a run in a feed file: one more than the last line of this run, read from the end of the file (so the writers of different
    # modules, and a feed that other runs appended to, all agree), else 1.
    param([string]$Path, [string]$RunId)
    $key = "$Path|$RunId"
    $fromMemory = if ($script:EventSeq.ContainsKey($key)) { [int]$script:EventSeq[$key] + 1 } else { 1 }
    $fromFile = 1
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $take = [int][Math]::Min($stream.Length, 262144)
                if ($take -gt 0) {
                    $null = $stream.Seek(-$take, [System.IO.SeekOrigin]::End)
                    $buffer = [byte[]]::new($take)
                    $read = $stream.Read($buffer, 0, $take)
                    $last = @([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read) -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
                    if ($last) {
                        $o = $last | ConvertFrom-Json
                        if ($o.PSObject.Properties['runId'] -and [string]$o.runId -eq $RunId -and $o.PSObject.Properties['seq']) { $fromFile = [int]$o.seq + 1 }
                    }
                }
            }
            finally { $stream.Dispose() }
        }
    }
    catch { Write-Verbose "Sequence not read from ${Path}: $($_.Exception.Message)" }
    return [Math]::Max($fromMemory, $fromFile)
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
        [datetime]$Now = [datetime]::UtcNow,
        # The run this line belongs to. Default: AZL_OSCONFIG_RUN_ID, which the run sets, so every module of one run writes the same id.
        [string]$RunId = [string]$env:AZL_OSCONFIG_RUN_ID
    )
    if (-not $Path) { return $false }
    try {
        $seq = Get-AzlOsEventNextSeq -Path $Path -RunId $RunId
        $entry = [ordered]@{
            timestamp  = Get-AzlOsEventTimestamp -Now $Now
            runId      = $RunId
            seq        = $seq
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
                $entry[[string]$key] = Protect-AzlOsEventValue -Value $Data[$key]
            }
        }
        $line = (ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n"
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
        $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
        finally { $stream.Dispose() }
        $script:EventSeq["$Path|$RunId"] = $seq
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

Export-ModuleMember -Function Get-AzlOsConfigurationEventState, Test-AzlOsConfigurationEventState, Protect-AzlOsEventText, Protect-AzlOsEventValue, Get-AzlOsConfigurationStepOrder, Get-AzlOsEventTimestamp, Write-AzlOsConfigurationEvent, Get-AzlOsStepPlan, ConvertFrom-AzlOsRetryWarning
