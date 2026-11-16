#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 05 (cluster deployment), the Azure CLI scripts: Invoke-AzureLocalArmDeployment.azcli.ps1 (task 01 of both identities: az deployment group validate, then
# create, with the parameter set of the toolkit's ARM deployment code) and Test-AzureLocalClusterDeployment.azcli.ps1 (task 02 of both identities). Every az command is
# replaced by a fake (tests/fixtures/AzCliFake.ps1): no Azure, no tenant and no sign-in is used. The ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment/ArmDeployment.AzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks and stub parameters.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $phase = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-05-cluster-deployment')
    $script:Arm = [IO.Path]::Combine($phase, 'Invoke-AzureLocalArmDeployment.azcli.ps1')
    $script:ArmAd = [IO.Path]::Combine($phase, 'active-directory', 'task-01-initiate-deployment-via-arm-template', 'azurecli', 'Invoke-AzureLocalArmDeployment.azcli.ps1')
    $script:ArmLocal = [IO.Path]::Combine($phase, 'local-identity', 'task-01-initiate-deployment-via-arm-template', 'azurecli', 'Invoke-AzureLocalArmDeployment.azcli.ps1')
    $script:Check = [IO.Path]::Combine($phase, 'Test-AzureLocalClusterDeployment.azcli.ps1')
    $script:CheckAd = [IO.Path]::Combine($phase, 'active-directory', 'task-02-verify-deployment-completion', 'azurecli', 'Test-ClusterDeployment.azcli.ps1')
    $script:CheckLocal = [IO.Path]::Combine($phase, 'local-identity', 'task-02-verify-deployment-completion', 'azurecli', 'Test-ClusterDeployment.azcli.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    function az { }
    . ([IO.Path]::Combine($repo, 'tests', 'fixtures', 'AzCliFake.ps1'))
    $script:Notfound = '(ResourceNotFound) The Resource was not found.'
    $script:Sub = $global:AzlTestSubscription

    # The toolkit's Fibre Channel fixture, reshaped to Storage Spaces Direct and an identity, with this run's tenant and subscription.
    function New-ArmFile {
        param([string]$Identity = 'active_directory', [scriptblock]$Edit)
        $infra = Get-TestInfra -Identity $Identity -Storage s2d
        $infra.azure.tenant_id = $global:AzlTestTenant
        $infra.azure.subscription_id = $global:AzlTestSubscription
        $infra.key_vaults[0].subscription_id = $global:AzlTestSubscription
        if ($Edit) { & $Edit $infra }
        $file = Join-Path $TestDrive "arm-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $infra)
        $file
    }
    function Get-SettingsJson([string]$Validation, [string]$Deployment, [string]$Provisioning = 'Succeeded') {
        '{"properties":{"provisioningState":"' + $Provisioning + '","reportedProperties":{"validationStatus":{"status":"' + $Validation + '"},"deploymentStatus":{"status":"' + $Deployment + '"}}}}'
    }
}

