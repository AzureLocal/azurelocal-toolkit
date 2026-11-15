#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Task 01 of automation / 01-cicd-infra, Azure CLI variant: New-CicdBootstrap.azcli.ps1 creates the app registration, the service principal, the federated
# credentials (or the client secret in Key Vault), the roles and the registrations with az commands only. The az command is replaced by a function that
# records the call: no network, no sign-in, nothing changes anywhere. The example file of the toolkit supplies every value.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/cicd-infra/CicdBootstrapAzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the answers and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the az command.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($script:Repo, 'scripts', 'deploy', '01-cicd-infra', 'phase-01-cicd-setup', 'task-01-bootstrap', 'azurecli', 'New-CicdBootstrap.azcli.ps1')
    $script:Example = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force
    $env:GH_TOKEN = $null; $env:GITLAB_TOKEN = $null; $env:AZURE_DEVOPS_EXT_PAT = $null; $env:GITHUB_TOKEN = $null; $env:GITLAB_PRIVATE_TOKEN = $null

    function az { }

    # The example without the Key Vault token: the settings are then read without any Key Vault access.
    function New-InfraFile([scriptblock]$Change) {
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $script:Example -Raw) -Ordered
        $doc.devops.Remove('api_token')
        if ($Change) { & $Change $doc }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    $script:Settings = Get-AzlCicdSetting -InfrastructureFile (New-InfraFile)
    $global:AzlK6Tenant = [string]$script:Settings.TenantId
    $global:AzlK6App = [guid]::NewGuid().ToString()
    $global:AzlK6Sp = [guid]::NewGuid().ToString()
    $global:AzlK6Secret = 'Canary-' + [guid]::NewGuid().ToString('N')
    $global:AzlK6Existing = '[]'

    function Reset-State {
        $global:AzlK6Calls = [System.Collections.Generic.List[string]]::new()
        $global:AzlK6Responder = { param($Line) }
    }
    function Use-AzMock {
        Mock az {
            $line = $args -join ' '
            $global:AzlK6Calls.Add($line)
            $answer = & $global:AzlK6Responder $line
            if ($answer -is [hashtable] -and $answer.ContainsKey('Fail')) { $global:LASTEXITCODE = 1; return $answer.Fail }
            $global:LASTEXITCODE = 0
            $answer
        }
    }
    function Invoke-Tool([string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $script:Script -InfrastructureFile $File @Extra 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Action'] -and $_ -isnot [string] -and $_ -isnot [Management.Automation.InformationRecord] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Pattern) { @($global:AzlK6Calls | Where-Object { $_ -match $Pattern }) }
    # Answers for a subscription that holds nothing yet.
    $global:AzlK6Empty = {
        param($Line)
        if ($Line -like 'account show*') { return $global:AzlK6Tenant }
        if ($Line -like 'ad app list*') { return '[]' }
        if ($Line -like 'ad app create*') { return $global:AzlK6App }
        if ($Line -like 'ad sp show*') { return @{ Fail = '(ResourceNotFound) Resource does not exist.' } }
        if ($Line -like 'ad sp create*') { return $global:AzlK6Sp }
        if ($Line -like 'ad app federated-credential list*') { return '[]' }
        if ($Line -like 'role assignment list*') { return '[]' }
        if ($Line -like 'feature show*') { return 'NotRegistered' }
        if ($Line -like 'keyvault secret show*') { return @{ Fail = '(SecretNotFound) A secret with this name was not found.' } }
        if ($Line -like 'ad app credential reset*') { return $global:AzlK6Secret }
    }
}

AfterAll { Remove-Variable -Name AzlK6Empty, AzlK6Tenant, AzlK6App, AzlK6Sp, AzlK6Secret, AzlK6Existing, AzlK6Calls, AzlK6Responder -Scope Global -ErrorAction SilentlyContinue }

Describe 'New-CicdBootstrap.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6Responder = $global:AzlK6Empty
    }

    It 'carries the standard header, takes -InfrastructureFile (mandatory) and uses az for every Azure call' {
        $text = Get-Content -LiteralPath $script:Script -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Not -Match 'Read-Host|Get-Credential|Connect-AzAccount|New-AzADApplication|Invoke-AzlNative|az login(?! --tenant)'
        $text | Should -Not -Match 'NOT IMPLEMENTED'
        $param = (Get-Command $script:Script).Parameters['InfrastructureFile']
        $param.Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -BeTrue
    }

    It 'creates the app, the principal, the federated credentials, the roles and the registrations, with the ids and names of the file' {
        $r = Invoke-Tool (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $s = $script:Settings
        (Get-Call '^ad app create --display-name ').Count | Should -Be 1
        (Get-Call ('^ad app create --display-name ' + [regex]::Escape($s.AppName) + ' ')).Count | Should -Be 1
        (Get-Call "^ad sp create --id $($global:AzlK6App) ").Count | Should -Be 1
        (Get-Call 'federated-credential create').Count | Should -Be (2 + $s.Environments.Count)
        (Get-Call '^role assignment create').Count | Should -Be ($s.RoleSubscriptionIds.Count * $s.Authentication.Roles.Count)
        (Get-Call "^role assignment create --assignee-object-id $($global:AzlK6Sp) --assignee-principal-type ServicePrincipal ").Count | Should -Be ($s.RoleSubscriptionIds.Count * $s.Authentication.Roles.Count)
        (Get-Call '^feature register').Count | Should -Be $s.RoleSubscriptionIds.Count
        (Get-Call '^provider register --namespace Microsoft.Compute --subscription ').Count | Should -Be $s.RoleSubscriptionIds.Count
        @($r.Rows | Where-Object Status -EQ 'Created').Count | Should -BeGreaterThan 5
    }

    It 'makes no change with -WhatIf' {
        $r = Invoke-Tool (New-InfraFile) @{ WhatIf = $true }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call ' (create|reset|register|set|add|admin-consent)( |$)').Count | Should -Be 0
        @($r.Rows | Where-Object Status -EQ 'Planned').Count | Should -BeGreaterThan 5
    }

    It 'creates nothing the second time' {
        $names = @(Get-AzlFederatedCredentialPlan -Settings $script:Settings | ForEach-Object Name | ConvertTo-Json -Compress -AsArray)
        $global:AzlK6Existing = $names[0]
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'ad app list*') { return "[`"$($global:AzlK6App)`"]" }
            if ($Line -like 'ad sp show*') { return $global:AzlK6Sp }
            if ($Line -like 'ad app federated-credential list*') { return $global:AzlK6Existing }
            if ($Line -like 'role assignment list*') { return '["Contributor","User Access Administrator"]' }
            if ($Line -like 'feature show*') { return 'Registered' }
        }
        $r = Invoke-Tool (New-InfraFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call ' (create|reset|register|add)( |$)').Count | Should -Be 0
        @($r.Rows | Where-Object Status -EQ 'Created').Count | Should -Be 0
        @($r.Rows | Where-Object Status -EQ 'Exists').Count | Should -BeGreaterThan 5
    }

    It 'sends a client secret to Key Vault from a file, never on a command line, and does not print it' {
        $file = New-InfraFile { param($d) $d.devops.authentication.method = 'client_secret'; $d.devops.authentication.client_secret = 'keyvault://kv-iic-mgmt-01/automation-spn-secret' }
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'ad app list*') { return "[`"$($global:AzlK6App)`"]" }
            if ($Line -like 'ad sp show*') { return $global:AzlK6Sp }
            if ($Line -like 'role assignment list*') { return '["Contributor","User Access Administrator"]' }
            if ($Line -like 'feature show*') { return 'Registered' }
            & $global:AzlK6Empty $Line
        }
        $r = Invoke-Tool $file
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-Call 'keyvault secret set').Count | Should -Be 1
        @(Get-Call 'keyvault secret set')[0] | Should -Match '--vault-name kv-iic-mgmt-01 --name automation-spn-secret --file '
        @($global:AzlK6Calls | Where-Object { $_ -match [regex]::Escape($global:AzlK6Secret) }).Count | Should -Be 0
        ($r.Text + ($r.Rows | Out-String)) | Should -Not -Match ([regex]::Escape($global:AzlK6Secret))
        (Get-Call 'federated-credential').Count | Should -Be 0
    }

    It 'does not issue a second client secret when the Key Vault secret exists' {
        $file = New-InfraFile { param($d) $d.devops.authentication.method = 'client_secret'; $d.devops.authentication.client_secret = 'keyvault://kv-iic-mgmt-01/automation-spn-secret' }
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'ad app list*') { return "[`"$($global:AzlK6App)`"]" }
            if ($Line -like 'ad sp show*') { return $global:AzlK6Sp }
            if ($Line -like 'keyvault secret show*') { return 'https://example.invalid/secrets/automation-spn-secret/1' }
            if ($Line -like 'role assignment list*') { return '["Contributor","User Access Administrator"]' }
            if ($Line -like 'feature show*') { return 'Registered' }
            & $global:AzlK6Empty $Line
        }
        $r = Invoke-Tool $file
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'credential reset|secret set').Count | Should -Be 0
    }

    It 'takes the federated credential of Azure DevOps from the organization of the platform' {
        Mock -ModuleName AzlCicdInfra Invoke-AzlNative { [pscustomobject]@{ ExitCode = 0; Output = 'not-a-real-token' } }
        Mock -ModuleName AzlCicdInfra Invoke-AzlRest { [pscustomobject]@{ instanceId = '22222222-2222-2222-2222-222222222222' } }
        $file = New-InfraFile { param($d) $d.devops.pipelines.service_connection = 'sc-iic-azl'; $d.devops.pipelines.variable_group = 'vg-iic-azl' }
        $r = Invoke-Tool $file @{ Platform = 'azure_devops' }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'federated-credential create').Count | Should -Be 1
    }

    It 'stops with exit code 1 before any change when az is not signed in, is signed in to another tenant or is not installed' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        $r = Invoke-Tool (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'az login'
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool (New-InfraFile)).ExitCode | Should -Be 1
        (Get-Call ' (create|reset|register|set|add)( |$)').Count | Should -Be 0
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        (Invoke-Tool (New-InfraFile)).ExitCode | Should -Be 1
    }

    It 'ends with exit code 1 when an az call fails' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'ad app create*') { return @{ Fail = 'Insufficient privileges to complete the operation.' } }
            & $global:AzlK6Empty $Line
        }
        $r = Invoke-Tool (New-InfraFile)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Insufficient privileges'
    }

    It 'ends with exit code 2 and calls nothing when the file is not there, has no devops section or has a client secret method without a reference' {
        (Invoke-Tool (Join-Path $TestDrive 'no-such-file.yml')).ExitCode | Should -Be 2
        (Invoke-Tool (New-InfraFile { param($d) $d.Remove('devops') })).ExitCode | Should -Be 2
        (Invoke-Tool (New-InfraFile { param($d) $d.devops.authentication.method = 'client_secret'; $d.devops.authentication.Remove('client_secret') })).ExitCode | Should -Be 2
        $global:AzlK6Calls.Count | Should -Be 0
    }
}
