#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 10: Deploy-KeyVaults.azcli.ps1 creates the Key Vaults of key_vaults with az commands and
# checks the secrets the file refers to. "az" is mocked: no Azure, no tenant and no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/KeyVaults.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-10-key-vault', 'azurecli', 'Deploy-KeyVaults.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlKvSub = [guid]::NewGuid().ToString()
    $global:AzlKvSub2 = [guid]::NewGuid().ToString()

    function New-Vault([string]$Name, [string]$Sub = $global:AzlKvSub, [string]$Group = 'rg-iic-mgmt-01') {
        $v = [ordered]@{ name = $Name; resource_group = $Group; purpose = 'management' }
        if ($Sub) { $v.subscription_id = $Sub }
        $v
    }
    function New-InfraFile {
        param([object]$Vaults = @((New-Vault 'kv-iic-mgmt-01'), (New-Vault 'kv-iic-deploy-01' $global:AzlKvSub2 'rg-iic-deploy-01')), [object]$TenantId = $global:AzlFakeTenant, [string]$Location = 'eastus',
            [string]$EnvironmentClass = '', [object]$Tags = $null, [switch]$NoReferences)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Location) { $doc.azure.location = $Location }
        if ($EnvironmentClass) { $doc.scenario = [ordered]@{ environment_class = $EnvironmentClass } }
        if ($Tags) { $doc.tags = $Tags }
        if ($null -ne $Vaults) { $doc.key_vaults = @($Vaults) }
        if (-not $NoReferences) {
            $doc.identity = [ordered]@{
                local_admin      = [ordered]@{ username = 'azl-admin'; password = 'keyvault://kv-iic-mgmt-01/local-admin-password' }
                active_directory = [ordered]@{ lcm_user = [ordered]@{ username = 'lcm-azl'; password = 'keyvault://kv-iic-mgmt-01/lcm-password' }; domain_join_account = [ordered]@{ username = 'svc-join'; password = 'keyvault://kv-iic-deploy-01/join-password' } }
            }
            $doc.operations = [ordered]@{ notifications = [ordered]@{ teams_webhook = 'keyvault://kv-iic-other-01/webhook-url' } }
        }
        Save-AzInfraFile $doc
    }
    # A vault as az returns it.
    function New-FakeVault([hashtable]$Property = @{}) {
        [ordered]@{ properties = (Set-AzOverride ([ordered]@{ enableRbacAuthorization = $true; enableSoftDelete = $true; softDeleteRetentionInDays = 90; enablePurgeProtection = $true }) $Property) }
    }
}

