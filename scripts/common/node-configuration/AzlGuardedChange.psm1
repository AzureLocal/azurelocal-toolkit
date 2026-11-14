#Requires -Version 7.0
<#
.SYNOPSIS
    The orchestrator side of a guarded change: stage it on the node, close the session, wait for the node to come back, confirm the change
    through a NEW session on the NEW address, and read the node's own verdict.

.DESCRIPTION
    Invoke-AzlGuardedChange     Stage (a short script that returns at once), wait (WinRM: probe the new address, then the old one; Arc: poll
                                the Arc machine until Connected with a newer last-status change), read the state, write the confirmation token
                                while the node is in AwaitingConfirm, and return the outcome: Committed, RolledBack, Refused, Failed, or Unknown
                                (PendingReconciliation: the node could not be read; this is never reported as a failure of the change).
    Resolve-AzlGuardStatus      Pure: what a status read means.
    Split-AzlGuardedAction      Pure: which planned actions are inline and which are guarded changes, in the order they run.
    Test-AzlGuardNetworkPrecondition  Pure: DHCP-off on the other ports only when the management port has a default gateway.
    Remove-AzlStaleRunCommand   Deletes azl-osconfig-* run commands that are old and neither Succeeded nor Running.
    Send-AzlGuardEvent          The one adapter to the event feed: Write-AzlOsConfigurationEvent of AzlOsConfigurationEvents.psm1 writes the line (the same writer,
                                timestamp format and fields as the wrapper's events); every event is also kept in the sink for the report. A state that is
                                not in the feed's contract (os-configuration-design.md section 6) stays in the sink and is not written to the feed.
    Get-AzlGuardSetting         networkRollbackMinutes (confirm window), networkStableSeconds, reconnectWaitMinutes, staleRunCommandMinutes, addressProbe.

    The clock is injected ({ Now; Sleep }) so a test needs no wait.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path $PSScriptRoot 'AzlNodePayload.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeTransport.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeGuard.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlOsConfigurationEvents.psm1')

# The settings object of the guarded change. Every key can be changed by the run settings (Get-AzlGuardSetting -Setting; the wrapper scripts pass networkRollbackMinutes
# and networkStableSeconds from os_configuration.network.confirm_minutes and stable_seconds); each is registered under tools.os_configuration.guard_settings.
# A setting of the tool's own behaviour, not a choice about the deployment, so none of them is an infrastructure key.
$script:GuardDefaults = [ordered]@{ networkRollbackMinutes = 10; networkStableSeconds = 60; reconnectWaitMinutes = 15; staleRunCommandMinutes = 15; addressProbe = $true }
# The name the node resolves through the management DNS during a guarded change when the file gives no domain. The Azure Resource Manager endpoint: Azure Local must
# resolve it anyway (Learn, Azure Local firewall requirements), so a management DNS that cannot answer it is a real problem.
$script:DefaultProbeHost = 'management.azure.com'

function Get-AzlGuardSetting {
    <#
    .SYNOPSIS
        The guarded-change settings: the defaults, over which a hashtable (the run settings) wins. Throws on a value that is not valid.
    #>
    [CmdletBinding()]
    param([hashtable]$Setting)
    $result = [ordered]@{}
    foreach ($k in $script:GuardDefaults.Keys) { $result[$k] = $script:GuardDefaults[$k] }
    if ($Setting) {
        foreach ($k in @($script:GuardDefaults.Keys)) {
            if (-not $Setting.ContainsKey($k)) { continue }
            $v = $Setting[$k]
            if ($k -eq 'addressProbe') {
                if ($v -isnot [bool]) { throw "Setting addressProbe must be true or false, not '$v'." }
                $result[$k] = $v
            }
            else {
                $n = 0
                if (-not [int]::TryParse([string]$v, [ref]$n) -or $n -lt 0 -or ($k -ne 'networkStableSeconds' -and $n -lt 1)) { throw "Setting $k must be a whole number of $(if ($k -like '*Seconds') { 'seconds, 0 or more' } else { 'minutes, 1 or more' }), not '$v'." }
                $result[$k] = $n
            }
        }
    }
    return $result
}

function New-AzlGuardClock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object.')]
    <#
    .SYNOPSIS
        The real clock: Now (UTC) and Sleep (seconds). A test passes its own.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{ Now = { [datetime]::UtcNow }; Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds } }
}

# ---------------------------------------------------------------------------------------------------------------------
# Events: one adapter to the feed
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlGuardEventContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object.')]
    <#
    .SYNOPSIS
        Where events go: a feed file (JSON Lines; optional), a sink (a list the report reads) and the versions every line carries (the master file's
        schema_version and the node payload version).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path, [System.Collections.IList]$Sink, [string]$SchemaVersion = '', [string]$PayloadVersion = '1', [string]$Method = '', [string]$Phase = '')
    # An empty list assigned from an expression would be unrolled to $null, so it is created by itself.
    $list = $Sink
    if ($null -eq $list) { $list = [System.Collections.Generic.List[object]]::new() }
    [pscustomobject]@{ Path = $Path; Sink = $list; SchemaVersion = $SchemaVersion; PayloadVersion = $PayloadVersion; Method = $Method; Phase = $Phase }
}

