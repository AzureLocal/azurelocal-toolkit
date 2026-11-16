#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 02 task 02 and phase 03 tasks 01 and 02 (resource providers, identity, RBAC), Azure CLI variants: Test-ResourceProviders.azcli.ps1,
# New-AutomationManagedIdentity.azcli.ps1, New-EntraSecurityGroups.azcli.ps1 and Set-EntraGroupRoleAssignments.azcli.ps1. Each takes its values from
# infrastructure.yml and calls az. The az command is replaced by a function that records the call: no Azure, no tenant and no sign-in is used.
# Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ProviderRbacAzureCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the az command.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $dir = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation')
    $script:Verify = [IO.Path]::Combine($dir, 'phase-02-resource-providers', 'task-02-verify-provider-registration', 'azurecli', 'Test-ResourceProviders.azcli.ps1')
    $script:Identity = [IO.Path]::Combine($dir, 'phase-03-rbac-permissions', 'task-01-create-azure-local-deployment-spn', 'azurecli', 'New-AutomationManagedIdentity.azcli.ps1')
    $script:Groups = [IO.Path]::Combine($dir, 'phase-03-rbac-permissions', 'task-02-assign-rbac-roles', 'azurecli', 'New-EntraSecurityGroups.azcli.ps1')
    $script:Roles = [IO.Path]::Combine($dir, 'phase-03-rbac-permissions', 'task-02-assign-rbac-roles', 'azurecli', 'Set-EntraGroupRoleAssignments.azcli.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    $script:Providers = @(Get-AzlArmMandatoryProvider)

    function az { }

    $global:AzlK6Tenant = [guid]::NewGuid().ToString()
    $global:AzlK6Sub = [guid]::NewGuid().ToString()
    $global:AzlK6Principal = [guid]::NewGuid().ToString()
    $global:AzlK6Client = [guid]::NewGuid().ToString()
    $global:AzlK6GroupA = [guid]::NewGuid().ToString()

    function Reset-State {
        $global:AzlK6Calls = [System.Collections.Generic.List[string]]::new()
        $global:AzlK6Responder = { param($Line) }
    }
    # The responder gets the az command line (without "az") and returns the text az would print, or @{ Fail = 'text' } for an az error.
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
    function New-InfraFile {
        param([object]$Tenant = $global:AzlK6Tenant, [hashtable]$Azure = @{}, [object]$Identity, [object]$EntraGroups, [object]$Tags)
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $Tenant) { $doc.azure.tenant_id = $Tenant }
        foreach ($k in $Azure.Keys) { $doc.azure[$k] = $Azure[$k] }
        if ($null -ne $Identity) { $doc.azure.automation_identity = $Identity }
        if ($null -ne $EntraGroups) { $doc.identity = [ordered]@{ entra = [ordered]@{ groups = @($EntraGroups) } } }
        if ($null -ne $Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Tool([string]$Script, [string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        [pscustomobject]@{
            ExitCode = $global:LASTEXITCODE
            Rows     = @($all | Where-Object { $_ -isnot [string] -and $_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord] -and $_ -isnot [Management.Automation.ErrorRecord] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Call([string]$Pattern) { @($global:AzlK6Calls | Where-Object { $_ -match $Pattern }) }
    $script:GroupsInFile = @(
        [ordered]@{ name = 'grp-iic-azl-admins'; purpose = 'Azure Local administrators'; roles = @('Contributor', 'Reader') },
        [ordered]@{ name = 'grp-iic-azl-readers'; roles = @('Reader'); scope = "/subscriptions/$($global:AzlK6Sub)" },
        [ordered]@{ name = 'grp-iic-azl-empty' })
}

AfterAll { Remove-Variable -Name AzlK6Tenant, AzlK6Sub, AzlK6Principal, AzlK6Client, AzlK6GroupA, AzlK6Calls, AzlK6Responder -Scope Global -ErrorAction SilentlyContinue }

Describe 'the Azure CLI provider and RBAC scripts, all of them' {
    It '<_> carries the standard header, reads only infrastructure.yml and never prompts' -ForEach @('Verify', 'Identity', 'Groups', 'Roles') {
        $path = (Get-Variable -Name $_ -Scope Script).Value
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match 'Import-AzlInfrastructure'
        $text | Should -Not -Match 'Read-Host|Get-Credential|Connect-AzAccount|Connect-MgGraph|az login(?! --tenant)'
        $text | Should -Not -Match 'NOT IMPLEMENTED'
    }
    It '<_> has no provider name and no role name in its code' -ForEach @('Verify', 'Roles') {
        $path = (Get-Variable -Name $_ -Scope Script).Value
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$null)
        (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match "Microsoft\.(HybridCompute|KeyVault|Storage|Insights)|Contributor|'Reader'|Owner"
    }
    It 'Test-ResourceProviders.azcli.ps1 takes the provider list from the toolkit' {
        (Get-Content -LiteralPath $script:Verify -Raw) | Should -Match 'Get-AzlArmMandatoryProvider'
    }
}

Describe 'Test-ResourceProviders.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6States = @{}
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'provider show*') {
                $name = $Line.Split(' ')[3]
                if ($global:AzlK6States.ContainsKey($name)) { return $global:AzlK6States[$name] }
                return 'Registered'
            }
        }
    }
    AfterAll { Remove-Variable -Name AzlK6States -Scope Global -ErrorAction SilentlyContinue }

    It 'ends with exit code 0 and one row per provider when all are registered, in the subscription of the file, and registers nothing' {
        $r = Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Sub })
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Rows.Count | Should -Be 13
        (Get-Call ('^provider show --namespace \S+ --subscription ' + $global:AzlK6Sub)).Count | Should -Be 13
        (Get-Call 'provider register').Count | Should -Be 0
        (Get-Call 'account set').Count | Should -Be 0
    }

    It 'ends with exit code 1 and names the provider that is not registered' {
        $global:AzlK6States['Microsoft.KeyVault'] = 'NotRegistered'
        $r = Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Sub })
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Microsoft\.KeyVault'
        @($r.Rows | Where-Object { -not $_.IsRegistered }).Provider | Should -Be 'Microsoft.KeyVault'
    }

    It 'reports a provider that cannot be read as Error and ends with exit code 1' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'provider show --namespace Microsoft.Insights*') { return @{ Fail = 'The read failed.' } }
            if ($Line -like 'provider show*') { return 'Registered' }
        }
        $r = Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Sub })
        $r.ExitCode | Should -Be 1
        (@($r.Rows | Where-Object Provider -EQ 'Microsoft.Insights').RegistrationState) | Should -Be 'Error'
    }

    It 'stops with exit code 1 when az is not signed in, is signed in to another tenant or is not installed' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        (Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Sub })).ExitCode | Should -Be 1
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Sub })).ExitCode | Should -Be 1
        (Get-Call 'provider show').Count | Should -Be 0
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
        (Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Sub })).ExitCode | Should -Be 1
    }

    It 'stops with exit code 2 before any call for a file without a usable tenant or subscription' {
        (Invoke-Tool $script:Verify (New-InfraFile -Tenant $null -Azure @{ subscription_id = $global:AzlK6Sub })).ExitCode | Should -Be 2
        (Invoke-Tool $script:Verify (New-InfraFile)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = '00000000-0000-0000-0000-000000000000' })).ExitCode | Should -Be 2
        (Invoke-Tool $script:Verify (New-InfraFile -Azure @{ subscription_id = 'not-a-guid' })).ExitCode | Should -Be 2
        $global:AzlK6Calls.Count | Should -Be 0
    }
}

