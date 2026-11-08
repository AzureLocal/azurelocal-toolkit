#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for two things a silent hang taught us: (1) Plan and Apply both read the node's last guarded change through the read-only status script and put its
# state, reason, checks, repairs and the last 20 log lines into the report and summary; (2) every wait of the host writes a NodeWaiting heartbeat every 60
# seconds, with the phase read last. No node, no network, no Azure: fake transports, a fake clock, mocked WinRM cmdlets.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/GuardStatusAndHeartbeat.Tests.ps1
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
    Import-Module (Join-Path $dir 'AzlOsConfigurationRun.psm1') -Force

    function ConvertTo-Line([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }
    # A transport whose Invoke answers the status script with $Status (or throws $Throw) and remembers every call.
    function New-StatusTransport([object]$Status, [string]$Throw = '') {
        $log = [System.Collections.Generic.List[object]]::new()
        $t = [pscustomobject]@{ Kind = 'WinRM'; Invoke = $null; Log = $log }
        $encode = ${function:ConvertTo-Line}
        $t.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            $log.Add([pscustomobject]@{ Script = $Script; Parameters = $Parameters; Secrets = $Secrets })
            if ($Throw) { throw $Throw }
            [pscustomobject]@{ Output = (& $encode $Status); Failed = $false; Error = ''; State = 'Succeeded' }
        }.GetNewClosure()
        return $t
    }
    function New-Status([int]$LogLines = 25) {
        [pscustomobject]@{
            v = 1; host = 'n2'; found = $true; identityOk = $true; scriptSha256Actual = 'AA'; nowUtc = '2026-11-07T20:30:00.0000000Z'; ackWritten = $false
            state = [pscustomobject]@{
                changeId = '5c073442ba6d'; group = 'Management'; state = 'RolledBack'; reason = 'the management port did not answer on 192.0.2.12 within the window'; updatedUtc = '2026-11-07T20:27:10.0000000Z'
                oldAddress = '192.0.2.62'; newAddress = '192.0.2.12'; verdict = 'unreachable'; watchdog = $true
                checks = @([pscustomobject]@{ name = 'address-present'; ok = $true; detail = '192.0.2.12/24' }, [pscustomobject]@{ name = 'gateway-ping'; ok = $false; detail = 'no reply from 192.0.2.1' })
                repairs = @([pscustomobject]@{ rung = 'readd-address'; item = 'Network/mac'; ok = $false; detail = 'still unreachable' })
            }
            log = @(1..$LogLines | ForEach-Object { "2026-11-07T20:2$($_ % 10)Z line $_" })
        }
    }
    $script:Clock = $null
}

Describe 'Get-AzlLastGuardedChange (read only)' {
    It 'asks the status script for the newest change with no id, no token and no cookie, and a log tail of 20' {
        $t = New-StatusTransport (New-Status)
        $r = Get-AzlLastGuardedChange -Transport $t -Node n2
        $t.Log.Count | Should -Be 1
        @($t.Log[0].Parameters.Keys) | Should -Be @('logTail')
        $t.Log[0].Parameters.logTail | Should -Be 20
        $t.Log[0].Script | Should -Match 'AZL-GUARD-STATUS'
        $t.Log[0].Secrets | Should -BeNullOrEmpty
        $r.Found | Should -BeTrue
    }
    It 'returns state, reason, verdict, checks, repairs, addresses and exactly the last 20 log lines' {
        $r = Get-AzlLastGuardedChange -Transport (New-StatusTransport (New-Status 25)) -Node n2
        $r.ChangeId | Should -Be '5c073442ba6d'
        $r.Group | Should -Be 'Management'
        $r.State | Should -Be 'RolledBack'
        $r.Reason | Should -Match 'did not answer'
        $r.Verdict | Should -Be 'unreachable'
        $r.OldAddress | Should -Be '192.0.2.62'
        $r.NewAddress | Should -Be '192.0.2.12'
        @($r.Checks).Count | Should -Be 2
        ($r.Checks | Where-Object { -not $_.ok }).name | Should -Be 'gateway-ping'
        $r.Repairs[0].rung | Should -Be 'readd-address'
        $r.Log.Count | Should -Be 20
        $r.Log[-1] | Should -Match 'line 25$'
    }
    It 'never writes: the status script is the one the confirmation uses, but without ackToken the acknowledgement file is not written' {
        $payload = Get-AzlGuardStatusPayload
        $payload | Should -Match "Get-P \`$P 'ackToken'"
        $payload | Should -Match "if \(\`$token -and"
        $r = Get-AzlLastGuardedChange -Transport (New-StatusTransport (New-Status)) -Node n2
        $r.PSObject.Properties.Name | Should -Not -Contain 'AckWritten'
    }
    It 'a node with no state is Found false, and a node that cannot be read is Readable false with the error; it never throws' {
        $none = Get-AzlLastGuardedChange -Transport (New-StatusTransport ([pscustomobject]@{ v = 1; found = $false })) -Node n2
        $none.Found | Should -BeFalse
        $none.Readable | Should -BeTrue
        $bad = Get-AzlLastGuardedChange -Transport (New-StatusTransport $null 'The call to n2 did not finish within 930 seconds and was abandoned.') -Node n2
        $bad.Readable | Should -BeFalse
        $bad.Error | Should -Match 'abandoned'
    }
}

