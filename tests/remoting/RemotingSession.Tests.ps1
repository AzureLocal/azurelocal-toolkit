#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the orchestrator side of the remote management profile: TrustedHosts set and restore with a fake store, the events, the choice
# of the WinRM endpoint, and the message when a node does not answer. No machine setting is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemotingSession.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake script blocks take the parameters the real ones are called with.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    foreach ($m in 'AzlRemotingProfile', 'AzlRemotingSession') { Import-Module (Join-Path (Join-Path $common 'remoting') "$m.psm1") -Force }
    Import-Module powershell-yaml
    $script:Example = Join-Path (Join-Path (Join-Path (Join-Path $repo 'config') 'variables') 'examples') 'infrastructure.example.yml'

    function Resolve-For([string]$Class, [scriptblock]$Change, [hashtable]$Override = @{}) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.scenario.environment_class = $Class
        if ($Change) { & $Change $doc }
        Resolve-AzlRemotingProfile -Infrastructure $doc -Override $Override
    }
    # A TrustedHosts store that is a variable, and remembers every write.
    function Get-FakeStore([string]$Initial = '') {
        $state = @{ Value = $Initial; Writes = [System.Collections.Generic.List[string]]::new() }
        [pscustomobject]@{
            Supported = $true; State = $state
            Get       = { $state.Value }.GetNewClosure()
            Set       = { param($Value) $state.Value = $Value; $state.Writes.Add($Value) }.GetNewClosure()
        }
    }
}

Describe 'TrustedHosts on the machine running the automation' {
    BeforeEach { Set-AzlRemotingEventSink -Reset -Confirm:$false }

    It '<_>: sets * and records the previous value, then restores it' -ForEach 'lab', 'test' {
        $store = Get-FakeStore 'existing.example.invalid'
        $profile1 = Resolve-For $_
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile $profile1 -Store $store -Confirm:$false
        $store.State.Value | Should -Be '*'
        $session.Previous | Should -Be 'existing.example.invalid'
        $session.Applied | Should -Be '*'
        $session.Changed | Should -BeTrue
        $r = Restore-AzlTrustedHostsPolicy -Session $session -Store $store -Confirm:$false
        $r.Restored | Should -BeTrue
        $store.State.Value | Should -Be 'existing.example.invalid'
    }
    It 'writes TrustedHostsChanged (Warning for a wildcard) and TrustedHostsRestored' {
        $store = Get-FakeStore 'a.example.invalid'
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $null = Restore-AzlTrustedHostsPolicy -Session $session -Store $store -Confirm:$false
        $events = @(Get-AzlRemotingEvent)
        $changed = $events | Where-Object state -eq 'TrustedHostsChanged'
        $changed.level | Should -Be 'Warning'
        $changed.previous | Should -Be 'a.example.invalid'
        $changed.applied | Should -Be '*'
        ($events | Where-Object state -eq 'TrustedHostsRestored').restored | Should -Be 'a.example.invalid'
    }
    It 'a wildcard that is already there is left, and not "restored" to itself' {
        $store = Get-FakeStore '*'
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $session.Changed | Should -BeFalse
        $store.State.Writes.Count | Should -Be 0
        (Restore-AzlTrustedHostsPolicy -Session $session -Store $store -Confirm:$false).Restored | Should -BeFalse
        $store.State.Value | Should -Be '*'
    }
    It 'dev: only the nodes'' addresses are added to what is there, and taken away again' {
        $store = Get-FakeStore 'keep.example.invalid'
        $p = Resolve-For 'dev'
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile $p -Address $p.TrustedHosts.Addresses -Store $store -Confirm:$false
        $store.State.Value | Should -Be 'keep.example.invalid,192.0.2.11,192.0.2.12'
        $store.State.Value | Should -Not -Match '\*'
        $null = Restore-AzlTrustedHostsPolicy -Session $session -Store $store -Confirm:$false
        $store.State.Value | Should -Be 'keep.example.invalid'
    }
    It 'dev: an address that is already trusted is not added twice' {
        $store = Get-FakeStore '192.0.2.11'
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'dev') -Address @('192.0.2.11') -Store $store -Confirm:$false
        $session.Changed | Should -BeFalse
    }
    It '<_>: sets nothing, and never a wildcard' -ForEach 'production', 'dmz' {
        $store = Get-FakeStore ''
        $p = Resolve-For $_ { param($d) $d.os_configuration.remoting.certificate = ('AB' * 20) }
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile $p -Address @('192.0.2.11') -Store $store -Confirm:$false
        $session.Changed | Should -BeFalse
        $store.State.Writes.Count | Should -Be 0
    }
    It 'production and dmz warn about a wildcard somebody else left, and do not copy or remove it' {
        $store = Get-FakeStore '*'
        $null = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'production') -Store $store -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        ($w -join ' ') | Should -Match 'already contains'
        $store.State.Value | Should -Be '*'
    }
    It 'a class other than lab and test cannot be made to set a wildcard, even by a hand-built profile' {
        $p = Resolve-For 'production'
        $p.TrustedHosts.Mode = 'wildcard'
        { Set-AzlTrustedHostsPolicy -RemotingProfile $p -Store (Get-FakeStore) -Confirm:$false } | Should -Throw '*never sets a TrustedHosts wildcard*'
    }
    It 'a value somebody else changed meanwhile is not overwritten on restore' {
        $store = Get-FakeStore 'x.example.invalid'
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $store.State.Value = 'changed-by-someone.example.invalid'
        $r = Restore-AzlTrustedHostsPolicy -Session $session -Store $store -Confirm:$false -WarningAction SilentlyContinue
        $r.Restored | Should -BeFalse
        $store.State.Value | Should -Be 'changed-by-someone.example.invalid'
    }
    It 'restore happens once' {
        $store = Get-FakeStore 'x.example.invalid'
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false
        $null = Restore-AzlTrustedHostsPolicy -Session $session -Store $store -Confirm:$false
        $writes = $store.State.Writes.Count
        (Restore-AzlTrustedHostsPolicy -Session $session -Store $store -Confirm:$false).Reason | Should -Be 'already restored'
        $store.State.Writes.Count | Should -Be $writes
    }
    It 'Invoke-AzlWithRemotingSession restores in a finally block, also when the work throws' {
        $store = Get-FakeStore 'x.example.invalid'
        { Invoke-AzlWithRemotingSession -RemotingProfile (Resolve-For 'lab') -Store $store -ScriptBlock { param($s) $null = $s; throw 'the run failed' } } | Should -Throw '*the run failed*'
        $store.State.Value | Should -Be 'x.example.invalid'
        @($store.State.Writes) | Should -Be @('*', 'x.example.invalid')
    }
    It 'the work sees the policy while it runs' {
        $store = Get-FakeStore ''
        $seen = Invoke-AzlWithRemotingSession -RemotingProfile (Resolve-For 'lab') -Store $store -ScriptBlock { param($s) $null = $s; $store.State.Value }
        $seen | Should -Be '*'
        $store.State.Value | Should -Be ''
    }
    It 'a platform without WSMan client settings changes nothing and says so' {
        $store = [pscustomobject]@{ Supported = $false; Get = { '' }; Set = { param($Value) throw 'must not be written' } }
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $session.Changed | Should -BeFalse
        ($w -join ' ') | Should -Match 'not available on this platform'
    }
    It 'WhatIf changes nothing' {
        $store = Get-FakeStore 'x'
        $session = Set-AzlTrustedHostsPolicy -RemotingProfile (Resolve-For 'lab') -Store $store -WhatIf
        $store.State.Writes.Count | Should -Be 0
        $session.Changed | Should -BeFalse
    }
}

