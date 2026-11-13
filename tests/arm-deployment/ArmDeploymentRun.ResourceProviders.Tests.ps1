#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The precondition ResourceProviders. The real failure behind it: the run only warned that Microsoft.HybridContainerService was not
# registered ("used by Arc VMs and AKS") and Azure's own validation (step 90 ValidateArcIntegration, check
# AzStackHci_ArcIntegration_MandatoryRPRegistration_Check) then failed on exactly that provider. Microsoft Learn ("Assign required
# permissions for Azure Local deployment") lists 13 providers as required; every one of them must fail the precondition when it is
# not Registered. Registration is opt in (-RegisterResourceProviders / deployment.register_resource_providers) and never happens
# in Plan or with WhatIf. All with a fake adapter and a fake clock: no Azure, no node.

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    $script:TemplateFile = Join-Path $TestDrive 'template.json'
    '{ "parameters": {}, "resources": [] }' | Set-Content -LiteralPath $script:TemplateFile
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
    function Get-Pre($Result, [string]$Name) { @($Result.Preconditions | Where-Object { $_.name -eq $Name }) }

    # The 13 providers of the Microsoft Learn page, as written there.
    $script:Mandatory = @(
        'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureStackHCI',
        'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector',
        'Microsoft.HybridContainerService', 'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault'
    )

    function Get-ProviderFake {
        <# A subscription whose providers are in the given states. A 'Registering' provider becomes Registered after -ReadsToRegister reads. #>
        param([hashtable]$State = @{}, [int]$ReadsToRegister = 2, [string[]]$RegisterFails = @(), [string[]]$NeverRegisters = @())
        $fake = [pscustomobject]@{ State = $State; Reads = @{}; Requested = [System.Collections.Generic.List[string]]::new() }
        $fake | Add-Member -NotePropertyName Override -NotePropertyValue @{
            GetProviderState = {
                param($Subscription, $Namespace)
                $null = $Subscription
                if (-not $fake.State.ContainsKey($Namespace)) { return 'Registered' }
                if ($fake.State[$Namespace] -eq 'Registering' -and $Namespace -notin $NeverRegisters) {
                    $fake.Reads[$Namespace] = 1 + [int]$(if ($fake.Reads.ContainsKey($Namespace)) { $fake.Reads[$Namespace] } else { 0 })
                    if ($fake.Reads[$Namespace] -ge $ReadsToRegister) { $fake.State[$Namespace] = 'Registered' }
                }
                $fake.State[$Namespace]
            }.GetNewClosure()
            RegisterProvider = {
                param($Subscription, $Namespace)
                $null = $Subscription
                if ($Namespace -in $RegisterFails) { throw "AuthorizationFailed: no permission to register $Namespace" }
                $fake.Requested.Add($Namespace)
                $fake.State[$Namespace] = 'Registering'
            }.GetNewClosure()
        }
        $fake
    }
}

