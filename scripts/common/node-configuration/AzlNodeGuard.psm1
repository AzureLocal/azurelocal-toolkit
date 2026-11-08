#Requires -Version 7.0
<#
.SYNOPSIS
    The node-side GUARDED CHANGE: a script that is staged on a node, runs there detached from the session that started it, checks
    the node still works after each change, repairs what it can, and rolls the node back to a snapshot when it can't.

.DESCRIPTION
    Why. A change to the management address, the gateway, DNS, VLAN, a firewall rule, WinRM, the time source, an unused adapter, DHCP
    on another port or the computer name can cut the connection the change was started over. If the change ran inside that
    connection, nobody would know what happened. So the session only STAGES the change; the node runs it and judges it.

    Get-AzlGuardScriptText   The exact text of the file staged on the node (net-<id>.ps1): a header, the engine and one call.
                             Its SHA-256 goes into the state file, and the engine refuses to run when the file differs.
    Get-AzlGuardStagePayload The script a session runs to stage a change: writes the script, the config and the first state,
                             registers the WATCHDOG (scheduled task: at startup and every minute) and starts it. Returns at once.
    Get-AzlGuardStatusPayload  A short read-only script: the state file, the tail of the log, the live configuration of the
                             management port, the staged file's SHA-256. With ack set it also writes the acknowledgement file.
    Get-AzlGuardEngine       The engine text (Windows PowerShell 5.1 syntax). A host test dot-sources it and injects fake node
                             operations with Set-GuardOps, so every rung of the ladders runs without a node.

    The state machine (net-<id>.state.json plus a copy and checksum files; log <id>.log; in an immutable directory per change under
    C:\ProgramData\AzureLocal\osconfig, ACL SYSTEM and Administrators):

      Staged -> Snapshotted -> Applying -> Verifying -> AwaitingConfirm -> Committed
        |           |             |           |  ^            |
      Refused     (revert)    Repairing ------+--+            +--> RolledBack  (no confirmation inside confirm_minutes)
                                  |
                                  +--> RolledBack (an undoing rung or the whole snapshot)   Failed (revert unverified; the watchdog stays armed)

    One controller owns every mutation: the payload process takes the machine-wide mutex Global\AzureLocalOsConfig and is the supervisor; the
    scheduled task (at startup and every minute, no execution time limit, restart on failure) is only the backstop that starts the same script
    again after a crash or a reboot. State writes are fenced by a generation number and flushed before the next mutation; a busy file is retried,
    not treated as corrupt. The node owns its deadlines (monotonic tick count while the boot is the same, UTC for display).

    A change is committed only after BOTH proofs: the node's local checks stay green for stable_seconds (Verifying), and the orchestrator writes the
    confirmation token through a new session on the new address while the state is AwaitingConfirm (AwaitingConfirm accepts it only under the mutex).
    The token is SHA-256 of '<changeId>:<script SHA-256>:<node cookie>'; the cookie and the machine SID are recorded at staging and echoed by every
    later read. A token that arrives after the rollback started is recorded as RolledBackLateConfirm and the rollback is finished.
    The management address change ADDS the new address and route first, waits for AddressState Preferred (Duplicate means refuse and revert, never
    re-apply), keeps the old address until the confirmation, and removes it afterwards (FinalizeItem). A revert restores a STATIC configuration from
    the snapshot. A panic document (static config by MAC, adapters enabled, WinRM listener, link-local firewall rule) is written before any mutation
    and run when the structured restore throws or the checks still fail after it. Verdicts: RolledBackVerified, or RollbackUnverified (state Failed).
    Refused: the plan would disable the management port or the port holding the default gateway; the management port is an LBFO team member or a
    vSwitch uplink, or the MAC is not on the interface that owns the current address; another host answers on the address (ping, neighbour cache) or
    duplicate address detection says Duplicate; a VLAN change is not alone or the driver reports no VLAN capability; the staged file's hash differs
    from the manifest; no port has the MAC. The computer name is its own change, after the network change is Committed; it stays in Applying with
    rebootExpected set before the restart, and startup resumes that change.

    Checks after the change (every check that passed BEFORE must pass; address and ports always; arc is evidence only; ICMP and the local subnet are not predicates):
      address   the management port has the expected address (AddressState Preferred), prefix, VLAN and a default gateway
      gateway   the gateway resolves to a MAC on the management port and a configured TCP probe answers through that interface
      dns       a name resolves
      winrm     WinRM is listening, if it was before
      ports     the ports that were cleaned have no address and no default route
      arc       the Arc agent service runs and reports Connected (evidence)
    Repair ladder, each rung followed by a re-check: ReProbe (one more look, no change) -> RestartArcAgent (only if Arc was in use) -> RestoreItem (the
    failing item only) -> ReEnableAdapter -> the whole snapshot (RolledBack). No re-apply and no NIC restart: after a failed probe the next step is a restore.

    The node text is Windows PowerShell 5.1 syntax (no ternary, ??, &&). Everything that touches the node goes through
    Invoke-GuardOp, so only New-GuardRealOps (not run on a host) calls Windows cmdlets.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AzlNodePayload.psm1')

$script:StateDirectory = 'C:\ProgramData\AzureLocal\osconfig'

$script:EngineBody = @'
# AZL-GUARD-ENGINE
$script:GuardOps = $null
$script:GuardInstance = [guid]::NewGuid().ToString('N')
$script:GuardReboot = $false