function Send-AzlGuardEvent {
    <#
    .SYNOPSIS
        Adds one event to the sink and, when the context has a feed path, appends it to the feed. Never throws.
    .DESCRIPTION
        Write-AzlOsConfigurationEvent of AzlOsConfigurationEvents.psm1 writes the line, so a guard event has the same shape as every other event of the feed
        (timestamp, node, stage, step, state, evidence, level, nextAction, method, transport, payloadVersion, schemaVersion). Old and new address go in the
        evidence and in the data (oldAddress, newAddress).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Context,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$State,
        [string]$Step = 'Network',
        [string]$Evidence = '',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$NextAction = '',
        [string]$Transport = '',
        [hashtable]$Data = @{},
        [string]$Method = ''
    )
    if (-not $Context) { return }
    if (-not $Method -and $Context.PSObject.Properties['Method']) { $Method = [string]$Context.Method }
    $transportName = if ($Transport -in 'ArcRunCommand', 'WinRM') { $Transport } else { '' }
    $methodName = if ($Method -in 'Ztp', 'Iso') { $Method } else { '' }
    try {
        # The sink goes into the report, so its text is redacted like the feed's.
        $entry = [ordered]@{ timestamp = (Get-AzlOsEventTimestamp); runId = [string]$env:AZL_OSCONFIG_RUN_ID; node = $Node; stage = 'OsConfiguration'; step = $Step; state = $State; evidence = (Protect-AzlOsEventText -Text $Evidence); level = $Level; nextAction = (Protect-AzlOsEventText -Text $NextAction); method = $methodName; transport = $transportName }
        foreach ($k in $Data.Keys) { if (-not $entry.Contains($k)) { $entry[$k] = Protect-AzlOsEventValue -Value $Data[$k] } }
        $Context.Sink.Add([pscustomobject]$entry)
        if (-not $Context.Path) { return }
        # The feed carries the states of the one registry (Get-AzlOsConfigurationEventState); anything else stays in the sink (and so in the report).
        if (-not (Test-AzlOsConfigurationEventState -State $State)) { Write-Verbose "Event $State is not in the registry of states; kept in the report only."; return }
        $schema = if ($Context.PSObject.Properties['SchemaVersion']) { [string]$Context.SchemaVersion } else { '' }
        $payload = if ($Context.PSObject.Properties['PayloadVersion']) { [string]$Context.PayloadVersion } else { '' }
        $null = Write-AzlOsConfigurationEvent -Path $Context.Path -Node $Node -State $State -Step $Step -Evidence $Evidence -Level $Level -NextAction $NextAction -Method $methodName -Transport $transportName -PayloadVersion $payload -SchemaVersion $schema -Data $Data
    }
    catch { Write-Verbose "Event $State not written: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------------------------------------------------
# Stale run commands
# ---------------------------------------------------------------------------------------------------------------------

function Remove-AzlStaleRunCommand {
    <#
    .SYNOPSIS
        Before a node run: delete this tool's own run commands (named azl-osconfig-*) that are older than -OlderThanMinutes and neither
        Succeeded nor Running (stuck in Creating, Unknown, Failed). Nothing else is touched. Returns what was deleted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Transport,
        [Parameter(Mandatory)][string]$Node,
        [int]$OlderThanMinutes = 15,
        [object]$Clock = (New-AzlGuardClock),
        [Alias('Event')][object]$EventContext
    )
    if (-not (Test-AzlTransportMember -Transport $Transport -Name 'ListRunCommands')) { return @() }
    $now = & $Clock.Now
    $deleted = [System.Collections.Generic.List[object]]::new()
    foreach ($rc in @(& $Transport.ListRunCommands $Transport $Node)) {
        if ($rc.Name -notlike 'azl-osconfig-*') { continue }
        $state = if ($rc.ExecutionState) { $rc.ExecutionState } else { $rc.ProvisioningState }
        if ($state -in 'Succeeded', 'Running') { continue }
        if (-not $rc.CreatedUtc) { continue }
        $age = ($now - ([datetime]$rc.CreatedUtc).ToUniversalTime()).TotalMinutes
        if ($age -lt $OlderThanMinutes) { continue }
        if (-not $PSCmdlet.ShouldProcess("$Node run command $($rc.Name)", 'Delete')) { continue }
        try {
            & $Transport.DeleteRunCommand $Transport $Node $rc.Name
            $deleted.Add([pscustomobject]@{ Name = $rc.Name; State = $state; AgeMinutes = [int]$age })
            Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'StaleRunCommandDeleted' -Step 'Transport' -Transport $Transport.Kind -Level Warning -Evidence "Deleted run command $($rc.Name) (state $state, $([int]$age) minutes old); left over from an earlier run." -Data @{ runCommand = $rc.Name; runCommandState = $state; ageMinutes = [int]$age }
        }
        catch { Write-Warning "Couldn't delete the stale run command $($rc.Name) on ${Node}: $($_.Exception.Message)" }
    }
    return $deleted.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# What runs inline and what is guarded
# ---------------------------------------------------------------------------------------------------------------------

function Split-AzlGuardedAction {
    <#
    .SYNOPSIS
        Splits the planned changes into the order they run: Management (the address, gateway, DNS: a guarded change by itself), Vlan (its own
        guarded change), Inline (everything that cannot cut the node off), Services (WinRM, RDP, ICMP, time source, DNS: one guarded change),
        Hostname (a guarded change of its own, with a restart), Network (DHCP off on the other ports, disabling unused adapters, renaming the adapters whose port has os_name_override), Sbe (the SBE package files: delivered last, by hardware.sbe.delivery, not by the guarded change).
    .PARAMETER Todo
        Plan items with an Apply hashtable (id, kind, ...).
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Todo = @())
    $r = [ordered]@{ Management = @(); Vlan = @(); Inline = @(); Services = @(); Hostname = @(); Network = @(); Sbe = @() }
    foreach ($item in $Todo) {
        $a = $item.Apply
        if (-not $a) { continue }
        $group = switch ([string]$a.kind) {
            'nic-static' { if ($a.ContainsKey('management') -and $a.management) { 'Management' } else { 'Inline' } }
            'nic-vlan' { 'Vlan' }
            { $_ -in 'winrm', 'rdp', 'icmp', 'ntp', 'nic-dns' } { 'Services' }
            'hostname' { 'Hostname' }
            { $_ -in 'nic-clean', 'nic-disable', 'nic-rename' } { 'Network' }
            'sbe-file' { 'Sbe' }
            default { 'Inline' }
        }
        $r[$group] += , $item
    }
    [pscustomobject]$r
}

