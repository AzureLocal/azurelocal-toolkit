#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the node-side guarded change engine (AzlNodeGuard.psm1). The engine text is dot-sourced on this host and every node
# operation is replaced by a fake (Set-GuardOps), so each state, check and repair rung runs without a node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/NodeGuard.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake node operations take the parameters of the real ones.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:GuardModule = [IO.Path]::Combine($repo, 'scripts', 'common', 'node-configuration', 'AzlNodeGuard.psm1')
    Import-Module $script:GuardModule -Force
    $script:EngineFile = Join-Path $TestDrive 'engine.ps1'
    Set-Content -LiteralPath $script:EngineFile -Value (Get-AzlGuardEngine)
    . $script:EngineFile

    $script:Id = 'abc123def456'
    $script:Dir = 'C:\fake'
    $script:CfgPath = 'C:\fake\net-abc123def456.json'
    $script:StatePath = 'C:\fake\net-abc123def456.state.json'
    $script:AckPath = 'C:\fake\net-abc123def456.ack'

    function New-Item2([string]$Id, [string]$Kind, [hashtable]$More = @{}) {
        $o = [ordered]@{ id = $Id; kind = $Kind; mac = 'aabbccddee01' }
        foreach ($k in $More.Keys) { $o[$k] = $More[$k] }
        return [pscustomobject]$o
    }
    $script:MgmtItem = { New-Item2 'Network/aabbccddee01' 'nic-static' @{ management = $true; ip = '10.0.0.60'; prefix = 24; gateway = '10.0.0.1'; dns = @('10.0.0.2') } }

    function New-World([hashtable]$Over = @{}) {
        $w = @{
            Time = [datetime]::SpecifyKind([datetime]'2026-11-07T10:00:00', [DateTimeKind]::Utc)
            Files = @{}; Applied = [System.Collections.Generic.List[string]]::new(); Restored = [System.Collections.Generic.List[string]]::new()
            Calls = [System.Collections.Generic.List[string]]::new(); Probe = $false; Dup = $false; AckAfterSleeps = 3; Sleeps = 0; Token = 'H(abc123def456:HASH1:)'; MutexBusy = $false; Topology = ''; VlanOk = $true; Panic = [System.Collections.Generic.List[string]]::new(); Finalized = [System.Collections.Generic.List[string]]::new()
            Nics = @(
                [pscustomobject]@{ mac = 'aabbccddee01'; name = 'Port0'; gw = @('10.0.0.1'); metric = 25; ips = @([pscustomobject]@{ ip = '10.0.0.50'; prefix = 24; origin = 'Dhcp' }) }
                [pscustomobject]@{ mac = 'aabbccddee02'; name = 'Port1'; gw = @(); metric = 9999; ips = @() })
            Ok = @{ address = { $true }; gateway = { $true }; dns = { $true }; arc = { $true }; winrm = { $true }; ports = { $true } }
            ApplyThrows = @(); RestoreThrows = @(); Hash = 'HASH1'; SnapshotThrows = $false
        }
        $w.BootTime = $w.Time.AddHours(-1)
        foreach ($k in $Over.Keys) { $w[$k] = $Over[$k] }
        return $w
    }

    function Set-World($w, [object[]]$Items, [string]$Unused = '', [hashtable]$Cfg = @{}, [string]$State = 'Staged') {
        $c = [ordered]@{
            changeId = $script:Id; dir = $script:Dir; group = 'management'; confirmMinutes = 10; stableSeconds = 0; startDelaySeconds = 0; checkSeconds = 30; repairSeconds = 20
            probe = $true; restartAfter = $false; probeHosts = @('management.azure.com')
            expect = [pscustomobject]@{ mac = 'aabbccddee01'; ip = '10.0.0.60'; requireGateway = $true; winrm = $true }; items = @($Items)
        }
        foreach ($k in $Cfg.Keys) { $c[$k] = $Cfg[$k] }
        $w.Files[$script:CfgPath] = ($c | ConvertTo-Json -Depth 8)
        $s = [ordered]@{ v = 1; changeId = $script:Id; state = $State; stagedUtc = $w.Time.ToString('o'); updatedUtc = $w.Time.ToString('o'); heartbeatUtc = $w.Time.ToString('o'); owner = ''; scriptSha256 = 'HASH1' }
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $ops = @{}
        $ops.Now = { $w.Time }.GetNewClosure()
        $ops.Sleep = { param($s) $w.Time = $w.Time.AddSeconds($s); $w.Sleeps++; if ($w.AckAfterSleeps -ge 0 -and $w.Sleeps -ge $w.AckAfterSleeps) { $w.Files['C:\fake\net-abc123def456.ack'] = $w.Token } }.GetNewClosure()
        $ops.ReadText = { param($p) $w.Files[$p] }.GetNewClosure()
        $ops.WriteText = { param($p, $t) $w.Files[$p] = $t }.GetNewClosure()
        $ops.AppendText = { param($p, $t) $w.Files[$p] = [string]$w.Files[$p] + $t + "`n" }.GetNewClosure()
        $ops.Exists = { param($p) $w.Files.ContainsKey($p) }.GetNewClosure()
        $ops.TextHash = { param($t) "H($t)" }
        $ops.FileHash = { param($p) $w.Hash }.GetNewClosure()
        $ops.BootTime = { $w.BootTime }.GetNewClosure()
        $ops.Tick = { [double]($w.Time - [datetime]::SpecifyKind([datetime]'2026-01-01', [DateTimeKind]::Utc)).TotalMilliseconds }.GetNewClosure()
        $ops.AcquireMutex = { param($n) -not $w.MutexBusy }.GetNewClosure()
        $ops.ReleaseMutex = { $w.Calls.Add('ReleaseMutex') }.GetNewClosure()
        $ops.WaitAdapters = { param($s) $true }.GetNewClosure()
        $ops.CheckTopology = { param($cfg) $w.Topology }.GetNewClosure()
        $ops.VlanCapable = { param($mac) $w.VlanOk }.GetNewClosure()
        $ops.WritePanic = { param($p, $nics) $w.Files[$p] = 'panic' }.GetNewClosure()
        $ops.RunPanic = { param($p) $w.Panic.Add($p); $w.Calls.Add('RunPanic') }.GetNewClosure()
        $ops.FinalizeItem = { param($i, $snap) $w.Finalized.Add([string]$i.id) }.GetNewClosure()
        $ops.Reboot = { $w.Calls.Add('Reboot') }.GetNewClosure()
        $ops.UnregisterWatchdog = { param($id) $w.Calls.Add("Unregister $id") }.GetNewClosure()
        $ops.GetNics = { $w.Nics }.GetNewClosure()
        $ops.ProbeAddress = { param($ip, $mac) $w.Calls.Add("Probe $ip"); $w.Probe }.GetNewClosure()
        $ops.IsDuplicate = { param($mac, $ip) if ([string]$w.Dup -eq 'throw') { throw 'boom in duplicate detection' }; $w.Dup }.GetNewClosure()
        $ops.SnapshotItem = { param($i) if ($w.SnapshotThrows) { throw 'cannot snapshot' }; @{ id = [string]$i.id; snap = $true } }.GetNewClosure()
        $ops.ApplyItem = { param($i) if ($w.ApplyThrows -contains [string]$i.id) { throw "cannot apply $($i.id)" }; $w.Applied.Add([string]$i.id); $w.Calls.Add("Apply $($i.id)") }.GetNewClosure()
        $ops.RestoreItem = { param($i, $snap) if ($w.RestoreThrows -contains [string]$i.id) { throw "cannot restore $($i.id)" }; $w.Restored.Add([string]$i.id); $w.Calls.Add("Restore $($i.id)"); $false }.GetNewClosure()
        foreach ($name in 'address', 'gateway', 'dns', 'arc', 'winrm', 'ports') {
            $n = $name
            $ops["Check$(@{ address = 'Address'; gateway = 'Gateway'; dns = 'Dns'; arc = 'Arc'; winrm = 'WinRm'; ports = 'Ports' }[$n])"] = { param($cfg) @{ ok = [bool](& $w.Ok[$n]); detail = "$n fake" } }.GetNewClosure()
        }
        $ops.RestartArcAgent = { $w.Calls.Add('RestartArcAgent') }.GetNewClosure()
        $ops.EnableAdapter = { param($mac) $w.Calls.Add("EnableAdapter $mac") }.GetNewClosure()
        $ops.RestartNic = { param($mac) $w.Calls.Add('RestartNic') }.GetNewClosure()
        Set-GuardOps $ops
    }
    function Get-FinalState($w) { $w.Files[$script:StatePath] | ConvertFrom-Json }
    function Invoke-World($w) { Invoke-GuardedChange -ChangeFile $script:CfgPath -ScriptPath 'C:\fake\net-abc123def456.ps1' }
}

