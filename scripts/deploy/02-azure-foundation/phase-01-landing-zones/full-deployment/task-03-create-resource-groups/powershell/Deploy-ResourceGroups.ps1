<#
.SYNOPSIS
    Creates the Azure resource groups that landing_zone.resource_groups of infrastructure.yml lists.

.DESCRIPTION
    Phase 01 (landing zones), Task 03 (resource groups). For each entry of landing_zone.resource_groups the script creates the resource group in
    the subscription the entry names, in the entry's location (azure.location when the entry has none), with the file-level tags
    (Microsoft Learn, Manage Azure resource groups by using Azure PowerShell: New-AzResourceGroup -Name -Location -Tag).

    When the file has no landing_zone.resource_groups the script creates the one resource group of the instance, azure.resource_group, in
    azure.subscription_id (the simplified deployment has no landing zone). When neither is in the file there is nothing to do.

    The subscription of an entry is a name in landing_zone.subscriptions[]; the script looks up its id there. An entry with no subscription uses
    azure.subscription_id. A subscription that does not exist yet has to be created first (task 02).

    Idempotent. A resource group that exists is reported as AlreadyExists and left alone: its location and its tags are never changed (a
    resource group cannot change location), and a difference from the file is reported. The script never deletes or moves anything.
    -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzResourceGroup, behind -WhatIf. It does not sign in: run Connect-AzAccount to the
    tenant in azure.tenant_id first, with an account that may create resource groups on each subscription (Contributor or Owner). The script
    changes the subscription of the session while it works and puts it back.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.subscription_id, azure.resource_group, azure.location, tags
        landing_zone.subscriptions[].name, .id                     the subscription of each entry
        landing_zone.resource_groups[].name, .subscription, .location, .purpose
            (purpose is shown in the progress lines and in the result; it is not written to Azure)

    Exit codes: 0 every resource group is in place (created now, already there, planned under -WhatIf) or the file lists none; 1 an Azure call
    failed or a precondition failed (not signed in, wrong tenant, Az module missing, a creation failed); 2 a value in the file is missing or
    not usable (a name Azure refuses, a name listed twice in one subscription, a subscription that is not in landing_zone.subscriptions, no location).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-ResourceGroups.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which resource groups would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-ResourceGroups.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the resource groups. Run it again: they are reported as AlreadyExists.
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
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$homeSubscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
$instanceGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')).Trim()
$defaultLocation = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')).Trim()
$rawGroups = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.resource_groups'
$groupEntries = @(@($rawGroups) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptionEntries = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($groupEntries.Count -eq 0 -and -not $instanceGroup) {
    Write-Line 'The file lists no landing_zone.resource_groups and no azure.resource_group: nothing to do.'
    exit 0
}
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }

# Resource group names: 1 to 90 characters, letters, digits, underscore, parentheses, hyphen, period; not ending in a period (Microsoft Learn, naming rules).
$namePattern = '^[-\w\.\(\)]{0,89}[-\w\(\)]$'