function Test-AzlGuardNetworkPrecondition {
    <#
    .SYNOPSIS
        Turning DHCP off on the other ports (or disabling an adapter) is allowed only while the management port has a default gateway and, when
        the transport can tell, the Arc machine is Connected. Returns Ok and a Reason that says what is missing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [Parameter(Mandatory)][object]$State, [object]$Transport, [string]$Node)
    $mgmt = @($State.nics | Where-Object { $_.mac -eq $Spec.Management.Mac } | Select-Object -First 1)
    if (-not $mgmt.Count) { return [pscustomobject]@{ Ok = $false; Reason = "No port has the management MAC $($Spec.Management.Mac), so DHCP is not turned off on the other ports." } }
    $gw = @($mgmt[0].gw | Where-Object { $_ })
    if (-not $gw.Count) { return [pscustomobject]@{ Ok = $false; Reason = "The management port ($($mgmt[0].n)) has no default gateway. Blocked: turning DHCP off on the other ports could remove the only route the node has. Give the management port its gateway first." } }
    if ($Transport -and (Test-AzlTransportMember -Transport $Transport -Name 'Machine')) {
        $machine = & $Transport.Machine $Transport $Node
        if ($machine.Found -and $machine.Status -ne 'Connected') { return [pscustomobject]@{ Ok = $false; Reason = "The Arc machine is $($machine.Status), not Connected. Blocked: the Arc agent's route is not confirmed, so DHCP is not turned off on the other ports." } }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# ---------------------------------------------------------------------------------------------------------------------
# Reading the node's verdict
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlGuardStatus {
    <#
    .SYNOPSIS
        What a status read means. Pure. Final is true when the state will not change again (or cannot be trusted): Committed, RolledBack, Refused, Failed,
        or an identity or hash mismatch.
    .OUTPUTS
        Final, State (Committed|RolledBack|Refused|Failed|InProgress|NotFound), Reason, Verdict, Repairs, OldAddress, NewAddress, Phase.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Status, [string]$ExpectedHash = '', [string]$ExpectedIp = '')
    if (-not $Status -or -not $Status.PSObject.Properties['found'] -or -not $Status.found) {
        return [pscustomobject]@{ Final = $false; State = 'NotFound'; Reason = 'the node has no state for this change yet'; Verdict = ''; Repairs = @(); OldAddress = ''; NewAddress = ''; Phase = 'NotFound' }
    }
    if ($Status.PSObject.Properties['unreadable'] -and $Status.unreadable) {
        return [pscustomobject]@{ Final = $false; State = 'InProgress'; Reason = 'the state file is being written'; Verdict = ''; Repairs = @(); OldAddress = ''; NewAddress = ''; Phase = 'Unreadable' }
    }
    if ($Status.PSObject.Properties['identityOk'] -and -not $Status.identityOk) {
        return [pscustomobject]@{ Final = $true; State = 'Refused'; Reason = 'The node that answered is not the node that was staged (the node cookie or the machine SID differs). Nothing was confirmed. Check which machine has this address.'; Verdict = ''; Repairs = @(); OldAddress = ''; NewAddress = ''; Phase = 'IdentityMismatch' }
    }
    $s = $Status.state
    $repairs = @(Get-AzlProp $s 'repairs' @() | Where-Object { $_ })
    $result = [ordered]@{ Final = $false; State = 'InProgress'; Reason = [string](Get-AzlProp $s 'reason' ''); Verdict = [string](Get-AzlProp $s 'verdict' ''); Repairs = $repairs; OldAddress = [string](Get-AzlProp $s 'oldAddress' ''); NewAddress = [string](Get-AzlProp $s 'newAddress' ''); Phase = [string]$s.state; Partial = $false }
    switch ([string]$s.state) {
        'Committed' {
            $problem = ''
            $actualHash = [string](Get-AzlProp $Status 'scriptSha256Actual' '')
            $live = Get-AzlProp $Status 'live' $null
            if ($ExpectedHash -and $actualHash -and $actualHash -ine $ExpectedHash) { $problem = "the staged script on the node has SHA-256 $actualHash, expected $ExpectedHash" }
            elseif ($ExpectedIp -and $live) {
                $has = @(Get-AzlProp $live 'ips' @() | Where-Object { ([string]$_) -like "$ExpectedIp/*" }).Count
                if (-not $has) { $problem = "the node says Committed but its management port holds $(@(Get-AzlProp $live 'ips' @()) -join ', '), not $ExpectedIp" }
            }
            if ($problem) { $result.Final = $true; $result.State = 'Failed'; $result.Reason = "Committed could not be verified: $problem." }
            else {
                $result.Final = $true; $result.State = 'Committed'
                # The early answer of the status script (partial = true) has the node's own state and identity but not the script hash or the live port: they were not read.
                if ([bool](Get-AzlProp $Status 'partial' $false)) { $result.Partial = $true; $result.Reason = "$($result.Reason) [early answer: the node's own state and identity were read; the script hash and the live port were not]".Trim() }
            }
        }
        { $_ -in 'RolledBack', 'Refused', 'Failed' } { $result.Final = $true; $result.State = [string]$s.state }
    }
    [pscustomobject]$result
}

function Get-AzlGuardToken {
    # SHA-256 of '<changeId>:<script SHA-256>:<node cookie>', the confirmation token the node compares with its own.
    param([string]$ChangeId, [string]$ScriptHash, [string]$Cookie)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes("${ChangeId}:${ScriptHash}:${Cookie}")
    return ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '')
}

function New-AzlChangeId {
    # Seam: a test replaces it.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if ($PSCmdlet.ShouldProcess('change id', 'Create')) { return [guid]::NewGuid().ToString('N').Substring(0, 12) }
}

