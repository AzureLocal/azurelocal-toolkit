#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Operational foundations, phase 01, task 02: Invoke-SdnIntegration-Orchestrated.ps1 runs the three network security group scripts in order.
# The orchestrator is copied into a folder tree under TestDrive with fake step scripts beside it: no Azure, no az, nothing real is called.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/operational-foundations/SdnIntegration.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Source = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-01-sdn-deployment', 'task-02-configure-network-security-groups', 'powershell', 'Invoke-SdnIntegration-Orchestrated.ps1')
    $script:Steps = @(
        @('04-cluster-deployment', 'phase-06-post-deployment', 'task-07-configure-nsgs', 'powershell', 'New-NetworkSecurityGroup.ps1'),
        @('05-operational-foundations', 'phase-01-sdn-deployment', 'task-02-configure-network-security-groups', 'azurecli', 'Set-NetworkSecurityGroupRule.azcli.ps1'),
        @('05-operational-foundations', 'phase-01-sdn-deployment', 'task-03-configure-network-security-groups', 'azurecli', 'Test-NetworkSecurityGroupRule.azcli.ps1')
    )

    # A fake step: writes its name and parameters to the call log, ends with the exit code its code file holds.
    $script:Fake = @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$InfrastructureFile, [switch]$RemoveUnlistedRules, [string]$LogPath)
$name = Split-Path -Leaf $PSCommandPath
Add-Content -LiteralPath (Join-Path $env:AZL_TEST_SDNINT_DIR 'calls.txt') -Value ("{0}|whatif={1}|remove={2}" -f $name, [bool]$WhatIfPreference, [bool]$RemoveUnlistedRules) -WhatIf:$false
$codeFile = Join-Path $env:AZL_TEST_SDNINT_DIR "$name.code"
exit $(if (Test-Path $codeFile) { [int](Get-Content $codeFile) } else { 0 })
'@

    function New-Tree {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $deploy = Join-Path $root 'deploy'
        foreach ($s in $script:Steps) {
            $path = $deploy; foreach ($p in $s) { $path = Join-Path $path $p }
            New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
            Set-Content -LiteralPath $path -Value $script:Fake
        }
        $orch = [IO.Path]::Combine($deploy, '05-operational-foundations', 'phase-01-sdn-deployment', 'task-02-configure-network-security-groups', 'powershell', 'Invoke-SdnIntegration-Orchestrated.ps1')
        New-Item -ItemType Directory -Path (Split-Path $orch) -Force | Out-Null
        Copy-Item -LiteralPath $script:Source -Destination $orch
        $env:AZL_TEST_SDNINT_DIR = $root
        Set-Content -LiteralPath (Join-Path $root 'infra.yml') -Value 'cluster: {}'
        [pscustomobject]@{ Root = $root; Orchestrator = $orch; Infra = (Join-Path $root 'infra.yml') }
    }
    function Invoke-Orch($Tree, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $out = & $Tree.Orchestrator -InfrastructureFile $Tree.Infra @Extra 6>$null
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Summary  = @($out | Where-Object { $_.PSObject.Properties['Step'] })
            Calls    = @(if (Test-Path (Join-Path $Tree.Root 'calls.txt')) { Get-Content (Join-Path $Tree.Root 'calls.txt') })
        }
    }
}

Describe 'Invoke-SdnIntegration-Orchestrated.ps1' {
    AfterAll { Remove-Item Env:AZL_TEST_SDNINT_DIR -ErrorAction SilentlyContinue }

    It 'runs create, align and verify in that order and exits 0' {
        $t = New-Tree
        $r = Invoke-Orch $t
        $r.ExitCode | Should -Be 0
        @($r.Calls | ForEach-Object { ($_ -split '\|')[0] }) | Should -Be @('New-NetworkSecurityGroup.ps1', 'Set-NetworkSecurityGroupRule.azcli.ps1', 'Test-NetworkSecurityGroupRule.azcli.ps1')
        @($r.Summary.Result) | Should -Be @('Passed', 'Passed', 'Passed')
    }

    It 'passes -RemoveUnlistedRules only to the align step' {
        $t = New-Tree
        $r = Invoke-Orch $t -Extra @{ RemoveUnlistedRules = $true }
        $r.Calls[0] | Should -Match 'remove=False'
        $r.Calls[1] | Should -Match 'remove=True'
    }

    It 'passes -WhatIf to create and align and does not run the verification' {
        $t = New-Tree
        $r = Invoke-Orch $t -Extra @{ WhatIf = $true }
        $r.ExitCode | Should -Be 0
        $r.Calls.Count | Should -Be 2
        $r.Calls | ForEach-Object { $_ | Should -Match 'whatif=True' }
        $r.Summary[2].Result | Should -Be 'Skipped'
    }

    It 'stops after a step that fails and exits 1' {
        $t = New-Tree
        Set-Content -LiteralPath (Join-Path $t.Root 'New-NetworkSecurityGroup.ps1.code') -Value 1
        $r = Invoke-Orch $t
        $r.ExitCode | Should -Be 1
        $r.Calls.Count | Should -Be 1
    }

    It 'passes on exit code 2 of a step (input problem)' {
        $t = New-Tree
        Set-Content -LiteralPath (Join-Path $t.Root 'Set-NetworkSecurityGroupRule.azcli.ps1.code') -Value 2
        $r = Invoke-Orch $t
        $r.ExitCode | Should -Be 2
        $r.Calls.Count | Should -Be 2
        $r.Summary[1].Result | Should -Be 'InputProblem'
    }

    It 'reports a verification failure with exit 1' {
        $t = New-Tree
        Set-Content -LiteralPath (Join-Path $t.Root 'Test-NetworkSecurityGroupRule.azcli.ps1.code') -Value 1
        (Invoke-Orch $t).ExitCode | Should -Be 1
    }

    It 'names the real step scripts, and they exist in the toolkit' {
        $deploy = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'scripts', 'deploy'))
        foreach ($s in $script:Steps) { $path = $deploy; foreach ($p in $s) { $path = Join-Path $path $p }; Test-Path -LiteralPath $path | Should -BeTrue }
    }
}
