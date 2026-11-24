#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), task 04, Azure CLI variant: Deploy-CostBudgets.azcli.ps1 creates the Cost Management budgets of landing_zone.budgets with
# "az rest" (the Microsoft.Consumption budgets REST API) and keeps them as the file says. "az" is mocked: no Azure, no tenant and no sign-in is used.
# Ids are generated per run. The checks of the values themselves are in CostBudgets.Tests.ps1 (both scripts share AzlCostBudget.psm1).
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/CostBudgets.AzCli.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant and the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment', 'task-04-create-cost-budgets', 'azurecli', 'Deploy-CostBudgets.azcli.ps1')
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'AzCliTestSupport.ps1'))
    function az { }

    $global:AzlFakeTenant = [guid]::NewGuid().ToString()
    $global:AzlCbcHome = [guid]::NewGuid().ToString()
    $global:AzlCbcSubA = [guid]::NewGuid().ToString()
    $script:FirstOfMonth = '{0:yyyy-MM}-01' -f [datetime]::UtcNow

    function New-InfraFile {
        param([object[]]$Budgets = @([ordered]@{ name = 'budget-iic-azl-monthly'; amount = 1000; contact_emails = @('cloud-costs@example.com') }), [hashtable]$Azure = @{}, [switch]$NoBudgets)
        $az = Set-AzOverride ([ordered]@{ tenant_id = $global:AzlFakeTenant; subscription_id = $global:AzlCbcHome; location = 'eastus' }) $Azure
        $lz = [ordered]@{ subscriptions = @([ordered]@{ name = 'sub-iic-management'; id = $global:AzlCbcSubA; role = 'management' }) }
        if (-not $NoBudgets) { $lz.budgets = @($Budgets) }
        Save-AzInfraFile ([ordered]@{ azure = $az; landing_zone = $lz })
    }
    # The PUT route: keeps the body that the script wrote to the file named by --body @<file> (the file is gone after the call).
    $script:PutRoute = {
        $list = @($args | ForEach-Object { "$_" })
        $i = [Array]::IndexOf($list, '--body')
        $global:AzlCbcBodies.Add([IO.File]::ReadAllText($list[$i + 1].Substring(1)))
        '{"name":"x"}'
    }
    function New-ExistingBudget([decimal]$Amount = 1000, [string]$Start = $script:FirstOfMonth) {
        [ordered]@{ name = 'budget-iic-azl-monthly'; eTag = '"abc"'; properties = [ordered]@{ category = 'Cost'; amount = $Amount; timeGrain = 'Monthly'
                timePeriod = [ordered]@{ startDate = "$($Start)T00:00:00Z"; endDate = '2036-10-31T00:00:00Z' }
                notifications = [ordered]@{
                    Actual_GreaterThan_80_Percent  = [ordered]@{ enabled = $true; operator = 'GreaterThan'; threshold = 80; thresholdType = 'Actual'; contactEmails = @('cloud-costs@example.com') }
                    Actual_GreaterThan_100_Percent = [ordered]@{ enabled = $true; operator = 'GreaterThan'; threshold = 100; thresholdType = 'Actual'; contactEmails = @('cloud-costs@example.com') }
                } } }
    }
}