function Get-AzlGuardNextAction {
    param([string]$State, [string]$Node, [string]$ChangeId, [int]$ConfirmMinutes, [string]$Verdict = '')
    $log = "C:\ProgramData\AzureLocal\osconfig\net-$ChangeId\$ChangeId.log"
    switch ($State) {
        'RolledBack' { return "The node was put back as it was$(if ($Verdict) { " ($Verdict)" }). Read $log on $Node, fix the cause (address in use, wrong gateway, VLAN, a firewall between this host and the new address) and run again. A rolled back change is not retried automatically." }
        'Refused' { return "Nothing was changed on $Node. Fix what the reason names and run again." }
        'Failed' { return "$Node needs attention at the console (BMC, iDRAC, iLO): the restore was not verified. Its watchdog keeps trying; read $log." }
        'Unknown' { return "$Node could not be read, so the outcome is PendingReconciliation, not a failure. Its watchdog reverts the change by itself if it was not confirmed within $ConfirmMinutes minutes. Check the route to the node, then run the OS configuration again: it reads change $ChangeId first." }
        default { return '' }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The last guarded change on a node, read only
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlLastGuardedChange {
    <#
    .SYNOPSIS
        What the node says about its newest guarded change: state, reason, the checks' verdict, the repairs and the last lines of the node-side log. Writes nothing.
    .DESCRIPTION
        Runs the read-only status script (Get-AzlGuardStatusPayload) with no change id (the node answers for its newest), no acknowledgement token and no
        management MAC, so it cannot confirm a change, cannot write the acknowledgement file and does not touch the network. Plan and Apply both use it, so
        a report always says what the node did with the last change, even when this run changed nothing. Never throws: a node that cannot be read comes back
        with Readable false and the error, because the report is most needed when something went wrong.
    .OUTPUTS
        Found, Readable, Error, ChangeId, Group, State, Reason, Verdict, Checks, Repairs, OldAddress, NewAddress, UpdatedUtc, Watchdog, Log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][string]$Node, [int]$LogLines = 20, [int]$TimeoutSeconds = 30,
        # The circuit breaker of the run (a hashtable with StatusTimedOut): once a status call timed out in this run, this read gets a 15 s timeout (a 30 s cap) instead of 30 s (45 s).
        [hashtable]$Breaker
    )
    if ($Breaker -and $Breaker.ContainsKey('StatusTimedOut') -and $Breaker.StatusTimedOut) { $TimeoutSeconds = [Math]::Min($TimeoutSeconds, 15) }
    $none = [ordered]@{ Found = $false; Readable = $true; Error = ''; ChangeId = ''; Group = ''; State = ''; Reason = ''; Verdict = ''; Checks = @(); Repairs = @(); OldAddress = ''; NewAddress = ''; UpdatedUtc = ''; Watchdog = $false; Log = @() }
    try {
        $status = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlGuardStatusPayload) -Parameters @{ logTail = $LogLines } -TimeoutSeconds $TimeoutSeconds -Tries 1 -Kind GuardStatus
    }
    catch {
        $none.Readable = $false; $none.Error = $_.Exception.Message
        return [pscustomobject]$none
    }
    if (-not $status -or -not (Get-AzlProp $status 'found' $false)) { return [pscustomobject]$none }
    if (Get-AzlProp $status 'unreadable' $false) { $none.Found = $true; $none.Readable = $false; $none.Error = 'the state file is being written'; $none.ChangeId = [string](Get-AzlProp $status 'changeId' ''); return [pscustomobject]$none }
    $s = Get-AzlProp $status 'state'
    $none.Found = $true
    $none.ChangeId = [string](Get-AzlProp $s 'changeId' '')
    $none.Group = [string](Get-AzlProp $s 'group' '')
    $none.State = [string](Get-AzlProp $s 'state' '')
    $none.Reason = [string](Get-AzlProp $s 'reason' '')
    $none.Verdict = [string](Get-AzlProp $s 'verdict' '')
    $none.Checks = @(Get-AzlProp $s 'checks' @() | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = [string]$_.name; ok = [bool]$_.ok; detail = [string]$_.detail } })
    $none.Repairs = @(Get-AzlProp $s 'repairs' @() | Where-Object { $_ } | ForEach-Object { [ordered]@{ rung = [string]$_.rung; item = [string](Get-AzlProp $_ 'item' ''); ok = [bool]$_.ok; detail = [string]$_.detail } })
    $none.OldAddress = [string](Get-AzlProp $s 'oldAddress' '')
    $none.NewAddress = [string](Get-AzlProp $s 'newAddress' '')
    $none.UpdatedUtc = [string](Get-AzlProp $s 'updatedUtc' '')
    $none.Watchdog = [bool](Get-AzlProp $s 'watchdog' $false)
    $none.Log = @(Get-AzlProp $status 'log' @() | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Select-Object -Last $LogLines)
    return [pscustomobject]$none
}

function ConvertTo-AzlGuardReportEntry {
    <#
    .SYNOPSIS
        The guard entries of one node's report: this run's outcomes, each with the node's own record when it is the same change, and the node's last change
        as its own entry (source node) when this run did not make it. Pure.
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$Outcome = @(), [AllowNull()][object]$Last)
    $entries = [System.Collections.Generic.List[object]]::new()
    $matched = $false
    foreach ($o in @($Outcome | Where-Object { $_ })) {
        $same = $Last -and (Get-AzlProp $Last 'Found' $false) -and [string]$Last.ChangeId -eq [string]$o.ChangeId
        if ($same) { $matched = $true }
        $repairs = if ($same) { @($Last.Repairs | ForEach-Object { $_.rung }) } else { @($o.Repairs | ForEach-Object { if ($_.PSObject.Properties['rung']) { $_.rung } else { $_ } }) }
        $entries.Add([ordered]@{
                source = 'run'; changeId = [string]$o.ChangeId; group = [string]$o.Group; state = [string]$o.State; reason = [string]$o.Reason; nextAction = [string]$o.NextAction
                oldAddress = [string]$o.OldAddress; newAddress = [string]$o.NewAddress; verdict = $(if ($same -and $Last.Verdict) { [string]$Last.Verdict } else { [string]$o.Verdict })
                repairs = @($repairs); checks = @($(if ($same) { $Last.Checks } else { @() })); updatedUtc = $(if ($same) { $Last.UpdatedUtc } else { '' }); log = @($(if ($same) { $Last.Log } else { @() }))
            })
    }
    if ($Last -and -not $matched) {
        if (Get-AzlProp $Last 'Found' $false) {
            $entries.Add([ordered]@{
                    source = 'node'; changeId = [string]$Last.ChangeId; group = [string]$Last.Group; state = $(if ($Last.Readable) { [string]$Last.State } else { 'Unreadable' }); reason = $(if ($Last.Readable) { [string]$Last.Reason } else { [string]$Last.Error })
                    nextAction = ''; oldAddress = [string]$Last.OldAddress; newAddress = [string]$Last.NewAddress; verdict = [string]$Last.Verdict; repairs = @($Last.Repairs | ForEach-Object { $_.rung })
                    checks = @($Last.Checks); updatedUtc = [string]$Last.UpdatedUtc; log = @($Last.Log)
                })
        }
        elseif (-not (Get-AzlProp $Last 'Readable' $true)) {
            $entries.Add([ordered]@{ source = 'node'; changeId = ''; group = ''; state = 'Unreadable'; reason = [string]$Last.Error; nextAction = 'Read the node again; its last guarded change could not be read.'; oldAddress = ''; newAddress = ''; verdict = ''; repairs = @(); checks = @(); updatedUtc = ''; log = @() })
        }
    }
    return $entries.ToArray()
}

