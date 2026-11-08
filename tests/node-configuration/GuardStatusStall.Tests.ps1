#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the first real runs' stall: the node-side guarded change worked every time, but the host never received the guard STATUS answer, so every status call hung to
# its hard cap and the guard ended Unknown. Covered here: (1) a call abandoned at its cap still hands back what the node had already written; (2) the status script
# answers at once (partial) after the acknowledgement, reads the log tail through a shared stream and lists the net-* folders without recursion; (3) the ack-only
# script; (4) the host uses a partial answer and the ack-only call. The node scripts RUN for real here, in a child pwsh against a folder in TestDrive (they are written
# in Windows PowerShell 5.1 syntax, which pwsh runs too); no node, no network, no Azure.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/GuardStatusStall.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester runs a module mock in the module scope; a global is how the mock reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test fixture credential, not a secret.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport members take the parameters of the real ones.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration')
    foreach ($m in 'AzlNodeTransport', 'AzlNodeGuard', 'AzlOsConfigurationEvents', 'AzlGuardedChange') { Import-Module (Join-Path $dir "$m.psm1") -Force }

    function ConvertTo-Line([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }
    # Runs a node script (status or ack) for real in a child pwsh and returns the decoded AZLRESULT lines in the order they were written.
    function Invoke-NodeScript([string]$Text, [hashtable]$Params) {
        $file = Join-Path $TestDrive "payload-$([guid]::NewGuid().ToString('N')).ps1"
        [IO.File]::WriteAllText($file, $Text, [Text.UTF8Encoding]::new($true))
        $p = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Params | ConvertTo-Json -Compress -Depth 5)))
        $exe = (Get-Process -Id $PID).Path
        $lines = @(& $exe -NoProfile -File $file -ParamsB64 $p 2>&1 | ForEach-Object { [string]$_ })
        $failure = @($lines | Where-Object { $_ -notlike 'AZLRESULT:*' })
        if ($failure.Count) { throw "the node script wrote something else than result lines: $($failure -join ' | ')" }
        , @($lines | ForEach-Object { ConvertTo-AzlNodeResult -Text $_ })
    }
    function New-ChangeFolder([string]$Root, [string]$Id, [string]$State, [string]$Cookie = 'ck1') {
        $d = Join-Path $Root "net-$Id"
        $null = New-Item -ItemType Directory -Force -Path $d
        $json = [ordered]@{ v = 1; generation = 3; changeId = $Id; group = 'Services'; state = $State; reason = 'r'; cookie = $Cookie; updatedUtc = '2026-11-07T20:00:00.0000000Z'; deadlineUtc = '2026-11-07T20:30:00.0000000Z'; watchdog = $true } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $d "net-$Id.state.json") -Value $json -Encoding UTF8
        return $d
    }
}

