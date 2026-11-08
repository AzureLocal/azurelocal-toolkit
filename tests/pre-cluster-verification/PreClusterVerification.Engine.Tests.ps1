#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The engine of the pre-cluster verification gate: modes, the catalog, the verdict, Skipped that blocks, the feed and the report, the
# result contract with the ARM run (hash, expiry), secrets. Fakes only: no Azure, no domain controller, no node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pre-cluster-verification

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapter members and mock script blocks keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    foreach ($m in 'infrastructure\AzlInfrastructure.psm1', 'azure-local\AzlAzure.psm1', 'arm-deployment\AzlArmDeployment.psm1', 'arm-deployment\AzlArmDeploymentRun.psm1', 'arm-deployment\AzlPreClusterGate.psm1', 'arm-deployment\AzlPreClusterVerification.psm1') {
        Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Force
    }
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'PreClusterVerification.Helpers.ps1'))
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
}

Describe 'The catalog' {
    It 'has the six categories and a source, a title and a reads text for every check' {
        $c = Get-AzlPclCatalog
        ($c.Category | Select-Object -Unique | Sort-Object) | Should -Be @('azure', 'identity', 'network', 'nodes', 'readiness', 'storage')
        foreach ($check in $c) {
            $check.Id | Should -Match '^(AZR|IDN|NOD|NET|STO|RDY)-\d{3}$'
            $check.Title | Should -Not -BeNullOrEmpty
            $check.Reads | Should -Not -BeNullOrEmpty
            $check.Source | Should -Match '^(https://(learn\.microsoft\.com|azurelocal\.cloud)/|config/)' -Because $check.Id
        }
        @($c.Id | Select-Object -Unique).Count | Should -Be $c.Count
    }
    It 'takes the Learn pages at view azloc-2610' {
        $learn = @(Get-AzlPclCatalog | Where-Object { $_.Source -match 'learn\.microsoft\.com' })
        $learn.Count | Should -BeGreaterThan 60
        @($learn | Where-Object { $_.Source -notmatch 'view=azloc-2610' }).Count | Should -Be 0
    }
    It 'covers each thing Azure ever returned in this project' {
        $titles = (Get-AzlPclCatalog | ForEach-Object { "$($_.Id) $($_.Title) $($_.Source)" }) -join "`n"
        foreach ($needle in 'resource providers', 'RDMA matches the intent', 'SAN the file declares', 'dedicated OU exists', 'Signed in to the tenant', 'zombie', 'already-exists', 'arc-device-id-name', 'unvalidated-solution-sbe-combination', 'Environment Checker') {
            $titles | Should -Match ([regex]::Escape($needle)) -Because $needle
        }
    }
    It 'marks only the register providers check as fixable (-Fix is Azure side only)' {
        @(Get-AzlPclCatalog | Where-Object { $_.Fixable } | ForEach-Object { $_.Id }) | Should -Be @('AZR-004')
    }
}

Describe 'Mode Plan' {
    It 'is offline: lists the checks, writes plan files, asks nothing of Azure, AD or a node and writes no result for the ARM run' {
        $w = New-PclWorld
        $infra = Get-PclInfra
        $r = Invoke-PclRun -World $w -Infra $infra -Mode Plan
        $r.ExitCode | Should -Be 0
        $r.Plan.Count | Should -Be (Get-AzlPclCatalog).Count
        $w.Calls.Count | Should -Be 0
        $w.NodeReads.Count | Should -Be 0
        $w.LdapCalls.Count | Should -Be 0
        $dir = Join-Path (Split-Path $r.InfraFile -Parent) '..\live' | Resolve-Path
        Test-Path (Join-Path $dir 'plan.json') | Should -BeTrue
        Test-Path (Join-Path $dir 'plan.md') | Should -BeTrue
        Test-Path (Join-Path $dir 'report.json') | Should -BeFalse
        Test-Path (Join-Path $dir 'precluster-verification-events.jsonl') | Should -BeFalse
    }
    It 'says which checks do not apply to this file and why' {
        $r = Invoke-PclRun -Mode Plan
        ($r.Plan | Where-Object { $_.Id -eq 'IDN-020' }).Applies | Should -BeFalse
        ($r.Plan | Where-Object { $_.Id -eq 'IDN-020' }).Reason | Should -Match 'active_directory'
        ($r.Plan | Where-Object { $_.Id -eq 'IDN-003' }).Applies | Should -BeTrue
        ($r.Plan | Where-Object { $_.Id -eq 'STO-006' }).Applies | Should -BeFalse
    }
    It 'does not replace the result of an earlier Verify' {
        $infra = Get-PclInfra
        $v = Invoke-PclRun -Infra $infra -Dir (Join-Path $TestDrive 'keep')
        $v.Verdict | Should -Be 'Pass'
        $p = Invoke-PclRun -Infra $infra -Mode Plan -Dir (Join-Path $TestDrive 'keep') -InfraFile $v.InfraFile
        (Test-Path (Join-Path (Split-Path $v.ReportPath) 'report.json')) | Should -BeTrue
        (Test-AzlPclGateResult -InfrastructureFile $v.InfraFile -Directory (Split-Path $v.ReportPath) -Now $v.World.Clock.Time).Passed | Should -BeTrue
        $p.Mode | Should -Be 'Plan'
    }
}