Describe 'Invoke-AzureLocalArmDeployment.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Mock Start-Sleep { }
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        # Azure as it is before anything was submitted: no instance, no deployment.
        $global:AzlArmState = @{ Settings = $null; Existing = ''; Created = $false; Validate = 'ok'; Result = 'Succeeded'; AfterCreate = (Get-SettingsJson 'Success' 'NotStarted') }
        Set-AzHandler 'rest' { if ($null -eq $global:AzlArmState.Settings) { New-AzFailure 3 $script:Notfound } else { $global:AzlArmState.Settings } }
        Set-AzHandler 'deployment group validate' { if ($global:AzlArmState.Validate -eq 'ok') { '{"properties":{"provisioningState":"Succeeded"}}' } else { New-AzFailure 1 'InvalidTemplateDeployment: the template is not valid.' } }
        Set-AzHandler 'deployment group show' {
            param($o, $a)
            $null = $a
            if ($o.ContainsKey('--query')) {
                if ($global:AzlArmState.Existing) { return $global:AzlArmState.Existing }
                return (New-AzFailure 3 $script:Notfound)
            }
            '{"properties":{"provisioningState":"' + $global:AzlArmState.Result + '","error":{"message":"the validator reported an error"}}}'
        }
        Set-AzHandler 'deployment group create' { $global:AzlArmState.Created = $true; $global:AzlArmState.Settings = $global:AzlArmState.AfterCreate }
    }
    AfterAll { Remove-Variable -Name AzlArmState -Scope Global -ErrorAction SilentlyContinue }

    It 'validates the parameters, then submits the Validate with the template, the parameter file and the names of the toolkit' {
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $order = @($global:AzlFake.Calls | Where-Object { $_.Command -in 'deployment group validate', 'deployment group create' } | ForEach-Object Command)
        $order | Should -Be @('deployment group validate', 'deployment group create')
        $create = (Get-AzCall 'deployment group create')[0]
        $create.Options['--name'][0] | Should -Match '^azl-validate-[0-9a-f]{12}$'
        $create.Options['--resource-group'] | Should -Be 'rg-iic-azl-01'
        $create.Options['--subscription'] | Should -Be $script:Sub
        $create.Options.ContainsKey('--no-wait') | Should -BeTrue
        $create.Options['--template-uri'][0] | Should -Be ((Get-AzlArmTemplateCatalog).templates['create-cluster'].uri)
        $file = $create.Options['--parameters'][0].Substring(1)
        $parameters = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters
        $parameters.deploymentMode.value | Should -Be 'Validate'
        $parameters.clusterName.value | Should -Be 'iic-clus01'
        $parameters.localAdminPassword.reference.secretName | Should -Be 'local-admin-password'
        $parameters.localAdminPassword.reference.keyVault.id | Should -Be "/subscriptions/$($script:Sub)/resourceGroups/rg-iic-mgmt-01/providers/Microsoft.KeyVault/vaults/kv-iic-mgmt-01"
        (Get-Content -LiteralPath $file -Raw) | Should -Not -Match 'password"\s*:\s*\{\s*"value"\s*:\s*"[^"]'
    }

    It 'runs the pre-flight but submits nothing under -WhatIf' {
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ ReportDirectory = (Join-Path $TestDrive 'report') } -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'deployment group validate').Count | Should -Be 1
        (Get-AzCall 'deployment group create').Count | Should -Be 0
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'refuses a Deploy until the instance validated, then submits it with deploymentMode Deploy' {
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ Mode = 'Deploy'; ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'No successful validation'
        (Get-AzCall 'deployment group create').Count | Should -Be 0
        $global:AzlArmState.Settings = Get-SettingsJson 'Success' 'NotStarted'
        $global:AzlArmState.AfterCreate = Get-SettingsJson 'Success' 'Success'
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ Mode = 'Deploy'; ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $create = (Get-AzCall 'deployment group create')[0]
        $create.Options['--name'][0] | Should -Match '^azl-deploy-[0-9a-f]{12}$'
        ((Get-Content -LiteralPath $create.Options['--parameters'][0].Substring(1) -Raw | ConvertFrom-Json).parameters.deploymentMode.value) | Should -Be 'Deploy'
    }

    It 'ends with exit code 1 and the reason when the deployment fails' {
        $global:AzlArmState.Result = 'Failed'
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'the validator reported an error'
    }

    It 'ends with exit code 1 and submits nothing when the pre-flight fails' {
        $global:AzlArmState.Validate = 'fail'
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'pre-flight'
        (Get-AzCall 'deployment group create').Count | Should -Be 0
    }

    It 'refuses Validate on an instance in a failed state, unless -AllowRevalidate' {
        $global:AzlArmState.Settings = Get-SettingsJson 'Error' 'Failed' 'Failed'
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 1
        (Get-AzCall 'deployment group create').Count | Should -Be 0
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ AllowRevalidate = $true; ReportDirectory = (Join-Path $TestDrive 'report') }
        (Get-AzCall 'deployment group create').Count | Should -Be 1
    }

    It 'attaches to a deployment that is running, and does not submit a deployment that Succeeded again' {
        $global:AzlArmState.Existing = 'Running'
        $global:AzlArmState.Settings = Get-SettingsJson 'Success' 'NotStarted'
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'deployment group create').Count | Should -Be 0
        $global:AzlArmState.Existing = 'Succeeded'
        (Invoke-AzTool $script:Arm (New-ArmFile) @{ ReportDirectory = (Join-Path $TestDrive 'report') }).ExitCode | Should -Be 0
        (Get-AzCall 'deployment group create').Count | Should -Be 0
    }

    It 'resubmits a failed Deploy only with -Resume' {
        $global:AzlArmState.Existing = 'Failed'
        $global:AzlArmState.Settings = Get-SettingsJson 'Success' 'Failed'
        $global:AzlArmState.AfterCreate = Get-SettingsJson 'Success' 'Success'
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ Mode = 'Deploy'; ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Resume'
        (Get-AzCall 'deployment group create').Count | Should -Be 0
        $r = Invoke-AzTool $script:Arm (New-ArmFile) @{ Mode = 'Deploy'; Resume = $true; ReportDirectory = (Join-Path $TestDrive 'report') }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'deployment group create').Count | Should -Be 1
    }

    It 'stops with exit code 2 and sends nothing to Azure for a missing value, a secret that is not a Key Vault reference, or the other identity' {
        (Invoke-AzTool $script:Arm (New-ArmFile -Edit { param($i) $i.cluster.Remove('name') })).ExitCode | Should -Be 2
        (Invoke-AzTool $script:Arm (New-ArmFile -Edit { param($i) $i.identity.local_admin.password = 'env://AZL_TEST_LOCAL_ADMIN' })).ExitCode | Should -Be 2
        (Invoke-AzTool $script:Arm (New-ArmFile) @{ ExpectedIdentity = 'local_identity' }).ExitCode | Should -Be 2
        @(Get-AzWriteCall).Count | Should -Be 0
        @($global:AzlFake.Calls | Where-Object Command -Like 'deployment*').Count | Should -Be 0
    }

    It 'stops with exit code 1 for another tenant, no sign-in or no az, before it submits anything' {
        Set-AzSignIn ([guid]::NewGuid().ToString()) $global:AzlTestSubscription
        (Invoke-AzTool $script:Arm (New-ArmFile)).ExitCode | Should -Be 1
        Set-AzHandler 'account show' { New-AzFailure 1 'Please run az login to setup account.' }
        (Invoke-AzTool $script:Arm (New-ArmFile)).ExitCode | Should -Be 1
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        (Invoke-AzTool $script:Arm (New-ArmFile)).ExitCode | Should -Be 1
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'is called by the task of each identity, which refuses the other identity with exit code 2' {
        $r = Invoke-AzTool $script:ArmAd (New-ArmFile -Identity local_identity)
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'active_directory'
        $r = Invoke-AzTool $script:ArmLocal (New-ArmFile -Identity active_directory)
        $r.ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
        $r = Invoke-AzTool $script:ArmAd (New-ArmFile -Identity active_directory) @{ ReportDirectory = (Join-Path $TestDrive 'report') } -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'deployment group validate').Count | Should -Be 1
        (Get-AzCall 'deployment group create').Count | Should -Be 0
        $r = Invoke-AzTool $script:ArmLocal (New-ArmFile -Identity local_identity) @{ ReportDirectory = (Join-Path $TestDrive 'report') } -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'deployment group validate')[-1].Options['--template-uri'][0] | Should -Match 'create-adless-cluster'
    }
}