Describe 'A call abandoned at its cap hands back what the node had already written' {
    BeforeEach {
        $global:StallOrder = [System.Collections.Generic.List[string]]::new()
        $global:StallPartial = @('some noise', (ConvertTo-Line ([pscustomobject]@{ v = 1; found = $true; partial = $true; state = [pscustomobject]@{ state = 'Committed' } })))
        Mock -ModuleName AzlNodeTransport Get-AzlWinRmSession { [pscustomobject]@{ State = 'Opened' } }
        Mock -ModuleName AzlNodeTransport Invoke-Command { [pscustomobject]@{ Id = 7 } } -RemoveParameterType 'Session'
        Mock -ModuleName AzlNodeTransport Wait-Job { return $null } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Receive-Job { $global:StallOrder.Add('receive'); if ($Keep) { $global:StallOrder.Add('keep') }; $global:StallPartial } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Stop-Job { $global:StallOrder.Add('stop') } -RemoveParameterType 'Job'
        # the job is stopped and removed in a background thread job: the order that matters is the partial output being taken before that clean-up is handed over
        Mock -ModuleName AzlNodeTransport Start-ThreadJob { $global:StallOrder.Add('cleanup'); [pscustomobject]@{ Id = 1 } }
        Mock -ModuleName AzlNodeTransport Remove-Job { $global:StallOrder.Add('remove') } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Remove-PSSession { } -RemoveParameterType 'Session'
        Mock -ModuleName AzlNodeTransport Wait-AzlNodeJob { $false }
        $script:t = New-AzlWinRmTransport -Address @{ n2 = '192.0.2.12' } -Credential ([pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
    }

    It 'returns the partial output with Failed true and State TimedOut, taken with Receive-Job -Keep BEFORE the job is stopped' {
        $r = & $script:t.Invoke $script:t 'n2' 'script' @{} @{} 30
        $r.Failed | Should -BeTrue
        $r.State | Should -Be 'TimedOut'
        $r.Output | Should -Match 'AZLRESULT:'
        $r.Output | Should -Match 'some noise'
        $global:StallOrder.IndexOf('keep') | Should -BeGreaterOrEqual 0
        $global:StallOrder.IndexOf('cleanup') | Should -BeGreaterThan $global:StallOrder.IndexOf('keep')
    }
    It 'Invoke-AzlNodeScript decodes the line the abandoned call had written and uses it, marked as recovered from the timeout' {
        $r = Invoke-AzlNodeScript -Transport $script:t -Node n2 -Script 'x' -Tries 1 -TimeoutSeconds 30
        $r.partial | Should -BeTrue
        $r.state.state | Should -Be 'Committed'
        $r.azlRecoveredFromTimeout | Should -BeTrue
    }
    It 'a partial output with no result line, or a cut one, is still the indeterminate timeout' {
        foreach ($text in @(@('only noise'), @('AZLRESULT:@@@not-base64', 'x'), @())) {
            $global:StallPartial = $text
            $caught = $null
            try { Invoke-AzlNodeScript -Transport $script:t -Node n2 -Script 'x' -Tries 1 -TimeoutSeconds 30 } catch { $caught = $_ }
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Data['AzlState'] | Should -Be 'Indeterminate'
        }
    }
}

Describe 'The status script (run for real against a state folder)' {
    BeforeEach {
        $script:root = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Force -Path $script:root
    }
    It 'writes the acknowledgement, then answers at once with a partial result, and the full result is the LAST line' {
        $d = New-ChangeFolder $script:root 'abc123def456' 'AwaitingConfirm'
        $lines = Invoke-NodeScript (Get-AzlGuardStatusPayload) @{ changeId = 'abc123def456'; dir = $script:root; ackToken = 'TOKEN1'; cookie = 'ck1'; logTail = 5 }
        $lines.Count | Should -Be 2
        $lines[0].partial | Should -BeTrue
        $lines[0].found | Should -BeTrue
        $lines[0].identityOk | Should -BeTrue
        $lines[0].ackWritten | Should -BeTrue
        $lines[0].state.state | Should -Be 'AwaitingConfirm'
        $lines[0].PSObject.Properties.Name | Should -Not -Contain 'log'
        $lines[0].PSObject.Properties.Name | Should -Not -Contain 'scriptSha256Actual'
        $lines[1].PSObject.Properties.Name | Should -Not -Contain 'partial'
        $lines[1].PSObject.Properties.Name | Should -Contain 'log'
        $lines[1].PSObject.Properties.Name | Should -Contain 'scriptSha256Actual'
        (Get-Content -LiteralPath (Join-Path $d 'net-abc123def456.ack') -Raw) | Should -Be 'TOKEN1'
    }
    It 'the partial result is written BEFORE the log, the hash and the live adapter are touched (order of the statements in the script)' {
        $text = Get-AzlGuardStatusPayload
        $early = $text.IndexOf('partial = $true')
        $early | Should -BeGreaterThan 0
        $early | Should -BeLessThan $text.IndexOf('$logPath = Join-Path')
        $early | Should -BeLessThan $text.IndexOf('Get-FileHash')
        $early | Should -BeLessThan $text.IndexOf('Get-NetAdapter')
        $text.IndexOf('$compact = ') | Should -BeLessThan $early -Because 'the compact state is built before the early answer'
        $text.IndexOf('WriteAllText') | Should -BeLessThan $early -Because 'the acknowledgement is written first'
    }
    It 'reads the log tail through a stream that shares the file with a live writer, the last lines in order, the cut first line dropped' {
        $d = New-ChangeFolder $script:root 'abc123def456' 'Verifying'
        $log = Join-Path $d 'abc123def456.log'
        Set-Content -LiteralPath $log -Value (1..2000 | ForEach-Object { "2026-11-07T20:00:00Z line $_ with some padding to make the file longer than eight kilobytes" }) -Encoding UTF8
        # the engine appends to this file while the status script reads it
        $writer = [IO.FileStream]::new($log, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $lines = Invoke-NodeScript (Get-AzlGuardStatusPayload) @{ changeId = 'abc123def456'; dir = $script:root; logTail = 7 }
        }
        finally { $writer.Dispose() }
        $full = $lines[-1]
        @($full.log).Count | Should -Be 7
        $full.log[-1] | Should -Match 'line 2000 '
        $full.log[0] | Should -Match 'line 1994 '
        (Get-AzlGuardStatusPayload) | Should -Not -Match 'Get-Content -LiteralPath \$logPath -Tail'
        (Get-AzlGuardStatusPayload) | Should -Match 'FileShare\]::ReadWrite'
    }
    It 'with no change id it takes the newest net-* folder, one level only (no recursion into a deep tree)' {
        $null = New-ChangeFolder $script:root 'old000000001' 'Committed'
        $new = New-ChangeFolder $script:root 'new000000002' 'RolledBack'
        (Get-Item (Join-Path $new 'net-new000000002.state.json')).LastWriteTime = [datetime]::Now.AddMinutes(-5)
        (Get-Item (Join-Path $script:root 'net-old000000001\net-old000000001.state.json')).LastWriteTime = [datetime]::Now.AddMinutes(-30)
        # a newer decoy state file deeper in the tree: the old -Recurse enumeration would take it
        $deep = Join-Path $script:root 'net-old000000001\sub\deeper'
        $null = New-Item -ItemType Directory -Force -Path $deep
        Set-Content -LiteralPath (Join-Path $deep 'net-decoy0000003.state.json') -Value ([ordered]@{ changeId = 'decoy0000003'; state = 'Failed' } | ConvertTo-Json) -Encoding UTF8
        $lines = Invoke-NodeScript (Get-AzlGuardStatusPayload) @{ dir = $script:root; logTail = 3 }
        $lines[-1].state.changeId | Should -Be 'new000000002'
        (Get-AzlGuardStatusPayload) | Should -Not -Match '-Recurse'
        (Get-AzlGuardStatusPayload) | Should -Match "Get-ChildItem -LiteralPath \`$base -Directory -Filter 'net-\*'"
    }
    It 'a folder with no state says found = false (one result line)' {
        $lines = Invoke-NodeScript (Get-AzlGuardStatusPayload) @{ dir = $script:root }
        $lines.Count | Should -Be 1
        $lines[0].found | Should -BeFalse
    }
}

Describe 'The ack-only script (run for real)' {
    BeforeEach {
        $script:root = Join-Path $TestDrive "ack-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $null = New-Item -ItemType Directory -Force -Path $script:root
    }
    It 'writes the token file while the change is AwaitingConfirm and nothing more is read (one small result: written)' {
        $d = New-ChangeFolder $script:root 'abc123def456' 'AwaitingConfirm'
        $lines = Invoke-NodeScript (Get-AzlGuardAckPayload) @{ changeId = 'abc123def456'; dir = $script:root; ackToken = 'TOKEN2'; cookie = 'ck1' }
        $lines.Count | Should -Be 1
        $lines[0].written | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $d 'net-abc123def456.ack') -Raw) | Should -Be 'TOKEN2'
        (Get-AzlGuardAckPayload) | Should -Not -Match 'Get-NetAdapter|Get-FileHash|\.log'
    }
    It 'refuses a wrong cookie, a missing token, a change that is not AwaitingConfirm and an unknown change; nothing is written' {
        $d = New-ChangeFolder $script:root 'abc123def456' 'AwaitingConfirm'
        (Invoke-NodeScript (Get-AzlGuardAckPayload) @{ changeId = 'abc123def456'; dir = $script:root; ackToken = 'T'; cookie = 'WRONG' })[0].why | Should -Match 'identity'
        (Invoke-NodeScript (Get-AzlGuardAckPayload) @{ changeId = 'abc123def456'; dir = $script:root; cookie = 'ck1' })[0].why | Should -Match 'token'
        (Invoke-NodeScript (Get-AzlGuardAckPayload) @{ changeId = 'nope00000000'; dir = $script:root; ackToken = 'T' })[0].written | Should -BeFalse
        Test-Path (Join-Path $d 'net-abc123def456.ack') | Should -BeFalse
        $v = New-ChangeFolder $script:root 'ver000000001' 'Verifying'
        $r = (Invoke-NodeScript (Get-AzlGuardAckPayload) @{ changeId = 'ver000000001'; dir = $script:root; ackToken = 'T'; cookie = 'ck1' })[0]
        $r.written | Should -BeFalse
        $r.why | Should -Match 'Verifying'
        Test-Path (Join-Path $v 'net-ver000000001.ack') | Should -BeFalse
    }
    It 'stays Windows PowerShell 5.1 syntax: no ternary, no null-coalescing, no &&' {
        foreach ($text in @((Get-AzlGuardAckPayload), (Get-AzlGuardStatusPayload))) {
            $text | Should -Not -Match '\?\?'
            $text | Should -Not -Match '&&'
            $text | Should -Not -Match '\) \? '
        }
    }
}

