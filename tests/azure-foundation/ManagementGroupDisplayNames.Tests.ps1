#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), full deployment, task 01: Set-ManagementGroupDisplayNames.ps1 sets the display name that landing_zone.management_groups gives each existing
# management group. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. The tenant id is generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/ManagementGroupDisplayNames.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant id.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment', 'task-01-configure-management-groups', 'powershell', 'Set-ManagementGroupDisplayNames.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not Az.Resources is installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzManagementGroup { [CmdletBinding()] param([string]$GroupName) }
    function Update-AzManagementGroup {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$GroupName, [string]$DisplayName)
    }

    $global:AzlMgTestTenant = [guid]::NewGuid().ToString()

    function New-InfraFile([object[]]$Groups, [object]$TenantId = $global:AzlMgTestTenant) {
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $Groups) { $doc.landing_zone = [ordered]@{ management_groups = @($Groups) } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-MgEntry([string]$Name, [string]$Display) {
        $g = [ordered]@{ name = $Name; parent = 'mg-root' }
        if ($Display) { $g.display_name = $Display }
        $g
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Rename([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['ManagementGroups'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Set-ManagementGroupDisplayNames.ps1' {
    AfterAll {
        Remove-Variable -Name AzlMgTestTenant -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlMgTestTenant } } }
        Mock Get-AzManagementGroup { [pscustomobject]@{ Name = $GroupName; DisplayName = 'Old name' } }
        Mock Update-AzManagementGroup { [pscustomobject]@{ Name = $GroupName; DisplayName = $DisplayName } }
    }

    Context 'renaming (happy path)' {
        It 'sets the display name on each group whose display name differs' {
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-platform' 'Platform'), (New-MgEntry 'mg-landing-zones' 'Landing Zones')))
            $r.ExitCode | Should -Be 0
            $r.Result.Renamed | Should -Be 2
            $r.Result.Failed | Should -Be 0
            Should -Invoke Update-AzManagementGroup -Times 2 -Exactly
            Should -Invoke Update-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-platform' -and $DisplayName -eq 'Platform' }
            Should -Invoke Update-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-landing-zones' -and $DisplayName -eq 'Landing Zones' }
            $r.Text | Should -Match "'Old name' is now 'Platform'"
        }

        It 'reads the old display name into the result' {
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')))
            $r.Result.ManagementGroups[0].Detail | Should -Be "was 'Old name'"
        }

        It 'never changes the id of a group: Update-AzManagementGroup is called with the display name only' {
            $null = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')))
            Should -Invoke Update-AzManagementGroup -Times 1 -Exactly -ParameterFilter { -not $PSBoundParameters.ContainsKey('ParentId') -and -not $PSBoundParameters.ContainsKey('InputObject') }
        }

        It 'treats a different letter case as a different display name and renames' {
            Mock Get-AzManagementGroup { [pscustomobject]@{ Name = $GroupName; DisplayName = 'platform' } }
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')))
            $r.Result.Renamed | Should -Be 1
        }

        It 'trims the display name it writes' {
            $null = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' '  Platform  ')))
            Should -Invoke Update-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -ceq 'Platform' }
        }
    }

    Context 'the display name is already correct (idempotent)' {
        It 'changes nothing and says so' {
            Mock Get-AzManagementGroup { [pscustomobject]@{ Name = $GroupName; DisplayName = $(if ($GroupName -eq 'mg-platform') { 'Platform' } else { 'Landing Zones' }) } }
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-platform' 'Platform'), (New-MgEntry 'mg-landing-zones' 'Landing Zones')))
            $r.ExitCode | Should -Be 0
            $r.Result.Renamed | Should -Be 0
            $r.Result.AlreadyCorrect | Should -Be 2
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
            $r.Text | Should -Match 'Nothing to do'
        }

        It 'a mixed file renames only the group that differs and skips an entry with no display name' {
            Mock Get-AzManagementGroup { [pscustomobject]@{ Name = $GroupName; DisplayName = $(if ($GroupName -eq 'mg-platform') { 'Platform' } else { 'Old name' }) } }
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-platform' 'Platform'), (New-MgEntry 'mg-landing-zones' 'Landing Zones'), (New-MgEntry 'mg-sandbox' '')))
            $r.ExitCode | Should -Be 0
            $r.Result.AlreadyCorrect | Should -Be 1
            $r.Result.Renamed | Should -Be 1
            $r.Result.Skipped | Should -Be 1
            Should -Invoke Update-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-landing-zones' }
            Should -Invoke Get-AzManagementGroup -Times 0 -Exactly -ParameterFilter { $GroupName -eq 'mg-sandbox' }
        }
    }

    Context '-WhatIf' {
        It 'plans the renames and makes none' {
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-platform' 'Platform'), (New-MgEntry 'mg-landing-zones' 'Landing Zones'))) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Planned | Should -Be 2
            $r.Result.Renamed | Should -Be 0
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
            $r.Text | Should -Match 'would become'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'rename.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform'))) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would become'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without landing_zone.management_groups' {
            $r = Invoke-Rename (New-InfraFile $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'landing_zone.management_groups is empty'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a file where no group has a display name' {
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-platform' ''), (New-MgEntry 'mg-sandbox' '')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'nothing to rename'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')) -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses an entry with no name' {
            $r = Invoke-Rename (New-InfraFile @(, ([ordered]@{ display_name = 'No id' })))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'has no name'
        }

        It 'refuses an invalid management group id: <_>' -ForEach 'bad group!', 'ends-with-period.', '-starts-with-hyphen' {
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry $_ 'Platform')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not a valid management group id'
        }

        It 'refuses the same group twice, whatever the case' {
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-platform' 'Platform'), (New-MgEntry 'MG-Platform' 'Other')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Rename (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
        }

        It 'fails a group that does not exist, and still renames the others' {
            Mock Get-AzManagementGroup { if ($GroupName -eq 'mg-missing') { throw 'Management group mg-missing does not exist (404 NotFound).' } else { [pscustomobject]@{ Name = $GroupName; DisplayName = 'Old name' } } }
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-missing' 'Missing'), (New-MgEntry 'mg-platform' 'Platform')))
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            $r.Result.Renamed | Should -Be 1
            ($r.Result.ManagementGroups | Where-Object Action -EQ 'Failed').Detail | Should -Match 'does not exist'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly -ParameterFilter { $GroupName -eq 'mg-missing' }
        }

        It 'fails a group that the lookup returns nothing for' {
            Mock Get-AzManagementGroup { $null }
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')))
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzManagementGroup { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Rename (New-InfraFile @(, (New-MgEntry 'mg-platform' 'Platform')))
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            ($r.Result.ManagementGroups | Where-Object Action -EQ 'Failed').Detail | Should -Match 'authorization'
            Should -Invoke Update-AzManagementGroup -Times 0 -Exactly
        }

        It 'reports a failed rename, still renames the others, and exits 1' {
            Mock Update-AzManagementGroup { if ($GroupName -eq 'mg-platform') { throw 'AuthorizationFailed' } }
            $r = Invoke-Rename (New-InfraFile @((New-MgEntry 'mg-platform' 'Platform'), (New-MgEntry 'mg-landing-zones' 'Landing Zones')))
            $r.ExitCode | Should -Be 1
            $r.Result.Renamed | Should -Be 1
            $r.Result.Failed | Should -Be 1
            ($r.Result.ManagementGroups | Where-Object Action -EQ 'Failed').Detail | Should -Match 'AuthorizationFailed'
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
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Set_ManagementGroupDisplayNames_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: azure.tenant_id and landing_zone.management_groups[] name, display_name' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'landing_zone.management_groups[].name', 'landing_zone.management_groups[].display_name') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
        }
    }
}
