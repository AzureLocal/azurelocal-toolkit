#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The engine of the pre-cluster verification gate: modes, the catalog, the verdict, Skipped that blocks, -Fix, the feed and the report, the
# Environment Checker, the Remote.Invoke shim, the result contract with the ARM run (hash, expiry, the checks inside the report), secrets.
# The checks themselves come from a FAKE verification module; the real modules have their own tests (Verification.*.Tests.ps1).
# Fakes only: no Azure, no domain controller, no node.
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
    BeforeAll { $script:Catalog = Get-AzlPclCatalog }
    It 'is the built-in check plus the checks of the seven verification modules (the SB- checks of the SBE package are in the category nodes), in the six categories, with no failing module' {
        ($script:Catalog.Category | Select-Object -Unique | Sort-Object) | Should -Be @('azure', 'identity', 'network', 'nodes', 'readiness', 'storage')
        $script:Catalog.Count | Should -BeGreaterThan 80
        @($script:Catalog | Where-Object { $_.Id -like 'EXT-*' }) | Should -BeNullOrEmpty
        $script:Catalog.Id | Should -Contain 'ARM-001'
        foreach ($prefix in 'AZ-', 'ID-', 'ND-', 'NW-', 'ST-', 'RD-', 'SB-') { @($script:Catalog | Where-Object { $_.Id -like "$prefix*" }).Count | Should -BeGreaterThan 0 -Because $prefix }
    }
    It 'has a unique id, a title and a source for every check, and the Learn pages at view azloc-2610' {
        @($script:Catalog.Id | Select-Object -Unique).Count | Should -Be $script:Catalog.Count
        foreach ($check in $script:Catalog) { $check.Title | Should -Not -BeNullOrEmpty -Because $check.Id; $check.Source | Should -Not -BeNullOrEmpty -Because $check.Id }
        @($script:Catalog | Where-Object { $_.Source -match 'learn\.microsoft\.com' -and $_.Source -notmatch 'view=azloc-2610' }) | Should -BeNullOrEmpty
    }
    It 'marks only the resource provider check as fixable (-Fix is Azure side only)' {
        @($script:Catalog | Where-Object { $_.Fixable } | ForEach-Object { $_.Id }) | Should -Be @('AZ-004')
    }
}

Describe 'Mode Plan' {
    It 'is offline: lists the checks, writes plan files, calls nothing and writes no result for the ARM run' {
        $w = New-PclWorld
        $r = Invoke-PclRun -World $w -Mode Plan
        $r.ExitCode | Should -Be 0
        $r.Plan.Count | Should -BeGreaterThan 6
        $w.Calls.Count | Should -Be 0
        $dir = Join-Path (Split-Path $r.InfraFile -Parent) '..\live' | Resolve-Path
        Test-Path (Join-Path $dir 'plan.json') | Should -BeTrue
        Test-Path (Join-Path $dir 'plan.md') | Should -BeTrue
        Test-Path (Join-Path $dir 'report.json') | Should -BeFalse
        Test-Path (Join-Path $dir 'precluster-verification-events.jsonl') | Should -BeFalse
    }
    It 'does not replace the result of an earlier Verify' {
        $v = Invoke-PclRun -Dir (Join-Path $TestDrive 'keep')
        $v.Verdict | Should -Be 'Pass'
        $null = Invoke-PclRun -Mode Plan -Dir (Join-Path $TestDrive 'keep') -InfraFile $v.InfraFile
        (Test-AzlPclGateResult -InfrastructureFile $v.InfraFile -Directory (Split-Path $v.ReportPath) -Now $v.World.Clock.Time).Passed | Should -BeTrue
    }
}

