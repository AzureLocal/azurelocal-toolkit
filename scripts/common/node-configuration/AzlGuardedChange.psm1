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
    Send-AzlGuardEvent          The one adapter to the event feed (AzlOsConfigurationEvents.psm1 when it is loaded, else a small JSON Lines writer of the
                                same shape); every event is also kept in the sink for the report.
    Get-AzlGuardSetting         networkRollbackMinutes (confirm window), networkStableSeconds, reconnectWaitMinutes, staleRunCommandMinutes, addressProbe.

    The clock is injected ({ Now; Sleep }) so a test needs no wait.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path $PSScriptRoot 'AzlNodePayload.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeTransport.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeGuard.psm1')

$script:GuardDefaults = [ordered]@{ networkRollbackMinutes = 10; networkStableSeconds = 60; reconnectWaitMinutes = 15; staleRunCommandMinutes = 15; addressProbe = $true }

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
        Where events go: a feed file (JSON Lines; optional) and a sink (a list the report reads).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path, [System.Collections.IList]$Sink)
    # An empty list assigned from an expression would be unrolled to $null, so it is created by itself.
    $list = $Sink
    if ($null -eq $list) { $list = [System.Collections.Generic.List[object]]::new() }
    [pscustomobject]@{ Path = $Path; Sink = $list }
}

