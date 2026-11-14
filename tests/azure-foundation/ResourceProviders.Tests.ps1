#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 02 (resource providers): Register-ResourceProviders.ps1 (PowerShell and Azure CLI) and Test-ResourceProviders.ps1 take the subscription from
# infrastructure.yml and the providers from the one list of the toolkit (Get-AzlArmMandatoryProvider). Every Az cmdlet and the az command are mocked:
# no Azure, no tenant and no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ResourceProviders.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Repo = $repo
    $dir = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-02-resource-providers')
    $script:Register = [IO.Path]::Combine($dir, 'task-01-register-resource-providers', 'powershell', 'Register-ResourceProviders.ps1')
    $script:RegisterCli = [IO.Path]::Combine($dir, 'task-01-register-resource-providers', 'azurecli', 'Register-ResourceProviders.azcli.ps1')
    $script:Verify = [IO.Path]::Combine($dir, 'task-02-verify-provider-registration', 'powershell', 'Test-ResourceProviders.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    $script:Providers = @(Get-AzlArmMandatoryProvider)

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Register-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function az { }

    $global:AzlRpTenant = [guid]::NewGuid().ToString()
    $global:AzlRpSubscription = [guid]::NewGuid().ToString()
    $global:AzlRpHome = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object]$Tenant = $global:AzlRpTenant, [object]$Subscription = $global:AzlRpSubscription)
        $azure = [ordered]@{}
        if ($null -ne $Tenant) { $azure.tenant_id = $Tenant }
        if ($null -ne $Subscription) { $azure.subscription_id = $Subscription }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml ([ordered]@{ azure = $azure }))
        $file
    }
    function Reset-State {
        $global:AzlRpState = @{}          # provider -> state returned by the reads; default NotRegistered
        $global:AzlRpReads = @{}          # provider -> how many reads so far
        $global:AzlRpBecomes = @{}        # provider -> read number from which it is Registered (default: never)
        $global:AzlRpRegistered = [System.Collections.Generic.List[string]]::new()
        $global:AzlRpContexts = [System.Collections.Generic.List[string]]::new()
        $global:AzlRpRegisterFails = @()
        $global:AzlRpAzCalls = [System.Collections.Generic.List[string]]::new()
        $global:AzlRpNow = [datetime]'2026-01-01T00:00:00Z'
    }
    function Invoke-Tool([string]$Script, [string]$File, [hashtable]$Extra = @{}, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1 } else { & $Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Provider'] -and -not ($_ -is [string]) -and $_ -isnot [Management.Automation.InformationRecord] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

AfterAll { Remove-Variable -Name AzlRpTenant, AzlRpSubscription, AzlRpHome, AzlRpState, AzlRpReads, AzlRpBecomes, AzlRpRegistered, AzlRpContexts, AzlRpRegisterFails, AzlRpAzCalls, AzlRpNow -Scope Global -ErrorAction SilentlyContinue }

Describe 'the provider list' {
    It 'is the 13 providers of Microsoft Learn, with Microsoft.KeyVault' {
        $script:Providers.Count | Should -Be 13
        $script:Providers | Should -Contain 'Microsoft.KeyVault'
        $script:Providers | Should -Contain 'Microsoft.AzureStackHCI'
    }
}

Describe 'Register-ResourceProviders.ps1' {
    BeforeEach {
        Reset-State
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlRpTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlRpHome } } }
        Mock Set-AzContext { $global:AzlRpContexts.Add($SubscriptionId) }
        Mock Get-AzResourceProvider {
            $global:AzlRpReads[$ProviderNamespace] = 1 + [int]$global:AzlRpReads[$ProviderNamespace]
            $state = if ($global:AzlRpBecomes.ContainsKey($ProviderNamespace) -and $global:AzlRpReads[$ProviderNamespace] -ge $global:AzlRpBecomes[$ProviderNamespace]) { 'Registered' }
            elseif ($global:AzlRpState.ContainsKey($ProviderNamespace)) { $global:AzlRpState[$ProviderNamespace] } else { 'NotRegistered' }
            [pscustomobject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = $state }
        }
        Mock Register-AzResourceProvider {
            if ($global:AzlRpRegisterFails -contains $ProviderNamespace) { throw 'The client does not have authorization to perform action.' }
            $global:AzlRpRegistered.Add($ProviderNamespace)
            [pscustomobject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = 'Registering' }
        }
        Mock Start-Sleep { $global:AzlRpNow = $global:AzlRpNow.AddSeconds($Seconds) }
        Mock Get-Date { $global:AzlRpNow }
    }

    It 'registers every provider of the toolkit list that is not registered, in the subscription of the file' {
        $r = Invoke-Tool $script:Register (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlRpRegistered | Sort-Object) | Should -Be @($script:Providers | Sort-Object)
        $global:AzlRpContexts[0] | Should -Be $global:AzlRpSubscription
    }

    It 'registers nothing and says so when every provider is registered' {
        foreach ($p in $script:Providers) { $global:AzlRpState[$p] = 'Registered' }
        $r = Invoke-Tool $script:Register (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlRpRegistered.Count | Should -Be 0
        $r.Text | Should -Match 'Nothing to do'
        @($r.Rows | Where-Object Action -EQ 'AlreadyRegistered').Count | Should -Be 13
    }

    It 'registers only the providers that are missing' {
        foreach ($p in $script:Providers | Select-Object -Skip 2) { $global:AzlRpState[$p] = 'Registered' }
        $null = Invoke-Tool $script:Register (New-InfraFile)
        @($global:AzlRpRegistered | Sort-Object) | Should -Be @($script:Providers | Select-Object -First 2 | Sort-Object)
    }

    It 'plans and registers nothing under -WhatIf' {
        $r = Invoke-Tool $script:Register (New-InfraFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $global:AzlRpRegistered.Count | Should -Be 0
        @($r.Rows | Where-Object Action -EQ 'WouldRegister').Count | Should -Be 13
    }

    It 'with -Wait polls until the providers it registered report Registered' {
        foreach ($p in $script:Providers) { $global:AzlRpBecomes[$p] = 3 }
        $r = Invoke-Tool $script:Register (New-InfraFile) @{ Wait = $true; PollSeconds = 5 }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Text | Should -Not -Match 'not Registered after'
        Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 5 }
    }

    It 'with -Wait ends with exit code 1 when a provider is still registering after -MaxWaitMinutes' {
        $r = Invoke-Tool $script:Register (New-InfraFile) @{ Wait = $true; MaxWaitMinutes = 1; PollSeconds = 30 }
        $r.ExitCode | Should -Be 1
        @($r.Rows | Where-Object Action -EQ 'TimedOut').Count | Should -Be 13
    }

    It 'goes on with the other providers when one cannot be registered, and ends with exit code 1' {
        $global:AzlRpRegisterFails = @('Microsoft.Attestation')
        $r = Invoke-Tool $script:Register (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $global:AzlRpRegistered.Count | Should -Be 12
        @($r.Rows | Where-Object Action -EQ 'Failed').Provider | Should -Be 'Microsoft.Attestation'
    }

    It 'puts the original subscription back' {
        $null = Invoke-Tool $script:Register (New-InfraFile)
        $global:AzlRpContexts[-1] | Should -Be $global:AzlRpHome
    }

    It 'registers nothing when the sign-in is to another tenant, and when there is no sign-in' {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() }; Subscription = $null } }
        (Invoke-Tool $script:Register (New-InfraFile)).ExitCode | Should -Be 1
        Mock Get-AzContext { $null }
        $r = Invoke-Tool $script:Register (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Connect-AzAccount'
        $global:AzlRpRegistered.Count | Should -Be 0
    }

    It 'stops with exit code 2 before any call when the file has no usable tenant or subscription' {
        (Invoke-Tool $script:Register (New-InfraFile -Tenant $null)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Register (New-InfraFile -Subscription $null)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Register (New-InfraFile -Subscription '00000000-0000-0000-0000-000000000000')).ExitCode | Should -Be 2
        (Invoke-Tool $script:Register (New-InfraFile -Subscription 'not-a-guid')).ExitCode | Should -Be 2
        Should -Invoke Get-AzResourceProvider -Times 0 -Exactly
    }

    It 'carries the standard header, takes the list from the toolkit and has no provider name in its code' {
        foreach ($path in $script:Register, $script:RegisterCli, $script:Verify) {
            $text = Get-Content -LiteralPath $path -Raw
            $text | Should -Match '(?m)^#Requires -Version 7\.0'
            $text | Should -Match 'Set-StrictMode -Version Latest'
            $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $text | Should -Match 'Get-AzlArmMandatoryProvider'
            $text | Should -Not -Match 'Read-Host|Get-Credential'
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match "Microsoft\.(HybridCompute|KeyVault|Storage|Insights)"
        }
    }

    It 'has every parameter registered' {
        $registry = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
        foreach ($p in 'InfrastructureFile', 'Wait', 'MaxWaitMinutes', 'PollSeconds', 'LogPath') {
            $registry | Should -Match ('Register_ResourceProviders_ps1_generated:[\s\S]{0,3000}?\b' + $p + ':')
        }
    }
}

