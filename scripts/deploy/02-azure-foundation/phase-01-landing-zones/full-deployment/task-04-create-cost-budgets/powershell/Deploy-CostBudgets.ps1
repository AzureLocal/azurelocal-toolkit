<#
.SYNOPSIS
    Creates the Cost Management budgets that landing_zone.budgets of infrastructure.yml lists, and keeps them as the file says.

.DESCRIPTION
    Phase 01 (landing zones), Task 04 (cost budgets). For each entry of landing_zone.budgets the script creates a Cost Management budget on the
    subscription the entry names (azure.subscription_id when it names none), or on one resource group of it (scope: resource_group), with the
    amount, the time grain, the start and end date, the alert thresholds (actual cost and forecast cost) and the e-mail addresses of the file
    (Microsoft Learn: Tutorial: Create and manage budgets; Budgets - Create Or Update). Budgets are free. A budget only sends e-mails: it never
    stops, limits or deletes anything.

    The script calls the Microsoft.Consumption budgets REST API with Invoke-AzRestMethod (Az.Accounts): a GET to read the budget, a PUT to create or
    update it. Each notification uses the operator GreaterThan, the one Learn recommends for budget alerts.

    Idempotent. A budget that matches the file (amount, time grain, end date when the file sets one, thresholds and e-mail addresses) is reported as
    AlreadyExists and left alone. A budget of the same name that differs is updated to the file (Updated), with its eTag, so a change made in between
    is not overwritten. An existing budget keeps its start date (a difference is reported, not changed) and its filter; its notifications become the
    ones of the file. Azure cannot change the time grain of a budget (HTTP 400 "Budget time grain cannot be updated"): a budget whose time grain differs
    is reported as Failed and left alone; delete it or give the entry another name. The script never deletes a budget. -WhatIf reads Azure and changes nothing.

    The script does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first, with an account that may write budgets on each scope
    (Cost Management Contributor, Contributor or Owner; Microsoft Learn: Assign access to Cost Management data). The script names each subscription in the
    request path, so the subscription of the session is not changed.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure and AzlCostBudget.psm1):
        azure.tenant_id, azure.subscription_id
        landing_zone.subscriptions[].name, .id                     the subscription of each entry
        landing_zone.budgets[].name, .scope, .subscription, .resource_group, .amount, .time_grain, .start_date, .end_date,
                               .thresholds, .forecast_thresholds, .contact_emails

    Exit codes: 0 every budget is in place (created, updated, already there, planned under -WhatIf) or the file lists none; 1 an Azure call failed
    or a precondition failed (not signed in, wrong tenant, Az.Accounts missing, a write refused); 2 a value in the file is missing or not usable
    (a name Azure refuses, a name listed twice in one scope, a subscription that is not in landing_zone.subscriptions, no amount, a start date
    that is not the first of a month, more than five thresholds, no contact e-mail).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5.6.30 or later for landing_zone.budgets). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-CostBudgets.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads each budget and shows what would be created or updated, and changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-CostBudgets.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the budgets. Run it again: they are reported as AlreadyExists.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'cost-management', 'AzlCostBudget.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# The error text of a REST answer that is not a success: the message of the error object when there is one, else the status code.
