#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the orchestrator side of the guarded change and for the remoting rules: staging that returns at once, the confirmation through a new
# session on the new address, reconnect polling with a fake clock (WinRM and Arc), the node's verdicts, PendingReconciliation, DHCP-off blocked without a
# gateway, an idempotent re-run, stale run command cleanup, and the transport settings. No node, no network and no Azure is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NetworkSafe.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A test credential for a transport object; it is never used.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport members take the parameters of the real ones.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    foreach ($m in 'AzlNodeTransport', 'AzlNodeGuard', 'AzlGuardedChange', 'AzlRemoting', 'AzlOsConfigurationEvents') { Import-Module (Join-Path $dir "$m.psm1") -Force }
    Mock -ModuleName AzlGuardedChange New-AzlChangeId { 'abc123def456' }

    function ConvertTo-Line([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }

    # The spec and state of one node, the parts the guarded change reads.
    function New-Spec { [pscustomobject]@{ Name = 'n1'; Management = [pscustomobject]@{ Mac = '00005e005311'; Ip = '192.0.2.60'; Prefix = 24; Gateway = '192.0.2.1'; Dns = @('192.0.2.4'); Vlan = 0 } } }
    function New-State { [pscustomobject]@{ nics = @([pscustomobject]@{ n = 'Port0'; mac = '00005e005311'; ips = @('192.0.2.50/24/Dhcp'); gw = @('192.0.2.1'); dhcp = 'Enabled'; dns = @() }); remote = [pscustomobject]@{ winrm = 'Running'; listeners = 1 } } }
    function New-MgmtItem { @{ id = 'Network/00005e005311'; kind = 'nic-static'; management = $true; mac = '00005e005311'; ip = '192.0.2.60'; prefix = 24; gateway = '192.0.2.1'; dns = @('192.0.2.4') } }

    # A clock that never waits: Sleep moves the time.
    function New-FakeClock {
        $state = @{ Now = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc) }
        [pscustomobject]@{ State = $state; Now = { $state.Now }.GetNewClosure(); Sleep = { param($Seconds) $state.Now = $state.Now.AddSeconds($Seconds) }.GetNewClosure() }
    }

    # A transport that answers the guarded-change scripts from a scenario: { param($Kind, $Params, $Address, $Now) -> the result object }.
    function New-GuardTransport([string]$Kind, [scriptblock]$Scenario, [object]$Clock, [string]$Address = '192.0.2.50', [scriptblock]$Machine) {
        $log = [System.Collections.Generic.List[object]]::new()
        $addr = @{ Current = $Address }
        $encode = ${function:ConvertTo-Line}
        $transport = [pscustomobject]@{ Kind = $Kind; Log = $log; Addr = $addr; Invoke = $null }
        $transport.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            $what = if ($Script -match 'AZL-GUARD-STAGE') { 'Stage' } elseif ($Script -match 'AZL-GUARD-STATUS') { 'Status' } else { 'Other' }
            $log.Add([pscustomobject]@{ Kind = $what; Parameters = $Parameters; Address = $addr.Current; At = (& $Clock.Now) })
            $r = & $Scenario $what $Parameters $addr.Current (& $Clock.Now)
            [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' }
        }.GetNewClosure()
        if ($Kind -eq 'WinRM') {
            $transport | Add-Member -NotePropertyName GetAddress -NotePropertyValue ({ param($Self, $Node) $addr.Current }.GetNewClosure())
            $transport | Add-Member -NotePropertyName GetPort -NotePropertyValue ({ param($Self, $Node) 5985 })
            $transport | Add-Member -NotePropertyName SetAddress -NotePropertyValue ({ param($Self, $Node, $Address) $addr.Current = $Address; $log.Add([pscustomobject]@{ Kind = 'SetAddress'; Address = $Address }) }.GetNewClosure())
            $transport | Add-Member -NotePropertyName CloseSession -NotePropertyValue ({ param($Self, $Node) $log.Add([pscustomobject]@{ Kind = 'CloseSession' }) }.GetNewClosure())
        }
        if ($Machine) { $transport | Add-Member -NotePropertyName Machine -NotePropertyValue $Machine }
        return $transport
    }

    # The state a node reports, with the fields the orchestrator reads.
    function New-NodeStatus([string]$State, [hashtable]$More = @{}) {
        $s = @{ changeId = 'abc123def456'; group = 'Management'; state = $State; reason = "node says $State"; oldAddress = '192.0.2.50'; newAddress = '192.0.2.60'; verdict = ''; repairs = @(); deadlineUtc = '2026-11-07T10:30:00Z' }
        foreach ($k in $More.Keys) { $s[$k] = $More[$k] }
        @{ v = 1; found = $true; identityOk = $true; nowUtc = '2026-11-07T10:01:00Z'; scriptSha256Actual = (Get-AzlGuardScriptHash -ChangeId 'abc123def456'); live = @{ ips = @('192.0.2.60/24/Manual/Preferred'); gw = @('192.0.2.1') }; state = $s }
    }
    function Get-Sink($context) { @($context.Sink | ForEach-Object { $_.state }) }
}

