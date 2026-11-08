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

    The state machine (net-<id>.state.json; log <id>.log in C:\ProgramData\AzureLocal\osconfig):

      Staged --> Applying --> Checking --> Committed
         |          |            |  ^
         |          |            v  |
         |          |         Repairing --> Committed        (a repair that keeps the change: Arc agent restart, re-apply, NIC restart)
         |          |            |
         |          |            +-------> RolledBack         (a repair that undoes: item restored, adapter re-enabled, whole snapshot)
         |          +--> RolledBack                           (an item failed to apply, the script died while applying, no acknowledgement)
         |          +--> Refused                              (duplicate address)
         |          +--> PendingReboot --> Checking           (computer name: the node restarts, the watchdog finishes after the boot)
         +--> Refused (would disable the management port or the port holding the default gateway; another host answers on the
                       address; the file's hash differs; no port with the MAC)
         +--> RolledBack (never started inside the window)
      RollbackFailed: a snapshot item could not be restored (an exception); the log says which. Needs console access.

    Checks, in order, after the change (all must pass that passed BEFORE the change; the address check always applies):
      address   the management port has the expected address and a default gateway
      gateway   the default gateway answers (ICMP, or a neighbour entry when ICMP is blocked)
      dns       a name resolves
      arc       the Arc agent service runs and the Azure endpoints answer on TCP 443 (azcmagent show reports the status)
      winrm     WinRM is listening, if it was before
    Repair ladder, each rung followed by a re-check:
      RestartArcAgent -> ReapplyConfig -> RestoreItem (the failing item only) -> ReEnableAdapter -> RestartNic ->
      RestoreSnapshot (whole; state RolledBack) -> DhcpFallback (management port to DHCP, only if even the snapshot fails the checks).

    Proof of connectivity before Committed: proof 'ack' (WinRM: the wrapper writes net-<id>.ack after it reached the node on the
    new address) or proof 'azure' (the arc check reached the Azure endpoints). No proof inside the window: rolled back.

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
function Save-GuardState($cfg, $st) {
    $now = (Get-GuardNow).ToString('o')
    Set-GuardProp $st 'updatedUtc' $now
    Set-GuardProp $st 'heartbeatUtc' $now
    Set-GuardProp $st 'owner' $script:GuardInstance
    Invoke-GuardOp WriteText (Get-GuardFile $cfg '.state.json') (ConvertTo-Json -InputObject $st -Depth 8)
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
function Get-GuardItemList($cfg) { return @($cfg.items) }
function Test-GuardManagementItem($i) { return ((Get-GuardProp $i 'kind' '') -eq 'nic-static' -and [bool](Get-GuardProp $i 'management' $false)) }

# ---- refusals: a plan that would disable the management port or the port the node is reached through
function Get-GuardRefusal($cfg, $nics) {
    $mgmt = [string](Get-GuardProp $cfg.expect 'mac' '')
    $mgmtNic = @($nics | Where-Object { $_.mac -eq $mgmt } | Select-Object -First 1)
    $mgmtGw = 0
    if ($mgmtNic.Count) { $mgmtGw = @($mgmtNic[0].gw).Count }
    $carrier = @($nics | Where-Object { @($_.gw).Count -gt 0 } | Sort-Object { [int]$_.metric } | Select-Object -First 1)
    foreach ($i in (Get-GuardItemList $cfg)) {
        $kind = [string](Get-GuardProp $i 'kind' '')
        $mac = [string](Get-GuardProp $i 'mac' '')
        if (-not $mac -and $kind -notin 'nic-static', 'nic-dns', 'nic-clean', 'nic-disable') { continue }
        if ($kind -eq 'nic-disable') {
            if ($mac -eq $mgmt) { return 'The plan would disable the management port (MAC ' + $mac + '). Refused: the node would have no management path.' }
            if ($carrier.Count -and $carrier[0].mac -eq $mac) { return 'The plan would disable ' + $carrier[0].name + ', the port that holds the default gateway the node reaches Azure through. Refused.' }
        }
        if ($kind -in 'nic-disable', 'nic-clean' -and $mac -ne $mgmt) {
            if ($mgmtNic.Count -eq 0) { return 'No port has the management MAC ' + $mgmt + ', so the change to ' + $mac + ' is refused.' }
            if ($mgmtGw -eq 0) { return 'The management port has no default gateway, so changing port ' + $mac + ' is refused until it has one.' }
            if ($kind -eq 'nic-clean' -and $carrier.Count -and $carrier[0].mac -eq $mac) { return 'Port ' + $mac + ' holds the default gateway the node reaches Azure through; DHCP-off there is refused.' }
        }
        if ($kind -eq 'nic-clean' -and $mac -eq $mgmt) { return 'The plan would remove the address and gateway of the management port. Refused.' }
        if ($kind -eq 'nic-static' -and (Test-GuardManagementItem $i) -and $mgmtNic.Count -eq 0) { return 'No port has the management MAC ' + $mgmt + '.' }
    }
    return ''
}

# ---- checks
function Test-GuardChecks($cfg) {
    $results = @()
    foreach ($c in @(@('address', 'CheckAddress'), @('gateway', 'CheckGateway'), @('dns', 'CheckDns'), @('arc', 'CheckArc'), @('winrm', 'CheckWinRm'))) {
        try { $r = Invoke-GuardOp $c[1] $cfg } catch { $r = @{ ok = $false; detail = $_.Exception.Message } }
        $results += New-Object psobject -Property @{ name = $c[0]; ok = [bool](Get-GuardProp $r 'ok' $false); detail = [string](Get-GuardProp $r 'detail' ''); skipped = [bool](Get-GuardProp $r 'skipped' $false) }
    }
    return $results
}
function Get-GuardRequired($st, $results) {
    # A check is required after the change when it passed before it; the address check always is.
    $baseline = @(Get-GuardProp $st 'baseline' @())
    $failed = @()
    foreach ($r in $results) {
        if ($r.ok) { continue }
        $before = $baseline | Where-Object { $_.name -eq $r.name } | Select-Object -First 1
        if ($r.name -eq 'address' -or ($before -and $before.ok)) { $failed += $r }
    }
    return $failed
}
function Wait-GuardChecks($cfg, $st, [int]$Seconds) {
    $end = (Get-GuardNow).AddSeconds($Seconds)
    while ($true) {
        $results = Test-GuardChecks $cfg
        $failed = Get-GuardRequired $st $results
        Set-GuardProp $st 'checks' @($results)
        Save-GuardState $cfg $st
        if (@($failed).Count -eq 0) { return @() }
        if ((Get-GuardNow) -ge $end) { return @($failed) }
        Invoke-GuardOp Sleep 10
    }
}

# ---- snapshot, restore
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
function Invoke-GuardFullRollback($cfg, $st, [string]$reason, [string]$FinalState = 'RolledBack') {
    $failures = @(Restore-GuardItems $cfg $st)
    if ($failures.Count) { return (Complete-GuardFinal $cfg $st 'RollbackFailed' ($reason + ' Restoring the snapshot failed for: ' + ($failures -join '; ') + '. Console access is needed.')) }
    $verified = $true
    $failed = @(Wait-GuardChecks $cfg $st 30)
    if ($failed.Count) {
        Write-GuardLog $cfg ('after the restore these checks still fail: ' + (($failed | ForEach-Object { $_.name }) -join ', '))
        $mac = [string](Get-GuardProp $cfg.expect 'mac' '')
        $rec = @(Get-GuardProp $st 'repairs' @())
        try {
            Invoke-GuardOp DhcpFallback $mac
            $rec += New-Object psobject -Property @{ rung = 'DhcpFallback'; ok = $true; detail = 'management port set to DHCP so the node keeps a path'; utc = (Get-GuardNow).ToString('o') }
            Set-GuardProp $st 'repairs' @($rec)
            $failed = @(Wait-GuardChecks $cfg $st 45)
        }
        catch { Write-GuardLog $cfg ('DHCP fallback failed: ' + $_.Exception.Message) }
        $verified = ($failed.Count -eq 0)
    }
    Set-GuardProp $st 'verified' $verified
    $text = $reason
    if (-not $verified) { $text += ' The management path could not be verified after the restore: check the node at the console.' }
    return (Complete-GuardFinal $cfg $st $FinalState $text)
}

# ---- repair ladder: returns @{ recovered; undone; rung }
function Invoke-GuardRepair($cfg, $st, $failed) {
    $names = @($failed | ForEach-Object { $_.name })
    $settle = [int](Get-GuardProp $cfg 'repairSeconds' 45)
    $items = @(Get-GuardItemList $cfg)
    $map = @{ address = @('nic-static', 'nic-clean'); gateway = @('nic-static', 'nic-clean', 'nic-dns'); dns = @('nic-dns', 'nic-static'); arc = @('nic-static', 'nic-clean', 'nic-dns', 'winrm'); winrm = @('winrm', 'icmp', 'rdp') }
    $candidateKinds = @()
    foreach ($n in $names) { if ($map.ContainsKey($n)) { $candidateKinds += $map[$n] } }
    $candidateKinds = @($candidateKinds | Select-Object -Unique)
    $rungs = @()
    if ($names -contains 'arc') { $rungs += , @('RestartArcAgent', $null, $false) }
    $rungs += , @('ReapplyConfig', $null, $false)
    $rev = @($items); [array]::Reverse($rev)
    foreach ($i in $rev) { if ($candidateKinds -contains [string]$i.kind -and [string]$i.kind -ne 'hostname') { $rungs += , @('RestoreItem', $i, $true) } }
    foreach ($i in $rev) { if ([string]$i.kind -eq 'nic-disable') { $rungs += , @('ReEnableAdapter', $i, $true) } }
    $rungs += , @('RestartNic', $null, $false)
    foreach ($r in $rungs) {
        $rung = $r[0]; $item = $r[1]; $undo = $r[2]
        if ((Get-GuardNow) -gt (ConvertTo-GuardTime ($st.deadlineUtc))) { Write-GuardLog $cfg 'the window is over; going to the whole restore'; break }
        Set-GuardState $cfg $st 'Repairing' ('rung ' + $rung + $(if ($item) { ' (' + $item.id + ')' } else { '' }) + ' for ' + ($names -join ', '))
        $detail = ''
        $ok = $true
        try {
            switch ($rung) {
                'RestartArcAgent' { Invoke-GuardOp RestartArcAgent; $detail = 'himds, GCArcService and ExtensionService restarted' }
                'ReapplyConfig' { foreach ($i in $items) { Invoke-GuardOp ApplyItem $i }; $detail = 'the intended configuration applied again' }
                'RestoreItem' { $f = @(Restore-GuardItems $cfg $st @([string]$item.id)); if ($f.Count) { throw ($f -join '; ') }; $detail = ('snapshot of ' + $item.id + ' restored') }
                'ReEnableAdapter' { Invoke-GuardOp EnableAdapter ([string]$item.mac); $done = @(Get-GuardProp $st 'restoredItems' @()) + [string]$item.id; Set-GuardProp $st 'restoredItems' @($done | Select-Object -Unique); $detail = ('adapter ' + $item.mac + ' enabled') }
                'RestartNic' { Invoke-GuardOp RestartNic ([string](Get-GuardProp $cfg.expect 'mac' '')); $detail = 'management port restarted' }
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

# ---- completion: checks, repair, proof, commit
function Complete-GuardChange($cfg, $st) {
    Set-GuardState $cfg $st 'Checking'
    $failed = @(Wait-GuardChecks $cfg $st ([int](Get-GuardProp $cfg 'checkSeconds' 120)))
    if ($failed.Count) {
        $repair = Invoke-GuardRepair $cfg $st $failed
        if (-not $repair.recovered) { return (Invoke-GuardFullRollback $cfg $st ('Checks failed (' + (($failed | ForEach-Object { $_.name + ': ' + $_.detail }) -join '; ') + ') and no repair worked; the snapshot was restored.')) }
        if ($repair.undone) {
            $restored = @(Get-GuardProp $st 'restoredItems' @())
            Set-GuardProp $st 'partial' $true
            return (Complete-GuardFinal $cfg $st 'RolledBack' ('Checks failed (' + (($failed | ForEach-Object { $_.name + ': ' + $_.detail }) -join '; ') + '). Rung ' + $repair.rung + ' restored ' + ($restored -join ', ') + ' and the node is healthy; the other items stay applied.'))
        }
    }
    if ([string]$cfg.proof -eq 'ack') {
        $deadline = ConvertTo-GuardTime ($st.deadlineUtc)
        while (-not (Invoke-GuardOp Exists (Get-GuardFile $cfg '.ack'))) {
            if ((Get-GuardNow) -ge $deadline) { return (Invoke-GuardFullRollback $cfg $st ('No acknowledgement from the operator host within ' + $cfg.windowMinutes + ' minutes (it could not reach the node on its new address); the snapshot was restored.')) }
            Invoke-GuardOp Sleep 5
            Save-GuardState $cfg $st
        }
        Set-GuardProp $st 'ackSeen' $true
    }
    $repairs = @(Get-GuardProp $st 'repairs' @() | Where-Object { $_.ok })
    $text = 'All checks passed.'
    if ($repairs.Count) { $text = 'Checks passed after repair (' + (($repairs | ForEach-Object { $_.rung }) -join ', ') + ').' }
    return (Complete-GuardFinal $cfg $st 'Committed' $text)
}

# ---- apply
function Start-GuardApply($cfg, $st) {
    $nics = @(Invoke-GuardOp GetNics)
    $refusal = Get-GuardRefusal $cfg $nics
    if ($refusal) { return (Complete-GuardFinal $cfg $st 'Refused' $refusal) }
    $mac = [string](Get-GuardProp $cfg.expect 'mac' '')
    $mgmtNic = @($nics | Where-Object { $_.mac -eq $mac } | Select-Object -First 1)
    $old = ''
    if ($mgmtNic.Count) { $old = (@($mgmtNic[0].ips | Where-Object { $_.ip -notlike '169.254.*' } | ForEach-Object { $_.ip }) -join ',') }
    Set-GuardProp $st 'oldAddress' $old
    foreach ($i in (Get-GuardItemList $cfg)) {
        if (-not (Test-GuardManagementItem $i)) { continue }
        Set-GuardProp $st 'newAddress' ([string]$i.ip)
        $already = ($mgmtNic.Count -gt 0) -and (@($mgmtNic[0].ips | Where-Object { $_.ip -eq [string]$i.ip }).Count -gt 0)
        if ([bool](Get-GuardProp $cfg 'probe' $true) -and -not $already) {
            $answers = Invoke-GuardOp ProbeAddress ([string]$i.ip) $mac
            if ($answers) { return (Complete-GuardFinal $cfg $st 'Refused' ('Another host answers on ' + $i.ip + ' (ping or neighbour entry). Refused: assigning it would duplicate the address.')) }
        }
    }
    $snapshots = @{}
    foreach ($i in (Get-GuardItemList $cfg)) { $snapshots[[string]$i.id] = Invoke-GuardOp SnapshotItem $i }
    Set-GuardProp $st 'snapshots' $snapshots
    Set-GuardProp $st 'baseline' @(Test-GuardChecks $cfg | ForEach-Object { New-Object psobject -Property @{ name = $_.name; ok = $_.ok; detail = $_.detail } })
    $now = Get-GuardNow
    Set-GuardProp $st 'appliedUtc' $now.ToString('o')
    Set-GuardProp $st 'deadlineUtc' $now.AddMinutes([double]$cfg.windowMinutes).ToString('o')
    Set-GuardState $cfg $st 'Applying'
    foreach ($i in (Get-GuardItemList $cfg)) {
        try { Invoke-GuardOp ApplyItem $i; Write-GuardLog $cfg ('applied ' + $i.id) }
        catch { return (Invoke-GuardFullRollback $cfg $st ('Item ' + $i.id + ' failed to apply (' + $_.Exception.Message + '); the snapshot was restored.')) }
    }
    foreach ($i in (Get-GuardItemList $cfg)) {
        if ((Test-GuardManagementItem $i) -and (Invoke-GuardOp IsDuplicate $mac ([string]$i.ip))) {
            return (Invoke-GuardFullRollback $cfg $st ('Windows reports ' + $i.ip + ' as a duplicate address: another host uses it. Refused; the snapshot was restored.') 'Refused')
        }
    }
    if ([bool](Get-GuardProp $cfg 'restartAfter' $false)) {
        Set-GuardProp $st 'rebootRequestedUtc' (Get-GuardNow).ToString('o')
        Set-GuardState $cfg $st 'PendingReboot' 'the computer name changed; the node restarts and the watchdog checks it after the boot'
        Invoke-GuardOp Reboot
        return 'PendingReboot'
    }
    return (Complete-GuardChange $cfg $st)
}

# ---- the entry point: resumable, so the watchdog can call it again after a reboot or a crash
function Invoke-GuardedChange {
    param([Parameter(Mandatory)][string]$ConfigPath, [string]$ScriptPath)
    $cfg = (Invoke-GuardOp ReadText $ConfigPath) | ConvertFrom-Json
    $statePath = Get-GuardFile $cfg '.state.json'
    if (-not (Invoke-GuardOp Exists $statePath)) { Remove-GuardWatchdog $cfg; return 'NoState' }
    $st = (Invoke-GuardOp ReadText $statePath) | ConvertFrom-Json
    $final = @('Committed', 'RolledBack', 'Refused', 'RollbackFailed')
    if ($final -contains [string]$st.state) { Remove-GuardWatchdog $cfg; return [string]$st.state }
    $now = Get-GuardNow
    $running = @('Applying', 'Checking', 'Repairing')
    if (($running -contains [string]$st.state) -and (Get-GuardProp $st 'owner' '') -and [string]$st.owner -ne $script:GuardInstance) {
        if (($now - (ConvertTo-GuardTime ($st.heartbeatUtc))).TotalSeconds -lt 120) { return 'Busy' }
        Write-GuardLog $cfg ('the script that owned this change (' + $st.owner + ') stopped; taking over in state ' + $st.state)
    }
    if ($ScriptPath -and (Get-GuardProp $st 'scriptSha256' '')) {
        $actual = [string](Invoke-GuardOp FileHash $ScriptPath)
        if ($actual -ine [string]$st.scriptSha256) {
            if ([string]$st.state -eq 'Staged') { return (Complete-GuardFinal $cfg $st 'Refused' ('The staged script has SHA-256 ' + $actual + ', the state file says ' + $st.scriptSha256 + '. Not run.')) }
            return (Complete-GuardFinal $cfg $st 'RollbackFailed' ('The staged script differs from the one recorded (SHA-256 ' + $actual + '); not run, the node was left as it is. Check it at the console.'))
        }
    }
    switch ([string]$st.state) {
        'Staged' {
            $start = (ConvertTo-GuardTime ($st.stagedUtc)).AddSeconds([double](Get-GuardProp $cfg 'startDelaySeconds' 20))
            $wait = ($start - $now).TotalSeconds
            if ($wait -gt 0) { Invoke-GuardOp Sleep ([int][math]::Ceiling($wait)) }
            if ((Get-GuardNow) -gt (ConvertTo-GuardTime ($st.stagedUtc)).AddMinutes([double]$cfg.windowMinutes)) {
                return (Complete-GuardFinal $cfg $st 'RolledBack' 'The change never started inside its window; nothing was changed.')
            }
            return (Start-GuardApply $cfg $st)
        }
        'Applying' { return (Invoke-GuardFullRollback $cfg $st 'The change script stopped while it was applying (reboot or crash); the snapshot was restored.') }
        'PendingReboot' {
            $booted = [datetime](Invoke-GuardOp BootTime)
            $requested = ConvertTo-GuardTime ($st.rebootRequestedUtc)
            if ($booted -lt $requested -and ($now - $requested).TotalMinutes -lt 15) { return 'PendingReboot' }
            Set-GuardProp $st 'deadlineUtc' ((Get-GuardNow).AddMinutes([double]$cfg.windowMinutes).ToString('o'))
            return (Complete-GuardChange $cfg $st)
        }
        default { return (Complete-GuardChange $cfg $st) }
    }
}

function New-GuardRealOps {
    function Get-GuardMacKey([string]$m) { return (($m -replace '[-:\.]', '')).ToLowerInvariant() }
    function Get-GuardAdapter([string]$mac) { return (Get-NetAdapter -Physical | Where-Object { (Get-GuardMacKey $_.MacAddress) -eq (Get-GuardMacKey $mac) } | Select-Object -First 1) }
    function Get-GuardNicInfo($a) {
        $idx = $a.ifIndex
        $ips = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { New-Object psobject -Property @{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = [string]$_.PrefixOrigin } })
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
        Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
    function Restore-GuardNic($snap, [bool]$DnsOnly) {
        $a = Get-GuardAdapter ([string]$snap.mac)
        if (-not $a) { throw ('No port with MAC ' + $snap.mac) }
        if ($DnsOnly) {
            if (@($snap.dns).Count -eq 0) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses } else { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($snap.dns) }
            return
        }
        Clear-GuardNic $a
        if ([string]$snap.dhcp -eq 'Enabled') {
            Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Enabled
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses
            & ipconfig.exe /renew | Out-Null
            return
        }
        $first = $true
        foreach ($ip in @($snap.ips | Where-Object { $_.ip -notlike '169.254.*' })) {
            if ($first -and @($snap.gw).Count) { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip.ip -PrefixLength ([int]$ip.prefix) -DefaultGateway ([string]@($snap.gw)[0]) | Out-Null }
            else { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip.ip -PrefixLength ([int]$ip.prefix) | Out-Null }
            $first = $false
        }
        if (@($snap.dns).Count) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($snap.dns) }
    }
    function Test-GuardTcp([string]$hostName, [int]$port, [int]$ms = 5000) {
        $c = New-Object System.Net.Sockets.TcpClient
        try { $t = $c.ConnectAsync($hostName, $port); return ($t.Wait($ms) -and $c.Connected) } catch { return $false } finally { $c.Close() }
    }
    $ops = @{}
    $ops.Now = { return [datetime]::UtcNow }
    $ops.Sleep = { param($s) Start-Sleep -Seconds $s }
    $ops.ReadText = { param($p) return (Get-Content -LiteralPath $p -Raw) }
    $ops.WriteText = { param($p, $t) $tmp = $p + '.tmp'; [IO.File]::WriteAllText($tmp, $t, (New-Object Text.UTF8Encoding($false))); Move-Item -LiteralPath $tmp -Destination $p -Force }
    $ops.AppendText = { param($p, $t) Add-Content -LiteralPath $p -Value $t -Encoding UTF8 }
    $ops.Exists = { param($p) return (Test-Path -LiteralPath $p) }
    $ops.FileHash = { param($p) return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
    $ops.BootTime = { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }
    $ops.Reboot = { & shutdown.exe /r /t 20 /d p:2:4 /c 'Azure Local OS configuration: restart to finish a guarded change' }
    $ops.UnregisterWatchdog = { param($id) Unregister-ScheduledTask -TaskName ('AzlOsConfig-Net-' + $id) -Confirm:$false -ErrorAction SilentlyContinue }
    $ops.GetNics = { return @(Get-NetAdapter -Physical | ForEach-Object { Get-GuardNicInfo $_ }) }
    $ops.ProbeAddress = {
        param($ip, $mac)
        if (Test-Connection -ComputerName $ip -Count 2 -Quiet -ErrorAction SilentlyContinue) { return $true }
        $own = @(Get-NetAdapter -Physical | ForEach-Object { Get-GuardMacKey $_.MacAddress })
        $n = @(Get-NetNeighbor -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { @('Reachable', 'Stale', 'Delay', 'Probe', 'Permanent') -contains [string]$_.State -and $_.LinkLayerAddress -and ($own -notcontains (Get-GuardMacKey $_.LinkLayerAddress)) })
        return ($n.Count -gt 0)
    }
    $ops.IsDuplicate = { param($mac, $ip) Start-Sleep -Seconds 5; return (@(Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue | Where-Object { [string]$_.AddressState -eq 'Duplicate' }).Count -gt 0) }
    $ops.SnapshotItem = {
        param($i)
        switch ([string]$i.kind) {
            { $_ -in 'nic-static', 'nic-dns', 'nic-clean' } { $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }; return (Get-GuardNicInfo $a) }
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
                $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }
                $gateway = [string](Get-GuardProp $i 'gateway' '')
                $have = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq [string]$i.ip -and $_.PrefixOrigin -eq 'Manual' -and $_.PrefixLength -eq [int]$i.prefix }
                $route = $null
                if ($gateway) { $route = Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $gateway } }
                if (-not ($have -and ($route -or -not $gateway))) {
                    Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled
                    Clear-GuardNic $a
                    if ($gateway) { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress ([string]$i.ip) -PrefixLength ([int]$i.prefix) -DefaultGateway $gateway | Out-Null }
                    else { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress ([string]$i.ip) -PrefixLength ([int]$i.prefix) | Out-Null }
                }
                if (@(Get-GuardProp $i 'dns' @()).Count) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($i.dns) }
                $vlan = [int](Get-GuardProp $i 'vlan' 0)
                if ($vlan -gt 0) { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword 'VlanID' -RegistryValue $vlan; Restart-NetAdapter -Name $a.Name -Confirm:$false }
            }
            'nic-dns' { $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }; Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($i.servers) }
            'nic-clean' {
                $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }
                Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled
                Clear-GuardNic $a
            }
            'nic-disable' { $a = Get-GuardAdapter ([string]$i.mac); if (-not $a) { throw ('No port with MAC ' + $i.mac) }; Disable-NetAdapter -Name $a.Name -Confirm:$false }
            'winrm' {
                Set-Service -Name WinRM -StartupType Automatic
                if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
                if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count -eq 0) { Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null }
            }
            'rdp' { Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0; Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' }
            'icmp' { foreach ($n in 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In') { Enable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue } }
            'ntp' {
                $peers = (@($i.servers) | ForEach-Object { $_ + ',0x8' }) -join ' '
                & w32tm.exe /config /manualpeerlist:"$peers" /syncfromflags:manual /reliable:no /update | Out-Null
                Restart-Service w32time
                Start-Sleep -Seconds 3
                & w32tm.exe /resync /force 2>&1 | Out-Null
            }
            'hostname' { Rename-Computer -NewName ([string]$i.name) -Force }
            default { throw ('Unknown guarded item ' + [string]$i.kind) }
        }
    }
    $ops.RestoreItem = {
        param($i, $snap)
        switch ([string]$i.kind) {
            'nic-static' { Restore-GuardNic $snap $false; return $false }
            'nic-clean' { Restore-GuardNic $snap $false; return $false }
            'nic-dns' { Restore-GuardNic $snap $true; return $false }
            'nic-disable' { $a = Get-GuardAdapter ([string]$snap.mac); if ($a -and [string]$snap.status -ne 'Disabled') { Enable-NetAdapter -Name $a.Name -Confirm:$false }; return $false }
            'winrm' { Set-Service -Name WinRM -StartupType ([string]$snap.start); if ([string]$snap.status -ne 'Running') { Stop-Service WinRM -Force -ErrorAction SilentlyContinue }; return $false }
            'rdp' {
                Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ([int]$snap.deny)
                if (@($snap.rules).Count -eq 0) { Disable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue }
                return $false
            }
            'icmp' { foreach ($n in 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In') { if (@($snap.rules) -notcontains $n) { Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue } }; return $false }
            'ntp' {
                $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
                Set-ItemProperty -Path $key -Name Type -Value ([string]$snap.type)
                Set-ItemProperty -Path $key -Name NtpServer -Value ([string]$snap.peers)
                Restart-Service w32time
                return $false
            }
            'hostname' { Rename-Computer -NewName ([string]$snap.name) -Force; return $true }
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
        if ([bool](Get-GuardProp $e 'requireGateway' $true) -and @($n.gw).Count -eq 0) { return @{ ok = $false; detail = ('address ' + ($ips -join ',') + ' but no default gateway') } }
        return @{ ok = $true; detail = ($ips -join ',') + ' gw ' + (@($n.gw) -join ',') }
    }
    $ops.CheckGateway = {
        param($cfg)
        $a = Get-GuardAdapter ([string]$cfg.expect.mac)
        if (-not $a) { return @{ ok = $false; detail = 'no management port' } }
        $gw = @((Get-GuardNicInfo $a).gw)
        if (-not $gw.Count) { return @{ ok = $false; detail = 'no default gateway' } }
        if (Test-Connection -ComputerName $gw[0] -Count 3 -Quiet -ErrorAction SilentlyContinue) { return @{ ok = $true; detail = ($gw[0] + ' answers') } }
        $n = @(Get-NetNeighbor -IPAddress $gw[0] -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { @('Reachable', 'Permanent', 'Stale', 'Delay', 'Probe') -contains [string]$_.State -and $_.LinkLayerAddress })
        if ($n.Count) { return @{ ok = $true; detail = ($gw[0] + ' has a neighbour entry (ICMP may be blocked)') } }
        return @{ ok = $false; detail = ($gw[0] + ' does not answer') }
    }
    $ops.CheckDns = {
        param($cfg)
        $name = [string]@($cfg.probeHosts)[0]
        try { $r = @(Resolve-DnsName -Name $name -Type A -DnsOnly -ErrorAction Stop); if ($r.Count) { return @{ ok = $true; detail = ($name + ' resolves') } } } catch { return @{ ok = $false; detail = ($name + ' does not resolve: ' + $_.Exception.Message) } }
        return @{ ok = $false; detail = ($name + ' returned nothing') }
    }
    $ops.CheckArc = {
        param($cfg)
        $svc = Get-Service himds -ErrorAction SilentlyContinue
        $reach = $false
        foreach ($h in @($cfg.probeHosts)) { if (Test-GuardTcp ([string]$h) 443) { $reach = $true; break } }
        if (-not $svc) { return @{ ok = $reach; skipped = $true; detail = $(if ($reach) { 'no Arc agent; Azure endpoints answer on 443' } else { 'no Arc agent; Azure endpoints do not answer on 443' }) } }
        $status = ''
        try {
            $out = (& 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe' show -j 2>&1) -join ' '
            $m = [regex]::Match($out, '"status"\s*:\s*"(\w+)"')
            if ($m.Success) { $status = $m.Groups[1].Value } else { $m2 = [regex]::Match($out, 'Agent Status\s*:\s*(\w+)'); if ($m2.Success) { $status = $m2.Groups[1].Value } }
        }
        catch { $status = 'unknown' }
        $running = ([string]$svc.Status -eq 'Running')
        return @{ ok = ($running -and $reach); detail = ('himds ' + $svc.Status + ', agent status ' + $status + ', Azure endpoints ' + $(if ($reach) { 'answer' } else { 'do not answer' }) + ' on 443') }
    }
    $ops.CheckWinRm = {
        param($cfg)
        if (-not [bool](Get-GuardProp $cfg.expect 'winrm' $false)) { return @{ ok = $true; skipped = $true; detail = 'WinRM was not listening before' } }
        $s = Get-Service WinRM
        $listen = Test-GuardTcp '127.0.0.1' 5985 2000
        if (-not $listen) { $listen = Test-GuardTcp '127.0.0.1' 5986 2000 }
        return @{ ok = ([string]$s.Status -eq 'Running' -and $listen); detail = ('WinRM ' + $s.Status + ', listener ' + $(if ($listen) { 'answers' } else { 'does not answer' })) }
    }
    $ops.RestartArcAgent = { foreach ($n in 'himds', 'GCArcService', 'ExtensionService') { if (Get-Service $n -ErrorAction SilentlyContinue) { Restart-Service -Name $n -Force -ErrorAction SilentlyContinue } } }
    $ops.EnableAdapter = { param($mac) $a = Get-GuardAdapter $mac; if ($a) { Enable-NetAdapter -Name $a.Name -Confirm:$false } }
    $ops.RestartNic = { param($mac) $a = Get-GuardAdapter $mac; if ($a) { Restart-NetAdapter -Name $a.Name -Confirm:$false; Start-Sleep -Seconds 10 } }
    $ops.DhcpFallback = {
        param($mac)
        $a = Get-GuardAdapter $mac; if (-not $a) { return }
        Clear-GuardNic $a
        Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses
        & ipconfig.exe /renew | Out-Null
    }
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
$dir = [string](Get-P $P 'dir' $stateDir)
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$utc = (Get-Date).ToUniversalTime()
$busy = ''
foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'net-*.state.json' -ErrorAction SilentlyContinue)) {
    try { $s = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (@('Staged', 'Applying', 'Checking', 'Repairing', 'PendingReboot') -contains [string]$s.state -and [string]$s.changeId -ne $id) {
        $age = ($utc - [datetime]::Parse([string]$s.updatedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()).TotalMinutes
        if ($age -lt 30) { $busy = [string]$s.changeId }
    }
}
if ($busy) { Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; staged = $false; busyWith = $busy }); return }

$scriptText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SCRIPT_B64__'))
$scriptPath = Join-Path $dir ('net-' + $id + '.ps1')
[IO.File]::WriteAllText($scriptPath, $scriptText, (New-Object Text.UTF8Encoding($false)))
$hash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
if ($hash -ine [string]$P.scriptSha256) { throw ('The staged script has SHA-256 ' + $hash + ', expected ' + $P.scriptSha256) }
$cfg = $P.config
$cfg | Add-Member -NotePropertyName dir -NotePropertyValue $dir -Force
ConvertTo-Json -InputObject $cfg -Depth 8 | Set-Content -LiteralPath (Join-Path $dir ('net-' + $id + '.json')) -Encoding UTF8
$state = [pscustomobject]@{ v = 1; changeId = $id; group = [string]$cfg.group; state = 'Staged'; reason = ''; stagedUtc = $utc.ToString('o'); updatedUtc = $utc.ToString('o'); heartbeatUtc = $utc.ToString('o'); owner = ''
    scriptSha256 = $hash; proof = [string]$cfg.proof; items = @($cfg.items | ForEach-Object { [string]$_.id }); watchdog = $false }
$statePath = Join-Path $dir ('net-' + $id + '.state.json')
ConvertTo-Json -InputObject $state -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8

# The watchdog: a scheduled task that runs the script at startup and every minute for the window. It is how the change survives the
# end of this command, a reboot and a crash; the script removes the task itself once the state is final.
$taskName = 'AzlOsConfig-Net-' + $id
$minutes = [int]$cfg.windowMinutes + 20
$mode = 'task'
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"')
    $startup = New-ScheduledTaskTrigger -AtStartup
    $repeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Minutes $minutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes $minutes) -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startup, $repeat) -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $state.watchdog = $true
}
catch {
    $mode = 'process'
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"') -WindowStyle Hidden
}
ConvertTo-Json -InputObject $state -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; staged = $true; changeId = $id; stagedUtc = $utc.ToString('o'); scriptSha256 = $hash; watchdog = [bool]$state.watchdog; startedBy = $mode })
'@

