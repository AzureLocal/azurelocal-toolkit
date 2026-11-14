#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The values the ARM deployment used to carry in its code (work order of the hard-coded rows): the SBE partner properties and credentials come from the file, the
# deployment name prefix and the waits of the run are settings, and the constants that Microsoft fixes are named. No Azure call is made: Invoke-AzlArm is mocked.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment/ArmDeployment.HardCoded.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock script blocks keep the signature of the real command.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($script:Repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    $script:CompleteSbe = [IO.Path]::Combine($script:Repo, 'tests', 'fixtures', 'sbe', 'hardware.sbe.complete.yml')
    $script:Catalog = Get-AzlArmTemplateCatalog
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    function Get-InfraWithSbe {
        $i = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
        $i.hardware = (ConvertFrom-Yaml -Ordered (Get-Content -LiteralPath $script:CompleteSbe -Raw)).hardware
        $i
    }
}

Describe 'hardware.sbe.partner_properties and partner_credentials reach the ARM parameters' {
    It 'sends the properties as name and value pairs and the credentials as secret names' {
        $i = Get-InfraWithSbe
        $i.hardware.sbe['partner_properties'] = @([ordered]@{ name = 'iic-example-property'; value = 'iic-example-value' }, [ordered]@{ name = 'iic-second-property'; value = 'two' })
        $i.hardware.sbe['partner_credentials'] = @([ordered]@{ secret_name = 'iic-sbe-download-login'; secret = 'keyvault://kv-iic-mgmt-01/sbe-download' }, [ordered]@{ secret_name = 'iic-sbe-second-login'; secret = 'env://IIC_SBE_SECOND' })
        $set = New-AzlArmParameterSet -Infrastructure $i -AllowUnresolvedSanLun -Catalog $script:Catalog
        @($set.Parameters.partnerProperties).Count | Should -Be 2
        $set.Parameters.partnerProperties[0].name | Should -Be 'iic-example-property'
        $set.Parameters.partnerProperties[0].value | Should -Be 'iic-example-value'
        @($set.Parameters.partnerCredentiallist).Count | Should -Be 2
        $set.Parameters.partnerCredentiallist[1].secretName | Should -Be 'iic-sbe-second-login'
        $set.Parameters.partnerCredentiallist[1].secretValue.KeyVault | Should -Be 'env://IIC_SBE_SECOND'
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates[$set.Template.Name].parameters) | Should -BeNullOrEmpty
    }
    It 'sends empty lists when the file names none (as before the keys existed)' {
        $set = New-AzlArmParameterSet -Infrastructure (Get-InfraWithSbe) -AllowUnresolvedSanLun -Catalog $script:Catalog
        @($set.Parameters.partnerProperties).Count | Should -Be 0
        @($set.Parameters.partnerCredentiallist).Count | Should -Be 0
    }
    It 'sends neither list without an SBE version, even when the file names them' {
        $i = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
        $i.hardware.sbe['partner_properties'] = @([ordered]@{ name = 'a'; value = 'b' }, [ordered]@{ name = 'c'; value = 'd' })
        $set = New-AzlArmParameterSet -Infrastructure $i -AllowUnresolvedSanLun -Catalog $script:Catalog
        $set.Parameters.Contains('partnerProperties') | Should -BeFalse
        $set.Parameters.Contains('partnerCredentiallist') | Should -BeFalse
    }
    It 'refuses an entry with no name and one with no secret_name' {
        $i = Get-InfraWithSbe
        $i.hardware.sbe['partner_properties'] = @([ordered]@{ name = ''; value = 'x' }, [ordered]@{ name = 'b'; value = 'y' })
        { New-AzlArmParameterSet -Infrastructure $i -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw '*partner_properties has an entry with no name*'
        $j = Get-InfraWithSbe
        $j.hardware.sbe['partner_credentials'] = @([ordered]@{ secret_name = ' '; secret = 'env://IIC_X' }, [ordered]@{ secret_name = 'b'; secret = 'env://IIC_Y' })
        { New-AzlArmParameterSet -Infrastructure $j -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw '*partner_credentials has an entry with no secret_name*'
    }
    It 'the parameter sources name both keys' {
        $sources = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'azure', 'arm-templates', 'parameter-sources.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 10
        $sources.parameters.partnerProperties.keys | Should -Contain 'hardware.sbe.partner_properties'
        $sources.parameters.partnerCredentiallist.keys | Should -Contain 'hardware.sbe.partner_credentials'
    }
}

Describe 'The run settings that replace the literals of the run' {
    It 'have these defaults' {
        $s = Get-AzlArmRunSetting
        $s.providerRegistrationTimeoutMinutes | Should -Be 15
        $s.providerRegistrationPollSeconds | Should -Be 10
        $s.deploymentNamePrefix | Should -Be 'azl'
        $s.reportDirectoryPrefix | Should -Be 'azl-arm'
        $s.verificationLdapTimeoutSeconds | Should -Be 20
        $s.verificationEndpointTimeoutSeconds | Should -Be 5
        $s.verificationRemoteCallSeconds | Should -Be 180
        $s.verificationSessionOpenSeconds | Should -Be 20
        $s.verificationSessionOperationSeconds | Should -Be 60
        $s.verificationPortTimeoutSeconds | Should -Be 3
        $s.verificationWebTimeoutSeconds | Should -Be 6
        $s.verificationResultFutureToleranceMinutes | Should -Be 5
        @($s.verificationAdvisedFeatures) | Should -Be @('FS-Data-Deduplication', 'RSAT-AD-PowerShell', 'RSAT-Clustering-PowerShell')
    }
    It 'take a value from -Settings' {
        $s = Get-AzlArmRunSetting -Settings @{ providerRegistrationTimeoutMinutes = 30; verificationLdapTimeoutSeconds = 45; deploymentNamePrefix = 'IIC-Prod'; verificationAdvisedFeatures = @('RSAT-AD-PowerShell') }
        $s.providerRegistrationTimeoutMinutes | Should -Be 30
        $s.verificationLdapTimeoutSeconds | Should -Be 45
        $s.deploymentNamePrefix | Should -Be 'iic-prod'
        @($s.verificationAdvisedFeatures) | Should -Be @('RSAT-AD-PowerShell')
    }
    It 'refuse a limit below 1 and a prefix that Azure would not take' {
        { Get-AzlArmRunSetting -Settings @{ providerRegistrationPollSeconds = 0 } } | Should -Throw '*must be 1 or more*'
        { Get-AzlArmRunSetting -Settings @{ verificationRemoteCallSeconds = 0 } } | Should -Throw '*must be 1 or more*'
        { Get-AzlArmRunSetting -Settings @{ deploymentNamePrefix = '1abc' } } | Should -Throw '*deploymentNamePrefix*'
        { Get-AzlArmRunSetting -Settings @{ deploymentNamePrefix = ('a' * 31) } } | Should -Throw '*deploymentNamePrefix*'
        { Get-AzlArmRunSetting -Settings @{ deploymentNamePrefix = 'has space' } } | Should -Throw '*deploymentNamePrefix*'
        { Get-AzlArmRunSetting -Settings @{ reportDirectoryPrefix = 'a/b' } } | Should -Throw '*reportDirectoryPrefix*'
        { Get-AzlArmRunSetting -Settings @{ reportDirectoryPrefix = '..\x' } } | Should -Throw '*reportDirectoryPrefix*'
        (Get-AzlArmRunSetting -Settings @{ reportDirectoryPrefix = 'iic_runs.1' }).reportDirectoryPrefix | Should -Be 'iic_runs.1'
    }
    It 'Get-AzlArmRunSettingValue gives the value of a settings object, else the default, and refuses an unknown name' {
        Get-AzlArmRunSettingValue -Settings ([ordered]@{ verificationWebTimeoutSeconds = 9 }) -Name verificationWebTimeoutSeconds | Should -Be 9
        Get-AzlArmRunSettingValue -Settings ([ordered]@{}) -Name verificationWebTimeoutSeconds | Should -Be 6
        Get-AzlArmRunSettingValue -Settings $null -Name verificationWebTimeoutSeconds | Should -Be 6
        $list = Get-AzlArmRunSettingValue -Settings $null -Name verificationAdvisedFeatures
        @($list).Count | Should -Be 3
        { Get-AzlArmRunSettingValue -Settings $null -Name noSuchSetting } | Should -Throw "*Unknown run setting*"
    }
}

Describe 'The ARM deployment names' {
    BeforeAll {
        $script:Template = [pscustomobject]@{ resources = @([pscustomobject]@{ type = 'microsoft.azurestackhci/clusters/deploymentSettings'; apiVersion = '2026-04-01-preview' }) }
        $script:Resolver = { param($Ref) "value-of-$($Ref.Split('/')[-1])" }
        $script:Set = New-AzlArmParameterSet -Infrastructure (Import-AzlInfrastructure -Path $script:Fixture -SkipValidation) -AllowUnresolvedSanLun -Catalog $script:Catalog -Mode Validate
        $script:Set.Parameters['infraVolLunId'] = 'UID-INFRA'; $script:Set.Parameters['infraPerfLunId'] = 'UID-PERF'
    }
    It 'the default name uses the prefix that is given, azl otherwise' {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { if ($Method -eq 'PUT') { $calls.Add($Path) }; $null }
        $null = Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $script:Resolver -NoWait
        $null = Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $script:Resolver -NoWait -DeploymentNamePrefix 'iic-prod'
        $calls[0] | Should -Match '/deployments/azl-validate-\d{14}$'
        $calls[1] | Should -Match '/deployments/iic-prod-validate-\d{14}$'
    }
    It 'refuses a prefix that is not a valid name part' {
        { Invoke-AzlArmDeployment -ParameterSet $script:Set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $script:Resolver -NoWait -DeploymentNamePrefix 'Bad Prefix' } | Should -Throw
    }
    It 'steps of an earlier run are told apart whatever the prefix was' {
        $hashNow = 'aaaaaaaaaaaa'
        $steps = @(
            [pscustomobject]@{ FullStepIndex = '0.1'; Name = 'Current'; Status = 'Success'; Description = "from corp-validate-$hashNow" }
            [pscustomobject]@{ FullStepIndex = '0.2'; Name = 'Earlier'; Status = 'Error'; Description = 'from corp-validate-bbbbbbbbbbbb' }
            [pscustomobject]@{ FullStepIndex = '0.3'; Name = 'EarlierDefaultPrefix'; Status = 'Error'; Description = 'from azl-deploy-cccccccccccc' }
        )
        $split = Select-AzlArmCurrentStep -Steps $steps -DeploymentName "corp-validate-$hashNow"
        @($split.Current | ForEach-Object Name) | Should -Be @('Current')
        @($split.Ignored | ForEach-Object Name) | Should -Contain 'Earlier'
        @($split.Ignored | ForEach-Object Name) | Should -Contain 'EarlierDefaultPrefix'
    }
}

Describe 'The report folder default is built from a setting' {
    It 'names the folder <temp>/<reportDirectoryPrefix>-<cluster> and no longer holds the literal' {
        $text = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Raw
        $text | Should -Match 'Join-Path \(\[IO\.Path\]::GetTempPath\(\)\) "\$\(\$run\.Settings\.reportDirectoryPrefix\)-\$cluster"'
        $text | Should -Not -Match '"azl-arm-\$cluster"'
    }
}

Describe 'The OS build to solution table has one home' {
    It 'the node checks read the table of the run module' {
        Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'verification', 'AzlVerification.NodeCommon.psm1')) -Force
        $table = @(Get-AzlArmSolutionOsBuild)
        $table.Count | Should -BeGreaterThan 0
        $one = $table[0]
        (ConvertFrom-AzlVerOsBuild $one.OsBuild).Version | Should -Be $one.Solution
        (ConvertFrom-AzlVerOsBuild ($one.OsBuild -replace '^10\.0\.', '')).Version | Should -Be $one.Solution
        ConvertFrom-AzlVerOsBuild '10.0.1.1' | Should -BeNullOrEmpty
        (Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'verification', 'AzlVerification.NodeCommon.psm1')) -Raw) | Should -Not -Match "OsBuild = '10\.0\."
    }
}

Describe 'Constants that Microsoft fixes are named in the code, with their source' {
    BeforeAll { $script:Arm = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Raw }
    It 'the API versions and the catalog are script variables with a comment that says what fixes them' {
        $script:Arm | Should -Match '(?s)# The api-version of the Azure Resource Manager deployments call.*?\r?\n\$script:DeploymentsApiVersion = '
        $script:Arm | Should -Match '(?s)# The api-version of the Microsoft\.AzureStackHCI resources.*?\r?\n\$script:HciApiVersion = '
        $script:Arm | Should -Match '(?m)^# The catalog of Microsoft''s quickstart templates'
    }
    It 'overrideAdapterProperty and the derived override flags are explained where they are set' {
        $script:Arm | Should -Match 'overrideAdapterProperty is always true: Microsoft''s quickstart parameters file sets it true'
        $script:Arm | Should -Match 'overrideVirtualSwitchConfiguration and overrideQosPolicy are not a choice'
    }
}