Describe 'Mode Verify: a healthy environment' {
    BeforeAll { $script:Healthy = Invoke-PclRun }
    It 'passes with exit code 0 and writes the three files' {
        $script:Healthy.Verdict | Should -Be 'Pass'
        $script:Healthy.ExitCode | Should -Be 0
        $script:Healthy.Counts.Failed | Should -Be 0
        Test-Path $script:Healthy.ReportPath | Should -BeTrue
        Test-Path $script:Healthy.SummaryPath | Should -BeTrue
        Test-Path $script:Healthy.EventPath | Should -BeTrue
        (Split-Path $script:Healthy.EventPath -Leaf) | Should -Be 'precluster-verification-events.jsonl'
    }
    It 'runs the built-in ARM-001 and every check of the module, once' {
        (Get-PclCheck $script:Healthy 'ARM-001').Status | Should -Be 'Passed'
        foreach ($c in 'azure', 'identity', 'nodes', 'network', 'storage', 'readiness') { @(Get-PclCheck $script:Healthy "FK-$c").Count | Should -Be 1 }
    }
    It 'names the exact next command' {
        $script:Healthy.NextAction | Should -Match 'Invoke-AzureLocalArmDeployment\.ps1'
        $script:Healthy.NextAction | Should -Match '-Mode Validate'
    }
    It 'writes a report with the hash of the file, the expiry (4 hours by default), all the checks and the Environment Checker statement' {
        $report = Get-Content $script:Healthy.ReportPath -Raw | ConvertFrom-Json
        $report.schema | Should -Be 1
        $report.mode | Should -Be 'Verify'
        $report.partial | Should -BeFalse
        $report.verdict | Should -Be 'Pass'
        $report.fileHash | Should -Be (Get-AzlPclFileHash -Path $script:Healthy.InfraFile)
        ([datetime]$report.expiresUtc - [datetime]$report.completedUtc).TotalHours | Should -Be 4
        @($report.checks).Count | Should -Be $script:Healthy.Checks.Count
        foreach ($p in 'checkId', 'category', 'title', 'status', 'node', 'message', 'remedy', 'source', 'blocking', 'accepted') { $report.checks[0].PSObject.Properties.Name | Should -Contain $p }
        $report.environmentChecker.requested | Should -BeFalse
        $report.environmentChecker.note | Should -Match 'did not install'
        $report.modules[0].name | Should -Be 'AzlVerification.Fake'
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
        $script:Lines.Count | Should -BeGreaterThan 6
    }
    It 'starts with RunStarted, ends with RunCompleted and has a Check line for every result' {
        $script:Events[0].type | Should -Be 'RunStarted'
        $script:Events[-1].type | Should -Be 'RunCompleted'
        @($script:Events | Where-Object { $_.type -eq 'Check' }).Count | Should -Be $script:Fed.Checks.Count
    }
    It 'carries the contract fields on every line, numbered 1, 2, 3 ... and stamped in UTC ISO' {
        foreach ($e in $script:Events) {
            foreach ($p in 'schema', 'runId', 'seq', 'ts', 'type', 'checkId', 'category', 'title', 'status', 'node', 'message', 'remedy', 'source', 'blocking') { $e.PSObject.Properties.Name | Should -Contain $p -Because "$($e.type) $p" }
            $e.runId | Should -Be $script:Fed.RunId
            $e.blocking | Should -BeOfType [bool]
        }
        for ($i = 0; $i -lt $script:Events.Count; $i++) { $script:Events[$i].seq | Should -Be ($i + 1) }
        $script:Lines[0] | Should -Match '"ts":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"'
    }
    It 'adds verdict, counts, fileHash and expiresUtc to RunCompleted only' {
        $done = $script:Events[-1]
        $done.verdict | Should -Be 'Pass'
        $done.fileHash | Should -Be (Get-AzlPclFileHash -Path $script:Fed.InfraFile)
        $done.expiresUtc | Should -Not -BeNullOrEmpty
        $script:Events[0].PSObject.Properties.Name | Should -Not -Contain 'counts'
    }
    It 'starts a fresh feed for every run and takes the previous report out of the way' {
        $dir = Join-Path $TestDrive 'twice'
        $first = Invoke-PclRun -Dir $dir
        $second = Invoke-PclRun -Dir $dir -InfraFile $first.InfraFile -Infra $first.Infra
        @(Read-PclEvent $second.EventPath | Where-Object { $_.runId -ne $second.RunId }).Count | Should -Be 0
        Test-Path (Join-Path (Split-Path $second.ReportPath) 'report.previous.json') | Should -BeTrue
    }
}