Describe 'Staging' {
    It 'returns at once: the stage script is one short call, then the session is closed before anything is awaited' {
        $clock = New-FakeClock
        $order = [System.Collections.Generic.List[string]]::new()
        $t = New-GuardTransport 'WinRM' { param($Kind, $P, $Address, $Now) if ($Kind -eq 'Stage') { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } else { New-NodeStatus 'Committed' } } $clock
        $null = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        @($t.Log | Where-Object Kind -in 'Stage', 'CloseSession', 'Status').Kind[0..1] | Should -Be @('Stage', 'CloseSession')
        $stage = @($t.Log | Where-Object Kind -eq 'Stage')[0]
        $stage.Parameters.changeId | Should -Be 'abc123def456'
        $stage.Parameters.scriptSha256 | Should -Be (Get-AzlGuardScriptHash -ChangeId 'abc123def456')
        $stage.Parameters.config.expect.currentIp | Should -Be '192.0.2.50'
        $stage.Parameters.config.expect.ip | Should -Be '192.0.2.60'
        $stage.Parameters.config.confirmMinutes | Should -Be 10
    }

    It 'a change that is already in progress on the node is not staged again' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' { param($Kind, $P, $A, $N) @{ staged = $false; busyWith = 'zzz999yyy888' } } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        $o.State | Should -Be 'Unknown'
        $o.Reason | Should -Match 'zzz999yyy888'
        @($t.Log | Where-Object Kind -eq 'Status').Count | Should -Be 0
    }
}

Describe 'Committed over WinRM: the address switches and the confirmation arrives on the new address' {
    It 'probes the new address, falls back to the old one, writes the token only on the new address and commits' {
        $clock = New-FakeClock
        $script:Probes = [System.Collections.Generic.List[string]]::new()
        $script:Phase = 0
        $t = New-GuardTransport 'WinRM' {
            param($Kind, $P, $Address, $Now)
            if ($Kind -eq 'Stage') { return @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } }
            $script:Phase++
            switch ($script:Phase) { 1 { New-NodeStatus 'Verifying' } 2 { New-NodeStatus 'AwaitingConfirm' } default { New-NodeStatus 'Committed' } }
        } $clock
        # The new address answers only from the third probe on; the old address answers all the time.
        $probe = { param($Address, $Port) $script:Probes.Add("$Address`:$Port"); ($Address -eq '192.0.2.50') -or ($script:Probes.Count -ge 5) }
        $ev = New-AzlGuardEventContext
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -Event $ev -PortProbe $probe
        $o.State | Should -Be 'Committed'
        $o.Address | Should -Be '192.0.2.60'
        $statuses = @($t.Log | Where-Object Kind -eq 'Status')
        # reads on the old address never carry the token; reads on the new address do, and it is the token of this change
        foreach ($s in $statuses) {
            if ($s.Address -eq '192.0.2.50') { $s.Parameters.ContainsKey('ackToken') | Should -BeFalse }
            else { $s.Parameters.ackToken | Should -Be (Get-AzlGuardToken -ChangeId 'abc123def456' -ScriptHash (Get-AzlGuardScriptHash -ChangeId 'abc123def456') -Cookie 'ck') }
            $s.Parameters.cookie | Should -Be 'ck'
            $s.Parameters.machineSid | Should -Be 'S-1'
        }
        @($statuses | Where-Object { $_.Parameters.ContainsKey('ackToken') }).Count | Should -BeGreaterThan 0
        $setAddresses = @($t.Log | Where-Object Kind -eq 'SetAddress' | ForEach-Object { $_.Address })
        $setAddresses[-1] | Should -Be '192.0.2.60'
        $states = Get-Sink $ev
        foreach ($e in 'NetworkChangeStaged', 'NodeReconnecting', 'NodeReconnected', 'NetworkChangeVerifying', 'NetworkChangeAwaitingConfirm', 'NetworkChangeCommitted') { $states | Should -Contain $e }
        $committed = @($ev.Sink | Where-Object state -eq 'NetworkChangeCommitted')[0]
        $committed.evidence | Should -Match '192\.0\.2\.50'
        $committed.evidence | Should -Match '192\.0\.2\.60'
        $committed.oldAddress | Should -Be '192.0.2.50'
        $committed.newAddress | Should -Be '192.0.2.60'
    }

    It 'a node that says Committed while its port does not hold the new address is not trusted' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' {
            param($Kind, $P, $Address, $Now)
            if ($Kind -eq 'Stage') { return @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } }
            $s = New-NodeStatus 'Committed'; $s.live = @{ ips = @('192.0.2.50/24/Dhcp/Preferred'); gw = @('192.0.2.1') }; $s
        } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        $o.State | Should -Be 'Failed'
        $o.Reason | Should -Match 'could not be verified'
    }
}

