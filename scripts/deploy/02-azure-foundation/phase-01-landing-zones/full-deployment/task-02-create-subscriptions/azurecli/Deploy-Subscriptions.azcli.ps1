<#
.SYNOPSIS
    Creates the Azure subscriptions that landing_zone.subscriptions of infrastructure.yml lists without an id, with the Azure CLI.

.DESCRIPTION
    Phase 01 (landing zones), Task 02 (subscriptions), "Creating Subscriptions", Azure CLI variant of Deploy-Subscriptions.ps1. For each entry of
    landing_zone.subscriptions that has no id (or the all-zero placeholder of the templates) the script creates a subscription with a subscription
    alias ("az account alias create", Microsoft Learn: Programmatically create Azure subscriptions): the alias and the subscription are both named
    after the entry, and the billing scope and the workload come from the entry. The billing scope is the one of your agreement: an enrollment
    account (Enterprise Agreement), an invoice section (Microsoft Customer Agreement) or a customer (Microsoft Partner Agreement).

    "az account alias create" has no management group or tag parameter, so the script does those two steps after the subscription exists: it puts
    the subscription under the entry's management_group ("az account management-group subscription add") and puts the file-level tags on it
    ("az tag update --operation Merge"). If one of these two steps fails the row is Failed and its detail names the subscription id: put the id in
    landing_zone.subscriptions[].id and run Invoke-SubscriptionMove-Orchestrated.azcli.ps1 for the move.

    The script prints the id of each subscription it creates. Put it in landing_zone.subscriptions[].id of the file: the other scripts read it from
    there. An entry that already has an id is an existing subscription: it is skipped (Invoke-SubscriptionMove-Orchestrated.azcli.ps1 moves it under
    its management group). A management group has to exist before the subscription is created (task 01).

    Idempotent. If a subscription alias of that name exists the script reports it as AlreadyExists with its subscription id and creates nothing.
    -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with the three commands above, behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first, with an account that may create subscriptions on the billing scope (Microsoft Learn: Grant access to
    create Azure Enterprise subscriptions, or the role on the invoice section or customer). The "az account alias" commands belong to the Azure CLI
    extension "account": install it once with "az extension add --name account", or the script stops with exit code 1.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                  the tenant the sign-in must belong to
        tags                                             tags for the subscriptions created (optional)
        landing_zone.subscriptions[].name                the alias and the display name of the subscription
        landing_zone.subscriptions[].id                  when set (and not all zeros) the entry is an existing subscription and is skipped
        landing_zone.subscriptions[].billing_scope       the billing scope the subscription is created under
        landing_zone.subscriptions[].workload            Production (default) or DevTest
        landing_zone.subscriptions[].management_group    the management group the subscription is put under (optional)

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every entry is in place (created now, already there, skipped because it has an id, or planned under -WhatIf); 1 an Azure call
    failed, a precondition failed (az or its account extension missing, not signed in, wrong tenant) or a creation failed; 2 the file has no entry
    this script can act on, or a value is not usable (no billing_scope, a workload that is not Production or DevTest, a name listed twice).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-Subscriptions.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which subscriptions would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Deploy-Subscriptions.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = '(?i)NotFound|not found|could not be found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# One az call. Returns the text of standard output; throws, with the error text, when az ends with an error (warnings on standard error are dropped).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgument)
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $AzArgument
    if ($unsafe) { Exit-InputProblem $unsafe }
    $all = @(& az @AzArgument 2>&1)
    $code = $LASTEXITCODE
    $errorText = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $text = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) { throw $(if ($errorText -or $text) { (@($errorText, $text) | Where-Object { $_ }) -join ' ' } else { "az ended with exit code $code." }) }
    $text
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$entries = @(@($rawSubscriptions) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawSubscriptions)) { Exit-InputProblem 'An entry of landing_zone.subscriptions is not a map (names with their settings).' } })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = [ordered]@{}
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
    if ($id -and $id -notmatch $Guid) { Exit-InputProblem "$at.id '$id' is not a GUID. It is the id of an existing subscription, or empty (or all zeros) for a subscription to create." }
    $hasId = $id -and $id -ne [guid]::Empty.ToString()
    $scope = if ($entry.Contains('billing_scope') -and $entry['billing_scope']) { ([string]$entry['billing_scope']).Trim() } else { '' }
    $workload = if ($entry.Contains('workload') -and $entry['workload']) { ([string]$entry['workload']).Trim() } else { 'Production' }
    $group = if ($entry.Contains('management_group') -and $entry['management_group']) { ([string]$entry['management_group']).Trim() } else { '' }
    if (-not $hasId) {
        if (-not $scope) { Exit-InputProblem "$at.billing_scope is missing for '$name'. It is the billing scope the new subscription is created under (an enrollment account, an invoice section or a customer)." }
        if ($scope -notmatch '^/providers/Microsoft\.Billing/|^/billingAccounts/') { Exit-InputProblem "$at.billing_scope '$scope' is not a billing scope. It starts with /providers/Microsoft.Billing/billingAccounts/." }
        if ($workload -notin 'Production', 'DevTest') { Exit-InputProblem "$at.workload '$workload' is not Production or DevTest." }
    }
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "$at.name" = $name; "$at.billing_scope" = $scope; "$at.management_group" = $group })
    if ($problem) { Exit-InputProblem $problem }
    $plan.Add([pscustomobject]@{ Name = $name; HasId = $hasId; BillingScope = $scope; Workload = $workload; ManagementGroup = $group })
}
if (@($plan | Where-Object { -not $_.HasId }).Count -eq 0) { Exit-InputProblem 'Every entry of landing_zone.subscriptions has an id, so there is no subscription to create. Invoke-SubscriptionMove-Orchestrated.azcli.ps1 moves the existing ones.' }

