#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Arc registration), the Azure CLI scripts: Test-ArcPrerequisites.azcli.ps1 (task 01, the Azure side of the pre-registration validation) and
# Test-ArcRegistration.azcli.ps1 (task 04, what Azure Arc reports about the machines). Task 02 (register the nodes) has no Azure CLI script: it runs on each node
# with Invoke-AzStackHciArcInitialization. Every az command is replaced by a fake (tests/fixtures/AzCliFake.ps1): no Azure, no tenant and no sign-in is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/ArcRegistration.AzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks and stub parameters.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $phase = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-04-arc-registration')
    $script:Prerequisites = [IO.Path]::Combine($phase, 'task-01-pre-registration-validation', 'azurecli', 'Test-ArcPrerequisites.azcli.ps1')
    $script:Registration = [IO.Path]::Combine($phase, 'task-04-verify-arc-registration-and-connectivity', 'azurecli', 'Test-ArcRegistration.azcli.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    $script:Providers = @(Get-AzlArmMandatoryProvider)
    function az { }
    . ([IO.Path]::Combine($repo, 'tests', 'fixtures', 'AzCliFake.ps1'))
    $script:Notfound = '(ResourceNotFound) The Resource was not found.'
}

Describe 'Test-ArcPrerequisites.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        $global:AzlArcState = @{ Roles = '["Azure Connected Machine Onboarding","Azure Connected Machine Resource Administrator"]'; Unregistered = @() }
        Set-AzHandler 'group show' { '{"name":"rg-azl-01","properties":{"provisioningState":"Succeeded"}}' }
        Set-AzHandler 'provider show' { param($o, $a); $null = $a; if ($o['--namespace'][0] -in $global:AzlArcState.Unregistered) { 'NotRegistered' } else { 'Registered' } }
        Set-AzHandler 'ad signed-in-user show' { '00000000-0000-0000-0000-0000000000a1' }
        Set-AzHandler 'role assignment list' { $global:AzlArcState.Roles }
    }
    AfterAll { Remove-Variable -Name AzlArcState -Scope Global -ErrorAction SilentlyContinue }

    It 'passes when the subscription, the resource group, every provider and the roles are in place, and changes nothing' {
        $r = Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($r.Rows | Where-Object Result -EQ 'Failed').Count | Should -Be 0
        @(Get-AzCall 'provider show').Count | Should -Be $script:Providers.Count
        @(Get-AzCall 'provider show' | ForEach-Object { $_.Options['--namespace'][0] } | Sort-Object) | Should -Be @($script:Providers | Sort-Object)
        (Get-AzCall 'group show')[0].Options['--name'] | Should -Be 'rg-azl-01'
        (Get-AzCall 'role assignment list')[0].Options['--scope'] | Should -Be "/subscriptions/$($global:AzlTestSubscription)/resourceGroups/rg-azl-01"
        (Get-AzCall 'role assignment list')[0].Options.ContainsKey('--include-groups') | Should -BeTrue
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'runs no check and calls no az command under -WhatIf' {
        $r = Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'ends with exit code 1 and names a provider that is not registered' {
        $global:AzlArcState.Unregistered = @('Microsoft.HybridCompute')
        $r = Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Microsoft.HybridCompute'
    }

    It 'ends with exit code 1 when the account lacks a registration role, and passes with Owner' {
        $global:AzlArcState.Roles = '["Azure Connected Machine Onboarding"]'
        $r = Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Azure Connected Machine Resource Administrator'
        $global:AzlArcState.Roles = '["Owner"]'
        (Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)).ExitCode | Should -Be 0
    }

    It 'looks up a service principal by its application ID when the sign-in is one' {
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription 'servicePrincipal' '00000000-0000-0000-0000-0000000000b2'
        Set-AzHandler 'ad sp show' { '00000000-0000-0000-0000-0000000000c3' }
        $r = Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'ad sp show')[0].Options['--id'] | Should -Be '00000000-0000-0000-0000-0000000000b2'
        (Get-AzCall 'role assignment list')[0].Options['--assignee'] | Should -Be '00000000-0000-0000-0000-0000000000c3'
        (Get-AzCall 'role assignment list')[0].Options.ContainsKey('--include-groups') | Should -BeFalse
    }

    It 'ends with exit code 1 when the resource group does not exist' {
        Set-AzHandler 'group show' { New-AzFailure 3 $script:Notfound }
        $r = Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'rg-azl-01'
    }

    It 'stops with exit code 2 for a file without a tenant or a resource group, and with exit code 1 for another tenant, no sign-in or no az' {
        (Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile { param($d) $d.azure.Remove('tenant_id') })).ExitCode | Should -Be 2
        (Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile { param($d) $d.azure.Remove('resource_group') })).ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
        Set-AzSignIn ([guid]::NewGuid().ToString()) $global:AzlTestSubscription
        (Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)).ExitCode | Should -Be 1
        Set-AzHandler 'account show' { New-AzFailure 1 'Please run az login to setup account.' }
        (Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)).ExitCode | Should -Be 1
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        (Invoke-AzTool $script:Prerequisites (New-AzTestInfraFile)).ExitCode | Should -Be 1
    }
}