function Get-GuardProp($o, [string]$n, $d = $null) {
    if ($null -eq $o) { return $d }
    if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n) -and $null -ne $o[$n]) { return $o[$n] }; return $d }
    if ($o.PSObject.Properties[$n]) { $v = $o.PSObject.Properties[$n].Value; if ($null -ne $v) { return $v } }
    return $d
}
function Set-GuardProp($o, [string]$n, $v) { Add-Member -InputObject $o -NotePropertyName $n -NotePropertyValue $v -Force }
function ConvertTo-GuardTime($s) {
    if ($s -is [datetime]) { if ($s.Kind -eq 'Unspecified') { return [datetime]::SpecifyKind($s, [DateTimeKind]::Utc) }; return $s.ToUniversalTime() }
    return [datetime]::Parse([string]$s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Set-GuardOps([hashtable]$Ops) { $script:GuardOps = $Ops }
function Invoke-GuardOp([string]$Name) {
    if (-not $script:GuardOps) { $script:GuardOps = New-GuardRealOps }
    if (-not $script:GuardOps.ContainsKey($Name)) { throw ('Node operation ' + $Name + ' is not available') }
    return (& $script:GuardOps[$Name] @args)
}
function Get-GuardNow { return [datetime](Invoke-GuardOp Now) }
function Get-GuardFile($cfg, [string]$suffix) { return ($cfg.dir.TrimEnd('\') + '\net-' + $cfg.changeId + $suffix) }
function Write-GuardLog($cfg, [string]$text) {
    try { Invoke-GuardOp AppendText ($cfg.dir.TrimEnd('\') + '\' + $cfg.changeId + '.log') ((Get-GuardNow).ToString('o') + ' ' + $text) } catch { $null = $_ }
}

# ---- state: one JSON file written atomically, a copy, a checksum file; a generation number fences writers (compare and swap).
# A read that fails because the file is busy is retried; it is not corruption.
function Read-GuardStateFile($cfg, [string]$suffix) {
    $path = Get-GuardFile $cfg $suffix
    if (-not (Invoke-GuardOp Exists $path)) { return $null }
    for ($try = 1; $try -le 3; $try++) {
        try {
            $text = [string](Invoke-GuardOp ReadText $path)
            $sumPath = $path + '.sum'
            if (Invoke-GuardOp Exists $sumPath) {
                $sum = ([string](Invoke-GuardOp ReadText $sumPath)).Trim()
                if ($sum -cne [string](Invoke-GuardOp TextHash $text)) { Write-GuardLog $cfg ($suffix + ' fails its checksum'); return $null }
            }
            return ($text | ConvertFrom-Json)
        }
        catch {
            if ($try -lt 3) { Invoke-GuardOp Sleep 1; continue }
            Write-GuardLog $cfg ($suffix + ' could not be read: ' + $_.Exception.Message)
            return $null
        }
    }
    return $null
}
function Read-GuardState($cfg) {
    foreach ($suffix in '.state.json', '.state.copy.json') {
        $st = Read-GuardStateFile $cfg $suffix
        if ($null -ne $st) { return $st }
    }
    return $null
}
function Save-GuardState($cfg, $st) {
    $disk = Read-GuardStateFile $cfg '.state.json'
    $mine = [int](Get-GuardProp $st 'generation' 0)
    if ($disk -and [int](Get-GuardProp $disk 'generation' 0) -gt $mine) { throw ('The state changed under this script (generation ' + $disk.generation + ' on disk, ' + $mine + ' here); another writer owns the change.') }
    $now = (Get-GuardNow).ToString('o')
    Set-GuardProp $st 'generation' ($mine + 1)
    Set-GuardProp $st 'updatedUtc' $now
    Set-GuardProp $st 'heartbeatUtc' $now
    Set-GuardProp $st 'owner' $script:GuardInstance
    $json = ConvertTo-Json -InputObject $st -Depth 8
    $sum = [string](Invoke-GuardOp TextHash $json)
    foreach ($suffix in '.state.json', '.state.copy.json') {
        Invoke-GuardOp WriteText (Get-GuardFile $cfg $suffix) $json
        Invoke-GuardOp WriteText ((Get-GuardFile $cfg $suffix) + '.sum') $sum
    }
}
function Set-GuardState($cfg, $st, [string]$state, [string]$reason = '') {
    Set-GuardProp $st 'state' $state
    if ($reason) { Set-GuardProp $st 'reason' $reason }
    Write-GuardLog $cfg ('state ' + $state + $(if ($reason) { ': ' + $reason } else { '' }))
    Save-GuardState $cfg $st
}
function Remove-GuardWatchdog($cfg) {
    try { Invoke-GuardOp UnregisterWatchdog $cfg.changeId } catch { Write-GuardLog $cfg ('could not remove the watchdog: ' + $_.Exception.Message) }
}
function Complete-GuardFinal($cfg, $st, [string]$state, [string]$reason) {
    Set-GuardState $cfg $st $state $reason
    Remove-GuardWatchdog $cfg
    if ($script:GuardReboot) { Write-GuardLog $cfg 'a restored item needs a restart'; Invoke-GuardOp Reboot }
    return $state
}
# Failed is not final: the watchdog stays armed and tries the restore again at its next run.
function Set-GuardFailed($cfg, $st, [string]$reason) {
    Set-GuardState $cfg $st 'Failed' $reason
    return 'Failed'
}
function Get-GuardItemList($cfg) { return @($cfg.items) }
function Test-GuardManagementItem($i) { return ((Get-GuardProp $i 'kind' '') -eq 'nic-static' -and [bool](Get-GuardProp $i 'management' $false)) }
function Get-GuardConfirmToken($cfg, $st) { return [string](Invoke-GuardOp TextHash ([string]$cfg.changeId + ':' + [string]$st.scriptSha256 + ':' + [string](Get-GuardProp $st 'cookie' ''))) }
# Deadlines are owned by the node and measured on the monotonic clock (milliseconds since boot) while the boot is the same; the UTC time is for display and the fallback.
function Test-GuardExpired($st, [string]$UtcField, [string]$TickField) {
    $tick = Get-GuardProp $st $TickField $null
    $sameBoot = $false
    if ($null -ne $tick -and (Get-GuardProp $st 'bootUtc' '')) { $sameBoot = ([math]::Abs(((ConvertTo-GuardTime $st.bootUtc) - [datetime](Invoke-GuardOp BootTime)).TotalSeconds) -lt 5) }
    if ($sameBoot) { return ([double](Invoke-GuardOp Tick) -ge [double]$tick) }
    return ((Get-GuardNow) -ge (ConvertTo-GuardTime (Get-GuardProp $st $UtcField '2000-01-01T00:00:00Z')))
}
function Set-GuardDeadline($st, [string]$UtcField, [string]$TickField, [double]$Seconds) {
    Set-GuardProp $st $UtcField ((Get-GuardNow).AddSeconds($Seconds).ToString('o'))
    Set-GuardProp $st $TickField ([double](Invoke-GuardOp Tick) + $Seconds * 1000)
    Set-GuardProp $st 'bootUtc' (([datetime](Invoke-GuardOp BootTime)).ToUniversalTime().ToString('o'))
}

# ---- refusals: a plan that would disable the management port or the port the node is reached through
function Get-GuardRefusal($cfg, $nics) {
    $mgmt = [string](Get-GuardProp $cfg.expect 'mac' '')
    $mgmtNic = @($nics | Where-Object { $_.mac -eq $mgmt } | Select-Object -First 1)
    $mgmtGw = 0
    if ($mgmtNic.Count) { $mgmtGw = @($mgmtNic[0].gw).Count }
    $carrier = @($nics | Where-Object { @($_.gw).Count -gt 0 } | Sort-Object { [int]$_.metric } | Select-Object -First 1)
    $vlanItems = @(Get-GuardItemList $cfg | Where-Object { [string]$_.kind -eq 'nic-vlan' })
    if ($vlanItems.Count -gt 1 -or ($vlanItems.Count -eq 1 -and @(Get-GuardItemList $cfg).Count -gt 1)) { return 'A VLAN change is its own change: one VLAN mutation per change, nothing else with it. Refused.' }
    foreach ($i in (Get-GuardItemList $cfg)) {
        $kind = [string](Get-GuardProp $i 'kind' '')
        $mac = [string](Get-GuardProp $i 'mac' '')
        if ($kind -eq 'nic-disable') {
            if ($mac -eq $mgmt) { return 'The plan would disable the management port (MAC ' + $mac + '). Refused: the node would have no management path.' }
            if ($carrier.Count -and $carrier[0].mac -eq $mac) { return 'The plan would disable ' + $carrier[0].name + ', the port that holds the default gateway the node (and its Arc agent) reaches Azure through. Refused.' }
        }
        if ($kind -in 'nic-disable', 'nic-clean' -and $mac -ne $mgmt) {
            if ($mgmtNic.Count -eq 0) { return 'No port has the management MAC ' + $mgmt + ', so the change to ' + $mac + ' is refused.' }
            if ($mgmtGw -eq 0) { return 'The management port has no default gateway, so changing port ' + $mac + ' is refused until it has one.' }
            if ($kind -eq 'nic-clean' -and $carrier.Count -and $carrier[0].mac -eq $mac) { return 'Port ' + $mac + ' holds the default gateway the node reaches Azure through; DHCP-off there is refused.' }
        }
        if ($kind -eq 'nic-clean' -and $mac -eq $mgmt) { return 'The plan would remove the address and gateway of the management port. Refused.' }
        if ($kind -eq 'nic-static' -and (Test-GuardManagementItem $i) -and $mgmtNic.Count -eq 0) { return 'No port has the management MAC ' + $mgmt + '.' }
        if ($kind -eq 'nic-vlan' -and -not (Invoke-GuardOp VlanCapable $mac)) { return 'The driver of port ' + $mac + ' does not report a VLAN ID setting (capability unknown). Refused: set the VLAN on the switch port or the host by another means.' }
    }
    return [string](Invoke-GuardOp CheckTopology $cfg)
}

# ---- the self-check ladder (local proof). Arc is evidence, not a commit predicate; so are ICMP and the local subnet.
function Test-GuardChecks($cfg) {
    $results = @()
    foreach ($c in @(@('address', 'CheckAddress'), @('gateway', 'CheckGateway'), @('dns', 'CheckDns'), @('winrm', 'CheckWinRm'), @('ports', 'CheckPorts'), @('arc', 'CheckArc'))) {
        try { $r = Invoke-GuardOp $c[1] $cfg } catch { $r = @{ ok = $false; detail = $_.Exception.Message } }
        $results += New-Object psobject -Property @{ name = $c[0]; ok = [bool](Get-GuardProp $r 'ok' $false); detail = [string](Get-GuardProp $r 'detail' ''); skipped = [bool](Get-GuardProp $r 'skipped' $false) }
    }
    return $results
}
function Get-GuardRequired($st, $results) {
    # A check is required after the change when it passed before it; the address and ports checks (the intended end state) always are; arc never is.
    $baseline = @(Get-GuardProp $st 'baseline' @())
    $failed = @()
    foreach ($r in $results) {
        if ($r.ok -or $r.name -eq 'arc') { continue }
        $before = $baseline | Where-Object { $_.name -eq $r.name } | Select-Object -First 1
        if ($r.name -in 'address', 'ports' -or ($before -and $before.ok)) { $failed += $r }
    }
    return $failed
}
function Wait-GuardChecks($cfg, $st, [int]$Seconds) {
    $end = (Get-GuardNow).AddSeconds($Seconds)
    while ($true) {
        $results = Test-GuardChecks $cfg
        $failed = @(Get-GuardRequired $st $results)
        Set-GuardProp $st 'checks' @($results)
        Save-GuardState $cfg $st
        if ($failed.Count -eq 0) { return @() }
        if ((Get-GuardNow) -ge $end) { return @($failed) }
        Invoke-GuardOp Sleep 10
    }
}
# Verifying: the checks must stay green for a stable period.
function Wait-GuardStable($cfg, $st, [int]$StableSeconds, [int]$MaxSeconds) {
    $start = Get-GuardNow
    $green = $null
    $last = @()
    while ($true) {
        $results = Test-GuardChecks $cfg
        $failed = @(Get-GuardRequired $st $results)
        Set-GuardProp $st 'checks' @($results)
        Save-GuardState $cfg $st
        $now = Get-GuardNow
        if ($failed.Count -eq 0) {
            if (-not $green) { $green = $now }
            if (($now - $green).TotalSeconds -ge $StableSeconds) { return @() }
        }
        else { $green = $null; $last = $failed }
        if (($now - $start).TotalSeconds -ge $MaxSeconds) {
            if ($last.Count) { return @($last) }
            return @(New-Object psobject -Property @{ name = 'stability'; ok = $false; detail = ('the checks did not stay green for ' + $StableSeconds + ' seconds'); skipped = $false })
        }
        Invoke-GuardOp Sleep 10
    }
}

# ---- restore. The panic document is written before anything is changed and is the last resort when the structured restore fails.
function New-GuardRevertConfig($cfg, $st) {
    $c = (ConvertTo-Json -InputObject $cfg -Depth 8) | ConvertFrom-Json
    Set-GuardProp $c.expect 'ip' ''
    Set-GuardProp $c.expect 'vlan' 0
    Set-GuardProp $c.expect 'requireGateway' ([bool](Get-GuardProp $st 'gatewayBefore' $true))
    Set-GuardProp $c 'items' @()
    return $c
}
function Restore-GuardItems($cfg, $st, [string[]]$Only) {
    $failures = @()
    $items = @(Get-GuardItemList $cfg)
    [array]::Reverse($items)
    foreach ($i in $items) {
        if ($Only -and $Only.Count -and ($Only -notcontains [string]$i.id)) { continue }
        $snap = Get-GuardProp (Get-GuardProp $st 'snapshots') ([string]$i.id)
        if ($null -eq $snap) { continue }
        try {
            $needsReboot = Invoke-GuardOp RestoreItem $i $snap
            if ($needsReboot -eq $true) { $script:GuardReboot = $true }
            Write-GuardLog $cfg ('restored ' + $i.id)
            $done = @(Get-GuardProp $st 'restoredItems' @()) + [string]$i.id
            Set-GuardProp $st 'restoredItems' @($done | Select-Object -Unique)
        }
        catch { $failures += ([string]$i.id + ': ' + $_.Exception.Message); Write-GuardLog $cfg ('restore of ' + $i.id + ' FAILED: ' + $_.Exception.Message) }
    }
    return $failures
}
function Invoke-GuardPanic($cfg, $st) {
    Write-GuardLog $cfg 'running the panic restore'
    Set-GuardProp $st 'panicRun' $true
    try { Invoke-GuardOp RunPanic (Get-GuardFile $cfg '.panic.json'); return $true }
    catch { Write-GuardLog $cfg ('the panic restore failed: ' + $_.Exception.Message); return $false }
}
function Invoke-GuardFullRollback($cfg, $st, [string]$reason, [string]$FinalState = 'RolledBack') {
    $failures = @(Restore-GuardItems $cfg $st)
    if ($failures.Count) {
        Write-GuardLog $cfg ('the structured restore threw (' + ($failures -join '; ') + ')')
        $null = Invoke-GuardPanic $cfg $st
    }
    $failed = @(Wait-GuardChecks (New-GuardRevertConfig $cfg $st) $st 60)
    if ($failed.Count -and -not (Get-GuardProp $st 'panicRun' $false)) {
        Write-GuardLog $cfg ('after the restore these checks fail: ' + (($failed | ForEach-Object { $_.name }) -join ', '))
        $null = Invoke-GuardPanic $cfg $st
        $failed = @(Wait-GuardChecks (New-GuardRevertConfig $cfg $st) $st 60)
    }
    if ($failed.Count) {
        Set-GuardProp $st 'verdict' 'RollbackUnverified'
        return (Set-GuardFailed $cfg $st ($reason + ' RollbackUnverified: after the restore' + $(if ($failures.Count) { ' (' + ($failures -join '; ') + ')' } else { '' }) + ' these checks still fail: ' + (($failed | ForEach-Object { $_.name + ' (' + $_.detail + ')' }) -join '; ') + '. The watchdog stays armed and tries again; if it keeps failing the node needs console access (BMC).'))
    }
    Set-GuardProp $st 'verdict' 'RolledBackVerified'
    Set-GuardProp $st 'verified' $true
    $ackPath = Get-GuardFile $cfg '.ack'
    if ((Invoke-GuardOp Exists $ackPath) -and (([string](Invoke-GuardOp ReadText $ackPath)).Trim() -ceq (Get-GuardConfirmToken $cfg $st))) {
        Set-GuardProp $st 'lateConfirm' $true
        $reason += ' RolledBackLateConfirm: the confirmation arrived after the rollback had started; the rollback was finished.'
    }
    return (Complete-GuardFinal $cfg $st $FinalState $reason)
}

# ---- repair ladder: returns @{ recovered; undone; rung }. One re-probe, the Arc agent services (only if Arc is in use), the failing item, the disabled adapter.
# No re-apply and no NIC restart: after a failed probe the next step is a restore.
function Invoke-GuardRepair($cfg, $st, $failed) {
    $names = @($failed | ForEach-Object { $_.name })
    $settle = [int](Get-GuardProp $cfg 'repairSeconds' 45)
    $items = @(Get-GuardItemList $cfg)
    $map = @{ address = @('nic-static', 'nic-clean', 'nic-vlan'); gateway = @('nic-static', 'nic-clean', 'nic-dns', 'nic-vlan'); dns = @('nic-dns', 'nic-static'); winrm = @('winrm', 'icmp', 'rdp'); ports = @('nic-clean'); stability = @('nic-static', 'nic-clean', 'nic-dns', 'winrm') }
    $candidateKinds = @()
    foreach ($n in $names) { if ($map.ContainsKey($n)) { $candidateKinds += $map[$n] } }
    $candidateKinds = @($candidateKinds | Select-Object -Unique)
    $arcBefore = @(Get-GuardProp $st 'baseline' @() | Where-Object { $_.name -eq 'arc' -and $_.ok -and -not $_.skipped })
    $rungs = @()
    $rungs += , @('ReProbe', $null, $false)
    if ($arcBefore.Count) { $rungs += , @('RestartArcAgent', $null, $false) }
    $rev = @($items); [array]::Reverse($rev)
    foreach ($i in $rev) { if ($candidateKinds -contains [string]$i.kind) { $rungs += , @('RestoreItem', $i, $true) } }
    foreach ($i in $rev) { if ([string]$i.kind -eq 'nic-disable') { $rungs += , @('ReEnableAdapter', $i, $true) } }
    foreach ($r in $rungs) {
        $rung = $r[0]; $item = $r[1]; $undo = $r[2]
        if (Test-GuardExpired $st 'deadlineUtc' 'deadlineTick') { Write-GuardLog $cfg 'the node''s deadline has passed; going to the whole restore'; break }
        Set-GuardState $cfg $st 'Repairing' ('rung ' + $rung + $(if ($item) { ' (' + $item.id + ')' } else { '' }) + ' for ' + ($names -join ', '))
        $detail = ''
        $ok = $true
        try {
            switch ($rung) {
                'ReProbe' { Invoke-GuardOp Sleep 10; $detail = 'probed again without changing anything' }
                'RestartArcAgent' { Invoke-GuardOp RestartArcAgent; $detail = 'himds, GCArcService and ExtensionService restarted' }
                'RestoreItem' { $f = @(Restore-GuardItems $cfg $st @([string]$item.id)); if ($f.Count) { throw ($f -join '; ') }; $detail = ('snapshot of ' + $item.id + ' restored') }
                'ReEnableAdapter' { Invoke-GuardOp EnableAdapter ([string]$item.mac); $done = @(Get-GuardProp $st 'restoredItems' @()) + [string]$item.id; Set-GuardProp $st 'restoredItems' @($done | Select-Object -Unique); $detail = ('adapter ' + $item.mac + ' enabled') }
            }
        }
        catch { $ok = $false; $detail = $_.Exception.Message }
        $stillFailing = @()
        if ($ok) { $stillFailing = @(Wait-GuardChecks $cfg $st $settle) }
        $recovered = $ok -and $stillFailing.Count -eq 0
        $rec = @(Get-GuardProp $st 'repairs' @()) + (New-Object psobject -Property @{ rung = $rung; item = $(if ($item) { [string]$item.id } else { '' }); ok = $recovered; detail = $detail; utc = (Get-GuardNow).ToString('o') })
        Set-GuardProp $st 'repairs' @($rec)
        Write-GuardLog $cfg ('rung ' + $rung + ': ' + $detail + '; checks ' + $(if ($recovered) { 'pass' } else { 'still fail' }))
        Save-GuardState $cfg $st
        if ($recovered) { return @{ recovered = $true; undone = $undo; rung = $rung } }
    }
    return @{ recovered = $false; undone = $false; rung = '' }
}

# ---- Verifying -> AwaitingConfirm -> Committed
function Complete-GuardChange($cfg, $st) {
    if ([string]$st.state -ne 'AwaitingConfirm') {
        Set-GuardState $cfg $st 'Verifying'
        $stable = [int](Get-GuardProp $cfg 'stableSeconds' 60)
        $max = [math]::Max([int](Get-GuardProp $cfg 'checkSeconds' 300), $stable + 120)
        $failed = @(Wait-GuardStable $cfg $st $stable $max)
        if ($failed.Count) {
            $text = ($failed | ForEach-Object { $_.name + ': ' + $_.detail }) -join '; '
            $repair = Invoke-GuardRepair $cfg $st $failed
            if (-not $repair.recovered) { return (Invoke-GuardFullRollback $cfg $st ('Checks failed (' + $text + ') and no repair worked; the snapshot was restored.')) }
            if ($repair.undone) {
                Set-GuardProp $st 'partial' $true
                Set-GuardProp $st 'verdict' 'RolledBackVerified'
                return (Complete-GuardFinal $cfg $st 'RolledBack' ('Checks failed (' + $text + '). Rung ' + $repair.rung + ' restored ' + (@(Get-GuardProp $st 'restoredItems' @()) -join ', ') + ' and the node is healthy; the other items stay applied.'))
            }
            Set-GuardState $cfg $st 'Verifying'
            $again = @(Wait-GuardStable $cfg $st $stable $max)
            if ($again.Count) { return (Invoke-GuardFullRollback $cfg $st ('Checks failed again after the repair (' + (($again | ForEach-Object { $_.name + ': ' + $_.detail }) -join '; ') + '); the snapshot was restored.')) }
        }
        Set-GuardDeadline $st 'confirmDeadlineUtc' 'confirmDeadlineTick' ([double]$cfg.confirmMinutes * 60)
        Set-GuardState $cfg $st 'AwaitingConfirm' 'local checks passed; waiting for the orchestrator''s confirmation'
    }
    $expected = Get-GuardConfirmToken $cfg $st
    while ($true) {
        $ackPath = Get-GuardFile $cfg '.ack'
        if (Invoke-GuardOp Exists $ackPath) {
            $token = ([string](Invoke-GuardOp ReadText $ackPath)).Trim()
            if ($token -ceq $expected) { break }
            Write-GuardLog $cfg 'the confirmation file does not hold the expected token (change id, script and node cookie); ignored'
        }
        if (Test-GuardExpired $st 'confirmDeadlineUtc' 'confirmDeadlineTick') { return (Invoke-GuardFullRollback $cfg $st ('No confirmation from the orchestrator within ' + $cfg.confirmMinutes + ' minutes (it could not reach the node on its new address); the snapshot was restored.')) }
        Invoke-GuardOp Sleep 5
        Save-GuardState $cfg $st
    }
    # Accepted: the old address (kept until now) and the old route go. If that breaks the node it is restored like any other failure.
    Set-GuardProp $st 'confirmed' $true
    $finalizeError = ''
    foreach ($i in (Get-GuardItemList $cfg)) {
        try { Invoke-GuardOp FinalizeItem $i (Get-GuardProp (Get-GuardProp $st 'snapshots') ([string]$i.id)); Write-GuardLog $cfg ('finalized ' + $i.id) }
        catch { $finalizeError = $_.Exception.Message; Write-GuardLog $cfg ('finalize of ' + $i.id + ' failed: ' + $finalizeError) }
    }
    if ($finalizeError) { Set-GuardProp $st 'finalizeError' $finalizeError }
    $after = @(Wait-GuardChecks $cfg $st 30)
    if ($after.Count) { return (Invoke-GuardFullRollback $cfg $st ('After the old address was removed these checks failed: ' + (($after | ForEach-Object { $_.name + ': ' + $_.detail }) -join '; ') + '; the snapshot was restored.')) }
    $repairs = @(Get-GuardProp $st 'repairs' @() | Where-Object { $_.ok })
    $text = 'Local checks passed and the orchestrator confirmed.'
    if ($repairs.Count) { $text = 'Local checks passed after repair (' + (($repairs | ForEach-Object { $_.rung }) -join ', ') + ') and the orchestrator confirmed.' }
    return (Complete-GuardFinal $cfg $st 'Committed' $text)
}

# ---- Snapshotted -> Applying
function Start-GuardApply($cfg, $st) {
    $nics = @(Invoke-GuardOp GetNics)
    $refusal = Get-GuardRefusal $cfg $nics
    if ($refusal) { return (Complete-GuardFinal $cfg $st 'Refused' $refusal) }
    $mac = [string](Get-GuardProp $cfg.expect 'mac' '')
    $mgmtNic = @($nics | Where-Object { $_.mac -eq $mac } | Select-Object -First 1)
    $old = ''
    $gwBefore = $true
    if ($mgmtNic.Count) { $old = (@($mgmtNic[0].ips | Where-Object { $_.ip -notlike '169.254.*' } | ForEach-Object { $_.ip }) -join ','); $gwBefore = (@($mgmtNic[0].gw).Count -gt 0) }
    Set-GuardProp $st 'oldAddress' $old
    Set-GuardProp $st 'gatewayBefore' $gwBefore
    foreach ($i in (Get-GuardItemList $cfg)) {
        if (-not (Test-GuardManagementItem $i)) { continue }
        Set-GuardProp $st 'newAddress' ([string]$i.ip)
        $already = ($mgmtNic.Count -gt 0) -and (@($mgmtNic[0].ips | Where-Object { $_.ip -eq [string]$i.ip }).Count -gt 0)
        if ([bool](Get-GuardProp $cfg 'probe' $true) -and -not $already) {
            if (Invoke-GuardOp ProbeAddress ([string]$i.ip) $mac) { return (Complete-GuardFinal $cfg $st 'Refused' ('Another host answers on ' + $i.ip + ' (ping or a neighbour-cache entry for another MAC). Refused: assigning it would duplicate the address.')) }
        }
    }
    $snapshots = @{}
    foreach ($i in (Get-GuardItemList $cfg)) { $snapshots[[string]$i.id] = Invoke-GuardOp SnapshotItem $i }
    Set-GuardProp $st 'snapshots' $snapshots
    Set-GuardProp $st 'nicsBefore' @($nics)
    Invoke-GuardOp WritePanic (Get-GuardFile $cfg '.panic.json') @($nics)
    Set-GuardProp $st 'baseline' @(Test-GuardChecks $cfg | ForEach-Object { New-Object psobject -Property @{ name = $_.name; ok = $_.ok; detail = $_.detail; skipped = $_.skipped } })
    $extra = 0
    if (@(Get-GuardItemList $cfg | Where-Object { [string]$_.kind -eq 'nic-vlan' }).Count) { $extra = [double](Get-GuardProp $cfg 'vlanLinkDownSeconds' 120) }
    Set-GuardDeadline $st 'deadlineUtc' 'deadlineTick' (([double]$cfg.confirmMinutes + 10) * 60 + [double](Get-GuardProp $cfg 'stableSeconds' 60) + $extra)
    Set-GuardProp $st 'appliedUtc' (Get-GuardNow).ToString('o')
    Set-GuardState $cfg $st 'Snapshotted' 'the pre-change state is saved (snapshot and panic document)'
    Set-GuardState $cfg $st 'Applying'
    foreach ($i in (Get-GuardItemList $cfg)) {
        try { Invoke-GuardOp ApplyItem $i; Write-GuardLog $cfg ('applied ' + $i.id) }
        catch { return (Invoke-GuardFullRollback $cfg $st ('Item ' + $i.id + ' failed to apply (' + $_.Exception.Message + '); the snapshot was restored.')) }
    }
    foreach ($i in (Get-GuardItemList $cfg)) {
        if ((Test-GuardManagementItem $i) -and (Invoke-GuardOp IsDuplicate $mac ([string]$i.ip))) {
            return (Invoke-GuardFullRollback $cfg $st ('Windows duplicate address detection reports ' + $i.ip + ' as a duplicate: another host uses it. Refused; the snapshot was restored (the address is never applied again).') 'Refused')
        }
    }
    if ([bool](Get-GuardProp $cfg 'restartAfter' $false)) {
        Set-GuardProp $st 'rebootRequestedUtc' (Get-GuardNow).ToString('o')
        Set-GuardProp $st 'rebootExpected' $true
        Set-GuardState $cfg $st 'Applying' 'the computer name changed; the node restarts and the watchdog checks it after the boot'
        Invoke-GuardOp Reboot
        return 'Applying'
    }
    return (Complete-GuardChange $cfg $st)
}

# ---- the entry point: one controller owns every mutation (machine-wide mutex); the scheduled task is the backstop that calls it again after a reboot or a crash
function Invoke-GuardedChange {
    param([Parameter(Mandatory)][string]$ConfigPath, [string]$ScriptPath)
    $cfg = (Invoke-GuardOp ReadText $ConfigPath) | ConvertFrom-Json
    if (-not (Invoke-GuardOp AcquireMutex 'Global\AzureLocalOsConfig')) { return 'Busy' }
    try {
        $st = Read-GuardState $cfg
        if ($null -eq $st) {
            Write-GuardLog $cfg 'neither the state file nor its copy can be read'
            Remove-GuardWatchdog $cfg
            return 'NoState'
        }
        if (@('Committed', 'RolledBack', 'Refused') -contains [string]$st.state) { Remove-GuardWatchdog $cfg; return [string]$st.state }
        # After a restart the adapters may not exist yet: wait, bounded, before judging anything.
        $null = Invoke-GuardOp WaitAdapters 120
        $now = Get-GuardNow
        if ($ScriptPath -and (Get-GuardProp $st 'scriptSha256' '')) {
            $actual = [string](Invoke-GuardOp FileHash $ScriptPath)
            if ($actual -ine [string]$st.scriptSha256) {
                if ([string]$st.state -eq 'Staged') { return (Complete-GuardFinal $cfg $st 'Refused' ('The staged script has SHA-256 ' + $actual + ', the manifest (state file) says ' + $st.scriptSha256 + '. Not run.')) }
                return (Set-GuardFailed $cfg $st ('The staged script differs from the one recorded (SHA-256 ' + $actual + '); not run, the node was left as it is. Check it at the console.'))
            }
        }
        if ([string]$st.state -ne 'Staged' -and (Get-GuardProp $st 'owner' '') -and [string]$st.owner -ne $script:GuardInstance) { Write-GuardLog $cfg ('taking over from ' + $st.owner + ' in state ' + $st.state + ' (it holds no mutex, so it stopped)') }
        switch ([string]$st.state) {
            'Staged' {
                $start = (ConvertTo-GuardTime $st.stagedUtc).AddSeconds([double](Get-GuardProp $cfg 'startDelaySeconds' 20))
                $wait = ($start - $now).TotalSeconds
                if ($wait -gt 0) { Invoke-GuardOp Sleep ([int][math]::Ceiling($wait)) }
                if ((Get-GuardNow) -gt (ConvertTo-GuardTime $st.stagedUtc).AddMinutes([double]$cfg.confirmMinutes)) {
                    return (Complete-GuardFinal $cfg $st 'RolledBack' 'The change never started inside its window; nothing was changed.')
                }
                return (Start-GuardApply $cfg $st)
            }
            'Snapshotted' { return (Invoke-GuardFullRollback $cfg $st 'The change script stopped before it applied anything (reboot or crash); the snapshot was restored.') }
            'Applying' {
                if (-not (Get-GuardProp $st 'rebootExpected' $false)) { return (Invoke-GuardFullRollback $cfg $st 'The change script stopped while it was applying (reboot or crash); the snapshot was restored.') }
                $booted = [datetime](Invoke-GuardOp BootTime)
                $requested = ConvertTo-GuardTime $st.rebootRequestedUtc
                if ($booted -lt $requested -and ($now - $requested).TotalMinutes -lt 15) { return 'Applying' }
                Set-GuardDeadline $st 'deadlineUtc' 'deadlineTick' (([double]$cfg.confirmMinutes + 10) * 60)
                return (Complete-GuardChange $cfg $st)
            }
            'Failed' { return (Invoke-GuardFullRollback $cfg $st 'Trying the restore again after a failure.') }
            default { return (Complete-GuardChange $cfg $st) }
        }
    }
    finally { Invoke-GuardOp ReleaseMutex }
}

function New-GuardRealOps {
    # Adapters are found by MAC (the permanent address first), never by ifIndex or alias.
    function Get-GuardMacKey([string]$m) { return (($m -replace '[-:\.]', '')).ToLowerInvariant() }
    function Get-GuardAdapter([string]$mac) {
        $k = Get-GuardMacKey $mac
        $all = @(Get-NetAdapter -Physical -ErrorAction Stop)
        $hit = @($all | Where-Object { $_.PSObject.Properties['PermanentAddress'] -and $_.PermanentAddress -and (Get-GuardMacKey ([string]$_.PermanentAddress)) -eq $k } | Select-Object -First 1)
        if ($hit.Count) { return $hit[0] }
        return ($all | Where-Object { (Get-GuardMacKey $_.MacAddress) -eq $k } | Select-Object -First 1)
    }
    function Invoke-GuardNative([string]$Exe, [string[]]$Arguments, [int]$TimeoutSeconds = 60) {
        $out = & $Exe @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($Exe + ' ' + ($Arguments -join ' ') + ' exited with ' + $LASTEXITCODE + ': ' + ($out -join ' ')) }
        return $out
    }
    function Get-GuardNicInfo($a) {
        $idx = $a.ifIndex
        $ips = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { New-Object psobject -Property @{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = [string]$_.PrefixOrigin; state = [string]$_.AddressState } })
        $routes = @(Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        $ipif = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        $metric = 9999
        if ($routes.Count -and $ipif) { $metric = [int]$routes[0].RouteMetric + [int]$ipif.InterfaceMetric }
        $vlan = $null
        $vp = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword 'VlanID' -ErrorAction SilentlyContinue
        if ($vp) { $vlan = [int](@($vp.RegistryValue)[0]) }
        $dhcp = ''
        if ($ipif) { $dhcp = [string]$ipif.Dhcp }
        return (New-Object psobject -Property @{ name = [string]$a.Name; mac = (Get-GuardMacKey $a.MacAddress); ifIndex = $idx; status = [string]$a.Status; ips = $ips; gw = @($routes | ForEach-Object { [string]$_.NextHop }); dns = $dns; dhcp = $dhcp; vlan = $vlan; metric = $metric })
    }
    function Clear-GuardNic($a) {
        Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction Stop
        Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
    }
    # The restore is always a STATIC configuration built from the snapshot (a DHCP lease is never relied on to come back).
    function Restore-GuardNic($snap, [bool]$DnsOnly) {
        $a = Get-GuardAdapter ([string]$snap.mac)
        if (-not $a) { throw ('No port with MAC ' + $snap.mac) }
        if ($DnsOnly) {
            if (@($snap.dns).Count -eq 0) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop } else { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($snap.dns) -ErrorAction Stop }
            return
        }
        Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
        Clear-GuardNic $a
        $first = $true
        foreach ($ip in @($snap.ips | Where-Object { $_.ip -notlike '169.254.*' })) {
            if ($first -and @($snap.gw).Count) { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip.ip -PrefixLength ([int]$ip.prefix) -DefaultGateway ([string]@($snap.gw)[0]) -ErrorAction Stop | Out-Null }
            else { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip.ip -PrefixLength ([int]$ip.prefix) -ErrorAction Stop | Out-Null }
            $first = $false
        }
        if (@($snap.ips | Where-Object { $_.ip -notlike '169.254.*' }).Count -eq 0 -and [string]$snap.dhcp -eq 'Enabled') { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop }
        if (@($snap.dns).Count) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($snap.dns) -ErrorAction Stop }
    }
    function Test-GuardTcp([string]$hostName, [int]$port, [int]$ms = 5000, [string]$source = '') {
        $c = $null
        try {
            if ($source) { $c = New-Object System.Net.Sockets.TcpClient((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($source), 0))) } else { $c = New-Object System.Net.Sockets.TcpClient }
            $t = $c.ConnectAsync($hostName, $port)
            return ($t.Wait($ms) -and $c.Connected)
        }
        catch { return $false }
        finally { if ($c) { $c.Close() } }
    }
    $ops = @{}
    $ops.Now = { return [datetime]::UtcNow }
    $ops.Tick = { return [double][Environment]::TickCount64 }
    $ops.Sleep = { param($s) Start-Sleep -Seconds $s }
    $ops.ReadText = { param($p) return (Get-Content -LiteralPath $p -Raw -ErrorAction Stop) }
    $ops.WriteText = {
        param($p, $t)
        $tmp = $p + '.tmp'
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes([string]$t)
        $fs = [IO.File]::Open($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
        Move-Item -LiteralPath $tmp -Destination $p -Force
    }
    $ops.AppendText = { param($p, $t) Add-Content -LiteralPath $p -Value $t -Encoding UTF8 }
    $ops.Exists = { param($p) return (Test-Path -LiteralPath $p) }
    $ops.FileHash = { param($p) return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
    $ops.TextHash = { param($t) return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$t))) -replace '-', '') }
    $ops.BootTime = { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }
    $ops.Reboot = { Invoke-GuardNative 'shutdown.exe' @('/r', '/t', '20', '/d', 'p:2:4', '/c', 'Azure Local OS configuration: restart to finish a guarded change') | Out-Null }
    $ops.AcquireMutex = {
        param($name)
        $m = New-Object System.Threading.Mutex($false, $name)
        $got = $false
        try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if ($got) { $script:GuardMutex = $m } else { $m.Dispose() }
        return $got
    }
    $ops.ReleaseMutex = { if ($script:GuardMutex) { try { $script:GuardMutex.ReleaseMutex() } catch { $null = $_ }; $script:GuardMutex.Dispose(); $script:GuardMutex = $null } }
    $ops.WaitAdapters = {
        param($seconds)
        $end = [datetime]::UtcNow.AddSeconds($seconds)
        while ([datetime]::UtcNow -lt $end) { if (@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue).Count -gt 0) { return $true }; Start-Sleep -Seconds 5 }
        return $false
    }
    $ops.UnregisterWatchdog = { param($id) Unregister-ScheduledTask -TaskName ('AzlOsConfig-Net-' + $id) -Confirm:$false -ErrorAction SilentlyContinue }
    $ops.GetNics = { return @(Get-NetAdapter -Physical | ForEach-Object { Get-GuardNicInfo $_ }) }
    $ops.CheckTopology = {
        param($cfg)
        $e = $cfg.expect
        $a = Get-GuardAdapter ([string]$e.mac)
        if (-not $a) { return ('No port has the management MAC ' + $e.mac) }
        $cur = [string](Get-GuardProp $e 'currentIp' '')
        if ($cur) {
            $owner = Get-NetIPAddress -IPAddress $cur -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($owner -and $owner.InterfaceIndex -ne $a.ifIndex) { return ('The address ' + $cur + ' belongs to another interface than the one with the management MAC ' + $e.mac + '. Refused: the MAC and the address do not match.') }
        }
        $team = $null
        if (Get-Command Get-NetLbfoTeamMember -ErrorAction SilentlyContinue) { $team = Get-NetLbfoTeamMember -Name $a.Name -ErrorAction SilentlyContinue }
        if ($team) { return ('Port ' + $a.Name + ' is a member of the LBFO team ' + $team.Team + '. Refused: operate on the team interface, never on a member.') }
        if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
            $sw = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapterInterfaceGuid -contains $a.InterfaceGuid })
            if ($sw.Count) { return ('Port ' + $a.Name + ' is the physical uplink of the virtual switch ' + $sw[0].Name + '. Refused: operate on the host vNIC, never on the uplink.') }
        }
        return ''
    }
    $ops.VlanCapable = { param($mac) $a = Get-GuardAdapter $mac; if (-not $a) { return $false }; return [bool](Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword 'VlanID' -ErrorAction SilentlyContinue) }
    $ops.ProbeAddress = {
        param($ip, $mac)
        if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
        $own = @(Get-NetAdapter -Physical | ForEach-Object { Get-GuardMacKey $_.MacAddress })
        $n = @(Get-NetNeighbor -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { @('Reachable', 'Stale', 'Delay', 'Probe', 'Permanent') -contains [string]$_.State -and $_.LinkLayerAddress -and ($own -notcontains (Get-GuardMacKey $_.LinkLayerAddress)) })
        return ($n.Count -gt 0)
    }
    $ops.IsDuplicate = {
        # The operating system's own duplicate address detection: Tentative becomes Preferred, or Duplicate. Polled for at least 15 seconds.
        param($mac, $ip)
        for ($k = 0; $k -lt 20; $k++) {
            $states = @(Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.AddressState })
            if ($states -contains 'Duplicate') { return $true }
            if ($k -ge 15 -and $states -contains 'Preferred') { return $false }
            Start-Sleep -Seconds 1
        }
        return $false
    }
    $ops.WritePanic = {
        param($path, $nics)
        $doc = [pscustomobject]@{ v = 1; createdUtc = [datetime]::UtcNow.ToString('o'); nics = @($nics | ForEach-Object { [pscustomobject]@{ mac = $_.mac; name = $_.name; enabled = ([string]$_.status -ne 'Disabled'); ips = @($_.ips | Where-Object { $_.ip -notlike '169.254.*' } | ForEach-Object { [pscustomobject]@{ ip = $_.ip; prefix = $_.prefix } }); gw = @($_.gw); dns = @($_.dns); vlan = $_.vlan } }) }
        $json = ConvertTo-Json -InputObject $doc -Depth 6
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
        $fs = [IO.File]::Open($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    }
    $ops.RunPanic = {
        # Restores the previous STATIC configuration by MAC, enables the adapters that were enabled, and makes WinRM listen with a link-local rule so the node can be reached from the same segment.
        param($path)
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($n in @($doc.nics)) {
            $a = Get-GuardAdapter ([string]$n.mac)
            if (-not $a) { continue }
            if ($n.enabled -and [string]$a.Status -eq 'Disabled') { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
            if (@($n.ips).Count) {
                Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
                Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                $first = $true
                foreach ($ip in @($n.ips)) {
                    if ($first -and @($n.gw).Count) { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip.ip -PrefixLength ([int]$ip.prefix) -DefaultGateway ([string]@($n.gw)[0]) -ErrorAction SilentlyContinue | Out-Null }
                    else { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip.ip -PrefixLength ([int]$ip.prefix) -ErrorAction SilentlyContinue | Out-Null }
                    $first = $false
                }
                if (@($n.dns).Count) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($n.dns) -ErrorAction SilentlyContinue }
            }
        }
        Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service WinRM -ErrorAction SilentlyContinue
        if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count -eq 0) { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null }
        if (-not (Get-NetFirewallRule -Name 'AzlPanicWinRM-LinkLocal' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name 'AzlPanicWinRM-LinkLocal' -DisplayName 'Azure Local OS configuration: WinRM from the link-local range' -Direction Inbound -Protocol TCP -LocalPort 5985, 5986 -RemoteAddress '169.254.0.0/16' -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null }
    }
    $ops.SnapshotItem = {
        param($i)
        switch ([string]$i.kind) {
            { $_ -in 'nic-static', 'nic-dns', 'nic-clean', 'nic-vlan' } { $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }; return (Get-GuardNicInfo $a) }
            'nic-disable' { $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }; return (New-Object psobject -Property @{ mac = (Get-GuardMacKey $a.MacAddress); name = [string]$a.Name; status = [string]$a.Status }) }
            'winrm' { $s = Get-Service WinRM; return (New-Object psobject -Property @{ status = [string]$s.Status; start = [string]$s.StartType; listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count }) }
            'rdp' { return (New-Object psobject -Property @{ deny = [int](Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections; rules = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' } | ForEach-Object { [string]$_.Name }) }) }
            'icmp' { return (New-Object psobject -Property @{ rules = @(Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' } | ForEach-Object { [string]$_.Name }) }) }
            'ntp' { $w = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'; return (New-Object psobject -Property @{ type = [string]$w.Type; peers = [string]$w.NtpServer }) }
            'hostname' { return (New-Object psobject -Property @{ name = [string]$env:COMPUTERNAME }) }
            default { throw ('Unknown guarded item ' + [string]$i.kind) }
        }
    }
    $ops.ApplyItem = {
        param($i)
        switch ([string]$i.kind) {
            'nic-static' {
                # The new address and the new route are added FIRST; the old address stays until the orchestrator has confirmed (FinalizeItem removes it).
                $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }
                $gateway = [string](Get-GuardProp $i 'gateway' '')
                Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
                $have = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -IPAddress ([string]$i.ip) -ErrorAction SilentlyContinue | Where-Object { $_.PrefixLength -eq [int]$i.prefix }
                if (-not $have) { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress ([string]$i.ip) -PrefixLength ([int]$i.prefix) -ErrorAction Stop | Out-Null }
                if ($gateway -and -not (Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $gateway })) {
                    New-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -NextHop $gateway -ErrorAction Stop | Out-Null
                }
                if (@(Get-GuardProp $i 'dns' @()).Count) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($i.dns) -ErrorAction Stop }
            }
            'nic-vlan' {
                $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }
                Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword 'VlanID' -RegistryValue ([int]$i.vlan) -ErrorAction Stop
                Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 15
            }
            'nic-dns' { $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }; Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($i.servers) -ErrorAction Stop }
            'nic-clean' {
                $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }
                Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
                Clear-GuardNic $a
            }
            'nic-disable' { $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }; Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop }
            'winrm' {
                Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
                if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM -ErrorAction Stop }
                if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count -eq 0) { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null }
            }
            'rdp' { Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -ErrorAction Stop; Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop }
            'icmp' { foreach ($n in 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In') { Enable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue } }
            'ntp' {
                $peers = (@($i.servers) | ForEach-Object { $_ + ',0x8' }) -join ' '
                Invoke-GuardNative 'w32tm.exe' @('/config', ('/manualpeerlist:' + $peers), '/syncfromflags:manual', '/reliable:no', '/update') | Out-Null
                Restart-Service w32time -ErrorAction Stop
                Start-Sleep -Seconds 3
                & w32tm.exe /resync /force 2>&1 | Out-Null
            }
            'hostname' { Rename-Computer -NewName ([string]$i.name) -Force -ErrorAction Stop }
            default { throw ('Unknown guarded item ' + [string]$i.kind) }
        }
    }
    $ops.FinalizeItem = {
        param($i, $snap)
        if ([string]$i.kind -ne 'nic-static' -or -not [bool](Get-GuardProp $i 'management' $false)) { return }
        $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { return }
        $gateway = [string](Get-GuardProp $i 'gateway' '')
        Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne [string]$i.ip -and $_.IPAddress -notlike '169.254.*' } | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
        if ($gateway) { Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne $gateway } | Remove-NetRoute -Confirm:$false -ErrorAction Stop }
    }
    $ops.RestoreItem = {
        param($i, $snap)
        switch ([string]$i.kind) {
            'nic-static' { Restore-GuardNic $snap $false; return $false }
            'nic-clean' { Restore-GuardNic $snap $false; return $false }
            'nic-dns' { Restore-GuardNic $snap $true; return $false }
            'nic-vlan' { $a = Get-GuardAdapter ([string]$snap.mac); if ($a) { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword 'VlanID' -RegistryValue ([int]$snap.vlan) -ErrorAction Stop; Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 15 }; return $false }
            'nic-disable' { $a = Get-GuardAdapter ([string]$snap.mac); if ($a -and [string]$snap.status -ne 'Disabled') { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop }; return $false }
            'winrm' { Set-Service -Name WinRM -StartupType ([string]$snap.start) -ErrorAction Stop; if ([string]$snap.status -ne 'Running') { Stop-Service WinRM -Force -ErrorAction SilentlyContinue }; return $false }
            'rdp' {
                Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ([int]$snap.deny) -ErrorAction Stop
                if (@($snap.rules).Count -eq 0) { Disable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue }
                return $false
            }
            'icmp' { foreach ($n in 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In') { if (@($snap.rules) -notcontains $n) { Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue } }; return $false }
            'ntp' {
                $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
                Set-ItemProperty -Path $key -Name Type -Value ([string]$snap.type) -ErrorAction Stop
                Set-ItemProperty -Path $key -Name NtpServer -Value ([string]$snap.peers) -ErrorAction Stop
                Restart-Service w32time -ErrorAction Stop
                return $false
            }
            'hostname' { Rename-Computer -NewName ([string]$snap.name) -Force -ErrorAction Stop; return $true }
            default { throw ('Unknown guarded item ' + [string]$i.kind) }
        }
    }
    $ops.CheckAddress = {
        param($cfg)
        $e = $cfg.expect
        $a = Get-GuardAdapter ([string]$e.mac)
        if (-not $a) { return @{ ok = $false; detail = ('no port with MAC ' + $e.mac) } }
        $n = Get-GuardNicInfo $a
        $ips = @($n.ips | Where-Object { $_.ip -notlike '169.254.*' } | ForEach-Object { $_.ip })
        if (-not $ips.Count) { return @{ ok = $false; detail = 'the management port has no address' } }
        if ([string](Get-GuardProp $e 'ip' '') -and ($ips -notcontains [string]$e.ip)) { return @{ ok = $false; detail = ('has ' + ($ips -join ',') + ', expected ' + $e.ip) } }
        if ([string](Get-GuardProp $e 'ip' '')) {
            $mine = @($n.ips | Where-Object { $_.ip -eq [string]$e.ip } | Select-Object -First 1)
            if ($mine.Count -and $mine[0].state -ne 'Preferred') { return @{ ok = $false; detail = ($e.ip + ' is ' + $mine[0].state + ', not Preferred') } }
            $wantPrefix = [int](Get-GuardProp $e 'prefix' 0)
            if ($wantPrefix -gt 0 -and $mine.Count -and [int]$mine[0].prefix -ne $wantPrefix) { return @{ ok = $false; detail = ('prefix length is ' + $mine[0].prefix + ', expected ' + $wantPrefix) } }
        }
        if ([bool](Get-GuardProp $e 'requireGateway' $true) -and @($n.gw).Count -eq 0) { return @{ ok = $false; detail = ('address ' + ($ips -join ',') + ' but no default gateway') } }
        $wantVlan = [int](Get-GuardProp $e 'vlan' 0)
        if ($wantVlan -gt 0 -and $n.vlan -ne $wantVlan) { return @{ ok = $false; detail = ('VLAN id is ' + $n.vlan + ', expected ' + $wantVlan) } }
        return @{ ok = $true; detail = ($ips -join ',') + ' gw ' + (@($n.gw) -join ',') }
    }
    $ops.CheckGateway = {
        # Neighbour resolution of the gateway plus the configured TCP probes, bound to the intended interface. ICMP is optional evidence only.
        param($cfg)
        $a = Get-GuardAdapter ([string]$cfg.expect.mac)
        if (-not $a) { return @{ ok = $false; detail = 'no management port' } }
        $n = Get-GuardNicInfo $a
        $gw = @($n.gw)
        if (-not $gw.Count) { return @{ ok = $false; detail = 'no default gateway' } }
        $null = Test-Connection -ComputerName $gw[0] -Count 1 -Quiet -ErrorAction SilentlyContinue
        $nb = @(Get-NetNeighbor -IPAddress $gw[0] -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { @('Reachable', 'Permanent', 'Stale', 'Delay', 'Probe') -contains [string]$_.State -and $_.LinkLayerAddress })
        if (-not $nb.Count) { return @{ ok = $false; detail = ($gw[0] + ' does not resolve to a MAC address on the management port') } }
        $targets = @(Get-GuardProp $cfg 'probeTargets' @())
        if ($targets.Count) {
            $src = [string](@($n.ips | Where-Object { $_.ip -notlike '169.254.*' } | ForEach-Object { $_.ip })[0])
            foreach ($t in $targets) {
                $h, $p = ([string]$t) -split ':', 2
                if (Test-GuardTcp $h ([int]$p) 5000 $src) { return @{ ok = $true; detail = ($gw[0] + ' resolves; TCP ' + $t + ' answers through ' + $src) } }
            }
            return @{ ok = $false; detail = ($gw[0] + ' resolves but none of the TCP probes (' + ($targets -join ', ') + ') answers through the management port') }
        }
        return @{ ok = $true; detail = ($gw[0] + ' resolves to a MAC address (no TCP probe configured)') }
    }
    $ops.CheckDns = {
        param($cfg)
        $name = [string]@($cfg.probeHosts)[0]
        try { $r = @(Resolve-DnsName -Name $name -Type A -DnsOnly -ErrorAction Stop); if ($r.Count) { return @{ ok = $true; detail = ($name + ' resolves') } } } catch { return @{ ok = $false; detail = ($name + ' does not resolve: ' + $_.Exception.Message) } }
        return @{ ok = $false; detail = ($name + ' returned nothing') }
    }
    $ops.CheckArc = {
        # Evidence only; never a commit predicate.
        param($cfg)
        $svc = Get-Service himds -ErrorAction SilentlyContinue
        if (-not $svc) { return @{ ok = $true; skipped = $true; detail = 'no Arc agent on this node' } }
        $status = ''
        try {
            $out = (& 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe' show -j 2>&1) -join ' '
            $m = [regex]::Match($out, '"status"\s*:\s*"(\w+)"')
            if ($m.Success) { $status = $m.Groups[1].Value } else { $m2 = [regex]::Match($out, 'Agent Status\s*:\s*(\w+)'); if ($m2.Success) { $status = $m2.Groups[1].Value } }
        }
        catch { $status = 'unknown' }
        return @{ ok = ([string]$svc.Status -eq 'Running' -and $status -eq 'Connected'); detail = ('himds ' + $svc.Status + ', agent status ' + $status) }
    }
    $ops.CheckWinRm = {
        param($cfg)
        if (-not [bool](Get-GuardProp $cfg.expect 'winrm' $false)) { return @{ ok = $true; skipped = $true; detail = 'WinRM was not listening before' } }
        $s = Get-Service WinRM
        $listen = Test-GuardTcp '127.0.0.1' 5985 2000
        if (-not $listen) { $listen = Test-GuardTcp '127.0.0.1' 5986 2000 }
        return @{ ok = ([string]$s.Status -eq 'Running' -and $listen); detail = ('WinRM ' + $s.Status + ', listener ' + $(if ($listen) { 'answers' } else { 'does not answer' })) }
    }
    $ops.CheckPorts = {
        param($cfg)
        $clean = @($cfg.items | Where-Object { [string]$_.kind -eq 'nic-clean' })
        if (-not $clean.Count) { return @{ ok = $true; skipped = $true; detail = 'no port was cleaned' } }
        $bad = @()
        foreach ($i in $clean) {
            $a = Get-GuardAdapter ([string]$i.mac)
            if (-not $a) { continue }
            $n = Get-GuardNicInfo $a
            if (@($n.ips | Where-Object { $_.ip -notlike '169.254.*' }).Count -or @($n.gw).Count) { $bad += $n.name }
        }
        return @{ ok = ($bad.Count -eq 0); detail = $(if ($bad.Count) { ('still have an address or a default route: ' + ($bad -join ', ')) } else { 'the cleaned ports have no address and no default route' }) }
    }
    $ops.RestartArcAgent = { foreach ($n in 'himds', 'GCArcService', 'ExtensionService') { if (Get-Service $n -ErrorAction SilentlyContinue) { Restart-Service -Name $n -Force -ErrorAction SilentlyContinue } } }
    $ops.EnableAdapter = { param($mac) $a = Get-GuardAdapter $mac; if ($a) { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop } }
    return $ops
}
'@

# The file that is staged on the node. Its SHA-256 is recorded in the state file and checked before the engine runs.
function Get-AzlGuardScriptText {
    <#
    .SYNOPSIS
        The exact text of net-<id>.ps1: a header, the engine and the call. Deterministic for a change id, so the wrapper can compute
        the SHA-256 the node must see.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]{6,32}$')][string]$ChangeId)
    $nl = "`n"
    $header = '# Azure Local OS configuration: guarded change ' + $ChangeId + $nl + 'param([string]$Mode = ''Auto'')' + $nl + '$ErrorActionPreference = ''Stop''' + $nl
    $call = $nl + 'Invoke-GuardedChange -ConfigPath ($PSScriptRoot + ''\net-' + $ChangeId + '.json'') -ScriptPath $PSCommandPath' + $nl
    return ($header + ($script:EngineBody -replace "`r`n", $nl) + $call)
}

function Get-AzlGuardEngine {
    <#
    .SYNOPSIS
        The engine functions as text, without the header and the call. For a host test: write it to a file and dot-source it, then
        Set-GuardOps with fake operations and call Invoke-GuardedChange.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ($script:EngineBody -replace "`r`n", "`n")
}

function Get-AzlGuardScriptHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ChangeId)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((Get-AzlGuardScriptText -ChangeId $ChangeId))
    return ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '')
}

