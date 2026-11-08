#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The ARM deployment scripts run under pwsh on Linux (self-hosted runners) as well as on Windows. A backslash in a local path
# literal (Join-Path $PSScriptRoot '..\..\common') is one file name on Linux. This scan, by AST, covers the files of the ARM
# Validate and Deploy automation, and the entry point's end-to-end behaviour in a child pwsh. Windows paths on a node (C:\SBE),
# UNC shares and provider paths are left alone. (The OS configuration branch has the same scan for its own files.)

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:ScanFiles = foreach ($relative in @(
            'scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1'
            'scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalClusterDeployment.ps1'
            'scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/New-AzureLocalArmParameters.ps1'
            'scripts/common/arm-deployment/AzlArmDeploymentRun.psm1'
            'scripts/common/arm-deployment/AzlArmDeployment.psm1'
            'tests/arm-deployment/ArmDeploymentRun.Helpers.ps1'
            'tests/arm-deployment/ArmDeploymentRun.Tests.ps1'
            'tests/arm-deployment/ArmDeploymentRun.Parameters.Tests.ps1'
            'tests/arm-deployment/ArmDeploymentRun.Preconditions.Tests.ps1'
            'tests/arm-deployment/ArmDeploymentRun.Pipelines.Tests.ps1'
        )) {
        $path = $repoRoot
        foreach ($segment in $relative.Split('/')) { $path = Join-Path $path $segment }
        @{ Name = $relative.Split('/')[-1]; Path = $path }
    }
}
BeforeAll {
    $script:PathCommands = @('Join-Path', 'Split-Path', 'Resolve-Path', 'Test-Path', 'Import-Module', 'Get-Content', 'Set-Content', 'Add-Content', 'Get-ChildItem', 'Get-Item', 'New-Item', 'Copy-Item', 'Remove-Item', 'Out-File', 'Import-PowerShellDataFile', 'Convert-Path', 'Move-Item')
    function Test-IntentionalWindowsPath([string]$Text) { return ($Text -match '^[A-Za-z]:\\' -or $Text -match '^\\\\' -or $Text -match '^(HKLM|HKCU|WSMan|Cert|Env|HKEY_[A-Z_]+):\\?') }
    function Get-BackslashPathLiteral([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "$Path does not parse: $($errors[0].Message)" }
        $found = [System.Collections.Generic.List[string]]::new()
        $stringTypes = { param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }
        foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if (-not $name -or $name -notin $script:PathCommands) { continue }
            foreach ($element in $command.CommandElements | Select-Object -Skip 1) {
                $strings = @($element.FindAll($stringTypes, $true))
                foreach ($s in $strings) { if ($s.Value -match '\\' -and -not (Test-IntentionalWindowsPath $s.Value)) { $found.Add("$($s.Extent.StartLineNumber): $name $($s.Value)") } }
            }
        }
        foreach ($s in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
            if ($s.Extent.Text -match '\$(\{?)(PSScriptRoot|here|repo|common|root)(\}?)\\') { $found.Add("$($s.Extent.StartLineNumber): $($s.Extent.Text)") }
        }
        foreach ($s in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -in 'SingleQuoted', 'DoubleQuoted' -and $n.Value -match '^\.\.?\\' }, $true)) { $found.Add("$($s.Extent.StartLineNumber): $($s.Value)") }
        return @($found | Group-Object { ($_ -split ':')[0] } | ForEach-Object { $_.Group[0] })
    }
}

Describe 'Cross-platform path handling in the ARM deployment scripts' {
    It 'has no backslash path literal in <Name>' -ForEach $script:ScanFiles {
        @(Get-BackslashPathLiteral -Path $Path) | Should -BeNullOrEmpty -Because 'a backslash in a local path breaks on Linux; use [IO.Path]::Combine or Join-Path per segment'
    }
    It 'detects a backslash path literal (the scan itself works)' {
        $file = Join-Path $TestDrive 'bad.ps1'
        Set-Content -LiteralPath $file -Value "`$a = Join-Path `$PSScriptRoot '..\..\common'`n`$b = Join-Path `$PSScriptRoot 'x'`n`$c = Join-Path 'C:\SBE' 'file.zip'"
        @(Get-BackslashPathLiteral -Path $file).Count | Should -Be 1
    }
}

Describe 'The entry point in a child pwsh (no Azure: -Offline)' {
    BeforeAll {
        $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
        $script:Entry = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-05-cluster-deployment', 'Invoke-AzureLocalArmDeployment.ps1')
        $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
        function Invoke-Entry([string[]]$Arguments) {
            $out = & pwsh -NoProfile -NonInteractive -File $script:Entry @Arguments 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
        }
    }
    It 'Plan -Offline on the example file: exit 0, report, summary, events and the parameter files' {
        $dir = Join-Path $TestDrive 'plan'
        $r = Invoke-Entry @('-InfrastructureFile', $script:Example, '-Mode', 'Plan', '-Offline', '-ReportDirectory', $dir)
        $r.ExitCode | Should -Be 0 -Because $r.Output
        foreach ($f in 'report.json', 'summary.md', 'arm-deployment-events.jsonl', 'parameter-sources.md') { Test-Path (Join-Path $dir $f) | Should -BeTrue }
        (Get-Content -LiteralPath (Join-Path $dir 'report.json') -Raw | ConvertFrom-Json).exitCode | Should -Be 0
        $r.Output | Should -Match 'exit code 0'
    }
    It 'Validate -Offline is bad input: exit 2' {
        (Invoke-Entry @('-InfrastructureFile', $script:Example, '-Mode', 'Validate', '-Offline', '-ReportDirectory', (Join-Path $TestDrive 'v'))).ExitCode | Should -Be 2
    }
    It 'a missing file is exit 2' {
        (Invoke-Entry @('-InfrastructureFile', (Join-Path $TestDrive 'nope.yml'), '-Mode', 'Plan', '-Offline', '-ReportDirectory', (Join-Path $TestDrive 'n'))).ExitCode | Should -Be 2
    }
    It 'an unknown mode is rejected by the parameter validation' {
        (Invoke-Entry @('-InfrastructureFile', $script:Example, '-Mode', 'Everything')).ExitCode | Should -Not -Be 0
    }
}