Describe "The node verdicts" {
    It 'RolledBack: the failure carries the node''s reason and the next action, the old address is used again, and an event says so' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' {
            param($Kind, $P, $Address, $Now)
            if ($Kind -eq 'Stage') { return @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } }
            $s = New-NodeStatus 'RolledBack' @{ reason = 'No confirmation from the orchestrator within 10 minutes.'; verdict = 'RolledBackVerified'; repairs = @(@{ rung = 'ReProbe'; item = ''; ok = $false; detail = 'x' }) }
            $s.live = @{ ips = @('192.0.2.50/24/Manual/Preferred'); gw = @('192.0.2.1') }; $s
        } $clock
        $ev = New-AzlGuardEventContext
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -Event $ev -PortProbe { param($a, $p) $a -eq '192.0.2.50' }
        $o.State | Should -Be 'RolledBack'
        $o.Reason | Should -Match 'No confirmation'
        $o.NextAction | Should -Match 'RolledBackVerified'
        $o.NextAction | Should -Match 'not retried automatically'
        $o.Address | Should -Be '192.0.2.50'
        (Get-Sink $ev) | Should -Contain 'NetworkChangeRolledBack'
        @($ev.Sink | Where-Object state -eq 'NetworkChangeRolledBack')[0].evidence | Should -Match '192\.0\.2\.60'
    }

    It 'RolledBack with no answer on the new address: the old address is used to read it (the proof never arrived)' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' { param($Kind, $P, $A, $N) if ($Kind -eq 'Stage') { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } else { New-NodeStatus 'RolledBack' } } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { param($a, $p) $a -eq '192.0.2.50' }
        $o.State | Should -Be 'RolledBack'
        @($t.Log | Where-Object Kind -eq 'Status') | ForEach-Object { $_.Address | Should -Be '192.0.2.50'; $_.Parameters.ContainsKey('ackToken') | Should -BeFalse }
    }

    It 'Refused: nothing was changed and the reason is the node''s' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' { param($Kind, $P, $A, $N) if ($Kind -eq 'Stage') { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } else { New-NodeStatus 'Refused' @{ reason = 'Another host answers on 192.0.2.60.' } } } $clock
        $ev = New-AzlGuardEventContext
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -Event $ev -PortProbe { $true }
        $o.State | Should -Be 'Refused'
        $o.Reason | Should -Match 'Another host answers'
        (Get-Sink $ev) | Should -Contain 'NetworkChangeRefused'
    }

    It 'Failed: the restore was not verified, and the next action is the console' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' { param($Kind, $P, $A, $N) if ($Kind -eq 'Stage') { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } else { New-NodeStatus 'Failed' @{ verdict = 'RollbackUnverified' } } } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        $o.State | Should -Be 'Failed'
        $o.NextAction | Should -Match 'console'
    }

    It 'a different machine answering (cookie or SID mismatch) is Refused, never confirmed' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' { param($Kind, $P, $A, $N) if ($Kind -eq 'Stage') { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } else { @{ found = $true; identityOk = $false } } } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        $o.State | Should -Be 'Refused'
        $o.Reason | Should -Match 'not the node that was staged'
    }

    It 'a node that never answers is PendingReconciliation (Unknown), never a failure of the change' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'WinRM' { param($Kind, $P, $A, $N) @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } $clock
        $ev = New-AzlGuardEventContext
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -Event $ev -PortProbe { $false } -Setting @{ reconnectWaitMinutes = 2 }
        $o.State | Should -Be 'Unknown'
        $o.State | Should -Not -Be 'Failed'
        $o.NextAction | Should -Match 'PendingReconciliation'
        $o.NextAction | Should -Match 'reverts the change by itself'
        (Get-Sink $ev) | Should -Not -Contain 'NetworkChangeCommitted'
        ($clock.State.Now - [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc)).TotalMinutes | Should -BeGreaterOrEqual 2
    }

    It 'keeps waiting past the reconnect window while the node''s own deadline has not passed' {
        $clock = New-FakeClock
        $script:Calls = 0
        $t = New-GuardTransport 'WinRM' {
            param($Kind, $P, $A, $N)
            if ($Kind -eq 'Stage') { return @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } }
            $script:Calls++
            if ($script:Calls -lt 12) { New-NodeStatus 'Verifying' } else { New-NodeStatus 'Committed' }
        } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true } -Setting @{ reconnectWaitMinutes = 1 }
        $o.State | Should -Be 'Committed'
    }
}