Describe 'Guarded change engine: commit confirmed' {
    It 'applies, verifies, waits for the orchestrator''s confirmation token and commits' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        $s = Get-FinalState $w
        $s.state | Should -Be 'Committed'
        $s.confirmed | Should -BeTrue
        $s.oldAddress | Should -Be '10.0.0.50'
        $s.newAddress | Should -Be '10.0.0.60'
        $w.Applied | Should -Contain 'Network/aabbccddee01'
        $w.Restored.Count | Should -Be 0
        $w.Calls | Should -Contain "Unregister $script:Id"
        $log = $w.Files['C:\fake\abc123def456.log']
        foreach ($state in 'Snapshotted', 'Applying', 'Verifying', 'AwaitingConfirm', 'Committed') { $log | Should -Match "state $state" }
    }

    It 'keeps a copy of the state file' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        $w.Files['C:\fake\net-abc123def456.state.copy.json'] | Should -Be $w.Files[$script:StatePath]
    }

    It 'falls back to the copy when the state file is corrupt' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $w.Files['C:\fake\net-abc123def456.state.copy.json'] = $w.Files[$script:StatePath]
        $w.Files[$script:StatePath] = '{ not json'
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'does nothing when neither the state file nor the copy can be read' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $w.Files[$script:StatePath] = '{ not json'
        Invoke-World $w | Should -Be 'NoState'
        $w.Applied.Count | Should -Be 0
    }

    It 'does not run twice: a final state only removes the watchdog' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        $w.Applied.Clear()
        Invoke-World $w | Should -Be 'Committed'
        $w.Applied.Count | Should -Be 0
    }

    It 'reverts to the snapshot when the confirmation never arrives' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'RolledBack'
        $s = Get-FinalState $w
        $s.reason | Should -Match 'No confirmation from the orchestrator'
        $w.Restored | Should -Contain 'Network/aabbccddee01'
        $s.verified | Should -BeTrue
    }

    It 'ignores a confirmation file that does not hold the token, and reverts' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem)
        $w.Files['C:\fake\net-abc123def456.ack'] = 'someone elses token'
        Invoke-World $w | Should -Be 'RolledBack'
    }

    It 'reverts when an item fails to apply and restores the items already applied' {
        $w = New-World @{ ApplyThrows = @('Dns/management') }
        Set-World $w @((& $script:MgmtItem), (New-Item2 'Dns/management' 'nic-dns' @{ servers = @('10.0.0.2') }))
        Invoke-World $w | Should -Be 'RolledBack'
        (Get-FinalState $w).reason | Should -Match 'Dns/management failed to apply'
        $w.Restored | Should -Contain 'Network/aabbccddee01'
    }

    It 'never starts after its window' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $w.Time = $w.Time.AddMinutes(30)
        Invoke-World $w | Should -Be 'RolledBack'
        (Get-FinalState $w).reason | Should -Match 'never started'
        $w.Applied.Count | Should -Be 0
    }

    It 'requires the checks to stay green for the stable period' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem) '' @{ stableSeconds = 60 }
        $t0 = $w.Time
        Invoke-World $w | Should -Be 'Committed'
        ($w.Time - $t0).TotalSeconds | Should -BeGreaterOrEqual 60
    }

    It 'restarts the stable period each time a check flaps' {
        $w = New-World
        $w.Ok.gateway = { ($w.Applied.Count -eq 0) -or ($w.Sleeps % 2 -eq 0) -or ($w.Sleeps -ge 8) }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem) '' @{ stableSeconds = 40 }
        Invoke-World $w | Should -Be 'Committed'
        $w.Sleeps | Should -BeGreaterOrEqual 12
        (Get-FinalState $w).repairs | Should -BeNullOrEmpty
    }
}

