#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Secret references in the registry, the schema, the validator and the ARM deployment. The four reference forms are accepted by every
# key of format kv_ref; a literal value is refused; the settings the forms need are checked (AZL-054); the ARM deployment reads its
# secret parameters through the resolver and refuses to hand a non-Key-Vault reference to Azure Resource Manager. No Azure call is made.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/secrets/SecretReferences.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    # Safety net: nothing in this file may reach Key Vault or Azure.
    function global:Get-AzContext { [CmdletBinding()] param() }
    function global:Get-AzKeyVaultSecret { [CmdletBinding()] param([string]$VaultName, [string]$Name, [string]$Version) }
    Mock -ModuleName AzlSecret Get-AzContext { throw 'A test tried to reach Azure.' }
    Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'A test tried to read Key Vault.' }

    $script:Canary = 'Canary-S3cret-ARM-4d81'
    $script:ExamplePath = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $script:Schema = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function Get-FindingFor([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:ExamplePath -Raw) -Ordered
        & $Change $doc
        $file = Join-Path $TestDrive ("case-{0}.yml" -f [guid]::NewGuid())
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        @(Test-AzlInfrastructure -Path $file)
    }
    function Get-RefNode($Node, [string]$Path = '') {
        # Every schema node that is a $ref to kv_ref, with the path where it was found.
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node['$ref'] -eq '#/$defs/kv_ref') { [pscustomobject]@{ Path = $Path; Node = $Node } }
            foreach ($k in $Node.Keys) { if ($k -ne '$defs') { Get-RefNode $Node[$k] "$Path.$k" } }
        }
        elseif ($Node -is [System.Collections.IList]) { for ($i = 0; $i -lt $Node.Count; $i++) { Get-RefNode $Node[$i] "$Path[$i]" } }
    }
}

AfterAll {
    Remove-Item function:global:Get-AzContext, function:global:Get-AzKeyVaultSecret -ErrorAction SilentlyContinue
}

Describe 'The registry' {
    It 'has the secrets key <_>' -ForEach 'secrets.provider', 'secrets.file.directory', 'secrets.command.executable', 'secrets.command.arguments', 'secrets.command.timeout_seconds' {
        $entry = $script:Registry | Where-Object Path -EQ $_
        @($entry).Count | Should -Be 1
        $entry.Node['since'] | Should -Not -BeNullOrEmpty -Because 'every new key carries the schema version that added it, in its description'
    }
    It 'gives secrets.provider the four providers and the default keyvault' {
        $e = $script:Registry | Where-Object Path -EQ 'secrets.provider'
        @($e.Node['enum']) | Should -Be @('keyvault', 'env', 'file', 'command')
        $e.Node['default'] | Should -Be 'keyvault'
    }
    It 'bounds the command timeout and defaults it to 30' {
        $e = $script:Registry | Where-Object Path -EQ 'secrets.command.timeout_seconds'
        $e.Node['default'] | Should -Be 30
        $e.Node['minimum'] | Should -Be 1
        $e.Node['maximum'] | Should -Be 300
    }
    It 'has the kv_ref pattern with all four forms' {
        $p = $script:Schema['$defs']['kv_ref']['pattern']
        foreach ($form in 'keyvault://kv-iic-mgmt-01/x', 'env://AZL_X', 'file://x', 'command://x') { [regex]::IsMatch($form, $p, 'ECMAScript') | Should -BeTrue -Because $form }
    }
}

