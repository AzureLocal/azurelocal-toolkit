#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# O10: a placeholder that a published guide page names becomes a thin wrapper over the script that does the job the page describes. The wrappers keep their
# file names, run the OS configuration, the pre-cluster verification or the post-deployment verification through scripts/deploy/common/DeploymentWrapper.psm1,
# and add no logic. These tests read the files, run each wrapper as a child process with a missing file (exit 2) and with -WhatIf (lists the command line,
# runs nothing), and run the shared module against fake scripts in TestDrive. Nothing here contacts Azure, a node or a BMC.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/PlaceholdersWrapped.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $cluster = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment')
    $p3 = 'phase-03-os-configuration'
    $p4 = 'phase-04-arc-registration'
    $p5 = 'phase-05-cluster-deployment'
    $osc = "$p3/Invoke-AzureLocalOsConfiguration.ps1"
    $pcv = "$p5/Invoke-AzureLocalPreClusterVerification.ps1"
    $arm = "$p5/Invoke-AzureLocalArmDeployment.ps1"
    $post = 'phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-PostDeploymentVerification-Orchestrated.ps1'
    # Wrapper (relative to the cluster folder) -> the scripts it runs (relative to the cluster folder) and the parameters it hands them.
    $script:Wrappers = @(
        @{ Wrapper = "$p3/task-16-phase03-verification/powershell/Invoke-Phase03Verification-Orchestrated.ps1"; Runs = @(@{ Script = $osc; Names = 'InfrastructureFile', 'Mode', 'FailOnPendingChanges', 'Node', 'Credential', 'SettingsFile', 'ReportDirectory' }, @{ Script = $pcv; Names = 'InfrastructureFile', 'Mode', 'Category', 'SettingsFile', 'ReportDirectory' }) }
        @{ Wrapper = "$p3/task-16-phase03-verification/powershell/Test-Phase03Verification.ps1"; Runs = @(@{ Script = "$p3/task-16-phase03-verification/powershell/Invoke-Phase03Verification-Orchestrated.ps1"; Names = 'InfrastructureFile', 'Node', 'ReportDirectory', 'SettingsFile', 'Credential' }) }
        @{ Wrapper = "$p4/task-01-pre-registration-validation/powershell/Invoke-ArcPrerequisites-Orchestrated.ps1"; Runs = @(@{ Script = $pcv; Names = 'InfrastructureFile', 'Mode', 'Category', 'ReportDirectory', 'SettingsFile' }) }
        @{ Wrapper = "$p4/task-02-register-cluster-nodes-with-azure-arc/powershell/Invoke-ArcRegistration-Orchestrated.ps1"; Runs = @(@{ Script = $osc; Names = 'InfrastructureFile', 'Mode', 'Step', 'Node', 'ReportDirectory', 'SettingsFile', 'Credential' }) }
        @{ Wrapper = "$p4/task-04-verify-arc-registration-and-connectivity/powershell/Invoke-ArcVerification-Orchestrated.ps1"; Runs = @(@{ Script = $osc; Names = 'InfrastructureFile', 'Mode', 'Step', 'ReportDirectory', 'Node', 'Credential', 'SettingsFile' }, @{ Script = $arm; Names = 'InfrastructureFile', 'Mode', 'OsConfigurationReport', 'ReportDirectory' }) }
        @{ Wrapper = "$p5/active-directory/task-01-initiate-deployment-via-arm-template/powershell/Invoke-VerifyADPrerequisites-Orchestrated.ps1"; Runs = @(@{ Script = $pcv; Names = 'InfrastructureFile', 'Mode', 'Category', 'ReportDirectory', 'SettingsFile' }) }
        @{ Wrapper = "$p5/local-identity/task-01-initiate-deployment-via-azure-portal/powershell/Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1"; Runs = @(@{ Script = $osc; Names = 'InfrastructureFile', 'Mode', 'Step', 'Node', 'ReportDirectory', 'SettingsFile', 'Credential' }) }
        @{ Wrapper = "$p5/local-identity/task-02-verify-deployment-completion/powershell/Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1"; Runs = @(@{ Script = $post; Names = 'InfrastructureFile', 'Credential', 'TargetNode', 'SkipAzure', 'LogPath' }) }
    ) | ForEach-Object {
        $runs = @($_.Runs | ForEach-Object { @{ Script = [IO.Path]::Combine($cluster, $_.Script.Replace('/', [IO.Path]::DirectorySeparatorChar)); Names = $_.Names } })
        @{ Name = [IO.Path]::GetFileName($_.Wrapper); Path = [IO.Path]::Combine($cluster, $_.Wrapper.Replace('/', [IO.Path]::DirectorySeparatorChar)); Runs = $runs }
    }
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:ModulePath = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', 'common', 'DeploymentWrapper.psm1')
    $script:PlaceholderPattern = '(?m)^# PLACEHOLDER:|\b(Invoke-Deployment(AzCliPowerShell|Orchestrated|Standalone)|Stop-DeploymentPlaceholder)\b'
    function Get-ParamName([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    function Invoke-Child([string]$Path, [string[]]$Arguments) {
        $out = & pwsh -NoProfile -NonInteractive -File $Path @Arguments 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    }
}

Describe 'The wrappers of the placeholders that guide pages name' {
    It '<Name> exists, parses, is not a placeholder and has the standard header' -ForEach $script:Wrappers {
        Test-Path -LiteralPath $Path | Should -BeTrue
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Not -Match $script:PlaceholderPattern
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Not -Match 'Read-Host|Get-Credential|ConfigPath'
    }

    It '<Name> has a mandatory -InfrastructureFile without a default' -ForEach $script:Wrappers {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' })
        $param.Count | Should -Be 1
        $param[0].DefaultValue | Should -BeNullOrEmpty
        @($param[0].Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } | ForEach-Object { $_.NamedArguments.ArgumentName }) | Should -Contain 'Mandatory'
    }

    It '<Name> hands only parameters that the script it runs declares' -ForEach $script:Wrappers {
        $text = Get-Content -LiteralPath $Path -Raw
        foreach ($run in $Runs) {
            Test-Path -LiteralPath $run.Script | Should -BeTrue
            $declared = Get-ParamName $run.Script
            foreach ($n in $run.Names) {
                $declared | Should -Contain $n -Because "$n is handed to $([IO.Path]::GetFileName($run.Script))"
            }
        }
    }

    It '<Name> does not run an Azure, node or BMC command of its own' -ForEach $script:Wrappers {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        @($names | Where-Object { $_ -match '^(az|Connect-|Invoke-Command|Invoke-RestMethod|Invoke-WebRequest|Set-(?!StrictMode)|New-AzureLocal|Enter-PSSession|New-PSSession)' }) | Should -BeNullOrEmpty
    }

    It '<Name> ends with exit code 2 and a message when the file does not exist' -ForEach $script:Wrappers {
        $r = Invoke-Child $Path @('-InfrastructureFile', (Join-Path $TestDrive 'does-not-exist.yml'))
        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'Cannot read the infrastructure file'
    }

    It '<Name> lists what it would run under -WhatIf, runs nothing and creates no file' -ForEach $script:Wrappers {
        $file = Join-Path $TestDrive "$Name.infrastructure.yml"
        Set-Content -LiteralPath $file -Value 'cluster: {}'
        $reports = Join-Path $TestDrive "$Name-reports"
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force).Count
        $r = Invoke-Child $Path @('-InfrastructureFile', $file, '-WhatIf')
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'WhatIf: would run'
        foreach ($run in $Runs) { $r.Output | Should -Match ([regex]::Escape([IO.Path]::GetFileName($run.Script))) }
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force).Count | Should -Be $before
    }
}