Describe 'Guarded change engine: refusals' {
    It 'refuses an address another host answers on, and changes nothing' {
        $w = New-World @{ Probe = $true }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'Another host answers on 10.0.0.60'
        $w.Applied.Count | Should -Be 0
    }

    It 'skips the probe when addressProbe is off' {
        $w = New-World @{ Probe = $true }
        Set-World $w @(& $script:MgmtItem) '' @{ probe = $false }
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'refuses a duplicate address that Windows duplicate address detection reports, and restores' {
        $w = New-World @{ Dup = $true }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'duplicate address detection'
        $w.Restored | Should -Contain 'Network/aabbccddee01'
    }

    It 'refuses a plan that would disable the management port' {
        $w = New-World
        Set-World $w @(New-Item2 'UnusedAdapters/aabbccddee01' 'nic-disable')
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'disable the management port'
        $w.Applied.Count | Should -Be 0
    }

    It 'refuses a plan that would disable the port Arc reaches Azure through (the default gateway holder)' {
        $w = New-World
        $w.Nics[1].gw = @('10.9.9.1'); $w.Nics[1].metric = 5
        Set-World $w @([pscustomobject]@{ id = 'UnusedAdapters/aabbccddee02'; kind = 'nic-disable'; mac = 'aabbccddee02' })
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'default gateway'
    }

    It 'refuses DHCP-off on another port while the management port has no gateway' {
        $w = New-World
        $w.Nics[0].gw = @()
        Set-World $w @([pscustomobject]@{ id = 'Network/aabbccddee02'; kind = 'nic-clean'; mac = 'aabbccddee02' })
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'no default gateway'
    }

    It 'refuses to remove the address of the management port' {
        $w = New-World
        Set-World $w @(New-Item2 'Network/aabbccddee01' 'nic-clean')
        Invoke-World $w | Should -Be 'Refused'
    }

    It 'allows disabling an unrelated port' {
        $w = New-World
        Set-World $w @([pscustomobject]@{ id = 'UnusedAdapters/aabbccddee02'; kind = 'nic-disable'; mac = 'aabbccddee02' })
        Invoke-World $w | Should -Be 'Committed'
        $w.Applied | Should -Contain 'UnusedAdapters/aabbccddee02'
    }

    It 'does not run a staged script whose hash differs from the manifest' {
        $w = New-World @{ Hash = 'OTHER' }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'SHA-256'
        $w.Applied.Count | Should -Be 0
    }
}

Describe 'Guarded change engine: the repair ladder, one rung at a time' {
    It 'rung ReProbe: a check that recovers by itself passes the re-probe and nothing is changed' {
        $w = New-World
        $w.Ok.dns = { ($w.Applied.Count -eq 0) -or ($w.Sleeps -ge 14) }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        $s = Get-FinalState $w
        @($s.repairs | Where-Object ok).rung | Should -Be @('ReProbe')
        $w.Restored.Count | Should -Be 0
        $s.reason | Should -Match 'ReProbe'
    }
    It 'rung RestartArcAgent: a failing check recovers after the Arc agent restarts (Arc was in use), and the change commits' {
        $w = New-World
        $w.Ok.dns = { ($w.Applied.Count -eq 0) -or ($w.Calls -contains 'RestartArcAgent') }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        @((Get-FinalState $w).repairs | Where-Object ok).rung | Should -Contain 'RestartArcAgent'
        $w.Restored.Count | Should -Be 0
    }

    It 'does not restart the Arc agent when Arc was not in use before the change; Arc itself is never a commit predicate' {
        $w = New-World
        $w.Ok.arc = { $false }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        $w.Calls | Should -Not -Contain 'RestartArcAgent'
        $w2 = New-World
        $w2.Ok.gateway = { ($w2.Applied.Count -eq 0) -or ($w2.Restored.Count -gt 0) }.GetNewClosure()
        $w2.Ok.arc = { $false }
        Set-World $w2 @(& $script:MgmtItem)
        Invoke-World $w2 | Should -Be 'RolledBack'
        $w2.Calls | Should -Not -Contain 'RestartArcAgent'
    }
    It 'rung RestoreItem: only the failing item is restored; the node is healthy and the state is RolledBack (partial)' {
        $w = New-World
        $w.Ok.dns = { ($w.Applied.Count -eq 0) -or ($w.Restored -contains 'Dns/management') }.GetNewClosure()
        Set-World $w @((& $script:MgmtItem), (New-Item2 'Dns/management' 'nic-dns' @{ servers = @('10.0.0.2') }))
        Invoke-World $w | Should -Be 'RolledBack'
        $s = Get-FinalState $w
        $w.Restored | Should -Be @('Dns/management')
        $s.partial | Should -BeTrue
        @($s.restoredItems) | Should -Be @('Dns/management')
        @($s.repairs | Where-Object ok).rung | Should -Contain 'RestoreItem'
    }

    It 'rung ReEnableAdapter: the adapter that was disabled is enabled again' {
        $w = New-World
        $w.Ok.gateway = { ($w.Applied.Count -eq 0) -or ($w.Calls -contains 'EnableAdapter aabbccddee02') }.GetNewClosure()
        Set-World $w @([pscustomobject]@{ id = 'UnusedAdapters/aabbccddee02'; kind = 'nic-disable'; mac = 'aabbccddee02' })
        Invoke-World $w | Should -Be 'RolledBack'
        @((Get-FinalState $w).repairs | Where-Object ok).rung | Should -Contain 'ReEnableAdapter'
        @((Get-FinalState $w).restoredItems) | Should -Contain 'UnusedAdapters/aabbccddee02'
    }

    It 'never re-applies the configuration and never restarts the NIC as a repair' {
        $w = New-World
        $w.Ok.gateway = { ($w.Applied.Count -eq 0) -or ($w.Restored.Count -gt 0) }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'RolledBack'
        @($w.Calls | Where-Object { $_ -like 'Apply *' }).Count | Should -Be 1
        $w.Calls | Should -Not -Contain 'RestartNic'
    }

    It 'runs the rungs in the designed order and ends in the whole restore' {
        $w = New-World
        $w.Ok.address = { $w.Restored.Count -ge 2 }.GetNewClosure()
        Set-World $w @((& $script:MgmtItem), (New-Item2 'Dns/management' 'nic-dns' @{ servers = @('10.0.0.2') }))
        Invoke-World $w | Should -Be 'RolledBack'
        $order = @((Get-FinalState $w).repairs | ForEach-Object { $_.rung })
        $order[0] | Should -Be 'ReProbe'
        $order[1] | Should -Be 'RestartArcAgent'
        $order | Should -Contain 'RestoreItem'
    }
    It 'whole snapshot: when nothing else helps the whole snapshot is restored and the state is RolledBack, verified' {
        $w = New-World
        $w.Ok.address = { $w.Restored.Count -ge 2 }.GetNewClosure()
        Set-World $w @((& $script:MgmtItem), (New-Item2 'Dns/management' 'nic-dns' @{ servers = @('10.0.0.2') }))
        Invoke-World $w | Should -Be 'RolledBack'
        $s = Get-FinalState $w
        $s.verified | Should -BeTrue
        $s.verdict | Should -Be 'RolledBackVerified'
        $s.reason | Should -Match 'snapshot was restored'
    }

    It 'checks the node against the snapshot (not the intended address) after the whole restore' {
        $w = New-World
        $seen = [System.Collections.Generic.List[string]]::new()
        Set-World $w @(& $script:MgmtItem)
        $ops = (Get-Variable -Name GuardOps -Scope Script -ValueOnly)
        $ops.CheckAddress = { param($cfg) $seen.Add([string]$cfg.expect.ip); @{ ok = ([string]$cfg.expect.ip -eq ''); detail = 'x' } }.GetNewClosure()
        Invoke-World $w | Should -Be 'RolledBack'
        $seen | Should -Contain ''
        $seen | Should -Contain '10.0.0.60'
    }
    It 'ends in Failed (watchdog stays armed) when even the restored node fails the checks' {
        $w = New-World
        $w.Ok.address = { $false }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Failed'
        $s = Get-FinalState $w
        $s.state | Should -Be 'Failed'
        $s.verdict | Should -Be 'RollbackUnverified'
        $s.reason | Should -Match 'console'
        $w.Panic.Count | Should -Be 1
        $w.Calls | Should -Not -Contain "Unregister $script:Id"
    }

    It 'ends in Failed when a snapshot item cannot be restored, and tries again at the next watchdog run' {
        $w = New-World @{ RestoreThrows = @('Network/aabbccddee01') }
        $w.Ok.address = { $false }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Failed'
        (Get-FinalState $w).reason | Should -Match 'cannot restore Network/aabbccddee01'
        $w.RestoreThrows = @()
        $w.Ok.address = { $true }
        Invoke-World $w | Should -Be 'RolledBack'
        $w.Calls | Should -Contain "Unregister $script:Id"
    }

    It 'requires only the checks that passed before the change (a check that already failed does not roll the change back)' {
        $w = New-World
        $w.Ok.dns = { $false }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        (Get-FinalState $w).baseline | Where-Object name -eq 'dns' | ForEach-Object { $_.ok } | Should -BeFalse
    }

    It 'always requires the cleaned ports to end with no address and no default route' {
        $w = New-World
        $w.Ok.ports = { $w.Restored.Count -gt 0 }.GetNewClosure()
        Set-World $w @([pscustomobject]@{ id = 'Network/aabbccddee02'; kind = 'nic-clean'; mac = 'aabbccddee02' })
        Invoke-World $w | Should -Be 'RolledBack'
    }
}

Describe 'Guarded change engine: design review rules' {
    It 'runs the panic restore when the structured restore throws, and reports a verified rollback if the node is healthy again' {
        $w = New-World @{ RestoreThrows = @('Network/aabbccddee01') }
        $w.Ok.address = { $w.Calls -contains 'RunPanic' -or $w.Applied.Count -eq 0 }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem) '' @{} 'Staged'
        $w.AckAfterSleeps = -1
        Invoke-World $w | Should -Be 'RolledBack'
        $w.Calls | Should -Contain 'RunPanic'
        (Get-FinalState $w).verdict | Should -Be 'RolledBackVerified'
    }

    It 'writes the panic document before anything is changed' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $order = [System.Collections.Generic.List[string]]::new()
        $ops = (Get-Variable -Name GuardOps -Scope Script -ValueOnly)
        $orig = $ops.ApplyItem
        $ops.WritePanic = { param($p, $nics) $order.Add('panic') }.GetNewClosure()
        $ops.ApplyItem = { param($i) $order.Add('apply'); & $orig $i }.GetNewClosure()
        $null = Invoke-World $w
        $order[0] | Should -Be 'panic'
    }

    It 'does nothing while another controller holds the machine-wide mutex' {
        $w = New-World @{ MutexBusy = $true }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Busy'
        $w.Applied.Count | Should -Be 0
    }

    It 'releases the mutex when it is done' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        $w.Calls | Should -Contain 'ReleaseMutex'
    }

    It 'refuses when the management interface is an LBFO team member or a vSwitch uplink or does not own the address' {
        $w = New-World @{ Topology = 'Port0 is a member of the LBFO team Team1.' }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'LBFO'
        $w.Applied.Count | Should -Be 0
    }

    It 'removes the old address only after the confirmation (FinalizeItem)' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        $w.Finalized | Should -Contain 'Network/aabbccddee01'
    }

    It 'does not finalize when the change is rolled back' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        $w.Finalized.Count | Should -Be 0
    }

    It 'rolls back when removing the old address breaks the node' {
        $w = New-World
        $w.Ok.gateway = { ($w.Applied.Count -eq 0) -or ($w.Finalized.Count -eq 0) -or ($w.Restored.Count -gt 0) }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'RolledBack'
        (Get-FinalState $w).reason | Should -Match 'old address was removed'
    }

    It 'accepts a confirmation only with the node cookie in the token' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem)
        $s = Get-FinalState $w
        $s | Add-Member -NotePropertyName cookie -NotePropertyValue 'COOKIE1' -Force
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $w.Files[$script:AckPath] = 'H(abc123def456:HASH1:)'
        Invoke-World $w | Should -Be 'RolledBack'
        $w2 = New-World @{ AckAfterSleeps = -1 }
        Set-World $w2 @(& $script:MgmtItem)
        $s2 = Get-FinalState $w2
        $s2 | Add-Member -NotePropertyName cookie -NotePropertyValue 'COOKIE1' -Force
        $w2.Files[$script:StatePath] = ($s2 | ConvertTo-Json -Depth 6)
        $w2.Files[$script:AckPath] = 'H(abc123def456:HASH1:COOKIE1)'
        Invoke-World $w2 | Should -Be 'Committed'
    }

    It 'records RolledBackLateConfirm when the token arrives after the rollback started' {
        $w = New-World @{ AckAfterSleeps = -1 }
        $w.Ok.address = { $true }
        Set-World $w @(& $script:MgmtItem)
        $ops = (Get-Variable -Name GuardOps -Scope Script -ValueOnly)
        $orig = $ops.RestoreItem
        $ops.RestoreItem = { param($i, $snap) $w.Files['C:\fake\net-abc123def456.ack'] = 'H(abc123def456:HASH1:)'; & $orig $i $snap }.GetNewClosure()
        Invoke-World $w | Should -Be 'RolledBack'
        $s = Get-FinalState $w
        $s.lateConfirm | Should -BeTrue
        $s.reason | Should -Match 'RolledBackLateConfirm'
    }

    It 'a VLAN change is its own change: refused with anything else, and refused when the driver reports no VLAN capability' {
        $vlan = [pscustomobject]@{ id = 'Network/vlan/aabbccddee01'; kind = 'nic-vlan'; mac = 'aabbccddee01'; vlan = 100 }
        $w = New-World
        Set-World $w @($vlan, (& $script:MgmtItem))
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'one VLAN mutation per change'
        $w2 = New-World @{ VlanOk = $false }
        Set-World $w2 @($vlan)
        Invoke-World $w2 | Should -Be 'Refused'
        (Get-FinalState $w2).reason | Should -Match 'capability unknown'
        $w3 = New-World
        Set-World $w3 @($vlan)
        Invoke-World $w3 | Should -Be 'Committed'
    }

    It 'the node owns its deadline: the confirmation window runs on the monotonic clock' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        $s = Get-FinalState $w
        $s.confirmDeadlineTick | Should -Not -BeNullOrEmpty
        $s.bootUtc | Should -Not -BeNullOrEmpty
    }

    It 'keeps a generation number and refuses to write over a newer state' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        (Get-FinalState $w).generation | Should -BeGreaterThan 3
        $cfg = $w.Files[$script:CfgPath] | ConvertFrom-Json
        $old = [pscustomobject]@{ generation = 1; state = 'Applying' }
        { Save-GuardState $cfg $old } | Should -Throw '*another writer*'
    }

    It 'treats a failing checksum as corruption and falls back to the copy' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $w.Files['C:\fake\net-abc123def456.state.copy.json'] = $w.Files[$script:StatePath]
        $w.Files[$script:StatePath + '.sum'] = 'WRONG'
        Invoke-World $w | Should -Be 'Committed'
    }
}

