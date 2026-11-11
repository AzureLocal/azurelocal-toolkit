#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 03 (RBAC and permissions), task 02: Set-EntraGroupRoleAssignments.ps1 assigns the Azure roles that identity.entra.groups gives each Microsoft Entra group.
# Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Tenant, subscription and object ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/EntraGroupRoleAssignments.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-03-rbac-permissions', 'task-02-assign-rbac-roles', 'powershell', 'Set-EntraGroupRoleAssignments.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not Az.Resources is installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzADGroup { [CmdletBinding()] param([string]$DisplayName) }
    function Get-AzRoleDefinition { [CmdletBinding()] param([string]$Name, [string]$Scope) }
    function Get-AzRoleAssignment { [CmdletBinding()] param([string]$ObjectId, [string]$RoleDefinitionName, [string]$Scope) }
    function New-AzRoleAssignment { [CmdletBinding()] param([string]$ObjectId, [string]$ObjectType, [string]$RoleDefinitionName, [string]$Scope) }

    $global:AzlRbacTestTenant = [guid]::NewGuid().ToString()
    $global:AzlRbacTestSub = [guid]::NewGuid().ToString()
    $global:AzlRbacTestSub2 = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object[]]$Groups, [object]$TenantId = $global:AzlRbacTestTenant, [object]$SubscriptionId = $global:AzlRbacTestSub, [string]$ResourceGroup = 'rg-azl-01')
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $SubscriptionId) { $doc.azure.subscription_id = $SubscriptionId }
        if ($ResourceGroup) { $doc.azure.resource_group = $ResourceGroup }
        if ($null -ne $Groups) { $doc.identity = [ordered]@{ entra = [ordered]@{ groups = @($Groups) } } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Group([string]$Name, [string[]]$Roles, [string]$Scope) {
        $g = [ordered]@{ name = $Name }
        if ($Roles) { $g.roles = @($Roles) }
        if ($Scope) { $g.scope = $Scope }
        $g
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-RoleRun([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['Assignments'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Set-EntraGroupRoleAssignments.ps1' {
    BeforeAll {
        $script:DefaultScope = "/subscriptions/$($global:AzlRbacTestSub)/resourceGroups/rg-azl-01"
    }

    AfterAll {
        Remove-Variable -Name AzlRbacTestTenant, AzlRbacTestSub, AzlRbacTestSub2 -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlRbacTestTenant } } }
        Mock Get-AzADGroup { [pscustomobject]@{ Id = "id-of-$DisplayName"; DisplayName = $DisplayName } }
        Mock Get-AzRoleDefinition { [pscustomobject]@{ Name = $Name } }
        Mock Get-AzRoleAssignment { @() }
        Mock New-AzRoleAssignment { [pscustomobject]@{ RoleDefinitionName = $RoleDefinitionName } }
    }

    Context 'assigning roles (happy path)' {
        It 'assigns each role of each group at the default scope (the instance resource group) and says it is a Group' {
            $file = New-InfraFile @((New-Group 'grp-operators' @('Reader', 'Contributor')), (New-Group 'grp-readers' @('Reader')))
            $r = Invoke-RoleRun $file
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Result.Assigned | Should -Be 3
            $r.Result.Failed | Should -Be 0
            Should -Invoke New-AzRoleAssignment -Times 3 -Exactly
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $ObjectId -eq 'id-of-grp-operators' -and $ObjectType -eq 'Group' -and $RoleDefinitionName -eq 'Contributor' -and $Scope -eq $script:DefaultScope }
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $ObjectId -eq 'id-of-grp-readers' -and $RoleDefinitionName -eq 'Reader' -and $Scope -eq $script:DefaultScope }
            $r.Text | Should -Match 'assigned'
        }

        It 'uses the scope of the entry when it has one' {
            $scope = "/subscriptions/$($global:AzlRbacTestSub2)"
            $null = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader') $scope)))
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $Scope -eq $scope }
            Should -Invoke Get-AzRoleDefinition -Times 1 -Exactly -ParameterFilter { $Scope -eq $scope }
        }

        It 'accepts a management group scope and a resource scope: <_>' -ForEach @(
            '/providers/Microsoft.Management/managementGroups/mg-platform',
            "/subscriptions/$([guid]::Empty)/resourceGroups/rg-a/providers/Microsoft.KeyVault/vaults/kv-a"
        ) {
            (Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader') $_)))).ExitCode | Should -Be 0
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $Scope -eq $_ }
        }

        It 'drops a trailing slash from the scope' {
            $null = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader') "/subscriptions/$($global:AzlRbacTestSub)/")))
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $Scope -eq "/subscriptions/$($global:AzlRbacTestSub)" }
        }

        It 'looks a group up once and a role once, however many assignments use them' {
            $null = Invoke-RoleRun (New-InfraFile @((New-Group 'grp-operators' @('Reader', 'Contributor')), (New-Group 'grp-readers' @('Reader'))))
            Should -Invoke Get-AzADGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'grp-operators' }
            Should -Invoke Get-AzRoleDefinition -Times 2 -Exactly
        }

        It 'lists a role named twice once' {
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader', 'Reader'))))
            $r.Result.Assigned | Should -Be 1
        }

        It 'skips a group with no roles and assigns for the others' {
            $r = Invoke-RoleRun (New-InfraFile @((New-Group 'grp-none' @()), (New-Group 'grp-readers' @('Reader'))))
            $r.ExitCode | Should -Be 0
            $r.Result.Skipped | Should -Be 1
            $r.Result.Assigned | Should -Be 1
            Should -Invoke Get-AzADGroup -Times 0 -Exactly -ParameterFilter { $DisplayName -eq 'grp-none' }
        }

        It 'ignores groups whose display name only starts with the name (a prefix match)' {
            Mock Get-AzADGroup { @([pscustomobject]@{ Id = 'wrong'; DisplayName = "$DisplayName-extra" }, [pscustomobject]@{ Id = 'right'; DisplayName = $DisplayName }) }
            $null = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $ObjectId -eq 'right' }
        }
    }

    Context 'the role is already assigned (idempotent)' {
        It 'assigns nothing and says so' {
            Mock Get-AzRoleAssignment { [pscustomobject]@{ RoleDefinitionName = $RoleDefinitionName; Scope = $Scope } }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader', 'Contributor'))))
            $r.ExitCode | Should -Be 0
            $r.Result.Assigned | Should -Be 0
            $r.Result.AlreadyAssigned | Should -Be 2
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
            $r.Text | Should -Match 'Nothing to do'
        }

        It 'compares the scope without regard to case' {
            Mock Get-AzRoleAssignment { [pscustomobject]@{ RoleDefinitionName = $RoleDefinitionName; Scope = $Scope.ToUpperInvariant() } }
            (Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))).Result.AlreadyAssigned | Should -Be 1
        }

        It 'a role held only at a higher scope does not count: it is assigned at the scope of the file' {
            Mock Get-AzRoleAssignment { [pscustomobject]@{ RoleDefinitionName = $RoleDefinitionName; Scope = "/subscriptions/$($global:AzlRbacTestSub)" } }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            $r.Result.Assigned | Should -Be 1
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly
        }

        It 'a mixed file assigns only what is missing' {
            Mock Get-AzRoleAssignment { if ($RoleDefinitionName -eq 'Reader') { [pscustomobject]@{ Scope = $Scope } } }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader', 'Contributor'))))
            $r.Result.AlreadyAssigned | Should -Be 1
            $r.Result.Assigned | Should -Be 1
            Should -Invoke New-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $RoleDefinitionName -eq 'Contributor' }
        }

        It 'never removes a role assignment' {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            $script:Text | Should -Not -Match 'Remove-AzRoleAssignment'
        }
    }

    Context '-WhatIf' {
        It 'plans the assignments and makes none' {
            $r = Invoke-RoleRun (New-InfraFile @((New-Group 'grp-operators' @('Reader', 'Contributor')))) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Planned | Should -Be 2
            $r.Result.Assigned | Should -Be 0
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
            $r.Text | Should -Match 'would get'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'rbac.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile @(, (New-Group 'grp-operators' @('Reader')))) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would get'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without identity.entra.groups' {
            $r = Invoke-RoleRun (New-InfraFile $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'identity.entra.groups is empty'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a file where no group has a role' {
            $r = Invoke-RoleRun (New-InfraFile @((New-Group 'grp-a' @()), (New-Group 'grp-b' $null)))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'nothing to assign'
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))) -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a group with no name' {
            $r = Invoke-RoleRun (New-InfraFile @(, ([ordered]@{ roles = @('Reader') })))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'has no name'
        }

        It 'refuses an entry with roles and no scope when the file gives no default scope' {
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))) -SubscriptionId $null -ResourceGroup '')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no scope'
        }

        It 'refuses a scope that is not a scope: <_>' -ForEach 'rg-azl-01', '/resourceGroups/rg-azl-01', '/subscriptions/not-a-guid', '/providers/Microsoft.Authorization/policyAssignments/x', 'https://example.test/scope' {
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader') $_)))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'is not a subscription, resource group'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'refuses the same group twice, whatever the case' {
            $r = Invoke-RoleRun (New-InfraFile @((New-Group 'grp-operators' @('Reader')), (New-Group 'GRP-Operators' @('Contributor'))))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-RoleRun (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'fails a group that does not exist, and still assigns to the others' {
            Mock Get-AzADGroup { if ($DisplayName -eq 'grp-missing') { $null } else { [pscustomobject]@{ Id = "id-of-$DisplayName"; DisplayName = $DisplayName } } }
            $r = Invoke-RoleRun (New-InfraFile @((New-Group 'grp-missing' @('Reader')), (New-Group 'grp-readers' @('Reader'))))
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            $r.Result.Assigned | Should -Be 1
            ($r.Result.Assignments | Where-Object Action -EQ 'Failed').Detail | Should -Match 'New-EntraSecurityGroups'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly -ParameterFilter { $ObjectId -match 'missing' }
        }

        It 'fails a group whose display name two groups share' {
            Mock Get-AzADGroup { @([pscustomobject]@{ Id = 'a'; DisplayName = $DisplayName }, [pscustomobject]@{ Id = 'b'; DisplayName = $DisplayName }) }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            $r.ExitCode | Should -Be 1
            ($r.Result.Assignments | Where-Object Action -EQ 'Failed').Detail | Should -Match '2 groups have the display name'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'fails a role Azure does not know' {
            Mock Get-AzRoleDefinition { if ($Name -eq 'Reeder') { $null } else { [pscustomobject]@{ Name = $Name } } }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reeder', 'Reader'))))
            $r.ExitCode | Should -Be 1
            $r.Result.Assigned | Should -Be 1
            ($r.Result.Assignments | Where-Object Action -EQ 'Failed').Detail | Should -Match "role 'Reeder' was not found"
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly -ParameterFilter { $RoleDefinitionName -eq 'Reeder' }
        }

        It 'treats a not-found error from the role lookup as an unknown role' {
            Mock Get-AzRoleDefinition { throw 'Role definition could not be found (404).' }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            $r.ExitCode | Should -Be 1
            ($r.Result.Assignments | Where-Object Action -EQ 'Failed').Detail | Should -Match 'was not found'
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzRoleDefinition { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            $r.ExitCode | Should -Be 1
            ($r.Result.Assignments | Where-Object Action -EQ 'Failed').Detail | Should -Match 'authorization'
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'reports a group lookup error and assigns nothing to that group' {
            Mock Get-AzADGroup { throw 'Insufficient privileges to complete the operation.' }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader'))))
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }

        It 'reports a failed assignment, still assigns the others, and exits 1' {
            Mock New-AzRoleAssignment { if ($RoleDefinitionName -eq 'Contributor') { throw 'AuthorizationFailed' } }
            $r = Invoke-RoleRun (New-InfraFile @(, (New-Group 'grp-operators' @('Reader', 'Contributor'))))
            $r.ExitCode | Should -Be 1
            $r.Result.Assigned | Should -Be 1
            $r.Result.Failed | Should -Be 1
            ($r.Result.Assignments | Where-Object Action -EQ 'Failed').Detail | Should -Match 'AuthorizationFailed'
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
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Set_EntraGroupRoleAssignments_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'identity.entra.groups[].name', 'identity.entra.groups[].roles', 'identity.entra.groups[].scope') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
        }
    }
}
