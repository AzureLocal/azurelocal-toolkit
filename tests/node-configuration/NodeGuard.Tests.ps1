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
            Calls = [System.Collections.Generic.List[string]]::new(); Probe = $false; Dup = $false; AckAfterSleeps = 3; Sleeps = 0
            Nics = @(
                [pscustomobject]@{ mac = 'aabbccddee01'; name = 'Port0'; gw = @('10.0.0.1'); metric = 25; ips = @([pscustomobject]@{ ip = '10.0.0.50'; prefix = 24; origin = 'Dhcp' }) }
                [pscustomobject]@{ mac = 'aabbccddee02'; name = 'Port1'; gw = @(); metric = 9999; ips = @() })
            Ok = @{ address = { $true }; gateway = { $true }; dns = { $true }; arc = { $true }; winrm = { $true } }
            ApplyThrows = @(); RestoreThrows = @(); Hash = 'HASH1'; Booted = $false
        }
        foreach ($k in $Over.Keys) { $w[$k] = $Over[$k] }
        return $w
    }

    function Set-World($w, [object[]]$Items, [string]$Proof = 'ack', [hashtable]$Cfg = @{}, [string]$State = 'Staged') {
        $c = [ordered]@{
            changeId = $script:Id; dir = $script:Dir; group = 'management'; proof = $Proof; windowMinutes = 10; startDelaySeconds = 0; checkSeconds = 30; repairSeconds = 20
            probe = $true; restartAfter = $false; probeHosts = @('management.azure.com')
            expect = [pscustomobject]@{ mac = 'aabbccddee01'; ip = '10.0.0.60'; requireGateway = $true; winrm = $true }; items = @($Items)
        }
        foreach ($k in $Cfg.Keys) { $c[$k] = $Cfg[$k] }
        $w.Files[$script:CfgPath] = ($c | ConvertTo-Json -Depth 8)
        $s = [ordered]@{ v = 1; changeId = $script:Id; state = $State; stagedUtc = $w.Time.ToString('o'); updatedUtc = $w.Time.ToString('o'); heartbeatUtc = $w.Time.ToString('o'); owner = ''; scriptSha256 = 'HASH1' }
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $ops = @{}
        $ops.Now = { $w.Time }.GetNewClosure()
        $ops.Sleep = { param($s) $w.Time = $w.Time.AddSeconds($s); $w.Sleeps++; if ($w.AckAfterSleeps -ge 0 -and $w.Sleeps -ge $w.AckAfterSleeps) { $w.Files['C:\fake\net-abc123def456.ack'] = '' } }.GetNewClosure()
        $ops.ReadText = { param($p) $w.Files[$p] }.GetNewClosure()
        $ops.WriteText = { param($p, $t) $w.Files[$p] = $t }.GetNewClosure()
        $ops.AppendText = { param($p, $t) $w.Files[$p] = [string]$w.Files[$p] + $t + "`n" }.GetNewClosure()
        $ops.Exists = { param($p) $w.Files.ContainsKey($p) }.GetNewClosure()
        $ops.FileHash = { param($p) $w.Hash }.GetNewClosure()
        $ops.BootTime = { if ($w.Booted) { $w.Time } else { $w.Time.AddHours(-1) } }.GetNewClosure()
        $ops.Reboot = { $w.Calls.Add('Reboot') }.GetNewClosure()
        $ops.UnregisterWatchdog = { param($id) $w.Calls.Add("Unregister $id") }.GetNewClosure()
        $ops.GetNics = { $w.Nics }.GetNewClosure()
        $ops.ProbeAddress = { param($ip, $mac) $w.Calls.Add("Probe $ip"); $w.Probe }.GetNewClosure()
        $ops.IsDuplicate = { param($mac, $ip) $w.Dup }.GetNewClosure()
        $ops.SnapshotItem = { param($i) @{ id = [string]$i.id; snap = $true } }.GetNewClosure()
        $ops.ApplyItem = { param($i) if ($w.ApplyThrows -contains [string]$i.id) { throw "cannot apply $($i.id)" }; $w.Applied.Add([string]$i.id); $w.Calls.Add("Apply $($i.id)") }.GetNewClosure()
        $ops.RestoreItem = { param($i, $snap) if ($w.RestoreThrows -contains [string]$i.id) { throw "cannot restore $($i.id)" }; $w.Restored.Add([string]$i.id); $w.Calls.Add("Restore $($i.id)"); $false }.GetNewClosure()
        foreach ($name in 'address', 'gateway', 'dns', 'arc', 'winrm') {
            $n = $name
            $ops["Check$(@{ address = 'Address'; gateway = 'Gateway'; dns = 'Dns'; arc = 'Arc'; winrm = 'WinRm' }[$n])"] = { param($cfg) @{ ok = [bool](& $w.Ok[$n]); detail = "$n fake" } }.GetNewClosure()
        }
        $ops.RestartArcAgent = { $w.Calls.Add('RestartArcAgent') }.GetNewClosure()
        $ops.EnableAdapter = { param($mac) $w.Calls.Add("EnableAdapter $mac") }.GetNewClosure()
        $ops.RestartNic = { param($mac) $w.Calls.Add('RestartNic') }.GetNewClosure()
        $ops.DhcpFallback = { param($mac) $w.Calls.Add('DhcpFallback') }.GetNewClosure()
        Set-GuardOps $ops
    }
    function Get-FinalState($w) { $w.Files[$script:StatePath] | ConvertFrom-Json }
    function Invoke-World($w) { Invoke-GuardedChange -ConfigPath $script:CfgPath -ScriptPath 'C:\fake\net-abc123def456.ps1' }
}