Describe 'Guarded change engine: the watchdog resumes after a reboot or a crash' {
    It 'reverts a change whose script died while applying' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem) '' @{} 'Applying'
        $s = Get-FinalState $w
        $s | Add-Member -NotePropertyName owner -NotePropertyValue 'deadinstance' -Force
        $s | Add-Member -NotePropertyName snapshots -NotePropertyValue ([pscustomobject]@{ 'Network/aabbccddee01' = [pscustomobject]@{ snap = $true } }) -Force
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $w.Time = $w.Time.AddMinutes(5)
        Invoke-World $w | Should -Be 'RolledBack'
        (Get-FinalState $w).reason | Should -Match 'stopped while it was applying'
        $w.Restored | Should -Contain 'Network/aabbccddee01'
    }

    It 'finishes a change whose script died while verifying, and commits once confirmed' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem) '' @{} 'Verifying'
        $s = Get-FinalState $w
        $s | Add-Member -NotePropertyName owner -NotePropertyValue 'deadinstance' -Force
        $s | Add-Member -NotePropertyName deadlineUtc -NotePropertyValue $w.Time.AddMinutes(20).ToString('o') -Force
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $w.Time = $w.Time.AddMinutes(5)
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'resumes AwaitingConfirm with the time that is left, and reverts when it has run out' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem) '' @{} 'AwaitingConfirm'
        $s = Get-FinalState $w
        $s | Add-Member -NotePropertyName owner -NotePropertyValue 'deadinstance' -Force
        $s | Add-Member -NotePropertyName confirmDeadlineUtc -NotePropertyValue $w.Time.AddMinutes(2).ToString('o') -Force
        $s | Add-Member -NotePropertyName snapshots -NotePropertyValue ([pscustomobject]@{ 'Network/aabbccddee01' = [pscustomobject]@{ snap = $true } }) -Force
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $w.Time = $w.Time.AddMinutes(5)
        Invoke-World $w | Should -Be 'RolledBack'
        (Get-FinalState $w).reason | Should -Match 'No confirmation'
    }

    It 'after a reboot (computer name) the watchdog runs the checks and commits once confirmed' {
        $w = New-World
        Set-World $w @(New-Item2 'Hostname/name' 'hostname' @{ name = 'new-name' }) '' @{ restartAfter = $true; group = 'hostname' }
        Invoke-World $w | Should -Be 'Applying'
        $s = Get-FinalState $w
        $s.state | Should -Be 'Applying'
        $s.rebootRequestedUtc | Should -Not -BeNullOrEmpty
        $w.Calls | Should -Contain 'Reboot'
        $w.Time = $w.Time.AddMinutes(3); $w.BootTime = $w.Time
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'waits while the node has not restarted yet' {
        $w = New-World
        Set-World $w @(New-Item2 'Hostname/name' 'hostname' @{ name = 'new-name' }) '' @{ restartAfter = $true; group = 'hostname' }
        $null = Invoke-World $w
        $w.Time = $w.Time.AddMinutes(3)
        Invoke-World $w | Should -Be 'Applying'
    }
}
Describe 'Staged script and payloads' {
    It 'builds the same script text and hash for a change id every time' {
        (Get-AzlGuardScriptText -ChangeId $script:Id) | Should -Be (Get-AzlGuardScriptText -ChangeId $script:Id)
        (Get-AzlGuardScriptHash -ChangeId $script:Id) | Should -Match '^[0-9A-F]{64}$'
        (Get-AzlGuardScriptHash -ChangeId $script:Id) | Should -Not -Be (Get-AzlGuardScriptHash -ChangeId 'zzz999yyy888')
    }

    It 'parses as PowerShell: <Name>' -ForEach @(
        @{ Name = 'script'; Text = { Get-AzlGuardScriptText -ChangeId 'abc123def456' } }
        @{ Name = 'stage'; Text = { Get-AzlGuardStagePayload -ChangeId 'abc123def456' } }
        @{ Name = 'status'; Text = { Get-AzlGuardStatusPayload } }
    ) {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput((& $Text), [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'uses only Windows PowerShell 5.1 syntax on the node (no ternary, null coalescing, &&)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-AzlGuardScriptText -ChangeId $script:Id), [ref]$tokens, [ref]$errors)
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)).Count | Should -Be 0
        @($tokens | Where-Object { $_.Kind -in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'AndAnd', 'OrOr' }).Count | Should -Be 0
    }

    It 'carries the markers a fake transport tells the payloads apart by' {
        (Get-AzlGuardStagePayload -ChangeId $script:Id) | Should -Match 'AZL-GUARD-STAGE'
        (Get-AzlGuardStatusPayload) | Should -Match 'AZL-GUARD-STATUS'
    }

    It 'registers the watchdog at startup and every minute, and removes it itself' {
        $stage = Get-AzlGuardStagePayload -ChangeId $script:Id
        $stage | Should -Match 'New-ScheduledTaskTrigger -AtStartup'
        $stage | Should -Match 'RepetitionInterval \(New-TimeSpan -Minutes 1\)'
        (Get-AzlGuardEngine) | Should -Match 'Unregister-ScheduledTask'
    }
}

