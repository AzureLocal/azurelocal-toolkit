#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Tests for the run-level behavior the first real runs needed: the caps of every call, a guarded change that ends Unknown but whose items are in place on the node
# (ObservedCommitted: the run goes on), one that is not in place (Unknown: the run stops, as before), the circuit breaker after a status call that timed out, the phase
# the heartbeat names, and the first read after staging. A fake transport with a fake clock: no node, no network, no Azure, and no real waiting.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/GuardStallFlow.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester runs a module mock in the module scope; a global is how the mock reports back to the test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake transport and mock script blocks keep the signature of the real ones.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    foreach ($m in 'infrastructure\AzlInfrastructure', 'azure-local\AzlAzure', 'node-configuration\AzlNodePayload', 'node-configuration\AzlNodeTransport', 'node-configuration\AzlNodeGuard', 'node-configuration\AzlOsConfigurationEvents', 'node-configuration\AzlGuardedChange', 'node-configuration\AzlNodeConfiguration') {
        Import-Module (Join-Path $repo "scripts\common\$m.psm1") -Force
    }
    Import-Module powershell-yaml
    $script:Fixture = Join-Path $repo 'tests\fixtures\infrastructure.fc-san.yml'
    function Get-Infra { Import-AzlInfrastructure -Path $script:Fixture -SkipValidation }
    function ConvertTo-ResultLine([object]$Object) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
        'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
    }
    # A node that already matches the spec: what the Read script would return for it.
    function New-ConfiguredState([object]$Spec) {
        $nics = foreach ($p in $Spec.Ports) {
            $isMgmt = $p.IsManagement
            [pscustomobject]@{
                n = "OS$($p.Name)"; mac = $p.Mac; st = $(if ($p.Roles -contains 'unused') { 'Disabled' } else { 'Up' }); pci = 'PCI\VEN_15B3&DEV_101D'; drv = '24.4.1.0'; desc = 'x'
                dhcp = 'Disabled'; ips = $(if ($isMgmt) { @("$($Spec.Management.Ip)/$($Spec.Management.Prefix)/Manual") } else { @() })
                gw = $(if ($isMgmt) { @($Spec.Management.Gateway) } else { @() }); dns = $(if ($isMgmt) { @($Spec.Management.Dns) } else { @() }); vlan = $null
            }
        }
        [pscustomobject]@{
            v = 1; host = $Spec.Hostname; boot = '2026-11-07T01:00:00Z'; os = '10.0.26100.1'; reboot = $false; nics = @($nics)
            remote = [pscustomobject]@{ winrm = 'Running'; winrmStart = 'Automatic'; listeners = 1; rdpDeny = 0; rdpRules = 3; icmp4 = 1; icmp6 = 1 }
            time = [pscustomobject]@{ type = 'NTP'; peers = ($Spec.Ntp | ForEach-Object { "$_,0x8" }) -join ' '; src = $Spec.Ntp[0] }
            sbe = @(); drv = @()
            admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $true }
            stor = [pscustomobject]@{ pools = 0; vdisks = 0; dirty = @() }
            san = [pscustomobject]@{
                feature = 'Enabled'; hw = @('DellEMC|PowerStore'); lb = 'RR'
                set = [pscustomobject]@{ RetryCount = '3'; UseCustomPathRecoveryTime = 'Enabled'; CustomPathRecoveryTime = '10'; DiskTimeoutValue = '30' }
                fc = @($Spec.San.ExpectedWwpn | ForEach-Object { [pscustomobject]@{ wwpn = $_; up = 'Online' } }); iqn = @(); iscsiSvc = ''; iscsiClaim = ''
                disks = @(
                    [pscustomobject]@{ n = 1; bus = 'Fibre Channel'; gb = 300; ps = 'RAW'; sn = 'SERIAL-INFRA'; uid = 'UID-INFRA'; lun = 0; paths = 4; st = 'Online' }
                    [pscustomobject]@{ n = 2; bus = 'Fibre Channel'; gb = 50; ps = 'RAW'; sn = 'SERIAL-PERF'; uid = 'UID-PERF'; lun = 1; paths = 4; st = 'Online' })
            }
            err = [pscustomobject]@{}
        }
    }
    function Set-WrongNtp($State) { $State.time.peers = 'time.windows.com,0x8' }
    function Set-DhcpOnPort($State, [string]$Mac) { $nic = $State.nics | Where-Object { $_.mac -eq $Mac }; $nic.dhcp = 'Enabled'; $nic.ips = @('203.0.113.9/24/Dhcp'); $nic.gw = @('203.0.113.1') }

    # A transport + clock for a whole run. Reads: the states in order (the last one repeats). Status calls take StatusSeconds on the fake clock (more than the call's cap:
    # the call is abandoned at the cap with no output, or with StatusPartial as its output); everything else answers at once.
    function New-Flow {
        param([object[]]$Reads, [double]$StatusSeconds = 0, [object]$StatusPartial, [scriptblock]$Apply, [int]$ThrowReadAt = 0, [string]$Answer = 'Committed')
        $clk = @{ Now = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc) }
        $log = [System.Collections.Generic.List[object]]::new()
        $queue = [System.Collections.Generic.Queue[object]]::new()
        foreach ($r in $Reads) { $queue.Enqueue($r) }
        $holder = @{ Last = $Reads[-1]; Reads = 0; Groups = @{}; N = 0 }
        $encode = ${function:ConvertTo-ResultLine}
        $transport = [pscustomobject]@{ Kind = 'WinRM'; State = @{}; Invoke = $null; Log = $log; GetAddress = { '192.0.2.11' }; GetPort = { 5985 }; SetAddress = {}; CloseSession = {} }
        $transport.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            $kind = if ($Script -match 'AZL-GUARD-STAGE') { 'GuardStage' } elseif ($Script -match 'AZL-GUARD-ACK') { 'GuardAck' } elseif ($Script -match 'AZL-GUARD-STATUS') { 'GuardStatus' } elseif ($Script -match 'function Invoke-Action') { 'Apply' } elseif ($Script -match 'shutdown\.exe') { 'Restart' } else { 'Read' }
            $phase = if ($Self.State.ContainsKey('Heartbeat') -and $Self.State.Heartbeat) { [string]$Self.State.Heartbeat.State.Phase } else { '' }
            $cap = $TimeoutSeconds + 15
            $entry = [pscustomobject]@{ Kind = $kind; Parameters = $Parameters; TimeoutSeconds = $TimeoutSeconds; Cap = $cap; Phase = $phase; Start = $clk.Now; Seconds = 0.0; TimedOut = $false }
            $log.Add($entry)
            $ok = { param($o) [pscustomobject]@{ Output = (& $encode $o); Failed = $false; Error = ''; State = 'Succeeded' } }
            switch ($kind) {
                'Read' {
                    $holder.Reads++
                    if ($ThrowReadAt -and $holder.Reads -eq $ThrowReadAt) { throw 'the read blew up' }
                    if ($queue.Count -gt 0) { $holder.Last = $queue.Dequeue() }
                    & $ok $holder.Last
                }
                'Apply' { & $ok (& $Apply $Parameters) }
                'Restart' { & $ok ([pscustomobject]@{ restartScheduled = $true }) }
                'GuardStage' {
                    $holder.Groups[[string]$Parameters.changeId] = [string]$Parameters.config.group
                    & $ok @{ v = 1; staged = $true; changeId = $Parameters.changeId; cookie = 'cookie1'; machineSid = 'S-1-5-21-1' }
                }
                'GuardAck' { & $ok @{ v = 1; written = $true; why = '' } }
                'GuardStatus' {
                    $spent = [Math]::Min($StatusSeconds, $cap)
                    $clk.Now = $clk.Now.AddSeconds($spent)
                    $entry.Seconds = $spent
                    if ($StatusSeconds -gt $cap) {
                        $entry.TimedOut = $true
                        $out = if ($null -ne $StatusPartial) { & $encode $StatusPartial } else { '' }
                        return [pscustomobject]@{ Output = $out; Failed = $true; Error = "The call to $Node did not finish within $cap seconds and was abandoned."; State = 'TimedOut' }
                    }
                    $id = if ($Parameters.ContainsKey('changeId')) { [string]$Parameters.changeId } else { '' }
                    & $ok @{ v = 1; found = $true; identityOk = $true; nowUtc = '2026-11-07T10:00:00Z'; partial = $true; state = @{ changeId = $id; group = [string]$holder.Groups[$id]; state = $Answer; reason = 'node says ' + $Answer; repairs = @(); deadlineUtc = '2026-11-07T11:00:00Z' } }
                }
            }
        }.GetNewClosure()
        $clock = [pscustomobject]@{ Now = { $clk.Now }.GetNewClosure(); Sleep = { param($Seconds) $clk.Now = $clk.Now.AddSeconds($Seconds) }.GetNewClosure() }
        [pscustomobject]@{ Transport = $transport; Clock = $clock; Clk = $clk; Log = $log }
    }
    function Invoke-Flow($Flow, $Spec, [hashtable]$Extra = @{}) {
        $ctx = New-AzlGuardEventContext
        $r = Invoke-AzlNodeConfiguration -Spec $Spec -Transport $Flow.Transport -Execute -SecretResolver { 'x' } -Clock $Flow.Clock -PortProbe { $true } -EventContext $ctx @Extra
        [pscustomobject]@{ Result = $r; Events = @($ctx.Sink); Started = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc) }
    }
    $global:ChangeCounter = 0
}

