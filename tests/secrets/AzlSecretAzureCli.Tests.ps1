#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# AzlSecretAzureCli.psm1 reads a keyvault:// reference for an Azure CLI script with "az keyvault secret show" and any other reference with the resolver.
# The tests give it a script block in place of az: no Azure, no vault and no sign-in is used. The secret is a canary made up at run time.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/secrets/AzlSecretAzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The fake az sets the exit code a native command sets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'secrets', 'AzlSecretAzureCli.psm1')) -Force
    $script:Canary = 'Canary-' + [guid]::NewGuid().ToString('N')
    $env:AZL_TEST_AZCLI_SECRET = $script:Canary
    $script:Infra = @{ key_vaults = @(@{ name = 'kv-iic-mgmt-01' }) }
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    # The fake az: records the call and answers like az does.
    $script:Calls.Clear()
    function Get-Thrown([scriptblock]$Block) { try { & $Block } catch { $_ } }
}

AfterAll { Remove-Item Env:AZL_TEST_AZCLI_SECRET -ErrorAction SilentlyContinue }

Describe 'Get-AzlSecretPlainTextAzureCli' {
    BeforeEach {
        $script:Calls.Clear()
        $canary = $script:Canary
        $calls = $script:Calls
        $script:GoodAz = { param([string[]]$AzArguments) $calls.Add($AzArguments -join ' '); $global:LASTEXITCODE = 0; $canary + "`n" }.GetNewClosure()
        $script:FailingAz = { param([string[]]$AzArguments) $calls.Add($AzArguments -join ' '); $global:LASTEXITCODE = 3; 'ERROR: (SecretNotFound) not found' }.GetNewClosure()
        $script:EmptyAz = { param([string[]]$AzArguments) $calls.Add($AzArguments -join ' '); $global:LASTEXITCODE = 0; '' }.GetNewClosure()
    }

    It 'reads a keyvault:// reference with az keyvault secret show and returns the text without the trailing line break' {
        $value = Get-AzlSecretPlainTextAzureCli -Reference 'keyvault://kv-iic-mgmt-01/vpn-dal-key' -Infrastructure $script:Infra -Az $script:GoodAz
        $value | Should -Be $script:Canary
        $script:Calls | Should -HaveCount 1
        $script:Calls[0] | Should -Be 'keyvault secret show --vault-name kv-iic-mgmt-01 --name vpn-dal-key --query value --output tsv'
    }

    It 'passes the version of a reference that has one' {
        $null = Get-AzlSecretPlainTextAzureCli -Reference 'keyvault://kv-iic-mgmt-01/vpn-dal-key/0123456789abcdef0123456789abcdef' -Infrastructure $script:Infra -Az $script:GoodAz
        $script:Calls[0] | Should -Be 'keyvault secret show --vault-name kv-iic-mgmt-01 --name vpn-dal-key --version 0123456789abcdef0123456789abcdef --query value --output tsv'
    }

    It 'reads an env:// reference through the resolver, without az' {
        (Get-AzlSecretPlainTextAzureCli -Reference 'env://AZL_TEST_AZCLI_SECRET' -Infrastructure $script:Infra -Az $script:GoodAz) | Should -Be $script:Canary
        $script:Calls | Should -HaveCount 0
    }

    It 'refuses a vault that is not listed under key_vaults with exit 2, before az is started' {
        $err = Get-Thrown { Get-AzlSecretPlainTextAzureCli -Reference 'keyvault://kv-iic-other-01/x' -Infrastructure $script:Infra -Az $script:GoodAz }
        $err.Exception.Data['AzlSecretError'] | Should -Be 'VaultNotListed'
        $err.Exception.Data['AzlExit'] | Should -Be 2
        $script:Calls | Should -HaveCount 0
    }

    It 'refuses a text that is not a reference, without echoing it' {
        $err = Get-Thrown { Get-AzlSecretPlainTextAzureCli -Reference 'not-a-reference-value' -Infrastructure $script:Infra -Az $script:GoodAz }
        $err.Exception.Data['AzlSecretError'] | Should -Be 'InvalidReference'
        $err.Exception.Message | Should -Not -Match 'not-a-reference-value'
        $script:Calls | Should -HaveCount 0
    }

    It 'refuses a keyvault:// reference of the wrong shape' {
        $err = Get-Thrown { Get-AzlSecretPlainTextAzureCli -Reference 'keyvault://kv-iic-mgmt-01/bad_name' -Infrastructure $script:Infra -Az $script:GoodAz }
        $err.Exception.Data['AzlExit'] | Should -Be 2
    }

    It 'reports a failed az call without the output of az and with exit 1' {
        $err = Get-Thrown { Get-AzlSecretPlainTextAzureCli -Reference 'keyvault://kv-iic-mgmt-01/vpn-dal-key' -Infrastructure $script:Infra -Az $script:FailingAz }
        $err.Exception.Data['AzlSecretError'] | Should -Be 'KeyVaultError'
        $err.Exception.Data['AzlExit'] | Should -Be 1
        $err.Exception.Message | Should -Match 'exit code 3'
        $err.Exception.Message | Should -Not -Match 'SecretNotFound'
    }

    It 'reports an empty secret' {
        $err = Get-Thrown { Get-AzlSecretPlainTextAzureCli -Reference 'keyvault://kv-iic-mgmt-01/vpn-dal-key' -Infrastructure $script:Infra -Az $script:EmptyAz }
        $err.Exception.Data['AzlSecretError'] | Should -Be 'EmptySecret'
    }

    It 'never writes the value to any stream' {
        $all = Get-AzlSecretPlainTextAzureCli -Reference 'keyvault://kv-iic-mgmt-01/vpn-dal-key' -Infrastructure $script:Infra -Az $script:GoodAz -Verbose 6>&1 3>&1 4>&1 5>&1 2>&1
        @($all | Where-Object { $_ -isnot [string] }) | Should -BeNullOrEmpty
    }
}