Describe 'DeploymentWrapper.psm1' {
    BeforeAll {
        Import-Module $script:ModulePath -Force
        function New-FakeScript([string]$Code) {
            $path = Join-Path $TestDrive ("fake-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            Set-Content -LiteralPath $path -Value "param([string]`$Marker, [switch]`$Flag)`nSet-Content -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'ran.txt') -Value ('{0}|{1}' -f `$Marker, `$Flag.IsPresent)`nexit $Code"
            $path
        }
    }
    It 'returns the exit code of the script' -ForEach @(@{ Code = 0 }, @{ Code = 1 }, @{ Code = 2 }) {
        $fake = New-FakeScript $Code
        (Invoke-DeploymentWrapperStep -ScriptPath $fake -Argument @{ Marker = 'x' } -Label 'fake' 6>$null 3>$null) | Should -Be $Code
    }
    It 'passes the named arguments, a switch as true' {
        $fake = New-FakeScript 0
        $null = Invoke-DeploymentWrapperStep -ScriptPath $fake -Argument @{ Marker = 'abc'; Flag = $true } -Label 'fake'
        Get-Content -LiteralPath (Join-Path $TestDrive 'ran.txt') -Raw | Should -Match 'abc\|True'
    }
    It 'reports exit code 3 as 0 only with -PartialIsPass' {
        $fake = New-FakeScript 3
        Invoke-DeploymentWrapperStep -ScriptPath $fake -Argument @{ Marker = 'x' } -Label 'fake' -PartialIsPass | Should -Be 0
        Invoke-DeploymentWrapperStep -ScriptPath $fake -Argument @{ Marker = 'x' } -Label 'fake' | Should -Be 3
    }
    It 'does not run the script under -WhatIf' {
        $fake = New-FakeScript 1
        Remove-Item -LiteralPath (Join-Path $TestDrive 'ran.txt') -ErrorAction SilentlyContinue
        Invoke-DeploymentWrapperStep -ScriptPath $fake -Argument @{ Marker = 'x' } -Label 'fake' -WhatIf | Should -Be 0
        Test-Path -LiteralPath (Join-Path $TestDrive 'ran.txt') | Should -BeFalse
    }
    It 'finds a script of scripts/deploy from a folder below the repository root' {
        $target = Get-DeploymentWrapperTarget -From ([IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-04-arc-registration')) -Relative '04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
        Test-Path -LiteralPath $target | Should -BeTrue
        { Get-DeploymentWrapperTarget -From $script:Repo -Relative 'no/such/script.ps1' } | Should -Throw
    }
}