Describe 'The kv_ref pattern' {
    BeforeAll { $script:Pattern = $script:Schema['$defs']['kv_ref']['pattern'] }

    It 'accepts <Ref>' -ForEach @(
        @{ Ref = 'keyvault://kv-iic-mgmt-01/local-admin-password' }
        @{ Ref = 'env://AZL_LOCAL_ADMIN_PASSWORD' }
        @{ Ref = 'env://_x' }
        @{ Ref = 'file://lcm-password' }
        @{ Ref = 'file://lcm-password.txt' }
        @{ Ref = 'command://lcm-password' }
        @{ Ref = 'command://secret_01.v2' }
    ) { [regex]::IsMatch($Ref, $script:Pattern, 'ECMAScript') | Should -BeTrue }

    It 'rejects <Text>' -ForEach @(
        @{ Text = 'P@ssw0rd-literal-value' }
        @{ Text = '' }
        @{ Text = 'keyvault://kv/x' }
        @{ Text = 'keyvault://kv-iic-mgmt-01' }
        @{ Text = 'env://has-dash' }
        @{ Text = 'env://1x' }
        @{ Text = 'file://../x' }
        @{ Text = 'file://a/b' }
        @{ Text = 'file://a\b' }
        @{ Text = 'file://C:\x.txt' }
        @{ Text = 'file://a..b' }
        @{ Text = 'file://.hidden' }
        @{ Text = 'command://rm -rf /' }
        @{ Text = 'command://a;b' }
        @{ Text = 'file://x.' }
        @{ Text = 'http://example.invalid/x' }
    ) { [regex]::IsMatch($Text, $script:Pattern, 'ECMAScript') | Should -BeFalse }

    It 'is the only pattern of the keys that reference it: no key carries the old Key Vault pattern next to the new one' {
        $nodes = @(Get-RefNode $script:Schema)
        $nodes.Count | Should -BeGreaterThan 15
        $stale = @($nodes | Where-Object { $_.Node.Contains('pattern') -and $_.Node['pattern'] -ne $script:Pattern } | ForEach-Object Path)
        $stale | Should -BeNullOrEmpty
        $json = $script:Schema | ConvertTo-Json -Depth 100
        ([regex]::Matches($json, [regex]::Escape('keyvault://[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]/[A-Za-z0-9-]{1,127}$"'))).Count | Should -Be 0 -Because 'the old pattern must be gone everywhere'
    }
}

Describe 'Validation of the file' {
    It 'accepts a secret key set to <Ref>' -ForEach @(
        @{ Ref = 'env://AZL_LOCAL_ADMIN_PASSWORD' }
        @{ Ref = 'keyvault://kv-iic-mgmt-01/local-admin-password' }
    ) {
        $r = $Ref
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = $r }
        @($f | Where-Object { $_.Severity -eq 'error' -and $_.Path -like 'identity.local_admin*' }) | Should -BeNullOrEmpty
    }
    It 'accepts file:// and command:// when the settings are in the file' {
        $f = Get-FindingFor { param($d)
            $d.identity.local_admin.password = 'file://local-admin-password'
            $d.identity.active_directory.lcm_user.password = 'command://lcm-password'
            $d.secrets = [ordered]@{ file = [ordered]@{ directory = 'C:\ProgramData\iic-secrets' }; command = [ordered]@{ executable = 'iic-secret-tool'; arguments = @('get', '{name}') } }
        }
        @($f | Where-Object Severity -eq 'error') | Should -BeNullOrEmpty
    }
    It 'refuses a literal value where a reference is required, and does not repeat the value' {
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = 'P@ssw0rd-literal-9z' }
        $hit = @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'identity.local_admin.password' })
        $hit.Count | Should -BeGreaterThan 0
        ($f | ForEach-Object { $_.Message }) -join ' ' | Should -Not -Match 'P@ssw0rd-literal-9z'
    }
    It 'refuses a file reference that holds a path' {
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = 'file://C:\Windows\win.ini'; $d.secrets = [ordered]@{ file = [ordered]@{ directory = 'C:\ProgramData\iic-secrets' } } }
        @($f | Where-Object { $_.Id -eq 'SCHEMA' -and $_.Path -eq 'identity.local_admin.password' }).Count | Should -BeGreaterThan 0
    }
    It 'AZL-054 needs secrets.file.directory for a file:// reference' {
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = 'file://local-admin-password' }
        @($f | Where-Object { $_.Id -eq 'AZL-054' -and $_.Message -match 'secrets.file.directory' }).Count | Should -Be 1
    }
    It 'AZL-054 needs the executable and {name} in an argument for a command:// reference' {
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = 'command://local-admin-password' }
        @($f | Where-Object { $_.Id -eq 'AZL-054' -and $_.Message -match 'secrets.command.executable' }).Count | Should -Be 1
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = 'command://local-admin-password'; $d.secrets = [ordered]@{ command = [ordered]@{ executable = 'iic-secret-tool'; arguments = @('get', 'fixed') } } }
        @($f | Where-Object Id -eq 'AZL-054').Count | Should -Be 1
    }
    It 'AZL-001 still needs a Key Vault reference to name a listed vault' {
        $f = Get-FindingFor { param($d) $d.identity.local_admin.password = 'keyvault://kv-unlisted-01/local-admin-password' }
        $f.Id | Should -Contain 'AZL-001'
    }
    It 'refuses an unknown provider in secrets.provider and an unknown key in secrets' {
        (Get-FindingFor { param($d) $d.secrets = [ordered]@{ provider = 'registry' } }).Id | Should -Contain 'SCHEMA'
        (Get-FindingFor { param($d) $d.secrets = [ordered]@{ vault = 'x' } }).Id | Should -Contain 'SCHEMA'
    }
}