$script:StageBody = @'
# AZL-GUARD-STAGE
$id = [string]$P.changeId
$base = [string](Get-P $P 'dir' $stateDir)
New-Item -ItemType Directory -Force -Path $base | Out-Null
# The state folder is for SYSTEM and Administrators only.
try { & icacls.exe $base /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null } catch { $null = $_ }
$utc = (Get-Date).ToUniversalTime()
$sid = ''
try { $sid = ([Security.Principal.NTAccount]('{0}\{0}$' -f $env:COMPUTERNAME)).Translate([Security.Principal.SecurityIdentifier]).AccountDomainSid.Value } catch { $sid = '' }
# One active change at a time. The same change id again: a Committed change is a no-op success, a running one is reported.
$busy = ''
foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'net-*' -ErrorAction SilentlyContinue)) {
    $f = Join-Path $d.FullName ($d.Name + '.state.json')
    if (-not (Test-Path -LiteralPath $f)) { continue }
    try { $s = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { continue }
    if ([string]$s.changeId -eq $id) {
        Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; staged = $false; sameChange = $true; changeId = $id; state = [string]$s.state; cookie = [string](Get-P $s 'cookie' ''); machineSid = $sid })
        return
    }
    if (@('Staged', 'Snapshotted', 'Applying', 'Verifying', 'AwaitingConfirm', 'Repairing', 'Failed') -contains [string]$s.state) { $busy = [string]$s.changeId }
}
if ($busy) { Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; staged = $false; busyWith = $busy }); return }

