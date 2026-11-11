#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (Azure management infrastructure), manual deployment, task 10: Deploy-KeyVaults.ps1 creates the Key Vaults of key_vaults and reports which secrets the
# keyvault:// references of the file still lack. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run; the secret
# names are made up and no secret value exists anywhere in the test.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/KeyVaults.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-04-azure-management-infrastructure', '02-manual-deployment', 'task-10-key-vault', 'powershell', 'Deploy-KeyVaults.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzKeyVault { [CmdletBinding()] param([string]$VaultName, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzKeyVault { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$Location, [string]$SubscriptionId, [string]$Sku, [switch]$EnablePurgeProtection, [hashtable]$Tag) }
    function Get-AzKeyVaultSecret { [CmdletBinding()] param([string]$VaultName, [string]$Name) }

    $global:AzlKvTestTenant = [guid]::NewGuid().ToString()
    $global:AzlKvTestSub = [guid]::NewGuid().ToString()
    $global:AzlKvTestSub2 = [guid]::NewGuid().ToString()

    function New-Vault([string]$Name, [string]$Sub = $global:AzlKvTestSub, [string]$Group = 'rg-mgmt-01') {
        $v = [ordered]@{ name = $Name; resource_group = $Group; purpose = 'management' }
        if ($Sub) { $v.subscription_id = $Sub }
        $v
    }
    function New-InfraFile {
        param([object]$Vaults = @((New-Vault 'kv-mgmt-01'), (New-Vault 'kv-deploy-01' $global:AzlKvTestSub2 'rg-deploy-01')), [object]$TenantId = $global:AzlKvTestTenant, [string]$Location = 'eastus',
            [string]$EnvironmentClass = '', [object]$Tags = $null, [switch]$NoReferences)
        $doc = [ordered]@{ azure = [ordered]@{} }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Location) { $doc.azure.location = $Location }
        if ($EnvironmentClass) { $doc.scenario = [ordered]@{ environment_class = $EnvironmentClass } }
        if ($Tags) { $doc.tags = $Tags }
        if ($null -ne $Vaults) { $doc.key_vaults = @($Vaults) }
        if (-not $NoReferences) {
            $doc.identity = [ordered]@{
                local_admin = [ordered]@{ username = 'azl-admin'; password = 'keyvault://kv-mgmt-01/local-admin-password' }
                active_directory = [ordered]@{ lcm_user = [ordered]@{ username = 'lcm-azl'; password = 'keyvault://kv-mgmt-01/lcm-password' }; domain_join_account = [ordered]@{ username = 'svc-join'; password = 'keyvault://kv-deploy-01/join-password' } }
            }
            $doc.operations = [ordered]@{ notifications = [ordered]@{ teams_webhook = 'keyvault://kv-other-01/webhook-url' } }
        }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Vault([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['SecretsMissing'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Deploy-KeyVaults.ps1' {
    AfterAll {
        Remove-Variable -Name AzlKvTestTenant, AzlKvTestSub, AzlKvTestSub2 -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlKvTestTenant } } }
        Mock Get-AzKeyVault { $null }
        Mock New-AzKeyVault { [pscustomobject]@{ VaultName = $Name } }
        Mock Get-AzKeyVaultSecret { @([pscustomobject]@{ Name = 'local-admin-password' }, [pscustomobject]@{ Name = 'lcm-password' }, [pscustomobject]@{ Name = 'join-password' }) }
    }

    Context 'creating the vaults (happy path)' {
        It 'creates each vault: Standard, in its subscription and resource group and the region of the file, with purge protection' {
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.Created | Should -Be 2
            Should -Invoke New-AzKeyVault -Times 1 -Exactly -ParameterFilter { $Name -eq 'kv-mgmt-01' -and $ResourceGroupName -eq 'rg-mgmt-01' -and $SubscriptionId -eq $global:AzlKvTestSub -and $Location -eq 'eastus' -and $Sku -eq 'Standard' -and $EnablePurgeProtection }
            Should -Invoke New-AzKeyVault -Times 1 -Exactly -ParameterFilter { $Name -eq 'kv-deploy-01' -and $ResourceGroupName -eq 'rg-deploy-01' -and $SubscriptionId -eq $global:AzlKvTestSub2 }
        }

        It 'does not switch the session subscription: it passes the subscription to the cmdlets' {
            (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Set-AzContext'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'asks for no access policy and no SKU other than Standard (Azure RBAC is the default of the cmdlet)' {
            $text = Get-Content -LiteralPath $script:Script -Raw
            $text | Should -Not -Match 'Set-AzKeyVaultAccessPolicy|DisableRbacAuthorization|Premium'
        }

        It 'puts the file-level tags on the vaults it creates' {
            $null = Invoke-Vault (New-InfraFile -Tags ([ordered]@{ environment = 'lab'; owner = 'team' }))
            Should -Invoke New-AzKeyVault -Times 2 -Exactly -ParameterFilter { $Tag -and $Tag['environment'] -eq 'lab' -and $Tag['owner'] -eq 'team' }
        }

        It 'sends no tags when the file has none' {
            $null = Invoke-Vault (New-InfraFile)
            Should -Invoke New-AzKeyVault -Times 2 -Exactly -ParameterFilter { -not $Tag }
        }

        It 'purge protection follows scenario.environment_class: <Class> is <Expected>' -ForEach @(
            @{ Class = ''; Expected = 'on' }, @{ Class = 'production'; Expected = 'on' }, @{ Class = 'dmz'; Expected = 'on' },
            @{ Class = 'lab'; Expected = 'off' }, @{ Class = 'test'; Expected = 'off' }, @{ Class = 'dev'; Expected = 'off' }, @{ Class = 'LAB'; Expected = 'off' }
        ) {
            $r = Invoke-Vault (New-InfraFile -EnvironmentClass $Class)
            $r.ExitCode | Should -Be 0
            if ($Expected -eq 'on') { Should -Invoke New-AzKeyVault -Times 2 -Exactly -ParameterFilter { $EnablePurgeProtection } }
            else { Should -Invoke New-AzKeyVault -Times 2 -Exactly -ParameterFilter { -not $EnablePurgeProtection } }
        }

        It 'treats a not-found error from the lookup as "no vault yet"' {
            Mock Get-AzKeyVault { throw 'The vault could not be found (404 NotFound).' }
            (Invoke-Vault (New-InfraFile)).Result.Created | Should -Be 2
        }
    }

    Context 'the vault already exists (idempotent)' {
        BeforeEach {
            Mock Get-AzKeyVault { [pscustomobject]@{ VaultName = $VaultName; EnableRbacAuthorization = $true; EnableSoftDelete = $true } }
        }

        It 'creates nothing and says so' {
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Result.Created | Should -Be 0
            $r.Result.AlreadyExists | Should -Be 2
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
            $r.Text | Should -Match 'nothing changed'
        }

        It 'reports a vault that uses access policies, and changes nothing' {
            Mock Get-AzKeyVault { [pscustomobject]@{ VaultName = $VaultName; EnableRbacAuthorization = $false; EnableSoftDelete = $true } }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 0
            ($r.Result.Vaults | Select-Object -First 1).Detail | Should -Match 'access policies'
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
        }

        It 'creates only the vault that is missing' {
            Mock Get-AzKeyVault { if ($VaultName -eq 'kv-mgmt-01') { [pscustomobject]@{ VaultName = $VaultName; EnableRbacAuthorization = $true } } }
            $r = Invoke-Vault (New-InfraFile)
            $r.Result.Created | Should -Be 1
            $r.Result.AlreadyExists | Should -Be 1
            Should -Invoke New-AzKeyVault -Times 1 -Exactly -ParameterFilter { $Name -eq 'kv-deploy-01' }
        }
    }

    Context 'the secrets the file refers to (names only; nothing is written or read)' {
        It 'reports a secret that exists as Present and one that does not as Missing, with a warning' {
            Mock Get-AzKeyVaultSecret { @([pscustomobject]@{ Name = 'local-admin-password' }) }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 0
            ($r.Result.Secrets | Where-Object Secret -EQ 'local-admin-password').Status | Should -Be 'Present'
            ($r.Result.Secrets | Where-Object Secret -EQ 'lcm-password').Status | Should -Be 'Missing'
            ($r.Result.Secrets | Where-Object Secret -EQ 'join-password').Status | Should -Be 'Missing'
            $r.Result.SecretsMissing | Should -Be 2
            $r.Result.SecretsPresent | Should -Be 1
            $r.Text | Should -Match "secret 'lcm-password' is referenced by the file and does not exist"
        }

        It 'lists the secrets of each vault once, with no -Name, so no secret value is read' {
            $null = Invoke-Vault (New-InfraFile)
            Should -Invoke Get-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter { $VaultName -eq 'kv-mgmt-01' -and -not $Name }
            Should -Invoke Get-AzKeyVaultSecret -Times 1 -Exactly -ParameterFilter { $VaultName -eq 'kv-deploy-01' -and -not $Name }
        }

        It 'compares secret names without regard to case' {
            Mock Get-AzKeyVaultSecret { @([pscustomobject]@{ Name = 'LOCAL-ADMIN-PASSWORD' }, [pscustomobject]@{ Name = 'lcm-password' }, [pscustomobject]@{ Name = 'join-password' }) }
            (Invoke-Vault (New-InfraFile)).Result.SecretsMissing | Should -Be 0
        }

        It 'reports a reference to a vault that is not in key_vaults as NotManaged and does not look in it' {
            $r = Invoke-Vault (New-InfraFile)
            ($r.Result.Secrets | Where-Object Secret -EQ 'webhook-url').Status | Should -Be 'NotManaged'
            Should -Invoke Get-AzKeyVaultSecret -Times 0 -Exactly -ParameterFilter { $VaultName -eq 'kv-other-01' }
            $r.Text | Should -Match "'kv-other-01', which is not in key_vaults"
        }

        It 'reports the secrets as Unchecked, not as an error, when the list is forbidden' {
            Mock Get-AzKeyVaultSecret { throw 'Operation returned an invalid status code ''Forbidden''' }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 0
            @($r.Result.Secrets | Where-Object Status -EQ 'Unchecked').Count | Should -Be 3
            $r.Text | Should -Match 'no permission to list the secrets'
        }

        It 'does not check the secrets of a vault that could not be created' {
            Mock New-AzKeyVault { if ($Name -eq 'kv-mgmt-01') { throw 'VaultAlreadyExists' } else { [pscustomobject]@{ VaultName = $Name } } }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke Get-AzKeyVaultSecret -Times 0 -Exactly -ParameterFilter { $VaultName -eq 'kv-mgmt-01' }
            ($r.Result.Secrets | Where-Object Secret -EQ 'lcm-password').Status | Should -Be 'Unchecked'
        }

        It 'does not check the secrets of a vault that is only planned under -WhatIf' {
            $r = Invoke-Vault (New-InfraFile) -DryRun
            Should -Invoke Get-AzKeyVaultSecret -Times 0 -Exactly
            @($r.Result.Secrets | Where-Object Status -EQ 'Unchecked').Count | Should -Be 3
        }

        It 'works on a file with no references at all' {
            $r = Invoke-Vault (New-InfraFile -NoReferences)
            $r.ExitCode | Should -Be 0
            @($r.Result.Secrets).Count | Should -Be 0
        }

        It 'never writes or prompts for a secret' {
            $text = Get-Content -LiteralPath $script:Script -Raw
            $text | Should -Not -Match 'Set-AzKeyVaultSecret\s+-|Read-Host|-AsPlainText|SecretValue'
        }
    }

    Context '-WhatIf' {
        It 'plans the vaults and creates none' {
            $r = Invoke-Vault (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Planned | Should -Be 2
            $r.Result.Created | Should -Be 0
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
            $r.Text | Should -Match 'would be created'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'kv.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile) -LogPath $log -WhatIf 6>$null 3>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be created'
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without key_vaults' {
            $r = Invoke-Vault (New-InfraFile -Vaults $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'key_vaults is empty'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Vault (New-InfraFile -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a missing azure.location' {
            $r = Invoke-Vault (New-InfraFile -Location '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.location is missing'
        }

        It 'refuses a vault name Key Vault does not accept: <_>' -ForEach 'ab', '1-starts-with-digit', 'ends-with-hyphen-', 'two--hyphens', 'has_underscore', ('k' * 25) {
            $r = Invoke-Vault (New-InfraFile -Vaults @(, (New-Vault $_)))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not a valid Key Vault name'
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
        }

        It 'refuses a vault with no name' {
            $r = Invoke-Vault (New-InfraFile -Vaults @(, ([ordered]@{ resource_group = 'rg'; subscription_id = $global:AzlKvTestSub })))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'has no name'
        }

        It 'refuses a vault with no subscription id, a bad one, or the all-zero placeholder' {
            foreach ($sub in '', 'not-a-guid', [guid]::Empty.ToString()) {
                $r = Invoke-Vault (New-InfraFile -Vaults @(, (New-Vault 'kv-mgmt-01' $sub)))
                $r.ExitCode | Should -Be 2
                $r.Text | Should -Match 'subscription_id'
            }
        }

        It 'refuses a vault with no resource group' {
            $r = Invoke-Vault (New-InfraFile -Vaults @(, (New-Vault 'kv-mgmt-01' $global:AzlKvTestSub '')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'resource_group is missing'
        }

        It 'refuses the same vault twice, whatever the case' {
            $r = Invoke-Vault (New-InfraFile -Vaults @((New-Vault 'kv-mgmt-01'), (New-Vault 'KV-MGMT-01')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Vault (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
        }

        It 'reports a vault that cannot be created, still creates the other, and exits 1' {
            Mock New-AzKeyVault { if ($Name -eq 'kv-mgmt-01') { throw 'VaultAlreadyExists: the vault name is in use' } else { [pscustomobject]@{ VaultName = $Name } } }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Created | Should -Be 1
            $r.Result.Failed | Should -Be 1
            ($r.Result.Vaults | Where-Object Action -EQ 'Failed').Detail | Should -Match 'VaultAlreadyExists'
        }

        It 'says which task creates a resource group that is missing' {
            Mock New-AzKeyVault { throw "ResourceGroupNotFound: Resource group 'rg-mgmt-01' could not be found." }
            $r = Invoke-Vault (New-InfraFile -Vaults @(, (New-Vault 'kv-mgmt-01')))
            $r.ExitCode | Should -Be 1
            ($r.Result.Vaults | Select-Object -First 1).Detail | Should -Match 'Create it first'
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzKeyVault { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Vault (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 2
            Should -Invoke New-AzKeyVault -Times 0 -Exactly
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads its values through the toolkit loader, never variables.yml, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_KeyVaults_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.location', 'scenario.environment_class', 'key_vaults[].name', 'key_vaults[].subscription_id', 'key_vaults[].resource_group', 'key_vaults[].purpose') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
            @($registry | Where-Object Path -EQ 'tags').Count | Should -BeGreaterOrEqual 1
        }
    }
}
