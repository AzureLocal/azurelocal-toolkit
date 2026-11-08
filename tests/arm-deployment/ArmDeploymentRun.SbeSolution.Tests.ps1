#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The precondition SbeValidatedWithSolution: the SBE the deployment will use must be validated, in the OEM's SBE discovery
# catalog, with the solution version the nodes run. The real failure behind it: Validate ran 13 minutes and failed at step 0.60
# (InvokeEnvironmentChecker) with ErrorUnvalidatedSolutionAndSbeCombination, because SBE 5.0.2606.1616 is not validated with
# Solution 12.2610.1004.50. The fixture is an excerpt of Dell's public catalog (SBE_Discovery_Dell.xml, 2026-10-21), unchanged
# apart from the entries left out. No download, no Azure call, no node.

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    $script:Catalog = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'sbe', 'SBE_Discovery_Dell.excerpt.xml')
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    $script:TemplateFile = Join-Path $TestDrive 'template.json'
    '{ "parameters": {}, "resources": [] }' | Set-Content -LiteralPath $script:TemplateFile
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
    function Get-Pre($Result, [string]$Name) { @($Result.Preconditions | Where-Object { $_.name -eq $Name }) }
    function Get-SbeInfra {
        param([string]$Version = '5.0.2606.1616', [string]$Family = '16G-45n0c-Intel', [string]$BundlePath)
        $infra = Get-TestInfra
        $sbe = [ordered]@{ publisher = 'Dell'; family = $Family; version = $Version; manifest_source = 'https://example.invalid/SBE_Discovery_Dell.xml'; manifest_creation_date = '2026-10-21T20:27:08Z' }
        if ($BundlePath) { $sbe.bundle_path = $BundlePath }
        $infra.hardware = [ordered]@{ vendor = 'Dell'; sbe = $sbe }
        $infra
    }
    function Get-BuildWorld([string]$OsVersion) {
        $w = Get-FakeWorld
        foreach ($n in 'iic-n01', 'iic-n02') {
            $w.Nodes[$n] = [pscustomobject]@{ Name = $n; ResourceId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-azl-01/providers/Microsoft.HybridCompute/machines/$n"; Status = 'Connected'; OsVersion = $OsVersion; ComputerName = $n }
        }
        $w
    }
}

Describe 'Read-AzlArmSbeCatalog' {
    It 'reads every ApplicableUpdate with its version, family, name and the Solution patterns of RequiredPackages' {
        $c = @(Read-AzlArmSbeCatalog -Path $script:Catalog)
        $c.Count | Should -Be 5
        $new = $c | Where-Object { $_.Version -eq '5.0.2609.1611' -and $_.Family -eq '16G-45n0c-Intel' }
        $new.Name | Should -Be 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611'
        @($new.SolutionPatterns.Pattern) | Should -Be @('12.*.1004.*', '12.*.1003.*')
        $old = $c | Where-Object { $_.Version -eq '5.0.2606.1616' }
        @($old.SolutionPatterns.Pattern) | Should -Be @('12.*.1003.*', '12.*.1002.*')
        @($old.SolutionPatterns)[1].MinVersionRequired | Should -Be '12.2603.1002.502'
    }
    It 'does not list SBE or other package types as Solution patterns' {
        $c = @(Read-AzlArmSbeCatalog -Path $script:Catalog)
        foreach ($e in $c) { foreach ($p in $e.SolutionPatterns) { $p.Pattern | Should -Match '^\d+\.' } }
    }
    It 'refuses a file that is not an SBE discovery manifest, and a missing file' {
        $bad = Join-Path $TestDrive 'bad.xml'
        '<other/>' | Set-Content -LiteralPath $bad
        { Read-AzlArmSbeCatalog -Path $bad } | Should -Throw '*SBEUpdatesManifest*'
        { Read-AzlArmSbeCatalog -Path (Join-Path $TestDrive 'nope.xml') } | Should -Throw '*not found*'
    }
    It 'does not resolve a DTD (no entity expansion)' {
        $evil = Join-Path $TestDrive 'evil.xml'
        '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "boom">]><SBEUpdatesManifest/>' | Set-Content -LiteralPath $evil
        { Read-AzlArmSbeCatalog -Path $evil } | Should -Throw
    }
}