# The payload runs from an immutable directory of its own for this change.
$dir = Join-Path $base ('net-' + $id)
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$scriptText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SCRIPT_B64__'))
$scriptPath = Join-Path $dir ('net-' + $id + '.ps1')
[IO.File]::WriteAllText($scriptPath, $scriptText, (New-Object Text.UTF8Encoding($false)))
$hash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
if ($hash -ine [string]$P.scriptSha256) { throw ('The staged script has SHA-256 ' + $hash + ', expected ' + $P.scriptSha256) }
$cfg = $P.config
$cfg | Add-Member -NotePropertyName dir -NotePropertyValue $dir -Force
ConvertTo-Json -InputObject $cfg -Depth 8 | Set-Content -LiteralPath (Join-Path $dir ('net-' + $id + '.json')) -Encoding UTF8
$cookie = [guid]::NewGuid().ToString('N')
$state = [pscustomobject]@{ v = 1; generation = 1; changeId = $id; group = [string]$cfg.group; state = 'Staged'; reason = ''; stagedUtc = $utc.ToString('o'); updatedUtc = $utc.ToString('o'); heartbeatUtc = $utc.ToString('o'); owner = ''
    scriptSha256 = $hash; cookie = $cookie; machineSid = $sid; items = @($cfg.items | ForEach-Object { [string]$_.id }); watchdog = $false }