Describe 'Register-ResourceProviders.azcli.ps1' {
    BeforeEach {
        Reset-State
        Mock Start-Sleep { $global:AzlRpNow = $global:AzlRpNow.AddSeconds($Seconds) }
        Mock Get-Date { $global:AzlRpNow }
        Mock az {
            $global:LASTEXITCODE = 0
            $line = $args -join ' '
            $global:AzlRpAzCalls.Add($line)
            if ($line -like 'account show*') { return @($global:AzlRpTenant, $global:AzlRpHome) }
            if ($line -like 'account set*') { return }
            if ($line -like 'provider show*') {
                $name = $args[3]
                $global:AzlRpReads[$name] = 1 + [int]$global:AzlRpReads[$name]
                if ($global:AzlRpBecomes.ContainsKey($name) -and $global:AzlRpReads[$name] -ge $global:AzlRpBecomes[$name]) { return 'Registered' }
                if ($global:AzlRpState.ContainsKey($name)) { return $global:AzlRpState[$name] }
                return 'NotRegistered'
            }
            if ($line -like 'provider register*') { $global:AzlRpRegistered.Add([string]$args[3]); return }
        }
    }

    It 'registers every missing provider with az, in the subscription of the file, and puts the earlier subscription back' {
        $r = Invoke-Tool $script:RegisterCli (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @($global:AzlRpRegistered | Sort-Object) | Should -Be @($script:Providers | Sort-Object)
        $global:AzlRpAzCalls | Should -Contain "account set --subscription $($global:AzlRpSubscription)"
        $global:AzlRpAzCalls[-1] | Should -Be "account set --subscription $($global:AzlRpHome)"
    }

    It 'registers nothing under -WhatIf or when every provider is registered' {
        $null = Invoke-Tool $script:RegisterCli (New-InfraFile) -DryRun
        $global:AzlRpRegistered.Count | Should -Be 0
        foreach ($p in $script:Providers) { $global:AzlRpState[$p] = 'Registered' }
        (Invoke-Tool $script:RegisterCli (New-InfraFile)).ExitCode | Should -Be 0
        $global:AzlRpRegistered.Count | Should -Be 0
    }

    It 'with -Wait ends with exit code 1 when a provider does not reach Registered in time' {
        $r = Invoke-Tool $script:RegisterCli (New-InfraFile) @{ Wait = $true; MaxWaitMinutes = 1; PollSeconds = 30 }
        $r.ExitCode | Should -Be 1
    }

    It 'stops when the az sign-in is to another tenant, and with exit code 2 for a file without a tenant' {
        Mock az { $global:LASTEXITCODE = 0; if (($args -join ' ') -like 'account show*') { return @([guid]::NewGuid().ToString(), $global:AzlRpHome) } }
        (Invoke-Tool $script:RegisterCli (New-InfraFile)).ExitCode | Should -Be 1
        (Invoke-Tool $script:RegisterCli (New-InfraFile -Tenant $null)).ExitCode | Should -Be 2
    }
}

Describe 'Test-ResourceProviders.ps1' {
    BeforeEach {
        Reset-State
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlRpTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlRpHome } } }
        Mock Set-AzContext { $global:AzlRpContexts.Add($SubscriptionId) }
        Mock Get-AzResourceProvider {
            if ($global:AzlRpRegisterFails -contains $ProviderNamespace) { throw 'The read failed.' }
            $state = if ($global:AzlRpState.ContainsKey($ProviderNamespace)) { $global:AzlRpState[$ProviderNamespace] } else { 'Registered' }
            [pscustomobject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = $state }
        }
        Mock Register-AzResourceProvider { throw 'The check script must not register.' }
    }

    It 'ends with exit code 0 and one row per provider when all are registered, and registers nothing' {
        $r = Invoke-Tool $script:Verify (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Rows.Count | Should -Be 13
        Should -Invoke Register-AzResourceProvider -Times 0 -Exactly
        $global:AzlRpContexts[0] | Should -Be $global:AzlRpSubscription
        $global:AzlRpContexts[-1] | Should -Be $global:AzlRpHome
    }

    It 'ends with exit code 1 and names the provider that is not registered' {
        $global:AzlRpState['Microsoft.KeyVault'] = 'NotRegistered'
        $r = Invoke-Tool $script:Verify (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Microsoft\.KeyVault'
        @($r.Rows | Where-Object { -not $_.IsRegistered }).Provider | Should -Be 'Microsoft.KeyVault'
    }

    It 'reports a provider that cannot be read as Error and ends with exit code 1' {
        $global:AzlRpRegisterFails = @('Microsoft.Insights')
        $r = Invoke-Tool $script:Verify (New-InfraFile)
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Provider -EQ 'Microsoft.Insights').RegistrationState) | Should -Be 'Error'
    }

    It 'stops with exit code 2 for a file without a subscription' {
        (Invoke-Tool $script:Verify (New-InfraFile -Subscription $null)).ExitCode | Should -Be 2
    }
}
