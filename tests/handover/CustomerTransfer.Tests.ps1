#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Handover: Set-CustomerTransfer.ps1 reads cluster.name, azure.tenant_id, azure.subscription_id, azure.resource_group and site.customer from
# infrastructure.yml, assigns the two Azure roles to the customer administrator and writes the transfer record. Every Az cmdlet is mocked: no Azure,
# no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/handover/CustomerTransfer.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'handover', 'customer-transfer', 'powershell', 'Set-CustomerTransfer.ps1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzADUser { [CmdletBinding()] param([string]$UserPrincipalName, [string]$Filter) }
    function Get-AzRoleAssignment { [CmdletBinding()] param([string]$ObjectId, [string]$Scope, [string]$RoleDefinitionName) }
    function New-AzRoleAssignment { [CmdletBinding()] param([string]$ObjectId, [string]$Scope, [string]$RoleDefinitionName) }

    $global:AzlCtTenant = [guid]::NewGuid().ToString()
    $global:AzlCtSub = [guid]::NewGuid().ToString()
    $global:AzlCtHome = [guid]::NewGuid().ToString()
    $global:AzlCtCustomerTenant = [guid]::NewGuid().ToString()
    $global:AzlCtUser = [guid]::NewGuid().ToString()
    $script:Admin = 'admin@improbability.cloud'

    function New-InfraFile {
        param([hashtable]$Azure = @{}, [hashtable]$Cluster = @{}, [hashtable]$Site = @{})
        $az = [ordered]@{ tenant_id = $global:AzlCtTenant; subscription_id = $global:AzlCtSub; resource_group = 'rg-iic-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $cl = [ordered]@{ name = 'iic-azl-01' }
        foreach ($k in $Cluster.Keys) { if ($null -eq $Cluster[$k]) { $cl.Remove($k) } else { $cl[$k] = $Cluster[$k] } }
        $si = [ordered]@{ customer = 'Improbability Inc' }
        foreach ($k in $Site.Keys) { if ($null -eq $Site[$k]) { $si.Remove($k) } else { $si[$k] = $Site[$k] } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml ([ordered]@{ azure = $az; cluster = $cl; site = $si }))
        $file
    }
    function Invoke-Transfer([string]$File, [switch]$DryRun, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $arguments = @{ InfrastructureFile = $File; CustomerTenantId = $global:AzlCtCustomerTenant; CustomerAdminUPN = $script:Admin }
        foreach ($k in $Extra.Keys) { if ($null -eq $Extra[$k]) { $arguments.Remove($k) } else { $arguments[$k] = $Extra[$k] } }
        $all = if ($DryRun) { & $script:Script @arguments -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script @arguments 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Step'] -and $_.PSObject.Properties['Status'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Set-CustomerTransfer.ps1' {
    AfterAll { Remove-Variable -Name AzlCtTenant, AzlCtSub, AzlCtHome, AzlCtCustomerTenant, AzlCtUser -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlCtTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlCtHome } } }
        Mock Set-AzContext { }
        Mock Get-AzADUser { if ($UserPrincipalName) { [pscustomobject]@{ Id = $global:AzlCtUser; UserPrincipalName = $UserPrincipalName } } }
        Mock Get-AzRoleAssignment { @() }
        Mock New-AzRoleAssignment { [pscustomobject]@{ RoleDefinitionName = $RoleDefinitionName } }
    }

    Context 'assigning the roles' {
        It 'assigns Contributor on the resource group and Reader on the subscription of the file to the administrator' {
            $r = Invoke-Transfer (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlCtSub }
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $ObjectId -eq $global:AzlCtUser -and $RoleDefinitionName -eq 'Contributor' -and $Scope -eq "/subscriptions/$($global:AzlCtSub)/resourceGroups/rg-iic-azl-01" }
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $ObjectId -eq $global:AzlCtUser -and $RoleDefinitionName -eq 'Reader' -and $Scope -eq "/subscriptions/$($global:AzlCtSub)" }
            @($r.Rows | Where-Object Status -EQ 'Assigned').Count | Should -Be 2
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlCtHome }
        }

        It 'looks the administrator up by mail when the user principal name is not found (a guest)' {
            Mock Get-AzADUser { if ($Filter) { [pscustomobject]@{ Id = $global:AzlCtUser } } }
            $r = Invoke-Transfer (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke Get-AzADUser -Times 1 -Exactly -ParameterFilter { $Filter -like "mail eq '*" }
        }

        It 'never removes a role assignment' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Get-ClusterNode|Invoke-Command'
        }
    }

    Context 'a role is assigned already (idempotent)' {
        It 'assigns nothing and reports it' {
            Mock Get-AzRoleAssignment { @([pscustomobject]@{ RoleDefinitionName = $RoleDefinitionName }) }
            $r = Invoke-Transfer (New-InfraFile)
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Status -EQ 'AlreadyAssigned').Count | Should -Be 2
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }
    }

    Context 'the transfer record' {
        It 'writes a Markdown page and a JSON file that name the cluster, the customer, the administrator and the portal link, and no secret' {
            $out = Join-Path $TestDrive 'record'
            $r = Invoke-Transfer (New-InfraFile) -Extra @{ OutputPath = $out }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $md = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $out -Filter '*.md')[0].FullName -Raw
            $md | Should -Match 'Cluster: iic-azl-01'
            $md | Should -Match 'Customer: Improbability Inc'
            $md | Should -Match 'Customer administrator: admin@improbability\.cloud'
            $md | Should -Match "https://portal\.azure\.com/#@$($global:AzlCtCustomerTenant)/resource/subscriptions/$($global:AzlCtSub)/resourceGroups/rg-iic-azl-01"
            $json = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $out -Filter '*.json')[0].FullName -Raw | ConvertFrom-Json
            $json.Cluster | Should -Be 'iic-azl-01'
            @($json.Steps).Count | Should -BeGreaterThan 3
        }

        It 'says that the local administrator access on the nodes is not changed' {
            $r = Invoke-Transfer (New-InfraFile)
            ($r.Rows | Where-Object Step -Like 'Local administrator*').Status | Should -Be 'Skipped'
        }

        It 'shows a missing site.customer as not set and still transfers' {
            $out = Join-Path $TestDrive 'record2'
            $r = Invoke-Transfer (New-InfraFile -Site @{ customer = $null }) -Extra @{ OutputPath = $out }
            $r.ExitCode | Should -Be 0
            (Get-Content -LiteralPath (Get-ChildItem -LiteralPath $out -Filter '*.md')[0].FullName -Raw) | Should -Match 'not set \(site\.customer\)'
        }
    }

    Context '-WhatIf and nothing written' {
        It 'plans the roles, assigns nothing and writes no file' {
            $out = Join-Path $TestDrive 'record3'
            $r = Invoke-Transfer (New-InfraFile) -DryRun -Extra @{ OutputPath = $out }
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Status -EQ 'WouldAssign').Count | Should -Be 2
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
            Test-Path -LiteralPath $out | Should -BeFalse
        }
    }

    Context 'a value is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing <Key>' -ForEach @(
            @{ Key = 'cluster.name'; Args2 = @{ Cluster = @{ name = $null } } }
            @{ Key = 'azure.tenant_id'; Args2 = @{ Azure = @{ tenant_id = $null } } }
            @{ Key = 'azure.subscription_id'; Args2 = @{ Azure = @{ subscription_id = $null } } }
            @{ Key = 'azure.resource_group'; Args2 = @{ Azure = @{ resource_group = $null } } }
        ) {
            $r = Invoke-Transfer (New-InfraFile @Args2)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a customer tenant that is not a GUID and an administrator that is not a user principal name' {
            (Invoke-Transfer (New-InfraFile) -Extra @{ CustomerTenantId = 'not-a-guid' }).ExitCode | Should -Be 2
            (Invoke-Transfer (New-InfraFile) -Extra @{ CustomerAdminUPN = 'nobody' }).ExitCode | Should -Be 2
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Transfer (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Transfer (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'fails when the administrator is not in Microsoft Entra ID' {
            Mock Get-AzADUser { $null }
            $r = Invoke-Transfer (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Step -EQ 'Customer administrator').Status | Should -Be 'Failed'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'reports a failed assignment, goes on with the next, puts the subscription back and exits 1' {
            Mock New-AzRoleAssignment { if ($RoleDefinitionName -eq 'Contributor') { throw 'AuthorizationFailed' } }
            $r = Invoke-Transfer (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Step -Like '*Contributor*').Status | Should -Be 'Failed'
            ($r.Rows | Where-Object Step -Like '*Reader*').Status | Should -Be 'Assigned'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlCtHome }
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt'
        }

        It 'reads the instance from the file, not from parameters, and uses no helper that no longer exists' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'logging\.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
            @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('InfrastructureFile', 'CustomerTenantId', 'CustomerAdminUPN', 'OutputPath', 'LogPath')
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Set_CustomerTransfer_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'cluster.name', 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'site.customer' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