Describe 'Deploy-CostBudgets.azcli.ps1' {
    AfterAll { Remove-Variable -Name AzlFakeTenant, AzlCbcHome, AzlCbcSubA, AzlCbcBodies, AzlFakeCalls, AzlFakeRoutes -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Initialize-AzFake
        $global:AzlCbcBodies = [System.Collections.Generic.List[string]]::new()
        Mock az { Invoke-AzFake $args }
        Add-AzRoute 'rest --method get *' "ERROR: Not Found({`"error`":{`"code`":`"NotFound`",`"message`":`"Budget not found.`"}})" 1
        Add-AzRoute 'rest --method put *' $script:PutRoute
    }

    Context 'creating budgets' {
        It 'reads the budget, then creates it with one az rest PUT whose body goes through a file' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $url = "/subscriptions/$($global:AzlCbcHome)/providers/Microsoft.Consumption/budgets/budget-iic-azl-monthly?api-version=2024-08-01"
            Get-AzCall "rest --method get --url $url --output json --only-show-errors" | Should -HaveCount 1
            Get-AzCall "rest --method put --url $url --headers Content-Type=application/json --body @*" | Should -HaveCount 1
            $global:AzlCbcBodies | Should -HaveCount 1
            $global:AzlCbcBodies[0] | Should -Match ([regex]::Escape("`"startDate`":`"$($script:FirstOfMonth)T00:00:00Z`""))
            $body = $global:AzlCbcBodies[0] | ConvertFrom-Json -Depth 20
            $body.properties.amount | Should -Be 1000
            $body.properties.category | Should -Be 'Cost'
            @($body.properties.notifications.PSObject.Properties.Name) | Should -Be @('Actual_GreaterThan_80_Percent', 'Actual_GreaterThan_100_Percent')
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'azl-budget-*.json') | Should -HaveCount 0
        }

        It 'puts a resource group budget under the resource group of the named subscription' {
            $b = [ordered]@{ name = 'b-rg'; scope = 'resource_group'; subscription = 'sub-iic-management'; resource_group = 'rg-iic-mgmt-01'; amount = 50; forecast_thresholds = @(100); contact_emails = @('a@example.com') }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Budgets @($b))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            Get-AzCall "rest --method put --url /subscriptions/$($global:AzlCbcSubA)/resourceGroups/rg-iic-mgmt-01/providers/Microsoft.Consumption/budgets/b-rg?api-version=*" | Should -HaveCount 1
            ($global:AzlCbcBodies[0] | ConvertFrom-Json).properties.notifications.Forecasted_GreaterThan_100_Percent.thresholdType | Should -Be 'Forecasted'
        }
    }

    Context 'a budget exists already (idempotent)' {
        It 'leaves a budget that matches the file alone' {
            Add-AzRoute 'rest --method get *' (New-ExistingBudget)
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            Get-AzCall 'rest --method put *' | Should -HaveCount 0
        }

        It 'updates a budget that differs, with its eTag and its start date' {
            Add-AzRoute 'rest --method get *' (New-ExistingBudget -Amount 10 -Start '2026-01-01')
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Updated'
            $global:AzlCbcBodies[0] | Should -Match '"eTag":"\\"abc\\""'
            $global:AzlCbcBodies[0] | Should -Match '"startDate":"2026-01-01T00:00:00Z"'
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'reads Azure and writes nothing' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Get-AzCall 'rest --method get *' | Should -HaveCount 1
            Get-AzWriteCall | Where-Object { $_ -notmatch '^rest --method get ' } | Should -BeNullOrEmpty
        }

        It 'makes no az call when the file lists no budget' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -NoBudgets)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Get-AzCall | Should -HaveCount 0
        }
    }

    Context 'refusals and failures' {
        It 'refuses a value the file cannot use with exit 2 and no az call' {
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Budgets @([ordered]@{ name = 'b1'; amount = 0; contact_emails = @('a@example.com') }))
            $r.ExitCode | Should -Be 2
            Get-AzCall | Should -HaveCount 0
        }

        It 'stops when az is signed in to another tenant' {
            Add-AzRoute 'account show*' ([guid]::NewGuid().ToString())
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Get-AzCall 'rest *' | Should -HaveCount 0
        }

        It 'does not take a missing resource group for a missing budget' {
            Add-AzRoute 'rest --method get *' 'ERROR: Not Found({"error":{"code":"ResourceGroupNotFound","message":"Resource group rg-iic-mgmt-01 could not be found."}})' 1
            $b = [ordered]@{ name = 'b-rg'; scope = 'resource_group'; resource_group = 'rg-iic-mgmt-01'; amount = 10; contact_emails = @('a@example.com') }
            $r = Invoke-AzCliScript $script:Script (New-InfraFile -Budgets @($b))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'ResourceGroupNotFound'
            Get-AzCall 'rest --method put *' | Should -HaveCount 0
        }

        It 'does not take a read error for a missing budget, and reports a refused write' {
            Add-AzRoute 'rest --method get *' 'ERROR: (AuthorizationFailed) The client does not have authorization.' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            Get-AzCall 'rest --method put *' | Should -HaveCount 0
            Add-AzRoute 'rest --method get *' "ERROR: Not Found({`"error`":{`"code`":`"NotFound`"}})" 1
            Add-AzRoute 'rest --method put *' 'ERROR: Bad Request({"error":{"code":"InvalidBudget"}})' 1
            $r = Invoke-AzCliScript $script:Script (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'InvalidBudget'
        }
    }
}
