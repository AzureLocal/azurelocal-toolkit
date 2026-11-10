#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 04 (security and governance), task 02: Invoke-AzurePolicyTier1-Orchestrated.ps1 assigns the built-in policy "Require a tag on resources" once per
# tag in landing_zone.policy.required_tags, in audit mode, at one management group. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/AzurePolicyTier1.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the definition id.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '05-operational-foundations', 'phase-04-security-governance', 'task-02-apply-azure-policy-initiatives', 'powershell', 'Invoke-AzurePolicyTier1-Orchestrated.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not Az.Resources is installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzPolicyDefinition { [CmdletBinding()] param([string]$Id) }
    function Get-AzPolicyAssignment { [CmdletBinding()] param([string]$Id) }
    function New-AzPolicyAssignment {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Name, [string]$Scope, [string]$DisplayName, [string]$Description, [object]$PolicyDefinition, [hashtable]$PolicyParameterObject, [string]$EnforcementMode)
    }

    $global:AzlTier1TestTenant = [guid]::NewGuid().ToString()

    function New-InfraFile([hashtable]$Policy, [object]$TenantId = $global:AzlTier1TestTenant) {
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($Policy) { $doc.landing_zone = [ordered]@{ policy = $Policy } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Tier1([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = @($all | Where-Object { $_.PSObject.Properties['Assignments'] })[0]
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }

    $global:AzlTier1TestDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99'
}

Describe 'Invoke-AzurePolicyTier1-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlTier1TestTenant, AzlTier1TestDefinitionId -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlTier1TestTenant } } }
        Mock Get-AzPolicyDefinition { [pscustomobject]@{ Id = $Id; DisplayName = 'Require a tag on resources' } }
        Mock Get-AzPolicyAssignment { $null }
        Mock New-AzPolicyAssignment { [pscustomobject]@{ Name = $Name } }
    }

    Context 'creating the assignments (happy path)' {
        It 'assigns the built-in definition once per tag at the tenant root group, in audit mode' {
            $file = New-InfraFile @{ required_tags = @('environment', 'owner', 'cost_center') }
            $r = Invoke-Tier1 $file
            $r.ExitCode | Should -Be 0
            $r.Result.Created | Should -Be 3
            $r.Result.Failed | Should -Be 0
            $r.Result.Scope | Should -Be "/providers/Microsoft.Management/managementGroups/$($global:AzlTier1TestTenant)"
            Should -Invoke New-AzPolicyAssignment -Times 3 -Exactly
            Should -Invoke New-AzPolicyAssignment -Times 3 -Exactly -ParameterFilter {
                $EnforcementMode -eq 'DoNotEnforce' -and $Scope -eq "/providers/Microsoft.Management/managementGroups/$($global:AzlTier1TestTenant)" -and $PolicyDefinition.Id -eq $global:AzlTier1TestDefinitionId
            }
            Should -Invoke New-AzPolicyAssignment -Times 1 -Exactly -ParameterFilter { $PolicyParameterObject.tagName -eq 'cost_center' -and $Name -eq 'req-tag-cost-center' }
            Should -Invoke Get-AzPolicyDefinition -Times 1 -Exactly -ParameterFilter { $Id -eq $global:AzlTier1TestDefinitionId }
        }

        It 'assigns at the management group named in landing_zone.policy.management_group' {
            $file = New-InfraFile @{ required_tags = @('owner'); management_group = 'mg-example' }
            $r = Invoke-Tier1 $file
            $r.ExitCode | Should -Be 0
            $r.Result.Scope | Should -Be '/providers/Microsoft.Management/managementGroups/mg-example'
            Should -Invoke New-AzPolicyAssignment -Times 1 -Exactly -ParameterFilter { $Scope -eq '/providers/Microsoft.Management/managementGroups/mg-example' }
        }

        It 'keeps every assignment name within the 24 characters a management group scope allows' {
            $file = New-InfraFile @{ required_tags = @('a-very-long-tag-name-that-goes-on-and-on', 'Cost Center (Primary)') }
            $r = Invoke-Tier1 $file
            $r.ExitCode | Should -Be 0
            foreach ($a in $r.Result.Assignments) { $a.Name.Length | Should -BeLessOrEqual 24; $a.Name | Should -Match '^req-tag-[a-z0-9-]+$' }
        }

        It 'passes the tag name as written to the policy parameter and says audit mode in the display name' {
            $file = New-InfraFile @{ required_tags = @('CostCenter') }
            $null = Invoke-Tier1 $file
            Should -Invoke New-AzPolicyAssignment -Times 1 -Exactly -ParameterFilter { $PolicyParameterObject.tagName -eq 'CostCenter' -and $DisplayName -match 'audit' }
        }

        It 'treats a not-found error from Azure as "does not exist yet" and creates the assignment' {
            Mock Get-AzPolicyAssignment { throw 'Response status code does not indicate success: 404 (PolicyAssignmentNotFound).' }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') })
            $r.ExitCode | Should -Be 0
            $r.Result.Created | Should -Be 1
        }
    }

    Context 'the assignment already exists (idempotent)' {
        It 'creates nothing, changes nothing and says so' {
            Mock Get-AzPolicyAssignment { [pscustomobject]@{ Id = $Id; Name = ($Id -split '/')[-1]; EnforcementMode = 'DoNotEnforce'; PolicyDefinitionId = $global:AzlTier1TestDefinitionId } }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('environment', 'owner') })
            $r.ExitCode | Should -Be 0
            $r.Result.Created | Should -Be 0
            $r.Result.AlreadyAssigned | Should -Be 2
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
            $r.Text | Should -Match 'Nothing to do'
            $r.Text | Should -Match 'already assigned, nothing changed'
        }

        It 'creates only the missing ones when some exist' {
            Mock Get-AzPolicyAssignment { if ($Id -like '*req-tag-owner') { [pscustomobject]@{ Id = $Id; EnforcementMode = 'DoNotEnforce'; PolicyDefinitionId = $global:AzlTier1TestDefinitionId } } }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('environment', 'owner') })
            $r.Result.Created | Should -Be 1
            $r.Result.AlreadyAssigned | Should -Be 1
            Should -Invoke New-AzPolicyAssignment -Times 1 -Exactly -ParameterFilter { $Name -eq 'req-tag-environment' }
        }

        It 'warns, and leaves the assignment alone, when an existing one enforces' {
            Mock Get-AzPolicyAssignment { [pscustomobject]@{ Id = $Id; EnforcementMode = 'Default'; PolicyDefinitionId = $global:AzlTier1TestDefinitionId } }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') })
            $r.ExitCode | Should -Be 0
            $r.Result.AlreadyAssigned | Should -Be 1
            $r.Result.Assignments[0].Detail | Should -Match 'Differs from Tier 1'
            $r.Text | Should -Match 'left unchanged'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans the assignments and creates none' {
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('environment', 'owner') }) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Planned | Should -Be 2
            $r.Result.Created | Should -Be 0
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
            $r.Text | Should -Match 'would be assigned'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'tier1.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile @{ required_tags = @('owner') }) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be assigned'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses an empty landing_zone.policy.required_tags' {
            $r = Invoke-Tier1 (New-InfraFile @{ management_group = 'mg-example' })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'required_tags is empty'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a file without landing_zone.policy at all' {
            $r = Invoke-Tier1 (New-InfraFile $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'required_tags is empty'
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') } -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }

        It 'refuses a tenant id that is not a GUID' {
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') } -TenantId 'not-a-guid')
            $r.ExitCode | Should -Be 2
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Tier1 (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }

        It 'refuses a tag name Azure does not allow' {
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('cost/center') })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'does not allow'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }

        It 'refuses two tags that give the same assignment name, before creating anything' {
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('cost_center', 'Cost-Center') })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'same assignment name'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }

        It 'refuses an invalid management group id: <_>' -ForEach 'bad group!', 'ends-with-period.', '-starts-with-hyphen' {
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner'); management_group = $_ })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'management_group'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') })
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') })
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
        }

        It 'stops when the built-in definition cannot be read' {
            Mock Get-AzPolicyDefinition { throw 'denied' }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') })
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
        }

        It 'reports a failed create, still creates the others, and exits 1' {
            Mock New-AzPolicyAssignment { if ($Name -eq 'req-tag-owner') { throw 'AuthorizationFailed' } else { [pscustomobject]@{ Name = $Name } } }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('environment', 'owner', 'workload') })
            $r.ExitCode | Should -Be 1
            $r.Result.Created | Should -Be 2
            $r.Result.Failed | Should -Be 1
            ($r.Result.Assignments | Where-Object Action -EQ 'Failed').Detail | Should -Match 'AuthorizationFailed'
        }

        It 'does not hide an error other than not-found when it looks for an assignment' {
            Mock Get-AzPolicyAssignment { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Tier1 (New-InfraFile @{ required_tags = @('owner') })
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            Should -Invoke New-AzPolicyAssignment -Times 0 -Exactly
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

        It 'reads its values through the toolkit loader, never variables.yml, and holds no environment value' {
            $script:Text | Should -Match 'Import-AzlInfrastructure'
            $script:Text | Should -Not -Match 'variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            # the only GUID in the file is the built-in policy definition
            $guids = [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Value | Sort-Object -Unique
            @($guids) | Should -Be @('871b6d14-10aa-478d-b590-94f262ecfa99')
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $registryScripts = [IO.Path]::Combine($repo, 'config', 'variables', 'scripts')
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Invoke_AzurePolicyTier1_Orchestrated_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'has its registry keys landing_zone.policy.required_tags and management_group, added in schema 5.6.5' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'landing_zone.policy.required_tags', 'landing_zone.policy.management_group') {
                $entry = $registry | Where-Object Path -EQ $key
                $entry | Should -Not -BeNullOrEmpty -Because $key
                $entry.Node['since'] | Should -Be '5.6.5'
                $entry.HasDefault | Should -BeFalse -Because 'the tools assume no tag names and no management group'
            }
        }
    }
}