Describe 'Arc Run Command (explicit): reconnect polling with a fake clock' {
    It 'waits through a Disconnected gap, reads only when Connected with a newer last status change, then confirms' {
        $clock = New-FakeClock
        $statusAt = [System.Collections.Generic.List[datetime]]::new()
        $machine = {
            param($Self, $Node)
            $secs = ((& $clock.Now) - [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc)).TotalSeconds
            if ($secs -lt 30) { [pscustomobject]@{ Found = $true; Status = 'Connected'; LastStatusChange = [datetime]::SpecifyKind([datetime]'2026-11-07T09:00:00', [DateTimeKind]::Utc) } }
            elseif ($secs -lt 150) { [pscustomobject]@{ Found = $true; Status = 'Disconnected'; LastStatusChange = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:20', [DateTimeKind]::Utc) } }
            elseif ($secs -lt 180) { [pscustomobject]@{ Found = $true; Status = 'Expired'; LastStatusChange = [datetime]::SpecifyKind([datetime]'2026-11-07T10:02:30', [DateTimeKind]::Utc) } }
            else { [pscustomobject]@{ Found = $true; Status = 'Connected'; LastStatusChange = [datetime]::SpecifyKind([datetime]'2026-11-07T10:03:00', [DateTimeKind]::Utc) } }
        }.GetNewClosure()
        $script:ArcPhase = 0
        $t = New-GuardTransport 'ArcRunCommand' {
            param($Kind, $P, $A, $N)
            if ($Kind -eq 'Stage') { return @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } }
            $script:ArcPhase++
            if ($script:ArcPhase -eq 1) { New-NodeStatus 'AwaitingConfirm' } else { New-NodeStatus 'Committed' }
        } $clock '' $machine
        $ev = New-AzlGuardEventContext
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock -Event $ev
        $o.State | Should -Be 'Committed'
        $first = @($t.Log | Where-Object Kind -eq 'Status')[0]
        ($first.At - [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc)).TotalSeconds | Should -BeGreaterOrEqual 180
        $first.Parameters.ackToken | Should -Not -BeNullOrEmpty
        $reconnected = @($ev.Sink | Where-Object state -eq 'NodeReconnected')[0]
        $reconnected.sawDisconnect | Should -BeTrue
    }

    It 'still looks now and then when the Arc machine never reports Disconnected' {
        $clock = New-FakeClock
        $machine = { param($Self, $Node) [pscustomobject]@{ Found = $true; Status = 'Connected'; LastStatusChange = [datetime]::SpecifyKind([datetime]'2026-11-07T09:00:00', [DateTimeKind]::Utc) } }
        $t = New-GuardTransport 'ArcRunCommand' { param($Kind, $P, $A, $N) if ($Kind -eq 'Stage') { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } else { New-NodeStatus 'Committed' } } $clock '' $machine
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @(New-MgmtItem) -Spec (New-Spec) -State (New-State) -Clock $clock
        $o.State | Should -Be 'Committed'
    }
}

Describe 'Order: DHCP off on the other ports only with a default gateway' {
    It 'blocks the group (no stage) while the management port has no default gateway' {
        $state = New-State; $state.nics[0].gw = @()
        $r = Test-AzlGuardNetworkPrecondition -Spec (New-Spec) -State $state
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'no default gateway'
    }
    It 'blocks the group while the Arc machine is not Connected' {
        $clock = New-FakeClock
        $t = New-GuardTransport 'ArcRunCommand' { param($Kind, $P, $A, $N) @{} } $clock '' { param($Self, $Node) [pscustomobject]@{ Found = $true; Status = 'Disconnected'; LastStatusChange = $null } }
        (Test-AzlGuardNetworkPrecondition -Spec (New-Spec) -State (New-State) -Transport $t -Node n1).Ok | Should -BeFalse
    }
    It 'allows it with a gateway' { (Test-AzlGuardNetworkPrecondition -Spec (New-Spec) -State (New-State)).Ok | Should -BeTrue }

    It 'puts the actions in the order the node needs them' {
        $todo = @(
            [pscustomobject]@{ Apply = @{ id = 'a'; kind = 'nic-clean' } }, [pscustomobject]@{ Apply = @{ id = 'b'; kind = 'nic-static'; management = $true } },
            [pscustomobject]@{ Apply = @{ id = 'c'; kind = 'ntp' } }, [pscustomobject]@{ Apply = @{ id = 'd'; kind = 'hostname' } }, [pscustomobject]@{ Apply = @{ id = 'e'; kind = 'mpio-feature' } },
            [pscustomobject]@{ Apply = @{ id = 'f'; kind = 'nic-static' } }, [pscustomobject]@{ Apply = @{ id = 'g'; kind = 'nic-vlan' } }, [pscustomobject]@{ Apply = @{ id = 'h'; kind = 'nic-disable' } })
        $s = Split-AzlGuardedAction -Todo $todo
        @($s.Management.Apply.id) | Should -Be @('b')
        @($s.Vlan.Apply.id) | Should -Be @('g')
        @($s.Inline.Apply.id) | Should -Be @('e', 'f')
        @($s.Services.Apply.id) | Should -Be @('c')
        @($s.Hostname.Apply.id) | Should -Be @('d')
        @($s.Network.Apply.id) | Should -Be @('a', 'h')
    }
}

Describe 'Idempotent re-run and the node loop' {
    BeforeAll {
        Import-Module (Join-Path $dir 'AzlNodeConfiguration.psm1') -Force
        Import-Module (Join-Path $dir 'AzlNodePayload.psm1') -Force
        Import-Module powershell-yaml
        $script:Fixture = Join-Path (Join-Path $repo 'tests') (Join-Path 'fixtures' 'infrastructure.fc-san.yml')
        Import-Module (Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') (Join-Path 'infrastructure' 'AzlInfrastructure.psm1')) -Force
        $infra = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
        $script:NodeSpec = Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0]
        function New-ConfiguredNode([object]$Spec) {
            $nics = foreach ($p in $Spec.Ports) {
                [pscustomobject]@{ n = "OS$($p.Name)"; mac = $p.Mac; st = $(if ($p.Roles -contains 'unused') { 'Disabled' } else { 'Up' }); pci = 'PCI\VEN_15B3&DEV_101D'; drv = '24.4.1.0'; desc = 'x'; dhcp = 'Disabled'
                    ips = $(if ($p.IsManagement) { @("$($Spec.Management.Ip)/$($Spec.Management.Prefix)/Manual") } else { @() }); gw = $(if ($p.IsManagement) { @($Spec.Management.Gateway) } else { @() }); dns = $(if ($p.IsManagement) { @($Spec.Management.Dns) } else { @() }); vlan = $null }
            }
            [pscustomobject]@{
                v = 1; host = $Spec.Hostname; boot = '2026-11-07T01:00:00Z'; os = '10.0.26100.1'; reboot = $false; nics = @($nics)
                remote = [pscustomobject]@{ winrm = 'Running'; winrmStart = 'Automatic'; listeners = 1; rdpDeny = 0; rdpRules = 3; icmp4 = 1; icmp6 = 1 }
                time = [pscustomobject]@{ type = 'NTP'; peers = ($Spec.Ntp | ForEach-Object { "$_,0x8" }) -join ' '; src = $Spec.Ntp[0] }
                sbe = @(); drv = @(); admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $true }; stor = [pscustomobject]@{ pools = 0; vdisks = 0; dirty = @() }
                san = [pscustomobject]@{ feature = 'Enabled'; hw = @('DellEMC|PowerStore'); lb = 'RR'; set = [pscustomobject]@{ RetryCount = '3'; UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '10'; DiskTimeoutValue = '30' }
                    fc = @($Spec.San.ExpectedWwpn | ForEach-Object { [pscustomobject]@{ wwpn = $_; up = 'Online' } }); iqn = @(); iscsiSvc = ''; iscsiClaim = ''
                    disks = @([pscustomobject]@{ n = 1; bus = 'Fibre Channel'; gb = 300; ps = 'RAW'; sn = 'SERIAL-INFRA'; uid = 'UID-INFRA'; lun = 0; paths = 4; st = 'Online' }, [pscustomobject]@{ n = 2; bus = 'Fibre Channel'; gb = 50; ps = 'RAW'; sn = 'SERIAL-PERF'; uid = 'UID-PERF'; lun = 1; paths = 4; st = 'Online' }) }
                err = [pscustomobject]@{}
            }
        }
        function New-NodeTransport([object[]]$States, [scriptblock]$Guard, [object]$Clock) {
            $queue = [System.Collections.Generic.Queue[object]]::new(); foreach ($s in $States) { $queue.Enqueue($s) }
            $last = [ref]$States[-1]
            $log = [System.Collections.Generic.List[object]]::new()
            $encode = ${function:ConvertTo-Line}
            $addr = @{ Current = '192.0.2.11' }
            $tr = [pscustomobject]@{ Kind = 'WinRM'; Log = $log; Invoke = $null; Stage = $null }
            $tr.Invoke = {
                param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
                $kind = if ($Script -match 'AZL-GUARD-STAGE') { 'Stage' } elseif ($Script -match 'AZL-GUARD-STATUS') { 'Status' } else { 'Read' }
                $log.Add([pscustomobject]@{ Kind = $kind; Parameters = $Parameters; Address = $addr.Current })
                $r = if ($kind -eq 'Read') { if ($queue.Count -gt 0) { $last.Value = $queue.Dequeue() }; $last.Value } else { & $Guard $kind $Parameters $addr.Current }
                [pscustomobject]@{ Output = (& $encode $r); Failed = $false; Error = ''; State = 'Succeeded' }
            }.GetNewClosure()
            $tr | Add-Member -NotePropertyName GetAddress -NotePropertyValue ({ param($Self, $Node) $addr.Current }.GetNewClosure())
            $tr | Add-Member -NotePropertyName GetPort -NotePropertyValue ({ param($Self, $Node) 5985 })
            $tr | Add-Member -NotePropertyName SetAddress -NotePropertyValue ({ param($Self, $Node, $Address) $addr.Current = $Address }.GetNewClosure())
            $tr | Add-Member -NotePropertyName CloseSession -NotePropertyValue ({ param($Self, $Node) })
            return $tr
        }
    }

    It 'a node that already has the address stages nothing and changes nothing, however often it runs' {
        $clock = New-FakeClock
        $state = New-ConfiguredNode $script:NodeSpec
        $t = New-NodeTransport @($state) { throw 'no guarded change expected' } $clock
        1..2 | ForEach-Object { $r = Invoke-AzlNodeConfiguration -Spec $script:NodeSpec -Transport $t -Execute -Clock $clock -PortProbe { $true } -SecretResolver { 'x' }; $r.Converged | Should -BeTrue }
        @($t.Log | Where-Object Kind -in 'Stage', 'Status') | Should -BeNullOrEmpty
    }

    It 'a wrong management address is one guarded change, confirmed before the next pass reads the node again' {
        $clock = New-FakeClock
        $good = New-ConfiguredNode $script:NodeSpec
        $bad = New-ConfiguredNode $script:NodeSpec
        $mgmt = $bad.nics | Where-Object { $_.mac -eq $script:NodeSpec.Management.Mac }
        $mgmt.ips = @('192.0.2.200/24/Dhcp'); $mgmt.dhcp = 'Enabled'
        $spec = $script:NodeSpec
        $t = New-NodeTransport @($bad, $good) {
            param($Kind, $P, $Address)
            if ($Kind -eq 'Stage') { return @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } }
            $s = New-NodeStatus 'Committed' @{ newAddress = $spec.Management.Ip; oldAddress = '192.0.2.200' }
            $s.live = @{ ips = @("$($spec.Management.Ip)/$($spec.Management.Prefix)/Manual/Preferred"); gw = @($spec.Management.Gateway) }
            $s.scriptSha256Actual = ''
            $s
        } $clock
        $r = Invoke-AzlNodeConfiguration -Spec $spec -Transport $t -Execute -Clock $clock -PortProbe { $true } -SecretResolver { 'x' }
        $kinds = @($t.Log | ForEach-Object { $_.Kind })
        $kinds | Should -Contain 'Stage'
        $kinds.IndexOf('Stage') | Should -BeGreaterThan $kinds.IndexOf('Read')
        ($kinds | Select-Object -Skip ($kinds.IndexOf('Stage') + 1) | Select-Object -First 5) | Should -Contain 'Status'
        @($t.Log | Where-Object Kind -eq 'Stage')[0].Parameters.config.items[0].management | Should -BeTrue
        $r.Converged | Should -BeTrue
        @($r.Guard)[0].State | Should -Be 'Committed'
    }

    It 'stops the node when the change is rolled back: nothing else is applied and the reason is in the changes' {
        $clock = New-FakeClock
        $bad = New-ConfiguredNode $script:NodeSpec
        ($bad.nics | Where-Object { $_.mac -eq $script:NodeSpec.Management.Mac }).ips = @('192.0.2.200/24/Dhcp')
        $bad.time.peers = 'time.windows.com,0x8'
        $t = New-NodeTransport @($bad) { param($Kind, $P, $Address) if ($Kind -eq 'Stage') { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } } else { New-NodeStatus 'RolledBack' @{ reason = 'Another host answers.' } } } $clock
        $r = Invoke-AzlNodeConfiguration -Spec $script:NodeSpec -Transport $t -Execute -Clock $clock -PortProbe { $true } -SecretResolver { 'x' }
        $r.Converged | Should -BeFalse
        @($t.Log | Where-Object Kind -eq 'Stage').Count | Should -Be 1
        ($r.Changes | Where-Object { $_.Id -like 'NetworkChange/*' }).Status | Should -Be 'failed'
        ($r.Changes | Where-Object { $_.Id -like 'NetworkChange/*' }).Detail | Should -Match 'Another host answers'
    }

    It 'DHCP off on the other ports is blocked (a clear reason, an event, nothing staged) while the Arc machine is not Connected' {
        $clock = New-FakeClock
        $bad = New-ConfiguredNode $script:NodeSpec
        ($bad.nics | Where-Object { $_.mac -eq '00005e005312' }).dhcp = 'Enabled'
        $t = New-NodeTransport @($bad) { throw 'nothing may be staged' } $clock
        $t.Kind = 'ArcRunCommand'
        $t | Add-Member -NotePropertyName Machine -NotePropertyValue { param($Self, $Node) [pscustomobject]@{ Found = $true; Status = 'Disconnected'; LastStatusChange = $null } }
        $ev = New-AzlGuardEventContext
        $r = Invoke-AzlNodeConfiguration -Spec $script:NodeSpec -Transport $t -Execute -Clock $clock -PortProbe { $true } -SecretResolver { 'x' } -EventContext $ev -Step Network
        @($t.Log | Where-Object Kind -in 'Stage', 'Status') | Should -BeNullOrEmpty
        ($r.Changes | Where-Object Status -eq 'blocked').Detail | Should -Match 'not Connected'
        (Get-Sink $ev) | Should -Contain 'NodeBlocked'
        $r.Converged | Should -BeFalse
    }
}