$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $tags })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-Subscriptions.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }
try { $extensions = Invoke-Az -AzArgument @('extension', 'list', '--query', "[?name=='account'].name", '--output', 'tsv') }
catch { Exit-Failed "The Azure CLI extensions could not be listed: $($_.Exception.Message)" }
if (-not $extensions) { Exit-Failed 'The Azure CLI extension "account" (az account alias) is not installed. Run az extension add --name account.' }

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
        $existingId = $null
        try { $existingId = Invoke-Az -AzArgument @('account', 'alias', 'show', '--name', $item.Name, '--query', 'properties.subscriptionId', '--output', 'tsv') }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($null -ne $existingId) {
            $row.SubscriptionId = $existingId
            if ($existingId -notmatch $Guid) { throw "The alias '$($item.Name)' is already there, but it reports no subscription id yet ('$existingId'). Run the script again when its provisioning has finished." }
            $row.Action = 'AlreadyExists'
            Write-Line "[exists]  The alias '$($item.Name)' is already there ($($row.SubscriptionId)), nothing created."
        }
        elseif ($PSCmdlet.ShouldProcess("subscription '$($item.Name)'", "Create ($($item.Workload))")) {
            $newId = Invoke-Az -AzArgument @('account', 'alias', 'create', '--name', $item.Name, '--display-name', $item.Name, '--billing-scope', $item.BillingScope, '--workload', $item.Workload, '--query', 'properties.subscriptionId', '--output', 'tsv')
            if ($newId -notmatch $Guid) { throw "az created the alias '$($item.Name)' but returned no subscription id ('$newId'), so the management group and the tags were not applied. Read the alias with az account alias show --name $($item.Name) and put its subscriptionId in landing_zone.subscriptions[].id." }
            $row.SubscriptionId = $newId
            Write-Line "[created] $($item.Name): subscription $newId. Put it in landing_zone.subscriptions[].id."
            try {
                if ($item.ManagementGroup) {
                    $null = Invoke-Az -AzArgument @('account', 'management-group', 'subscription', 'add', '--name', $item.ManagementGroup, '--subscription', $newId, '--output', 'none')
                    Write-Line "[moved]   $($item.Name): under the management group '$($item.ManagementGroup)'."
                }
                if ($tags.Count) {
                    $null = Invoke-Az -AzArgument (@('tag', 'update', '--resource-id', "/subscriptions/$newId", '--operation', 'Merge', '--tags') + @($tags.Keys | ForEach-Object { "$_=$($tags[$_])" }) + @('--output', 'none'))
                }
                $row.Action = 'Created'
            }
            catch {
                $row.Action = 'Failed'; $row.Detail = "The subscription $newId was created, but a follow-up step failed: $($_.Exception.Message) Put the id in landing_zone.subscriptions[].id and run Invoke-SubscriptionMove-Orchestrated.azcli.ps1 for the management group."
                Write-Warning "$($item.Name): $($row.Detail)"
            }
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
