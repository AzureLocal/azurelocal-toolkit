#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the second review of the remote management profiles, host side of the RemoteManagement step: F1 (the operator must stay inside the scope
# the commit sets; a fresh session after the commit, else revert; the node's own revert timer), F4 (the listener and the rules stay on * and Any until
# the node holds the management IP, and bind on the pass after), F7 (the 5986 rule is not disabled with the HTTP listener).
# No node, no Azure, no machine setting is touched.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/remoting/RemoteManagement.Review2.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake script blocks take the parameters the real ones are called with.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $common = Join-Path (Join-Path $repo 'scripts') 'common'
    Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'azure-local') 'AzlAzure.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodePayload.psm1') -Force
    Import-Module (Join-Path (Join-Path $common 'node-configuration') 'AzlNodeTransport.psm1') -Force
    foreach ($m in 'AzlRemotingProfile', 'AzlRemotingPayload', 'AzlRemotingSession', 'AzlRemoteManagement') { Import-Module (Join-Path (Join-Path $common 'remoting') "$m.psm1") -Force }
    Import-Module powershell-yaml
    $script:Fixture = Join-Path (Join-Path (Join-Path $repo 'tests') 'fixtures') 'infrastructure.fc-san.yml'
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function Get-FixtureInfra([string]$Class, [scriptblock]$Change) {
        $infra = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
        if (-not $infra.Contains('os_configuration')) { $infra['os_configuration'] = [ordered]@{} }
        if (-not $infra['os_configuration'].Contains('remoting')) { $infra['os_configuration']['remoting'] = [ordered]@{} }
        if ($Class) { $infra['scenario']['environment_class'] = $Class }
        if ($Change) { & $Change $infra }
        $infra
    }
    function Get-NodeSpecFor([string]$Class, [string]$Current = '192.0.2.11', [string]$Source = '') {
        $p = Resolve-AzlRemotingProfile -Infrastructure (Get-FixtureInfra $Class)
        New-AzlRemotingNodeSpec -RemotingProfile $p -Name 'iic-n01' -ManagementIp '192.0.2.11' -DnsNames @('iic-n01') -CurrentAddress $Current -SourceAddress $Source
    }
    # What the Read script returns for a node that already matches the spec (the management IP held, the session on it).
    function Get-MatchingState([object]$Spec) {
        $local = @("$($Spec.ManagementIp)/32")
        $rules = foreach ($r in $Spec.Rules) {
            if ($r.kind -eq 'managed' -and $r.desired -eq 'present') { [pscustomobject]@{ name = $r.name; enabled = $true; profile = 'Any'; remote = @($r.remote); local = $local; protocol = $r.protocol; port = [string]$r.port } }
        }
        $listenAddr = "IP:$($Spec.ManagementIp)"
        $listeners = @()
        if ($Spec.HttpsListener) { $listeners += [pscustomobject]@{ transport = 'HTTPS'; address = $listenAddr; port = '5986'; thumbprint = ('AB' * 20); hostname = 'iic-n01' } }
        if ($Spec.HttpListener) { $listeners += [pscustomobject]@{ transport = 'HTTP'; address = $(if ($Spec.ListenerBind -eq 'managementIp') { $listenAddr } else { '*' }); port = '5985'; thumbprint = ''; hostname = '' } }
        $discover = @($Spec.Rules | Where-Object { $_.kind -eq 'discoverWinRm' })[0]
        $on = $discover.desired -eq 'present'
        $winrm = @([pscustomobject]@{ name = 'WINRM-HTTP-In-TCP'; enabled = $on; profile = 'Any'; remote = $(if ($on) { @($discover.remote) } else { @('Any') }); local = @('Any'); protocol = 'TCP'; port = '5985' })
        [pscustomobject]@{
            v = 1; host = 'iic-n01'; domainJoined = $false
            service = [pscustomobject]@{ running = $true; allowUnencrypted = 'false'; basic = 'false'; credSsp = 'false'; cbt = 'Strict'; compatHttp = 'false'; compatHttps = 'false' }
            listeners = $listeners; rules = @($rules); winrmRules = $winrm
            certs = @([pscustomobject]@{ thumbprint = ('AB' * 20); subject = 'CN=iic-n01'; dns = @('iic-n01'); ips = @($Spec.ManagementIp); serverAuth = $true; privateKey = $true; selfSigned = $true; notAfter = '2030-01-01T00:00:00.0000000Z' })
            wantCert = $null; categories = @(); rdp = [pscustomobject]@{ deny = $(if ($Spec.RdpEnabled) { 0 } else { 1 }); nla = $(if ($Spec.RdpEnabled) { 1 } else { $null }) }
            tls = [pscustomobject]@{ tls12ServerEnabled = $null }; addresses = @($Spec.ManagementIp); pending = $null; err = [pscustomobject]@{}
        }
    }
    function Get-Item2([object[]]$Plan, [string]$Like) { @($Plan | Where-Object { $_.Item -like $Like }) }
    function Get-FakeNode([scriptblock]$Answer) {
        $log = [System.Collections.Generic.List[object]]::new()
        $invoke = { param($Mode, $Parameters, $Secrets) $log.Add([pscustomobject]@{ Mode = $Mode; Parameters = $Parameters; Secrets = $Secrets }); & $Answer $Mode $Parameters }.GetNewClosure()
        [pscustomobject]@{ Log = $log; Invoke = $invoke }
    }
    $script:Good = { param($Mode, $Parameters) [pscustomobject]@{ ok = $true; reverted = $false; thumbprint = ('AB' * 20); certPublic = 'cHVibGlj'; results = @([pscustomobject]@{ id = 'x'; status = 'changed'; detail = "$Mode ok" }) } }
    function Get-PlanItem { @([pscustomobject]@{ Apply = @{ id = 'RemoteManagement/baseline'; kind = 'remoting' } }) }
    $script:Verified = { param($Stage) [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
}

Describe 'F1: the operator must stay inside the scope the commit sets' {
    It 'a source address outside the firewall scope is Blocked with the reason, and no change of the step is left to apply' {
        $s = Get-NodeSpecFor 'production' '192.0.2.11' '203.0.113.9'
        $st = Get-MatchingState $s
        $st.service.basic = 'true'   # something that would be a Change
        $plan = @(Compare-AzlRemotingState -Spec $s -State $st)
        $b = @($plan | Where-Object { $_.Item -eq 'operator access' })
        $b.Count | Should -Be 1
        $b[0].Action | Should -Be 'Blocked'
        $b[0].Note | Should -Match '203\.0\.113\.9'
        $b[0].Note | Should -Match 'allowed_source_cidrs'
        @($plan | Where-Object { $_.Action -eq 'Change' -and $_.Apply }) | Should -BeNullOrEmpty
        (Get-Item2 $plan 'WinRM baseline')[0].Action | Should -Be 'Blocked'
    }
    It 'a source address inside the scope is no problem' {
        $s = Get-NodeSpecFor 'production' '192.0.2.11' '192.0.2.5'
        $plan = @(Compare-AzlRemotingState -Spec $s -State (Get-MatchingState $s))
        @($plan | Where-Object { $_.Action -eq 'Blocked' }) | Should -BeNullOrEmpty
    }
    It 'lab (Any) never blocks, an unknown source address is not guessed at' {
        $plan = @(Compare-AzlRemotingState -Spec (Get-NodeSpecFor 'lab' '192.0.2.11' '203.0.113.9') -State (Get-MatchingState (Get-NodeSpecFor 'lab')))
        @($plan | Where-Object { $_.Action -eq 'Blocked' }) | Should -BeNullOrEmpty
        $s = Get-NodeSpecFor 'production'
        @(Compare-AzlRemotingState -Spec $s -State (Get-MatchingState $s) | Where-Object { $_.Action -eq 'Blocked' }) | Should -BeNullOrEmpty
    }
    It 'Test-AzlAddressInScope: CIDRs, hosts, Any, keywords and IPv6' {
        Test-AzlAddressInScope -Address '192.0.2.5' -Scope @('192.0.2.0/24') | Should -BeTrue
        Test-AzlAddressInScope -Address '192.0.3.5' -Scope @('192.0.2.0/24') | Should -BeFalse
        Test-AzlAddressInScope -Address '198.51.100.7' -Scope @('192.0.2.0/24', '198.51.100.7/32') | Should -BeTrue
        Test-AzlAddressInScope -Address '203.0.113.9' -Scope @('Any') | Should -BeTrue
        Test-AzlAddressInScope -Address '203.0.113.9' -Scope @('LocalSubnet') | Should -BeTrue
        Test-AzlAddressInScope -Address '2001:db8::5' -Scope @('2001:db8::/64') | Should -BeTrue
        Test-AzlAddressInScope -Address '2001:db9::5' -Scope @('2001:db8::/64') | Should -BeFalse
        Test-AzlAddressInScope -Address '2001:db8::5' -Scope @('192.0.2.0/24') | Should -BeFalse
    }
    It 'the source address is the local address that routes to the node (a resolver is injected here; the default asks the routing table)' {
        Get-AzlRemotingSourceAddress -Destination '192.0.2.11' -Resolver { param($d) '198.51.100.20' } | Should -Be '198.51.100.20'
        Get-AzlRemotingSourceAddress -Destination '' | Should -Be ''
        Get-AzlRemotingSourceAddress -Destination '192.0.2.11' -Resolver { throw 'no route' } | Should -Be ''
        Get-AzlRemotingSourceAddress -Destination '127.0.0.1' | Should -Be '127.0.0.1'
    }
    It 'Read-AzlRemotingState records the source address on the spec' {
        Mock -ModuleName AzlRemoteManagement Invoke-AzlNodeScript { [pscustomobject]@{} }
        $s = Get-NodeSpecFor 'production'
        $t = [pscustomobject]@{ Kind = 'WinRM'; State = @{ Addresses = @{ 'iic-n01' = '192.0.2.11' } } }
        $null = Read-AzlRemotingState -Spec $s -Transport $t -SourceResolver { param($d) '198.51.100.20' }
        $s.CurrentAddress | Should -Be '192.0.2.11'
        $s.SourceAddress | Should -Be '198.51.100.20'
    }
}

Describe 'F1: after the commit a fresh session is opened; if it fails the change is reverted' {
    BeforeEach { Set-AzlRemotingEventSink -Reset -Confirm:$false }

    It 'a fresh session that works: the timer is disarmed and the change stays' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem) -Invoke $node.Invoke -ConfirmPath $script:Verified -Reconnect { param($Verified) [pscustomobject]@{ Ok = $true; Reason = '' } }
        @($node.Log.Mode) | Should -Be @('stage', 'commit', 'disarm')
        $r.Status | Should -Be 'committed'
    }
    It 'a fresh session that fails: the change is reverted, the timer is not disarmed, the reason says why' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem) -Invoke $node.Invoke -ConfirmPath $script:Verified -Reconnect { param($Verified) [pscustomobject]@{ Ok = $false; Reason = 'timed out' } }
        @($node.Log.Mode) | Should -Be @('stage', 'commit', 'revert')
        $r.Status | Should -Be 'reverted'
        $r.Reason | Should -Match 'new session'
        $r.Reason | Should -Match 'timed out'
    }
    It 'the reconnect is told whether the HTTPS path was verified' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $script:seenVerified = $null
        $null = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem) -Invoke $node.Invoke -ConfirmPath $script:Verified -Reconnect { param($Verified) $script:seenVerified = $Verified; [pscustomobject]@{ Ok = $true; Reason = '' } }
        $script:seenVerified | Should -BeTrue
    }
    It 'a disarm that fails reverts now, not by the timer later' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode { param($Mode, $Parameters) if ($Mode -eq 'disarm') { [pscustomobject]@{ ok = $false; results = @([pscustomobject]@{ id = 'disarm'; status = 'failed'; detail = 'denied' }) } } else { & $script:Good $Mode $Parameters } }
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem) -Invoke $node.Invoke -ConfirmPath $script:Verified -Reconnect { param($Verified) [pscustomobject]@{ Ok = $true; Reason = '' } }
        @($node.Log.Mode) | Should -Be @('stage', 'commit', 'disarm', 'revert')
        $r.Status | Should -Be 'reverted'
    }
    It 'any guard that reverts a failed commit gets the same behaviour: the check is part of the commit step, not of the default guard' {
        $s = Get-NodeSpecFor 'production'
        $node = Get-FakeNode $script:Good
        $guard = { param($Change) $st = & $Change.Stage $Change; $c = & $Change.Commit $Change ([pscustomobject]@{ Verified = $true }); [pscustomobject]@{ Status = $(if ($c.Ok) { 'committed' } else { 'reverted' }); Stage = $st; Confirm = $null; Commit = $c; Revert = $null; Reason = $c.Reason } }
        $r = Invoke-AzlRemotingApply -Spec $s -Item (Get-PlanItem) -Invoke $node.Invoke -Guard $guard -Reconnect { param($Verified) [pscustomobject]@{ Ok = $false; Reason = 'x' } }
        $r.Status | Should -Be 'reverted'
    }
    It 'the commit asks the node to arm a revert timer; stage and revert do not' {
        $s = Get-NodeSpecFor 'production'
        (Get-AzlRemotingChangeParameter -Spec $s -Mode commit -ChangeId 'c1').revertMinutes | Should -BeGreaterThan 0
        (Get-AzlRemotingChangeParameter -Spec $s -Mode stage -ChangeId 'c1').revertMinutes | Should -Be 0
        (Get-AzlRemotingChangeParameter -Spec $s -Mode disarm -ChangeId 'c1').mode | Should -Be 'disarm'
    }
    It 'Test-AzlRemotingFreshSession: Arc has no firewall path to test; WinRM opens a new session over HTTPS when HTTP is going' {
        $s = Get-NodeSpecFor 'production'
        (Test-AzlRemotingFreshSession -Spec $s -Transport ([pscustomobject]@{ Kind = 'ArcRunCommand' })).Ok | Should -BeTrue
        $t = [pscustomobject]@{ Kind = 'WinRM'; State = @{ Ssl = $false; Addresses = @{ 'iic-n01' = '192.0.2.11' }; Credential = 'x' } }
        $script:seen = $null
        $r = Test-AzlRemotingFreshSession -Spec $s -Transport $t -Verified $true -OpenAndRead { param($Spec, $Transport, $Address, $Ssl) $script:seen = "$Address|$Ssl"; [pscustomobject]@{ Ok = $false; Reason = 'refused' } }
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'refused'
        $script:seen | Should -Be '192.0.2.11|True'
        $null = Test-AzlRemotingFreshSession -Spec $s -Transport $t -Verified $false -OpenAndRead { param($Spec, $Transport, $Address, $Ssl) $script:seen = "$Address|$Ssl"; [pscustomobject]@{ Ok = $true; Reason = '' } }
        $script:seen | Should -Be '192.0.2.11|False'
    }
}