Describe 'Guarded change engine: the normal path' {
    It 'applies, checks, waits for the acknowledgement and commits' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        $s = Get-FinalState $w
        $s.state | Should -Be 'Committed'
        $s.oldAddress | Should -Be '10.0.0.50'
        $s.newAddress | Should -Be '10.0.0.60'
        $w.Applied | Should -Contain 'Network/aabbccddee01'
        $w.Restored.Count | Should -Be 0
        $w.Calls | Should -Contain "Unregister $script:Id"
        $w.Files['C:\fake\abc123def456.log'] | Should -Match 'state Committed'
    }

    It 'commits on proof from Azure (arc check) without an acknowledgement' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem) 'azure'
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'does not run twice: a final state only removes the watchdog' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem)
        $null = Invoke-World $w
        $w.Applied.Clear()
        Invoke-World $w | Should -Be 'Committed'
        $w.Applied.Count | Should -Be 0
    }

    It 'rolls back to the snapshot when the acknowledgement never arrives' {
        $w = New-World @{ AckAfterSleeps = -1 }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'RolledBack'
        $s = Get-FinalState $w
        $s.reason | Should -Match 'No acknowledgement'
        $w.Restored | Should -Contain 'Network/aabbccddee01'
        $s.verified | Should -BeTrue
    }

    It 'rolls back when an item fails to apply and restores the items already applied' {
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
        Set-World $w @(& $script:MgmtItem) 'ack' @{ probe = $false }
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'refuses a duplicate address that Windows detects after assigning it, and restores' {
        $w = New-World @{ Dup = $true }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Refused'
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

    It 'does not run a staged script whose hash differs' {
        $w = New-World @{ Hash = 'OTHER' }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Refused'
        (Get-FinalState $w).reason | Should -Match 'SHA-256'
        $w.Applied.Count | Should -Be 0
    }
}

Describe 'Guarded change engine: the repair ladder, one rung at a time' {
    It 'rung RestartArcAgent: the arc check passes after the Arc agent restarts, and the change commits' {
        $w = New-World
        $w.Ok.arc = { ($w.Applied.Count -eq 0) -or ($w.Calls -contains 'RestartArcAgent') }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        $s = Get-FinalState $w
        @($s.repairs | Where-Object ok).rung | Should -Contain 'RestartArcAgent'
        $s.reason | Should -Match 'RestartArcAgent'
        $w.Restored.Count | Should -Be 0
    }

    It 'rung ReapplyConfig: the address check passes after the configuration is applied a second time' {
        $w = New-World
        $w.Ok.address = { @($w.Calls | Where-Object { $_ -like 'Apply Network*' }).Count -ge 2 }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        @((Get-FinalState $w).repairs | Where-Object ok).rung | Should -Contain 'ReapplyConfig'
        $w.Restored.Count | Should -Be 0
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

    It 'rung RestartNic: the management port is restarted and the change commits' {
        $w = New-World
        $w.Ok.gateway = { ($w.Applied.Count -eq 0) -or ($w.Calls -contains 'RestartNic') }.GetNewClosure()
        Set-World $w @(New-Item2 'Dns/management' 'winrm')
        Invoke-World $w | Should -Be 'Committed'
        @((Get-FinalState $w).repairs | Where-Object ok).rung | Should -Contain 'RestartNic'
    }

    It 'rung RestoreSnapshot: when nothing else helps the whole snapshot is restored and the state is RolledBack, verified' {
        $w = New-World
        $w.Ok.address = { $w.Restored.Count -ge 2 }.GetNewClosure()
        Set-World $w @((& $script:MgmtItem), (New-Item2 'Dns/management' 'nic-dns' @{ servers = @('10.0.0.2') }))
        Invoke-World $w | Should -Be 'RolledBack'
        $s = Get-FinalState $w
        $s.verified | Should -BeTrue
        $s.reason | Should -Match 'snapshot was restored'
        $w.Calls | Should -Not -Contain 'DhcpFallback'
    }

    It 'rung DhcpFallback: if even the restored snapshot fails the checks the management port goes to DHCP' {
        $w = New-World
        $w.Ok.address = { $w.Calls -contains 'DhcpFallback' }.GetNewClosure()
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'RolledBack'
        $w.Calls | Should -Contain 'DhcpFallback'
        (Get-FinalState $w).verified | Should -BeTrue
    }

    It 'says plainly when the path cannot be verified after the restore' {
        $w = New-World
        $w.Ok.address = { $false }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'RolledBack'
        $s = Get-FinalState $w
        $s.verified | Should -BeFalse
        $s.reason | Should -Match 'console'
    }

    It 'marks RollbackFailed when a snapshot item cannot be restored' {
        $w = New-World @{ RestoreThrows = @('Network/aabbccddee01') }
        $w.Ok.address = { $false }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'RollbackFailed'
        (Get-FinalState $w).reason | Should -Match 'Console access'
    }

    It 'requires only the checks that passed before the change (a check that already failed does not roll the change back)' {
        $w = New-World
        $w.Ok.dns = { $false }
        Set-World $w @(& $script:MgmtItem)
        Invoke-World $w | Should -Be 'Committed'
        (Get-FinalState $w).baseline | Where-Object name -eq 'dns' | ForEach-Object { $_.ok } | Should -BeFalse
    }
}

Describe 'Guarded change engine: the watchdog resumes after a reboot or a crash' {
    It 'rolls back a change whose script died while applying' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem) 'ack' @{} 'Applying'
        $s = Get-FinalState $w
        $s | Add-Member -NotePropertyName owner -NotePropertyValue 'deadinstance' -Force
        $s | Add-Member -NotePropertyName snapshots -NotePropertyValue ([pscustomobject]@{ 'Network/aabbccddee01' = [pscustomobject]@{ snap = $true } }) -Force
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $w.Time = $w.Time.AddMinutes(5)
        Invoke-World $w | Should -Be 'RolledBack'
        (Get-FinalState $w).reason | Should -Match 'stopped while it was applying'
        $w.Restored | Should -Contain 'Network/aabbccddee01'
    }

    It 'leaves a change alone while its owner is alive (fresh heartbeat)' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem) 'ack' @{} 'Checking'
        $s = Get-FinalState $w
        $s | Add-Member -NotePropertyName owner -NotePropertyValue 'someoneelse' -Force
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        Invoke-World $w | Should -Be 'Busy'
    }

    It 'finishes the checks of a change whose script died while checking, and commits' {
        $w = New-World
        Set-World $w @(& $script:MgmtItem) 'azure' @{} 'Checking'
        $s = Get-FinalState $w
        $s | Add-Member -NotePropertyName owner -NotePropertyValue 'deadinstance' -Force
        $s | Add-Member -NotePropertyName deadlineUtc -NotePropertyValue $w.Time.AddMinutes(10).ToString('o') -Force
        $w.Files[$script:StatePath] = ($s | ConvertTo-Json -Depth 6)
        $w.Time = $w.Time.AddMinutes(5)
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'after a reboot (computer name) the watchdog runs the checks and commits' {
        $w = New-World
        Set-World $w @(New-Item2 'Hostname/name' 'hostname' @{ name = 'new-name' }) 'azure' @{ restartAfter = $true; group = 'hostname' }
        Invoke-World $w | Should -Be 'PendingReboot'
        (Get-FinalState $w).state | Should -Be 'PendingReboot'
        $w.Calls | Should -Contain 'Reboot'
        $w.Time = $w.Time.AddMinutes(3); $w.Booted = $true
        Invoke-World $w | Should -Be 'Committed'
    }

    It 'waits while the node has not restarted yet' {
        $w = New-World
        Set-World $w @(New-Item2 'Hostname/name' 'hostname' @{ name = 'new-name' }) 'azure' @{ restartAfter = $true; group = 'hostname' }
        $null = Invoke-World $w
        $w.Time = $w.Time.AddMinutes(3)
        Invoke-World $w | Should -Be 'PendingReboot'
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