Describe 'The mandatory resource providers (Microsoft Learn)' {
    It 'checks exactly the 13 providers Microsoft lists as required, once each' {
        $seen = [System.Collections.Generic.List[string]]::new()
        $null = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override @{ GetProviderState = { param($Subscription, $Namespace) $null = $Subscription; $seen.Add($Namespace); 'Registered' }.GetNewClosure() }
        @($seen | Sort-Object -Unique) | Should -Be @($script:Mandatory | Sort-Object)
        $seen.Count | Should -Be 13
    }

    It 'passes when every mandatory provider is Registered' {
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan
        (Get-Pre $r ResourceProviders).result | Should -Be 'Passed'
        (Get-Pre $r ResourceProviders).evidence | Should -Match '13 mandatory'
    }

    It '<_> not Registered fails the precondition, names it and gives its exact command' -ForEach @(
        'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureStackHCI',
        'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector',
        'Microsoft.HybridContainerService', 'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault'
    ) {
        $ns = $_
        $fake = Get-ProviderFake -State @{ $ns = 'NotRegistered' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override $fake.Override
        $pre = Get-Pre $r ResourceProviders
        $pre.result | Should -Be 'Failed'
        $pre.evidence | Should -Match ([regex]::Escape($ns))
        $pre.nextAction | Should -Match ([regex]::Escape("Register-AzResourceProvider -ProviderNamespace $ns"))
        $r.ExitCode | Should -Be 1
    }

    It 'the lab failure: Microsoft.HybridContainerService missing is a Failure, no longer a Warning, and names the Azure check' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.HybridContainerService' = 'NotRegistered' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Override $fake.Override
        $pre = Get-Pre $r ResourceProviders
        $pre.result | Should -Be 'Failed'
        $pre.result | Should -Not -Be 'Warning'
        $pre.evidence | Should -Match 'AzStackHci_ArcIntegration_MandatoryRPRegistration_Check'
        $pre.evidence | Should -Match 'ValidateArcIntegration'
        $r.ExitCode | Should -Be 1
        $r.State | Should -Not -Be 'ValidationPassed'
    }

    It 'every missing provider is named, each with its own command' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.HybridContainerService' = 'NotRegistered'; 'Microsoft.Attestation' = 'NotRegistered'; 'Microsoft.Insights' = 'Registering' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Override $fake.Override
        $pre = Get-Pre $r ResourceProviders
        foreach ($ns in 'Microsoft.HybridContainerService', 'Microsoft.Attestation', 'Microsoft.Insights') {
            $pre.evidence | Should -Match ([regex]::Escape($ns))
            $pre.nextAction | Should -Match ([regex]::Escape("Register-AzResourceProvider -ProviderNamespace $ns"))
        }
        $pre.evidence | Should -Not -Match 'Microsoft.KeyVault'
    }

    It 'the failure tells the operator the opt-in switch, and changes nothing in Azure' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.Attestation' = 'NotRegistered' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Override $fake.Override
        (Get-Pre $r ResourceProviders).nextAction | Should -Match '-RegisterResourceProviders'
        $fake.Requested.Count | Should -Be 0
    }
}

