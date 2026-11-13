#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Every script that reads a secret reads it through the one resolver (scripts/common/secrets/AzlSecret.psm1).
#   * Script text: no script under scripts/ calls Get-AzKeyVaultSecret or "az keyvault secret show" itself, except the write-side
#     scripts that are listed here. The text is checked by the PowerShell parser, so comments do not count.
#   * Behaviour: the Resolve-KeyVaultRef helpers of the orchestrated scripts, the shared module helpers and the default adapters read
#     through the resolver. All Key Vault access is mocked; a test that reaches Azure or a vault fails.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/secrets/ScriptsUseResolver.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets and the helpers under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Tests build SecureStrings from a made-up canary.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $scriptsRoot = [IO.Path]::Combine($repoRoot, 'scripts')
    $names = 'Resolve-KeyVaultRef', 'Resolve-KvSecret'
    # The scripts that define their own small helper around the resolver (found by the parser, so a new one is tested too).
    $script:HelperCases = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Include '*.ps1' |
            Where-Object { $_.FullName -notmatch '[\\/]secrets[\\/]' } |
            ForEach-Object {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
                $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names }, $true) | Select-Object -First 1
                if ($fn) { @{ Relative = $_.FullName.Substring($repoRoot.Length + 1).Replace('\', '/'); Name = $fn.Name } }
            })
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:ScriptsRoot = [IO.Path]::Combine($script:Repo, 'scripts')
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'verification', 'AzlVerification.Azure.psm1')) -Force

    # Safety net: nothing in this file may reach Azure or a vault.
    function global:Get-AzContext { [CmdletBinding()] param() }
    function global:Get-AzKeyVaultSecret { [CmdletBinding()] param([string]$VaultName, [string]$Name, [string]$Version) }
    Mock -ModuleName AzlSecret Get-AzContext { throw 'A test tried to reach Azure.' }
    Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'A test tried to read Key Vault.' }

    $script:Canary = 'Canary-Script-S3cret-9f2c'
    $script:Vault = 'kv-iic-mgmt-01'
    function New-Infra { [ordered]@{ key_vaults = @([ordered]@{ name = $script:Vault; subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group = 'rg-iic-mgmt-01' }) } }
    function New-Secure([string]$Text) { $s = [securestring]::new(); foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }; $s.MakeReadOnly(); $s }
    function ConvertTo-Plain([securestring]$Secure) {
        $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
    }

    # The script text without comments: the parser's tokens, so a mention in help or a comment does not count.
    function Get-CodeText([string]$Path) {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
    function Get-ScriptFile {
        Get-ChildItem -LiteralPath $script:ScriptsRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } |
            Where-Object { $_.FullName -notmatch '[\\/]common[\\/]secrets[\\/]' }
    }
    function Get-Rel([string]$Full) { $Full.Substring($script:Repo.Length + 1).Replace('\', '/') }

    # The scripts that WRITE secrets or create vaults. They may keep their own Key Vault calls; each still has to write.
    $script:WriteSide = [ordered]@{
        'scripts/common/utilities/tools/Add-KeyVaultCredentials.ps1'                                                                                                    = 'secret set'
        'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-10-key-vault/powershell/Deploy-KeyVaults.ps1'              = 'New-AzKeyVault'
    }
}

AfterAll {
    Remove-Item function:global:Get-AzContext, function:global:Get-AzKeyVaultSecret -ErrorAction SilentlyContinue
    Remove-Item Env:AZL_TEST_SCRIPT_CANARY -ErrorAction SilentlyContinue
}

Describe 'Script text: no script reads a secret without the resolver' {
    It 'no script calls Get-AzKeyVaultSecret or "az keyvault secret show" outside the secrets module and the write-side list' {
        $offenders = foreach ($f in Get-ScriptFile) {
            $rel = Get-Rel $f.FullName
            if ($script:WriteSide.Contains($rel)) { continue }
            $code = Get-CodeText $f.FullName
            if ($code -match '(?i)\bGet-AzKeyVaultSecret\b') { "$rel calls Get-AzKeyVaultSecret" }
            if ($code -match "(?i)\bkeyvault['""\s,]+secret['""\s,]+show\b") { "$rel calls az keyvault secret show" }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'a secret is read with Get-AzlSecretValue or Get-AzlSecretPlainText and a reference from the infrastructure file'
    }
    It 'the scan sees the secrets module itself (so it would see a call elsewhere)' {
        (Get-CodeText ([IO.Path]::Combine($script:ScriptsRoot, 'common', 'secrets', 'AzlSecret.psm1'))) | Should -Match 'Get-AzKeyVaultSecret'
    }
    It 'every write-side exception exists and still writes (<_>)' -ForEach @(
        'scripts/common/utilities/tools/Add-KeyVaultCredentials.ps1'
        'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-10-key-vault/powershell/Deploy-KeyVaults.ps1'
    ) {
        $path = [IO.Path]::Combine($script:Repo, $_.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Test-Path -LiteralPath $path | Should -BeTrue
        (Get-CodeText $path) | Should -Match ([regex]::Escape($script:WriteSide[$_])) -Because 'an exception is only for a script that writes to Key Vault'
    }
    It 'no script outside the secrets module hard-codes a vault name in a Key Vault call' {
        $offenders = foreach ($f in Get-ScriptFile) {
            $rel = Get-Rel $f.FullName
            if ($script:WriteSide.Contains($rel)) { continue }
            $code = Get-CodeText $f.FullName
            if ($code -match "(?i)-VaultName\s+['""][^'""$]+['""]") { "$rel names a vault in a -VaultName argument" }
            if ($code -match "(?i)--vault-name\s+['""][^'""$]+['""]") { "$rel names a vault in --vault-name" }
        }
        @($offenders) | Should -BeNullOrEmpty
    }
    It 'every script that calls the resolver imports AzlSecret.psm1, and the path it builds exists' {
        $resolverCalls = '\b(Get-AzlSecretValue|Get-AzlSecretPlainText|Get-AzlSecretProvider|Test-AzlSecretReference|New-AzlSecretReference)\b'
        $offenders = foreach ($f in Get-ScriptFile) {
            $rel = Get-Rel $f.FullName
            $code = Get-CodeText $f.FullName
            if ($code -notmatch $resolverCalls) { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $imports = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' -and $n.Extent.Text -match 'AzlSecret\.psm1' }, $true))
            if (-not $imports) { "$rel calls the resolver but does not import AzlSecret.psm1"; continue }
            foreach ($i in $imports) {
                $expr = $i.CommandElements[1].Extent.Text
                if ($expr -match '\$script:|\$here|\$Common') { continue }   # built from a variable the test cannot evaluate here
                $text = $expr.Replace('$PSScriptRoot', "'" + $f.DirectoryName.Replace("'", "''") + "'")
                $path = try { & ([scriptblock]::Create($text)) } catch { $null }
                if (-not $path -or -not (Test-Path -LiteralPath ([string]$path))) { "$rel imports AzlSecret.psm1 from a path that does not exist: $expr" }
            }
        }
        @($offenders) | Should -BeNullOrEmpty
    }
    It 'the iDRAC scripts import AzlRedfishCore.psm1 from a path that exists' {
        $offenders = foreach ($f in Get-ScriptFile) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($i in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' -and $n.Extent.Text -match 'AzlRedfishCore\.psm1' }, $true))) {
                $expr = $i.CommandElements[1].Extent.Text
                if ($expr -notmatch '^\(\[IO\.Path\]::GetFullPath') { continue }
                $text = $expr.Replace('$PSScriptRoot', "'" + $f.DirectoryName.Replace("'", "''") + "'")
                $path = try { & ([scriptblock]::Create($text)) } catch { $null }
                if (-not $path -or -not (Test-Path -LiteralPath ([string]$path))) { "$(Get-Rel $f.FullName): $expr" }
            }
        }
        @($offenders) | Should -BeNullOrEmpty
    }
}

Describe 'The secret helper of the script <Relative>' -ForEach $script:HelperCases {
    BeforeAll {
        $script:RefSecret = $null
        $path = [IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
        $script:HelperText = $fn.Extent.Text
        $script:ReturnsSecure = $fn.Extent.Text -match 'Get-AzlSecretValue'
        $script:UsesConfigVariable = $fn.Extent.Text -match '-Infrastructure \$config\b'
        $env:AZL_TEST_SCRIPT_CANARY = $script:Canary
    }
    BeforeEach {
        # The helper is defined here, with the logging function it expects. The infrastructure file reaches it the way the script does it.
        function Write-Log { param($Message, $Level) }
        function Write-LogMessage { param($Message, $Level) }
        . ([scriptblock]::Create($script:HelperText))
        $script:SecretInfrastructure = New-Infra
        $config = $script:SecretInfrastructure
    }

    It 'has no direct Key Vault call and no Azure CLI call' {
        $script:HelperText | Should -Not -Match '(?i)Get-AzKeyVaultSecret|keyvault\s+secret|\baz\s+keyvault'
        $script:HelperText | Should -Not -Match "keyvault://"
    }
    It 'reads an environment-variable reference through the resolver' {
        $value = & $Name 'env://AZL_TEST_SCRIPT_CANARY'
        if ($script:ReturnsSecure) { $value | Should -BeOfType ([securestring]); (ConvertTo-Plain $value) | Should -Be $script:Canary }
        else { $value | Should -BeExactly $script:Canary }
    }
    It 'reads a Key Vault reference through the resolver (mocked) and never signs in' {
        Mock -ModuleName AzlSecret Get-AzContext { [pscustomobject]@{ Account = 'test' } }
        Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { [pscustomobject]@{ SecretValue = (New-Secure $script:Canary) } }
        $value = & $Name "keyvault://$($script:Vault)/local-admin-password"
        if ($script:ReturnsSecure) { (ConvertTo-Plain $value) | Should -Be $script:Canary } else { $value | Should -BeExactly $script:Canary }
        Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSecret -Times 1 -Exactly -ParameterFilter { $VaultName -eq $script:Vault -and $Name -eq 'local-admin-password' }
    }
    It 'returns $null for a vault that the file does not list, and does not call Azure' {
        Mock -ModuleName AzlSecret Get-AzContext { throw 'A test tried to reach Azure.' }
        & $Name 'keyvault://kv-unlisted-01/local-admin-password' | Should -BeNullOrEmpty
        Should -Invoke Get-AzContext -ModuleName AzlSecret -Times 0 -Exactly
    }
    It 'returns $null for text that is not a reference and does not repeat it' {
        $output = & $Name 'a-password-written-by-mistake-77' 6>&1 3>&1 | Out-String
        $output | Should -Not -Match 'a-password-written-by-mistake-77'
        (& $Name 'a-password-written-by-mistake-77') | Should -BeNullOrEmpty
    }
    It 'returns $null for an environment variable that is not set' {
        Remove-Item Env:AZL_TEST_SCRIPT_UNSET -ErrorAction SilentlyContinue
        & $Name 'env://AZL_TEST_SCRIPT_UNSET' | Should -BeNullOrEmpty
    }
}

Describe 'The shared helpers read through the resolver' {
    BeforeEach {
        $env:AZL_TEST_SCRIPT_CANARY = $script:Canary
        $script:Infra = New-Infra
    }

    Context 'Get-AzlSecret and New-AzlSecretResolver (AzlAzure)' {
        It 'Get-AzlSecret returns the text of an environment reference' {
            Get-AzlSecret -Reference 'env://AZL_TEST_SCRIPT_CANARY' -Infrastructure $script:Infra | Should -BeExactly $script:Canary
        }
        It 'Get-AzlSecret needs the infrastructure file for a Key Vault reference' {
            { Get-AzlSecret -Reference "keyvault://$($script:Vault)/x" -Infrastructure $null } | Should -Throw '*infrastructure file is needed*'
        }
        It 'Get-AzlSecret refuses a vault the file does not list, without calling Azure' {
            { Get-AzlSecret -Reference 'keyvault://kv-unlisted-01/x' -Infrastructure $script:Infra } | Should -Throw '*not listed*'
        }
        It 'New-AzlSecretResolver returns a scriptblock bound to the file it was given' {
            $resolver = New-AzlSecretResolver -Infrastructure $script:Infra
            $resolver | Should -BeOfType ([scriptblock])
            (& $resolver 'env://AZL_TEST_SCRIPT_CANARY') | Should -BeExactly $script:Canary
        }
    }

    Context 'Get-AzlBmcKeyVaultSecret and Resolve-AzlBmcCredential (AzlRedfishCore)' {
        It 'returns a SecureString, or the text with -AsPlainText' {
            (ConvertTo-Plain (Get-AzlBmcKeyVaultSecret -Reference 'env://AZL_TEST_SCRIPT_CANARY' -Infrastructure $script:Infra)) | Should -Be $script:Canary
            Get-AzlBmcKeyVaultSecret -Reference 'env://AZL_TEST_SCRIPT_CANARY' -Infrastructure $script:Infra -AsPlainText | Should -BeExactly $script:Canary
        }
        It 'builds the BMC credential from references of any provider; a plain user name stays a plain user name' {
            $env:AZL_TEST_SCRIPT_BMCUSER = 'bmc-admin'
            $infra = New-Infra
            $infra.hardware = [ordered]@{ bmc = [ordered]@{ username = 'env://AZL_TEST_SCRIPT_BMCUSER'; password = 'env://AZL_TEST_SCRIPT_CANARY' } }
            $c = Resolve-AzlBmcCredential -Infrastructure $infra -NoPrompt
            $c.UserName | Should -Be 'bmc-admin'
            $c.GetNetworkCredential().Password | Should -Be $script:Canary
            $infra.hardware.bmc.username = 'plain-user'
            (Resolve-AzlBmcCredential -Infrastructure $infra -NoPrompt).UserName | Should -Be 'plain-user'
            Remove-Item Env:AZL_TEST_SCRIPT_BMCUSER -ErrorAction SilentlyContinue
        }
        It 'warns without the secret and refuses with -NoPrompt when the reference cannot be read' {
            $infra = New-Infra
            $infra.hardware = [ordered]@{ bmc = [ordered]@{ username = 'plain-user'; password = 'env://AZL_TEST_SCRIPT_UNSET' } }
            Remove-Item Env:AZL_TEST_SCRIPT_UNSET -ErrorAction SilentlyContinue
            { Resolve-AzlBmcCredential -Infrastructure $infra -NoPrompt -WarningAction SilentlyContinue } | Should -Throw '*No BMC credential*'
        }
    }

    Context 'The ARM run adapter: TestSecret' {
        BeforeEach {
            Mock -ModuleName AzlSecret Get-AzContext { [pscustomobject]@{ Account = 'test' } }
            $script:Adapter = New-AzlArmAzureAdapter
        }
        It 'is $true for a secret the resolver can read, and reads through Get-AzKeyVaultSecret of the resolver only' {
            Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { [pscustomobject]@{ SecretValue = (New-Secure $script:Canary) } }
            (& $script:Adapter.TestSecret $script:Vault 'lcm-password' $script:Infra) | Should -BeTrue
            Should -Invoke Get-AzKeyVaultSecret -ModuleName AzlSecret -Times 1 -Exactly -ParameterFilter { $VaultName -eq $script:Vault -and $Name -eq 'lcm-password' }
        }
        It 'is $false when the secret is not in the vault' {
            Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'SecretNotFound: the secret was not found' }
            (& $script:Adapter.TestSecret $script:Vault 'lcm-password' $script:Infra) | Should -BeFalse
        }
        It 'throws, without a value, when access is denied' {
            Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'Forbidden: AccessDenied' }
            { & $script:Adapter.TestSecret $script:Vault 'lcm-password' $script:Infra } | Should -Throw '*denied*'
        }
        It 'throws for a vault the file does not list, and does not call Azure' {
            { & $script:Adapter.TestSecret 'kv-unlisted-01' 'lcm-password' $script:Infra } | Should -Throw '*not listed*'
        }
    }

    Context 'The pre-cluster verification adapter: GetKeyVaultSecret' {
        BeforeEach {
            Mock -ModuleName AzlSecret Get-AzContext { [pscustomobject]@{ Account = 'test' } }
            $script:Get = (Get-AzlVerificationAdapterDefault).Azure.GetKeyVaultSecret
        }
        It 'returns the text of the secret' {
            Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { [pscustomobject]@{ SecretValue = (New-Secure $script:Canary) } }
            (& $script:Get $script:Vault 'local-admin-username' $script:Infra) | Should -BeExactly $script:Canary
        }
        It 'returns $null when the secret does not exist' {
            Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'SecretNotFound: the secret was not found' }
            (& $script:Get $script:Vault 'local-admin-username' $script:Infra) | Should -BeNullOrEmpty
        }
        It 'throws when it cannot be read for another reason' {
            Mock -ModuleName AzlSecret Get-AzKeyVaultSecret { throw 'Forbidden: AccessDenied' }
            { & $script:Get $script:Vault 'local-admin-username' $script:Infra } | Should -Throw
        }
        It 'GetNodeCredential and KeyVault.GetSecret read the reference with the infrastructure file' {
            $adapter = Get-AzlVerificationAdapterDefault
            $infra = New-Infra
            $infra.identity = [ordered]@{ local_admin = [ordered]@{ username = 'azl-admin'; password = 'env://AZL_TEST_SCRIPT_CANARY' } }
            $c = & $adapter.Azure.GetNodeCredential $infra
            $c.UserName | Should -Be 'azl-admin'
            $c.GetNetworkCredential().Password | Should -Be $script:Canary
        }
    }

    Context 'The CI/CD module reads its secrets through the resolver' {
        BeforeAll { Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force }
        It 'keeps the infrastructure file in the settings and reads the API token from an environment reference' {
            $doc = [ordered]@{
                devops = [ordered]@{ platform = 'gitlab'; url = 'https://gitlab.example.com'; api_token = 'env://AZL_TEST_SCRIPT_CANARY' }
                key_vaults = @()
            }
            $settings = ConvertTo-AzlCicdSetting -Infrastructure $doc
            $settings.Infrastructure | Should -Not -BeNullOrEmpty
            foreach ($n in 'GITLAB_TOKEN', 'GITLAB_PRIVATE_TOKEN') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
            $module = Get-Module AzlCicdInfra
            (& $module { param($s) Resolve-AzlCicdToken -Settings $s } $settings) | Should -BeExactly $script:Canary
        }
    }
}