$statePath = Join-Path $dir ('net-' + $id + '.state.json')
Set-Content -LiteralPath $statePath -Value (ConvertTo-Json -InputObject $state -Depth 6) -Encoding UTF8

# The watchdog is a BACKSTOP for a crash or a reboot: the payload process is the supervisor. A scheduled task runs the script at startup and every minute;
# a named mutex keeps one controller active. No execution time limit, start when available, restart on failure.
$taskName = 'AzlOsConfig-Net-' + $id
$minutes = [int]$cfg.confirmMinutes + 60
$mode = 'task'
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"')
    $startup = New-ScheduledTaskTrigger -AtStartup
    $repeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Minutes $minutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startup, $repeat) -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $state.watchdog = $true
}
catch {
    $mode = 'process'
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"') -WindowStyle Hidden
}
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; staged = $true; changeId = $id; stagedUtc = $utc.ToString('o'); scriptSha256 = $hash; cookie = $cookie; machineSid = $sid; watchdog = [bool]$state.watchdog; startedBy = $mode })
'@

$script:StatusBody = @'
# AZL-GUARD-STATUS
$id = [string](Get-P $P 'changeId' '')
$base = [string](Get-P $P 'dir' $stateDir)
$statePath = ''
if ($id) { $statePath = Join-Path (Join-Path $base ('net-' + $id)) ('net-' + $id + '.state.json') }
else {
    $latest = Get-ChildItem -LiteralPath $base -Recurse -Filter 'net-*.state.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.copy.json' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $statePath = $latest.FullName }
}
if (-not $statePath -or -not (Test-Path -LiteralPath $statePath)) { Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; found = $false; changeId = $id }); return }
$state = $null
foreach ($candidate in @($statePath, ($statePath -replace '\.state\.json$', '.state.copy.json'))) {
    for ($try = 1; $try -le 3 -and -not $state; $try++) {
        try { $state = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 300 }
    }
    if ($state) { break }
}
if (-not $state) { Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; found = $true; unreadable = $true; changeId = $id }); return }
$id = [string]$state.changeId
$dir = Split-Path -Parent $statePath
# Identity: the node cookie and the machine SID recorded at staging must be echoed back; a different node answering is refused.
$sid = ''
try { $sid = ([Security.Principal.NTAccount]('{0}\{0}$' -f $env:COMPUTERNAME)).Translate([Security.Principal.SecurityIdentifier]).AccountDomainSid.Value } catch { $sid = '' }
$cookieWanted = [string](Get-P $P 'cookie' '')
$identityOk = $true
if ($cookieWanted -and $cookieWanted -ne [string](Get-P $state 'cookie' '')) { $identityOk = $false }
$sidWanted = [string](Get-P $P 'machineSid' '')
if ($sidWanted -and $sid -and $sidWanted -ne $sid) { $identityOk = $false }
$ack = $false
$token = [string](Get-P $P 'ackToken' '')
if ($token -and $identityOk -and [string]$state.state -eq 'AwaitingConfirm') { [IO.File]::WriteAllText((Join-Path $dir ('net-' + $id + '.ack')), $token, (New-Object Text.UTF8Encoding($false))); $ack = $true }
$log = @()
$logPath = Join-Path $dir ($id + '.log')
if (Test-Path -LiteralPath $logPath) { $log = @(Get-Content -LiteralPath $logPath -Tail 14 | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) } else { $_ } }) }
$actual = ''
$scriptPath = Join-Path $dir ('net-' + $id + '.ps1')
if (Test-Path -LiteralPath $scriptPath) { $actual = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash }
$live = $null
$mac = Get-MacKey ([string](Get-P $P 'mac' ''))
if ($mac) {
    $a = Get-NetAdapter -Physical | Where-Object { (Get-MacKey $_.MacAddress) -eq $mac } | Select-Object -First 1
    if ($a) {
        $live = [pscustomobject]@{
            name = [string]$a.Name
            ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { '{0}/{1}/{2}/{3}' -f $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin, $_.AddressState })
            gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop })
            dns = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        }
    }
}
$remaining = $null
if (Get-P $state 'confirmDeadlineUtc' '') { $remaining = [int](([datetime]::Parse([string]$state.confirmDeadlineUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) - (Get-Date).ToUniversalTime()).TotalSeconds }
$compact = [pscustomobject]@{
    changeId = $id; group = [string](Get-P $state 'group' ''); state = [string]$state.state; generation = [int](Get-P $state 'generation' 0); reason = [string](Get-P $state 'reason' ''); updatedUtc = [string](Get-P $state 'updatedUtc' ''); heartbeatUtc = [string](Get-P $state 'heartbeatUtc' '')
    confirmDeadlineUtc = [string](Get-P $state 'confirmDeadlineUtc' ''); confirmSecondsLeft = $remaining; deadlineUtc = [string](Get-P $state 'deadlineUtc' '')
    oldAddress = [string](Get-P $state 'oldAddress' ''); newAddress = [string](Get-P $state 'newAddress' ''); scriptSha256 = [string](Get-P $state 'scriptSha256' ''); verdict = [string](Get-P $state 'verdict' ''); verified = (Get-P $state 'verified' $null); partial = (Get-P $state 'partial' $false); lateConfirm = [bool](Get-P $state 'lateConfirm' $false)
    restoredItems = @(Get-P $state 'restoredItems' @()); watchdog = [bool](Get-P $state 'watchdog' $false); finalizeError = [string](Get-P $state 'finalizeError' '')
    repairs = @(Get-P $state 'repairs' @() | ForEach-Object { [pscustomobject]@{ rung = [string]$_.rung; item = [string](Get-P $_ 'item' ''); ok = [bool]$_.ok; detail = [string]$_.detail } })
    checks = @(Get-P $state 'checks' @() | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; ok = [bool]$_.ok; detail = [string]$_.detail } })
}
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; found = $true; identityOk = $identityOk; state = $compact; log = $log; scriptSha256Actual = $actual; live = $live; ackWritten = $ack; machineSid = $sid; nowUtc = (Get-Date).ToUniversalTime().ToString('o') })
'@

function Get-AzlGuardStagePayload {
    <#
    .SYNOPSIS
        The script a session runs to stage a guarded change. Parameters (ParamsB64): changeId, scriptSha256, config. Returns at once.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ChangeId)
    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((Get-AzlGuardScriptText -ChangeId $ChangeId)))
    return ((Get-AzlNodePrologue) + [Environment]::NewLine + ($script:StageBody -replace '__SCRIPT_B64__', $b64))
}

function Get-AzlGuardStatusPayload {
    <#
    .SYNOPSIS
        A short read-only script: the state file, the log tail, the live management port. Parameters: changeId (else the newest), mac,
        ack (write the acknowledgement file).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ((Get-AzlNodePrologue) + [Environment]::NewLine + $script:StatusBody)
}

Export-ModuleMember -Function Get-AzlGuardScriptText, Get-AzlGuardEngine, Get-AzlGuardScriptHash, Get-AzlGuardStagePayload, Get-AzlGuardStatusPayload
