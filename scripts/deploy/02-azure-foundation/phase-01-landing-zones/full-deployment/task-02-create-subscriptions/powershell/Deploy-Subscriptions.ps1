<#
.SYNOPSIS
    Creates the Azure subscriptions that landing_zone.subscriptions of infrastructure.yml lists without an id, under the management group the entry names.

.DESCRIPTION
    Phase 01 (landing zones), Task 02 (subscriptions), "Creating Subscriptions". For each entry of landing_zone.subscriptions that has no id (or the
    all-zero placeholder of the templates) the script creates a subscription with a subscription alias (Microsoft Learn, Programmatically create
    Azure subscriptions): the alias and the subscription are both named after the entry, the billing scope and the workload come from the entry,
    and the subscription is put under the entry's management_group in the same call. The billing scope is the one of your agreement: an
    enrollment account (Enterprise Agreement), an invoice section (Microsoft Customer Agreement) or a customer (Microsoft Partner Agreement).

    The script prints the id of each subscription it creates. Put it in landing_zone.subscriptions[].id of the file: the other scripts read it
    from there. An entry that already has an id is an existing subscription: it is skipped (Invoke-SubscriptionMove-Orchestrated.ps1 moves it
    under its management group). A management group has to exist before the subscription is created (task 01).

    Idempotent. If a subscription alias of that name exists the script reports it as AlreadyExists with its subscription id and creates
    nothing. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzSubscriptionAlias, behind -WhatIf. It does not sign in: run Connect-AzAccount
    to the tenant in azure.tenant_id first, with an account that may create subscriptions on the billing scope (Microsoft Learn: Grant access to
    create Azure Enterprise subscriptions, or the role on the invoice section or customer). The tags in the file-level tags map are put on the
    subscriptions it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                  the tenant the sign-in must belong to
        tags                                             tags for the subscriptions created (optional)
        landing_zone.subscriptions[].name                the alias and the display name of the subscription
        landing_zone.subscriptions[].id                  when set (and not all zeros) the entry is an existing subscription and is skipped
        landing_zone.subscriptions[].billing_scope       the billing scope the subscription is created under
        landing_zone.subscriptions[].workload            Production (default) or DevTest
        landing_zone.subscriptions[].management_group    the management group the subscription is created under (optional)

    Exit codes: 0 every entry is in place (created now, already there, skipped because it has an id, or planned under -WhatIf); 1 an Azure call
    failed, a precondition failed (not signed in, wrong tenant, Az.Subscription missing) or a creation failed; 2 the file has no entry this script
    can act on, or a value is not usable (no billing_scope, a workload that is not Production or DevTest, a name listed twice).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-Subscriptions.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which subscriptions would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-Subscriptions.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the subscriptions that have no id. Run it again: they are reported as AlreadyExists.
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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$entries = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($entries.Count -eq 0) { Exit-InputProblem 'landing_zone.subscriptions is empty. List the subscriptions with their name, billing_scope and management_group.' }