Describe 'Test-AzureLocalClusterDeployment.azcli.ps1' {
    BeforeEach {
        Reset-AzFake
        Set-AzSignIn $global:AzlTestTenant $global:AzlTestSubscription
        Mock az { & $global:AzlFakeDispatch $args }
        $global:AzlArmState = @{ Settings = (Get-SettingsJson 'Success' 'Success'); Arc = 'Connected'; Cluster = 'Succeeded' }
        Set-AzHandler 'stack-hci cluster list' { '[{"name":"iic-clus01","provisioningState":"' + $global:AzlArmState.Cluster + '","status":"ConnectedRecently"}]' }
        Set-AzHandler 'rest' { $global:AzlArmState.Settings }
        Set-AzHandler 'connectedmachine show' { '{"name":"x","status":"' + $global:AzlArmState.Arc + '"}' }
    }
    AfterAll { Remove-Variable -Name AzlArmState -Scope Global -ErrorAction SilentlyContinue }

    It 'passes when the instance, its deployment and every Arc machine are fine, and changes nothing' {
        $r = Invoke-AzTool $script:Check (New-ArmFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-AzCall 'stack-hci cluster list')[0].Options['--resource-group'] | Should -Be 'rg-iic-azl-01'
        (Get-AzCall 'rest')[0].Options['--url'][0] | Should -Match '/clusters/iic-clus01/deploymentSettings/default\?api-version='
        @(Get-AzCall 'connectedmachine show').Count | Should -Be 2
        @(Get-AzWriteCall).Count | Should -Be 0
    }

    It 'runs no check under -WhatIf' {
        $r = Invoke-AzTool $script:Check (New-ArmFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlFake.Calls.Count | Should -Be 0
    }

    It 'ends with exit code 1 for an unfinished deployment, an instance that is not Succeeded and a machine that is not Connected' {
        $global:AzlArmState.Settings = Get-SettingsJson 'Success' 'InProgress'
        (Invoke-AzTool $script:Check (New-ArmFile)).ExitCode | Should -Be 1
        $global:AzlArmState.Settings = Get-SettingsJson 'Success' 'Success'
        $global:AzlArmState.Cluster = 'Failed'
        (Invoke-AzTool $script:Check (New-ArmFile)).ExitCode | Should -Be 1
        $global:AzlArmState.Cluster = 'Succeeded'
        $global:AzlArmState.Arc = 'Expired'
        (Invoke-AzTool $script:Check (New-ArmFile)).ExitCode | Should -Be 1
    }

    It 'stops with exit code 2 for a file without a cluster name and for the other identity, and with exit code 1 for another tenant or no az' {
        (Invoke-AzTool $script:Check (New-ArmFile -Edit { param($i) $i.cluster.Remove('name') })).ExitCode | Should -Be 2
        (Invoke-AzTool $script:CheckAd (New-ArmFile -Identity local_identity)).ExitCode | Should -Be 2
        (Invoke-AzTool $script:CheckLocal (New-ArmFile -Identity active_directory)).ExitCode | Should -Be 2
        $global:AzlFake.Calls.Count | Should -Be 0
        (Invoke-AzTool $script:CheckAd (New-ArmFile -Identity active_directory)).ExitCode | Should -Be 0
        (Invoke-AzTool $script:CheckLocal (New-ArmFile -Identity local_identity)).ExitCode | Should -Be 0
        Set-AzSignIn ([guid]::NewGuid().ToString()) $global:AzlTestSubscription
        (Invoke-AzTool $script:Check (New-ArmFile)).ExitCode | Should -Be 1
        Set-AzHandler 'account show' { New-AzFailure 1 'Please run az login to setup account.' }
        (Invoke-AzTool $script:Check (New-ArmFile)).ExitCode | Should -Be 1
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        (Invoke-AzTool $script:Check (New-ArmFile)).ExitCode | Should -Be 1
    }
}