Describe 'The ARM deployment and the providers' {
    BeforeAll {
        $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
        $script:HandoffFile = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'handoff.v2.json')
        . ([IO.Path]::Combine($repo, 'tests', 'arm-deployment', 'ArmDeploymentRun.Helpers.ps1'))
        $script:TemplateFile = Join-Path $TestDrive 'template.json'
        '{ "parameters": {}, "resources": [] }' | Set-Content -LiteralPath $script:TemplateFile
        Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
        function Get-Pre($Result, [string]$Name) { @($Result.Preconditions | Where-Object { $_.name -eq $Name }) }
        # The run's adapter members that read secrets, wired to the real resolver (everything else stays a fake).
        $script:ResolverMembers = @{
            GetSecret           = { param($Reference, $Infrastructure) Get-AzlSecretPlainText -Reference $Reference -Infrastructure $Infrastructure }
            TestSecretReference = { param($Reference, $Infrastructure) Test-AzlSecretReference -Reference $Reference -Infrastructure $Infrastructure -Detailed }
        }
        function Get-EnvInfra {
            $infra = Get-TestInfra
            $infra.identity.local_admin.password = 'env://AZL_TEST_LOCAL_ADMIN'
            $infra.identity.active_directory.lcm_user.password = 'env://AZL_TEST_LCM'
            $infra
        }
    }
    BeforeEach { $env:AZL_TEST_LCM = 'Canary-Lcm-0b7e' }
    AfterEach { Remove-Item Env:AZL_TEST_LOCAL_ADMIN, Env:AZL_TEST_LCM -ErrorAction SilentlyContinue }

    Context 'the parameter file' {
        BeforeAll {
            $script:Set = New-AzlArmParameterSet -Infrastructure (Get-EnvInfra) -Mode Validate -AllowUnresolvedSanLun
            $script:KvSet = New-AzlArmParameterSet -Infrastructure (Get-TestInfra) -Mode Validate -AllowUnresolvedSanLun
        }
        It 'keeps the reference, whatever the provider, in the parameter set' {
            $script:Set.Parameters.localAdminPassword.KeyVault | Should -Be 'env://AZL_TEST_LOCAL_ADMIN'
        }
        It 'Placeholder mode writes null for a secret of any provider and never a value' {
            $env:AZL_TEST_LOCAL_ADMIN = $script:Canary
            $json = ConvertTo-AzlArmParameterFile -ParameterSet $script:Set -Infrastructure (Get-EnvInfra)
            $json | Should -Not -Match $script:Canary
            (ConvertFrom-Json $json).parameters.localAdminPassword.value | Should -BeNullOrEmpty
        }
        It 'KeyVaultReference mode still hands ARM a Key Vault reference for a keyvault:// secret, unchanged' {
            $o = ConvertTo-AzlArmParameterFile -ParameterSet $script:KvSet -Infrastructure (Get-TestInfra) -SecretMode KeyVaultReference | ConvertFrom-Json
            $o.parameters.localAdminPassword.reference.keyVault.id | Should -BeLike '*/providers/Microsoft.KeyVault/vaults/kv-iic-mgmt-01'
            $o.parameters.localAdminPassword.reference.secretName | Should -Be 'local-admin-password'
        }
        It 'KeyVaultReference mode refuses a secret of another provider, names the parameter and the way out' {
            $failure = try { ConvertTo-AzlArmParameterFile -ParameterSet $script:Set -Infrastructure (Get-EnvInfra) -SecretMode KeyVaultReference; $null } catch { $_.Exception.Message }
            $failure | Should -Match 'localAdminPassword'
            $failure | Should -Match 'env'
            $failure | Should -Match 'Placeholder'
        }
    }

    Context 'the default adapter' {
        It 'GetSecret and TestSecretReference are members, and read through the resolver for any provider' {
            $a = New-AzlArmAzureAdapter
            $a.Contains('GetSecret') | Should -BeTrue
            $a.Contains('TestSecretReference') | Should -BeTrue
            $env:AZL_TEST_LOCAL_ADMIN = $script:Canary
            $infra = Get-EnvInfra
            (& $a.GetSecret 'env://AZL_TEST_LOCAL_ADMIN' $infra) | Should -BeExactly $script:Canary
            $d = & $a.TestSecretReference 'env://AZL_TEST_LOCAL_ADMIN' $infra
            $d.Resolvable | Should -BeTrue
            ($d | ConvertTo-Json) | Should -Not -Match $script:Canary
        }
    }

    Context 'the precondition KeyVaultSecrets' {
        It 'passes for a secret in an environment variable that is set' {
            $env:AZL_TEST_LOCAL_ADMIN = $script:Canary
            $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-EnvInfra) -Mode Plan -Override $script:ResolverMembers
            (Get-Pre $r KeyVaultSecrets).result | Should -Be 'Passed'
        }
        It 'fails, naming the parameter and the reference but not a value, when the variable is not set' {
            $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-EnvInfra) -Mode Plan -Override $script:ResolverMembers
            $c = Get-Pre $r KeyVaultSecrets
            $c.result | Should -Be 'Failed'
            $c.evidence | Should -Match 'localAdminPassword'
            $c.evidence | Should -Match 'AZL_TEST_LOCAL_ADMIN'
        }
        It 'fails for text that is not a reference' {
            $infra = Get-EnvInfra
            $infra.identity.local_admin.password = 'a-literal-password'
            $r = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -Override $script:ResolverMembers
            $c = Get-Pre $r KeyVaultSecrets
            $c.result | Should -Be 'Failed'
            $c.evidence | Should -Not -Match 'a-literal-password'
        }
        It 'with secretMode KeyVaultReference fails a secret of another provider with the Azure Resource Manager reason; a keyvault:// reference still passes' {
            $env:AZL_TEST_LOCAL_ADMIN = $script:Canary
            $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-EnvInfra) -Mode Plan -Override $script:ResolverMembers -Settings @{ secretMode = 'KeyVaultReference' }
            $c = Get-Pre $r KeyVaultSecrets
            $c.result | Should -Be 'Failed'
            $c.evidence | Should -Match 'localAdminPassword'
            $c.evidence | Should -Match 'Azure Resource Manager can read only keyvault:// references'
            $c.evidence | Should -Not -Match $script:Canary
            $kv = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-TestInfra) -Mode Plan -Override $script:ResolverMembers -Settings @{ secretMode = 'KeyVaultReference' }
            (Get-Pre $kv KeyVaultSecrets).result | Should -Be 'Passed'
        }
        It 'in the default Placeholder mode the same file passes' {
            $env:AZL_TEST_LOCAL_ADMIN = $script:Canary
            $r = Invoke-TestRun -World (Get-FakeWorld) -Infra (Get-EnvInfra) -Mode Plan -Override $script:ResolverMembers -Settings @{ secretMode = 'Placeholder' }
            (Get-Pre $r KeyVaultSecrets).result | Should -Be 'Passed'
        }
        It 'the setting secretMode is Placeholder by default, is case-insensitive, and refuses another value' {
            (Get-AzlArmRunSetting).secretMode | Should -Be 'Placeholder'
            (Get-AzlArmRunSetting -Settings @{ secretMode = 'keyvaultreference' }).secretMode | Should -Be 'KeyVaultReference'
            { Get-AzlArmRunSetting -Settings @{ secretMode = 'Inline' } } | Should -Throw '*secretMode must be Placeholder or KeyVaultReference*'
        }
        It 'does not read Key Vault for a secret of another provider' {
            $env:AZL_TEST_LOCAL_ADMIN = $script:Canary
            $asked = [System.Collections.Generic.List[string]]::new()
            $override = $script:ResolverMembers.Clone()
            $override.TestSecret = { param($Vault, $Secret) $null = $Vault; $asked.Add($Secret); $true }.GetNewClosure()
            $infra = Get-EnvInfra
            $infra.identity.active_directory.lcm_user.password = 'keyvault://kv-iic-mgmt-01/lcm-password'
            $null = Invoke-TestRun -World (Get-FakeWorld) -Infra $infra -Mode Plan -Override $override
            $asked | Should -Not -Contain 'local-admin-password'
            $asked | Should -Contain 'lcm-password' -Because 'a Key Vault reference still goes through the Key Vault check'
        }
    }

    Context 'Validate reads the secrets through the resolver' {
        BeforeAll {
            $script:Steps = @(Get-TestStep '0.1' 'Validate environment' 'Success' 0 @() '2026-11-07T12:10:00Z')
            $script:Passed = Get-TestState -Validation 'Succeeded' -ValidationSteps $script:Steps
            $script:Busy = Get-TestState -Validation 'InProgress' -ValidationSteps @(Get-TestStep '0.1' 'Validate environment' 'InProgress' 0 @() '2026-11-07T12:01:00Z')
            $script:ArmRunning = [pscustomobject]@{ ProvisioningState = 'Running'; Error = ''; Timestamp = '' }
            $script:ArmDone = [pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' }
        }
        It 'hands the resolver the reference AND the infrastructure file, resolves an env:// secret, and scrubs it from every file written' {
            $env:AZL_TEST_LOCAL_ADMIN = $script:Canary
            $w = Get-FakeWorld
            $w.After['validate'] = @($script:Busy, $script:Passed); $w.ArmAfter['validate'] = @($script:ArmRunning, $script:ArmDone)
            $seen = [System.Collections.Generic.List[object]]::new()
            $override = @{
                GetSecret = {
                    param($Reference, $Infrastructure)
                    $seen.Add([pscustomobject]@{ Reference = $Reference; HasInfrastructure = ($Infrastructure -is [System.Collections.IDictionary]) })
                    Get-AzlSecretPlainText -Reference $Reference -Infrastructure $Infrastructure
                }.GetNewClosure()
                TestSecretReference = $script:ResolverMembers.TestSecretReference
            }
            # The fake world's Submit resolves every secret parameter through the SecretResolver that the run passes, as the real one does.
            $r = Invoke-TestRun -World $w -Infra (Get-EnvInfra) -Mode Validate -Override $override
            $r.ExitCode | Should -Be 0
            $w.SubmitCalls[0].SecretKeys | Should -Contain 'localAdminPassword'
            @($seen | Where-Object { $_.Reference -eq 'env://AZL_TEST_LOCAL_ADMIN' }).Count | Should -BeGreaterThan 0
            @($seen | Where-Object { -not $_.HasInfrastructure }).Count | Should -Be 0
            foreach ($f in Get-ChildItem -LiteralPath $r.ReportDirectory -File) { (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match $script:Canary }
        }
    }
}

Describe 'Key Vault stays the only provider that is handed to Azure Resource Manager' {
    It 'the module text says so where the parameter file is built' {
        $t = Get-Content -LiteralPath ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Raw
        $t | Should -Match 'ARM reads only Key Vault'
        $t | Should -Match 'Placeholder'
    }
}