$plan = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($entry in $entries) {
    $index++
    $at = "landing_zone.subscriptions[$index]"
    $name = if ($entry.Contains('name') -and $entry['name']) { ([string]$entry['name']).Trim() } else { '' }
    if (-not $name) { Exit-InputProblem "$at has no name." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "The subscription '$name' appears more than once in landing_zone.subscriptions." }
    $seen[$name.ToLowerInvariant()] = $true
    $id = if ($entry.Contains('id') -and $entry['id']) { ([string]$entry['id']).Trim() } else { '' }
    $hasId = $id -and $id -ne [guid]::Empty.ToString()
    $scope = if ($entry.Contains('billing_scope') -and $entry['billing_scope']) { ([string]$entry['billing_scope']).Trim() } else { '' }
    $workload = if ($entry.Contains('workload') -and $entry['workload']) { ([string]$entry['workload']).Trim() } else { 'Production' }
    $group = if ($entry.Contains('management_group') -and $entry['management_group']) { ([string]$entry['management_group']).Trim() } else { '' }
    if (-not $hasId) {
        if (-not $scope) { Exit-InputProblem "$at.billing_scope is missing for '$name'. It is the billing scope the new subscription is created under (an enrollment account, an invoice section or a customer)." }
        if ($scope -notmatch '^/providers/Microsoft\.Billing/|^/billingAccounts/') { Exit-InputProblem "$at.billing_scope '$scope' is not a billing scope. It starts with /providers/Microsoft.Billing/billingAccounts/." }
        if ($workload -notin 'Production', 'DevTest') { Exit-InputProblem "$at.workload '$workload' is not Production or DevTest." }
    }
    $plan.Add([pscustomobject]@{ Name = $name; HasId = $hasId; BillingScope = $scope; Workload = $workload; ManagementGroup = $group })
}
if (@($plan | Where-Object { -not $_.HasId }).Count -eq 0) { Exit-InputProblem 'Every entry of landing_zone.subscriptions has an id, so there is no subscription to create. Invoke-SubscriptionMove-Orchestrated.ps1 moves the existing ones.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Get-AzSubscriptionAlias', 'New-AzSubscriptionAlias') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Subscription modules: Install-Module Az.Accounts, Az.Subscription -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Subscriptions: $(@($plan | Where-Object { -not $_.HasId }).Count) to create, $(@($plan | Where-Object HasId).Count) already have an id"

# ---- one subscription at a time
$results = foreach ($item in $plan) {
    $row = [ordered]@{ Subscription = $item.Name; Action = ''; SubscriptionId = ''; Detail = '' }
    if ($item.HasId) {
        $row.Action = 'Skipped'; $row.Detail = 'The entry has an id: it is an existing subscription.'
        Write-Line "[skip]    $($item.Name) has an id, so it exists; nothing created."
        [pscustomobject]$row
        continue
    }
    try {
        $existing = $null
        try { $existing = Get-AzSubscriptionAlias -AliasName $item.Name -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($existing) {
            $row.Action = 'AlreadyExists'
            $row.SubscriptionId = if ($existing.PSObject.Properties['SubscriptionId']) { [string]$existing.SubscriptionId } else { '' }
            Write-Line "[exists]  The alias '$($item.Name)' is already there ($($row.SubscriptionId)), nothing created."
        }
        elseif ($PSCmdlet.ShouldProcess("subscription '$($item.Name)'", "Create ($($item.Workload))")) {
            $arguments = @{ AliasName = $item.Name; SubscriptionName = $item.Name; BillingScope = $item.BillingScope; Workload = $item.Workload; ErrorAction = 'Stop' }
            if ($item.ManagementGroup) { $arguments.ManagementGroupId = $item.ManagementGroup }
            if ($tags.Count) { $arguments.Tag = $tags }
            $created = New-AzSubscriptionAlias @arguments
            $row.Action = 'Created'
            $row.SubscriptionId = if ($created -and $created.PSObject.Properties['SubscriptionId']) { [string]$created.SubscriptionId } else { '' }
            Write-Line "[created] $($item.Name): subscription $($row.SubscriptionId). Put it in landing_zone.subscriptions[].id."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    $($item.Name) would be created ($($item.Workload))."
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        Write-Warning "$($item.Name): $($row.Detail)"
    }
    [pscustomobject]$row
}

$results = @($results)
$created = @($results | Where-Object Action -EQ 'Created').Count
$exists = @($results | Where-Object Action -EQ 'AlreadyExists').Count
$planned = @($results | Where-Object Action -EQ 'WouldCreate').Count
$skipped = @($results | Where-Object Action -EQ 'Skipped').Count
$failed = @($results | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $created created, $exists already there, $planned planned, $skipped skipped, $failed failed."

$results
if ($failed -gt 0) { exit 1 }
exit 0
