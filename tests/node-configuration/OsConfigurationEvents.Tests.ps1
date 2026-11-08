#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the OS configuration event feed (AzlOsConfigurationEvents.psm1): the writer, the plan folding and the retry warning reader.
# A temp file only: no network, no Azure, no node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/OsConfigurationEvents.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = Join-Path (Join-Path $repo 'scripts') (Join-Path 'common' 'node-configuration')
    Import-Module (Join-Path $dir 'AzlOsConfigurationEvents.psm1') -Force
    Import-Module (Join-Path $dir 'AzlNodeTransport.psm1') -Force
    function Read-FeedEvent([string]$Path) { @(Get-Content -LiteralPath $Path -Encoding utf8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
}

Describe 'Write-AzlOsConfigurationEvent' {
    It 'appends one JSON object per line with the ZTP shape, UTC time, no byte-order mark' {
        $file = Join-Path $TestDrive 'a.jsonl'
        Write-AzlOsConfigurationEvent -Path $file -Node 'n1' -State NodeStarted -Evidence 'hello' -Method Ztp -Transport ArcRunCommand | Should -BeTrue
        Write-AzlOsConfigurationEvent -Path $file -Node '*' -State RunCompleted -Level Error -NextAction 'fix it' | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($file)
        $bytes[0] | Should -Not -Be 0xEF
        $bytes[-1] | Should -Be 10
        $raw = Get-Content -LiteralPath $file
        $raw.Count | Should -Be 2
        $e = Read-FeedEvent $file
        $e[0].stage | Should -Be 'OsConfiguration'
        $e[0].node | Should -Be 'n1'
        $e[0].state | Should -Be 'NodeStarted'
        $e[0].method | Should -Be 'Ztp'
        $e[0].transport | Should -Be 'ArcRunCommand'
        $e[0].level | Should -Be 'Info'
        $e[0].PSObject.Properties.Name | Should -Contain 'step'
        $e[0].PSObject.Properties.Name | Should -Contain 'nextAction'
        $raw[0] | Should -Match '"timestamp":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z"'
        $e[1].level | Should -Be 'Error'
        $e[1].nextAction | Should -Be 'fix it'
    }
    It 'keeps UTF-8 text, flattens line breaks, and a timestamp that does not depend on the culture' {
        $file = Join-Path $TestDrive 'b.jsonl'
        $old = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('tr-TR')
            $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n1' -State StepFailed -Evidence "caf$([char]0xE9)`r`nline two" -Now ([datetime]::SpecifyKind([datetime]'2026-11-07T19:01:59.536', 'Utc'))
        }
        finally { [cultureinfo]::CurrentCulture = $old }
        $e = Read-FeedEvent $file
        $e[0].evidence | Should -Be "caf$([char]0xE9) line two"
        (Get-Content -LiteralPath $file -Raw) | Should -Match '\"timestamp\":\"2026-11-07T19:01:59.5360000Z\"'
    }
    It 'adds extra fields after the standard ones and never lets them replace a standard field' {
        $file = Join-Path $TestDrive 'c.jsonl'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node '*' -State RunStarted -Data @{ nodes = @('a', 'b'); state = 'Hijack'; exitCode = 0 }
        $e = (Read-FeedEvent $file)[0]
        $e.state | Should -Be 'RunStarted'
        @($e.nodes) | Should -Be @('a', 'b')
        $e.exitCode | Should -Be 0
    }
    It 'a single node name stays an array' {
        $file = Join-Path $TestDrive 'd.jsonl'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node '*' -State RunStarted -Data @{ nodes = @('only') }
        (Get-Content -LiteralPath $file -Raw) | Should -Match '"nodes":\["only"\]'
    }
    It 'never throws: no path, a directory as the path, an invalid name' {
        Write-AzlOsConfigurationEvent -Path '' -Node 'n' -State X | Should -BeFalse
        { Write-AzlOsConfigurationEvent -Path $TestDrive -Node 'n' -State X } | Should -Not -Throw
        Write-AzlOsConfigurationEvent -Path $TestDrive -Node 'n' -State X | Should -BeFalse
        { Write-AzlOsConfigurationEvent -Path "$TestDrive\bad|name?.jsonl" -Node 'n' -State X } | Should -Not -Throw
    }
    It 'creates the folder, and a reader that keeps the file open does not stop the writer' {
        $file = Join-Path $TestDrive 'sub\deeper\e.jsonl'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n' -State A
        $reader = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite,Delete')
        try { Write-AzlOsConfigurationEvent -Path $file -Node 'n' -State B | Should -BeTrue }
        finally { $reader.Dispose() }
        (Read-FeedEvent $file).state | Should -Be @('A', 'B')
    }
    It 'limits very long evidence' {
        $file = Join-Path $TestDrive 'f.jsonl'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n' -State A -Evidence ('x' * 5000)
        (Read-FeedEvent $file)[0].evidence.Length | Should -BeLessOrEqual 2000
    }
    It 'rejects a level or transport outside the contract' {
        { Write-AzlOsConfigurationEvent -Path (Join-Path $TestDrive 'g.jsonl') -Node 'n' -State A -Level Fatal } | Should -Throw
        { Write-AzlOsConfigurationEvent -Path (Join-Path $TestDrive 'g.jsonl') -Node 'n' -State A -Transport SSH } | Should -Throw
    }
}