Describe 'A run on a node whose guard status never comes back' {
    BeforeAll { $script:Infra = Get-Infra; $script:Spec = Get-AzlNodeSpec -Infrastructure $script:Infra -Node $script:Infra.nodes[0] }
    BeforeEach {
        $global:ChangeCounter = 0
        Mock -ModuleName AzlGuardedChange New-AzlChangeId { $global:ChangeCounter++; 'chg{0:d9}' -f $global:ChangeCounter }
    }
    AfterAll { Remove-Variable -Name ChangeCounter -Scope Global -ErrorAction SilentlyContinue }

    Context 'every status call takes 120 s (past its cap)' {
        BeforeAll {
            $bad = New-ConfiguredState $script:Spec; Set-WrongNtp $bad
            $fixed = New-ConfiguredState $script:Spec
            $script:Flow = New-Flow -Reads @($bad, $fixed) -StatusSeconds 120
            $script:Run = Invoke-Flow $script:Flow $script:Spec
        }
        It 'every status call is capped at 30 s (+15 s grace): none costs more than 45 s, and none is asked for more than 30 s' {
            $status = @($script:Flow.Log | Where-Object Kind -eq 'GuardStatus')
            $status.Count | Should -BeGreaterThan 3
            foreach ($s in $status) {
                $s.TimeoutSeconds | Should -BeLessOrEqual 30
                $s.Seconds | Should -BeLessOrEqual 45
            }
        }
        It 'the whole run finishes within the guard wait (15 min) plus the capped calls, not one 210 s call after another' {
            $elapsed = ($script:Flow.Clk.Now - $script:Run.Started).TotalMinutes
            $elapsed | Should -BeLessThan 17.5
        }
        It 'the guard ended Unknown, the one Read (cap 90 s) shows the items in place, and the outcome is ObservedCommitted; the run goes on and converges' {
            $script:Run.Result.Guard.Count | Should -Be 1
            $script:Run.Result.Guard[0].State | Should -Be 'ObservedCommitted'
            $script:Run.Result.Guard[0].Group | Should -Be 'Services'
            $script:Run.Result.Converged | Should -BeTrue
            $script:Run.Result.Error | Should -BeNullOrEmpty
        }
        It 'the Read after the Unknown has a cap of 90 s, every Read has, and the stage call has 60 s' {
            foreach ($r in @($script:Flow.Log | Where-Object Kind -eq 'Read')) { $r.TimeoutSeconds | Should -Be 90 }
            foreach ($s in @($script:Flow.Log | Where-Object Kind -eq 'GuardStage')) { $s.TimeoutSeconds | Should -Be 60 }
        }
        It 'the circuit breaker: after one status call timed out, the final status read has a 30 s cap (15 s + 15 s grace)' {
            $last = @($script:Flow.Log | Where-Object Kind -eq 'GuardStatus')[-1]
            $last.TimeoutSeconds | Should -Be 15
            $last.Cap | Should -Be 30
        }
        It 'the feed has the ObservedCommitted event, a NodeCallAttempt per call (payload kind, state, address) and the changes of the group are recorded as changed' {
            @($script:Run.Events | Where-Object state -eq 'ObservedCommitted').Count | Should -Be 1
            $attempts = @($script:Run.Events | Where-Object state -eq 'NodeCallAttempt')
            $attempts.Count | Should -BeGreaterThan 5
            @($attempts | Where-Object { $_.payload -eq 'GuardStatus' -and $_.callState -eq 'TimedOut' }).Count | Should -BeGreaterThan 3
            ($attempts | Where-Object payload -eq 'Read' | Select-Object -First 1).address | Should -Be '192.0.2.11'
            $ntp = @($script:Run.Result.Changes | Where-Object Id -eq 'Time/ntp')
            $ntp.Status | Should -Contain 'changed'
        }
    }

    Context 'an Unknown guard whose items are NOT in place' {
        BeforeAll {
            $bad = New-ConfiguredState $script:Spec; Set-WrongNtp $bad
            $script:Flow2 = New-Flow -Reads @($bad) -StatusSeconds 120
            $script:Run2 = Invoke-Flow $script:Flow2 $script:Spec
        }
        It 'keeps Unknown and stops the run as before: the pass is not continued, the node is not converged, no second guarded change is staged' {
            $script:Run2.Result.Guard.Count | Should -Be 1
            $script:Run2.Result.Guard[0].State | Should -Be 'Unknown'
            $script:Run2.Result.Converged | Should -BeFalse
            @($script:Flow2.Log | Where-Object Kind -eq 'GuardStage').Count | Should -Be 1
            @($script:Run2.Events | Where-Object state -eq 'ObservedCommitted').Count | Should -Be 0
        }
        It 'it read the node exactly once more to decide (cap 90 s)' {
            # Read 1 is the plan, Read 2 is the reconciliation read; nothing else reads the node.
            @($script:Flow2.Log | Where-Object Kind -eq 'Read').Count | Should -Be 2
        }
    }

    Context 'a status call that times out with its answer already written' {
        BeforeAll {
            $bad = New-ConfiguredState $script:Spec; Set-WrongNtp $bad
            $fixed = New-ConfiguredState $script:Spec
            $partial = @{ v = 1; found = $true; identityOk = $true; nowUtc = '2026-11-07T10:00:00Z'; partial = $true; state = @{ changeId = 'chg000000001'; group = 'Services'; state = 'Committed'; reason = 'all checks passed'; repairs = @() } }
            $script:Flow3 = New-Flow -Reads @($bad, $fixed) -StatusSeconds 120 -StatusPartial $partial
            $script:Run3 = Invoke-Flow $script:Flow3 $script:Spec
        }
        It 'uses the answer: Committed after the first (abandoned) status call, not Unknown after 15 minutes' {
            $script:Run3.Result.Guard[0].State | Should -Be 'Committed'
            @($script:Flow3.Log | Where-Object { $_.Kind -eq 'GuardStatus' -and $_.TimedOut }).Count | Should -BeGreaterOrEqual 1
            (($script:Flow3.Clk.Now - $script:Run3.Started).TotalMinutes) | Should -BeLessThan 5
            $script:Run3.Result.Converged | Should -BeTrue
        }
        It 'the stall still trips the breaker: the final status read is the short one' {
            @($script:Flow3.Log | Where-Object Kind -eq 'GuardStatus')[-1].TimeoutSeconds | Should -Be 15
        }
    }

    Context 'ObservedCommitted continues the pass: the next step is attempted' {
        It 'Services observed, then the Network step (DHCP off on another port) is staged and committed, and the run converges' {
            $first = New-ConfiguredState $script:Spec; Set-WrongNtp $first; Set-DhcpOnPort $first '00005e005312'
            $second = New-ConfiguredState $script:Spec; Set-DhcpOnPort $second '00005e005312'
            $done = New-ConfiguredState $script:Spec
            # the first guarded change (Services) never answers; the second (Network) answers Committed
            $flow = New-Flow -Reads @($first, $second, $second, $done) -StatusSeconds 0
            $inner = $flow.Transport.Invoke
            $flow.Transport.Invoke = {
                param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
                if ($Script -match 'AZL-GUARD-STATUS' -and $Parameters.ContainsKey('changeId') -and $Parameters.changeId -eq 'chg000000001') {
                    $flow.Clk.Now = $flow.Clk.Now.AddSeconds($TimeoutSeconds + 15)
                    return [pscustomobject]@{ Output = ''; Failed = $true; Error = 'abandoned'; State = 'TimedOut' }
                }
                & $inner $Self $Node $Script $Parameters $Secrets $TimeoutSeconds
            }.GetNewClosure()
            $run = Invoke-Flow $flow $script:Spec
            @($run.Result.Guard | ForEach-Object { "$($_.Group):$($_.State)" }) | Should -Be @('Services:ObservedCommitted', 'Network:Committed')
            $run.Result.Converged | Should -BeTrue
            @($flow.Log | Where-Object Kind -eq 'GuardStage').Count | Should -Be 2
        }
    }
}