Describe 'Mode Verify: a healthy environment' {
    BeforeAll {
        $script:Healthy = Invoke-PclRun
    }
    It 'passes with exit code 0 and writes the three files' {
        $script:Healthy.Verdict | Should -Be 'Pass'
        $script:Healthy.ExitCode | Should -Be 0
        $script:Healthy.Counts.Failed | Should -Be 0
        $script:Healthy.Counts.Skipped | Should -Be 0
        Test-Path $script:Healthy.ReportPath | Should -BeTrue
        Test-Path $script:Healthy.SummaryPath | Should -BeTrue
        Test-Path $script:Healthy.EventPath | Should -BeTrue
        (Split-Path $script:Healthy.EventPath -Leaf) | Should -Be 'precluster-verification-events.jsonl'
    }
    It 'gives every check of the catalog at least one result' {
        $ids = @($script:Healthy.Checks | ForEach-Object { $_.Id } | Select-Object -Unique)
        @(Get-AzlPclCatalog | Where-Object { $_.Id -notin $ids }) | Should -BeNullOrEmpty
    }
    It 'names the exact next command' {
        $script:Healthy.NextAction | Should -Match 'Invoke-AzureLocalArmDeployment\.ps1'
        $script:Healthy.NextAction | Should -Match '-Mode Validate'
    }
    It 'writes a report with the hash of the file, the expiry (4 hours by default) and all the checks' {
        $report = Get-Content $script:Healthy.ReportPath -Raw | ConvertFrom-Json
        $report.schema | Should -Be 1
        $report.mode | Should -Be 'Verify'
        $report.partial | Should -BeFalse
        $report.verdict | Should -Be 'Pass'
        $report.fileHash | Should -Be (Get-AzlPclFileHash -Path $script:Healthy.InfraFile)
        ([datetime]$report.expiresUtc - [datetime]$report.completedUtc).TotalHours | Should -Be 4
        $report.maxAgeHours | Should -Be 4
        @($report.checks).Count | Should -Be $script:Healthy.Checks.Count
        $first = $report.checks[0]
        foreach ($p in 'checkId', 'category', 'title', 'status', 'node', 'message', 'remedy', 'source', 'blocking') { $first.PSObject.Properties.Name | Should -Contain $p }
    }
    It 'honours the maximum age setting' {
        $r = Invoke-PclRun -Settings @{ preClusterVerificationMaxAgeHours = 9 }
        $report = Get-Content $r.ReportPath -Raw | ConvertFrom-Json
        ([datetime]$report.expiresUtc - [datetime]$report.completedUtc).TotalHours | Should -Be 9
    }
}