Describe 'The event contract (os-configuration-design.md section 6)' {
    It 'has exactly the states of the contract, by level' {
        $c = Get-AzlOsConfigurationEventState
        $c.Run -join ',' | Should -Be 'RunStarted,PlanCompleted,WipeListPublished,WipeListApproved,WipeListRejected,RunCompleted'
        $c.Transport -join ',' | Should -Be 'StaleRunCommandDeleted,NodeCallAttempt,SbeDeliveryProgress'
        $c.Node -join ',' | Should -Be 'NodeStarted,MethodResolved,TransportResolved,NodeRetry,NodeRestarting,NodeConverged,NodeFailed,NodeBlocked,NodeReconnecting,NodeReconnected,NodeWaiting'
        $c.Step -join ',' | Should -Be 'StepPlanned,StepSkipped,StepApplying,StepApplied,StepFailed,StepVerified'
        $c.DomainJoin -join ',' | Should -Be 'DomainJoinPlanned,DomainJoinApplying,DomainJoined,DomainAdminsConfigured,DomainJoinFailed'
        $c.Guarded -join ',' | Should -Be 'NetworkChangeStaged,NetworkChangeVerifying,NetworkChangeAwaitingConfirm,NetworkChangeCommitted,NetworkChangeRepaired,NetworkChangeRolledBack,NetworkChangeRefused,ObservedCommitted'
    }
    It 'every line carries the contract fields, including payloadVersion and schemaVersion' {
        $file = Join-Path $TestDrive 'contract.jsonl'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node n1 -State NetworkChangeRolledBack -Step Network -Level Error -Evidence 'reason' -Method Iso -Transport WinRM -PayloadVersion '1' -SchemaVersion '5.3.0' -Data @{ reason = 'gateway unreachable'; confirmBy = '2026-11-07T19:11:59.0000000Z' }
        $e = (Read-FeedEvent $file)[0]
        $names = $e.PSObject.Properties.Name
        foreach ($f in 'timestamp', 'node', 'stage', 'step', 'state', 'evidence', 'level', 'nextAction', 'method', 'transport', 'payloadVersion', 'schemaVersion') { $names | Should -Contain $f }
        $e.payloadVersion | Should -Be '1'
        $e.schemaVersion | Should -Be '5.3.0'
        $e.reason | Should -Be 'gateway unreachable'
    }
}