Describe 'ConvertTo-AzlGuardReportEntry and Format-AzlGuardSummary' {
    It 'the node''s last change becomes a guard entry of its own when this run made none' {
        $last = Get-AzlLastGuardedChange -Transport (New-StatusTransport (New-Status)) -Node n2
        $e = @(ConvertTo-AzlGuardReportEntry -Outcome @() -Last $last)
        $e.Count | Should -Be 1
        $e[0].source | Should -Be 'node'
        $e[0].state | Should -Be 'RolledBack'
        $e[0].checks.Count | Should -Be 2
        $e[0].log.Count | Should -Be 20
    }
    It 'this run''s outcome of the same change carries the node''s checks, repairs and log, and is not listed twice' {
        $last = Get-AzlLastGuardedChange -Transport (New-StatusTransport (New-Status)) -Node n2
        $outcome = [pscustomobject]@{ Group = 'Management'; State = 'RolledBack'; Reason = 'rolled back'; NextAction = 'read the log'; ChangeId = '5c073442ba6d'; OldAddress = '192.0.2.62'; NewAddress = '192.0.2.12'; Repairs = @(); Verdict = '' }
        $e = @(ConvertTo-AzlGuardReportEntry -Outcome @($outcome) -Last $last)
        $e.Count | Should -Be 1
        $e[0].source | Should -Be 'run'
        $e[0].nextAction | Should -Be 'read the log'
        $e[0].verdict | Should -Be 'unreachable'
        @($e[0].repairs) | Should -Be @('readd-address')
        $e[0].log.Count | Should -Be 20
    }
    It 'an outcome of another change and the node''s newest are both listed; nothing at all gives an empty list' {
        $last = Get-AzlLastGuardedChange -Transport (New-StatusTransport (New-Status)) -Node n2
        $other = [pscustomobject]@{ Group = 'Services'; State = 'Committed'; Reason = 'ok'; NextAction = ''; ChangeId = 'aaaaaaaaaaaa'; OldAddress = ''; NewAddress = ''; Repairs = @(); Verdict = '' }
        @(ConvertTo-AzlGuardReportEntry -Outcome @($other) -Last $last).Count | Should -Be 2
        @(ConvertTo-AzlGuardReportEntry -Outcome @() -Last $null).Count | Should -Be 0
        @(ConvertTo-AzlGuardReportEntry -Outcome @() -Last ([pscustomobject]@{ Found = $false; Readable = $true })).Count | Should -Be 0
    }
    It 'an unreadable node is reported, not hidden' {
        $bad = Get-AzlLastGuardedChange -Transport (New-StatusTransport $null 'boom') -Node n2
        $e = @(ConvertTo-AzlGuardReportEntry -Outcome @() -Last $bad)
        $e[0].state | Should -Be 'Unreadable'
        $e[0].reason | Should -Be 'boom'
    }
    It 'the summary lines name the change, its state, the failed check, the repair and the node log' {
        $last = Get-AzlLastGuardedChange -Transport (New-StatusTransport (New-Status)) -Node n2
        $text = (Format-AzlGuardSummary -Node n2 -Entry @(ConvertTo-AzlGuardReportEntry -Outcome @() -Last $last)) -join "`n"
        $text | Should -Match 'n2: change 5c073442ba6d \(Management\) \*\*RolledBack\*\*'
        $text | Should -Match 'check gateway-ping: FAILED \(no reply from 192\.0\.2\.1\)'
        $text | Should -Match 'check address-present: ok'
        $text | Should -Match 'repair: readd-address'
        $text | Should -Match 'line 25'
    }
}