Describe 'The catch path and the pending-change read after a stalled status call' {
    BeforeAll { $script:Infra = Get-Infra; $script:Spec = Get-AzlNodeSpec -Infrastructure $script:Infra -Node $script:Infra.nodes[0] }
    BeforeEach {
        $global:ChangeCounter = 0
        Mock -ModuleName AzlGuardedChange New-AzlChangeId { $global:ChangeCounter++; 'chg{0:d9}' -f $global:ChangeCounter }
    }
    It 'a run that fails after a stalled status call reads the last guarded change with the short cap (the catch read)' {
        $bad = New-ConfiguredState $script:Spec; Set-WrongNtp $bad
        $fixed = New-ConfiguredState $script:Spec
        # Read 1 plans, Read 2 is the reconciliation read, Read 3 (next pass) blows up
        $flow = New-Flow -Reads @($bad, $fixed) -StatusSeconds 120 -ThrowReadAt 3
        $caught = $null
        try { $null = Invoke-Flow $flow $script:Spec } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Match 'blew up'
        @($flow.Log | Where-Object Kind -eq 'GuardStatus')[-1].TimeoutSeconds | Should -Be 15
    }
    It 'without a stalled status call the catch read and the final read have the normal 30 s cap' {
        $fixed = New-ConfiguredState $script:Spec
        $flow = New-Flow -Reads @($fixed) -StatusSeconds 0
        $null = Invoke-Flow $flow $script:Spec
        @($flow.Log | Where-Object Kind -eq 'GuardStatus')[-1].TimeoutSeconds | Should -Be 30
    }
    It 'Get-AzlPendingGuardState: 30 s, and 15 s (a 30 s cap) once a status call timed out in the run' {
        $flow = New-Flow -Reads @(New-ConfiguredState $script:Spec) -StatusSeconds 0
        $null = @(Get-AzlPendingGuardState -Transport $flow.Transport -Node n1 -ChangeId 'chg000000009' -Spec $script:Spec)
        $null = @(Get-AzlPendingGuardState -Transport $flow.Transport -Node n1 -ChangeId 'chg000000009' -Spec $script:Spec -StatusTimedOut)
        $calls = @($flow.Log | Where-Object Kind -eq 'GuardStatus')
        $calls[0].TimeoutSeconds | Should -Be 30
        $calls[1].TimeoutSeconds | Should -Be 15
    }
}

