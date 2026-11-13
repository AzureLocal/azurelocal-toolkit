#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The verification modules (scripts/common/arm-deployment/verification/AzlVerification.*.psm1): the engine loads them, merges their adapter
# defaults, runs each check with error isolation, and treats a module that cannot load as a failure. A fake module stands in for the real ones.

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

    function New-FakeModuleFolder([hashtable]$Files) {
        $dir = Join-Path $TestDrive ('ext-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-Item -ItemType Directory -Path $dir
        foreach ($name in $Files.Keys) { $Files[$name] | Set-Content -LiteralPath (Join-Path $dir $name) -Encoding utf8NoBOM }
        $dir
    }
    $script:GoodModule = @'
function Get-AzlVerificationAdapterDefault { @{ GetFakeFact = { 'real-fact' }; GetContext = { throw 'a module default must never replace a built-in adapter member' } } }
function Get-AzlVerificationCheckDefinition {
    @(
        @{ Id = 'FAKE-001'; Category = 'azure'; Title = 'A fake check that passes'; Source = 'https://learn.microsoft.com/fake?view=azloc-2610'; Blocking = $true
           Applies = { param($Context) $true }
           Run = { param($Context) @{ Status = 'Passed'; Node = '*'; Message = "fact: $(& $Context.Adapters.GetFakeFact) account: $((& $Context.Adapters.GetContext).Account) cluster: $($Context.Infrastructure.cluster.name)"; Remedy = ''; Evidence = 'seen by the fake' } } }
        @{ Id = 'FAKE-002'; Category = 'nodes'; Title = 'A fake check that fails per node'; Source = 'https://learn.microsoft.com/fake?view=azloc-2610'; Blocking = $true
           Applies = { param($Context) $true }
           Run = { param($Context) foreach ($n in $Context.Nodes) { @{ Status = 'Failed'; Node = [string]$n['name']; Message = 'broken'; Remedy = 'fix it'; Evidence = @('a', 'b') } } } }
        @{ Id = 'FAKE-003'; Category = 'network'; Title = 'A fake check that throws'; Source = 'x'; Blocking = $true; Applies = { param($Context) $true }; Run = { param($Context) throw 'the fake exploded' } }
        @{ Id = 'FAKE-004'; Category = 'storage'; Title = 'A fake check that does not apply'; Source = 'x'; Blocking = $true; Applies = { param($Context) $false }; Run = { param($Context) @{ Status = 'Failed'; Message = 'never run' } } }
        @{ Id = 'FAKE-005'; Category = 'identity'; Title = 'A fake check that is skipped'; Source = 'x'; Blocking = $true; Applies = { param($Context) 'only for another design' }; Run = { param($Context) @{ Status = 'Failed'; Message = 'never run' } } }
        @{ Id = 'FAKE-006'; Category = 'readiness'; Title = 'A fake check with a bad status'; Source = 'x'; Blocking = $false; Applies = { param($Context) $true }; Run = { param($Context) @{ Status = 'Maybe'; Message = 'unsure' } } }
    )
}
Export-ModuleMember -Function Get-AzlVerificationAdapterDefault, Get-AzlVerificationCheckDefinition
'@
}

