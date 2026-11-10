#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), full deployment, task 02: Invoke-SubscriptionMove-Orchestrated.ps1 puts the subscriptions of landing_zone.subscriptions under the
# management group named for each. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in is used. Subscription and tenant ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/SubscriptionMove.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment', 'task-02-create-subscriptions', 'powershell', 'Invoke-SubscriptionMove-Orchestrated.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not Az.Resources is installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzManagementGroup { [CmdletBinding()] param([string]$GroupName) }
    function Get-AzManagementGroupSubscription { [CmdletBinding()] param([string]$GroupName, [string]$SubscriptionId) }
    function New-AzManagementGroupSubscription {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$GroupName, [guid]$SubscriptionId)
    }

    $global:AzlMoveTestTenant = [guid]::NewGuid().ToString()
    $global:AzlMoveTestSubA = [guid]::NewGuid().ToString()
    $global:AzlMoveTestSubB = [guid]::NewGuid().ToString()
    $global:AzlMoveTestSubC = [guid]::NewGuid().ToString()

    function New-InfraFile([object[]]$Subscriptions, [object]$TenantId = $global:AzlMoveTestTenant) {
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $Subscriptions) { $doc.landing_zone = [ordered]@{ subscriptions = @($Subscriptions) } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Sub([string]$Name, [string]$Id, [string]$Group) {
        $s = [ordered]@{ name = $Name; role = 'workload' }
        if ($Id) { $s.id = $Id }
        if ($Group) { $s.management_group = $Group }
        $s
    }

    # Runs the script and returns its exit code, its result object and every message (information, warning, error) as text.
    function Invoke-Move([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Result   = ($all | Where-Object { $_.PSObject.Properties['Subscriptions'] } | Select-Object -First 1)
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Invoke-SubscriptionMove-Orchestrated.ps1' {
    AfterAll {
        Remove-Variable -Name AzlMoveTestTenant, AzlMoveTestSubA, AzlMoveTestSubB, AzlMoveTestSubC -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlMoveTestTenant } } }
        Mock Get-AzManagementGroup { [pscustomobject]@{ Name = $GroupName } }
        Mock Get-AzManagementGroupSubscription { $null }
        Mock New-AzManagementGroupSubscription { [pscustomobject]@{ Name = $SubscriptionId } }
    }

    Context 'moving subscriptions (happy path)' {
        It 'moves each subscription that is not under its group, to the group the file names' {
            $file = New-InfraFile @((New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'), (New-Sub 'sub-b' $global:AzlMoveTestSubB 'mg-landing-zones'))
            $r = Invoke-Move $file
            $r.ExitCode | Should -Be 0
            $r.Result.Moved | Should -Be 2
            $r.Result.Failed | Should -Be 0
            Should -Invoke New-AzManagementGroupSubscription -Times 2 -Exactly
            Should -Invoke New-AzManagementGroupSubscription -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-platform' -and "$SubscriptionId" -eq $global:AzlMoveTestSubA }
            Should -Invoke New-AzManagementGroupSubscription -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-landing-zones' -and "$SubscriptionId" -eq $global:AzlMoveTestSubB }
            $r.Text | Should -Match 'now under'
        }

        It 'looks each target group up once, however many subscriptions go under it' {
            $file = New-InfraFile @((New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'), (New-Sub 'sub-b' $global:AzlMoveTestSubB 'mg-platform'))
            $null = Invoke-Move $file
            Should -Invoke Get-AzManagementGroup -Times 1 -Exactly -ParameterFilter { $GroupName -eq 'mg-platform' }
        }

        It 'treats a not-found error from Azure as "not under that group yet" and moves' {
            Mock Get-AzManagementGroupSubscription { throw 'Response status code does not indicate success: 404 (NotFound).' }
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform')))
            $r.ExitCode | Should -Be 0
            $r.Result.Moved | Should -Be 1
        }
    }

    Context 'the subscription is already under its group (idempotent)' {
        It 'moves nothing and says so' {
            Mock Get-AzManagementGroupSubscription { [pscustomobject]@{ Name = $SubscriptionId; ParentId = "/providers/Microsoft.Management/managementGroups/$GroupName" } }
            $file = New-InfraFile @((New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'), (New-Sub 'sub-b' $global:AzlMoveTestSubB 'mg-landing-zones'))
            $r = Invoke-Move $file
            $r.ExitCode | Should -Be 0
            $r.Result.Moved | Should -Be 0
            $r.Result.AlreadyInPlace | Should -Be 2
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
            $r.Text | Should -Match 'Nothing to do'
            $r.Text | Should -Match 'already under'
        }

        It 'a mixed file moves only what is out of place, and skips what has no id or no group' {
            Mock Get-AzManagementGroupSubscription { if ($SubscriptionId -eq $global:AzlMoveTestSubA) { [pscustomobject]@{ Name = $SubscriptionId } } }
            $file = New-InfraFile @(
                (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'),
                (New-Sub 'sub-b' $global:AzlMoveTestSubB 'mg-platform'),
                (New-Sub 'sub-c' $global:AzlMoveTestSubC ''),
                (New-Sub 'sub-d' ([guid]::Empty.ToString()) 'mg-platform'),
                (New-Sub 'sub-e' '' 'mg-platform')
            )
            $r = Invoke-Move $file
            $r.ExitCode | Should -Be 0
            $r.Result.AlreadyInPlace | Should -Be 1
            $r.Result.Moved | Should -Be 1
            $r.Result.Skipped | Should -Be 3
            Should -Invoke New-AzManagementGroupSubscription -Times 1 -Exactly -ParameterFilter { "$SubscriptionId" -eq $global:AzlMoveTestSubB }
        }
    }

    Context '-WhatIf' {
        It 'plans the moves and makes none' {
            $file = New-InfraFile @((New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'), (New-Sub 'sub-b' $global:AzlMoveTestSubB 'mg-platform'))
            $r = Invoke-Move $file -DryRun
            $r.ExitCode | Should -Be 0
            $r.Result.Planned | Should -Be 2
            $r.Result.Moved | Should -Be 0
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
            $r.Text | Should -Match 'would be moved'
        }

        It 'still writes the progress lines to -LogPath' {
            $log = Join-Path $TestDrive 'move.log'
            $null = & $script:Script -InfrastructureFile (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'))) -LogPath $log -WhatIf 6>$null
            Get-Content -LiteralPath $log -Raw | Should -Match 'would be moved'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
        }
    }

    Context 'a value the script needs is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a file without landing_zone.subscriptions' {
            $r = Invoke-Move (New-InfraFile $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'landing_zone.subscriptions is empty'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses a file where no subscription has both an id and a management group' {
            $r = Invoke-Move (New-InfraFile @((New-Sub 'sub-a' '' 'mg-platform'), (New-Sub 'sub-b' $global:AzlMoveTestSubB '')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'nothing to move'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
        }

        It 'refuses a missing azure.tenant_id' {
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform')) -TenantId $null)
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'azure.tenant_id'
        }

        It 'refuses a subscription id that is not a GUID' {
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' 'not-a-guid' 'mg-platform')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'not a GUID'
        }

        It 'refuses an invalid management group id: <_>' -ForEach 'bad group!', 'ends-with-period.', '-starts-with-hyphen' {
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA $_)))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'management_group'
        }

        It 'refuses the same subscription id twice' {
            $r = Invoke-Move (New-InfraFile @((New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'), (New-Sub 'sub-b' $global:AzlMoveTestSubA 'mg-landing-zones')))
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'more than once'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
        }

        It 'refuses a file that does not exist' {
            $r = Invoke-Move (Join-Path $TestDrive 'nowhere.yml')
            $r.ExitCode | Should -Be 2
            $r.Text | Should -Match 'Cannot read the infrastructure file'
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in' {
            Mock Get-AzContext { $null }
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'Not signed in'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
        }

        It 'stops when the sign-in is to another tenant' {
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
        }

        It 'fails a subscription whose target management group does not exist, and still moves the others' {
            Mock Get-AzManagementGroup { if ($GroupName -eq 'mg-missing') { throw 'Management group mg-missing does not exist (404 NotFound).' } else { [pscustomobject]@{ Name = $GroupName } } }
            $file = New-InfraFile @((New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-missing'), (New-Sub 'sub-b' $global:AzlMoveTestSubB 'mg-platform'))
            $r = Invoke-Move $file
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            $r.Result.Moved | Should -Be 1
            ($r.Result.Subscriptions | Where-Object Action -EQ 'Failed').Detail | Should -Match 'does not exist'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly -ParameterFilter { $GroupName -eq 'mg-missing' }
        }

        It 'stops on a group lookup error that is not a not-found' {
            Mock Get-AzManagementGroup { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'could not be read'
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
        }

        It 'reports a failed move, still moves the others, and exits 1' {
            Mock New-AzManagementGroupSubscription { if ("$SubscriptionId" -eq $global:AzlMoveTestSubA) { throw 'AuthorizationFailed' } }
            $file = New-InfraFile @((New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform'), (New-Sub 'sub-b' $global:AzlMoveTestSubB 'mg-platform'))
            $r = Invoke-Move $file
            $r.ExitCode | Should -Be 1
            $r.Result.Moved | Should -Be 1
            $r.Result.Failed | Should -Be 1
            ($r.Result.Subscriptions | Where-Object Action -EQ 'Failed').Detail | Should -Match 'AuthorizationFailed'
        }

        It 'does not hide an error other than not-found when it looks where a subscription is' {
            Mock Get-AzManagementGroupSubscription { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Move (New-InfraFile @(, (New-Sub 'sub-a' $global:AzlMoveTestSubA 'mg-platform')))
            $r.ExitCode | Should -Be 1
            $r.Result.Failed | Should -Be 1
            Should -Invoke New-AzManagementGroupSubscription -Times 0 -Exactly
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
            $own = @($registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Invoke_SubscriptionMove_Orchestrated_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $registryScripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: azure.tenant_id and landing_zone.subscriptions[] name, id, management_group' {
            $registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
            foreach ($key in 'azure.tenant_id', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id', 'landing_zone.subscriptions[].management_group') {
                @($registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
            }
        }
    }
}