Describe 'Test-ArcRegistration.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        $global:AzlArcState = @{ Status = 'Connected'; Missing = @(); Found = @('azl-n01', 'arc-azl-n02') }
        Set-AzHandler 'extension show' { '{"name":"connectedmachine"}' }
        Set-AzHandler 'connectedmachine show' {
            param($o, $a)
            $null = $a
            if ($o['--name'][0] -notin $global:AzlArcState.Found) { return (New-AzFailure 3 $script:Notfound) }
            '{"name":"' + $o['--name'][0] + '","status":"' + $global:AzlArcState.Status + '","agentVersion":"1.50.0"}'
        }
        Set-AzHandler 'connectedmachine extension list' {
            $all = @('AzureEdgeTelemetryAndDiagnostics', 'AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport') | Where-Object { $_ -notin $global:AzlArcState.Missing }
            '[' + ((@($all) | ForEach-Object { '{"name":"' + $_ + '","properties":{"provisioningState":"Succeeded"}}' }) -join ',') + ']'
        }
    }
    AfterAll { Remove-Variable -Name AzlArcState -Scope Global -ErrorAction SilentlyContinue }

    It 'passes when every machine of the file is Connected with the four Azure Local extensions, and changes nothing' {
        $r = Invoke-AzTool $script:Registration (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-AzCall 'connectedmachine show' | ForEach-Object { $_.Options['--name'][0] }) | Should -Be @('azl-n01', 'arc-azl-n02')
        (Get-AzCall 'connectedmachine show')[0].Options['--resource-group'] | Should -Be 'rg-azl-01'
        (Get-AzCall 'connectedmachine show')[0].Options['--subscription'] | Should -Be $global:AzlTestSubscription
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'runs no check and calls no az command under -WhatIf' {
        $r = Invoke-AzTool $script:Registration (New-AzTestInfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'ends with exit code 1 for a machine that is not Connected, a missing extension and a machine that is not in Azure' {
        $global:AzlArcState.Status = 'Disconnected'
        (Invoke-AzTool $script:Registration (New-AzTestInfraFile)).ExitCode | Should -Be 1
        $global:AzlArcState.Status = 'Connected'
        $global:AzlArcState.Missing = @('AzureEdgeLifecycleManager')
        $r = Invoke-AzTool $script:Registration (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'AzureEdgeLifecycleManager'
        $global:AzlArcState.Missing = @()
        $global:AzlArcState.Found = @('azl-n01')
        $r = Invoke-AzTool $script:Registration (New-AzTestInfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'arc-azl-n02'
    }

    It 'limits the check to the nodes named with -TargetNode' {
        $r = Invoke-AzTool $script:Registration (New-AzTestInfraFile) @{ TargetNode = 'arc-no-such' }
        $r.ExitCode | Should -Be 2
        $r = Invoke-AzTool $script:Registration (New-AzTestInfraFile) @{ TargetNode = 'azl-n01' }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-AzCall 'connectedmachine show').Count | Should -Be 1
    }

    It 'stops with exit code 2 for a file without a subscription, and with exit code 1 for another tenant, no sign-in, no extension or no az' {
        (Invoke-AzTool $script:Registration (New-AzTestInfraFile { param($d) $d.azure.Remove('subscription_id') })).ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
        Set-AzSignIn ([guid]::NewGuid().ToString()) $global:AzlTestSubscription
        (Invoke-AzTool $script:Registration (New-AzTestInfraFile)).ExitCode | Should -Be 1
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Set-AzHandler 'extension show' { New-AzFailure 1 'The extension is not installed.' }
        (Invoke-AzTool $script:Registration (New-AzTestInfraFile)).ExitCode | Should -Be 1
        Set-AzHandler 'account show' { New-AzFailure 1 'Please run az login to setup account.' }
        (Invoke-AzTool $script:Registration (New-AzTestInfraFile)).ExitCode | Should -Be 1
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        (Invoke-AzTool $script:Registration (New-AzTestInfraFile)).ExitCode | Should -Be 1
    }
}