$script:StatusBody = @'
# AZL-GUARD-STATUS
$id = [string](Get-P $P 'changeId' '')
$dir = [string](Get-P $P 'dir' $stateDir)
$statePath = ''
if ($id) { $statePath = Join-Path $dir ('net-' + $id + '.state.json') }
else {
    $latest = Get-ChildItem -LiteralPath $dir -Filter 'net-*.state.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $statePath = $latest.FullName }
}
if (-not $statePath -or -not (Test-Path -LiteralPath $statePath)) { Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; found = $false; changeId = $id }); return }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$id = [string]$state.changeId
$ack = $false
if (Get-P $P 'ack' $false) { New-Item -ItemType File -Force -Path (Join-Path $dir ('net-' + $id + '.ack')) | Out-Null; $ack = $true }
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
            ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { '{0}/{1}/{2}' -f $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin })
            gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop })
            dns = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        }
    }
}
$compact = [pscustomobject]@{
    changeId = $id; group = [string](Get-P $state 'group' ''); state = [string]$state.state; reason = [string](Get-P $state 'reason' ''); updatedUtc = [string](Get-P $state 'updatedUtc' ''); heartbeatUtc = [string](Get-P $state 'heartbeatUtc' '')
    oldAddress = [string](Get-P $state 'oldAddress' ''); newAddress = [string](Get-P $state 'newAddress' ''); scriptSha256 = [string](Get-P $state 'scriptSha256' ''); verified = (Get-P $state 'verified' $null); partial = (Get-P $state 'partial' $false)
    restoredItems = @(Get-P $state 'restoredItems' @()); watchdog = [bool](Get-P $state 'watchdog' $false)
    repairs = @(Get-P $state 'repairs' @() | ForEach-Object { [pscustomobject]@{ rung = [string]$_.rung; item = [string](Get-P $_ 'item' ''); ok = [bool]$_.ok; detail = [string]$_.detail } })
    checks = @(Get-P $state 'checks' @() | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; ok = [bool]$_.ok; detail = [string]$_.detail } })
}
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; found = $true; state = $compact; log = $log; scriptSha256Actual = $actual; live = $live; ackWritten = $ack; nowUtc = (Get-Date).ToUniversalTime().ToString('o') })
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
