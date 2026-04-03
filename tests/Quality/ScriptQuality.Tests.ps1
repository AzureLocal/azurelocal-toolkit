#Requires -Modules Pester, PSScriptAnalyzer
<#
.SYNOPSIS
    PSScriptAnalyzer quality tests for all scripts in scripts/
.DESCRIPTION
    Runs PSScriptAnalyzer against every .ps1 file under scripts/ using the
    shared PSScriptAnalyzerSettings.psd1 configuration. Each file is tested
    as an individual Pester It block so failures are easy to locate.
#>

BeforeDiscovery {
    $repoRoot     = Join-Path $PSScriptRoot '..' '..'
    $scriptsRoot  = Join-Path $repoRoot 'scripts'

    $scriptFiles = Get-ChildItem -Path $scriptsRoot -Recurse -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch [regex]::Escape($PSScriptRoot) }

    $script:scriptTestCases = $scriptFiles | ForEach-Object { @{ ScriptFile = $_ } }
}

BeforeAll {
    $settingsFile = Join-Path $PSScriptRoot '..' 'PSScriptAnalyzerSettings.psd1'
    $script:analyzerSettings = $settingsFile
}

Describe 'PSScriptAnalyzer — Script Quality' {
    Context 'All scripts pass static analysis' {
        It '<ScriptFile.Name> should have zero PSScriptAnalyzer Error violations' -ForEach $script:scriptTestCases {
            $results = Invoke-ScriptAnalyzer `
                -Path $ScriptFile.FullName `
                -Settings $script:analyzerSettings

            $errors = $results | Where-Object { $_.Severity -eq 'Error' }

            if ($errors) {
                $violations = $errors | ForEach-Object {
                    "  [Error] $($_.RuleName) — line $($_.Line): $($_.Message)"
                }
                $message = "Script '$($ScriptFile.Name)' has $($errors.Count) Error violation(s):`n$($violations -join "`n")"
                $message | Should -BeNullOrEmpty
            }

            $errors | Should -BeNullOrEmpty
        }
    }
}