Describe 'The wrapper keeps the guard entries per change and says so in the summary' {
    It 'a later read of the same change replaces the earlier one; a node-side change that did not commit warns once' {
        InModuleScope AzlOsConfigurationRun {
            $record = [ordered]@{ name = 'n2'; guard = @(); warnings = @() }
            $entry = [ordered]@{ source = 'node'; changeId = 'c1'; group = 'Management'; state = 'RolledBack'; reason = 'nope'; log = @() }
            Add-AzlRunGuardEntry -Record $record -Entry @($entry)
            Add-AzlRunGuardEntry -Record $record -Entry @($entry)
            @($record.guard).Count | Should -Be 1
            @($record.warnings).Count | Should -Be 1
            $record.warnings[0] | Should -Match 'last guarded change c1'
        }
    }
    It 'Format-AzlGuardSection is empty without a guard entry and a heading with one' {
        InModuleScope AzlOsConfigurationRun {
            Format-AzlGuardSection -Record @([pscustomobject]@{ name = 'n1'; guard = @() }) | Should -BeNullOrEmpty
            (Format-AzlGuardSection -Record @([pscustomobject]@{ name = 'n2'; guard = @([ordered]@{ source = 'node'; changeId = 'c1'; group = 'Management'; state = 'Committed'; reason = ''; updatedUtc = ''; verdict = ''; checks = @(); repairs = @(); log = @('a line') }) })) | Should -Match '### Guarded changes'
        }
    }
}

