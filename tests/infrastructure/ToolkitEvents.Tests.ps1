#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# K9: the shared event writer (Write-AzlToolkitEvent) and the events folder rule (Resolve-AzlEventsDirectory warns when -ReportDirectory moves the feed away from
# the folder azurelocal-sonar reads). Files only; nothing outside the test drive is written.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/infrastructure/ToolkitEvents.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
}

Describe 'Write-AzlToolkitEvent' {
    It 'appends one JSON object per line with the shared envelope and creates the folder' {
        $feed = Join-Path $TestDrive 'new\events\update-events.jsonl'
        Write-AzlToolkitEvent -Path $feed -Stage SolutionUpdate -Step Run -State RunStarted -Evidence 'start' -RunId 'r1' -Mode Check -Cluster 'clus01' | Should -BeTrue
        Write-AzlToolkitEvent -Path $feed -Stage SolutionUpdate -Step Update -State UpdateStart -Evidence 'one' -Level Warning -NextAction 'do it' -RunId 'r1' -Mode Check -Cluster 'clus01' -Data @{ version = '12.2611.1004.9'; exitCode = 0; stage = 'ignored' } | Should -BeTrue
        $lines = @(Get-Content -LiteralPath $feed)
        $lines.Count | Should -Be 2
        $second = $lines[1] | ConvertFrom-Json
        $second.stage | Should -Be 'SolutionUpdate' -Because 'a Data key never replaces an envelope field'
        $second.node | Should -Be '*'
        $second.step | Should -Be 'Update'
        $second.state | Should -Be 'UpdateStart'
        $second.level | Should -Be 'Warning'
        $second.nextAction | Should -Be 'do it'
        $second.runId | Should -Be 'r1'
        $second.mode | Should -Be 'Check'
        $second.cluster | Should -Be 'clus01'
        $second.version | Should -Be '12.2611.1004.9'
        $second.exitCode | Should -Be 0
        { [datetime]::Parse($second.timestamp, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } | Should -Not -Throw
        [IO.File]::ReadAllBytes($feed)[0] | Should -Not -Be 0xEF -Because 'UTF-8 without BOM'
    }
    It 'writes nothing and does not throw without a path, and returns false when the path cannot be written' {
        Write-AzlToolkitEvent -Path '' -Stage S -State X | Should -BeFalse
        $blocker = Join-Path $TestDrive 'a-file'
        Set-Content -LiteralPath $blocker -Value 'x'
        Write-AzlToolkitEvent -Path (Join-Path $blocker 'sub\feed.jsonl') -Stage S -State X | Should -BeFalse
    }
}

Describe 'Resolve-AzlEventsDirectory: -ReportDirectory without deployment.events_directory' {
    It 'warns that Sonar will not see the feed, once per folder, and still returns the report directory' {
        $infra = @{ cluster = @{ name = 'clus01' } }
        $dir = Join-Path $TestDrive 'run-k9'
        $first = Resolve-AzlEventsDirectory -Infrastructure $infra -ReportDirectory $dir -WarningVariable w1 -WarningAction SilentlyContinue
        $first | Should -Be $dir
        ($w1 -join ' ') | Should -Match 'deployment\.events_directory'
        $null = Resolve-AzlEventsDirectory -Infrastructure $infra -ReportDirectory $dir -WarningVariable w2 -WarningAction SilentlyContinue
        @($w2).Count | Should -Be 0
    }
    It 'does not warn when deployment.events_directory is set' {
        $infra = @{ cluster = @{ name = 'clus01' }; deployment = @{ events_directory = (Join-Path $TestDrive 'ev') } }
        $null = Resolve-AzlEventsDirectory -Infrastructure $infra -ReportDirectory (Join-Path $TestDrive 'run-k9b') -WarningVariable w -WarningAction SilentlyContinue
        @($w).Count | Should -Be 0
    }
}