Describe 'One registry of states' {
    It 'every state the node-configuration code sends to the feed is registered' {
        $dir = Join-Path (Join-Path $PSScriptRoot '..\..') (Join-Path 'scripts' (Join-Path 'common' 'node-configuration'))
        $registry = @((Get-AzlOsConfigurationEventState).Values | ForEach-Object { $_ })
        $used = [System.Collections.Generic.List[object]]::new()
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.psm1') + @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..\..') 'scripts\deploy\04-cluster-deployment\phase-03-os-configuration') -Filter '*.ps1' -File)
        foreach ($f in $files) {
            foreach ($line in Get-Content -LiteralPath $f.FullName) {
                if ($line -match '(Send-Azl\w*Event|Write-AzlOsConfigurationEvent)\b.*?-State:?\s+''?(?<state>[A-Z][A-Za-z]+)''?') { $used.Add([pscustomobject]@{ File = $f.Name; State = $Matches['state'] }) }
            }
        }
        $used.Count | Should -BeGreaterThan 20
        foreach ($u in $used) { $registry | Should -Contain $u.State -Because "$($u.State) is sent from $($u.File)" }
    }
    It 'the states the guard sends outside the old contract are registered, and reach the feed file' {
        foreach ($s in 'StaleRunCommandDeleted', 'NodeRestarting', 'DomainJoined', 'DomainAdminsConfigured', 'NetworkChangeRepaired', 'NodeReconnecting') { Test-AzlOsConfigurationEventState -State $s | Should -BeTrue -Because $s }
        Test-AzlOsConfigurationEventState -State 'Made-Up' | Should -BeFalse
        Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot '..\..') 'scripts\common\node-configuration') 'AzlGuardedChange.psm1') -Force
        $file = Join-Path $TestDrive 'registry.jsonl'
        $ctx = New-AzlGuardEventContext -Path $file
        Send-AzlGuardEvent -Context $ctx -Node n1 -State StaleRunCommandDeleted -Step Transport -Evidence 'Deleted azl-osconfig-x'
        Send-AzlGuardEvent -Context $ctx -Node n1 -State NotInTheRegistry -Evidence 'stays in the sink'
        @(Read-FeedEvent $file).state | Should -Be @('StaleRunCommandDeleted')
        @($ctx.Sink).Count | Should -Be 2
    }
}

Describe 'Every line carries the run id and a sequence number' {
    It 'runId is the one given, seq counts 1, 2, 3 within a run and starts again at 1 for another run in the same file' {
        $file = Join-Path $TestDrive 'runs.jsonl'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node '*' -State RunStarted -RunId 'run-A'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n1' -State NodeStarted -RunId 'run-A'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node '*' -State RunCompleted -RunId 'run-A'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node '*' -State RunStarted -RunId 'run-B'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node '*' -State RunCompleted -RunId 'run-B'
        $e = Read-FeedEvent $file
        @($e | ForEach-Object { $_.runId }) | Should -Be @('run-A', 'run-A', 'run-A', 'run-B', 'run-B')
        @($e | ForEach-Object { $_.seq }) | Should -Be @(1, 2, 3, 1, 2)
        # an old RunCompleted is told from the new one by its run id
        @($e | Where-Object { $_.state -eq 'RunCompleted' } | ForEach-Object { $_.runId }) | Should -Be @('run-A', 'run-B')
    }
    It 'a writer that is given no run id uses the one of the process (AZL_OSCONFIG_RUN_ID), so every module of one run agrees' {
        $file = Join-Path $TestDrive 'env.jsonl'
        $old = $env:AZL_OSCONFIG_RUN_ID
        try {
            $env:AZL_OSCONFIG_RUN_ID = 'run-from-env'
            $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n' -State A
            $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n' -State B
        }
        finally { $env:AZL_OSCONFIG_RUN_ID = $old }
        $e = Read-FeedEvent $file
        @($e.runId | Select-Object -Unique) | Should -Be @('run-from-env')
        @($e.seq) | Should -Be @(1, 2)
    }
    It 'the guard adapter writes them too' {
        Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot '..\..') 'scripts\common\node-configuration') 'AzlGuardedChange.psm1') -Force
        $file = Join-Path $TestDrive 'guard-run.jsonl'
        $old = $env:AZL_OSCONFIG_RUN_ID
        try {
            $env:AZL_OSCONFIG_RUN_ID = 'run-G'
            $ctx = New-AzlGuardEventContext -Path $file
            Send-AzlGuardEvent -Context $ctx -Node n1 -State NetworkChangeStaged -Evidence 'x'
            Send-AzlGuardEvent -Context $ctx -Node n1 -State NetworkChangeCommitted -Evidence 'y'
        }
        finally { $env:AZL_OSCONFIG_RUN_ID = $old }
        $e = Read-FeedEvent $file
        @($e.runId) | Should -Be @('run-G', 'run-G')
        @($e.seq) | Should -Be @(1, 2)
    }
}