Describe 'The event feed' {
    BeforeAll {
        $script:Fed = Invoke-PclRun
        $script:Lines = @(Get-Content -LiteralPath $script:Fed.EventPath)
        $script:Events = @($script:Lines | ForEach-Object { $_ | ConvertFrom-Json })
    }
    It 'is one single-line JSON object per line' {
        foreach ($line in $script:Lines) { $line | Should -Not -Match "[\r\n]"; { $line | ConvertFrom-Json } | Should -Not -Throw }
        $script:Lines.Count | Should -BeGreaterThan 80
    }
    It 'starts with RunStarted, ends with RunCompleted and has a Check line for every result' {
        $script:Events[0].type | Should -Be 'RunStarted'
        $script:Events[-1].type | Should -Be 'RunCompleted'
        @($script:Events | Where-Object { $_.type -eq 'Check' }).Count | Should -Be $script:Fed.Checks.Count
        @($script:Events | Where-Object { $_.type -eq 'RunStarted' }).Count | Should -Be 1
        @($script:Events | Where-Object { $_.type -eq 'RunCompleted' }).Count | Should -Be 1
    }
    It 'carries the contract fields on every line' {
        foreach ($e in $script:Events) {
            foreach ($p in 'schema', 'runId', 'seq', 'ts', 'type', 'checkId', 'category', 'title', 'status', 'node', 'message', 'remedy', 'source', 'blocking') { $e.PSObject.Properties.Name | Should -Contain $p -Because "$($e.type) $($e.checkId) lacks $p" }
            $e.schema | Should -Be 1
            $e.runId | Should -Be $script:Fed.RunId
            $e.blocking | Should -BeOfType [bool]
        }
    }
    It 'numbers the lines 1, 2, 3 ... and stamps them in UTC ISO' {
        for ($i = 0; $i -lt $script:Events.Count; $i++) { $script:Events[$i].seq | Should -Be ($i + 1) }
        $script:Lines[0] | Should -Match '"ts":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"'
    }
    It 'uses the six categories in lower case and the six statuses' {
        $checks = @($script:Events | Where-Object { $_.type -eq 'Check' })
        @($checks.category | Select-Object -Unique | Sort-Object) | Should -Be @('azure', 'identity', 'network', 'nodes', 'readiness', 'storage')
        foreach ($s in $checks.status) { $s | Should -BeIn 'Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable', 'Fixed' }
    }
    It 'adds verdict, counts, fileHash and expiresUtc to RunCompleted only' {
        $done = $script:Events[-1]
        $done.verdict | Should -Be 'Pass'
        $done.fileHash | Should -Be (Get-AzlPclFileHash -Path $script:Fed.InfraFile)
        $done.expiresUtc | Should -Not -BeNullOrEmpty
        $done.counts.Passed | Should -BeGreaterThan 50
        foreach ($p in 'counts') { $script:Events[0].PSObject.Properties.Name | Should -Not -Contain $p }
    }
    It 'starts a fresh feed for every run and takes the previous report out of the way while it runs' {
        $dir = Join-Path $TestDrive 'twice'
        $infra = Get-PclInfra
        $first = Invoke-PclRun -Infra $infra -Dir $dir
        $second = Invoke-PclRun -Infra $infra -Dir $dir -InfraFile $first.InfraFile
        $events = Read-PclEvent $second.EventPath
        @($events | Where-Object { $_.runId -ne $second.RunId }).Count | Should -Be 0
        Test-Path (Join-Path (Split-Path $second.ReportPath) 'report.previous.json') | Should -BeTrue
    }
}

Describe 'The verdict' {
    It 'is Fail with exit code 1 when a blocking check fails, and says which and what to run' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'
        $r = Invoke-PclRun -World $w -Infra $infra
        $r.Verdict | Should -Be 'Fail'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'AZR-004'
        $r.NextAction | Should -Match 'Register-AzResourceProvider -ProviderNamespace Microsoft.KeyVault'
        $events = Read-PclEvent $r.EventPath
        ($events | Where-Object { $_.checkId -eq 'AZR-004' }).blocking | Should -BeTrue
        $events[-1].verdict | Should -Be 'Fail'
    }
    It 'is not blocked by a Warning' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.reboot.files = $true }
        $r = Invoke-PclRun -World $w -Infra $infra
        (Get-PclCheck $r 'NOD-008' 'iic-n01').Status | Should -Be 'Warning'
        $r.Verdict | Should -Be 'Pass'
    }
    It 'turns a check that throws into Failed with the message, never into a pass' {
        $r = Invoke-PclRun -Override @{ GetResourceGroup = { throw 'HTTP 503 from ARM' } }
        $c = Get-PclCheck $r 'AZR-003'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'could not run'
        $c.Message | Should -Match 'HTTP 503 from ARM'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'never truncates a failure message' {
        $long = 'x' * 6000
        $r = Invoke-PclRun -Override @{ GetResourceGroup = { throw $long } }
        (Get-PclCheck $r 'AZR-003').Message | Should -Match ('x{6000}')
        $ev = Read-PclEvent $r.EventPath | Where-Object { $_.checkId -eq 'AZR-003' }
        $ev.message.Length | Should -BeGreaterThan 6000
    }
}