Describe 'Stale run commands' {
    It 'deletes only this tool''s old run commands that are neither Succeeded nor Running, logs each, and touches nothing else' {
        $clock = New-FakeClock
        $now = & $clock.Now
        $deleted = [System.Collections.Generic.List[string]]::new()
        $t = [pscustomobject]@{
            Kind = 'ArcRunCommand'
            ListRunCommands = { param($Self, $Node) @(
                    [pscustomobject]@{ Name = 'azl-osconfig-stuck-creating'; ProvisioningState = 'Creating'; ExecutionState = ''; CreatedUtc = $now.AddHours(-3) }
                    [pscustomobject]@{ Name = 'azl-osconfig-unknown'; ProvisioningState = 'Succeeded'; ExecutionState = 'Unknown'; CreatedUtc = $now.AddMinutes(-40) }
                    [pscustomobject]@{ Name = 'azl-osconfig-failed'; ProvisioningState = 'Failed'; ExecutionState = ''; CreatedUtc = $now.AddMinutes(-16) }
                    [pscustomobject]@{ Name = 'azl-osconfig-young-creating'; ProvisioningState = 'Creating'; ExecutionState = ''; CreatedUtc = $now.AddMinutes(-5) }
                    [pscustomobject]@{ Name = 'azl-osconfig-done'; ProvisioningState = 'Succeeded'; ExecutionState = 'Succeeded'; CreatedUtc = $now.AddHours(-9) }
                    [pscustomobject]@{ Name = 'azl-osconfig-running'; ProvisioningState = 'Succeeded'; ExecutionState = 'Running'; CreatedUtc = $now.AddHours(-9) }
                    [pscustomobject]@{ Name = 'someone-elses-script'; ProvisioningState = 'Failed'; ExecutionState = ''; CreatedUtc = $now.AddHours(-9) }) }.GetNewClosure()
            DeleteRunCommand = { param($Self, $Node, $Name) $deleted.Add($Name) }.GetNewClosure()
        }
        $ev = New-AzlGuardEventContext
        $r = Remove-AzlStaleRunCommand -Transport $t -Node n1 -OlderThanMinutes 15 -Clock $clock -Event $ev
        @($deleted | Sort-Object) | Should -Be @('azl-osconfig-failed', 'azl-osconfig-stuck-creating', 'azl-osconfig-unknown')
        @($r).Count | Should -Be 3
        @($ev.Sink | Where-Object state -eq 'StaleRunCommandDeleted').Count | Should -Be 3
        (@($ev.Sink | Where-Object state -eq 'StaleRunCommandDeleted')[0]).evidence | Should -Match 'azl-osconfig-'
    }
    It 'does nothing for a transport without run commands (WinRM)' {
        Remove-AzlStaleRunCommand -Transport ([pscustomobject]@{ Kind = 'WinRM' }) -Node n1 | Should -BeNullOrEmpty
    }
    It 'the Arc transport names each run command uniquely and deletes its own after the run' {
        $names = [System.Collections.Generic.List[string]]::new()
        $deletes = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlNodeTransport Start-Sleep {}
        Mock -ModuleName AzlNodeTransport Invoke-AzlArm {
            if ($Method -eq 'PUT') { $names.Add(($Path -split '/')[-1]) }
            if ($Method -eq 'DELETE') { $deletes.Add(($Path -split '/')[-1]) }
            if ($Method -eq 'GET' -and $Path -like '*runCommands*') { [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; instanceView = [pscustomobject]@{ executionState = 'Succeeded'; exitCode = 0; output = (ConvertTo-Line @{ ok = 1 }); error = '' } } } }
            elseif ($Method -eq 'GET') { [pscustomobject]@{ location = 'eastus' } } else { [pscustomobject]@{} }
        }
        $t = New-AzlArcRunCommandTransport -ArcResourceId @{ n1 = '/subscriptions/s/resourceGroups/r/providers/Microsoft.HybridCompute/machines/n1' } -PollSeconds 1
        $null = Invoke-AzlNodeScript -Transport $t -Node n1 -Script 'x'
        $null = Invoke-AzlNodeScript -Transport $t -Node n1 -Script 'x'
        @($names | Select-Object -Unique).Count | Should -Be 2
        $names | ForEach-Object { $_ | Should -BeLike 'azl-osconfig-*' }
        @($deletes | Sort-Object) | Should -Be @($names | Sort-Object)
    }
}