Describe 'Test-AzlArmSolutionVersionMatch (wildcards)' {
    It '<Pattern> against <Version> is <Expected>' -ForEach @(
        @{ Pattern = '12.*.1004.*'; Version = '12.2610.1004.50'; Expected = $true }
        @{ Pattern = '12.*.1003.*'; Version = '12.2610.1004.50'; Expected = $false }
        @{ Pattern = '12.*.1003.*'; Version = '12.2609.1003.12'; Expected = $true }
        @{ Pattern = '12.*.1004.*'; Version = '12.2610.11004.50'; Expected = $false }
        @{ Pattern = '12.2610.*'; Version = '12.2610.1004.50'; Expected = $true }
        @{ Pattern = '12.2610.1004.50'; Version = '12.2610.1004.50'; Expected = $true }
        @{ Pattern = '12.2610.1004.50'; Version = '12.2610.1004.5'; Expected = $false }
        @{ Pattern = '13.*.1004.*'; Version = '12.2610.1004.50'; Expected = $false }
        @{ Pattern = '12.*.1004.*'; Version = '112.2610.1004.50'; Expected = $false }
    ) {
        Test-AzlArmSolutionVersionMatch -Pattern $Pattern -Version $Version | Should -Be $Expected
    }
    It 'honours MinVersionRequired for a complete version' {
        Test-AzlArmSolutionVersionMatch -Pattern '12.*.1002.*' -Version '12.2603.1002.501' -MinVersionRequired '12.2603.1002.502' | Should -BeFalse
        Test-AzlArmSolutionVersionMatch -Pattern '12.*.1002.*' -Version '12.2603.1002.502' -MinVersionRequired '12.2603.1002.502' | Should -BeTrue
        Test-AzlArmSolutionVersionMatch -Pattern '12.*.1002.*' -Version '12.2605.1002.10' -MinVersionRequired '12.2603.1002.502' | Should -BeTrue
    }
    It 'cannot prove a minimum for a derived (three-part) version, so the pattern alone decides' {
        Test-AzlArmSolutionVersionMatch -Pattern '12.*.1002.*' -Version '12.2603.1002' -MinVersionRequired '12.2603.1002.502' | Should -BeTrue
    }
}

Describe 'ConvertFrom-AzlArmOsBuild (solution version from the OS build)' {
    It 'maps the build the lab runs (10.0.26100.33650) to the 12.2610.1004 line, and says it is derived' {
        $s = ConvertFrom-AzlArmOsBuild -OsBuild '10.0.26100.33650'
        $s.Version | Should -Be '12.2610.1004'
        $s.Derived | Should -BeTrue
        $s.Note | Should -Match 'derived'
    }
    It 'returns nothing for a build that does not map unambiguously' -ForEach @(
        @{ Build = '10.0.26100.32230' }, @{ Build = '10.0.25398.1' }, @{ Build = '' }, @{ Build = 'not a build' }
    ) {
        ConvertFrom-AzlArmOsBuild -OsBuild $Build | Should -BeNullOrEmpty
    }
}