Describe 'Guarded change engine: an unhandled error never leaves the change Staged without a log' {
    It 'writes a first log line before the state is read, so an early failure leaves a trace' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $null = $w.Files.Remove($script:StatePath)
        Invoke-World $w | Should -Be 'NoState'
        $lines = @(($w.Files['C:\fake\abc123def456.log'] -split "`n") | Where-Object { $_ })
        $lines[0] | Should -Match ' start '
    }

    It 'logs UNHANDLED first, rolls back from Applying, and throws again so the script exits non-zero' {
        $w = New-World @{ Dup = 'throw' }
        Set-World $w @(& $script:MgmtItem)
        { Invoke-World $w } | Should -Throw '*boom in duplicate detection*'
        $log = [string]$w.Files['C:\fake\abc123def456.log']
        $log | Should -Match 'UNHANDLED'
        $log.IndexOf('UNHANDLED') | Should -BeLessThan $log.IndexOf('restored Network')
        (Get-FinalState $w).state | Should -Be 'RolledBack'
        $w.Restored | Should -Contain 'Network/aabbccddee01'
        $w.Calls | Should -Contain "Unregister $script:Id"
        $w.Calls | Should -Contain 'ReleaseMutex'
    }

    It 'before anything is applied the change ends Failed with the message (nothing to restore)' {
        $w = New-World @{ SnapshotThrows = $true }
        Set-World $w @(& $script:MgmtItem)
        { Invoke-World $w } | Should -Throw '*cannot snapshot*'
        $s = Get-FinalState $w
        $s.state | Should -Be 'Failed'
        $s.reason | Should -Match 'cannot snapshot'
        ([string]$w.Files['C:\fake\abc123def456.log']) | Should -Match 'UNHANDLED'
        $w.Restored.Count | Should -Be 0
    }
}