Describe 'New-AutomationManagedIdentity.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'identity show*') { return @{ Fail = '(ResourceNotFound) The Resource Microsoft.ManagedIdentity/userAssignedIdentities/x was not found.' } }
            if ($Line -like 'identity create*') { return (@{ clientId = $global:AzlK6Client; principalId = $global:AzlK6Principal } | ConvertTo-Json -Compress) }
        }
        $script:Mi = [ordered]@{ type = 'managed_identity'; name = 'id-iic-azl-automation' }
        $script:AzureKeys = @{ subscription_id = $global:AzlK6Sub; resource_group = 'rg-iic-azl-01' }
    }

    It 'creates the identity in the subscription, resource group and region of the file, with the file tags, and reports the ids' {
        $r = Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $script:Mi -Tags ([ordered]@{ Project = 'azl' }))
        $r.ExitCode | Should -Be 0 -Because $r.Text
        @(Get-Call '^identity create') | Should -Be @("identity create --name id-iic-azl-automation --resource-group rg-iic-azl-01 --location eastus --subscription $($global:AzlK6Sub) --tags Project=azl --query {clientId:clientId,principalId:principalId,location:location} --output json")
        $r.Rows[0].Action | Should -Be 'Created'
        $r.Rows[0].ClientId | Should -Be $global:AzlK6Client
        $r.Rows[0].PrincipalId | Should -Be $global:AzlK6Principal
    }

    It 'uses the subscription and resource group of the identity entry when it has them' {
        $other = [guid]::NewGuid().ToString()
        $mi = [ordered]@{ type = 'managed_identity'; name = 'id-iic-azl-automation'; subscription_id = $other; resource_group = 'rg-iic-identity' }
        $null = Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $mi)
        (Get-Call "^identity create --name id-iic-azl-automation --resource-group rg-iic-identity --location eastus --subscription $other").Count | Should -Be 1
    }

    It 'creates nothing under -WhatIf' {
        $r = Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $script:Mi) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'identity create').Count | Should -Be 0
        $r.Rows[0].Action | Should -Be 'WouldCreate'
    }

    It 'leaves an identity that exists alone, reports its ids and a different region' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'identity show*') { return (@{ clientId = $global:AzlK6Client; principalId = $global:AzlK6Principal; location = 'westus3' } | ConvertTo-Json -Compress) }
        }
        $r = Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $script:Mi)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'identity create').Count | Should -Be 0
        $r.Rows[0].Action | Should -Be 'AlreadyExists'
        $r.Rows[0].ClientId | Should -Be $global:AzlK6Client
        $r.Rows[0].Detail | Should -Match 'cannot move'
    }

    It 'ends with exit code 1 when the resource group does not exist or the creation fails' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'identity show*') { return @{ Fail = "(ResourceGroupNotFound) Resource group 'rg-iic-azl-01' could not be found." } }
        }
        $r = Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $script:Mi)
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Create it first'
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'identity show*') { return @{ Fail = 'NotFound' } }
            if ($Line -like 'identity create*') { return @{ Fail = 'AuthorizationFailed' } }
        }
        (Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $script:Mi)).ExitCode | Should -Be 1
    }

    It 'stops with exit code 1 when az is not signed in or is signed in to another tenant' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        (Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $script:Mi)).ExitCode | Should -Be 1
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity $script:Mi)).ExitCode | Should -Be 1
        (Get-Call 'identity').Count | Should -Be 0
    }

    It 'stops with exit code 2 before any call for a service principal, a missing name, a bad name, a missing tenant or a missing place' {
        (Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity ([ordered]@{ type = 'service_principal'; name = 'sp-iic' }))).ExitCode | Should -Be 2
        (Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity ([ordered]@{ type = 'managed_identity' }))).ExitCode | Should -Be 2
        (Invoke-Tool $script:Identity (New-InfraFile -Azure $script:AzureKeys -Identity ([ordered]@{ type = 'managed_identity'; name = 'x' }))).ExitCode | Should -Be 2
        (Invoke-Tool $script:Identity (New-InfraFile -Tenant $null -Azure $script:AzureKeys -Identity $script:Mi)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Identity (New-InfraFile -Identity $script:Mi)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Identity (New-InfraFile -Azure @{ subscription_id = $global:AzlK6Sub } -Identity $script:Mi)).ExitCode | Should -Be 2
        $global:AzlK6Calls.Count | Should -Be 0
    }
}