Describe 'The wait heartbeat (NodeWaiting)' {
    BeforeEach {
        $global:AzlHbT = [datetime]::SpecifyKind([datetime]'2026-11-07T20:00:00', [DateTimeKind]::Utc)
        $script:HbClock = [pscustomobject]@{ Now = { $global:AzlHbT }; Sleep = { param($Seconds) $global:AzlHbT = $global:AzlHbT.AddSeconds($Seconds) } }
    }
    It 'NodeWaiting is a state of the feed''s contract' {
        (Get-AzlOsConfigurationEventState).Node | Should -Contain 'NodeWaiting'
    }
    It 'writes nothing before 60 seconds, then one event per 60 seconds with what is awaited, how long and the phase read last' {
        $file = Join-Path $TestDrive 'hb.jsonl'
        $ctx = New-AzlGuardEventContext -Path $file -SchemaVersion '5.6.0'
        $hb = New-AzlWaitHeartbeat -EventContext $ctx -Node n2 -Transport WinRM -Clock $script:HbClock
        & $hb.SetPhase $hb 'AwaitingConfirm'
        & $hb.Begin $hb 'n2 to answer again'
        $global:AzlHbT = $global:AzlHbT.AddSeconds(30); & $hb.Tick $hb '' ''
        @($ctx.Sink | Where-Object state -eq 'NodeWaiting').Count | Should -Be 0
        $global:AzlHbT = $global:AzlHbT.AddSeconds(30); & $hb.Tick $hb '' ''
        $global:AzlHbT = $global:AzlHbT.AddSeconds(20); & $hb.Tick $hb '' ''
        $global:AzlHbT = $global:AzlHbT.AddSeconds(40); & $hb.Tick $hb '' 'Verifying'
        & $hb.End $hb
        $beats = @(Get-Content -LiteralPath $file -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $beats.Count | Should -Be 2
        $beats[0].state | Should -Be 'NodeWaiting'
        $beats[0].node | Should -Be 'n2'
        $beats[0].waiting | Should -Be 'n2 to answer again'
        $beats[0].phase | Should -Be 'AwaitingConfirm'
        $beats[0].elapsedSeconds | Should -Be 60
        $beats[0].evidence | Should -Match 'last phase read: AwaitingConfirm'
        $beats[1].elapsedSeconds | Should -Be 120
        $beats[1].phase | Should -Be 'Verifying'
        $beats[1].schemaVersion | Should -Be '5.6.0'
        $beats[1].transport | Should -Be 'WinRM'
    }
    It 'waits nest: the elapsed time counts from the outermost wait' {
        $ctx = New-AzlGuardEventContext
        $hb = New-AzlWaitHeartbeat -EventContext $ctx -Node n2 -Clock $script:HbClock
        & $hb.Begin $hb 'outer'
        $global:AzlHbT = $global:AzlHbT.AddSeconds(50)
        & $hb.Begin $hb 'inner'
        $global:AzlHbT = $global:AzlHbT.AddSeconds(15); & $hb.Tick $hb '' ''
        & $hb.End $hb
        $e = @($ctx.Sink | Where-Object state -eq 'NodeWaiting')
        $e.Count | Should -Be 1
        $e[0].elapsedSeconds | Should -Be 65
        $e[0].waiting | Should -Be 'inner'
    }
    It 'Wait-AzlNodeJob ticks the transport''s heartbeat between slices and gives up after the cap' {
        $global:AzlHbWaits = 0
        Mock -ModuleName AzlNodeTransport Wait-Job { $global:AzlHbWaits++; $global:AzlHbT = $global:AzlHbT.AddSeconds(5); if ($global:AzlHbWaits -ge 14) { return [pscustomobject]@{ Id = 1 } }; return $null } -RemoveParameterType 'Job'
        $ctx = New-AzlGuardEventContext
        $transport = [pscustomobject]@{ Kind = 'WinRM'; State = @{} }
        Set-AzlTransportHeartbeat -Transport $transport -Heartbeat (New-AzlWaitHeartbeat -EventContext $ctx -Node n2 -Transport WinRM -Clock $script:HbClock) -Confirm:$false
        (Wait-AzlNodeJob -Job ([pscustomobject]@{ Id = 1 }) -CapSeconds 600 -Transport $transport -Node n2) | Should -BeTrue
        $global:AzlHbWaits | Should -Be 14
        @($ctx.Sink | Where-Object state -eq 'NodeWaiting').Count | Should -Be 1 -Because '14 slices of 5 seconds are 70 seconds: one heartbeat at 60'
        $global:AzlHbWaits = 0
        Mock -ModuleName AzlNodeTransport Wait-Job { $global:AzlHbWaits++; return $null } -RemoveParameterType 'Job'
        (Wait-AzlNodeJob -Job ([pscustomobject]@{ Id = 1 }) -CapSeconds 20 -Transport $transport -Node n2) | Should -BeFalse
        $global:AzlHbWaits | Should -Be 4
    }
    It 'a WinRM call that stalls past its cap is abandoned and reported as failed, and its heartbeat is ended' {
        Mock -ModuleName AzlNodeTransport Get-AzlWinRmSession { [pscustomobject]@{ State = 'Opened' } }
        Mock -ModuleName AzlNodeTransport Invoke-Command { [pscustomobject]@{ Id = 7 } } -RemoveParameterType 'Session'
        Mock -ModuleName AzlNodeTransport Wait-Job { return $null } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Stop-Job { } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Remove-Job { } -RemoveParameterType 'Job'
        Mock -ModuleName AzlNodeTransport Remove-PSSession { } -RemoveParameterType 'Session'
        $ctx = New-AzlGuardEventContext
        $t = New-AzlWinRmTransport -Address @{ n2 = '192.0.2.12' } -Credential ([pscredential]::new('Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
        $hb = New-AzlWaitHeartbeat -EventContext $ctx -Node n2 -Transport WinRM -Clock $script:HbClock
        Set-AzlTransportHeartbeat -Transport $t -Heartbeat $hb -Confirm:$false
        $r = & $t.Invoke $t 'n2' 'script' @{} @{} 30
        $r.Failed | Should -BeTrue
        $r.Error | Should -Match 'did not finish within 60 seconds and was abandoned'
        Should -Invoke -ModuleName AzlNodeTransport Stop-Job -Times 1 -Exactly
        $hb.State.Depth | Should -Be 0
    }
}