function Format-AzlGuardSummary {
    <#
    .SYNOPSIS
        The guarded changes of a report as Markdown lines (summary.md): per node the change, its state and reason, the checks, the repairs and the node-side log. Pure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Node, [AllowNull()][object[]]$Entry = @())
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($Entry | Where-Object { $_ })) {
        # An entry from an older node script may lack fields: every one is read with a default.
        $g = { param($n, $d) Get-AzlProp $e $n $d }
        $reasonText = [string](& $g 'reason' ''); $updatedText = [string](& $g 'updatedUtc' '')
        $reason = if ($reasonText) { ": $reasonText" } else { '' }
        $updated = if ($updatedText) { ", updated $updatedText" } else { '' }
        $lines.Add("- ${Node}: change $(& $g 'changeId' '') ($(& $g 'group' '')) **$(& $g 'state' '')**$reason [$(& $g 'source' 'run')$updated]")
        if (& $g 'verdict' '') { $lines.Add("  - verdict: $(& $g 'verdict' '')") }
        foreach ($c in @(& $g 'checks' @())) { $lines.Add("  - check $($c.name): $(if ($c.ok) { 'ok' } else { 'FAILED' })$(if ($c.detail) { " ($($c.detail))" })") }
        foreach ($r in @(& $g 'repairs' @())) { $lines.Add("  - repair: $r") }
        $log = @(& $g 'log' @())
        if ($log.Count) {
            $lines.Add('  - node log (last lines):')
            foreach ($l in $log) { $lines.Add("    $l") }
        }
    }
    return $lines.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# A heartbeat for every wait
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlWaitHeartbeat {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object.')]
    <#
    .SYNOPSIS
        While the host waits for a node, one NodeWaiting event every 60 seconds says what it is waiting for, for how long and which phase it read last, so a
        silent hang cannot happen: the feed always shows the last sign of life.
    .DESCRIPTION
        Begin and End bracket a wait (they nest: the elapsed time counts from the outermost Begin), Tick is called by the wait loop as often as it likes
        and writes at most one event per interval, SetPhase records the phase read last (Read, Apply, AwaitingConfirm, ...). The clock is injected.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object]$EventContext, [Parameter(Mandatory)][string]$Node, [string]$Transport = '', [object]$Clock = (New-AzlGuardClock), [int]$IntervalSeconds = 60)
    $now = & $Clock.Now
    [pscustomobject]@{
        State    = @{ Context = $EventContext; Node = $Node; Transport = $Transport; Clock = $Clock; Interval = $IntervalSeconds; Depth = 0; Started = $now; Last = $now; Phase = ''; Waits = [System.Collections.Generic.List[string]]::new(); Count = 0 }
        SetPhase = { param($Self, [string]$Phase) $Self.State.Phase = $Phase }
        # Any other event a call wants in the feed (one per attempt of a call, the SBE delivery progress): the same context and transport as the heartbeat's own.
        Emit     = {
            param($Self, [string]$Node, [string]$State, [string]$Step, [string]$Evidence, [string]$Level, [hashtable]$Data)
            $s = $Self.State
            Send-AzlGuardEvent -Context $s.Context -Node $(if ($Node) { $Node } else { $s.Node }) -State $State -Step $Step -Transport $s.Transport -Level $(if ($Level) { $Level } else { 'Info' }) -Evidence $Evidence -Data $(if ($Data) { $Data } else { @{} })
        }
        Begin    = {
            param($Self, [string]$Waiting)
            $s = $Self.State
            if ($s.Depth -eq 0) { $t = & $s.Clock.Now; $s.Started = $t; $s.Last = $t }
            $s.Depth++
            $s.Waits.Add($Waiting)
        }
        End      = {
            param($Self)
            $s = $Self.State
            if ($s.Waits.Count) { $s.Waits.RemoveAt($s.Waits.Count - 1) }
            if ($s.Depth -gt 0) { $s.Depth-- }
        }
        Tick     = {
            param($Self, [string]$Waiting, [string]$Phase)
            $s = $Self.State
            if ($Phase) { $s.Phase = $Phase }
            $t = & $s.Clock.Now
            if (($t - $s.Last).TotalSeconds -lt $s.Interval) { return }
            $s.Last = $t
            $s.Count++
            $what = if ($Waiting) { $Waiting } elseif ($s.Waits.Count) { $s.Waits[$s.Waits.Count - 1] } else { 'the node' }
            $elapsed = [int](($t - $s.Started).TotalSeconds)
            Send-AzlGuardEvent -Context $s.Context -Node $s.Node -State 'NodeWaiting' -Step '' -Transport $s.Transport -Evidence "Still waiting for ${what} ($elapsed s so far; last phase read: $(if ($s.Phase) { $s.Phase } else { 'none yet' }))." -Data @{ waiting = $what; phase = [string]$s.Phase; elapsedSeconds = $elapsed; heartbeat = $s.Count }
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The guarded change
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlGuardedChange {
    <#
    .SYNOPSIS
        Runs one guarded change on one node and returns its outcome. Over WinRM and over Arc Run Command alike.
    .DESCRIPTION
        1. Stage: one short script puts the change on the node (script, manifest hash, desired state) and starts it detached (scheduled task as the
           backstop, mutex-guarded controller). It returns at once with the node cookie and machine SID.
        2. The session is closed. WinRM: the new address (from the master file) is probed, then the old one; Arc: the Arc machine is polled until Connected
           with a newer last-status change. Events NodeReconnecting and NodeReconnected.
        3. Every read echoes the cookie and SID. In AwaitingConfirm, on the NEW address (WinRM), the read writes the confirmation token.
        4. The outcome is the node's own final state. A read that fails or a node that does not answer is Unknown (PendingReconciliation), never a failure.
    .OUTPUTS
        Group, State (Committed|RolledBack|Refused|Failed|Unknown), Reason, NextAction, ChangeId, OldAddress, NewAddress, Repairs, Verdict, Restarted, Address.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transport,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][hashtable[]]$Item,
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$State,
        [hashtable]$Setting,
        [object]$Clock = (New-AzlGuardClock),
        [Alias('Event')][object]$EventContext,
        [scriptblock]$PortProbe,
        [switch]$NoRestart,
        # The circuit breaker of the run (a hashtable): a status call that times out sets StatusTimedOut, which shortens the reads that come after the guarded change.
        [hashtable]$Breaker
    )
    $cfgSetting = Get-AzlGuardSetting -Setting $Setting
    $confirmMinutes = [int]$cfgSetting.networkRollbackMinutes
    $isWinRm = ($Transport.Kind -eq 'WinRM')
    $port = if ($isWinRm -and (Test-AzlTransportMember -Transport $Transport -Name 'GetPort')) { [int](& $Transport.GetPort $Transport $Node) } else { 5985 }
    if (-not $PortProbe) { $PortProbe = { param($Address, $Port) (Test-AzlTcpPort -Address $Address -Port $Port -TimeoutMilliseconds 4000).Open } }
    $changeId = New-AzlChangeId
    $isManagement = ($Group -eq 'Management')
    $restart = ($Group -eq 'Hostname') -and -not $NoRestart
    $oldAddress = if ($isWinRm -and (Test-AzlTransportMember -Transport $Transport -Name 'GetAddress')) { [string](& $Transport.GetAddress $Transport $Node) } else { '' }
    $mgmtNic = @($State.nics | Where-Object { $_.mac -eq $Spec.Management.Mac } | Select-Object -First 1)
    if (-not $oldAddress -and $mgmtNic.Count) { $oldAddress = [string](@($mgmtNic[0].ips | Where-Object { $_ -notlike '169.254.*' } | ForEach-Object { ($_ -split '/')[0] })[0]) }
    $newAddress = if ($isManagement) { [string]$Spec.Management.Ip } else { $oldAddress }
    $items = @($Item | ForEach-Object { $copy = @{} + $_; if ($copy.kind -eq 'nic-static' -and $copy.ContainsKey('management')) { $copy.Remove('vlan') }; $copy })
    # The DNS check on the node asks the management port's DNS servers for this name; the AD domain is what the internal servers answer for.
    $probeHost = if ($Spec.PSObject.Properties['DomainFqdn'] -and [string]$Spec.DomainFqdn) { [string]$Spec.DomainFqdn } else { $script:DefaultProbeHost }
    $remote = $State.PSObject.Properties['remote'] -and $State.remote -and [string]$State.remote.winrm -eq 'Running' -and [int]$State.remote.listeners -gt 0
    $config = [ordered]@{
        changeId = $changeId; group = $Group; confirmMinutes = $confirmMinutes + $(if ($restart) { 10 } else { 0 }); stableSeconds = [int]$cfgSetting.networkStableSeconds; startDelaySeconds = 20; checkSeconds = 300; repairSeconds = 45
        probe = [bool]$cfgSetting.addressProbe; restartAfter = $restart; probeHosts = @($probeHost); probeTargets = @(); vlanLinkDownSeconds = 120
        expect = [ordered]@{ mac = [string]$Spec.Management.Mac; ip = $(if ($isManagement) { $newAddress } else { '' }); prefix = $(if ($isManagement) { [int]$Spec.Management.Prefix } else { 0 }); currentIp = $oldAddress; requireGateway = ($mgmtNic.Count -gt 0 -and @($mgmtNic[0].gw | Where-Object { $_ }).Count -gt 0); winrm = [bool]$remote; vlan = 0 }
        items = $items
    }
    $scriptHash = Get-AzlGuardScriptHash -ChangeId $changeId
    $evidenceItems = ($items | ForEach-Object { $_.id }) -join ', '
    $data = { param($extra) $d = @{ changeId = $changeId; group = $Group; oldAddress = $oldAddress; newAddress = $newAddress; items = $evidenceItems }; foreach ($k in $extra.Keys) { $d[$k] = $extra[$k] }; $d }
    $out = [ordered]@{ Group = $Group; State = 'Unknown'; Reason = ''; NextAction = ''; ChangeId = $changeId; OldAddress = $oldAddress; NewAddress = $newAddress; Repairs = @(); Verdict = ''; Restarted = $restart; Address = $oldAddress; Partial = $false; Staged = $true; SettledAfterUtc = $null }
    $finish = {
        param($state, $reason, $verdict, $repairs)
        $out.State = $state; $out.Reason = $reason; $out.Verdict = $verdict; $out.Repairs = @($repairs)
        $out.NextAction = Get-AzlGuardNextAction -State $state -Node $Node -ChangeId $changeId -ConfirmMinutes $confirmMinutes -Verdict $verdict
        [pscustomobject]$out
    }

    # ---- 1. stage
    $stageError = ''
    $stage = $null
    try { $stage = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlGuardStagePayload -ChangeId $changeId) -Parameters @{ changeId = $changeId; scriptSha256 = $scriptHash; config = $config } -TimeoutSeconds 60 -Tries 1 -Kind GuardStage }
    catch { $stageError = $_.Exception.Message }
    if ($stage -and $stage.PSObject.Properties['busyWith'] -and $stage.busyWith) {
        $out.Staged = $false
        return (& $finish 'Unknown' "Change $($stage.busyWith) is still in progress on $Node (one change at a time), so this one was not staged. Wait for it to finish: its node-side state decides." '' @())
    }
    if ($stageError -and -not $isWinRm -and -not $stage) {
        # The Arc run command can end Unknown even though staging worked; the state on the node decides.
        Write-Verbose "Stage of $changeId on ${Node}: $stageError"
    }
    $cookie = if ($stage -and $stage.PSObject.Properties['cookie']) { [string]$stage.cookie } else { '' }
    $sid = if ($stage -and $stage.PSObject.Properties['machineSid']) { [string]$stage.machineSid } else { '' }
    $stagedAt = & $Clock.Now
    # After the node's own confirm window (plus a minute) its state is final, committed or rolled back: a read of the node then says what the change did, whatever the status could say.
    $out.SettledAfterUtc = $stagedAt.AddMinutes([double]$config.confirmMinutes + 1)
    Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeStaged' -Transport $Transport.Kind -Evidence "Staged guarded change $changeId (${Group}: $evidenceItems) on the node; address $oldAddress -> $newAddress; the node applies, checks and waits for the confirmation (window $confirmMinutes minutes)." -Data (& $data @{ scriptSha256 = $scriptHash; stageError = $stageError })

    # ---- 2. close the session and wait
    if (Test-AzlTransportMember -Transport $Transport -Name 'CloseSession') { & $Transport.CloseSession $Transport $Node }
    # A hard deadline on the HOST's clock: the wait never outlasts reconnectWaitMinutes, whatever the node's clock says (a frozen or wrong node clock, a slow read).
    $reconnectDeadline = $stagedAt.AddMinutes([double]$cfgSetting.reconnectWaitMinutes)
    $lastNow = $stagedAt
    $token = if ($cookie) { Get-AzlGuardToken -ChangeId $changeId -ScriptHash $scriptHash -Cookie $cookie } else { '' }
    Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NodeReconnecting' -Transport $Transport.Kind -Evidence "Waiting for $Node to answer again$(if ($isWinRm) { " on $newAddress (then $oldAddress) over WinRM port $port" } else { ' (Arc machine Connected with a newer last status change)' })." -Data (& $data @{})
    $reconnected = $false
    $lastPhase = ''
    Send-AzlTransportHeartbeat -Transport $Transport -Action Begin -Text "$Node to answer again after change $changeId"
    $lastError = $stageError
    $resolved = $null
    $nodeDeadline = $null
    $nodeNow = $null
    $sawDisconnect = $false
    $lastQuietRead = $stagedAt
    # The confirmation token has been written for the AwaitingConfirm the host last saw (by the status read itself or by the ack-only call): it is not sent again for that phase.
    $ackSent = $false
    while ($true) {
        $now = & $Clock.Now
        # The node's clock between two reads moves by the time that really passed on the host, not by what a sleep was asked for.
        if ($nodeNow -and $now -gt $lastNow) { $nodeNow = $nodeNow.Add($now - $lastNow) }
        $lastNow = $now
        $address = ''
        $readNow = $false
        if ($isWinRm) {
            foreach ($candidate in @($newAddress, $oldAddress | Where-Object { $_ } | Select-Object -Unique)) {
                if (& $PortProbe $candidate $port) { $address = $candidate; break }
            }
            if ($address) {
                if (Test-AzlTransportMember -Transport $Transport -Name 'SetAddress') { & $Transport.SetAddress $Transport $Node $address }
                $out.Address = $address
                $readNow = $true
            }
        }
        else {
            $machine = if (Test-AzlTransportMember -Transport $Transport -Name 'Machine') { & $Transport.Machine $Transport $Node } else { $null }
            if ($machine) {
                if ($machine.Status -ne 'Connected') { $sawDisconnect = $true }
                $newer = $machine.LastStatusChange -and ([datetime]$machine.LastStatusChange).ToUniversalTime() -gt $stagedAt
                if ($machine.Status -eq 'Connected' -and $newer) { $readNow = $true }
                # The connection may never have dropped (the Arc service marks a machine Disconnected only after missed heartbeats): look anyway now and then.
                elseif ($machine.Status -eq 'Connected' -and ($now - $lastQuietRead).TotalSeconds -ge 120) { $readNow = $true; $lastQuietRead = $now }
            }
        }
        if ($readNow) {
            $onNew = (-not $isManagement) -or (-not $isWinRm) -or ($address -eq $newAddress)
            $parameters = @{ changeId = $changeId; mac = [string]$Spec.Management.Mac; cookie = $cookie; machineSid = $sid }
            if ($onNew -and $token) { $parameters.ackToken = $token }
            # The state is known to be AwaitingConfirm and only the token is missing: the tiny ack script writes it (no log, no hash, no adapter query), and the next pass reads the state.
            $ackOnly = ($lastPhase -eq 'AwaitingConfirm') -and $onNew -and $token -and -not $ackSent
            try {
                if ($ackOnly) {
                    $ackSent = $true
                    $ackResult = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlGuardAckPayload) -Parameters @{ changeId = $changeId; cookie = $cookie; machineSid = $sid; ackToken = $token } -TimeoutSeconds 30 -Tries 1 -Kind GuardAck
                    if (-not (Get-AzlProp $ackResult 'written' $false)) { $lastError = "the acknowledgement was not written: $(Get-AzlProp $ackResult 'why' 'no reason given')" }
                }
                else {
                    $status = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlGuardStatusPayload) -Parameters $parameters -TimeoutSeconds 30 -Tries 1 -Kind GuardStatus
                    if (-not $reconnected) {
                        $reconnected = $true
                        Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NodeReconnected' -Transport $Transport.Kind -Evidence "$Node answers again$(if ($address) { " on $address" })." -Data (& $data @{ address = $address; sawDisconnect = $sawDisconnect })
                    }
                    if ($Breaker -and (Get-AzlProp $status 'azlRecoveredFromTimeout' $false)) { $Breaker.StatusTimedOut = $true }
                    $resolved = Resolve-AzlGuardStatus -Status $status -ExpectedHash $scriptHash -ExpectedIp $(if ($isManagement) { $newAddress } else { '' })
                    if ($status.PSObject.Properties['nowUtc'] -and $status.nowUtc -and $status.state) {
                        $nodeNow = ([datetime]::Parse([string]$status.nowUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
                        $deadlineText = [string](Get-AzlProp $status.state 'deadlineUtc' '')
                        if ($deadlineText) { $nodeDeadline = ([datetime]::Parse($deadlineText, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() }
                        $lastNow = & $Clock.Now
                    }
                    # A status read that carried the token while the node was AwaitingConfirm has written it (ackWritten): the ack-only call is not needed for that phase.
                    if ($resolved.Phase -ne 'AwaitingConfirm') { $ackSent = $false }
                    elseif (Get-AzlProp $status 'ackWritten' $false) { $ackSent = $true }
                    if ($resolved.Phase -ne $lastPhase) {
                        $lastPhase = $resolved.Phase
                        if ($resolved.Phase -eq 'Verifying') { Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeVerifying' -Transport $Transport.Kind -Evidence "The node is verifying change ${changeId}: its own checks must stay green for $($cfgSetting.networkStableSeconds) seconds." -Data (& $data @{}) }
                        if ($resolved.Phase -eq 'AwaitingConfirm') { Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeAwaitingConfirm' -Transport $Transport.Kind -Evidence "Local checks passed on the node; the confirmation token $(if ($onNew -and $token) { 'was written through a new session' } else { 'is waiting for a session on the new address' })." -Data (& $data @{}) }
                    }
                    if ($resolved.Final) { break }
                }
            }
            catch {
                $lastError = $_.Exception.Message
                if ($Breaker -and $_.Exception.Data['AzlState'] -eq 'Indeterminate') { $Breaker.StatusTimedOut = $true }
            }
        }
        # The node's published deadline has passed and the last read was not Committed: the node has reverted (or failed); read once more is done above.
        if ($nodeDeadline -and $nodeNow -and $nodeNow -gt $nodeDeadline.AddSeconds(60) -and $resolved -and -not $resolved.Final) { break }
        # The hard stop. The clock is read again here: a read can take minutes, and the stale $now from the top of the pass must not hide that.
        if ((& $Clock.Now) -ge $reconnectDeadline) { break }
        Send-AzlTransportHeartbeat -Transport $Transport -Action Tick -Text "$Node to answer again after change $changeId" -Phase $(if ($lastPhase) { $lastPhase } elseif ($resolved) { [string]$resolved.Phase } else { 'no state read yet' })
        & $Clock.Sleep 15
    }

    Send-AzlTransportHeartbeat -Transport $Transport -Action End
    # ---- 3. the outcome
    if (-not $resolved -or -not $resolved.Final) {
        $what = if ($resolved) { "last state read: $($resolved.Phase)" } else { "no state could be read ($lastError)" }
        $reason = "$Node did not give a final state within $($cfgSetting.reconnectWaitMinutes) minutes ($what)."
        Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NodeReconnecting' -Level Warning -Transport $Transport.Kind -Evidence "PendingReconciliation: $reason" -NextAction (Get-AzlGuardNextAction -State 'Unknown' -Node $Node -ChangeId $changeId -ConfirmMinutes $confirmMinutes) -Data (& $data @{ pendingReconciliation = $true })
        return (& $finish 'Unknown' $reason '' @())
    }
    $repairsOk = @($resolved.Repairs | Where-Object { $_.ok })
    switch ($resolved.State) {
        'Committed' {
            Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeCommitted' -Transport $Transport.Kind -Evidence "Change ${changeId} committed on ${Node}: $($resolved.Reason) Address $oldAddress -> $newAddress." -Data (& $data @{})
            if ($repairsOk.Count) { Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeRepaired' -Level Warning -Transport $Transport.Kind -Evidence "The node repaired itself during change ${changeId}: rung $((@($repairsOk | ForEach-Object { $_.rung }) -join ', '))." -Data (& $data @{ rung = @($repairsOk | ForEach-Object { $_.rung }) }) }
            if ($isWinRm -and $isManagement -and (Test-AzlTransportMember -Transport $Transport -Name 'SetAddress')) { & $Transport.SetAddress $Transport $Node $newAddress; $out.Address = $newAddress }
            return (& $finish 'Committed' $resolved.Reason $resolved.Verdict $resolved.Repairs)
        }
        'RolledBack' {
            Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeRolledBack' -Level Warning -Transport $Transport.Kind -Evidence "Change ${changeId} on ${Node} was rolled back by the node: $($resolved.Reason) Address stays $oldAddress (wanted $newAddress)." -NextAction (Get-AzlGuardNextAction -State 'RolledBack' -Node $Node -ChangeId $changeId -ConfirmMinutes $confirmMinutes -Verdict $resolved.Verdict) -Data (& $data @{ verdict = $resolved.Verdict; rungs = @($repairsOk | ForEach-Object { $_.rung }) })
            if ($repairsOk.Count) { Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeRepaired' -Level Warning -Transport $Transport.Kind -Evidence "The node tried to repair itself during change ${changeId}: rung $((@($repairsOk | ForEach-Object { $_.rung }) -join ', '))." -Data (& $data @{ rung = @($repairsOk | ForEach-Object { $_.rung }) }) }
            if ($isWinRm -and $out.Address -ne $oldAddress -and (Test-AzlTransportMember -Transport $Transport -Name 'SetAddress')) { & $Transport.SetAddress $Transport $Node $oldAddress; $out.Address = $oldAddress }
            return (& $finish 'RolledBack' $resolved.Reason $resolved.Verdict $resolved.Repairs)
        }
        'Refused' {
            Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeRefused' -Level Warning -Transport $Transport.Kind -Evidence "Change $changeId on $Node was refused: $($resolved.Reason)" -NextAction (Get-AzlGuardNextAction -State 'Refused' -Node $Node -ChangeId $changeId -ConfirmMinutes $confirmMinutes) -Data (& $data @{})
            return (& $finish 'Refused' $resolved.Reason $resolved.Verdict $resolved.Repairs)
        }
        default {
            Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NodeFailed' -Level Error -Transport $Transport.Kind -Evidence "Change ${changeId} on ${Node}: $($resolved.Reason)" -NextAction (Get-AzlGuardNextAction -State 'Failed' -Node $Node -ChangeId $changeId -ConfirmMinutes $confirmMinutes) -Data (& $data @{ verdict = $resolved.Verdict })
            return (& $finish 'Failed' $resolved.Reason $resolved.Verdict $resolved.Repairs)
        }
    }
}

function Get-AzlPendingGuardState {
    <#
    .SYNOPSIS
        Reads, once and without changing anything, what the node says about guarded changes whose outcome an earlier call could not read (state Unknown). No
        confirmation token and no cookie are sent, so a change still awaiting its confirmation is only looked at, never confirmed.
    .OUTPUTS
        One object per change id: ChangeId, State (Committed, RolledBack, Refused, Failed, InProgress, NotFound or Unknown when the node could not be read), Final, Reason.
        Only Committed counts as reconciled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][string[]]$ChangeId, [Parameter(Mandatory)][object]$Spec,
        # A status call timed out earlier in this run (the circuit breaker): the read gets a 15 s timeout (a 30 s cap) instead of 30 s (45 s).
        [switch]$StatusTimedOut
    )
    $timeout = if ($StatusTimedOut) { 15 } else { 30 }
    foreach ($id in $ChangeId) {
        try {
            $status = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlGuardStatusPayload) -Parameters @{ changeId = $id; mac = [string]$Spec.Management.Mac } -TimeoutSeconds $timeout -Tries 1 -Kind GuardStatus
            $resolved = Resolve-AzlGuardStatus -Status $status
            [pscustomobject]@{ ChangeId = $id; State = $resolved.State; Final = [bool]$resolved.Final; Reason = $resolved.Reason }
        }
        catch { [pscustomobject]@{ ChangeId = $id; State = 'Unknown'; Final = $false; Reason = "the node could not be read: $($_.Exception.Message)" } }
    }
}

Export-ModuleMember -Function Get-AzlPendingGuardState, Get-AzlLastGuardedChange, ConvertTo-AzlGuardReportEntry, Format-AzlGuardSummary, New-AzlWaitHeartbeat, Get-AzlGuardSetting, New-AzlGuardClock, New-AzlGuardEventContext, Send-AzlGuardEvent, Remove-AzlStaleRunCommand, Split-AzlGuardedAction, Test-AzlGuardNetworkPrecondition, Resolve-AzlGuardStatus, Get-AzlGuardToken, New-AzlChangeId, Invoke-AzlGuardedChange
