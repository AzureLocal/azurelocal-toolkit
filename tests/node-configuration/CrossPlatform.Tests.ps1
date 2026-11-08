#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The OS configuration scripts run on a Linux self-hosted runner under pwsh as well as on Windows. A path literal with a
# backslash (Join-Path $PSScriptRoot '..\..\common') is one file name on Linux, so it breaks there. This test scans the
# scripts and the modules they import for such literals. Paths on the nodes (C:\SBE) are Windows paths on purpose and the
# node scripts are text for Windows PowerShell 5.1; both are left alone.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/node-configuration/CrossPlatform.Tests.ps1

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:ScanFiles = foreach ($relative in @(
            'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Set-AzureLocalNodeConfiguration.ps1'
            'scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
            'scripts/common/node-configuration/AzlOsConfigurationRun.psm1'
            'scripts/common/node-configuration/AzlNodeConfiguration.psm1'
            'scripts/common/node-configuration/AzlNodePayload.psm1'
            'scripts/common/node-configuration/AzlNodeTransport.psm1'
            'scripts/common/infrastructure/AzlInfrastructure.psm1'
            'scripts/common/azure-local/AzlAzure.psm1'
            'scripts/common/remoting/AzlRemotingProfile.psm1'
            'scripts/common/remoting/AzlRemotingPayload.psm1'
            'scripts/common/remoting/AzlRemotingSession.psm1'
            'scripts/common/remoting/AzlRemoteManagement.psm1'
            'scripts/common/remoting/AzlRemotingBootstrap.psm1'
        )) {
        $path = $repoRoot
        foreach ($segment in $relative.Split('/')) { $path = Join-Path $path $segment }
        @{ Name = $relative.Split('/')[-1]; Path = $path }
    }
}
BeforeAll {
    # Commands whose arguments are local paths.
    $script:PathCommands = @(
        'Join-Path', 'Split-Path', 'Resolve-Path', 'Test-Path', 'Import-Module', 'Get-Content', 'Set-Content', 'Add-Content', 'Get-ChildItem',
        'Get-Item', 'New-Item', 'Copy-Item', 'Remove-Item', 'Out-File', 'Import-PowerShellDataFile', 'Convert-Path', 'Move-Item'
    )

    # A string that is not a local path even though it holds a backslash: a Windows path on a node, a UNC share, a provider path.
    function Test-IntentionalWindowsPath([string]$Text) {
        return ($Text -match '^[A-Za-z]:\\' -or $Text -match '^\\\\' -or $Text -match '^(HKLM|HKCU|WSMan|Cert|Env|HKEY_[A-Z_]+):\\?')
    }

    # Returns one finding per path literal with a backslash: "<line>: <text>".
    function Get-BackslashPathLiteral([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "$Path does not parse: $($errors[0].Message)" }
        $found = [System.Collections.Generic.List[string]]::new()

        # (1) string arguments of the path commands, anywhere inside them (including (Join-Path ... ) nested in a parameter)
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            if (-not $name -or $name -notin $script:PathCommands) { continue }
            foreach ($element in $command.CommandElements | Select-Object -Skip 1) {
                $strings = $element.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $element -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $strings = @($element) + @($strings) }
                foreach ($s in $strings) {
                    # skip anything that sits inside a nested command that is not a path command (its own string arguments are not paths)
                    $text = if ($s -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $s.Value } else { $s.Value }
                    if ($text -match '\\' -and -not (Test-IntentionalWindowsPath $text)) { $found.Add("$($s.Extent.StartLineNumber): $($command.GetCommandName()) $text") }
                }
            }
        }
        # (2) "$PSScriptRoot\x", "$here\x": a variable followed by a backslash inside a string
        $expandable = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
        foreach ($s in $expandable) {
            if ($s.StringConstantType -in 'DoubleQuotedHereString', 'SingleQuotedHereString') { continue }
            if ($s.Extent.Text -match '\$(\{?)(PSScriptRoot|here|repo|common|root)(\}?)\\') { $found.Add("$($s.Extent.StartLineNumber): $($s.Extent.Text)") }
        }
        # (3) a path variable assigned or defaulted from a literal with a backslash: $x = '..\..\config' is caught only through (1), so also
        # look for [IO.Path]-less concatenation with a leading ..\
        $plain = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -in 'SingleQuoted', 'DoubleQuoted' -and $n.Value -match '^\.\.?\\' }, $true)
        foreach ($s in $plain) { $found.Add("$($s.Extent.StartLineNumber): $($s.Value)") }
        return @($found | Group-Object { ($_ -split ':')[0] } | ForEach-Object { $_.Group[0] })
    }
}

Describe 'Cross-platform path handling in the OS configuration scripts' {
    It 'has no backslash path literal in <Name>' -ForEach $script:ScanFiles {
        @(Get-BackslashPathLiteral -Path $Path) | Should -BeNullOrEmpty -Because 'a backslash in a local path breaks on Linux; use Join-Path per segment or [IO.Path]::Combine'
    }

    It 'detects a backslash path literal (the scan itself works)' {
        $file = Join-Path $TestDrive 'bad.ps1'
        Set-Content -LiteralPath $file -Value "`$a = Join-Path `$PSScriptRoot '..\..\common'`n`$b = Join-Path `$PSScriptRoot 'x'`n`$c = Join-Path 'C:\SBE' 'file.zip'"
        @(Get-BackslashPathLiteral -Path $file).Count | Should -Be 1
    }
}