function Send-AzlGuardEvent {
    <#
    .SYNOPSIS
        Adds one event to the sink and, when the context has a feed path, appends it to the feed. Never throws.
    .DESCRIPTION
        When AzlOsConfigurationEvents.psm1 is loaded its Write-AzlOsConfigurationEvent writes the line; otherwise a writer of the same
        shape (timestamp, node, stage, step, state, evidence, level, nextAction, method, transport) is used. Old and new address go in the evidence and in
        the data (oldAddress, newAddress).
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
    $transportName = if ($Transport -in 'ArcRunCommand', 'WinRM') { $Transport } else { '' }
    $methodName = if ($Method -in 'Ztp', 'Iso') { $Method } else { '' }
    try {
        $entry = [ordered]@{ timestamp = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture); node = $Node; stage = 'OsConfiguration'; step = $Step; state = $State; evidence = $Evidence; level = $Level; nextAction = $NextAction; method = $methodName; transport = $transportName }
        foreach ($k in $Data.Keys) { if (-not $entry.Contains($k)) { $entry[$k] = $Data[$k] } }
        $Context.Sink.Add([pscustomobject]$entry)
        if (-not $Context.Path) { return }
        if (Get-Command Write-AzlOsConfigurationEvent -ErrorAction SilentlyContinue) {
            $null = Write-AzlOsConfigurationEvent -Path $Context.Path -Node $Node -State $State -Step $Step -Evidence $Evidence -Level $Level -NextAction $NextAction -Method $methodName -Transport $transportName -Data $Data
        }
        else {
            $line = (ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n"
            $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Context.Path))
            if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
            $stream = [System.IO.File]::Open($Context.Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try { $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
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
        Hostname (a guarded change of its own, with a restart), Network (DHCP off on the other ports, disabling unused adapters: last).
    .PARAMETER Todo
        Plan items with an Apply hashtable (id, kind, ...).
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Todo = @())
    $r = [ordered]@{ Management = @(); Vlan = @(); Inline = @(); Services = @(); Hostname = @(); Network = @() }
    foreach ($item in $Todo) {
        $a = $item.Apply
        if (-not $a) { continue }
        $group = switch ([string]$a.kind) {
            'nic-static' { if ($a.ContainsKey('management') -and $a.management) { 'Management' } else { 'Inline' } }
            'nic-vlan' { 'Vlan' }
            { $_ -in 'winrm', 'rdp', 'icmp', 'ntp', 'nic-dns' } { 'Services' }
            'hostname' { 'Hostname' }
            { $_ -in 'nic-clean', 'nic-disable' } { 'Network' }
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
    $result = [ordered]@{ Final = $false; State = 'InProgress'; Reason = [string](Get-AzlProp $s 'reason' ''); Verdict = [string](Get-AzlProp $s 'verdict' ''); Repairs = $repairs; OldAddress = [string](Get-AzlProp $s 'oldAddress' ''); NewAddress = [string](Get-AzlProp $s 'newAddress' ''); Phase = [string]$s.state }
    switch ([string]$s.state) {
        'Committed' {
            $problem = ''
            $actualHash = [string](Get-AzlProp $Status 'scriptSha256Actual' '')
            if ($ExpectedHash -and $actualHash -and $actualHash -ine $ExpectedHash) { $problem = "the staged script on the node has SHA-256 $actualHash, expected $ExpectedHash" }
            elseif ($ExpectedIp -and $Status.live) {
                $has = @($Status.live.ips | Where-Object { ([string]$_) -like "$ExpectedIp/*" }).Count
                if (-not $has) { $problem = "the node says Committed but its management port holds $(@($Status.live.ips) -join ', '), not $ExpectedIp" }
            }
            if ($problem) { $result.Final = $true; $result.State = 'Failed'; $result.Reason = "Committed could not be verified: $problem." }
            else { $result.Final = $true; $result.State = 'Committed' }
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
        [switch]$NoRestart
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
    $remote = $State.PSObject.Properties['remote'] -and $State.remote -and [string]$State.remote.winrm -eq 'Running' -and [int]$State.remote.listeners -gt 0
    $config = [ordered]@{
        changeId = $changeId; group = $Group; confirmMinutes = $confirmMinutes + $(if ($restart) { 10 } else { 0 }); stableSeconds = [int]$cfgSetting.networkStableSeconds; startDelaySeconds = 20; checkSeconds = 300; repairSeconds = 45
        probe = [bool]$cfgSetting.addressProbe; restartAfter = $restart; probeHosts = @('management.azure.com'); probeTargets = @(); vlanLinkDownSeconds = 120
        expect = [ordered]@{ mac = [string]$Spec.Management.Mac; ip = $(if ($isManagement) { $newAddress } else { '' }); prefix = $(if ($isManagement) { [int]$Spec.Management.Prefix } else { 0 }); currentIp = $oldAddress; requireGateway = ($mgmtNic.Count -gt 0 -and @($mgmtNic[0].gw | Where-Object { $_ }).Count -gt 0); winrm = [bool]$remote; vlan = 0 }
        items = $items
    }
    $scriptHash = Get-AzlGuardScriptHash -ChangeId $changeId
    $evidenceItems = ($items | ForEach-Object { $_.id }) -join ', '
    $data = { param($extra) $d = @{ changeId = $changeId; group = $Group; oldAddress = $oldAddress; newAddress = $newAddress; items = $evidenceItems }; foreach ($k in $extra.Keys) { $d[$k] = $extra[$k] }; $d }
    $out = [ordered]@{ Group = $Group; State = 'Unknown'; Reason = ''; NextAction = ''; ChangeId = $changeId; OldAddress = $oldAddress; NewAddress = $newAddress; Repairs = @(); Verdict = ''; Restarted = $restart; Address = $oldAddress; Partial = $false }
    $finish = {
        param($state, $reason, $verdict, $repairs)
        $out.State = $state; $out.Reason = $reason; $out.Verdict = $verdict; $out.Repairs = @($repairs)
        $out.NextAction = Get-AzlGuardNextAction -State $state -Node $Node -ChangeId $changeId -ConfirmMinutes $confirmMinutes -Verdict $verdict
        [pscustomobject]$out
    }

    # ---- 1. stage
    $stageError = ''
    $stage = $null
    try { $stage = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlGuardStagePayload -ChangeId $changeId) -Parameters @{ changeId = $changeId; scriptSha256 = $scriptHash; config = $config } -TimeoutSeconds 300 -Tries 1 }
    catch { $stageError = $_.Exception.Message }
    if ($stage -and $stage.PSObject.Properties['busyWith'] -and $stage.busyWith) {
        return (& $finish 'Unknown' "Change $($stage.busyWith) is still in progress on $Node (one change at a time), so this one was not staged. Wait for it to finish: its node-side state decides." '' @())
    }
    if ($stageError -and -not $isWinRm -and -not $stage) {
        # The Arc run command can end Unknown even though staging worked; the state on the node decides.
        Write-Verbose "Stage of $changeId on ${Node}: $stageError"
    }
    $cookie = if ($stage -and $stage.PSObject.Properties['cookie']) { [string]$stage.cookie } else { '' }
    $sid = if ($stage -and $stage.PSObject.Properties['machineSid']) { [string]$stage.machineSid } else { '' }
    $stagedAt = & $Clock.Now
    Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeStaged' -Transport $Transport.Kind -Evidence "Staged guarded change $changeId (${Group}: $evidenceItems) on the node; address $oldAddress -> $newAddress; the node applies, checks and waits for the confirmation (window $confirmMinutes minutes)." -Data (& $data @{ scriptSha256 = $scriptHash; stageError = $stageError })

    # ---- 2. close the session and wait
    if (Test-AzlTransportMember -Transport $Transport -Name 'CloseSession') { & $Transport.CloseSession $Transport $Node }
    $reconnectDeadline = $stagedAt.AddMinutes([double]$cfgSetting.reconnectWaitMinutes + $confirmMinutes * 0)
    $token = if ($cookie) { Get-AzlGuardToken -ChangeId $changeId -ScriptHash $scriptHash -Cookie $cookie } else { '' }
    Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NodeReconnecting' -Transport $Transport.Kind -Evidence "Waiting for $Node to answer again$(if ($isWinRm) { " on $newAddress (then $oldAddress) over WinRM port $port" } else { ' (Arc machine Connected with a newer last status change)' })." -Data (& $data @{})
    $reconnected = $false
    $lastPhase = ''
    $lastError = $stageError
    $resolved = $null
    $nodeDeadline = $null
    $nodeNow = $null
    $sawDisconnect = $false
    $lastQuietRead = $stagedAt
    while ($true) {
        $now = & $Clock.Now
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
            try {
                $status = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlGuardStatusPayload) -Parameters $parameters -TimeoutSeconds 180 -Tries 1
                if (-not $reconnected) {
                    $reconnected = $true
                    Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NodeReconnected' -Transport $Transport.Kind -Evidence "$Node answers again$(if ($address) { " on $address" })." -Data (& $data @{ address = $address; sawDisconnect = $sawDisconnect })
                }
                $resolved = Resolve-AzlGuardStatus -Status $status -ExpectedHash $scriptHash -ExpectedIp $(if ($isManagement) { $newAddress } else { '' })
                if ($status.PSObject.Properties['nowUtc'] -and $status.nowUtc -and $status.state) {
                    $nodeNow = ([datetime]::Parse([string]$status.nowUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
                    $deadlineText = [string](Get-AzlProp $status.state 'deadlineUtc' '')
                    if ($deadlineText) { $nodeDeadline = ([datetime]::Parse($deadlineText, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() }
                }
                if ($resolved.Phase -ne $lastPhase) {
                    $lastPhase = $resolved.Phase
                    if ($resolved.Phase -eq 'Verifying') { Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeVerifying' -Transport $Transport.Kind -Evidence "The node is verifying change ${changeId}: its own checks must stay green for $($cfgSetting.networkStableSeconds) seconds." -Data (& $data @{}) }
                    if ($resolved.Phase -eq 'AwaitingConfirm') { Send-AzlGuardEvent -Context $EventContext -Node $Node -State 'NetworkChangeAwaitingConfirm' -Transport $Transport.Kind -Evidence "Local checks passed on the node; the confirmation token $(if ($onNew -and $token) { 'was written through a new session' } else { 'is waiting for a session on the new address' })." -Data (& $data @{}) }
                }
                if ($resolved.Final) { break }
            }
            catch { $lastError = $_.Exception.Message }
        }
        # The node's published deadline has passed and the last read was not Committed: the node has reverted (or failed); read once more is done above.
        if ($nodeDeadline -and $nodeNow -and $nodeNow -gt $nodeDeadline.AddSeconds(60) -and $resolved -and -not $resolved.Final) { break }
        if ($now -ge $reconnectDeadline -and -not ($resolved -and $nodeDeadline -and $nodeNow -lt $nodeDeadline.AddSeconds(60))) { break }
        & $Clock.Sleep 15
        # Reading the clock once per pass keeps the nodeNow comparison honest between reads.
        if ($nodeNow) { $nodeNow = $nodeNow.AddSeconds(15) }
    }

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

Export-ModuleMember -Function Get-AzlGuardSetting, New-AzlGuardClock, New-AzlGuardEventContext, Send-AzlGuardEvent, Remove-AzlStaleRunCommand, Split-AzlGuardedAction, Test-AzlGuardNetworkPrecondition, Resolve-AzlGuardStatus, Get-AzlGuardToken, New-AzlChangeId, Invoke-AzlGuardedChange
