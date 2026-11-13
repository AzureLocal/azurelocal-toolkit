#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), full deployment, task 02: Deploy-Subscriptions.ps1 creates the subscriptions of landing_zone.subscriptions that have no id,
# with a subscription alias, under the billing scope and management group of the entry. Every Az cmdlet is mocked: no Azure, no tenant, no sign-in
# is used. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/Subscriptions.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment', 'task-02-create-subscriptions', 'powershell', 'Deploy-Subscriptions.ps1')
    Import-Module powershell-yaml

    # Stubs with the Az signatures the script uses, so the mocks work whether or not Az.Subscription is installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzSubscriptionAlias { [CmdletBinding()] param([string]$AliasName) }
    function New-AzSubscriptionAlias { [CmdletBinding()] param([string]$AliasName, [string]$SubscriptionName, [string]$BillingScope, [string]$Workload, [string]$ManagementGroupId, [hashtable]$Tag) }

    $global:AzlSubTestTenant = [guid]::NewGuid().ToString()
    $global:AzlSubTestNewId = [guid]::NewGuid().ToString()
    $script:Scope = '/providers/Microsoft.Billing/billingAccounts/1234567/enrollmentAccounts/7654321'

    function New-InfraFile {
        param([object[]]$Subscriptions, [object]$TenantId = $global:AzlSubTestTenant, [object]$Tags = $null)
        $doc = [ordered]@{ azure = [ordered]@{ location = 'eastus' } }
        if ($null -ne $TenantId) { $doc.azure.tenant_id = $TenantId }
        if ($null -ne $Subscriptions) { $doc.landing_zone = [ordered]@{ subscriptions = @($Subscriptions) } }
        if ($Tags) { $doc.tags = $Tags }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function New-Sub([string]$Name, [string]$Scope = $script:Scope, [string]$Group = 'mg-iic-platform', [string]$Id, [string]$Workload) {
        $s = [ordered]@{ name = $Name; role = 'management' }
        if ($Scope) { $s.billing_scope = $Scope }
        if ($Group) { $s.management_group = $Group }
        if ($Id) { $s.id = $Id }
        if ($Workload) { $s.workload = $Workload }
        $s
    }
    function Invoke-Deploy([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Subscription'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
}

Describe 'Deploy-Subscriptions.ps1' {
    AfterAll { Remove-Variable -Name AzlSubTestTenant, AzlSubTestNewId -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlSubTestTenant } } }
        Mock Get-AzSubscriptionAlias { throw "The subscription alias '$AliasName' could not be found (404 NotFound)." }
        Mock New-AzSubscriptionAlias { [pscustomobject]@{ AliasName = $AliasName; SubscriptionId = $global:AzlSubTestNewId } }
    }

    Context 'creating subscriptions' {
        It 'creates the subscription under the billing scope and management group of the entry and prints its id' {
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-iic-management')))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $r.Rows[0].SubscriptionId | Should -Be $global:AzlSubTestNewId
            Should -Invoke New-AzSubscriptionAlias -Times 1 -Exactly -ParameterFilter {
                $AliasName -eq 'sub-iic-management' -and $SubscriptionName -eq 'sub-iic-management' -and $BillingScope -eq $script:Scope -and $Workload -eq 'Production' -and $ManagementGroupId -eq 'mg-iic-platform'
            }
        }

        It 'uses the workload of the entry, and puts the file-level tags on the subscription' {
            $null = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-iic-dev' -Workload 'DevTest')) -Tags ([ordered]@{ environment = 'lab' }))
            Should -Invoke New-AzSubscriptionAlias -Times 1 -Exactly -ParameterFilter { $Workload -eq 'DevTest' -and $Tag -and $Tag['environment'] -eq 'lab' }
        }

        It 'creates one subscription for each entry without an id and sends no management group when the entry has none' {
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-a'), (New-Sub 'sub-b' -Group '')))
            $r.Rows.Count | Should -Be 2
            Should -Invoke New-AzSubscriptionAlias -Times 1 -Exactly -ParameterFilter { $AliasName -eq 'sub-a' -and $ManagementGroupId -eq 'mg-iic-platform' }
            Should -Invoke New-AzSubscriptionAlias -Times 1 -Exactly -ParameterFilter { $AliasName -eq 'sub-b' -and -not $ManagementGroupId }
        }

        It 'creates only subscriptions and never cancels, renames or moves one' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'Remove-AzSubscriptionAlias|Rename-AzSubscription|Stop-AzSubscription|New-AzManagementGroupSubscription|Get-AzEnrollmentAccount'
        }
    }

    Context 'idempotence and existing subscriptions' {
        It 'creates nothing when the alias exists, and reports its subscription id' {
            Mock Get-AzSubscriptionAlias { [pscustomobject]@{ AliasName = $AliasName; SubscriptionId = $global:AzlSubTestNewId } }
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-iic-management')))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Rows[0].SubscriptionId | Should -Be $global:AzlSubTestNewId
            Should -Invoke New-AzSubscriptionAlias -Times 0 -Exactly
        }

        It 'skips an entry that has an id, and treats the all-zero placeholder as no id' {
            $real = [guid]::NewGuid().ToString()
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-existing' -Id $real -Scope ''), (New-Sub 'sub-new' -Id ([guid]::Empty.ToString()))))
            $r.ExitCode | Should -Be 0
            ($r.Rows | Where-Object Subscription -EQ 'sub-existing').Action | Should -Be 'Skipped'
            ($r.Rows | Where-Object Subscription -EQ 'sub-new').Action | Should -Be 'Created'
            Should -Invoke New-AzSubscriptionAlias -Times 1 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'plans the subscription and creates nothing' {
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-iic-management'))) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Should -Invoke New-AzSubscriptionAlias -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses a missing or non-GUID azure.tenant_id' {
            (Invoke-Deploy (New-InfraFile @((New-Sub 'sub-a')) -TenantId $null)).ExitCode | Should -Be 2
            (Invoke-Deploy (New-InfraFile @((New-Sub 'sub-a')) -TenantId 'x')).ExitCode | Should -Be 2
            Should -Invoke Get-AzContext -Times 0 -Exactly
        }

        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a file with no subscription'; Entries = @() }
            @{ Why = 'an entry with no name'; Entries = @([ordered]@{ billing_scope = '/providers/Microsoft.Billing/billingAccounts/1/enrollmentAccounts/2' }) }
            @{ Why = 'an entry with no billing scope'; Entries = @([ordered]@{ name = 'sub-a' }) }
            @{ Why = 'a billing scope that is not one'; Entries = @([ordered]@{ name = 'sub-a'; billing_scope = 'enterprise' }) }
            @{ Why = 'a workload that is not Production or DevTest'; Entries = @([ordered]@{ name = 'sub-a'; billing_scope = '/providers/Microsoft.Billing/billingAccounts/1/enrollmentAccounts/2'; workload = 'Test' }) }
            @{ Why = 'the same name twice'; Entries = @([ordered]@{ name = 'sub-a'; billing_scope = '/providers/Microsoft.Billing/billingAccounts/1/enrollmentAccounts/2' }, [ordered]@{ name = 'SUB-A'; billing_scope = '/providers/Microsoft.Billing/billingAccounts/1/enrollmentAccounts/2' }) }
            @{ Why = 'a file where every entry has an id'; Entries = @([ordered]@{ name = 'sub-a'; id = '11111111-2222-3333-4444-555555555555' }) }
        ) {
            $r = Invoke-Deploy (New-InfraFile $Entries)
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke New-AzSubscriptionAlias -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Deploy (New-InfraFile @((New-Sub 'sub-a')))).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-a')))
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke New-AzSubscriptionAlias -Times 0 -Exactly
        }

        It 'does not hide a lookup error that is not a not-found' {
            Mock Get-AzSubscriptionAlias { throw 'The client does not have authorization to perform action.' }
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-a')))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            Should -Invoke New-AzSubscriptionAlias -Times 0 -Exactly
        }

        It 'reports a failed creation, goes on with the next one, and exits 1' {
            Mock New-AzSubscriptionAlias { if ($AliasName -eq 'sub-a') { throw 'AuthorizationFailed' } else { [pscustomobject]@{ SubscriptionId = $global:AzlSubTestNewId } } }
            $r = Invoke-Deploy (New-InfraFile @((New-Sub 'sub-a'), (New-Sub 'sub-b')))
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed', 'Created')
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
            $script:Text | Should -Not -Match 'variables\.yml|azure\.management_groups'
            $script:Text | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
            [regex]::Matches($script:Text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}').Count | Should -Be 0
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match 'Deploy_Subscriptions_ps1' })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @(& (Join-Path $repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'azure.tenant_id', 'tags', 'landing_zone.subscriptions[].name', 'landing_zone.subscriptions[].id', 'landing_zone.subscriptions[].billing_scope', 'landing_zone.subscriptions[].workload', 'landing_zone.subscriptions[].management_group' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}