Describe 'Settings and the pre-check' {
    It 'has the defaults: 10 minutes, 60 seconds, 15 minutes, 15 minutes, probe on' {
        $s = Get-AzlGuardSetting
        $s.networkRollbackMinutes | Should -Be 10
        $s.networkStableSeconds | Should -Be 60
        $s.reconnectWaitMinutes | Should -Be 15
        $s.staleRunCommandMinutes | Should -Be 15
        $s.addressProbe | Should -BeTrue
    }
    It 'takes the keys and rejects values that are not valid' {
        (Get-AzlGuardSetting -Setting @{ networkRollbackMinutes = 20; addressProbe = $false }).networkRollbackMinutes | Should -Be 20
        { Get-AzlGuardSetting -Setting @{ networkRollbackMinutes = 0 } } | Should -Throw '*networkRollbackMinutes*'
        { Get-AzlGuardSetting -Setting @{ addressProbe = 'yes' } } | Should -Throw '*addressProbe*'
        { Get-AzlGuardSetting -Setting @{ reconnectWaitMinutes = 'soon' } } | Should -Throw '*reconnectWaitMinutes*'
    }
    It 'transport: WinRM by default, Arc only when asked, the file and the settings in order' {
        (Get-AzlRemotingSetting).Kind | Should -Be 'WinRM'
        (Get-AzlRemotingSetting -Transport ArcRunCommand).Kind | Should -Be 'ArcRunCommand'
        (Get-AzlRemotingSetting -Setting @{ remoting = @{ transport = 'winrm_https' } }).Port | Should -Be 5986
        (Get-AzlRemotingSetting -Setting @{ remoting = @{ transport = 'arc' } } -Transport WinRM).Kind | Should -Be 'WinRM'
        (Get-AzlRemotingSetting).BootstrapTransport | Should -Be 'none'
        (Get-AzlRemotingSetting -Setting @{ remoting = @{ bootstrapTransport = 'arc'; allowedSourceCidrs = @('198.51.100.0/24') } }).AllowedSourceCidrs | Should -Be @('198.51.100.0/24')
        { Get-AzlRemotingSetting -Setting @{ remoting = @{ bootstrapTransport = 'sometimes' } } } | Should -Throw '*bootstrapTransport*'
        { Get-AzlRemotingSetting -Setting @{ remoting = @{ allowedSourceCidrs = @('not-a-cidr') } } } | Should -Throw '*CIDR*'
        { Get-AzlRemotingSetting -Setting @{ remoting = @{ colour = 'red' } } } | Should -Throw '*Unknown remoting setting*'
    }
    It 'the allowed CIDRs always include the management network' {
        $infra = @{ networking = @{ management = @{ subnet = '192.0.2.0/24' } } }
        Get-AzlRemotingAllowedCidr -Infrastructure $infra -RunnerCidr @('198.51.100.0/24') | Should -Be @('192.0.2.0/24', '198.51.100.0/24')
    }
    It 'the pre-check names a closed port, a timeout and a missing credential, and never suggests Arc as a fallback' {
        $probe = { param($Address, $Port) if ($Address -eq '192.0.2.11') { [pscustomobject]@{ Open = $false; Reason = 'TimedOut'; Detail = 'no answer' } } elseif ($Address -eq '192.0.2.12') { [pscustomobject]@{ Open = $false; Reason = 'Closed'; Detail = 'refused' } } else { [pscustomobject]@{ Open = $true; Reason = 'Open'; Detail = 'ok' } } }
        $f = @(Get-AzlRemotingFinding -Node @([pscustomobject]@{ Name = 'a'; Addresses = @('192.0.2.11') }, [pscustomobject]@{ Name = 'b'; Addresses = @('192.0.2.12') }, [pscustomobject]@{ Name = 'c'; Addresses = @('192.0.2.13') }) -HasCredential $false -Probe $probe)
        ($f | Where-Object Node -eq 'a').Result | Should -Be 'TimedOut'
        ($f | Where-Object Node -eq 'a').Diagnosis | Should -Match 'limited to the local subnet|local subnet'
        ($f | Where-Object Node -eq 'b').Result | Should -Be 'Closed'
        ($f | Where-Object Node -eq 'c').Result | Should -Be 'NoCredential'
        ($f | Where-Object Node -eq 'c').Diagnosis | Should -Match 'credential'
        ($f | Where-Object Node -eq 'a').Diagnosis | Should -Match "bootstrapTransport = 'arc'"
        (Format-AzlRemotingFinding -Finding $f) | Should -Match 'TimedOut'
    }
    It 'a node with no candidate address is reported with what to put in the file' {
        $f = @(Get-AzlRemotingFinding -Node @([pscustomobject]@{ Name = 'a'; Addresses = @() }) -Probe { [pscustomobject]@{ Open = $true; Reason = 'Open'; Detail = '' } })
        $f[0].Reachable | Should -BeFalse
        $f[0].Diagnosis | Should -Match 'nodes\[\].management.ip_address|the file'
    }
    It 'the probe picks the address that answers and tries every candidate' {
        $r = @(Test-AzlNodeConnectivity -Node @([pscustomobject]@{ Name = 'a'; Addresses = @('192.0.2.11', '192.0.2.60'); Port = 5985 }) -Probe { param($Address, $Port) [pscustomobject]@{ Open = ($Address -eq '192.0.2.60'); Reason = 'x'; Detail = '' } })
        $r[0].Reachable | Should -BeTrue
        $r[0].BestAddress | Should -Be '192.0.2.60'
        $r[0].Tried | Should -Be @('192.0.2.11', '192.0.2.60')
    }
    It 'the WinRM transport carries the authentication, the port and HTTPS' {
        $t = New-AzlWinRmTransport -Address @{ n1 = '192.0.2.11' } -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'x' -AsPlainText -Force))) -UseSsl -Authentication Kerberos
        $t.State.Port | Should -Be 5986
        $t.State.Ssl | Should -BeTrue
        $t.State.Authentication | Should -Be 'Kerberos'
        & $t.GetPort $t 'n1' | Should -Be 5986
        & $t.SetAddress $t 'n1' '192.0.2.60'
        & $t.GetAddress $t 'n1' | Should -Be '192.0.2.60'
    }
}