function Get-RestError([object]$Response) {
    $content = if ($Response -and $Response.PSObject.Properties['Content']) { [string]$Response.Content } else { '' }
    try {
        $parsed = $content | ConvertFrom-Json -ErrorAction Stop
        if ($parsed.PSObject.Properties['error'] -and $parsed.error) { return "HTTP $($Response.StatusCode) $($parsed.error.code): $($parsed.error.message)" }
    }
    catch { Write-Verbose 'The error answer is not JSON.' }
    "HTTP $($Response.StatusCode) $content".Trim()
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
try { $plan = @(Get-AzlCostBudgetPlan -Infrastructure $infra) }
catch {
    if ($_.Exception.Data.Contains('AzlExit')) { Exit-InputProblem $_.Exception.Message }
    throw
}
if ($plan.Count -eq 0) {
    Write-Line 'The file lists no landing_zone.budgets: nothing to do.'
    exit 0
}
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Invoke-AzRestMethod') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts module: Install-Module Az.Accounts -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Cost budgets: $($plan.Count) in the file"
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($item in $plan) {
    $subscriptionText = if ($item.Subscription -eq 'azure.subscription_id') { "$($item.SubscriptionId) (azure.subscription_id)" } else { $item.Subscription }
    $where = if ($item.Scope -eq 'resource_group') { "resource group '$($item.ResourceGroup)' of subscription $subscriptionText" } else { "subscription $subscriptionText" }
    $thresholdText = @(@($item.Thresholds | ForEach-Object { "$_%" }) + @($item.ForecastThresholds | ForEach-Object { "$_% forecast" })) -join ', '
    $row = [ordered]@{ Budget = $item.Name; Scope = $where; Action = ''; Amount = $item.Amount; TimeGrain = $item.TimeGrain; Thresholds = $thresholdText; Detail = '' }
    $path = Get-AzlCostBudgetPath -Plan $item
    try {
        $read = Invoke-AzRestMethod -Method GET -Path $path -WhatIf:$false -ErrorAction Stop
        $existing = $null
        if ($read.StatusCode -eq 200) { $existing = $read.Content | ConvertFrom-Json -Depth 20 }
        elseif ($read.StatusCode -ne 404) { throw "The budget could not be read ($(Get-RestError $read))." }
        # A missing subscription or resource group answers 404 too, with its own error code: a failure to report, not a budget to create.
        elseif ([string]$read.Content -match '(?i)ResourceGroupNotFound|SubscriptionNotFound|InvalidSubscriptionId') { throw "The scope of the budget was not found ($(Get-RestError $read))." }

        $verb = 'Create'
        if ($existing) {
            $diff = Compare-AzlCostBudget -Plan $item -Existing $existing
            foreach ($note in $diff.Notes) { Write-Warning "$($item.Name): $note" }
            if ($diff.Blocker) { throw $diff.Blocker }
            if ($diff.Differences.Count -eq 0) {
                $row.Action = 'AlreadyExists'
                $row.Detail = ($diff.Notes -join ' ')
                Write-Line "[exists]  '$($item.Name)' on the $where matches the file, nothing changed."
                $rows.Add([pscustomobject]$row)
                continue
            }
            $verb = 'Update'
            $row.Detail = 'Differs from the file: ' + ($diff.Differences -join '; ') + '.'
        }
        if ($PSCmdlet.ShouldProcess("budget '$($item.Name)' on the $where", "$verb (amount $($item.Amount), $($item.TimeGrain), alerts at $thresholdText)")) {
            $body = New-AzlCostBudgetBody -Plan $item -Existing $existing | ConvertTo-Json -Depth 20 -Compress
            $write = Invoke-AzRestMethod -Method PUT -Path $path -Payload $body -WhatIf:$false -ErrorAction Stop
            if ($write.StatusCode -notin 200, 201) { throw "The budget could not be written ($(Get-RestError $write))." }
            $row.Action = if ($verb -eq 'Create') { 'Created' } else { 'Updated' }
            Write-Line "[$($row.Action.ToLowerInvariant())] '$($item.Name)' on the $where`: $($item.Amount) $($item.TimeGrain), alerts at $thresholdText to $($item.ContactEmails -join ', ')."
        }
        else {
            $row.Action = if ($verb -eq 'Create') { 'WouldCreate' } else { 'WouldUpdate' }
            Write-Line "[plan]    '$($item.Name)' on the $where would be $(if ($verb -eq 'Create') { 'created' } else { 'updated' }): $($item.Amount) $($item.TimeGrain), alerts at $thresholdText."
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        Write-Warning "$($item.Name): $($row.Detail)"
    }
    $rows.Add([pscustomobject]$row)
}

$created = @($rows | Where-Object Action -EQ 'Created').Count
$updated = @($rows | Where-Object Action -EQ 'Updated').Count
$exists = @($rows | Where-Object Action -EQ 'AlreadyExists').Count
$planned = @($rows | Where-Object Action -In 'WouldCreate', 'WouldUpdate').Count
$failed = @($rows | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $created created, $updated updated, $exists already there, $planned planned, $failed failed."

$rows
if ($failed -gt 0) { exit 1 }
exit 0