Describe 'Opt-in registration (-RegisterResourceProviders / deployment.register_resource_providers)' {
    It 'by default no run ever registers a provider (Plan, Validate, Deploy)' {
        foreach ($mode in 'Plan', 'Validate', 'Deploy') {
            $fake = Get-ProviderFake -State @{ 'Microsoft.HybridContainerService' = 'NotRegistered'; 'Microsoft.Attestation' = 'NotRegistered' }
            $null = Invoke-TestRun -World (Get-FakeWorld) -Mode $mode -Override $fake.Override
            $fake.Requested.Count | Should -Be 0 -Because "Mode $mode without the opt-in"
        }
    }

    It 'the setting defaults to false and is read from the master file key and from the run settings' {
        (Get-AzlArmRunSetting -Infrastructure @{}).registerResourceProviders | Should -BeFalse
        (Get-AzlArmRunSetting -Infrastructure @{ deployment = @{ register_resource_providers = $true } }).registerResourceProviders | Should -BeTrue
        (Get-AzlArmRunSetting -Infrastructure @{} -Settings @{ registerResourceProviders = $true }).registerResourceProviders | Should -BeTrue
        (Get-AzlArmRunSetting -Infrastructure @{ deployment = @{ register_resource_providers = $true } } -Settings @{ registerResourceProviders = $false }).registerResourceProviders | Should -BeFalse
    }

    It 'Validate with the opt-in registers only the missing providers, waits until they are Registered, then passes' {
        $world = Get-FakeWorld
        $fake = Get-ProviderFake -State @{ 'Microsoft.HybridContainerService' = 'NotRegistered'; 'Microsoft.Attestation' = 'NotRegistered' } -ReadsToRegister 3
        $r = Invoke-TestRun -World $world -Mode Validate -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        @($fake.Requested | Sort-Object) | Should -Be @('Microsoft.Attestation', 'Microsoft.HybridContainerService')
        $pre = Get-Pre $r ResourceProviders
        $pre.result | Should -Be 'Passed'
        $pre.evidence | Should -Match 'Registered by this run'
        $pre.evidence | Should -Match 'Microsoft.HybridContainerService'
        $pre.evidence | Should -Not -Match 'Microsoft.KeyVault'
        $world.Clock.Sleeps.Count | Should -BeGreaterThan 0 -Because 'it waited on the (fake) clock for Registered'
        $fake.State['Microsoft.HybridContainerService'] | Should -Be 'Registered'
    }

    It 'the -RegisterResourceProviders switch of the run does the same as the setting' {
        $world = Get-FakeWorld
        $fake = Get-ProviderFake -State @{ 'Microsoft.HybridContainerService' = 'NotRegistered' }
        $dir = Join-Path $TestDrive 'switch-run'
        $r = Invoke-AzlArmDeploymentRun -Infrastructure (Get-TestInfra) -Mode Validate -ReportDirectory $dir -TemplateFile $script:TemplateFile -OsConfigurationReport (Get-TestOsReport -Infra (Get-TestInfra)) -Adapter (Get-FakeAdapter -World $world -Override $fake.Override) -RegisterResourceProviders
        $fake.Requested | Should -Be @('Microsoft.HybridContainerService')
        (Get-Pre $r ResourceProviders).result | Should -Be 'Passed'
    }

    It 'a provider already Registering is waited for, not requested again' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.Insights' = 'Registering'; 'Microsoft.Attestation' = 'NotRegistered' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        $fake.Requested | Should -Be @('Microsoft.Attestation')
        (Get-Pre $r ResourceProviders).result | Should -Be 'Passed'
    }

    It 'Plan never registers, even with the opt-in, and says so' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.HybridContainerService' = 'NotRegistered' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Plan -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        $fake.Requested.Count | Should -Be 0
        (Get-Pre $r ResourceProviders).result | Should -Be 'Failed'
        (Get-Pre $r ResourceProviders).nextAction | Should -Match 'Plan and WhatIf never change Azure'
    }

    It 'WhatIf never registers, even with the opt-in' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.HybridContainerService' = 'NotRegistered' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -DryRun -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        $fake.Requested.Count | Should -Be 0
        (Get-Pre $r ResourceProviders).result | Should -Be 'Failed'
    }

    It 'a provider that never reaches Registered fails after the time limit and names it' {
        $world = Get-FakeWorld
        $fake = Get-ProviderFake -State @{ 'Microsoft.Attestation' = 'NotRegistered' } -NeverRegisters @('Microsoft.Attestation')
        $start = $world.Clock.Time
        $r = Invoke-TestRun -World $world -Mode Validate -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        $pre = Get-Pre $r ResourceProviders
        $pre.result | Should -Be 'Failed'
        $pre.evidence | Should -Match 'not Registered after 15 minutes: Microsoft.Attestation'
        ($world.Clock.Time - $start).TotalMinutes | Should -BeGreaterOrEqual 15
        $r.ExitCode | Should -Be 1
    }

    It 'a refused registration (no permission) fails, names the provider and gives the manual command' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.Attestation' = 'NotRegistered' } -RegisterFails @('Microsoft.Attestation')
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        $pre = Get-Pre $r ResourceProviders
        $pre.result | Should -Be 'Failed'
        $pre.evidence | Should -Match 'Registering Microsoft.Attestation failed'
        $pre.evidence | Should -Match 'AuthorizationFailed'
        $pre.nextAction | Should -Match 'Register-AzResourceProvider -ProviderNamespace Microsoft.Attestation'
    }

    It 'a provider that does not exist in the subscription (NotFound) is not registered and fails' {
        $fake = Get-ProviderFake -State @{ 'Microsoft.Attestation' = 'NotFound' }
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        $fake.Requested.Count | Should -Be 0
        (Get-Pre $r ResourceProviders).result | Should -Be 'Failed'
        (Get-Pre $r ResourceProviders).evidence | Should -Match 'do not exist'
    }

    It 'nothing is registered when everything already is, even with the opt-in' {
        $fake = Get-ProviderFake -State @{}
        $r = Invoke-TestRun -World (Get-FakeWorld) -Mode Validate -Settings @{ registerResourceProviders = $true } -Override $fake.Override
        $fake.Requested.Count | Should -Be 0
        (Get-Pre $r ResourceProviders).result | Should -Be 'Passed'
        (Get-Pre $r ResourceProviders).evidence | Should -Not -Match 'Registered by this run'
    }
}