Describe 'Master file keys (schema 5.4.4)' {
    BeforeAll {
        Import-Module powershell-yaml
        Import-Module (Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') (Join-Path 'infrastructure' 'AzlInfrastructure.psm1')) -Force
        function Get-SchemaFinding([scriptblock]$Change) {
            $doc = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path (Join-Path $repo 'tests') (Join-Path 'fixtures' 'infrastructure.fc-san.yml')) -Raw) -Ordered
            & $Change $doc
            $file = Join-Path $TestDrive "s-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
            @(Test-AzlInfrastructure -Path $file | Where-Object { $_.Id -eq 'SCHEMA' })
        }
    }
    It 'accepts the new keys' {
        Get-SchemaFinding { param($d) $d.os_configuration = [ordered]@{ network = [ordered]@{ confirm_minutes = 15; stable_seconds = 30 }; remoting = [ordered]@{ transport = 'winrm_https'; bootstrap_transport = 'arc'; allowed_source_cidrs = @('198.51.100.0/24') } } } | Should -BeNullOrEmpty
    }
    It 'rejects a transport that is not winrm, winrm_https or arc, a bootstrap that is not none or arc, a CIDR that is not one, and a zero confirmation window' {
        (Get-SchemaFinding { param($d) $d.os_configuration = [ordered]@{ remoting = [ordered]@{ transport = 'ssh' } } }).Count | Should -BeGreaterThan 0
        (Get-SchemaFinding { param($d) $d.os_configuration = [ordered]@{ remoting = [ordered]@{ bootstrap_transport = 'always' } } }).Count | Should -BeGreaterThan 0
        (Get-SchemaFinding { param($d) $d.os_configuration = [ordered]@{ remoting = [ordered]@{ allowed_source_cidrs = @('runner') } } }).Count | Should -BeGreaterThan 0
        (Get-SchemaFinding { param($d) $d.os_configuration = [ordered]@{ network = [ordered]@{ confirm_minutes = 0 } } }).Count | Should -BeGreaterThan 0
    }
}
Describe 'The split of the planned changes puts the SBE package last' {
    It 'splits an SBE file into its own group, which is the last one' {
        $todo = @(
            [pscustomobject]@{ Apply = @{ id = 'Sbe/x.zip'; kind = 'sbe-file' } }
            [pscustomobject]@{ Apply = @{ id = 'Hostname/name'; kind = 'hostname' } }
            [pscustomobject]@{ Apply = @{ id = 'LocalAdmin/user'; kind = 'admin' } })
        $parts = Split-AzlGuardedAction -Todo $todo
        @($parts.Sbe).Count | Should -Be 1
        @($parts.Inline).Count | Should -Be 1
        @($parts.Hostname).Count | Should -Be 1
        @($parts.PSObject.Properties.Name)[-1] | Should -Be 'Sbe'
    }
}