Describe 'Deploy-KeyVaults.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlKvSub, AzlKvSub2, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        Mock az { Invoke-AzFake $args }
    }

    Context 'creating the vaults (happy path)' {
        It 'creates each vault in the subscription and group of its entry, in azure.location, with Azure RBAC, soft delete and purge protection' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Created | Should -Be 2
            Get-AzCall "keyvault create --name kv-iic-mgmt-01 --resource-group rg-iic-mgmt-01 --location eastus --subscription $($global:AzlKvSub) --sku standard --enable-rbac-authorization true --retention-days 90 --enable-purge-protection true" | Should -HaveCount 1
            Get-AzCall "keyvault create --name kv-iic-deploy-01 --resource-group rg-iic-deploy-01 --location eastus --subscription $($global:AzlKvSub2) --sku standard --enable-rbac-authorization true --retention-days 90 --enable-purge-protection true" | Should -HaveCount 1
        }

        It 'passes soft_delete_retention_days of each entry, and 90 when an entry leaves it out' {
            $a = New-Vault 'kv-iic-mgmt-01'; $a.soft_delete_retention_days = 14
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Vaults @($a, (New-Vault 'kv-iic-deploy-01' $global:AzlKvSub2 'rg-iic-deploy-01')))
            Get-AzCall 'keyvault create --name kv-iic-mgmt-01*--retention-days 14*' | Should -HaveCount 1
            Get-AzCall 'keyvault create --name kv-iic-deploy-01*--retention-days 90*' | Should -HaveCount 1
        }

        It 'leaves purge protection off for lab, test and dev, and on for any other class and for none' -ForEach @(
            @{ Class = 'lab'; On = $false }, @{ Class = 'test'; On = $false }, @{ Class = 'dev'; On = $false }, @{ Class = 'Lab'; On = $false }
            @{ Class = 'production'; On = $true }, @{ Class = 'staging'; On = $true }, @{ Class = ''; On = $true }
        ) {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -EnvironmentClass $Class)
            @(Get-AzCall 'keyvault create*--enable-purge-protection true*').Count | Should -Be $(if ($On) { 2 } else { 0 })
        }

        It 'puts the file-level tags on the vaults' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Get-AzCall 'keyvault create*--tags environment=lab owner=team' | Should -HaveCount 2
        }

        It 'never changes the subscription of the az session' {
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall 'account set*' | Should -BeNullOrEmpty
        }

        It 'says which resource group is missing when a creation fails for that reason' {
            Add-AzRoute 'keyvault create --name kv-iic-mgmt-01*' "ERROR: (ResourceGroupNotFound) Resource group 'rg-iic-mgmt-01' could not be found." 3
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match "resource group 'rg-iic-mgmt-01' does not exist"
            $r.Rows[0].Created | Should -Be 1
        }
    }

    Context 'the vaults already exist (idempotent)' {
        BeforeEach { Add-AzRoute 'keyvault show*' (New-FakeVault) }

        It 'creates nothing and says so' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoReferences)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].AlreadyExists | Should -Be 2
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'Nothing to do'
        }

        It 'reports a vault that differs from what the script creates and leaves it alone' {
            Add-AzRoute 'keyvault show*' (New-FakeVault @{ enableRbacAuthorization = $false; softDeleteRetentionInDays = 30; enablePurgeProtection = $null })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoReferences)
            $r.ExitCode | Should -Be 0
            $detail = $r.Rows[0].Vaults[0].Detail
            $detail | Should -Match 'access policies, not Azure RBAC'
            $detail | Should -Match 'soft delete keeps 30 days, the file says 90'
            $detail | Should -Match 'purge protection is off'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'does not say purge protection is off for a lab vault' {
            Add-AzRoute 'keyvault show*' (New-FakeVault @{ enablePurgeProtection = $null })
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoReferences -EnvironmentClass lab)
            $r.Rows[0].Vaults[0].Detail | Should -BeNullOrEmpty
        }
    }

    Context 'the secrets the file refers to (names only)' {
        BeforeEach { Add-AzRoute 'keyvault show*' (New-FakeVault) }

        It 'reports Present and Missing for the vaults it manages, and NotManaged for another vault' {
            Add-AzRoute 'keyvault secret list --vault-name kv-iic-mgmt-01*' @('local-admin-password')
            Add-AzRoute 'keyvault secret list --vault-name kv-iic-deploy-01*' @('join-password', 'other-secret')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $by = @{}; foreach ($s in $r.Rows[0].Secrets) { $by["$($s.Vault)/$($s.Secret)"] = $s.Status }
            $by['kv-iic-mgmt-01/local-admin-password'] | Should -Be 'Present'
            $by['kv-iic-mgmt-01/lcm-password'] | Should -Be 'Missing'
            $by['kv-iic-deploy-01/join-password'] | Should -Be 'Present'
            $by['kv-iic-other-01/webhook-url'] | Should -Be 'NotManaged'
            $r.Rows[0].SecretsMissing | Should -Be 1
            $r.Text | Should -Match "secret 'lcm-password' is referenced"
        }

        It 'lists names with --query and never reads, sets or shows a secret' {
            Add-AzRoute 'keyvault secret list*' @()
            $null = Invoke-AzCliScript $script:Script (New-InfraFile)
            Get-AzCall 'keyvault secret list --vault-name kv-iic-mgmt-01 --query `[`].name' | Should -HaveCount 1
            Get-AzCall 'keyvault secret show*' | Should -BeNullOrEmpty
            Get-AzCall 'keyvault secret set*' | Should -BeNullOrEmpty
        }

        It 'reports Unchecked when the secrets of a vault cannot be listed' {
            Add-AzRoute 'keyvault secret list*' 'ERROR: (Forbidden) The user does not have secrets list permission on the vault.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0
            @($r.Rows[0].Secrets | Where-Object Status -EQ 'Unchecked').Count | Should -Be 3
            $r.Text | Should -Match 'no permission to list'
        }

        It 'reports Unchecked, and lists nothing, for a vault that was not created' {
            Add-AzNotFound 'keyvault show*'
            Add-AzRoute 'keyvault create*' 'ERROR: (VaultAlreadyExists) The vault name is already in use.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @($r.Rows[0].Secrets | Where-Object Status -EQ 'Unchecked').Count | Should -Be 3
            Get-AzCall 'keyvault secret list*' | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf' {
        It 'plans every vault and writes nothing to Azure' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Planned | Should -Be 2
            Get-AzWriteCall | Should -BeNullOrEmpty
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'kv.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, no az call)' {
        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a missing tenant'; Tenant = $null; Vaults = $null; Location = 'eastus'; Match = 'azure.tenant_id' }
            @{ Case = 'no vaults'; Tenant = 'default'; Vaults = @(); Location = 'eastus'; Match = 'key_vaults is empty' }
            @{ Case = 'no azure.location'; Tenant = 'default'; Vaults = $null; Location = ''; Match = 'azure.location is missing' }
        ) {
            $tenant = if ($Tenant -eq 'default') { $global:AzlFakeTenant } else { $Tenant }
            $vaults = if ($null -eq $Vaults) { @((New-Vault 'kv-iic-mgmt-01')) } else { $Vaults }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Vaults $vaults -TenantId $tenant -Location $Location)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'a vault with no name'; Vault = @{ name = '' }; Match = 'has no name' }
            @{ Case = 'a name that is too short'; Vault = @{ name = 'kv' }; Match = 'not a valid Key Vault name' }
            @{ Case = 'a name with two hyphens in a row'; Vault = @{ name = 'kv--mgmt' }; Match = 'not a valid Key Vault name' }
            @{ Case = 'a name that starts with a digit'; Vault = @{ name = '1kv-mgmt-01' }; Match = 'not a valid Key Vault name' }
            @{ Case = 'a vault without a subscription'; Vault = @{ subscription_id = '' }; Match = 'subscription_id is missing' }
            @{ Case = 'the all-zero subscription'; Vault = @{ subscription_id = '00000000-0000-0000-0000-000000000000' }; Match = 'all-zero placeholder' }
            @{ Case = 'a vault without a resource group'; Vault = @{ resource_group = '' }; Match = 'resource_group is missing' }
            @{ Case = 'a retention of 6 days'; Vault = @{ soft_delete_retention_days = 6 }; Match = 'from 7 to 90' }
            @{ Case = 'a retention of 91 days'; Vault = @{ soft_delete_retention_days = 91 }; Match = 'from 7 to 90' }
            @{ Case = 'a retention that is not a number'; Vault = @{ soft_delete_retention_days = 'long' }; Match = 'from 7 to 90' }
            @{ Case = 'a retention of 20 digits (too long for an integer)'; Vault = @{ soft_delete_retention_days = '99999999999999999999' }; Match = 'from 7 to 90' }
            @{ Case = 'a resource group with an ampersand'; Vault = @{ resource_group = 'rg&calc' }; Match = "key_vaults resource_group\[0\] holds the value 'rg&calc'" }
        ) {
            $v = Set-AzOverride (New-Vault 'kv-iic-mgmt-01') $Vault
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Vaults @($v))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match $Match
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses an entry that is not a map, with exit code 2 and no az call (it is not skipped)' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Vaults @((New-Vault 'kv-iic-mgmt-01'), 'kv-iic-deploy-01'))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            $r.Text | Should -Match 'entry of key_vaults is not a map'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'refuses the same vault twice' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Vaults @((New-Vault 'kv-iic-mgmt-01'), (New-Vault 'KV-IIC-MGMT-01')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-AzCliScript $script:Script (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when az is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Azure CLI \(az\) was not found'
            $global:AzlFakeCalls | Should -BeNullOrEmpty
        }

        It 'stops when nobody is signed in' {
            Add-AzRoute 'account show*' 'ERROR: Please run ''az login'' to setup account.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'stops when the sign-in is to another tenant' {
            Add-AzRoute 'account show*' ([guid]::NewGuid().ToString())
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Get-AzWriteCall | Should -BeNullOrEmpty
        }

        It 'reports a vault that cannot be created, still creates the other, and exits 1' {
            Add-AzRoute 'keyvault create --name kv-iic-mgmt-01*' 'ERROR: (VaultAlreadyExists) The vault name is already in use.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoReferences)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Failed | Should -Be 1
            $r.Rows[0].Created | Should -Be 1
            $r.Rows[0].Vaults[0].Detail | Should -Match 'VaultAlreadyExists'
        }

        It 'does not hide a read error that is not a not-found' {
            Add-AzRoute 'keyvault show*' 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoReferences)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Failed | Should -Be 2
            Get-AzWriteCall | Should -BeNullOrEmpty
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, holds no GUID, and never sets or shows a secret' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($script:Text, [ref]$tokens, [ref]$null)
            $code = ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
            $code | Should -Not -Match 'Invoke-Az(Json)? keyvault (secret (set|show|delete|purge|backup|restore|recover)|delete|purge)'
        }

        It 'has every parameter registered' {
            $registry = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
            foreach ($p in 'InfrastructureFile', 'LogPath') {
                ($registry -match ('Deploy_KeyVaults_azcli_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')) | Should -BeTrue -Because "$p of the script is in the registry"
            }
        }
    }
}