Describe 'Test-AzlArmSbeSolution (pure)' {
    BeforeAll { $script:Entries = @(Read-AzlArmSbeCatalog -Path $script:Catalog) }
    It 'the real failure: 5.0.2606.1616 with Solution 12.2610.1004.50 is not validated and the validated versions of the family are listed' {
        $r = Test-AzlArmSbeSolution -Catalog $script:Entries -Family '16G-45n0c-Intel' -Version '5.0.2606.1616' -Solution '12.2610.1004.50'
        $r.Status | Should -Be 'NotValidated'
        $r.Patterns | Should -Be @('12.*.1003.*', '12.*.1002.*')
        $r.ValidatedVersions | Should -Be @('5.0.2609.1611')
    }
    It '5.0.2609.1611 with Solution 12.2610.1004.50 is validated' {
        (Test-AzlArmSbeSolution -Catalog $script:Entries -Family '16G-45n0c-Intel' -Version '5.0.2609.1611' -Solution '12.2610.1004.50').Status | Should -Be 'Validated'
    }
    It 'a Solution on the 1003 line validates the older SBE too; one nobody validated lists nothing' {
        $r = Test-AzlArmSbeSolution -Catalog $script:Entries -Family '16G-45n0c-Intel' -Version '5.0.2606.1616' -Solution '12.2609.1003.9'
        $r.Status | Should -Be 'Validated'
        $r2 = Test-AzlArmSbeSolution -Catalog $script:Entries -Family '16G-45n0c-Intel' -Version '5.0.2609.1611' -Solution '12.2701.1009.1'
        $r2.Status | Should -Be 'NotValidated'
        $r2.ValidatedVersions | Should -BeNullOrEmpty
        $r2.ValidatedElsewhere | Should -BeNullOrEmpty
    }
    It 'an SBE the catalog does not list is NotListed' {
        (Test-AzlArmSbeSolution -Catalog $script:Entries -Family '16G-45n0c-Intel' -Version '5.0.2601.1' -Solution '12.2610.1004.50').Status | Should -Be 'NotListed'
        (Test-AzlArmSbeSolution -Catalog $script:Entries -Family 'AX-99G' -Version '5.0.2609.1611' -Solution '12.2610.1004.50').Status | Should -Be 'NotListed'
    }
    It 'matches the family without regard to case' {
        (Test-AzlArmSbeSolution -Catalog $script:Entries -Family '16g-45N0C-intel' -Version '5.0.2609.1611' -Solution '12.2610.1004.50').Status | Should -Be 'Validated'
    }
    It 'when no SBE of the family is validated, the validated SBEs of the other families are named' {
        $old = [pscustomobject]@{ Name = 'SBE_Example_AX-OLD_4.0.0.1'; Version = '4.0.0.1'; Family = 'AX-OLD'; SolutionPatterns = @([pscustomobject]@{ Pattern = '12.*.1001.*'; MinVersionRequired = '' }) }
        $r = Test-AzlArmSbeSolution -Catalog (@($script:Entries) + $old) -Family 'AX-OLD' -Version '4.0.0.1' -Solution '12.2610.1004.50'
        $r.Status | Should -Be 'NotValidated'
        $r.ValidatedVersions | Should -BeNullOrEmpty
        $r.ValidatedElsewhere | Should -Be @('SBE_Dell_17G-Intel_5.0.2609.1715', 'SBE_Dell_16G-45n0c-Intel_5.0.2609.1611', 'SBE_Dell_AX-15G_5.0.2609.1511', 'SBE_Dell_AX-14G_5.0.2609.1409')
    }
}