Describe 'Guarded change engine: which port carries the node to Azure' {
    BeforeEach {
        function New-TiedPortSet {
            # Six DHCP ports on one subnet, tied metrics: the ports being cleaned are listed first and have the lower ifIndex.
            $list = @()
            foreach ($k in 2..6) { $list += [pscustomobject]@{ mac = "aabbccddee0$k"; name = "Port$k"; ifIndex = (20 - $k); gw = @('10.0.0.1'); metric = 25; ips = @([pscustomobject]@{ ip = "10.0.0.5$k"; prefix = 24; origin = 'Dhcp' }) } }
            $list += [pscustomobject]@{ mac = 'aabbccddee01'; name = 'Port1'; ifIndex = 30; gw = @('10.0.0.1'); metric = 25; ips = @([pscustomobject]@{ ip = '10.0.0.50'; prefix = 24; origin = 'Dhcp' }) }
            return $list
        }
    }

    It 'DHCP-off on the five other ports is allowed when the management port holds a gateway too (tied metrics)' {
        $w = New-World
        $w.Nics = New-TiedPortSet
        $items = foreach ($k in 2..6) { [pscustomobject]@{ id = "Network/aabbccddee0$k"; kind = 'nic-clean'; mac = "aabbccddee0$k" } }
        Set-World $w @($items)
        Invoke-World $w | Should -Be 'Committed'
        $w.Applied.Count | Should -Be 5
    }

    It 'without a gateway on the management port the carrier is the best-metric port, ties broken by ifIndex, not by the order read' {
        $w = New-World
        $w.Nics = @(
            [pscustomobject]@{ mac = 'aabbccddee01'; name = 'Port0'; ifIndex = 5; gw = @(); metric = 9999; ips = @() }
            [pscustomobject]@{ mac = 'aabbccddee03'; name = 'PortHigh'; ifIndex = 12; gw = @('10.0.0.1'); metric = 25; ips = @() }
            [pscustomobject]@{ mac = 'aabbccddee02'; name = 'PortLow'; ifIndex = 11; gw = @('10.0.0.1'); metric = 25; ips = @() })
        Set-World $w @([pscustomobject]@{ id = 'UnusedAdapters/aabbccddee02'; kind = 'nic-disable'; mac = 'aabbccddee02' })
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'PortLow'
    }
}

