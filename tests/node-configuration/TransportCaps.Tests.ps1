#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the WinRM transport's caps: a call is abandoned at its timeout plus a 15 second grace, the session is opened with an open timeout of 30 s and a cancel timeout of
# 5 s, the wait is measured with a Stopwatch (not by counting slices), an abandoned call is cleaned up in a background thread job (the host never blocks on it), and every
# attempt is one NodeCallAttempt event. No node, no network, no Azure: the WinRM cmdlets are mocked.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/TransportCaps.Tests.ps1
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
    function New-Cred { [pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
}

Describe 'The hard cap of a call' {
    It 'is the call''s timeout plus 15 seconds; no timeout means 900 plus 15' {
        Get-AzlNodeCallCap -TimeoutSeconds 30 | Should -Be 45
        Get-AzlNodeCallCap -TimeoutSeconds 90 | Should -Be 105
        Get-AzlNodeCallCap -TimeoutSeconds 300 | Should -Be 315
        Get-AzlNodeCallCap -TimeoutSeconds 0 | Should -Be 915
    }
    It 'a WinRM call that stalls is reported as abandoned after timeout + 15 s (not +30 s, and not at least 60 s)' {
        Mock -ModuleName AzlNodeTransport Get-AzlWinRmSession { [pscustomobject]@{ State = 'Opened' } }
        Mock -ModuleName AzlNodeTransport Invoke-Command { [pscustomobject]@{ Id = 7 } } -RemoveParameterType 'Session'
        Mock -ModuleName AzlNodeTransport Wait-Job { return $null } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Receive-Job { } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Start-ThreadJob { [pscustomobject]@{ Id = 1 } }
        # the wait is real time now: the elapsed-time seam of Wait-AzlNodeJob is not reachable from here, so the cap is read from the message and the wait is shortened by mocking it
        Mock -ModuleName AzlNodeTransport Wait-AzlNodeJob { $false }
        $t = New-AzlWinRmTransport -Address @{ n2 = '192.0.2.12' } -Credential (New-Cred)
        (& $t.Invoke $t 'n2' 'script' @{} @{} 30).Error | Should -Match 'did not finish within 45 seconds'
        (& $t.Invoke $t 'n2' 'script' @{} @{} 90).Error | Should -Match 'did not finish within 105 seconds'
        (& $t.Invoke $t 'n2' 'script' @{} @{} 300).Error | Should -Match 'did not finish within 315 seconds'
    }
}

Describe 'The session options' {
    It 'New-AzlWinRmSessionOption: open timeout 30000 ms and cancel timeout 5000 ms' {
        $o = New-AzlWinRmSessionOption
        $o.OpenTimeout.TotalMilliseconds | Should -Be 30000
        $o.CancelTimeout.TotalMilliseconds | Should -Be 5000
        $o.SkipCACheck | Should -BeFalse
    }
    It 'with the certificate check skipped the options keep the same two timeouts' {
        $o = New-AzlWinRmSessionOption -SkipCertificateCheck
        $o.OpenTimeout.TotalMilliseconds | Should -Be 30000
        $o.CancelTimeout.TotalMilliseconds | Should -Be 5000
        $o.SkipCACheck | Should -BeTrue
        $o.SkipCNCheck | Should -BeTrue
        $o.SkipRevocationCheck | Should -BeTrue
    }
    It 'every session a transport opens is opened with those options, whether or not the certificate check is skipped' {
        $global:SessionArgs = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlNodeTransport New-PSSession {
            $global:SessionArgs.Add([pscustomobject]@{ Open = $SessionOption.OpenTimeout.TotalMilliseconds; Cancel = $SessionOption.CancelTimeout.TotalMilliseconds; SkipCA = $SessionOption.SkipCACheck; Address = $ComputerName })
            [pscustomobject]@{ State = 'Opened' }
        }
        foreach ($skip in $false, $true) {
            $t = New-AzlWinRmTransport -Address @{ n2 = '192.0.2.12' } -Credential (New-Cred) -SkipCertificateCheck:$skip
            $s = $t.State
            InModuleScope AzlNodeTransport -Parameters @{ S = $s } { $null = Get-AzlWinRmSession -State $S -Node 'n2' }
        }
        $global:SessionArgs.Count | Should -Be 2
        foreach ($a in $global:SessionArgs) {
            $a.Open | Should -Be 30000
            $a.Cancel | Should -Be 5000
        }
        $global:SessionArgs[0].SkipCA | Should -BeFalse
        $global:SessionArgs[1].SkipCA | Should -BeTrue
        Remove-Variable -Name SessionArgs -Scope Global -ErrorAction SilentlyContinue
    }
    It 'a session that cannot be opened names the node, the address, the port and the time it took, and writes an attempt event' {
        Mock -ModuleName AzlNodeTransport New-PSSession { throw 'The WinRM client cannot process the request.' }
        $ctx = New-AzlGuardEventContext
        $t = New-AzlWinRmTransport -Address @{ n2 = '192.0.2.12' } -Credential (New-Cred)
        Set-AzlTransportHeartbeat -Transport $t -Heartbeat (New-AzlWaitHeartbeat -EventContext $ctx -Node n2 -Transport WinRM) -Confirm:$false
        $s = $t.State
        $caught = $null
        try { InModuleScope AzlNodeTransport -Parameters @{ S = $s; T = $t } { $null = Get-AzlWinRmSession -State $S -Node 'n2' -Transport $T } } catch { $caught = $_ }
        $caught.Exception.Message | Should -Match 'n2'
        $caught.Exception.Message | Should -Match '192\.0\.2\.12:5985'
        $caught.Exception.Message | Should -Match 'cannot process'
        $e = @($ctx.Sink | Where-Object state -eq 'NodeCallAttempt')
        $e.Count | Should -Be 1
        $e[0].payload | Should -Be 'Session'
        $e[0].address | Should -Be '192.0.2.12'
        $e[0].level | Should -Be 'Warning'
    }
}

Describe 'Wait-AzlNodeJob measures real time' {
    It 'with a Stopwatch: slices that return early do not add up to the cap (five 0.3 s slices are 1.5 s, not 25 s)' {
        Mock -ModuleName AzlNodeTransport Wait-Job { Start-Sleep -Milliseconds 300; $null } -RemoveParameterType 'Job'
        $t = [pscustomobject]@{ Kind = 'WinRM'; State = @{} }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ok = Wait-AzlNodeJob -Job ([pscustomobject]@{ Id = 1 }) -CapSeconds 1 -Transport $t -Node n2
        $sw.Stop()
        $ok | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 0.9 -Because 'the old code counted the 5 s slice it asked for as elapsed and gave up after 0.3 s'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 6
    }
    It 'never waits a slice longer than what is left of the cap (cap 12, slice 5: 5, 5, 2)' {
        $global:Slices = [System.Collections.Generic.List[int]]::new()
        $global:Elapsed = 0
        Mock -ModuleName AzlNodeTransport Wait-Job { $global:Slices.Add([int]$Timeout); $global:Elapsed += $Timeout; $null } -RemoveParameterType 'Job'
        $t = [pscustomobject]@{ Kind = 'WinRM'; State = @{} }
        (Wait-AzlNodeJob -Job ([pscustomobject]@{ Id = 1 }) -CapSeconds 12 -Transport $t -Node n2 -Elapsed { $global:Elapsed }) | Should -BeFalse
        $global:Slices | Should -Be @(5, 5, 2)
        Remove-Variable -Name Slices, Elapsed -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'An abandoned call' {
    BeforeEach {
        $global:Cleanup = $null
        $global:Calls = [System.Collections.Generic.List[string]]::new()
        $script:t = New-AzlWinRmTransport -Address @{ n2 = '192.0.2.12' } -Credential (New-Cred)
        $global:Sess = [pscustomobject]@{ State = 'Opened'; Name = 'the-session' }
        $script:t.State.Sessions['n2'] = $global:Sess
        $global:Table = $script:t.State.Sessions
        Mock -ModuleName AzlNodeTransport Get-AzlWinRmSession { $global:Sess }
        Mock -ModuleName AzlNodeTransport Invoke-Command { [pscustomobject]@{ Id = 7 } } -RemoveParameterType 'Session'
        Mock -ModuleName AzlNodeTransport Wait-AzlNodeJob { $false }
        Mock -ModuleName AzlNodeTransport Receive-Job { } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Stop-Job { $global:Calls.Add('Stop-Job') } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Remove-Job { $global:Calls.Add('Remove-Job') } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Remove-PSSession { $global:Calls.Add('Remove-PSSession') } -RemoveParameterType 'Session'
        Mock -ModuleName AzlNodeTransport Start-ThreadJob { $global:Cleanup = [pscustomobject]@{ TableHadSession = $global:Table.ContainsKey('n2'); Arguments = $ArgumentList }; [pscustomobject]@{ Id = 99 } }
    }
    AfterAll { Remove-Variable -Name Cleanup, Calls, Sess, Table -Scope Global -ErrorAction SilentlyContinue }

    It 'is dropped from the session table FIRST, then Stop-Job, Remove-Job and Remove-PSSession run in a background thread job, not on the host''s thread' {
        $r = & $script:t.Invoke $script:t 'n2' 'script' @{} @{} 30
        $r.State | Should -Be 'TimedOut'
        $r.Failed | Should -BeTrue
        $global:Cleanup | Should -Not -BeNullOrEmpty -Because 'the clean-up was handed to Start-ThreadJob'
        $global:Cleanup.TableHadSession | Should -BeFalse -Because 'the session left the table before the clean-up started'
        $global:Cleanup.Arguments | Should -Contain $global:Sess
        $global:Calls | Should -BeNullOrEmpty -Because 'the host thread called none of Stop-Job, Remove-Job, Remove-PSSession (each can block on a stalled session)'
        $script:t.State.Sessions.ContainsKey('n2') | Should -BeFalse
    }
    It 'the next call opens a new session (the table has none)' {
        $null = & $script:t.Invoke $script:t 'n2' 'script' @{} @{} 30
        $script:t.State.Sessions.Count | Should -Be 0
    }
}

Describe 'Every attempt is an event' {
    BeforeAll {
        function New-AttemptFake([scriptblock]$Run) {
            $t = [pscustomobject]@{ Kind = 'WinRM'; State = @{}; Invoke = $Run; GetAddress = { param($Self, $Node) '192.0.2.12' } }
            Set-AzlTransportHeartbeat -Transport $t -Heartbeat $script:hb -Confirm:$false
            $t
        }
    }
    BeforeEach {
        $script:ctx = New-AzlGuardEventContext
        $script:hb = New-AzlWaitHeartbeat -EventContext $script:ctx -Node n2 -Transport WinRM
    }
    It 'a successful call: payload kind, duration, address, no error, level Info' {
        $t = New-AttemptFake {
            param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds)
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true}'); $ms = [IO.MemoryStream]::new(); $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
            $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
            [pscustomobject]@{ Output = ('AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())); Failed = $false; Error = ''; State = 'Succeeded' }
        }
        $null = Invoke-AzlNodeScript -Transport $t -Node n2 -Script 'x' -Kind Read -TimeoutSeconds 90 -Tries 1
        $e = @($script:ctx.Sink | Where-Object state -eq 'NodeCallAttempt')
        $e.Count | Should -Be 1
        $e[0].payload | Should -Be 'Read'
        $e[0].address | Should -Be '192.0.2.12'
        $e[0].level | Should -Be 'Info'
        $e[0].callState | Should -Be 'Succeeded'
        $e[0].timeoutSeconds | Should -Be 90
        $e[0].durationSeconds | Should -BeGreaterOrEqual 0
        $e[0].step | Should -Be 'Transport'
    }
    It 'a call that timed out: the error text and the state are in the event, level Warning, and the call still throws as before' {
        $t = New-AttemptFake { param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds) [pscustomobject]@{ Output = ''; Failed = $true; Error = 'The call to n2 did not finish within 45 seconds and was abandoned.'; State = 'TimedOut' } }
        { Invoke-AzlNodeScript -Transport $t -Node n2 -Script 'x# AZL-GUARD-STATUS' -Tries 1 -TimeoutSeconds 30 } | Should -Throw
        $e = @($script:ctx.Sink | Where-Object state -eq 'NodeCallAttempt')
        $e.Count | Should -Be 1
        $e[0].payload | Should -Be 'GuardStatus' -Because 'the kind is read from the script marker when the caller gave none'
        $e[0].callState | Should -Be 'TimedOut'
        $e[0].error | Should -Match 'abandoned'
        $e[0].level | Should -Be 'Warning'
    }
    It 'a call that throws (a session that cannot be opened) is an attempt event with the error, and the exception goes on' {
        $t = New-AttemptFake { param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds) throw 'no route to 192.0.2.12' }
        { Invoke-AzlNodeScript -Transport $t -Node n2 -Script 'x' -Kind Apply -Tries 1 } | Should -Throw '*no route*'
        $e = @($script:ctx.Sink | Where-Object state -eq 'NodeCallAttempt')
        $e.Count | Should -Be 1
        $e[0].payload | Should -Be 'Apply'
        $e[0].error | Should -Match 'no route'
    }
    It 'a transport without a heartbeat (a fake in a test) is left alone' {
        $t = [pscustomobject]@{ Kind = 'WinRM'; Invoke = { param($Self, $Node, $Script, $Parameters, $Secrets, $TimeoutSeconds) [pscustomobject]@{ Output = ''; Failed = $true; Error = 'x'; State = 'Failed' } } }
        { Invoke-AzlNodeScript -Transport $t -Node n2 -Script 'x' -Tries 1 } | Should -Throw
    }
}