Describe 'The host uses a partial answer and the ack-only call' {
    BeforeAll {
        function New-FakeClock {
            $state = @{ Now = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc) }
            [pscustomobject]@{ State = $state; Now = { $state.Now }.GetNewClosure(); Sleep = { param($Seconds) $state.Now = $state.Now.AddSeconds($Seconds) }.GetNewClosure() }
        }
        function New-Spec { [pscustomobject]@{ Name = 'n1'; Management = [pscustomobject]@{ Mac = '00005e005311'; Ip = '192.0.2.60'; Prefix = 24; Gateway = '192.0.2.1'; Dns = @('192.0.2.4'); Vlan = 0 } } }
        function New-State { [pscustomobject]@{ nics = @([pscustomobject]@{ n = 'Port0'; mac = '00005e005311'; ips = @('192.0.2.50/24/Dhcp'); gw = @('192.0.2.1'); dhcp = 'Enabled'; dns = @() }); remote = [pscustomobject]@{ winrm = 'Running'; listeners = 1 } } }
        function New-Item1 { @{ id = 'RemoteManagement/WinRM'; kind = 'winrm' } }
        # A WinRM fake that answers by the marker of the script: Stage, Status (a scenario decides) and Ack (written).
        function New-FakeTransport([scriptblock]$Status, [object]$Clock) {
            $log = [System.Collections.Generic.List[object]]::new()
            $t = [pscustomobject]@{ Kind = 'WinRM'; Log = $log; Invoke = $null }
            $enc = ${function:ConvertTo-Line}
            $t.Invoke = {
                param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
                $what = if ($Script -match 'AZL-GUARD-STAGE') { 'Stage' } elseif ($Script -match 'AZL-GUARD-ACK') { 'Ack' } elseif ($Script -match 'AZL-GUARD-STATUS') { 'Status' } else { 'Other' }
                $log.Add([pscustomobject]@{ Kind = $what; Parameters = $Parameters; TimeoutSeconds = $TimeoutSeconds })
                $r = switch ($what) {
                    'Stage' { @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' } }
                    'Ack' { @{ v = 1; written = $true; why = '' } }
                    default { & $Status ($log | Where-Object Kind -eq 'Status').Count }
                }
                [pscustomobject]@{ Output = (& $enc $r); Failed = $false; Error = ''; State = 'Succeeded' }
            }.GetNewClosure()
            $t | Add-Member -NotePropertyName GetAddress -NotePropertyValue ({ param($Self, $Node) '192.0.2.50' })
            $t | Add-Member -NotePropertyName GetPort -NotePropertyValue ({ param($Self, $Node) 5985 })
            $t | Add-Member -NotePropertyName SetAddress -NotePropertyValue ({ param($Self, $Node, $Address) })
            $t | Add-Member -NotePropertyName CloseSession -NotePropertyValue ({ param($Self, $Node) })
            return $t
        }
        function New-Answer([string]$State, [switch]$Partial, [bool]$AckWritten = $false) {
            $a = @{ v = 1; found = $true; identityOk = $true; nowUtc = '2026-11-07T10:01:00Z'; ackWritten = $AckWritten; state = @{ changeId = 'abc123def456'; group = 'Services'; state = $State; reason = "node says $State"; verdict = ''; repairs = @(); deadlineUtc = '2026-11-07T10:30:00Z' } }
            if (-not $Partial) { $a.scriptSha256Actual = (Get-AzlGuardScriptHash -ChangeId 'abc123def456'); $a.live = @{ ips = @(); gw = @() }; $a.log = @() } else { $a.partial = $true }
            $a
        }
    }
    BeforeEach { Mock -ModuleName AzlGuardedChange New-AzlChangeId { 'abc123def456' } }

    It 'Resolve-AzlGuardStatus accepts a partial Committed (no script hash, no live port in it), and says so' {
        $partial = [pscustomobject]@{ v = 1; found = $true; identityOk = $true; partial = $true; state = [pscustomobject]@{ state = 'Committed'; reason = 'all checks passed' } }
        $r = Resolve-AzlGuardStatus -Status $partial -ExpectedHash 'ABCDEF' -ExpectedIp '192.0.2.60'
        $r.Final | Should -BeTrue
        $r.State | Should -Be 'Committed'
        $r.Reason | Should -Match 'early answer'
    }
    It 'a full Committed whose live port lacks the new address is still Failed (the check is kept for a full answer)' {
        $full = [pscustomobject]@{ v = 1; found = $true; identityOk = $true; state = [pscustomobject]@{ state = 'Committed' }; live = [pscustomobject]@{ ips = @('192.0.2.99/24/Manual/Preferred') } }
        (Resolve-AzlGuardStatus -Status $full -ExpectedIp '192.0.2.60').State | Should -Be 'Failed'
    }
    It 'a guarded change finishes Committed on a partial answer' {
        $clock = New-FakeClock
        $t = New-FakeTransport { param($n) New-Answer Committed -Partial } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Services -Item @(New-Item1) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        $o.State | Should -Be 'Committed'
    }
    It 'when the state is already known to be AwaitingConfirm the token goes in the ack-only call (cap 30), then the next read gets the state' {
        $clock = New-FakeClock
        $t = New-FakeTransport { param($n) if ($n -eq 1) { New-Answer AwaitingConfirm -Partial } else { New-Answer Committed -Partial } } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Services -Item @(New-Item1) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        $o.State | Should -Be 'Committed'
        $acks = @($t.Log | Where-Object Kind -eq 'Ack')
        $acks.Count | Should -Be 1
        $acks[0].TimeoutSeconds | Should -BeLessOrEqual 30
        @($acks[0].Parameters.Keys | Sort-Object) | Should -Be @('ackToken', 'changeId', 'cookie', 'machineSid')
        $acks[0].Parameters.cookie | Should -Be 'ck'
        $acks[0].Parameters.ackToken | Should -Be (Get-AzlGuardToken -ChangeId 'abc123def456' -ScriptHash (Get-AzlGuardScriptHash -ChangeId 'abc123def456') -Cookie 'ck')
        # order: status (AwaitingConfirm), ack, status (Committed)
        @($t.Log | Where-Object Kind -in 'Status', 'Ack').Kind | Should -Be @('Status', 'Ack', 'Status')
    }
    It 'when the status read already wrote the acknowledgement (ackWritten) no ack-only call is made' {
        $clock = New-FakeClock
        $t = New-FakeTransport { param($n) if ($n -eq 1) { New-Answer AwaitingConfirm -Partial -AckWritten $true } else { New-Answer Committed -Partial } } $clock
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Services -Item @(New-Item1) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe { $true }
        $o.State | Should -Be 'Committed'
        @($t.Log | Where-Object Kind -eq 'Ack').Count | Should -Be 0
    }
}