Describe 'Precondition SbeValidatedWithSolution' {
    It 'is registered after SbeConsistent' {
        $names = Get-AzlArmPreconditionName
        $names | Should -Contain 'SbeValidatedWithSolution'
        [array]::IndexOf($names, 'SbeValidatedWithSolution') | Should -Be ([array]::IndexOf($names, 'SbeConsistent') + 1)
    }
    It 'FAILS the real mismatch (5.0.2606.1616 with Solution 12.2610.1004.50) and gives the exact fix' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog; solutionVersion = '12.2610.1004.50' }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Failed'
        $p.evidence | Should -Match 'SBE 5\.0\.2606\.1616 is validated for Solution 12\.\*\.1003\.\* and 12\.\*\.1002\.\*'
        $p.evidence | Should -Match 'this deployment uses 12\.2610\.1004\.50'
        $p.nextAction | Should -Match 'Use SBE 5\.0\.2609\.1611'
        $p.nextAction | Should -Match 'validated: 5\.0\.2609\.1611'
        $p.nextAction | Should -Match 'download it from Dell support'
        $p.nextAction | Should -Match 'hardware\.sbe\.version'
        $p.nextAction | Should -Match 'bundle_path'
        $p.nextAction | Should -Match 'OS configuration'
        $r.ExitCode | Should -Be 1
        $r.Message | Should -Match 'SbeValidatedWithSolution'
        (Get-Pre $r SbeConsistent).result | Should -Be 'Passed'
    }
    It 'PASSES 5.0.2609.1611 with Solution 12.2610.1004.50' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra -Version '5.0.2609.1611') -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog; solutionVersion = '12.2610.1004.50' }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Passed'
        $p.evidence | Should -Match '5\.0\.2609\.1611'
        $p.evidence | Should -Match '12\.2610\.1004\.50'
        $p.evidence | Should -Match 'run setting solutionVersion'
    }
    It 'derives the solution version from the OS build the Arc machines report (10.0.26100.33650), and says so' {
        $r = Invoke-TestRun -World (Get-BuildWorld '10.0.26100.33650') -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Failed'
        $p.evidence | Should -Match 'derived from OS build 10\.0\.26100\.33650'
        $p.evidence | Should -Match '12\.2610\.1004'
        $ok = Invoke-TestRun -World (Get-BuildWorld '10.0.26100.33650') -Infra (Get-SbeInfra -Version '5.0.2609.1611') -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog }
        (Get-Pre $ok SbeValidatedWithSolution).result | Should -Be 'Passed'
        (Get-Pre $ok SbeValidatedWithSolution).evidence | Should -Match 'derived'
    }
    It 'the explicit run setting wins over the OS build' {
        $r = Invoke-TestRun -World (Get-BuildWorld '10.0.26100.33650') -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog; solutionVersion = '12.2609.1003.9' }
        (Get-Pre $r SbeValidatedWithSolution).result | Should -Be 'Passed'
    }
    It 'uses the solution version of the ZTP handoff when the file has one' {
        $handoff = Join-Path $TestDrive 'handoff.json'
        (Get-Content -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'handoff.v2.json')) -Raw) | Set-Content -LiteralPath $handoff
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Handoff $handoff -Settings @{ sbeCatalogPath = $script:Catalog }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Failed'
        $p.evidence | Should -Match '12\.2610\.1004\.50'
        $p.evidence | Should -Match 'handoff'
    }
    It 'WARNS (does not fail) when the solution version cannot be determined' {
        # the default fake OS build, 10.0.26100.32230, does not map unambiguously
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Warning'
        $p.evidence | Should -Match 'solution version'
        $p.nextAction | Should -Match 'solutionVersion'
        $r.ExitCode | Should -Be 0
    }
    It 'is SKIPPED, with the reason, when there is no catalog' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Settings @{ solutionVersion = '12.2610.1004.50' }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Skipped'
        $p.evidence | Should -Match 'sbeCatalogPath'
        $p.evidence | Should -Match 'bundle_path'
        $p.evidence | Should -Match 'Nothing is downloaded'
        $r.ExitCode | Should -Be 0
    }
    It 'is SKIPPED when the catalog path does not exist, and names the path' {
        $missing = Join-Path $TestDrive 'nowhere' 'SBE_Discovery_Dell.xml'
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $missing; solutionVersion = '12.2610.1004.50' }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Skipped'
        $p.evidence | Should -Match 'nowhere'
    }
    It 'reads SBE_Discovery_*.xml from hardware.sbe.bundle_path when no run setting is given' {
        $bundle = Join-Path $TestDrive 'bundle'
        $null = New-Item -ItemType Directory -Path $bundle
        Copy-Item -LiteralPath $script:Catalog -Destination (Join-Path $bundle 'SBE_Discovery_Dell.xml')
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra -BundlePath $bundle) -Mode Plan -Settings @{ solutionVersion = '12.2610.1004.50' }
        (Get-Pre $r SbeValidatedWithSolution).result | Should -Be 'Failed'
        (Get-Pre $r SbeValidatedWithSolution).evidence | Should -Match 'SBE_Discovery_Dell\.xml'
    }
    It 'sbeCatalogPath may be a folder that holds SBE_Discovery_*.xml' {
        $bundle = Join-Path $TestDrive 'folder'
        $null = New-Item -ItemType Directory -Path $bundle
        Copy-Item -LiteralPath $script:Catalog -Destination (Join-Path $bundle 'SBE_Discovery_Dell.xml')
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra -Version '5.0.2609.1611') -Mode Plan -Settings @{ sbeCatalogPath = $bundle; solutionVersion = '12.2610.1004.50' }
        (Get-Pre $r SbeValidatedWithSolution).result | Should -Be 'Passed'
    }
    It 'WARNS when the configured SBE is not in the catalog at all' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra -Version '5.0.2601.1') -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog; solutionVersion = '12.2610.1004.50' }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Warning'
        $p.evidence | Should -Match '5\.0\.2601\.1'
        $p.evidence | Should -Match 'not listed'
    }
    It 'WARNS, does not throw, when the catalog file cannot be read' {
        $bad = Join-Path $TestDrive 'broken.xml'
        'this is not xml' | Set-Content -LiteralPath $bad
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $bad; solutionVersion = '12.2610.1004.50' }
        (Get-Pre $r SbeValidatedWithSolution).result | Should -Be 'Warning'
        (Get-Pre $r SbeValidatedWithSolution).evidence | Should -Match 'could not be read'
    }
    It 'can be skipped on purpose and then shows as Skipped' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog; solutionVersion = '12.2610.1004.50'; skipPreconditions = @('SbeValidatedWithSolution') }
        (Get-Pre $r SbeValidatedWithSolution).result | Should -Be 'Skipped'
        $r.ExitCode | Should -Be 0
    }
    It 'reads nothing from Azure and nothing from the network' {
        $null = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-SbeInfra) -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog; solutionVersion = '12.2610.1004.50' }
        Should -Invoke -ModuleName AzlAzure Invoke-AzRestMethod -Times 0 -Exactly
    }
}