Describe 'Loading verification modules' {
    It 'takes the definitions of every AzlVerification.*.psm1 in the folder, and only those files' {
        $dir = New-FakeModuleFolder @{ 'AzlVerification.Fake.psm1' = $script:GoodModule; 'Other.psm1' = 'throw "must not load"'; 'notes.txt' = 'x' }
        $e = Import-AzlPclExtension -Folder $dir
        @($e.Definitions | ForEach-Object { $_.Id }) | Should -Be @('FAKE-001', 'FAKE-002', 'FAKE-003', 'FAKE-004', 'FAKE-005', 'FAKE-006')
        $e.Modules.Count | Should -Be 1
        $e.Modules[0].Name | Should -Be 'AzlVerification.Fake'
        $e.Modules[0].Checks | Should -Be 6
        $e.AdapterDefaults.Keys | Should -Contain 'GetFakeFact'
    }
    It 'loads nothing from an empty folder, and a missing folder becomes one failing check (not a silent gap)' {
        $empty = Join-Path $TestDrive 'empty-ext'; $null = New-Item -ItemType Directory $empty
        (Import-AzlPclExtension -Folder $empty).Definitions.Count | Should -Be 0
        $missing = Import-AzlPclExtension -Folder (Join-Path $TestDrive 'nope')
        $missing.Definitions.Count | Should -Be 1
        $missing.Definitions[0].Id | Should -Be 'EXT-Folder'
    }
    It 'turns a module that does not load into a failing check, and reads one without definitions or adapters as a library' {
        $dir = New-FakeModuleFolder @{ 'AzlVerification.Broken.psm1' = 'throw "syntax of doom"'; 'AzlVerification.Empty.psm1' = 'function Foo { }; Export-ModuleMember -Function Foo' }
        $e = Import-AzlPclExtension -Folder $dir
        $e.Definitions.Count | Should -Be 1
        ($e.Modules | Where-Object { $_.Name -eq 'AzlVerification.Broken' }).Error | Should -Match 'syntax of doom'
        ($e.Modules | Where-Object { $_.Name -eq 'AzlVerification.Empty' }).Library | Should -BeTrue
        $r = Invoke-PclRun -ExtensionFolder $dir -Category readiness
        $c = Get-PclCheck $r 'EXT-Broken'
        $c.Status | Should -Be 'Failed'; $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'syntax of doom'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'turns a definition with a bad category or no Run into a failing check named after it' {
        $mod = 'function Get-AzlVerificationCheckDefinition { @(@{ Id = ''BAD-001''; Category = ''weather''; Title = ''t''; Run = { } }, @{ Id = ''BAD-002''; Category = ''azure''; Title = ''t'' }) }; Export-ModuleMember -Function Get-AzlVerificationCheckDefinition'
        $dir = New-FakeModuleFolder @{ 'AzlVerification.Bad.psm1' = $mod }
        $r = Invoke-PclRun -ExtensionFolder $dir -Category readiness
        (Get-PclCheck $r 'BAD-001').Message | Should -Match "category 'weather'"
        (Get-PclCheck $r 'BAD-002').Message | Should -Match 'Run is not a scriptblock'
    }
}

Describe 'Running the checks of a module' {
    BeforeAll {
        $script:Dir = New-FakeModuleFolder @{ 'AzlVerification.Fake.psm1' = $script:GoodModule }
        $script:Run = Invoke-PclRun -ExtensionFolder $script:Dir
    }
    It 'hands a $Context hashtable with Infrastructure, Handoff, OsReport, Settings and Adapters, and merges the module''s adapter defaults' {
        $c = Get-PclCheck $script:Run 'FAKE-001'
        $c.Status | Should -Be 'Passed'
        $c.Message | Should -Match 'fact: real-fact'
        $c.Message | Should -Match 'cluster: iic-clus01'
        $c.Message | Should -Match 'Evidence: seen by the fake'
    }
    It 'never lets a module''s default replace a member the engine or the caller already has (the module''s GetContext throws; the test''s answers)' {
        (Get-PclCheck $script:Run 'FAKE-001').Message | Should -Match 'account: tester@example.invalid'
    }
    It 'lets a test override an adapter member the module brings' {
        $r = Invoke-PclRun -ExtensionFolder $script:Dir -Override @{ GetFakeFact = { 'from the test' } }
        (Get-PclCheck $r 'FAKE-001').Message | Should -Match 'fact: from the test'
    }
    It 'reads per-node results of a module, with Evidence kept in full and as details' {
        $c = Get-PclCheck $script:Run 'FAKE-002' 'iic-n02'
        $c.Status | Should -Be 'Failed'; $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'Evidence: a; b'
        $c.Remedy | Should -Be 'fix it'
        $c.Details | Should -Contain 'a'
    }
    It 'isolates a check that throws: Failed with the exception text, the run goes on' {
        $c = Get-PclCheck $script:Run 'FAKE-003'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'the fake exploded'
        (Get-PclCheck $script:Run 'FAKE-001').Status | Should -Be 'Passed'
    }
    It 'reports NotApplicable for Applies that returns false or a reason, and Failed for an unknown status' {
        (Get-PclCheck $script:Run 'FAKE-004').Status | Should -Be 'NotApplicable'
        $c = Get-PclCheck $script:Run 'FAKE-005'
        $c.Status | Should -Be 'NotApplicable'; $c.Message | Should -Match 'only for another design'
        (Get-PclCheck $script:Run 'FAKE-006').Message | Should -Match "status 'Maybe'"
    }
    It 'puts the module checks in the feed and the report, and lists the module' {
        $events = Read-PclEvent $script:Run.EventPath
        @($events | Where-Object { $_.checkId -like 'FAKE-*' -and $_.type -eq 'Check' }).Count | Should -BeGreaterThan 6
        $report = Get-Content $script:Run.ReportPath -Raw | ConvertFrom-Json
        $report.modules[0].name | Should -Be 'AzlVerification.Fake'
        $report.categories.nodes.Failed | Should -BeGreaterThan 1
    }
    It 'lets a module check replace a built-in check of the same Id' {
        $mod = 'function Get-AzlVerificationCheckDefinition { @(@{ Id = ''ARM-001''; Category = ''azure''; Title = ''Replaced''; Source = ''x''; Applies = { param($Context) $true }; Run = { param($Context) @{ Status = ''Warning''; Message = ''the harvested version'' } } }) }; Export-ModuleMember -Function Get-AzlVerificationCheckDefinition'
        $dir = New-FakeModuleFolder @{ 'AzlVerification.Replace.psm1' = $mod }
        $r = Invoke-PclRun -ExtensionFolder $dir -Category azure
        $c = Get-PclCheck $r 'ARM-001'
        $c.Message | Should -Be 'the harvested version'
        $c.Title | Should -Be 'Replaced'
        @(Get-PclCheck $r 'ARM-001').Count | Should -Be 1
    }
    It 'lists the module checks in Mode Plan and accepts their ids in -AcceptSkipped' {
        $p = Invoke-PclRun -ExtensionFolder $script:Dir -Mode Plan
        @($p.Plan | Where-Object { $_.Id -like 'FAKE-*' }).Count | Should -Be 6
        ($p.Plan | Where-Object { $_.Id -eq 'FAKE-004' }).Applies | Should -BeFalse
        (Invoke-PclRun -ExtensionFolder $script:Dir -AcceptSkipped 'FAKE-001').ExitCode | Should -Not -Be 2
    }
}

Describe 'The default report directory' {
    It 'is arm-report\verification\live in the folder that holds the evidence folder (the environment data folder)' {
        $infra = @{ provisioning = @{ simplified = @{ evidence_path = 'D:\Data\azl-ztp\iic\evidence'; media_path = 'D:\Data\azl-ztp\iic\media' } } }
        Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\git\env\infrastructure.yml' -Infrastructure $infra | Should -Be 'D:\Data\azl-ztp\iic\arm-report\verification\live'
    }
    It 'falls back to the media folder, then to the folder of the file' {
        Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\git\env\infrastructure.yml' -Infrastructure @{ provisioning = @{ simplified = @{ media_path = 'E:\site\media' } } } | Should -Be 'E:\site\arm-report\verification\live'
        Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\git\env\infrastructure.yml' -Infrastructure @{} | Should -Be 'D:\git\env\arm-report\verification\live'
    }
    It 'is overridden by the setting' {
        Resolve-AzlPclReportDirectory -InfrastructureFile 'D:\git\env\infrastructure.yml' -Configured 'Z:\x' -Infrastructure @{ provisioning = @{ simplified = @{ evidence_path = 'D:\a\evidence' } } } | Should -Be 'Z:\x'
    }
}