Describe 'A Skipped check blocks unless the operator accepts it' {
    It 'is Skipped, blocking and a Fail when the adapter cannot ask (the old silent AD skip)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $r = Invoke-PclRun -World $w -Infra $infra -Override @{ LdapSearch = $null }
        foreach ($id in 'IDN-002', 'IDN-003', 'IDN-004') {
            $c = Get-PclCheck $r $id
            $c.Status | Should -Be 'Skipped'
            $c.Blocking | Should -BeTrue
            $c.Message | Should -Match 'Skipped checks block the verdict'
        }
        $r.Verdict | Should -Be 'Fail'
        $r.ExitCode | Should -Be 1
    }
    It 'passes once those ids are accepted, and records that it was the operator' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $skipped = 'IDN-002', 'IDN-003', 'IDN-004', 'IDN-005', 'IDN-006', 'IDN-010', 'IDN-012'
        $r = Invoke-PclRun -World $w -Infra $infra -Override @{ LdapSearch = $null } -AcceptSkipped $skipped
        $r.Verdict | Should -Be 'Pass'
        $c = Get-PclCheck $r 'IDN-003'
        $c.Status | Should -Be 'Skipped'
        $c.Blocking | Should -BeFalse
        $c.Accepted | Should -BeTrue
        $c.Message | Should -Match 'ACCEPTED by the operator with -AcceptSkipped IDN-003'
        $report = Get-Content $r.ReportPath -Raw | ConvertFrom-Json
        $report.acceptedSkipped | Should -Contain 'IDN-003'
        (Get-Content $r.SummaryPath -Raw) | Should -Match 'Accepted as Skipped by the operator'
    }
    It 'does not let an accepted id excuse a Failed check' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Providers['Microsoft.Insights'] = 'NotRegistered'
        $r = Invoke-PclRun -World $w -Infra $infra -AcceptSkipped 'AZR-004'
        (Get-PclCheck $r 'AZR-004').Status | Should -Be 'Failed'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'refuses an id that is not a check (exit code 2)' {
        $r = Invoke-PclRun -AcceptSkipped 'AD-CHECK'
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'not a check id'
    }
    It 'takes the ids comma-separated or as a list, in any case' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $r = Invoke-PclRun -World $w -Infra $infra -Override @{ LdapSearch = $null } -AcceptSkipped 'idn-002,IDN-003', 'IDN-004,IDN-005,IDN-006,IDN-010,IDN-012'
        $r.Verdict | Should -Be 'Pass'
    }
}

Describe 'Partial runs and bad input' {
    It 'marks a run of fewer than all categories as partial, in the report and the summary' {
        $r = Invoke-PclRun -Category azure
        $report = Get-Content $r.ReportPath -Raw | ConvertFrom-Json
        $report.partial | Should -BeTrue
        @($report.checks | ForEach-Object { $_.category } | Select-Object -Unique) | Should -Be @('azure')
        (Get-Content $r.SummaryPath -Raw) | Should -Match 'Partial run'
    }
    It 'refuses an unknown category and a missing file (exit code 2)' {
        (Invoke-PclRun -Category storagex -ErrorAction SilentlyContinue).ExitCode | Should -Be 2
        $r = Invoke-AzlPreClusterVerification -InfrastructureFile (Join-Path $TestDrive 'nope.yml') -Mode Verify
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'not found'
    }
    It 'needs the file (not only an object) in Mode Verify, because the result is tied to its hash' {
        $infra = Get-PclInfra
        $r = Invoke-AzlPreClusterVerification -Infrastructure $infra -Mode Verify -Adapter (New-PclAdapter -World (New-PclWorld) -Infra $infra)
        $r.ExitCode | Should -Be 2
        $r.Message | Should -Match 'SHA-256'
    }
    It 'refuses to read a bypass key from the settings file' {
        $cfg = Join-Path $TestDrive 'cfg.json'
        '{ "skipPreClusterVerification": true }' | Set-Content $cfg
        { Get-AzlArmRunSetting -Infrastructure @{} -ConfigPath $cfg } | Should -Throw '*explicit switch*'
    }
}