Describe 'Run settings solutionVersion and sbeCatalogPath' {
    It 'default to empty' {
        $s = Get-AzlArmRunSetting
        $s.solutionVersion | Should -Be ''
        $s.sbeCatalogPath | Should -Be ''
    }
    It 'are read from the master file deployment block in snake_case' {
        $s = Get-AzlArmRunSetting -Infrastructure @{ deployment = @{ solution_version = '12.2610.1004.50'; sbe_catalog_path = 'D:\sbe\SBE_Discovery_Dell.xml' } }
        $s.solutionVersion | Should -Be '12.2610.1004.50'
        $s.sbeCatalogPath | Should -Be 'D:\sbe\SBE_Discovery_Dell.xml'
    }
    It 'refuses solutionVersion <Value> (not four numeric parts)' -ForEach @(@{ Value = 'latest' }, @{ Value = '12.2610' }, @{ Value = '12.2610.1004.x' }, @{ Value = '12.2610.1004.50.1' }) {
        { Get-AzlArmRunSetting -Settings @{ solutionVersion = $Value } } | Should -Throw '*solutionVersion*'
    }
}

Describe 'Without a Solution Builder Extension (opt-in)' {
    It 'SbeValidatedWithSolution is Passed with the note, not Skipped or Warning, when hardware.sbe has no version' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Settings @{ sbeCatalogPath = $script:Catalog; solutionVersion = '12.2610.1004.50' }
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Passed'
        $p.evidence | Should -Match 'deploying without a Solution Builder Extension'
    }
    It 'is Passed with the note when there is no hardware.sbe block at all, even with no catalog and no solution version' {
        $infra = Get-TestInfra
        $infra.hardware.Remove('sbe')
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        $p = Get-Pre $r SbeValidatedWithSolution
        $p.result | Should -Be 'Passed'
        $p.evidence | Should -Match 'deploying without a Solution Builder Extension'
        $p.nextAction | Should -BeNullOrEmpty
    }
    It 'neither SBE precondition blocks Validate or Deploy, and the plan has no failed or warning SBE entry' {
        $infra = Get-TestInfra
        $infra.hardware.Remove('sbe')
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        @($r.Preconditions | Where-Object { $_.name -like 'Sbe*' -and $_.result -ne 'Passed' }) | Should -BeNullOrEmpty
    }
    It 'the ARM parameter file of the run carries no SBE parameter' {
        $infra = Get-TestInfra
        $infra.hardware.Remove('sbe')
        $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan
        $file = Get-ChildItem -LiteralPath $r.ReportDirectory -Filter '*.parameters.json' -Recurse | Select-Object -First 1
        $file | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match '"sbe|partner'
    }
}
Describe 'Known issue unvalidated-solution-sbe-combination' {
    BeforeAll {
        # The error text of the real failure (validate-3, step 0.60 InvokeEnvironmentChecker, 2026-11-08)
        $script:RealError = "Type 'InvokeEnvironmentChecker' of Role 'DeploymentService' raised an exception: Microsoft.AzureStack.Solution.Deploy.DeploymentLauncher.Models.EceActionLaunchException: Fail to initialize cloud deployment: SBE package and manifest validation failed with code 'ErrorUnvalidatedSolutionAndSbeCombination'. Error Details: The SBE package SBE_Dell_16G-45n0c-Intel_5.0.2606.1616 has not been validated with Solution version 12.2610.1004.50. The following SBE have been validated: SBE_Dell_17G-Intel_5.0.2609.1715, SBE_Dell_16G-45n0c-Intel_5.0.2609.1611, SBE_Dell_AX-15G_5.0.2609.1511, SBE_Dell_AX-14G_5.0.2609.1409. If the SBE is present on the system, this error can indicate the signature is untrusted or the XML has been tampered with."
    }
    It 'is in the data file, with a cause, remediation steps, retry after-fix and the confidence from the real failure' {
        $i = Get-AzlArmKnownIssue | Where-Object { $_['id'] -eq 'unvalidated-solution-sbe-combination' }
        $i | Should -Not -BeNullOrEmpty
        $i['retry'] | Should -Be 'after-fix'
        $i['confidence'] | Should -Be 'documented'
        $i['cause'] | Should -Match 'SBE'
        @($i['remediation']).Count | Should -BeGreaterThan 2
        $i['evidence'] | Should -Match 'validate-3'
        @($i['phase']) | Should -Contain 'Validate'
        @($i['phase']) | Should -Contain 'Deploy'
    }
    It 'matches the real error text at step 0.60 in Validate and names the fix' {
        $k = Find-AzlArmKnownIssue -Phase Validate -StepId '0.60' -StepName 'InvokeEnvironmentChecker' -ErrorText $script:RealError -Build '12.2610.1004.50'
        $k.Id | Should -Be 'unvalidated-solution-sbe-combination'
        $k.Retry | Should -Be 'after-fix'
        ($k.Remediation -join ' ') | Should -Match 'SbeValidatedWithSolution'
        ($k.Remediation -join ' ') | Should -Match 'bundle_path'
    }
    It 'matches by the error code alone, and in Deploy' {
        (Find-AzlArmKnownIssue -Phase Validate -ErrorText 'ErrorUnvalidatedSolutionAndSbeCombination').Id | Should -Be 'unvalidated-solution-sbe-combination'
        (Find-AzlArmKnownIssue -Phase Deploy -ErrorText 'The SBE package X has not been validated with Solution version 12.2610.1004.50').Id | Should -Be 'unvalidated-solution-sbe-combination'
    }
    It 'does not steal other SBE failures' {
        Find-AzlArmKnownIssue -Phase Validate -ErrorText 'The SBE package hash does not match' | Should -BeNullOrEmpty
    }
}
