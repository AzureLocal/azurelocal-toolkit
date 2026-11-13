#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), full deployment, task 01: Deploy-ManagementGroups.ps1 creates the management groups of landing_zone.management_groups,
# parents first, under the tenant root when an entry has no parent. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used.
# The tenant id is generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ManagementGroups.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant id.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment', 'task-01-configure-management-groups', 'powershell', 'Deploy-ManagementGroups.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not Az.Resources is installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzManagementGroup { [CmdletBinding()] param([string]$GroupName, [switch]$Expand) }
    function New-AzManagementGroup { [CmdletBinding()] param([string]$GroupName, [string]$DisplayName, [string]$ParentId) }

    $global:AzlMgcTenant = [guid]::NewGuid().ToString()
    $global:AzlMgcRoot = "/providers/Microsoft.Management/managementGroups/$($global:AzlMgcTenant)"

    function New-InfraFile([object[]]$Groups, [object]$TenantId = $global:AzlMgcTenant) {
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $Groups) { $doc.landing_zone = [ordered]@{ management_groups = @($Groups) } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Group([string]$Name, [string]$Display, [string]$Parent) {
        $g = [ordered]@{ name = $Name }
        if ($Display) { $g.display_name = $Display }
        if ($Parent) { $g.parent = $Parent }
        $g
    }
    function Invoke-Deploy([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['ManagementGroup'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    $script:Tree = @((New-Group 'mg-iic-platform' 'Platform' 'mg-iic'), (New-Group 'mg-iic' 'IIC'), (New-Group 'mg-iic-identity' 'Identity' 'mg-iic-platform'))
}

Describe 'Deploy-ManagementGroups.ps1' {
    AfterAll { Remove-Variable -Name AzlMgcTenant, AzlMgcRoot -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlMgcTenant } } }
        Mock Get-AzManagementGroup { throw "Management group '$GroupName' could not be found (404 NotFound)." }
        Mock New-AzManagementGroup { [pscustomobject]@{ Name = $GroupName } }
    }

    Context 'creating the hierarchy' {
        It 'creates the groups with parents first, whatever the order of the file, and the group without a parent under the tenant root' {
            $r = Invoke-Deploy (New-InfraFile $script:Tree)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.ManagementGroup) | Should -Be @('mg-iic', 'mg-iic-platform', 'mg-iic-identity')
            Should -Invoke New-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-iic' -and $DisplayName -eq 'IIC' -and $ParentId -eq $global:AzlMgcRoot }
            Should -Invoke New-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-iic-platform' -and $ParentId -eq '/providers/Microsoft.Management/managementGroups/mg-iic' }
            Should -Invoke New-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-iic-identity' -and $DisplayName -eq 'Identity' -and $ParentId -eq '/providers/Microsoft.Management/managementGroups/mg-iic-platform' }
        }

        It 'makes one group from a file with one entry, and uses the name as the display name when the entry has none' {
            $r = Invoke-Deploy (New-InfraFile @((New-Group 'mg-iic')))
            $r.ExitCode | Should -Be 0
            Should -Invoke New-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'mg-iic' -and $ParentId -eq $global:AzlMgcRoot }
        }

        It 'creates only management groups and never removes or moves one' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-AzManagementGroup|Update-AzManagementGroup|New-AzManagementGroupSubscription'
        }
    }

    Context 'a group already exists (idempotent)' {
        It 'creates nothing for it and says so' {
            Mock Get-AzManagementGroup { [pscustomobject]@{ Name = $GroupName; DisplayName = 'IIC'; ParentId = $global:AzlMgcRoot } }
            $r = Invoke-Deploy (New-InfraFile @((New-Group 'mg-iic' 'IIC')))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -BeNullOrEmpty
            Should -Invoke New-AzManagementGroup -Times 0 -Exactly
        }

        It 'reports a different display name and a different parent, and changes nothing' {
            Mock Get-AzManagementGroup { [pscustomobject]@{ Name = $GroupName; DisplayName = 'Old name'; ParentId = '/providers/Microsoft.Management/managementGroups/other' } }
            $r = Invoke-Deploy (New-InfraFile @((New-Group 'mg-iic' 'IIC')))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Detail | Should -Match 'display name is ''Old name'''
            $r.Rows[0].Detail | Should -Match 'parent is /providers/Microsoft.Management/managementGroups/other'
            Should -Invoke New-AzManagementGroup -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans every group and creates nothing' {
            $r = Invoke-Deploy (New-InfraFile $script:Tree) -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows.Action | Select-Object -Unique) | Should -Be @('WouldCreate')
            Should -Invoke New-AzManagementGroup -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing or non-GUID azure.tenant_id' {
            (Invoke-Deploy (New-InfraFile $script:Tree -TenantId $null)).ExitCode | Should -Be 2
            (Invoke-Deploy (New-InfraFile $script:Tree -TenantId 'not-a-guid')).ExitCode | Should -Be 2
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a file with no management group'; Groups = @() }
            @{ Why = 'an entry with no name'; Groups = @([ordered]@{ display_name = 'x' }) }
            @{ Why = 'a name Azure refuses'; Groups = @([ordered]@{ name = 'bad name' }) }
            @{ Why = 'the same name twice'; Groups = @([ordered]@{ name = 'mg-a' }, [ordered]@{ name = 'MG-A' }) }
            @{ Why = 'a parent that is not in the list'; Groups = @([ordered]@{ name = 'mg-a'; parent = 'mg-missing' }) }
            @{ Why = 'a group that is its own parent'; Groups = @([ordered]@{ name = 'mg-a'; parent = 'mg-a' }) }
            @{ Why = 'a loop of parents'; Groups = @([ordered]@{ name = 'mg-a'; parent = 'mg-b' }, [ordered]@{ name = 'mg-b'; parent = 'mg-a' }) }
        ) {
            $r = Invoke-Deploy (New-InfraFile $Groups)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzManagementGroup -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Deploy (New-InfraFile $script:Tree)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Deploy (New-InfraFile $script:Tree)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzManagementGroup -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzManagementGroup { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Deploy (New-InfraFile @((New-Group 'mg-iic' 'IIC')))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke New-AzManagementGroup -Times 0 -Exactly
        }

        It 'reports a failed creation, does not try its children, goes on with the others, and exits 1' {
            Mock New-AzManagementGroup { if ($GroupName -eq 'mg-iic-platform') { throw 'AuthorizationFailed' } else { [pscustomobject]@{ Name = $GroupName } } }
            $file = New-InfraFile @((New-Group 'mg-iic' 'IIC'), (New-Group 'mg-iic-platform' 'Platform' 'mg-iic'), (New-Group 'mg-iic-identity' 'Identity' 'mg-iic-platform'), (New-Group 'mg-iic-sandbox' 'Sandbox' 'mg-iic'))
            $r = Invoke-Deploy $file
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object ManagementGroup -EQ 'mg-iic-platform').Action | Should -Be 'Failed'
            ($r.Rows | Where-Object ManagementGroup -EQ 'mg-iic-identity').Detail | Should -Match 'was not created'
            ($r.Rows | Where-Object ManagementGroup -EQ 'mg-iic-sandbox').Action | Should -Be 'Created'
            Should -Invoke New-AzManagementGroup -Times 0 -Exactly -ParameterFilter { $GroupName -eq 'mg-iic-identity' }
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

        It 'reads its values through the toolkit loader, never the old layout, and holds no GUID or address' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml|azure\.management_groups|tenant_root'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_ManagementGroups_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'landing_zone.management_groups[].name', 'landing_zone.management_groups[].display_name', 'landing_zone.management_groups[].parent' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