Describe 'Guarded change engine: moving the management address from port A to port B' {
    BeforeEach {
        function New-MoveWorld {
            $w = New-World
            $w.Nics = @(
                [pscustomobject]@{ mac = 'aabbccddee01'; name = 'PortA'; ifIndex = 10; gw = @('10.0.0.1'); metric = 25; ips = @([pscustomobject]@{ ip = '10.0.0.50'; prefix = 24; origin = 'Manual' }) }
                [pscustomobject]@{ mac = 'aabbccddee02'; name = 'PortB'; ifIndex = 11; gw = @(); metric = 9999; ips = @() })
            return $w
        }
        $script:MoveItem = { New-Item2 'Network/aabbccddee02' 'nic-static' @{ mac = 'aabbccddee02'; management = $true; move = $true; ip = '10.0.0.50'; prefix = 24; gateway = '10.0.0.1'; dns = @('10.0.0.2') } }
        $script:MoveExpect = [pscustomobject]@{ mac = 'aabbccddee02'; ip = '10.0.0.50'; requireGateway = $true; winrm = $true; currentIp = '10.0.0.50' }
    }

    It 'allows the plan: the management port (B) has no gateway yet, the plan gives it one, and A is cleaned' {
        $w = New-MoveWorld
        Set-World $w @((& $script:MoveItem), (New-Item2 'Network/aabbccddee01' 'nic-clean')) '' @{ expect = $script:MoveExpect }
        Invoke-World $w | Should -Be 'Committed'
        $w.Applied | Should -Contain 'Network/aabbccddee02'
        $w.Applied | Should -Contain 'Network/aabbccddee01'
    }

    It 'does not probe the address it is moving (it answers on port A itself)' {
        $w = New-MoveWorld
        $w.Probe = $true
        Set-World $w @(& $script:MoveItem) '' @{ expect = $script:MoveExpect }
        Invoke-World $w | Should -Be 'Committed'
        $w.Calls | Should -Not -Contain 'Probe 10.0.0.50'
    }

    It 'still refuses cleaning another port when nothing gives the management port a gateway' {
        $w = New-MoveWorld
        $item = New-Item2 'Network/aabbccddee02' 'nic-static' @{ mac = 'aabbccddee02'; management = $true; move = $true; ip = '10.0.0.50'; prefix = 24 }
        Set-World $w @($item, (New-Item2 'Network/aabbccddee01' 'nic-clean')) '' @{ expect = $script:MoveExpect }
        Invoke-World $w | Should -Be 'Refused'
    }

    It 'a management MAC with no port is its own verdict: AdapterMissing (BIOS-disabled or not present)' {
        $w = New-World
        $w.Nics = @([pscustomobject]@{ mac = 'aabbccddee01'; name = 'PortA'; ifIndex = 10; gw = @('10.0.0.1'); metric = 25; ips = @() })
        Set-World $w @(New-Item2 'Network/aabbccddee02' 'nic-static' @{ mac = 'aabbccddee02'; management = $true; ip = '10.0.0.60'; prefix = 24; gateway = '10.0.0.1' }) '' @{ expect = [pscustomobject]@{ mac = 'aabbccddee02'; ip = '10.0.0.60'; requireGateway = $true; winrm = $true } }
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'AdapterMissing'
    }
}