Describe 'The events' {
    BeforeEach { Set-AzlRemotingEventSink -Reset -Confirm:$false }
    It 'RemotingProfileResolved carries the class and the posture, at Warning for a relaxed class' {
        Send-AzlRemotingProfileEvent -RemotingProfile (Resolve-For 'lab')
        Send-AzlRemotingProfileEvent -RemotingProfile (Resolve-For 'production')
        $events = @(Get-AzlRemotingEvent)
        $events.Count | Should -Be 2
        $events[0].state | Should -Be 'RemotingProfileResolved'
        $events[0].class | Should -Be 'lab'
        $events[0].posture | Should -Be 'relaxed-wildcard'
        $events[0].level | Should -Be 'Warning'
        $events[0].evidence | Should -Match 'Relaxed remote management posture'
        $events[1].class | Should -Be 'production'
        $events[1].level | Should -Be 'Info'
        $events[1].posture | Should -Be 'restricted'
    }
    It 'every event has the feed''s fields' {
        Write-AzlRemotingEvent -State TrustedHostsRestored -Node 'n1' -Evidence 'x'
        $e = (Get-AzlRemotingEvent)[0]
        foreach ($f in 'timestamp', 'node', 'stage', 'step', 'state', 'evidence', 'level', 'nextAction') { $e.PSObject.Properties.Name | Should -Contain $f }
        $e.stage | Should -Be 'OsConfiguration'
        $e.step | Should -Be 'RemoteManagement'
        { [datetime]::Parse($e.timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } | Should -Not -Throw
    }
    It 'goes to a JSON Lines file and to a sink; a failing sink does not throw' {
        $file = Join-Path $TestDrive 'events\remoting-events.jsonl'
        $script:got = @()
        Set-AzlRemotingEventSink -Path $file -Sink { param($e) $script:got += $e.state } -Reset -Confirm:$false
        Write-AzlRemotingEvent -State RemotingBootstrapStarted -Node 'n1' -Data ([ordered]@{ route = 'smb' })
        Write-AzlRemotingEvent -State RemotingBootstrapFailed -Node 'n1' -Level Warning -Data ([ordered]@{ route = 'smb'; reason = 'x' })
        $lines = @(Get-Content -LiteralPath $file)
        $lines.Count | Should -Be 2
        ($lines[1] | ConvertFrom-Json).route | Should -Be 'smb'
        @($script:got) | Should -Be @('RemotingBootstrapStarted', 'RemotingBootstrapFailed')
        Set-AzlRemotingEventSink -Sink { throw 'sink down' } -Reset -Confirm:$false
        { Write-AzlRemotingEvent -State TrustedHostsChanged } | Should -Not -Throw
    }
}

Describe 'Resolve-AzlRemotingEndpoint' {
    BeforeAll {
        function Get-Order([string]$Class, [switch]$Window, [scriptblock]$Change, [int[]]$Answer = @()) {
            $script:asked = [System.Collections.Generic.List[int]]::new()
            $script:answer = $Answer
            $r = Resolve-AzlRemotingEndpoint -RemotingProfile (Resolve-For $Class $Change) -Address '192.0.2.11' -BootstrapWindow:$Window -PortTest { param($a, $p) $null = $a; $script:asked.Add($p); $p -in $script:answer }
            [pscustomobject]@{ Asked = @($script:asked); Result = $r }
        }
    }
    It 'lab tries HTTP 5985 first, then 5986' {
        (Get-Order 'lab').Asked | Should -Be @(5985, 5986)
        $o = Get-Order 'lab' -Answer 5985
        $o.Result.Answers | Should -BeTrue
        $o.Result.UseSsl | Should -BeFalse
        (Get-Order 'lab' -Answer 5986).Result.UseSsl | Should -BeTrue
    }
    It 'production uses HTTPS only, and never HTTP' {
        (Get-Order 'production' -Answer 5985).Asked | Should -Be @(5986)
        (Get-Order 'production' -Answer 5985).Result.Answers | Should -BeFalse
        (Get-Order 'production' -Answer 5986).Result.UseSsl | Should -BeTrue
    }
    It 'dev falls back to HTTP in the bootstrap window' {
        (Get-Order 'dev').Asked | Should -Be @(5986, 5985)
        (Get-Order 'dev' -Answer 5985).Result.UseSsl | Should -BeFalse
    }
    It 'production opens an HTTP window only after a bootstrap of this run' {
        (Get-Order 'production' -Window).Asked | Should -Be @(5986, 5985)
        (Get-Order 'dmz' -Window { param($d) $d.os_configuration.remoting.certificate = ('AB' * 20) }).Asked | Should -Be @(5986)
    }
    It 'when nothing answers the message says the node firewall probably limits WinRM to its own subnet' {
        $r = (Get-Order 'lab').Result
        $r.Answers | Should -BeFalse
        $r.Message | Should -Match 'the node firewall probably limits WinRM to its own subnet'
        $r.Message | Should -Match '192\.0\.2\.11 TCP 5985/5986'
    }
}

Describe 'Format-AzlWinRmUnreachableMessage: the bootstrap options of the profile' {
    It 'always says the node firewall probably limits WinRM to its own subnet' {
        foreach ($c in 'lab', 'test', 'dev', 'production', 'dmz') {
            (Format-AzlWinRmUnreachableMessage -RemotingProfile (Resolve-For $c) -Node 'n1' -Address '192.0.2.11') | Should -Match 'the node firewall probably limits WinRM to its own subnet' -Because $c
        }
    }
    It 'lab, not chosen: names bootstrap_transport smb, arc or auto, and the console or BMC' {
        $m = Format-AzlWinRmUnreachableMessage -RemotingProfile (Resolve-For 'lab') -Address '192.0.2.11'
        $m | Should -Match 'bootstrap_transport'
        $m | Should -Match 'smb, arc or auto'
        $m | Should -Match 'console or the BMC'
    }
    It 'lab, chosen: says the bootstrap is permitted and which routes' {
        $m = Format-AzlWinRmUnreachableMessage -RemotingProfile (Resolve-For 'lab' { param($d) $d.os_configuration.remoting.bootstrap_transport = 'auto' }) -Address '192.0.2.11'
        $m | Should -Match 'chosen and permitted'
        $m | Should -Match 'smb, arc'
    }
    It 'production, chosen but not approved: asks for -ApprovedBootstrap' {
        $m = Format-AzlWinRmUnreachableMessage -RemotingProfile (Resolve-For 'production' { param($d) $d.os_configuration.remoting.bootstrap_transport = 'smb' }) -Address '192.0.2.11'
        $m | Should -Match 'ApprovedBootstrap'
        $m | Should -Match 'not approved'
    }
    It 'production, not chosen: says what it takes' {
        $m = Format-AzlWinRmUnreachableMessage -RemotingProfile (Resolve-For 'production') -Address '192.0.2.11'
        $m | Should -Match 'arc, smb or auto'
        $m | Should -Match 'ApprovedBootstrap'
    }
    It 'says the smb route is Windows-orchestrator only and the arc route needs outbound 443 only' {
        $m = Format-AzlWinRmUnreachableMessage -RemotingProfile (Resolve-For 'lab') -Address '192.0.2.11'
        $m | Should -Match 'Windows orchestrator'
        $m | Should -Match 'outbound 443'
    }
    It 'names the sources the class allows' {
        (Format-AzlWinRmUnreachableMessage -RemotingProfile (Resolve-For 'dev') -Address '192.0.2.11') | Should -Match '198\.51\.100\.10/32'
    }
}