Describe 'Secrets' {
    It 'never writes a secret value into the report, the summary or the feed' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'
        $w.Secrets['keyvault://kv-iic-mgmt-01/local-admin-password'] = 'Zz9!qwertyuiop-SECRET-local'
        $w.Secrets['keyvault://kv-iic-mgmt-01/lcm-password'] = 'Yy8!asdfghjkl-SECRET-lcm'
        $r = Invoke-PclRun -World $w -Infra $infra -Override @{ ReadNode = { param($Request) throw "WinRM said no to Zz9!qwertyuiop-SECRET-local" } }
        $r.Verdict | Should -Be 'Fail'
        foreach ($path in $r.ReportPath, $r.SummaryPath, $r.EventPath) {
            $text = Get-Content $path -Raw
            $text | Should -Not -Match 'SECRET-local'
            $text | Should -Not -Match 'SECRET-lcm'
        }
        (Get-Content $r.ReportPath -Raw) | Should -Match '\*\*\*'
        $w.Calls | Should -Contain 'GetSecret:keyvault://kv-iic-mgmt-01/local-admin-password'
    }
}

Describe 'The result contract with the ARM run' {
    BeforeAll {
        $script:Run = Invoke-PclRun
        $script:Dir = Split-Path $script:Run.ReportPath
        $script:Now = $script:Run.World.Clock.Time
    }
    It 'accepts a Pass for the same file, not expired, not partial' {
        $t = Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $script:Dir -Now $script:Now.AddHours(1)
        $t.Passed | Should -BeTrue
        $t.Reason | Should -Match 'valid until'
    }
    It 'refuses a result that expired' {
        $t = Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $script:Dir -Now $script:Now.AddHours(5)
        $t.Passed | Should -BeFalse
        $t.Reason | Should -Match 'expired'
        $t.Command | Should -Match '-Mode Verify'
    }
    It 'refuses a result for a file that changed (the hash no longer matches)' {
        $copy = Join-Path $TestDrive 'changed.yml'
        Copy-Item $script:Run.InfraFile $copy
        Add-Content $copy "`n# an edit"
        $t = Test-AzlPclGateResult -InfrastructureFile $copy -Directory $script:Dir -Now $script:Now
        $t.Passed | Should -BeFalse
        $t.Reason | Should -Match 'changed since the verification'
    }
    It 'refuses a Fail, a partial run, a Plan and a missing result' {
        $bad = Invoke-PclRun -Override @{ GetResourceGroup = { $null } }
        (Test-AzlPclGateResult -InfrastructureFile $bad.InfraFile -Directory (Split-Path $bad.ReportPath) -Now $bad.World.Clock.Time).Reason | Should -Match 'verdict Fail'
        $part = Invoke-PclRun -Category azure
        (Test-AzlPclGateResult -InfrastructureFile $part.InfraFile -Directory (Split-Path $part.ReportPath) -Now $part.World.Clock.Time).Reason | Should -Match 'only some categories'
        $empty = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory $empty
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $empty).Reason | Should -Match 'no result'
        $tamper = Join-Path $TestDrive 'tamper'
        $null = New-Item -ItemType Directory $tamper
        $j = Get-Content $script:Run.ReportPath -Raw | ConvertFrom-Json; $j.mode = 'Plan'
        $j | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $tamper 'report.json')
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $tamper -Now $script:Now).Reason | Should -Match "only a Verify run counts"
    }
    It 'defaults the directory to arm-report\verification\live next to the file' {
        (Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\Data\site\infrastructure.yml') | Should -Be 'D:\Data\site\arm-report\verification\live'
        (Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\Data\site\infrastructure.yml' -Configured 'E:\x') | Should -Be 'E:\x'
    }
}