Describe 'The caps of the other calls' {
    BeforeAll { $script:Infra = Get-Infra; $script:Spec = Get-AzlNodeSpec -Infrastructure $script:Infra -Node $script:Infra.nodes[0] }
    BeforeEach {
        $global:ChangeCounter = 0
        Mock -ModuleName AzlGuardedChange New-AzlChangeId { $global:ChangeCounter++; 'chg{0:d9}' -f $global:ChangeCounter }
    }
    It 'an inline Apply without a storage wipe has 300 s; with a storage wipe 900 s' {
        $s2d = Get-Infra; $s2d.scenario.storage_architecture = 's2d'
        $spec = Get-AzlNodeSpec -Infrastructure $s2d -Node $s2d.nodes[0]
        $mpio = New-ConfiguredState $script:Spec; $mpio.san.feature = 'Disabled'
        $flow = New-Flow -Reads @($mpio) -Apply { param($p) [pscustomobject]@{ reboot = $false; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'ok' } }) } }
        $null = Invoke-Flow $flow $script:Spec
        @($flow.Log | Where-Object Kind -eq 'Apply')[0].TimeoutSeconds | Should -Be 300
        $dirty = New-ConfiguredState $spec
        $dirty.stor = [pscustomobject]@{ pools = 1; vdisks = 2; dirty = @([pscustomobject]@{ n = 3; id = 'SN-3'; sn = 'SN-3'; uid = 'UID-SN-3'; size = [int64]1000GB; model = 'M'; bus = 'NVMe'; ps = 'GPT'; why = 'GPT' }); cluster = [pscustomobject]@{ deployed = $false; why = @() } }
        $flow2 = New-Flow -Reads @($dirty) -Apply { param($p) [pscustomobject]@{ reboot = $false; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'cleared' } }) } }
        $null = Invoke-Flow $flow2 $spec @{ ClearStorage = [switch]$true }
        $wipe = @($flow2.Log | Where-Object { $_.Kind -eq 'Apply' -and @($_.Parameters.actions | Where-Object kind -eq 'storage-clear').Count })
        $wipe.Count | Should -Be 1
        $wipe[0].TimeoutSeconds | Should -Be 900
    }
    It 'the restart script has 60 s' {
        $mpio = New-ConfiguredState $script:Spec; $mpio.san.feature = 'Disabled'
        $flow = New-Flow -Reads @($mpio, $mpio) -Apply { param($p) [pscustomobject]@{ reboot = $true; results = @($p.actions | ForEach-Object { [pscustomobject]@{ id = $_.id; status = 'changed'; detail = 'ok' } }) } }
        Mock -ModuleName AzlNodeConfiguration Wait-AzlNodeRestart { [pscustomobject]@{ boot = 'new'; nics = @() } }
        try { $null = Invoke-Flow $flow $script:Spec } catch { $null = $_ }
        $restart = @($flow.Log | Where-Object Kind -eq 'Restart')
        $restart.Count | Should -BeGreaterOrEqual 1
        $restart[0].TimeoutSeconds | Should -Be 60
    }
    It 'the heartbeat names the guarded change while its calls run (phase "Guarded change <group>")' {
        $bad = New-ConfiguredState $script:Spec; Set-WrongNtp $bad
        $flow = New-Flow -Reads @($bad, (New-ConfiguredState $script:Spec)) -StatusSeconds 0
        $null = Invoke-Flow $flow $script:Spec
        @($flow.Log | Where-Object Kind -eq 'GuardStage')[0].Phase | Should -Be 'Guarded change Services'
        @($flow.Log | Where-Object Kind -eq 'GuardStatus')[0].Phase | Should -Be 'Guarded change Services'
    }
}