Describe 'New-EntraSecurityGroups.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'ad group list*grp-iic-azl-readers*') { return (@([ordered]@{ id = $global:AzlK6GroupA; securityEnabled = $true }) | ConvertTo-Json -Compress -AsArray) }
            if ($Line -like 'ad group list*') { return '[]' }
            if ($Line -like 'ad group create*') { return [guid]::NewGuid().ToString() }
        }
    }

    It 'returns the object id of a group that exists' {
        $r = Invoke-Tool $script:Groups (New-InfraFile -EntraGroups $script:GroupsInFile)
        ($r.Rows[0].Groups | Where-Object Name -EQ 'grp-iic-azl-readers').Id | Should -Be $global:AzlK6GroupA
    }

    It 'reports one group of the name that is not a security group (a Microsoft 365 group) as a conflict, creates nothing for it and ends with exit code 1' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'ad group list*') { return (@([ordered]@{ id = $global:AzlK6GroupA; securityEnabled = $false }) | ConvertTo-Json -Compress -AsArray) }
        }
        $r = Invoke-Tool $script:Groups (New-InfraFile -EntraGroups @($script:GroupsInFile[0]))
        $r.ExitCode | Should -Be 1
        $r.Rows[0].Conflict | Should -Be 1
        $r.Text | Should -Match 'not a security group'
        (Get-Call 'ad group create').Count | Should -Be 0
        (Get-Call '^ad group list .*--query \[\]\.\{id:id,securityEnabled:securityEnabled\}').Count | Should -Be 1
    }

    It 'creates only the groups that are missing, as security groups with a mail nickname and the purpose as description' {
        $r = Invoke-Tool $script:Groups (New-InfraFile -EntraGroups $script:GroupsInFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Rows[0].Created | Should -Be 2
        $r.Rows[0].AlreadyExists | Should -Be 1
        @(Get-Call '^ad group create') | Should -Be @(
            "ad group create --display-name grp-iic-azl-admins --mail-nickname grp-iic-azl-admins --description Azure Local administrators --query id --output tsv"
            "ad group create --display-name grp-iic-azl-empty --mail-nickname grp-iic-azl-empty --description Azure Local security group --query id --output tsv")
        (Get-Call '^ad group list --filter displayName eq ''grp-iic-azl-admins''').Count | Should -Be 1
    }

    It 'creates nothing under -WhatIf' {
        $r = Invoke-Tool $script:Groups (New-InfraFile -EntraGroups $script:GroupsInFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'ad group create').Count | Should -Be 0
        $r.Rows[0].Planned | Should -Be 2
    }

    It 'reports two groups with one display name as a conflict, creates nothing for it and ends with exit code 1' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'ad group list*') { return (@([ordered]@{ id = [guid]::NewGuid().ToString(); securityEnabled = $true }, [ordered]@{ id = [guid]::NewGuid().ToString(); securityEnabled = $true }) | ConvertTo-Json -Compress) }
        }
        $r = Invoke-Tool $script:Groups (New-InfraFile -EntraGroups @($script:GroupsInFile[0]))
        $r.ExitCode | Should -Be 1
        $r.Rows[0].Conflict | Should -Be 1
        (Get-Call 'ad group create').Count | Should -Be 0
    }

    It 'ends with exit code 1 when a group cannot be created' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'ad group list*') { return '[]' }
            if ($Line -like 'ad group create*') { return @{ Fail = 'Insufficient privileges to complete the operation.' } }
        }
        $r = Invoke-Tool $script:Groups (New-InfraFile -EntraGroups @($script:GroupsInFile[0]))
        $r.ExitCode | Should -Be 1
        $r.Rows[0].Failed | Should -Be 1
    }

    It 'stops with exit code 1 when az is not signed in or is signed in to another tenant, and with exit code 2 for a bad file' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        (Invoke-Tool $script:Groups (New-InfraFile -EntraGroups $script:GroupsInFile)).ExitCode | Should -Be 1
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:Groups (New-InfraFile -EntraGroups $script:GroupsInFile)).ExitCode | Should -Be 1
        (Get-Call 'ad group').Count | Should -Be 0
        (Invoke-Tool $script:Groups (New-InfraFile -Tenant $null -EntraGroups $script:GroupsInFile)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Groups (New-InfraFile)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Groups (New-InfraFile -EntraGroups @([ordered]@{ purpose = 'no name' }))).ExitCode | Should -Be 2
        (Invoke-Tool $script:Groups (New-InfraFile -EntraGroups @($script:GroupsInFile[0], $script:GroupsInFile[0]))).ExitCode | Should -Be 2
    }
}