$wanted = @(if ($groupEntries.Count -gt 0) { $groupEntries } else { [ordered]@{ name = $instanceGroup } })
$plan = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($entry in $wanted) {
    $index++
    $at = if ($groupEntries.Count -gt 0) { "landing_zone.resource_groups[$index]" } else { 'azure.resource_group' }
    $name = Get-Entry $entry 'name'
    if (-not $name) { Exit-InputProblem "$at has no name." }
    if ($name -notmatch $namePattern) { Exit-InputProblem "$at name '$name' is not a valid resource group name: 1 to 90 letters, digits, underscore, hyphen, parentheses or period, and it does not end in a period." }

    $subscriptionName = Get-Entry $entry 'subscription'
    if ($subscriptionName) {
        $subscription = @($subscriptionEntries | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
        if (-not $subscription) { Exit-InputProblem "$at.subscription '$subscriptionName' is not a name in landing_zone.subscriptions." }
        $subscriptionId = Get-Entry $subscription 'id'
        if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "$at.subscription '$subscriptionName' has no usable id in landing_zone.subscriptions. Create the subscription first (task 02) and put its id there." }
    }
    else {
        $subscriptionName = 'azure.subscription_id'
        $subscriptionId = $homeSubscriptionId
        if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "$at names no subscription, and azure.subscription_id is missing, not a GUID or the all-zero placeholder." }
    }
    $location = Get-Entry $entry 'location'
    if (-not $location) { $location = $defaultLocation }
    if (-not $location) { Exit-InputProblem "$at has no location, and azure.location is empty." }

    $key = "$($subscriptionId.ToLowerInvariant())/$($name.ToLowerInvariant())"
    if ($seen.ContainsKey($key)) { Exit-InputProblem "$at name '$name' is listed twice for the subscription '$subscriptionName'." }
    $seen[$key] = $true
    $plan.Add([pscustomobject]@{ Name = $name; Subscription = $subscriptionName; SubscriptionId = $subscriptionId; Location = $location; Purpose = (Get-Entry $entry 'purpose') })
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzResourceGroup', 'New-AzResourceGroup') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context
$currentSubscription = ''

Write-Line "Resource groups: $($plan.Count) in the file"
$rows = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($item in $plan) {
        $row = [ordered]@{ ResourceGroup = $item.Name; Subscription = $item.Subscription; Action = ''; Location = $item.Location; Purpose = $item.Purpose; Detail = '' }
        $what = if ($item.Purpose) { "'$($item.Name)' ($($item.Purpose))" } else { "'$($item.Name)'" }
        try {
            if ($currentSubscription -ne $item.SubscriptionId) {
                $null = Set-AzContext -SubscriptionId $item.SubscriptionId -Tenant $tenantId -ErrorAction Stop
                $currentSubscription = $item.SubscriptionId
            }
            $existing = $null
            try { $existing = Get-AzResourceGroup -Name $item.Name -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

            if ($existing) {
                $row.Action = 'AlreadyExists'
                Write-Line "[exists]  $what is already there, nothing changed."
                $existingLocation = if ($existing.PSObject.Properties['Location'] -and $existing.Location) { ([string]$existing.Location).Replace(' ', '').ToLowerInvariant() } else { '' }
                if ($existingLocation -and $existingLocation -ne $item.Location.Replace(' ', '').ToLowerInvariant()) {
                    $row.Detail = "Differs from the file: the resource group is in $existingLocation, the file says $($item.Location). A resource group cannot change location; left unchanged."
                    Write-Warning "$($item.Name): $($row.Detail)"
                }
            }
            elseif ($PSCmdlet.ShouldProcess("resource group '$($item.Name)' in subscription '$($item.Subscription)'", "Create ($($item.Location))")) {
                $arguments = @{ Name = $item.Name; Location = $item.Location; Force = $true; ErrorAction = 'Stop' }
                if ($tags.Count) { $arguments.Tag = $tags }
                $null = New-AzResourceGroup @arguments
                $row.Action = 'Created'
                Write-Line "[created] $what in $($item.Location)."
            }
            else {
                $row.Action = 'WouldCreate'
                Write-Line "[plan]    $what would be created in $($item.Location)."
            }
        }
        catch {
            $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
            Write-Warning "$($item.Name): $($row.Detail)"
        }
        $rows.Add([pscustomobject]$row)
    }
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id'] -and $currentSubscription) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$created = @($rows | Where-Object Action -EQ 'Created').Count
$exists = @($rows | Where-Object Action -EQ 'AlreadyExists').Count
$planned = @($rows | Where-Object Action -EQ 'WouldCreate').Count
$failed = @($rows | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $created created, $exists already there, $planned planned, $failed failed."

$rows
if ($failed -gt 0) { exit 1 }
exit 0
