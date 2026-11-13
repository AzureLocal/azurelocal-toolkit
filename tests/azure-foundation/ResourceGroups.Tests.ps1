#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), task 03: Deploy-ResourceGroups.ps1 creates the resource groups of landing_zone.resource_groups (or the one azure.resource_group
# when the file has no landing zone). Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ResourceGroups.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment', 'task-03-create-resource-groups', 'powershell', 'Deploy-ResourceGroups.ps1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceGroup { [CmdletBinding()] param([string]$Name) }
    function New-AzResourceGroup { [CmdletBinding()] param([string]$Name, [string]$Location, [hashtable]$Tag, [switch]$Force) }

    $global:AzlRgTenant = [guid]::NewGuid().ToString()
    $global:AzlRgHome = [guid]::NewGuid().ToString()
    $global:AzlRgSubA = [guid]::NewGuid().ToString()
    $global:AzlRgSubB = [guid]::NewGuid().ToString()

    function New-InfraFile {
        param([object[]]$Groups = @(
                [ordered]@{ name = 'rg-iic-conn-01'; subscription = 'sub-iic-connectivity'; location = 'westeurope'; purpose = 'hub network' }
                [ordered]@{ name = 'rg-iic-mgmt-01'; subscription = 'sub-iic-management'; purpose = 'management machines' }
            ), [hashtable]$Azure = @{}, [object]$Tags = $null, [switch]$NoGroups, [switch]$NoSubscriptions)
        $az = [ordered]@{ tenant_id = $global:AzlRgTenant; subscription_id = $global:AzlRgHome; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $doc = [ordered]@{ azure = $az }
        $lz = [ordered]@{}
        if (-not $NoSubscriptions) {
            $lz.subscriptions = @(
                [ordered]@{ name = 'sub-iic-connectivity'; id = $global:AzlRgSubA; role = 'connectivity' }
                [ordered]@{ name = 'sub-iic-management'; id = $global:AzlRgSubB; role = 'management' }
            )
        }
        if (-not $NoGroups) { $lz.resource_groups = @($Groups) }
        if ($lz.Count) { $doc.landing_zone = $lz }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Groups([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['ResourceGroup'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Deploy-ResourceGroups.ps1' {
    AfterAll { Remove-Variable -Name AzlRgTenant, AzlRgHome, AzlRgSubA, AzlRgSubB -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlRgTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlRgHome } } }
        Mock Set-AzContext { }
        Mock Get-AzResourceGroup { throw "Provided resource group does not exist." }
        Mock New-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name; Location = $Location } }
    }

    Context 'creating resource groups' {
        It 'creates each group in the subscription and location the entry names, and uses azure.location when the entry has none' {
            $r = Invoke-Groups (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows | Where-Object Action -EQ 'Created').Count | Should -Be 2
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlRgSubA }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlRgSubB }
            Should -Invoke New-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'rg-iic-conn-01' -and $Location -eq 'westeurope' }
            Should -Invoke New-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'rg-iic-mgmt-01' -and $Location -eq 'eastus' }
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlRgHome }
        }

        It 'puts the file-level tags on a group it creates and shows the purpose' {
            $r = Invoke-Groups (New-InfraFile -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzResourceGroup -Times 2 -Exactly -ParameterFilter { $Tag['environment'] -eq 'lab' }
            ($r.Rows | Where-Object ResourceGroup -EQ 'rg-iic-conn-01').Purpose | Should -Be 'hub network'
            $r.Text | Should -Match 'hub network'
        }

        It 'uses azure.subscription_id for an entry that names no subscription' {
            $null = Invoke-Groups (New-InfraFile -Groups @([ordered]@{ name = 'rg-iic-home-01' }))
            Should -Invoke Set-AzContext -Times 2 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlRgHome }   # once to select it, once to put the session back
            Should -Invoke New-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'rg-iic-home-01' }
        }

        It 'creates the one azure.resource_group when the file has no landing_zone.resource_groups' {
            $r = Invoke-Groups (New-InfraFile -NoGroups -NoSubscriptions -Azure @{ resource_group = 'rg-iic-azl-01' })
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke New-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'rg-iic-azl-01' -and $Location -eq 'eastus' }
        }

        It 'never removes, moves or changes a group' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-Az|Set-AzResourceGroup|Move-Az|Update-Az'
        }
    }

    Context 'a group exists already (idempotent)' {
        It 'creates nothing, says so, and reports another location without changing it' {
            Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name; Location = 'northeurope' } }
            $r = Invoke-Groups (New-InfraFile)
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'AlreadyExists').Count | Should -Be 2
            ($r.Rows | Where-Object ResourceGroup -EQ 'rg-iic-conn-01').Detail | Should -Match 'cannot change location'
            ($r.Rows | Where-Object ResourceGroup -EQ 'rg-iic-mgmt-01').Detail | Should -Match 'cannot change location'
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'does not report a difference when the location is the same, written with spaces or capitals' {
            Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = $Name; Location = 'West Europe' } }
            $r = Invoke-Groups (New-InfraFile -Groups @([ordered]@{ name = 'rg-iic-conn-01'; subscription = 'sub-iic-connectivity'; location = 'westeurope' }))
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].Detail | Should -BeNullOrEmpty
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'plans the groups and creates nothing' {
            $r = Invoke-Groups (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            @($r.Rows | Where-Object Action -EQ 'WouldCreate').Count | Should -Be 2
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'does nothing and does not touch Azure when the file lists no resource group at all' {
            $r = Invoke-Groups (New-InfraFile -NoGroups -NoSubscriptions)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing azure.tenant_id' {
            (Invoke-Groups (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a group with no name'; Groups = @([ordered]@{ subscription = 'sub-iic-connectivity' }) }
            @{ Why = 'a name Azure refuses (ends in a period)'; Groups = @([ordered]@{ name = 'rg-bad.'; subscription = 'sub-iic-connectivity' }) }
            @{ Why = 'a name with a space'; Groups = @([ordered]@{ name = 'rg bad'; subscription = 'sub-iic-connectivity' }) }
            @{ Why = 'a subscription that is not in landing_zone.subscriptions'; Groups = @([ordered]@{ name = 'rg-iic-x-01'; subscription = 'sub-other' }) }
            @{ Why = 'the same name twice in one subscription'; Groups = @([ordered]@{ name = 'rg-iic-x-01'; subscription = 'sub-iic-connectivity' }, [ordered]@{ name = 'RG-IIC-X-01'; subscription = 'sub-iic-connectivity' }) }
        ) {
            $r = Invoke-Groups (New-InfraFile -Groups $Groups)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'accepts the same name in two subscriptions' {
            $r = Invoke-Groups (New-InfraFile -Groups @([ordered]@{ name = 'rg-iic-x-01'; subscription = 'sub-iic-connectivity' }, [ordered]@{ name = 'rg-iic-x-01'; subscription = 'sub-iic-management' }))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Should -Invoke New-AzResourceGroup -Times 2 -Exactly
        }

        It 'refuses a subscription whose id is the all-zero placeholder or missing' {
            $file = New-InfraFile
            (Get-Content -LiteralPath $file -Raw) -replace [regex]::Escape($global:AzlRgSubA), [guid]::Empty.ToString() | Set-Content -LiteralPath $file
            $r = Invoke-Groups $file
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'no usable id'
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'refuses an entry with no location when azure.location is empty' {
            $r = Invoke-Groups (New-InfraFile -Azure @{ location = $null } -Groups @([ordered]@{ name = 'rg-iic-x-01'; subscription = 'sub-iic-connectivity' }))
            $r.ExitCode | Should -Be 2
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Groups (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Groups (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzResourceGroup { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Groups (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'reports a failed creation, goes on with the next group, puts the subscription back, and exits 1' {
            Mock New-AzResourceGroup { if ($Name -eq 'rg-iic-conn-01') { throw 'AuthorizationFailed' } else { [pscustomobject]@{ ResourceGroupName = $Name } } }
            $r = Invoke-Groups (New-InfraFile)
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object ResourceGroup -EQ 'rg-iic-conn-01').Action | Should -Be 'Failed'
            ($r.Rows | Where-Object ResourceGroup -EQ 'rg-iic-mgmt-01').Action | Should -Be 'Created'
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $global:AzlRgHome }
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
            $script:Text | Should -Not -Match 'azure_infrastructure|config-loader|Get-SolutionConfig|variables\.yml'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_ResourceGroups_ps1' -and $_.Path -match 'full_deployment' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'azure.subscription_id', 'azure.resource_group', 'azure.location', 'tags', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id', 'landing_zone.resource_groups[].name', 'landing_zone.resource_groups[].subscription', 'landing_zone.resource_groups[].location', 'landing_zone.resource_groups[].purpose' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