Describe 'F4: the listener and the rules stay on * and Any until the node holds the management IP' {
    It 'the node does not hold the file address: no Blocked item, the listener may stay on *, the rules take any local address' {
        $s = Get-NodeSpecFor 'production' '192.0.2.50'
        $st = Get-MatchingState $s
        $st.addresses = @('192.0.2.50')
        foreach ($l in $st.listeners) { $l.address = '*' }
        foreach ($r in $st.rules) { $r.local = @('Any') }
        $plan = @(Compare-AzlRemotingState -Spec $s -State $st)
        @($plan | Where-Object { $_.Action -in 'Blocked', 'Change' }) | Should -BeNullOrEmpty
        (Get-Item2 $plan 'listener address')[0].Action | Should -Be 'Info'
        (Get-Item2 $plan 'HTTPS listener')[0].Action | Should -Be 'Ok'
    }
    It 'the pass after the Network step: the node holds the file address, so the listener and the rules are Changes to bind to it' {
        $s = Get-NodeSpecFor 'production' '192.0.2.11'
        $st = Get-MatchingState $s
        foreach ($l in $st.listeners) { $l.address = '*' }
        foreach ($r in $st.rules) { $r.local = @('Any') }
        $plan = @(Compare-AzlRemotingState -Spec $s -State $st)
        (Get-Item2 $plan 'HTTPS listener')[0].Action | Should -Be 'Change'
        (Get-Item2 $plan 'HTTPS listener')[0].Desired | Should -Match 'IP:192\.0\.2\.11'
        (Get-Item2 $plan 'firewall AzlOsConfig-WinRM-HTTPS-In')[0].Action | Should -Be 'Change'
        (Get-Item2 $plan 'firewall AzlOsConfig-WinRM-HTTPS-In')[0].Desired | Should -Match '192\.0\.2\.11/32'
    }
    It 'the node holds the file address but the session came in on another one: still *, so the path in use is not cut' {
        $s = Get-NodeSpecFor 'production' '192.0.2.50'
        $st = Get-MatchingState $s
        $st.addresses = @('192.0.2.11', '192.0.2.50')
        foreach ($l in $st.listeners) { $l.address = '*' }
        foreach ($r in $st.rules) { $r.local = @('Any') }
        $plan = @(Compare-AzlRemotingState -Spec $s -State $st)
        @($plan | Where-Object { $_.Action -in 'Blocked', 'Change' }) | Should -BeNullOrEmpty
    }
    It 'the RemoteManagement step is part of every pass, so the pass after the Network step does it (the node loop reads and compares all steps each pass)' {
        $text = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path $repo 'scripts') 'common') 'node-configuration') 'AzlNodeConfiguration.psm1') -Raw
        $text | Should -Match "Read-AzlRemotingState -Spec \`$remoting -Transport \`$Transport"
        $text | Should -Match "for \(\`$pass = 1; \`$pass -le \`$limit \+ 1; \`$pass\+\+\)"
    }
}

Describe 'F7: only the HTTP rule goes with the HTTP listener' {
    It 'a built-in rule that allows 5986 is scoped like the profile, never planned to be switched off' {
        $s = Get-NodeSpecFor 'production'
        $st = Get-MatchingState $s
        $st.winrmRules = @(
            [pscustomobject]@{ name = 'WINRM-HTTP-In-TCP'; enabled = $true; profile = 'Any'; remote = @('Any'); local = @('Any'); protocol = 'TCP'; port = '5985' }
            [pscustomobject]@{ name = 'WINRM-HTTPS-In-TCP'; enabled = $true; profile = 'Any'; remote = @('Any'); local = @('Any'); protocol = 'TCP'; port = '5986' }
        )
        $plan = @(Compare-AzlRemotingState -Spec $s -State $st)
        $http = (Get-Item2 $plan 'firewall WINRM-HTTP-In-TCP')[0]
        $http.Action | Should -Be 'Change'
        $http.Desired | Should -Be 'off'
        $https = (Get-Item2 $plan 'firewall WINRM-HTTPS-In-TCP')[0]
        $https.Desired | Should -Not -Be 'off'
        $https.Desired | Should -Match '^on, every profile, from '
    }
}