Describe 'The verdict' {
    It 'is Fail with exit code 1 when a blocking check fails, and says which and what to run' {
        $w = New-PclWorld; $w.Status['nodes'] = 'Failed'
        $r = Invoke-PclRun -World $w
        $r.Verdict | Should -Be 'Fail'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'FK-nodes'
        $r.NextAction | Should -Match 'fix the nodes thing'
        $events = Read-PclEvent $r.EventPath
        ($events | Where-Object { $_.checkId -eq 'FK-nodes' }).blocking | Should -BeTrue
        $events[-1].verdict | Should -Be 'Fail'
    }
    It 'is not blocked by a Warning' {
        $w = New-PclWorld; $w.Status['network'] = 'Warning'
        $r = Invoke-PclRun -World $w
        (Get-PclCheck $r 'FK-network').Status | Should -Be 'Warning'
        $r.Verdict | Should -Be 'Pass'
    }
    It 'turns a check that throws into Failed with the message, never into a pass, and runs the others' {
        $w = New-PclWorld; $w.Status['identity'] = 'Throw'
        $r = Invoke-PclRun -World $w
        $c = Get-PclCheck $r 'FK-identity'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'the fake exploded'
        (Get-PclCheck $r 'FK-storage').Status | Should -Be 'Passed'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'never truncates a failure message' {
        $w = New-PclWorld; $w.Status['azure'] = 'Failed'; $w.Message['azure'] = 'x' * 6000
        $r = Invoke-PclRun -World $w
        (Get-PclCheck $r 'FK-azure').Message | Should -Match ('x{6000}')
        (Read-PclEvent $r.EventPath | Where-Object { $_.checkId -eq 'FK-azure' }).message.Length | Should -BeGreaterThan 6000
    }
}

Describe 'A Skipped check blocks unless the operator accepts it' {
    It 'is Skipped, blocking and a Fail when nothing accepts it' {
        $w = New-PclWorld; $w.Status['readiness'] = 'Skipped'
        $r = Invoke-PclRun -World $w
        $c = Get-PclCheck $r 'FK-readiness'
        $c.Status | Should -Be 'Skipped'; $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'Skipped checks block the verdict'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'passes once the id is accepted, and records that it was the operator' {
        $w = New-PclWorld; $w.Status['readiness'] = 'Skipped'
        $r = Invoke-PclRun -World $w -AcceptSkipped 'FK-readiness'
        $r.Verdict | Should -Be 'Pass'
        $c = Get-PclCheck $r 'FK-readiness'
        $c.Blocking | Should -BeFalse; $c.Accepted | Should -BeTrue
        $c.Message | Should -Match 'ACCEPTED by the operator with -AcceptSkipped FK-readiness'
        (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).acceptedSkipped | Should -Contain 'FK-readiness'
        (Get-Content $r.SummaryPath -Raw) | Should -Match 'Accepted as Skipped by the operator'
    }
    It 'does not let an accepted id excuse a Failed check' {
        $w = New-PclWorld; $w.Status['readiness'] = 'Failed'
        $r = Invoke-PclRun -World $w -AcceptSkipped 'FK-readiness'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'refuses an id that is not a check (exit code 2) and takes ids comma-separated or as a list, in any case' {
        $r = Invoke-PclRun -AcceptSkipped 'AD-CHECK'
        $r.ExitCode | Should -Be 2; $r.Message | Should -Match 'not a check id'
        $w = New-PclWorld; $w.Status['readiness'] = 'Skipped'; $w.Status['storage'] = 'Skipped'
        (Invoke-PclRun -World $w -AcceptSkipped 'fk-readiness,FK-storage').Verdict | Should -Be 'Pass'
        (Invoke-PclRun -World $w -AcceptSkipped 'fk-readiness', 'fk-storage').Verdict | Should -Be 'Pass'
    }
}

Describe '-Fix registers resource providers and nothing else' {
    It 'changes nothing by default: the missing provider stays missing and the check Fails' {
        $w = New-PclWorld; $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'
        $r = Invoke-PclRun -World $w
        (Get-PclCheck $r 'AZ-004').Status | Should -Be 'Failed'
        $w.Registered.Count | Should -Be 0
        $r.Verdict | Should -Be 'Fail'
    }
    It 'with -Fix registers it, reports Fixed, and the verdict is Pass' {
        $w = New-PclWorld; $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'
        $r = Invoke-PclRun -World $w -Fix
        (Get-PclCheck $r 'AZ-004').Status | Should -Be 'Fixed'
        $w.Registered | Should -Contain 'Microsoft.KeyVault'
        $r.Verdict | Should -Be 'Pass'
        (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).fixesApplied | Should -BeTrue
    }
    It 'with -Fix still Fails, saying why, when the registration is not allowed' {
        $w = New-PclWorld; $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'; $w.RegisterFails = @('Microsoft.KeyVault')
        $r = Invoke-PclRun -World $w -Fix
        (Get-PclCheck $r 'AZ-004').Status | Should -Be 'Failed'
        (Get-PclCheck $r 'AZ-004').Message | Should -Match 'Registering Microsoft.KeyVault failed'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'does not fix anything in Mode Plan' {
        $w = New-PclWorld; $w.Providers['Microsoft.KeyVault'] = 'NotRegistered'
        $null = Invoke-PclRun -World $w -Fix -Mode Plan
        $w.Registered.Count | Should -Be 0
    }
}

Describe 'Partial runs and bad input' {
    It 'marks a run of fewer than all categories as partial, exits 3 even when nothing fails, and says so in the summary' {
        $r = Invoke-PclRun -Category azure
        $report = Get-Content $r.ReportPath -Raw | ConvertFrom-Json
        $report.partial | Should -BeTrue
        @($report.checks | ForEach-Object { $_.category } | Select-Object -Unique) | Should -Be @('azure')
        $r.ExitCode | Should -Be 3
        (Get-Content $r.SummaryPath -Raw) | Should -Match 'Partial run'
    }
    It 'refuses an unknown category and a missing file (exit code 2)' {
        (Invoke-PclRun -Category storagex).ExitCode | Should -Be 2
        $r = Invoke-AzlPreClusterVerification -InfrastructureFile (Join-Path $TestDrive 'nope.yml') -Mode Verify
        $r.ExitCode | Should -Be 2; $r.Message | Should -Match 'not found'
    }
    It 'needs the file (not only an object) in Mode Verify, because the result is tied to its hash' {
        $infra = Get-PclInfra
        $r = Invoke-AzlPreClusterVerification -Infrastructure $infra -Mode Verify -Adapter (New-PclAdapter -World (New-PclWorld) -Infra $infra) -ExtensionFolder (New-PclModuleFolder)
        $r.ExitCode | Should -Be 2; $r.Message | Should -Match 'SHA-256'
    }
    It 'refuses to read a bypass key from the settings file' {
        $cfg = Join-Path $TestDrive 'cfg.json'
        '{ "skipPreClusterVerification": true }' | Set-Content $cfg
        { Get-AzlArmRunSetting -Infrastructure @{} -SettingsFile $cfg } | Should -Throw '*explicit switch*'
    }
}

Describe 'A run that fails after it started still ends its feed and leaves no report (review C5)' {
    It 'writes RunCompleted with the verdict Error, no report.json and no summary.md when the summary cannot be made' {
        Mock -ModuleName AzlPreClusterVerification Format-AzlPclSummary { throw 'disk full' }
        $r = Invoke-PclRun
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'disk full'
        Test-Path (Join-Path (Split-Path $r.EventPath) 'report.json') | Should -BeFalse
        Test-Path (Join-Path (Split-Path $r.EventPath) 'summary.md') | Should -BeFalse
        $events = Read-PclEvent $r.EventPath
        $events[-1].type | Should -Be 'RunCompleted'
        $events[-1].verdict | Should -Be 'Error'
        $events[-1].message | Should -Match 'disk full'
    }
    It 'writes summary.md before report.json, so a Pass report implies a summary' {
        $r = Invoke-PclRun
        (Get-Item $r.SummaryPath).LastWriteTimeUtc | Should -BeLessOrEqual (Get-Item $r.ReportPath).LastWriteTimeUtc
        Get-ChildItem (Split-Path $r.ReportPath) -Filter '*.tmp' | Should -BeNullOrEmpty
    }
    It 'refuses a file that changed while the checks ran' {
        $w = New-PclWorld
        $infra = Get-PclInfra
        $file = Write-PclInfraFile -Infra $infra -Directory (Join-Path $TestDrive 'moving')
        $mod = (Get-PclFakeModuleText).Replace("`$status = if (`$w.Status.ContainsKey('azure'))", "Add-Content -LiteralPath '$file' -Value '# edited during the run'; `$status = if (`$w.Status.ContainsKey('azure'))")
        $dir = New-PclModuleFolder -Files @{ 'AzlVerification.Fake.psm1' = $mod }
        $r = Invoke-PclRun -World $w -Infra $infra -InfraFile $file -ExtensionFolder $dir
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'changed while the checks ran'
        Test-Path $r.ReportPath | Should -BeFalse
    }
}

Describe 'A module that is missing is a failure, not a gap (review C9)' {
    It 'fails when the folder of the modules does not exist' {
        $r = Invoke-PclRun -ExtensionFolder (Join-Path $TestDrive 'no-such-folder')
        $r.Verdict | Should -Be 'Fail'
        (Get-PclCheck $r 'EXT-Folder').Status | Should -Be 'Failed'
    }
    It 'fails for an expected module that is not in the folder' {
        $e = Import-AzlPclExtension -Folder (New-PclModuleFolder) -Expected 'AzlVerification.Gone'
        ($e.Definitions | Where-Object { $_.Id -eq 'EXT-Gone' }) | Should -Not -BeNullOrEmpty
        ($e.Modules | Where-Object { $_.Name -eq 'AzlVerification.Gone' }).Error | Should -Match 'missing'
    }
    It 'fails the second module that defines an id a module already defines, and keeps the first' {
        $one = New-PclModuleFolder -Files @{ 'AzlVerification.A.psm1' = (Get-PclFakeModuleText); 'AzlVerification.B.psm1' = (Get-PclFakeModuleText) }
        $r = Invoke-PclRun -ExtensionFolder $one
        @($r.Checks | Where-Object { $_.Id -like 'EXT-*Duplicate*' }).Count | Should -BeGreaterThan 0
        $r.Verdict | Should -Be 'Fail'
        @(Get-PclCheck $r 'FK-azure').Count | Should -Be 1
    }
    It 'treats a module that exports neither function as a library, not as a failure' {
        $dir = New-PclModuleFolder -Files @{ 'AzlVerification.Fake.psm1' = (Get-PclFakeModuleText); 'AzlVerification.Lib.psm1' = 'function Get-LibThing { 1 }; Export-ModuleMember -Function Get-LibThing' }
        $e = Import-AzlPclExtension -Folder $dir
        ($e.Modules | Where-Object { $_.Name -eq 'AzlVerification.Lib' }).Library | Should -BeTrue
        ($e.Modules | Where-Object { $_.Name -eq 'AzlVerification.Lib' }).Error | Should -BeNullOrEmpty
        @($e.Definitions | Where-Object { $_.Id -like 'EXT-*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Remote.Invoke serves both forms the modules use' {
    BeforeAll {
        $script:RemoteMod = @'
function Get-AzlVerificationCheckDefinition {
    @(
        @{ Id = 'RM-001'; Category = 'nodes'; Title = 'node form'; Source = 'x'; Run = { param($Context) $o = & $Context.Adapters['Remote']['Invoke'] 'iic-n01' { 'raw-output' } @('a'); @{ Status = 'Passed'; Message = "got $o" } } }
        @{ Id = 'RM-002'; Category = 'network'; Title = 'request form'; Source = 'x'; Run = { param($Context) $r = & $Context.Adapters['Remote']['Invoke'] ([pscustomobject]@{ Node = 'iic-n01'; Addresses = @('192.0.2.11'); Credential = $null; ScriptBlock = { 'x' }; ArgumentList = @(); UseSsl = $false; Authentication = 'Negotiate' }); @{ Status = 'Passed'; Message = "ok=$($r.Ok) address=$($r.Address) result=$($r.Result)" } } }
        @{ Id = 'RM-003'; Category = 'storage'; Title = 'node form fails'; Source = 'x'; Run = { param($Context) & $Context.Adapters['Remote']['Invoke'] 'iic-n02' { 'x' }; @{ Status = 'Passed'; Message = 'must not get here' } } }
    )
}
Export-ModuleMember -Function Get-AzlVerificationCheckDefinition
'@
    }
    It 'takes (node, scriptblock, arguments) and returns what the script block output; the request form returns Ok, Address, Result' {
        Mock -ModuleName AzlPreClusterVerification Invoke-AzlPclRemote {
            if ($Request.Node -eq 'iic-n02') { return [pscustomobject]@{ Ok = $false; Address = ''; Result = $null; Error = 'boom with Sup3r-S3cret-Value!'; AuthFailed = $false } }
            [pscustomobject]@{ Ok = $true; Address = [string]@($Request.Addresses)[0]; Result = 'raw-output'; Error = ''; AuthFailed = $false }
        }
        $dir = New-PclModuleFolder -Files @{ 'AzlVerification.Remote.psm1' = $script:RemoteMod }
        $r = Invoke-PclRun -ExtensionFolder $dir
        (Get-PclCheck $r 'RM-001').Message | Should -Match 'got raw-output'
        (Get-PclCheck $r 'RM-002').Message | Should -Match 'ok=True'
        (Get-PclCheck $r 'RM-002').Message | Should -Match 'result=raw-output'
        $c = Get-PclCheck $r 'RM-003'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'The call to iic-n02 failed'
        $c.Message | Should -Not -Match 'Sup3r-S3cret-Value'
    }
    It 'leaves a Remote.Invoke the caller brought alone' {
        $w = New-PclWorld
        $dir = New-PclModuleFolder -Files @{ 'AzlVerification.Remote.psm1' = $script:RemoteMod }
        $r = Invoke-PclRun -World $w -ExtensionFolder $dir -Override @{ Remote = @{ Invoke = { param($Node, $Script, $Arguments) "from the test for $Node" } } }
        (Get-PclCheck $r 'RM-001').Message | Should -Match 'from the test for iic-n01'
    }
}

Describe 'The Environment Checker (remove it again, and say so)' {
    It 'is not touched by default: no call to a node, and the report says so' {
        $w = New-PclWorld
        $r = Invoke-PclRun -World $w -Override @{ Remote = @{ Invoke = (New-PclRemoteFake -World $w) } }
        $w.RemoteCalls.Count | Should -Be 0
        (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).environmentChecker.requested | Should -BeFalse
    }
    It 'with -InstallEnvironmentChecker installs it on every node and removes it again at the end, and the report states both' {
        $w = New-PclWorld
        $r = Invoke-PclRun -World $w -InstallEnvironmentChecker -Override @{ Remote = @{ Invoke = (New-PclRemoteFake -World $w) } }
        @($w.RemoteCalls | Where-Object Kind -EQ 'Install').Count | Should -Be 2
        @($w.RemoteCalls | Where-Object Kind -EQ 'Remove').Count | Should -Be 2
        $w.RemoteCalls[-1].Kind | Should -Be 'Remove'
        $ec = (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).environmentChecker
        $ec.requested | Should -BeTrue
        @($ec.installedOn).Count | Should -Be 2
        @($ec.removedFrom).Count | Should -Be 2
        $ec.note | Should -Match 'REMOVED'
        (Get-Content $r.SummaryPath -Raw) | Should -Match 'Environment Checker on the nodes'
    }
    It 'removes it even when the run Fails' {
        $w = New-PclWorld; $w.Status['nodes'] = 'Failed'
        $null = Invoke-PclRun -World $w -InstallEnvironmentChecker -Override @{ Remote = @{ Invoke = (New-PclRemoteFake -World $w) } }
        @($w.RemoteCalls | Where-Object Kind -EQ 'Remove').Count | Should -Be 2
    }
    It 'with -KeepEnvironmentChecker leaves it on the nodes and the report says it is kept' {
        $w = New-PclWorld
        $r = Invoke-PclRun -World $w -InstallEnvironmentChecker -KeepEnvironmentChecker -Override @{ Remote = @{ Invoke = (New-PclRemoteFake -World $w) } }
        @($w.RemoteCalls | Where-Object Kind -EQ 'Remove').Count | Should -Be 0
        (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).environmentChecker.note | Should -Match 'KEPT'
    }
    It 'reports a node it could not clean, instead of saying removed' {
        $w = New-PclWorld; $w.EcRemoveFails = @('iic-n02')
        $r = Invoke-PclRun -World $w -InstallEnvironmentChecker -Override @{ Remote = @{ Invoke = (New-PclRemoteFake -World $w) } }
        $ec = (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).environmentChecker
        @($ec.errors).Count | Should -BeGreaterThan 0
        $ec.note | Should -Match 'removing it failed'
    }
}

Describe 'Secrets' {
    It 'never writes a secret value into the report, the summary or the feed' {
        Mock -ModuleName AzlPreClusterVerification Invoke-AzlPclRemote { [pscustomobject]@{ Ok = $false; Address = ''; Result = $null; Error = 'WinRM said no to Zz9!qwertyuiop-SECRET-local'; AuthFailed = $true } }
        $w = New-PclWorld
        $w.Secrets['keyvault://kv-iic-mgmt-01/local-admin-password'] = 'Zz9!qwertyuiop-SECRET-local'
        $mod = "function Get-AzlVerificationCheckDefinition { @(@{ Id = 'SC-001'; Category = 'nodes'; Title = 'secret'; Source = 'x'; Run = { param(`$Context) & `$Context.Adapters['Remote']['Invoke'] 'iic-n01' { 'x' } @() } }) }; Export-ModuleMember -Function Get-AzlVerificationCheckDefinition"
        $r = Invoke-PclRun -World $w -ExtensionFolder (New-PclModuleFolder -Files @{ 'AzlVerification.Sc.psm1' = $mod })
        $r.Verdict | Should -Be 'Fail'
        foreach ($path in $r.ReportPath, $r.SummaryPath, $r.EventPath) {
            if (Test-Path $path) { (Get-Content $path -Raw) | Should -Not -Match 'SECRET-local' }
        }
        (Get-PclCheck $r 'SC-001').Message | Should -Match '\*\*\*'
    }
}

Describe 'The result contract with the ARM run' {
    BeforeAll {
        $script:Run = Invoke-PclRun
        $script:Dir = Split-Path $script:Run.ReportPath
        $script:Now = $script:Run.World.Clock.Time
        $script:Tamper = {
            param([scriptblock]$Edit, [switch]$NoSummary)
            $d = Join-Path $TestDrive ('t-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $null = New-Item -ItemType Directory $d
            $j = Get-Content $script:Run.ReportPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            & $Edit $j
            $j | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $d 'report.json')
            if (-not $NoSummary) { 'summary' | Set-Content (Join-Path $d 'summary.md') }
            $d
        }
    }
    It 'accepts a Pass for the same file, not expired, not partial' {
        $t = Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $script:Dir -Now $script:Now.AddHours(1)
        $t.Passed | Should -BeTrue
        $t.Reason | Should -Match 'valid until'
    }
    It 'refuses a result that expired, and one older than the ARM run allows (review C6)' {
        $t = Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $script:Dir -Now $script:Now.AddHours(5)
        $t.Passed | Should -BeFalse; $t.Reason | Should -Match 'expired'; $t.Command | Should -Match '-Mode Verify'
        $old = Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $script:Dir -Now $script:Now.AddHours(2) -MaxAgeHours 1
        $old.Passed | Should -BeFalse; $old.Reason | Should -Match 'allows a result to be 1 hour'
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $script:Dir -Now $script:Now.AddMinutes(30) -MaxAgeHours 1).Passed | Should -BeTrue
    }
    It 'refuses a result dated in the future and an expiry far beyond 168 hours (review C6)' {
        $d = & $script:Tamper { param($j) $j.completedUtc = $script:Now.AddHours(3).ToString('o') }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $d -Now $script:Now).Reason | Should -Match 'in the future'
        $d2 = & $script:Tamper { param($j) $j.expiresUtc = $script:Now.AddDays(400).ToString('o') }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $d2 -Now $script:Now.AddHours(1)).Reason | Should -Match 'more than 168 hours'
    }
    It 'reads the dates the same whatever kind of DateTime ConvertFrom-Json made of them (review C11)' {
        $utc = [datetime]::Parse('2026-11-08T12:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        (ConvertTo-AzlPclUtc $utc).Ticks | Should -Be $utc.Ticks
        (ConvertTo-AzlPclUtc $utc.ToLocalTime()).Ticks | Should -Be $utc.Ticks
        (ConvertTo-AzlPclUtc ([datetime]::SpecifyKind($utc, [DateTimeKind]::Unspecified))).Ticks | Should -Be $utc.Ticks
        (ConvertTo-AzlPclUtc '2026-11-08T12:00:00.0000000Z').Ticks | Should -Be $utc.Ticks
        (ConvertTo-AzlPclUtc '2026-11-08T14:00:00+02:00').Ticks | Should -Be $utc.Ticks
        ConvertTo-AzlPclUtc 'not a date' | Should -BeNullOrEmpty
    }
    It 'refuses a result for a file that changed, and one whose file changed while it was parsed (review C12)' {
        $copy = Join-Path $TestDrive 'changed.yml'
        Copy-Item $script:Run.InfraFile $copy
        Add-Content $copy "`n# an edit"
        $t = Test-AzlPclGateResult -InfrastructureFile $copy -Directory $script:Dir -Now $script:Now
        $t.Passed | Should -BeFalse; $t.Reason | Should -Match 'changed since the verification'
        $t2 = Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $script:Dir -Now $script:Now -ExpectedFileHash ('0' * 64)
        $t2.Passed | Should -BeFalse; $t2.Reason | Should -Match 'changed while it was being read'
    }
    It 'refuses a Fail, a partial run, a Plan, a missing result and a missing summary.md (review C5)' {
        $w = New-PclWorld; $w.Status['azure'] = 'Failed'
        $bad = Invoke-PclRun -World $w
        $reason = (Test-AzlPclGateResult -InfrastructureFile $bad.InfraFile -Directory (Split-Path $bad.ReportPath) -Now $bad.World.Clock.Time).Reason
        $reason | Should -Match 'verdict Fail'; $reason | Should -Match 'FK-azure'
        $part = Invoke-PclRun -Category azure
        (Test-AzlPclGateResult -InfrastructureFile $part.InfraFile -Directory (Split-Path $part.ReportPath) -Now $part.World.Clock.Time).Reason | Should -Match 'only some categories'
        $empty = Join-Path $TestDrive 'empty'; $null = New-Item -ItemType Directory $empty
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $empty).Reason | Should -Match 'no result'
        $plan = & $script:Tamper { param($j) $j.mode = 'Plan' }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $plan -Now $script:Now).Reason | Should -Match 'only a Verify run counts'
        $noSummary = & $script:Tamper { param($j) } -NoSummary
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $noSummary -Now $script:Now).Reason | Should -Match 'summary.md'
    }
    It 'does not take the verdict on trust: checks inside a Pass must agree (review C8)' {
        $none = & $script:Tamper { param($j) $j.checks = @() }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $none -Now $script:Now).Reason | Should -Match 'lists no check'
        $failed = & $script:Tamper { param($j) $j.checks[0].status = 'Failed' }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $failed -Now $script:Now).Reason | Should -Match 'Failed or blocking'
        $blocking = & $script:Tamper { param($j) $j.checks[1].blocking = $true }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $blocking -Now $script:Now).Passed | Should -BeFalse
        $skip = & $script:Tamper { param($j) $j.checks[1].status = 'Skipped'; $j.checks[1].accepted = $false }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $skip -Now $script:Now).Reason | Should -Match 'not accepted'
        $cats = & $script:Tamper { param($j) $j.categories.Remove('storage') }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $cats -Now $script:Now).Reason | Should -Match 'storage'
        $noRun = & $script:Tamper { param($j) $j.Remove('runId') }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $noRun -Now $script:Now).Passed | Should -BeFalse
        $partialNull = & $script:Tamper { param($j) $j.partial = $null }
        (Test-AzlPclGateResult -InfrastructureFile $script:Run.InfraFile -Directory $partialNull -Now $script:Now).Passed | Should -BeFalse
    }
    It 'shows the accepted skips in the reason and in AcceptedSkipped (review C7)' {
        $w = New-PclWorld; $w.Status['readiness'] = 'Skipped'
        $r = Invoke-PclRun -World $w -AcceptSkipped 'FK-readiness'
        $t = Test-AzlPclGateResult -InfrastructureFile $r.InfraFile -Directory (Split-Path $r.ReportPath) -Now $r.World.Clock.Time
        $t.Passed | Should -BeTrue
        $t.AcceptedSkipped | Should -Contain 'FK-readiness'
        $t.Reason | Should -Match 'accepted by the operator with -AcceptSkipped: FK-readiness'
    }
    It 'defaults the directory to arm-report\verification\live next to the file' {
        (Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\Data\site\infrastructure.yml') | Should -Be 'D:\Data\site\arm-report\verification\live'
        (Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\Data\site\infrastructure.yml' -Configured 'E:\x') | Should -Be 'E:\x'
    }
}

Describe 'The readiness adapter gets the local administrator credential the engine already uses (lab: RD-004 and RD-005 Skipped)' {
    It 'fills Adapters.Readiness.Credential (.\user) and the address map when the module brings none, and never writes the password' {
        $mod = @'
function Get-AzlVerificationAdapterDefault { @{ Readiness = @{ Run = { 'x' }; Credential = $null; Address = @{} } } }
function Get-AzlVerificationCheckDefinition {
    @(@{ Id = 'RC-001'; Category = 'readiness'; Title = 'readiness credential'; Source = 'x'; Run = { param($Context)
        $r = $Context.Adapters['Readiness']
        @{ Status = 'Passed'; Message = "user=$($r.Credential.UserName) addresses=$(@($r.Address.Keys).Count) first=$($r.Address['iic-n01'])" } } })
}
Export-ModuleMember -Function Get-AzlVerificationAdapterDefault, Get-AzlVerificationCheckDefinition
'@
        $w = New-PclWorld
        $infra = Get-PclInfra
        $r = Invoke-PclRun -World $w -Infra $infra -ExtensionFolder (New-PclModuleFolder -Files @{ 'AzlVerification.Rc.psm1' = $mod })
        $c = Get-PclCheck $r 'RC-001'
        $c.Status | Should -Be 'Passed'
        $c.Message | Should -BeLike ('user=.\' + [string]$infra.identity.local_admin.username + '*')
        $c.Message | Should -Match 'addresses=2'
        (Get-Content $r.ReportPath -Raw) | Should -Not -Match 'Sup3r-S3cret'
    }
    It 'leaves a credential the module or the caller brought alone' {
        $mod = @'
function Get-AzlVerificationAdapterDefault { @{ Readiness = @{ Run = { 'x' }; Credential = ([pscredential]::new('own\admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))); Address = @{} } } }
function Get-AzlVerificationCheckDefinition {
    @(@{ Id = 'RC-002'; Category = 'readiness'; Title = 'own credential'; Source = 'x'; Run = { param($Context) @{ Status = 'Passed'; Message = "user=$($Context.Adapters['Readiness'].Credential.UserName)" } } })
}
Export-ModuleMember -Function Get-AzlVerificationAdapterDefault, Get-AzlVerificationCheckDefinition
'@
        $r = Invoke-PclRun -ExtensionFolder (New-PclModuleFolder -Files @{ 'AzlVerification.Rc.psm1' = $mod })
        (Get-PclCheck $r 'RC-002').Message | Should -Be 'user=own\admin'
    }
}

Describe 'The switch port checklist in report.json and summary.md' {
    It 'is taken from a module that offers Get-AzlVerificationSwitchPortChecklist and written to both files' {
        $mod = @'
function Get-AzlVerificationCheckDefinition { @(@{ Id = 'SW-001'; Category = 'network'; Title = 'sw'; Source = 'x'; Run = { param($Context) @{ Status = 'Passed'; Message = 'ok' } } }) }
function Get-AzlVerificationSwitchPortChecklist { param($Context) [pscustomobject]@{ switch = 'tor-a'; port = 'Ethernet1/11'; node = 'iic-n01'; filePort = 'Slot 3 Port 1'; mac = 'AA:BB:CC:00:00:01'; roles = 'management+compute'; expectedMode = 'trunk'; expectedVlans = @(711, 717); hostTag = 711; source = 'port vlan_id 711; allowed_vlans 717' } }
Export-ModuleMember -Function Get-AzlVerificationCheckDefinition, Get-AzlVerificationSwitchPortChecklist
'@
        $r = Invoke-PclRun -ExtensionFolder (New-PclModuleFolder -Files @{ 'AzlVerification.Sw.psm1' = $mod })
        $report = Get-Content $r.ReportPath -Raw | ConvertFrom-Json
        @($report.switchPortChecklist).Count | Should -Be 1
        $report.switchPortChecklist[0].switch | Should -Be 'tor-a'
        @($report.switchPortChecklist[0].expectedVlans) | Should -Be @(711, 717)
        $summary = Get-Content $r.SummaryPath -Raw
        $summary | Should -Match 'Switch port checklist'
        $summary | Should -Match '\| tor-a \| Ethernet1/11 \| iic-n01 \| Slot 3 Port 1 \| AA:BB:CC:00:00:01 \| trunk \| 711, 717 \| 711 \|'
    }
    It 'is an empty list, and no table, when no module offers one' {
        $r = Invoke-PclRun
        @((Get-Content $r.ReportPath -Raw | ConvertFrom-Json).switchPortChecklist).Count | Should -Be 0
        (Get-Content $r.SummaryPath -Raw) | Should -Not -Match 'Switch port checklist'
    }
}
