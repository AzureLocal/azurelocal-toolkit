#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 01 (landing zones), task 04: Deploy-CostBudgets.ps1 creates the Cost Management budgets of landing_zone.budgets with the Microsoft.Consumption
# budgets REST API (Invoke-AzRestMethod) and keeps them as the file says. Get-AzContext and Invoke-AzRestMethod are mocked: no Azure, no tenant, no
# sign-in is used. Ids are generated per run. The shared logic (AzlCostBudget.psm1) is also tested on its own.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/azure-foundation/CostBudgets.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the tenant, the ids and the answers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the Az cmdlets.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '02-azure-foundation', 'phase-01-landing-zones', 'full-deployment', 'task-04-create-cost-budgets', 'powershell', 'Deploy-CostBudgets.ps1')
    $script:Module = [IO.Path]::Combine($repo, 'scripts', 'common', 'cost-management', 'AzlCostBudget.psm1')
    Import-Module powershell-yaml

    function Get-AzContext { [CmdletBinding()] param() }
    function Invoke-AzRestMethod { [CmdletBinding(SupportsShouldProcess)] param([string]$Method, [string]$Path, [string]$Payload) }

    $global:AzlCbTenant = [guid]::NewGuid().ToString()
    $global:AzlCbHome = [guid]::NewGuid().ToString()
    $global:AzlCbSubA = [guid]::NewGuid().ToString()
    $now = [datetime]::UtcNow
    $script:FirstOfMonth = '{0:yyyy-MM}-01' -f $now
    $script:NextMonth = '{0:yyyy-MM}-01' -f $now.AddMonths(1)

    function New-InfraFile {
        param([object[]]$Budgets = @([ordered]@{ name = 'budget-iic-azl-monthly'; amount = 1000; contact_emails = @('cloud-costs@example.com') }),
            [hashtable]$Azure = @{}, [switch]$NoBudgets)
        $az = [ordered]@{ tenant_id = $global:AzlCbTenant; subscription_id = $global:AzlCbHome; location = 'eastus' }
        foreach ($k in $Azure.Keys) { if ($null -eq $Azure[$k]) { $az.Remove($k) } else { $az[$k] = $Azure[$k] } }
        $lz = [ordered]@{ subscriptions = @([ordered]@{ name = 'sub-iic-management'; id = $global:AzlCbSubA; role = 'management' }) }
        if (-not $NoBudgets) { $lz.budgets = @($Budgets) }
        $doc = [ordered]@{ azure = $az; landing_zone = $lz }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Invoke-Budgets([string]$File, [switch]$DryRun) {
        $global:LASTEXITCODE = $null
        $all = if ($DryRun) { & $script:Script -InfrastructureFile $File -WhatIf 6>&1 3>&1 2>&1 } else { & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1 }
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Budget'] -and $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    # A budget as the GET returns it.
    function New-ExistingBudget {
        param([decimal]$Amount = 1000, [string]$Grain = 'Monthly', [string]$Start = $script:FirstOfMonth, [string]$End = '2036-10-31',
            [object[]]$Notification = @(@('Actual', 80), @('Actual', 100)), [string[]]$Emails = @('cloud-costs@example.com'))
        $n = [ordered]@{}
        foreach ($pair in $Notification) { $n["$($pair[0])_GreaterThan_$($pair[1])_Percent"] = [ordered]@{ enabled = $true; operator = 'GreaterThan'; threshold = $pair[1]; thresholdType = $pair[0]; contactEmails = $Emails } }
        [ordered]@{ name = 'budget-iic-azl-monthly'; eTag = '"1d34d016a593709"'; properties = [ordered]@{ category = 'Cost'; amount = $Amount; timeGrain = $Grain
                timePeriod = [ordered]@{ startDate = "$($Start)T00:00:00Z"; endDate = "$($End)T00:00:00Z" }; notifications = $n } }
    }
    function Get-PutBody { @($global:AzlCbPuts | ForEach-Object { $_.Payload | ConvertFrom-Json -Depth 20 }) }
}

Describe 'Deploy-CostBudgets.ps1' {
    AfterAll { Remove-Variable -Name AzlCbTenant, AzlCbHome, AzlCbSubA, AzlCbExisting, AzlCbPuts, AzlCbGetCode, AzlCbPutCode -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        $global:AzlCbExisting = $null
        $global:AzlCbGetCode = $null
        $global:AzlCbPutCode = 201
        $global:AzlCbPuts = [System.Collections.Generic.List[object]]::new()
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlCbTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlCbHome } } }
        Mock Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                if ($global:AzlCbGetCode) { return [pscustomobject]@{ StatusCode = $global:AzlCbGetCode; Content = '{"error":{"code":"AuthorizationFailed","message":"no access"}}' } }
                if ($global:AzlCbExisting) { return [pscustomobject]@{ StatusCode = 200; Content = ($global:AzlCbExisting | ConvertTo-Json -Depth 20) } }
                return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NotFound","message":"Budget not found."}}' }
            }
            $global:AzlCbPuts.Add([pscustomobject]@{ Path = $Path; Payload = $Payload })
            if ($global:AzlCbPutCode -notin 200, 201) { return [pscustomobject]@{ StatusCode = $global:AzlCbPutCode; Content = '{"error":{"code":"InvalidBudget","message":"The budget is not valid."}}' } }
            [pscustomobject]@{ StatusCode = $global:AzlCbPutCode; Content = $Payload }
        }
    }

    Context 'creating budgets' {
        It 'creates a subscription budget on azure.subscription_id with the default grain, start date, thresholds 80 and 100, and the e-mail addresses' {
            $r = Invoke-Budgets (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Created'
            $global:AzlCbPuts | Should -HaveCount 1
            $global:AzlCbPuts[0].Path | Should -BeExactly "/subscriptions/$($global:AzlCbHome)/providers/Microsoft.Consumption/budgets/budget-iic-azl-monthly?api-version=2024-08-01"
            $body = (Get-PutBody)[0]
            $body.properties.category | Should -Be 'Cost'
            $body.properties.amount | Should -Be 1000
            $body.properties.timeGrain | Should -Be 'Monthly'
            $global:AzlCbPuts[0].Payload | Should -Match ([regex]::Escape("`"startDate`":`"$($script:FirstOfMonth)T00:00:00Z`""))
            $body.properties.timePeriod.PSObject.Properties['endDate'] | Should -BeNullOrEmpty
            $body.PSObject.Properties['eTag'] | Should -BeNullOrEmpty
            @($body.properties.notifications.PSObject.Properties.Name) | Should -Be @('Actual_GreaterThan_80_Percent', 'Actual_GreaterThan_100_Percent')
            $body.properties.notifications.Actual_GreaterThan_80_Percent.operator | Should -Be 'GreaterThan'
            $body.properties.notifications.Actual_GreaterThan_80_Percent.enabled | Should -BeTrue
            @($body.properties.notifications.Actual_GreaterThan_100_Percent.contactEmails) | Should -Be @('cloud-costs@example.com')
        }

        It 'creates a resource group budget in a named subscription with the dates, grain and forecast thresholds of the file' {
            $b = [ordered]@{ name = 'budget-iic-mgmt-q'; scope = 'resource_group'; subscription = 'sub-iic-management'; resource_group = 'rg-iic-mgmt-01'; amount = 250.5
                time_grain = 'Quarterly'; start_date = $script:NextMonth; end_date = '2030-12-31'; thresholds = @(50, 90.5); forecast_thresholds = @(100); contact_emails = @('a@example.com', 'b@example.com') }
            $r = Invoke-Budgets (New-InfraFile -Budgets @($b))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlCbPuts[0].Path | Should -BeLike "/subscriptions/$($global:AzlCbSubA)/resourceGroups/rg-iic-mgmt-01/providers/Microsoft.Consumption/budgets/budget-iic-mgmt-q?api-version=*"
            $body = (Get-PutBody)[0]
            $body.properties.amount | Should -Be 250.5
            $body.properties.timeGrain | Should -Be 'Quarterly'
            $global:AzlCbPuts[0].Payload | Should -Match ([regex]::Escape("`"startDate`":`"$($script:NextMonth)T00:00:00Z`""))
            $global:AzlCbPuts[0].Payload | Should -Match '"endDate":"2030-12-31T00:00:00Z"'
            @($body.properties.notifications.PSObject.Properties.Name) | Should -Be @('Actual_GreaterThan_50_Percent', 'Actual_GreaterThan_90_5_Percent', 'Forecasted_GreaterThan_100_Percent')
            $body.properties.notifications.Forecasted_GreaterThan_100_Percent.thresholdType | Should -Be 'Forecasted'
            @($body.properties.notifications.Forecasted_GreaterThan_100_Percent.contactEmails) | Should -Be @('a@example.com', 'b@example.com')
        }

        It 'never deletes a budget' {
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'DELETE|Remove-Az'
        }
    }

    Context 'a budget exists already (idempotent)' {
        It 'leaves a budget that matches the file alone, whatever the order and case of the e-mail addresses' {
            $global:AzlCbExisting = New-ExistingBudget -Emails @('Cloud-Costs@Example.com')
            $r = Invoke-Budgets (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $global:AzlCbPuts | Should -HaveCount 0
        }

        It 'updates a budget that differs (<Why>), with its eTag, its start date and its end date' -ForEach @(
            @{ Why = 'amount'; Existing = @{ Amount = 500 } }
            @{ Why = 'a threshold'; Existing = @{ Notification = @(, @('Actual', 90)) } }
            @{ Why = 'an e-mail address'; Existing = @{ Emails = @('other@example.com') } }
        ) {
            $e = $Existing
            $global:AzlCbExisting = New-ExistingBudget @e -Start '2026-01-01'
            $r = Invoke-Budgets (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Action | Should -Be 'Updated'
            $r.Rows[0].Detail | Should -Match 'Differs from the file'
            $body = (Get-PutBody)[0]
            $body.eTag | Should -Be '"1d34d016a593709"'
            $global:AzlCbPuts[0].Payload | Should -Match '"startDate":"2026-01-01T00:00:00Z"'
            $global:AzlCbPuts[0].Payload | Should -Match '"endDate":"2036-10-31T00:00:00Z"'
            $body.properties.amount | Should -Be 1000
        }

        It 'does not try to change the time grain, which Azure refuses, and says what to do (exit 1, no write, also under -WhatIf)' {
            $global:AzlCbExisting = New-ExistingBudget -Grain 'Annually'
            $r = Invoke-Budgets (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Detail | Should -Match 'cannot change the time grain'
            (Invoke-Budgets (New-InfraFile) -DryRun).ExitCode | Should -Be 1
            $global:AzlCbPuts | Should -HaveCount 0
        }

        It 'keeps the start date of an existing budget and says so, without an update for that alone' {
            $global:AzlCbExisting = New-ExistingBudget -Start '2026-01-01'
            $r = Invoke-Budgets (New-InfraFile -Budgets @([ordered]@{ name = 'budget-iic-azl-monthly'; amount = 1000; start_date = $script:FirstOfMonth; contact_emails = @('cloud-costs@example.com') }))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'AlreadyExists'
            $r.Text | Should -Match 'start date of an existing budget is kept'
            $global:AzlCbPuts | Should -HaveCount 0
        }

        It 'updates a budget whose notifications also send to an action group or a contact role, so only the e-mail addresses of the file stay' {
            $existing = New-ExistingBudget
            $existing.properties.notifications['Actual_GreaterThan_80_Percent'].contactRoles = @('Owner')
            $global:AzlCbExisting = $existing
            $r = Invoke-Budgets (New-InfraFile)
            $r.Rows[0].Action | Should -Be 'Updated'
            $global:AzlCbPuts[0].Payload | Should -Not -Match 'contactRoles|contactGroups'
        }

        It 'refuses an end date of the file that is not after the start date the existing budget keeps' {
            $global:AzlCbExisting = New-ExistingBudget -Start ('{0:yyyy-MM}-01' -f [datetime]::UtcNow.AddMonths(3))
            $r = Invoke-Budgets (New-InfraFile -Budgets @([ordered]@{ name = 'budget-iic-azl-monthly'; amount = 1000; end_date = ('{0:yyyy-MM}-15' -f [datetime]::UtcNow.AddMonths(1)); contact_emails = @('cloud-costs@example.com') }))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'keeps its start date'
            $global:AzlCbPuts | Should -HaveCount 0
        }

        It 'updates the end date when the file sets another one' {
            $global:AzlCbExisting = New-ExistingBudget
            $r = Invoke-Budgets (New-InfraFile -Budgets @([ordered]@{ name = 'budget-iic-azl-monthly'; amount = 1000; end_date = '2028-12-31'; contact_emails = @('cloud-costs@example.com') }))
            $r.Rows[0].Action | Should -Be 'Updated'
            $global:AzlCbPuts[0].Payload | Should -Match '"endDate":"2028-12-31T00:00:00Z"'
        }
    }

    Context '-WhatIf and nothing to do' {
        It 'reads Azure, plans the creation and the update, and writes nothing' {
            $r = Invoke-Budgets (New-InfraFile) -DryRun
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Action | Should -Be 'WouldCreate'
            Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' }
            $global:AzlCbPuts | Should -HaveCount 0
            $global:AzlCbExisting = New-ExistingBudget -Amount 10
            (Invoke-Budgets (New-InfraFile) -DryRun).Rows[0].Action | Should -Be 'WouldUpdate'
            $global:AzlCbPuts | Should -HaveCount 0
        }

        It 'does nothing and does not touch Azure when the file lists no budget' {
            $r = Invoke-Budgets (New-InfraFile -NoBudgets)
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        }
    }

    Context 'a value in the file is missing or unusable (exit 2, nothing sent to Azure)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a budget with no name'; Budget = [ordered]@{ amount = 10; contact_emails = @('a@example.com') } }
            @{ Why = 'a name Azure refuses'; Budget = [ordered]@{ name = 'budget.one'; amount = 10; contact_emails = @('a@example.com') } }
            @{ Why = 'a name longer than 63 characters'; Budget = [ordered]@{ name = ('b' * 64); amount = 10; contact_emails = @('a@example.com') } }
            @{ Why = 'no amount'; Budget = [ordered]@{ name = 'b1'; contact_emails = @('a@example.com') } }
            @{ Why = 'an amount of 0'; Budget = [ordered]@{ name = 'b1'; amount = 0; contact_emails = @('a@example.com') } }
            @{ Why = 'an amount that is not a number'; Budget = [ordered]@{ name = 'b1'; amount = 'lots'; contact_emails = @('a@example.com') } }
            @{ Why = 'a time grain of the Web Direct billing period'; Budget = [ordered]@{ name = 'b1'; amount = 10; time_grain = 'BillingMonth'; contact_emails = @('a@example.com') } }
            @{ Why = 'a start date that is not the first of a month'; Budget = [ordered]@{ name = 'b1'; amount = 10; start_date = '2026-12-15'; contact_emails = @('a@example.com') } }
            @{ Why = 'a start date before June 2017'; Budget = [ordered]@{ name = 'b1'; amount = 10; start_date = '2017-05-01'; contact_emails = @('a@example.com') } }
            @{ Why = 'a start date more than twelve months ahead'; Budget = [ordered]@{ name = 'b1'; amount = 10; start_date = ('{0:yyyy-MM}-01' -f [datetime]::UtcNow.AddMonths(13)); contact_emails = @('a@example.com') } }
            @{ Why = 'an end date before the start date'; Budget = [ordered]@{ name = 'b1'; amount = 10; start_date = ('{0:yyyy-MM}-01' -f [datetime]::UtcNow.AddMonths(1)); end_date = ('{0:yyyy-MM}-01' -f [datetime]::UtcNow); contact_emails = @('a@example.com') } }
            @{ Why = 'an end date that is not a date'; Budget = [ordered]@{ name = 'b1'; amount = 10; end_date = '31/12/2030'; contact_emails = @('a@example.com') } }
            @{ Why = 'more than five thresholds together'; Budget = [ordered]@{ name = 'b1'; amount = 10; thresholds = @(10, 20, 30, 40); forecast_thresholds = @(50, 60); contact_emails = @('a@example.com') } }
            @{ Why = 'a threshold of 0'; Budget = [ordered]@{ name = 'b1'; amount = 10; thresholds = @(0); contact_emails = @('a@example.com') } }
            @{ Why = 'a threshold above 1000'; Budget = [ordered]@{ name = 'b1'; amount = 10; forecast_thresholds = @(1001); contact_emails = @('a@example.com') } }
            @{ Why = 'a threshold listed twice'; Budget = [ordered]@{ name = 'b1'; amount = 10; thresholds = @(80, 80); contact_emails = @('a@example.com') } }
            @{ Why = 'no threshold at all'; Budget = [ordered]@{ name = 'b1'; amount = 10; thresholds = @(); contact_emails = @('a@example.com') } }
            @{ Why = 'no contact e-mail'; Budget = [ordered]@{ name = 'b1'; amount = 10 } }
            @{ Why = 'a contact that is not an e-mail address'; Budget = [ordered]@{ name = 'b1'; amount = 10; contact_emails = @('not-an-address') } }
            @{ Why = 'an e-mail address listed twice'; Budget = [ordered]@{ name = 'b1'; amount = 10; contact_emails = @('a@example.com', 'A@example.com') } }
            @{ Why = 'scope resource_group with no resource group'; Budget = [ordered]@{ name = 'b1'; scope = 'resource_group'; amount = 10; contact_emails = @('a@example.com') } }
            @{ Why = 'a resource group with scope subscription'; Budget = [ordered]@{ name = 'b1'; resource_group = 'rg-iic-x-01'; amount = 10; contact_emails = @('a@example.com') } }
            @{ Why = 'an unknown scope'; Budget = [ordered]@{ name = 'b1'; scope = 'management_group'; amount = 10; contact_emails = @('a@example.com') } }
            @{ Why = 'a subscription that is not in landing_zone.subscriptions'; Budget = [ordered]@{ name = 'b1'; subscription = 'sub-other'; amount = 10; contact_emails = @('a@example.com') } }
        ) {
            $r = Invoke-Budgets (New-InfraFile -Budgets @($Budget))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Get-AzContext -Times 0 -Exactly
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        }

        It 'refuses the same name twice in one scope, and accepts it in two scopes' {
            $one = [ordered]@{ name = 'b1'; amount = 10; contact_emails = @('a@example.com') }
            $two = [ordered]@{ name = 'B1'; amount = 20; contact_emails = @('a@example.com') }
            (Invoke-Budgets (New-InfraFile -Budgets @($one, $two))).ExitCode | Should -Be 2
            $other = [ordered]@{ name = 'b1'; subscription = 'sub-iic-management'; amount = 20; contact_emails = @('a@example.com') }
            $r = Invoke-Budgets (New-InfraFile -Budgets @($one, $other))
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $global:AzlCbPuts | Should -HaveCount 2
        }

        It 'refuses a missing azure.tenant_id, and a missing azure.subscription_id for a budget that names no subscription' {
            (Invoke-Budgets (New-InfraFile -Azure @{ tenant_id = $null })).ExitCode | Should -Be 2
            (Invoke-Budgets (New-InfraFile -Azure @{ subscription_id = $null })).ExitCode | Should -Be 2
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        }
    }

    Context 'preconditions and failures (exit 1)' {
        It 'stops when nobody is signed in, or the sign-in is to another tenant' {
            Mock Get-AzContext { $null }
            (Invoke-Budgets (New-InfraFile)).ExitCode | Should -Be 1
            Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() } } }
            $r = Invoke-Budgets (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'right tenant'
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        }

        It 'does not take a read error for a missing budget' {
            $global:AzlCbGetCode = 403
            $r = Invoke-Budgets (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'AuthorizationFailed'
            $global:AzlCbPuts | Should -HaveCount 0
        }

        It 'does not take a missing resource group (404 ResourceGroupNotFound) for a missing budget' {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"ResourceGroupNotFound","message":"Resource group rg-iic-mgmt-01 could not be found."}}' } } -ParameterFilter { $Method -eq 'GET' }
            $b = [ordered]@{ name = 'b-rg'; scope = 'resource_group'; resource_group = 'rg-iic-mgmt-01'; amount = 10; contact_emails = @('a@example.com') }
            $r = Invoke-Budgets (New-InfraFile -Budgets @($b))
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Detail | Should -Match 'ResourceGroupNotFound'
            $global:AzlCbPuts | Should -HaveCount 0
        }

        It 'reports a refused write with the Azure error, goes on with the next budget, and exits 1' {
            $global:AzlCbPutCode = 400
            $r = Invoke-Budgets (New-InfraFile -Budgets @([ordered]@{ name = 'b1'; amount = 10; contact_emails = @('a@example.com') }, [ordered]@{ name = 'b2'; amount = 10; contact_emails = @('a@example.com') }))
            $r.ExitCode | Should -Be 1
            @($r.Rows | Where-Object Action -EQ 'Failed') | Should -HaveCount 2
            $r.Rows[0].Detail | Should -Match 'InvalidBudget'
        }
    }
}

Describe 'AzlCostBudget.psm1' {
    BeforeAll { Import-Module $script:Module -Force }

    It 'takes the default start date from the month of -Now' {
        $infra = @{ azure = @{ subscription_id = [guid]::NewGuid().ToString() }; landing_zone = @{ budgets = @(@{ name = 'b1'; amount = 5; contact_emails = @('a@example.com') }) } }
        $plan = @(Get-AzlCostBudgetPlan -Infrastructure $infra -Now ([datetime]::new(2027, 2, 17, 23, 0, 0, [DateTimeKind]::Utc)))
        $plan[0].DefaultStartDate | Should -Be '2027-02-01'
        $plan[0].StartDate | Should -Be ''
        @($plan[0].Thresholds) | Should -Be @(80, 100)
        (New-AzlCostBudgetBody -Plan $plan[0]).properties.timePeriod.startDate | Should -Be '2027-02-01T00:00:00Z'
    }

    It 'reads a start date that ConvertFrom-Json turned into a DateTime' {
        $infra = @{ azure = @{ subscription_id = [guid]::NewGuid().ToString() }; landing_zone = @{ budgets = @(@{ name = 'b1'; amount = 5; contact_emails = @('a@example.com') }) } }
        $plan = @(Get-AzlCostBudgetPlan -Infrastructure $infra)[0]
        $existing = [pscustomobject]@{ eTag = 'x'; properties = [pscustomobject]@{ amount = 5; timeGrain = 'Monthly'; timePeriod = [pscustomobject]@{ startDate = [datetime]::new(2026, 3, 1, 0, 0, 0, [DateTimeKind]::Utc); endDate = '2036-02-28T00:00:00Z' }; notifications = [pscustomobject]@{} } }
        (New-AzlCostBudgetBody -Plan $plan -Existing $existing).properties.timePeriod.startDate | Should -Be '2026-03-01T00:00:00Z'
        (Compare-AzlCostBudget -Plan $plan -Existing $existing).Differences | Should -Be @('the thresholds or the contact e-mail addresses')
    }
}