Describe 'Guard events go through the feed writer and stay inside its contract' {
    It 'writes the same line shape as the run (round-trip timestamp, payloadVersion, schemaVersion) for a contract state' {
        $file = Join-Path $TestDrive 'guard-feed.jsonl'
        $ev = New-AzlGuardEventContext -Path $file -SchemaVersion '5.6.0'
        Send-AzlGuardEvent -Context $ev -Node n1 -State NetworkChangeCommitted -Step Network -Transport WinRM -Evidence 'committed' -Data @{ oldAddress = '192.0.2.50'; newAddress = '192.0.2.60' }
        $line = Get-Content -LiteralPath $file -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
        $line.state | Should -Be 'NetworkChangeCommitted'
        (Get-Content -LiteralPath $file -Raw -Encoding utf8) | Should -Match '"timestamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z"'
        $line.payloadVersion | Should -Be '1'
        $line.schemaVersion | Should -Be '5.6.0'
        $line.newAddress | Should -Be '192.0.2.60'
        $line.transport | Should -Be 'WinRM'
    }
    It 'a state outside the contract (StaleRunCommandDeleted) stays in the sink and out of the feed' {
        $file = Join-Path $TestDrive 'guard-feed2.jsonl'
        $ev = New-AzlGuardEventContext -Path $file
        Send-AzlGuardEvent -Context $ev -Node n1 -State StaleRunCommandDeleted -Step Transport -Evidence 'x'
        Send-AzlGuardEvent -Context $ev -Node n1 -State NodeBlocked -Step Network -Evidence 'y'
        @($ev.Sink).Count | Should -Be 2
        @(Get-Content -LiteralPath $file -Encoding utf8 | Where-Object { $_ }).Count | Should -Be 1
    }
    It 'every state the scripts name in a guard event is a state of the contract, except the documented report-only one' {
        $contract = @((Get-AzlOsConfigurationEventState).Values | ForEach-Object { $_ })
        $dir = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'scripts'
        $found = foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -Include *.ps1, *.psm1 -File) {
            [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw), "Send-AzlGuardEvent[^\r\n]*?-State '([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value }
        }
        $found.Count | Should -BeGreaterThan 5
        @($found | Select-Object -Unique | Where-Object { $_ -notin $contract -and $_ -ne 'StaleRunCommandDeleted' }) | Should -BeNullOrEmpty
    }
}