Describe 'Set-EntraGroupRoleAssignments.azcli.ps1' {
    BeforeEach {
        Reset-State
        Use-AzMock
        $script:RgScope = "/subscriptions/$($global:AzlK6Sub)/resourceGroups/rg-iic-azl-01"
        $global:AzlK6RgScope = $script:RgScope
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'ad group list*') { return (@($global:AzlK6GroupA) | ConvertTo-Json -Compress -AsArray) }
            if ($Line -like 'role definition list*') { return '["/providers/Microsoft.Authorization/roleDefinitions/x"]' }
            if ($Line -like 'role assignment list*--role Reader*') { return (@($global:AzlK6RgScope) | ConvertTo-Json -Compress -AsArray) }
            if ($Line -like 'role assignment list*') { return '[]' }
        }
        $script:Azure = @{ subscription_id = $global:AzlK6Sub; resource_group = 'rg-iic-azl-01' }
    }
    AfterAll { Remove-Variable -Name AzlK6RgScope -Scope Global -ErrorAction SilentlyContinue }

    It 'assigns the roles that are missing at the scope of the entry (default: the resource group of the instance) and leaves the ones held' {
        $r = Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups $script:GroupsInFile)
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $r.Rows[0].Assigned | Should -Be 2
        $r.Rows[0].AlreadyAssigned | Should -Be 1
        $r.Rows[0].Skipped | Should -Be 1
        @(Get-Call '^role assignment create') | Should -Be @(
            "role assignment create --assignee-object-id $($global:AzlK6GroupA) --assignee-principal-type Group --role Contributor --scope $($script:RgScope) --output none"
            "role assignment create --assignee-object-id $($global:AzlK6GroupA) --assignee-principal-type Group --role Reader --scope /subscriptions/$($global:AzlK6Sub) --output none")
    }

    It 'assigns nothing under -WhatIf' {
        $r = Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups $script:GroupsInFile) -DryRun
        $r.ExitCode | Should -Be 0 -Because $r.Text
        (Get-Call 'role assignment create').Count | Should -Be 0
        $r.Rows[0].Planned | Should -Be 2
    }

    It 'fails for a group that is not found, a group name two groups share and a role Azure does not know, and assigns nothing for them' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return $global:AzlK6Tenant }; if ($Line -like 'ad group list*') { return '[]' } }
        $r = Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups @($script:GroupsInFile[0]))
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'was not found in Microsoft Entra ID'
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return $global:AzlK6Tenant }; if ($Line -like 'ad group list*') { return (@([guid]::NewGuid().ToString(), [guid]::NewGuid().ToString()) | ConvertTo-Json -Compress) } }
        (Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups @($script:GroupsInFile[0]))).ExitCode | Should -Be 1
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return $global:AzlK6Tenant }; if ($Line -like 'ad group list*') { return (@($global:AzlK6GroupA) | ConvertTo-Json -Compress -AsArray) }; if ($Line -like 'role definition list*') { return '[]' } }
        $r = Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups @($script:GroupsInFile[0]))
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'role .* was not found'
        (Get-Call 'role assignment create').Count | Should -Be 0
    }

    It 'does not count a role held at a higher scope' {
        $global:AzlK6Responder = {
            param($Line)
            if ($Line -like 'account show*') { return $global:AzlK6Tenant }
            if ($Line -like 'ad group list*') { return (@($global:AzlK6GroupA) | ConvertTo-Json -Compress -AsArray) }
            if ($Line -like 'role definition list*') { return '["x"]' }
            if ($Line -like 'role assignment list*') { return (@("/subscriptions/$($global:AzlK6Sub)") | ConvertTo-Json -Compress -AsArray) }
        }
        $null = Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups @([ordered]@{ name = 'grp-iic-azl-readers'; roles = @('Reader') }))
        (Get-Call 'role assignment create').Count | Should -Be 1
    }

    It 'stops with exit code 1 when az is not signed in or is signed in to another tenant, and with exit code 2 for a bad file' {
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return @{ Fail = 'Please run az login' } } }
        (Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups $script:GroupsInFile)).ExitCode | Should -Be 1
        $global:AzlK6Responder = { param($Line) if ($Line -like 'account show*') { return [guid]::NewGuid().ToString() } }
        (Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups $script:GroupsInFile)).ExitCode | Should -Be 1
        (Get-Call 'role|ad group').Count | Should -Be 0
        (Invoke-Tool $script:Roles (New-InfraFile -Tenant $null -Azure $script:Azure -EntraGroups $script:GroupsInFile)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure)).ExitCode | Should -Be 2
        (Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups @($script:GroupsInFile[2]))).ExitCode | Should -Be 2
        (Invoke-Tool $script:Roles (New-InfraFile -EntraGroups @($script:GroupsInFile[0]))).ExitCode | Should -Be 2
        (Invoke-Tool $script:Roles (New-InfraFile -Azure $script:Azure -EntraGroups @([ordered]@{ name = 'g'; roles = @('Reader'); scope = 'not/a/scope' }))).ExitCode | Should -Be 2
    }
}
