#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# scripts/common/utilities/tools/Set-AzlDeploymentPolicyExemption.ps1 exempts the deployment resource groups from inherited
# deployIfNotExists and modify policy assignments. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are
# generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/utilities/DeploymentPolicyExemption.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'common', 'utilities', 'tools', 'Set-AzlDeploymentPolicyExemption.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not the Az modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceGroup { [CmdletBinding()] param([string]$Name) }
    function Get-AzPolicyAssignment { [CmdletBinding()] param([string]$Scope) }
    function Get-AzPolicyDefinition { [CmdletBinding()] param([string]$Id) }
    function Get-AzPolicySetDefinition { [CmdletBinding()] param([string]$Id) }
    function Get-AzPolicyExemption { [CmdletBinding()] param([string]$Scope) }
    function New-AzPolicyExemption { [CmdletBinding()] param([string]$Name, [string]$Scope, [object]$PolicyAssignment, [string]$ExemptionCategory, [string]$DisplayName, [string]$Description, [datetime]$ExpiresOn, [string[]]$PolicyDefinitionReferenceId) }
    function Remove-AzPolicyExemption { [CmdletBinding()] param([string]$Id, [switch]$Force) }
    function Get-AzSecurityPricing { [CmdletBinding()] param([string]$Name) }

    $global:AzlPeTestTenant = [guid]::NewGuid().ToString()
    $global:AzlPeTestSub = [guid]::NewGuid().ToString()
    $global:AzlPeTestHome = [guid]::NewGuid().ToString()
    $global:AzlPeTestMg = "/providers/Microsoft.Management/managementGroups/mg-$([guid]::NewGuid().ToString('N').Substring(0, 6))"

    function New-InfraFile {
        param([hashtable]$Azure = @{}, [hashtable]$Simplified = $null)
        $az = [ordered]@{ tenant_id = $global:AzlPeTestTenant; subscription_id = $global:AzlPeTestSub; resource_group = 'rg-iic-azl-01' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az }
        if ($Simplified) { $doc.provisioning = [ordered]@{ simplified = [ordered]@{} + $Simplified } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Exemption([string]$File, [switch]$DryRun, [switch]$Remove, [string[]]$Managed = @()) {
        $global:LASTEXITCODE = $null
        $arguments = @{ InfrastructureFile = $File }
        if ($DryRun) { $arguments.WhatIf = $true }
        if ($Remove) { $arguments.Remove = $true }
        if ($Managed) { $arguments.ManagedResourceGroupName = $Managed }
        $all = & $script:Script @arguments 6>&1 3>&1 2>&1
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['ResourceGroup'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Set-AzlDeploymentPolicyExemption.ps1' {
    AfterAll { Remove-Variable -Name AzlPeTestTenant, AzlPeTestSub, AzlPeTestHome, AzlPeTestMg -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlPeTestTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlPeTestHome } } }
        Mock Set-AzContext { }
        Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name } }
        Mock Get-AzPolicyAssignment {
            @(
                [pscustomobject]@{ Name = 'deploy-agent'; DisplayName = 'Deploy an agent'; Id = "$($global:AzlPeTestMg)/providers/Microsoft.Authorization/policyAssignments/deploy-agent"; Scope = $global:AzlPeTestMg; PolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/def-deploy'; Parameter = $null }
                [pscustomobject]@{ Name = 'audit-tags'; DisplayName = 'Audit tags'; Id = "$($global:AzlPeTestMg)/providers/Microsoft.Authorization/policyAssignments/audit-tags"; Scope = $global:AzlPeTestMg; PolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/def-audit'; Parameter = $null }
            )
        }
        Mock Get-AzPolicyDefinition {
            $effect = if ($Id -match 'def-deploy') { 'deployIfNotExists' } else { 'audit' }
            [pscustomobject]@{ PolicyRule = @{ then = @{ effect = $effect } }; Parameter = $null }
        }
        Mock Get-AzPolicySetDefinition { }
        Mock Get-AzPolicyExemption { @() }
        Mock New-AzPolicyExemption { [pscustomobject]@{ Name = $Name } }
        Mock Remove-AzPolicyExemption { }
        Mock Get-AzSecurityPricing { [pscustomobject]@{ PricingTier = 'Free'; SubPlan = $null } }
    }

    Context 'creating exemptions' {
        It 'exempts only the assignment that deploys, in the resource group of the file, and puts the subscription back' {
            $r = Invoke-Exemption (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'Exempted').Count | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'LeftInForce').Count | Should -Be 1
            Should -Invoke New-AzPolicyExemption -Times 1 -Exactly -ParameterFilter { $Scope -eq "/subscriptions/$($global:AzlPeTestSub)/resourceGroups/rg-iic-azl-01" -and $ExemptionCategory -eq 'Waiver' -and $Name -like 'azl-deploy-*' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlPeTestHome }
        }

        It 'also exempts provisioning.simplified.resource_group, the managed resource group of the file and -ManagedResourceGroupName' {
            $r = Invoke-Exemption (New-InfraFile -Simplified @{ resource_group = 'rg-iic-edge-01'; managed_resource_group_name = 'rg-iic-site-managed' }) -Managed 'rg-iic-azure-named'
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.ResourceGroup | Sort-Object -Unique) | Should -Be @('rg-iic-azl-01', 'rg-iic-azure-named', 'rg-iic-edge-01', 'rg-iic-site-managed')
            Should -Invoke New-AzPolicyExemption -Times 4 -Exactly
        }

        It 'exempts the groups of the site in provisioning.simplified.subscription_id when the file names another subscription' {
            $site = [guid]::NewGuid().ToString()
            $r = Invoke-Exemption (New-InfraFile -Simplified @{ subscription_id = $site; resource_group = 'rg-iic-edge-01' })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke New-AzPolicyExemption -Times 1 -Exactly -ParameterFilter { $Scope -eq "/subscriptions/$site/resourceGroups/rg-iic-edge-01" }
            Should -Invoke New-AzPolicyExemption -Times 1 -Exactly -ParameterFilter { $Scope -eq "/subscriptions/$($global:AzlPeTestSub)/resourceGroups/rg-iic-azl-01" }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $site }
        }

        It 'leaves an excluded assignment in force' {
            $global:LASTEXITCODE = $null
            $all = & $script:Script -InfrastructureFile (New-InfraFile) -ExcludeAssignmentName 'deploy-agent' 6>&1 3>&1 2>&1
            $LASTEXITCODE | Should -Be 0
            @($all | Where-Object { $_.PSObject.Properties['Action'] -and $_.Action -eq 'Excluded' }).Count | Should -Be 1
            Should -Invoke New-AzPolicyExemption -Times 0 -Exactly
        }
    }

    Context 'idempotent, -WhatIf and -Remove' {
        It 'reports an exemption it already made and makes no second one' {
            Mock Get-AzPolicyExemption {
                $scope = "/subscriptions/$($global:AzlPeTestSub)/resourceGroups/rg-iic-azl-01"
                $assignment = "$($global:AzlPeTestMg)/providers/Microsoft.Authorization/policyAssignments/deploy-agent"
                $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$scope|$assignment".ToLowerInvariant()))
                [pscustomobject]@{ Name = 'azl-deploy-' + (-join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })); Id = 'x'; DisplayName = 'azl-deploy: Deploy an agent'; Description = 'azl-deploy: temporary exemption while Azure Local machines are provisioned and the cluster is deployed. Created.'; ExpiresOn = (Get-Date).AddDays(3) }
            }
            $r = Invoke-Exemption (New-InfraFile)
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'AlreadyExempt').Count | Should -Be 1
            Should -Invoke New-AzPolicyExemption -Times 0 -Exactly
        }

        It '-WhatIf lists what it would do and changes nothing' {
            $r = Invoke-Exemption (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'WouldExempt').Count | Should -Be 1
            Should -Invoke New-AzPolicyExemption -Times 0 -Exactly
        }

        It '-Remove deletes only the exemptions this script made' {
            Mock Get-AzPolicyExemption {
                [pscustomobject]@{ Name = 'azl-deploy-0a1b2c3d4e5f'; Id = 'ours'; DisplayName = 'azl-deploy: Deploy an agent'; Description = 'azl-deploy: temporary exemption while Azure Local machines are provisioned and the cluster is deployed. Created.' }
                [pscustomobject]@{ Name = 'owner-exemption'; Id = 'theirs'; DisplayName = 'Owner'; Description = 'Made by the owner.' }
            }
            $r = Invoke-Exemption (New-InfraFile) -Remove
            $r.ExitCode | Should -Be 0
            Should -Invoke Remove-AzPolicyExemption -Times 1 -Exactly -ParameterFilter { $Id -eq 'ours' }
            Should -Invoke New-AzPolicyExemption -Times 0 -Exactly
        }

        It 'skips a resource group that does not exist yet' {
            Mock Get-AzResourceGroup { $null }
            $r = Invoke-Exemption (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'NotFound'
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.<Key>' -ForEach @(@{ Key = 'tenant_id' }, @{ Key = 'subscription_id' }, @{ Key = 'resource_group' }) {
            $r = Invoke-Exemption (New-InfraFile -Azure @{ $Key = $null })
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match "azure.$Key"
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
        It 'refuses the all-zero subscription id and a resource group name Azure does not allow' {
            (Invoke-Exemption (New-InfraFile -Azure @{ subscription_id = [guid]::Empty.ToString() })).ExitCode | Should -Be 2
            (Invoke-Exemption (New-InfraFile -Azure @{ resource_group = 'rg-ends-with-a-dot.' })).ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Exemption (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Exemption (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzPolicyExemption -Times 0 -Exactly
        }
        It 'reports a failed exemption and exits 1' {
            Mock New-AzPolicyExemption { throw 'AuthorizationFailed' }
            $r = Invoke-Exemption (New-InfraFile)
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed').Count | Should -Be 1
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }
        It 'carries the standard header, takes the file and never prompts' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Match 'SupportsShouldProcess'
            $script:Text | Should -Match '\[Parameter\(Mandatory\)\]\[string\]\$InfrastructureFile'
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|\$SubscriptionId\s*,|\[string\[\]\]\$ResourceGroupName|-Execute\b'
        }
        It 'holds no GUID or address' {
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }
        It 'has every parameter in the master registry' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Set_AzlDeploymentPolicyExemption_ps1' })
            $names = @($own | ForEach-Object { $_.Node['name'] })
            foreach ($p in 'InfrastructureFile', 'ManagedResourceGroupName', 'ExpiresInDays', 'ExcludeAssignmentName', 'Remove', 'LogPath') { $names | Should -Contain $p }
        }
        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'provisioning.simplified.subscription_id', 'provisioning.simplified.resource_group', 'provisioning.simplified.managed_resource_group_name' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