Describe 'Free text in the feed is redacted' {
    It '<Name>' -ForEach @(
        @{ Name = 'a password in a connection string'; Text = 'connect failed: Server=x;Password=Hunter2!;Port=1'; Secret = 'Hunter2' }
        @{ Name = 'password: value'; Text = 'the join said password: Sup3rS3cret for the account'; Secret = 'Sup3rS3cret' }
        @{ Name = 'a bearer token'; Text = 'sent Authorization: Bearer abcdef0123456789ABCDEF.ghi-jkl_mno to ARM'; Secret = 'abcdef0123456789ABCDEF' }
        @{ Name = 'a JWT'; Text = 'token eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlMTIzNDU2 was refused'; Secret = 'eyJhbGciOiJSUzI1NiJ9' }
        @{ Name = 'a SAS signature in a URL'; Text = 'GET https://x.blob.core.windows.net/c/f.zip?sv=2024-01-01&sig=AbCdEfGh%2Bij12345&se=2026'; Secret = 'AbCdEfGh' }
        @{ Name = 'a storage account key'; Text = 'AccountKey=QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=;EndpointSuffix=core.windows.net'; Secret = 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo' }
        @{ Name = 'a node result line'; Text = ('output: AZLRESULT:' + ('A1b2' * 60)); Secret = 'A1b2A1b2A1b2A1b2' }
        @{ Name = 'a private key'; Text = "-----BEGIN RSA PRIVATE KEY-----`nMIIEowIBAAKCAQEA1234`n-----END RSA PRIVATE KEY-----"; Secret = 'MIIEowIBAAKCAQEA1234' }
    ) {
        $file = Join-Path $TestDrive "redact-$([guid]::NewGuid().ToString('N').Substring(0, 6)).jsonl"
        $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n' -State StepFailed -Evidence $Text -NextAction $Text -Data @{ detail = $Text; list = @($Text); nested = @{ inner = $Text } }
        $raw = Get-Content -LiteralPath $file -Raw
        $raw | Should -Not -Match ([regex]::Escape($Secret))
        $raw | Should -Match '\*\*\*'
    }
    It 'leaves ordinary evidence alone' {
        $file = Join-Path $TestDrive 'plain.jsonl'
        $text = 'LocalAdmin: password differs; present, enabled, in Administrators, password from Key Vault. 192.0.2.11 on port 5985 (token window 10 minutes).'
        $null = Write-AzlOsConfigurationEvent -Path $file -Node 'n' -State StepPlanned -Evidence $text
        (Read-FeedEvent $file)[0].evidence | Should -Be $text
    }
}

Describe 'Get-AzlOsConfigurationStepOrder' {
    It 'is the 13 steps in display order, then the Arc registration' {
        (Get-AzlOsConfigurationStepOrder) -join ',' | Should -Be 'RemoteManagement,Network,Dns,Time,Hostname,UnusedAdapters,DomainJoin,LocalAdmin,Mpio,SanVerify,ClearStorage,Sbe,Drivers,ArcRegistration'
    }
}

Describe 'Get-AzlOsStepPlan' {
    BeforeAll {
        function Get-PlanItem($Step, $Item, $Current, $Desired, $Action, $Note = '') { [pscustomobject]@{ Step = $Step; Item = $Item; Current = $Current; Desired = $Desired; Action = $Action; Note = $Note } }
    }
    It 'Blocked beats Change beats Info beats Ok, and names the deciding items with current and desired' {
        $plan = @(
            (Get-PlanItem Network 'management' 'dhcp' 'static 192.0.2.11' Change),
            (Get-PlanItem Network 'port 2' 'ok' 'ok' Ok),
            (Get-PlanItem Dns 'DNS' '1.1.1.1' '1.1.1.1' Ok),
            (Get-PlanItem Mpio 'feature' 'Disabled' 'Enabled' Blocked 'Needs a restart.'),
            (Get-PlanItem SanVerify 'LUN' 'seen' 'seen' Skipped)
        )
        $s = @{}; foreach ($p in Get-AzlOsStepPlan -Plan $plan) { $s[$p.Step] = $p }
        $s.Network.Action | Should -Be 'Change'
        $s.Network.Evidence | Should -Be 'management: dhcp -> static 192.0.2.11'
        $s.Network.Current | Should -Be 'dhcp'
        $s.Network.Desired | Should -Be 'static 192.0.2.11'
        $s.Network.Count | Should -Be 2
        $s.Dns.Action | Should -Be 'Ok'
        $s.Mpio.Action | Should -Be 'Blocked'
        $s.Mpio.Evidence | Should -Match 'Needs a restart'
        $s.SanVerify.Action | Should -Be 'Info'
    }
    It 'shortens a step with many changed items' {
        $plan = 1..6 | ForEach-Object { Get-PlanItem Network "nic $_" 'a' 'b' Change }
        $p = Get-AzlOsStepPlan -Plan $plan
        $p.Evidence | Should -Match 'and 2 more$'
    }
    It 'an empty plan is an empty result' { @(Get-AzlOsStepPlan -Plan @()).Count | Should -Be 0 }
}

Describe 'ConvertFrom-AzlOsRetryWarning' {
    It 'reads the warning Invoke-AzlNodeScript writes before it tries a run command again' {
        $r = ConvertFrom-AzlOsRetryWarning -Message "node-01: the run command ended in state Unknown (try 2 of 3; the node's agent may have lost its connection). Trying again in 45 s."
        $r.Node | Should -Be 'node-01'
        $r.Try | Should -Be 2
        $r.Tries | Should -Be 3
        $r.WaitSeconds | Should -Be 45
    }
    It 'is $null for other text' {
        ConvertFrom-AzlOsRetryWarning -Message 'node-01: its Arc machine reports Disconnected.' | Should -BeNullOrEmpty
        ConvertFrom-AzlOsRetryWarning -Message '' | Should -BeNullOrEmpty
    }
    It 'reads what the real transport writes (the contract with AzlNodeTransport.psm1)' {
        $script:Calls = 0
        $json = '{"v":1,"ok":true}'
        $ms = [IO.MemoryStream]::new()
        $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
        $b = [Text.Encoding]::UTF8.GetBytes($json); $gz.Write($b, 0, $b.Length); $gz.Close()
        $good = 'AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray())
        $transport = [pscustomobject]@{
            Kind   = 'ArcRunCommand'
            Invoke = {
                param($t, $node, $script, $parameters, $secrets, $timeout)
                $null = $t, $node, $script, $parameters, $secrets, $timeout
                $script:Calls++
                if ($script:Calls -eq 1) { return [pscustomobject]@{ Output = ''; Failed = $true; State = 'Unknown'; Error = '' } }
                [pscustomobject]@{ Output = $good; Failed = $false; State = 'Succeeded'; Error = '' }
            }
        }
        Set-AzlNodeRetryPolicy -Tries 2 -DelaySeconds @(0) -Confirm:$false
        try {
            $messages = @(Invoke-AzlNodeScript -Transport $transport -Node 'node-01' -Script 'x' 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        }
        finally { Set-AzlNodeRetryPolicy -Tries 3 -DelaySeconds @(15, 45, 120) -Confirm:$false }
        $messages.Count | Should -Be 1
        $r = ConvertFrom-AzlOsRetryWarning -Message $messages[0]
        $r.Node | Should -Be 'node-01'
        $r.Try | Should -Be 1
        $r.Tries | Should -Be 2
        $r.WaitSeconds | Should -Be 0
    }
}

Describe 'Invoke-AzlSetNodeConfiguration and the retry events' {
    BeforeAll {
        Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "..") (Join-Path "scripts" "common")) (Join-Path "node-configuration" "AzlOsConfigurationRun.psm1")) -Force
        # Runs the real Invoke-AzlSetNodeConfiguration against a stand-in for the script. Returns its result.
        function Invoke-StandIn([string[]]$ScriptLine, [string]$ReportPath) {
            $standIn = Join-Path $TestDrive "standin-$([guid]::NewGuid().ToString('N').Substring(0, 6)).ps1"
            Set-Content -LiteralPath $standIn -Value $ScriptLine
            InModuleScope AzlOsConfigurationRun -Parameters @{ FakeScript = $standIn; Report = $ReportPath } {
                param($FakeScript, $Report)
                $old = $script:SetScript
                $script:SetScript = $FakeScript
                try { Invoke-AzlSetNodeConfiguration -Parameters @{ ReportPath = $Report } 3>$null }
                finally { $script:SetScript = $old }
            }
        }
    }
    It 'a stale report with an exit code 0 and no new report is a failure (exit 1), not a success' {
        $report = Join-Path $TestDrive 'stale.json'
        '{ "nodes": [ { "name": "iic-n01", "converged": true, "plan": [] } ] }' | Set-Content -LiteralPath $report
        $run = Invoke-StandIn @('param($ReportPath)', 'exit 0') $report
        $run.ExitCode | Should -Be 1
        $run.Report | Should -BeNullOrEmpty
        $run.Error | Should -Match 'no readable report'
        Test-Path -LiteralPath $report | Should -BeFalse
    }
    It 'a script that exits early without a report is a failure even when it says 0' {
        $run = Invoke-StandIn @('param($ReportPath)', 'exit 0') (Join-Path $TestDrive 'never-written.json')
        $run.ExitCode | Should -Be 1
    }
    It 'a script that writes its report is read as before' {
        $report = Join-Path $TestDrive 'fresh.json'
        $run = Invoke-StandIn @('param($ReportPath)', "'{ ""nodes"": [ { ""name"": ""iic-n01"" } ] }' | Set-Content -LiteralPath `$ReportPath", 'exit 0') $report
        $run.ExitCode | Should -Be 0
        $run.Report.nodes[0].name | Should -Be 'iic-n01'
    }
    It 'writes NodeRetry for the retry warning of the script while it runs, passes every warning on, drops the output, and keeps the exit code' {
        $script = Join-Path $TestDrive 'fake-set.ps1'
        $lines = @(
            'param($ReportPath)'
            'Write-Warning "iic-n01: the run command ended in state Unknown (try 1 of 3; the node''s agent may have lost its connection). Trying again in 15 s."'
            'Write-Warning ''something else'''
            '''output that is dropped'''
            'exit 3'
        )
        Set-Content -LiteralPath $script -Value $lines
        $feed = Join-Path $TestDrive 'retry.jsonl'
        $got = InModuleScope AzlOsConfigurationRun -Parameters @{ FakeScript = $script; Feed = $feed } {
            param($FakeScript, $Feed)
            $old = $script:SetScript
            $script:SetScript = $FakeScript
            try {
                $context = [pscustomobject]@{ EventLogPath = $Feed }
                $record = [ordered]@{ name = 'iic-n01'; method = 'Ztp'; transport = 'ArcRunCommand' }
                $out = @(Invoke-AzlSetNodeConfiguration -Parameters @{ ReportPath = 'none' } -EventContext $context -EventRecord $record -EventPhase Apply 3>&1)
                [pscustomobject]@{
                    Run      = @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
                    Warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
                }
            }
            finally { $script:SetScript = $old }
        }
        $got.Run.ExitCode | Should -Be 3
        $got.Warnings.Count | Should -Be 2
        $e = Read-FeedEvent $feed
        $e.Count | Should -Be 1
        $e[0].state | Should -Be 'NodeRetry'
        $e[0].node | Should -Be 'iic-n01'
        $e[0].try | Should -Be 1
        $e[0].tries | Should -Be 3
        $e[0].waitSeconds | Should -Be 15
        $e[0].phase | Should -Be 'Apply'
        $e[0].level | Should -Be 'Warning'
        $e[0].method | Should -Be 'Ztp'
    }
}