Describe 'The first read after staging a management change' {
    BeforeAll {
        function New-Spec { [pscustomobject]@{ Name = 'n1'; Management = [pscustomobject]@{ Mac = '00005e005311'; Ip = '192.0.2.60'; Prefix = 24; Gateway = '192.0.2.1'; Dns = @('192.0.2.4'); Vlan = 0 } } }
        function New-State { [pscustomobject]@{ nics = @([pscustomobject]@{ n = 'Port0'; mac = '00005e005311'; ips = @('192.0.2.50/24/Dhcp'); gw = @('192.0.2.1'); dhcp = 'Enabled'; dns = @() }); remote = [pscustomobject]@{ winrm = 'Running'; listeners = 1 } } }
    }
    It 'goes to the OLD address while the new one is closed, with the 30 s cap (45 s with grace); once the new one answers the next read is on it' {
        Mock -ModuleName AzlGuardedChange New-AzlChangeId { 'abc123def456' }
        $clk = @{ Now = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc); Addr = '192.0.2.50'; Probes = 0 }
        $log = [System.Collections.Generic.List[object]]::new()
        $enc = ${function:ConvertTo-ResultLine}
        $t = [pscustomobject]@{ Kind = 'WinRM'; Log = $log; Invoke = $null }
        $t.Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            if ($Script -match 'AZL-GUARD-STAGE') { return [pscustomobject]@{ Output = (& $enc @{ staged = $true; cookie = 'ck'; machineSid = 'S-1' }); Failed = $false; Error = ''; State = 'Succeeded' } }
            $log.Add([pscustomobject]@{ Address = $clk.Addr; TimeoutSeconds = $TimeoutSeconds })
            # the node is not reachable on the old address any more: the first read hangs to its cap
            if ($clk.Addr -eq '192.0.2.50' -and $log.Count -eq 1) { $clk.Now = $clk.Now.AddSeconds($TimeoutSeconds + 15); return [pscustomobject]@{ Output = ''; Failed = $true; Error = 'abandoned'; State = 'TimedOut' } }
            [pscustomobject]@{ Output = (& $enc @{ v = 1; found = $true; identityOk = $true; nowUtc = '2026-11-07T10:01:00Z'; partial = $true; state = @{ changeId = 'abc123def456'; group = 'Management'; state = 'Committed'; reason = 'ok'; repairs = @() } }); Failed = $false; Error = ''; State = 'Succeeded' }
        }.GetNewClosure()
        $t | Add-Member -NotePropertyName GetAddress -NotePropertyValue ({ param($Self, $Node) $clk.Addr }.GetNewClosure())
        $t | Add-Member -NotePropertyName GetPort -NotePropertyValue ({ param($Self, $Node) 5985 })
        $t | Add-Member -NotePropertyName SetAddress -NotePropertyValue ({ param($Self, $Node, $Address) $clk.Addr = $Address }.GetNewClosure())
        $t | Add-Member -NotePropertyName CloseSession -NotePropertyValue ({ param($Self, $Node) })
        $clock = [pscustomobject]@{ Now = { $clk.Now }.GetNewClosure(); Sleep = { param($Seconds) $clk.Now = $clk.Now.AddSeconds($Seconds) }.GetNewClosure() }
        # the new address answers only from the second probe pass on
        $probe = { param($Address, $Port) $clk.Probes++; if ($Address -eq '192.0.2.60') { $clk.Probes -ge 3 } else { $true } }.GetNewClosure()
        $item = @{ id = 'Network/00005e005311'; kind = 'nic-static'; management = $true; mac = '00005e005311'; ip = '192.0.2.60'; prefix = 24; gateway = '192.0.2.1'; dns = @('192.0.2.4') }
        $o = Invoke-AzlGuardedChange -Transport $t -Node n1 -Group Management -Item @($item) -Spec (New-Spec) -State (New-State) -Clock $clock -PortProbe $probe
        $log[0].Address | Should -Be '192.0.2.50'
        $log[0].TimeoutSeconds | Should -Be 30
        $log[1].Address | Should -Be '192.0.2.60'
        $o.State | Should -Be 'Committed'
        $o.Address | Should -Be '192.0.2.60'
    }
}
