#Requires -Version 7.0
<#
.SYNOPSIS
    The Cost Management budgets of landing_zone.budgets: what both scripts of phase 01, task 04 (Deploy-CostBudgets.ps1 and Deploy-CostBudgets.azcli.ps1)
    read from infrastructure.yml, the request body they send, and how they compare an existing budget with the file.

.DESCRIPTION
    A budget is a free Cost Management object (Microsoft Learn: Tutorial: Create and manage budgets). It tracks the cost of a subscription or a resource
    group over a time grain and sends an e-mail when a threshold is passed; it never stops or deletes anything. Both scripts write it with the
    Microsoft.Consumption budgets REST API (Microsoft Learn: Budgets - Create Or Update): one PUT of the whole budget, read back with a GET.

    Functions
        Get-AzlCostBudgetPlan        infrastructure (the hashtable of Import-AzlInfrastructure) -> one plan object per landing_zone.budgets entry, every value
                                     checked. A value that is missing or not usable throws an exception with Data['AzlExit'] = 2.
        Get-AzlCostBudgetPath        plan object -> the ARM path of the budget, with the api-version.
        New-AzlCostBudgetBody        plan object (+ the existing budget) -> the request body, as a map ready for ConvertTo-Json.
        Compare-AzlCostBudget        plan object + existing budget -> what differs from the file (empty: the budget matches), and the notes that are
                                     not a reason to change it.

    Fixed by Microsoft, not chosen by a deployment (Microsoft Learn: Budgets - Create Or Update):
        category Cost (the only category of the API), operator GreaterThan (the operator Learn recommends for budget alerts), at most five notifications,
        a threshold greater than 0 and at most 1000 percent, a start date on the first of a month, on or after 2017-06-01 and at most twelve months ahead.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1')))

# The api-version of the Microsoft.Consumption budgets REST API (Microsoft Learn: Budgets - Create Or Update; 2024-08-01 is a released, not preview, version).
$script:ApiVersion = '2024-08-01'
$script:Operator = 'GreaterThan'
$script:MaxNotifications = 5
$script:EarliestStart = [datetime]::new(2017, 6, 1, 0, 0, 0, [DateTimeKind]::Utc)
$script:Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$script:NamePattern = '^[A-Za-z0-9_-]{1,63}$'
# Resource group names: 1 to 90 characters, letters, digits, underscore, parentheses, hyphen, period; not ending in a period (Microsoft Learn, naming rules).
$script:GroupPattern = '^[-\w\.\(\)]{0,89}[-\w\(\)]$'
$script:EmailPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

function New-InputProblem([string]$Message) {
    $e = [System.ArgumentException]::new($Message)
    $e.Data['AzlExit'] = 2
    $e
}

function Get-Entry([object]$Entry, [string]$Key) {
    # The comma keeps a list of one item (or none) a list: PowerShell would unroll it.
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return , $Entry[$Key] }
    $null
}

function Get-EntryText([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# A number of the file: an integer or a decimal (YAML gives int, long, double or decimal); text that holds a number in the invariant culture is taken too.
function ConvertTo-Number([object]$Value, [string]$At) {
    if ($Value -is [bool] -or $null -eq $Value) { throw (New-InputProblem "$At is not a number.") }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) { return [decimal]$Value }
    $parsed = [decimal]0
    if ([decimal]::TryParse(([string]$Value).Trim(), [Globalization.NumberStyles]::Number, $script:Invariant, [ref]$parsed)) { return $parsed }
    throw (New-InputProblem "$At '$Value' is not a number.")
}

function ConvertTo-Date([string]$Text, [string]$At) {
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Text, 'yyyy-MM-dd', $script:Invariant, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        throw (New-InputProblem "$At '$Text' is not a date written YYYY-MM-DD.")
    }
    [datetime]::SpecifyKind($parsed.Date, [DateTimeKind]::Utc)
}

# The date part (YYYY-MM-DD) of a date that Azure returned: text, or a DateTime that ConvertFrom-Json made from it.
function ConvertTo-DateText([object]$Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) {
        $d = if ($Value.Kind -eq [DateTimeKind]::Local) { $Value.ToUniversalTime() } else { $Value }
        return $d.ToString('yyyy-MM-dd', $script:Invariant)
    }
    $text = ([string]$Value).Trim()
    if ($text.Length -ge 10) { return $text.Substring(0, 10) }
    $text
}

function Format-Number([decimal]$Value) { $Value.ToString('0.############', $script:Invariant) }

function Get-PropertyValue([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

# The percentages of one list of the entry (thresholds or forecast_thresholds), checked: each greater than 0 and at most 1000, none twice.
function Get-ThresholdList([object]$Raw, [string]$At, [string]$Key, [decimal[]]$Default) {
    if ($null -eq $Raw) { return , [decimal[]]$Default }
    $raw = $Raw
    if ($raw -is [string] -or $raw -isnot [System.Collections.IEnumerable]) { throw (New-InputProblem "$At.$Key is not a list of percentages.") }
    $list = [System.Collections.Generic.List[decimal]]::new()
    $i = -1
    foreach ($item in $raw) {
        $i++
        $value = ConvertTo-Number $item "$At.$Key[$i]"
        if ($value -le 0 -or $value -gt 1000) { throw (New-InputProblem "$At.$Key[$i] is $(Format-Number $value): a threshold is a percentage of the amount, greater than 0 and at most 1000.") }
        if ($list.Contains($value)) { throw (New-InputProblem "$At.$Key lists $(Format-Number $value) twice.") }
        $list.Add($value)
    }
    , $list.ToArray()
}

function Get-AzlCostBudgetPlan {
    <#
    .SYNOPSIS
        One plan object per entry of landing_zone.budgets, with every value checked. Throws (Data['AzlExit'] = 2) on a value that is missing or not usable.
    .PARAMETER Infrastructure
        The file as Import-AzlInfrastructure returns it.
    .PARAMETER Now
        The time the run starts (UTC). The default start date is the first day of its month. Tests pass a fixed time.
    .OUTPUTS
        Name, Scope (subscription or resource_group), Subscription (the name in the file, or azure.subscription_id), SubscriptionId, ResourceGroup,
        ScopeId (/subscriptions/<id>[/resourceGroups/<name>]), Amount, TimeGrain, StartDate ('' when the file has none), DefaultStartDate, EndDate,
        Thresholds, ForecastThresholds, ContactEmails, and Where (the entry, for messages).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [datetime]$Now = [datetime]::UtcNow
    )
    $now = if ($Now.Kind -eq [DateTimeKind]::Local) { $Now.ToUniversalTime() } else { $Now }
    $firstOfMonth = [datetime]::new($now.Year, $now.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $latestStart = $firstOfMonth.AddMonths(12)

    $homeSubscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'azure.subscription_id')).Trim()
    $rawBudgets = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'landing_zone.budgets'
    if ($null -ne $rawBudgets -and ($rawBudgets -is [string] -or $rawBudgets -isnot [System.Collections.IEnumerable])) { throw (New-InputProblem 'landing_zone.budgets is not a list of budgets.') }
    if ($null -ne $rawBudgets -and @(@($rawBudgets) | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count) { throw (New-InputProblem 'An entry of landing_zone.budgets is not a map (names with their settings).') }
    $budgetEntries = @(@($rawBudgets) | Where-Object { $_ -is [System.Collections.IDictionary] })
    $rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'landing_zone.subscriptions'
    if ($null -ne $rawSubscriptions -and @(@($rawSubscriptions) | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count) { throw (New-InputProblem 'An entry of landing_zone.subscriptions is not a map (names with their settings).') }
    $subscriptionEntries = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })

    $seen = @{}
    $index = -1
    foreach ($entry in $budgetEntries) {
        $index++
        $at = "landing_zone.budgets[$index]"
        $name = Get-EntryText $entry 'name'
        if (-not $name) { throw (New-InputProblem "$at has no name.") }
        if ($name -notmatch $script:NamePattern) { throw (New-InputProblem "$at name '$name' is not a valid budget name: 1 to 63 letters, digits, hyphens and underscores.") }
        $at = "landing_zone.budgets[$index] ('$name')"

        $scope = Get-EntryText $entry 'scope'
        if (-not $scope) { $scope = 'subscription' }
        if ($scope -cnotin 'subscription', 'resource_group') { throw (New-InputProblem "$at.scope '$scope' is not subscription or resource_group.") }
        $group = Get-EntryText $entry 'resource_group'
        if ($scope -eq 'resource_group' -and -not $group) { throw (New-InputProblem "$at.scope is resource_group, and resource_group is empty. Name the resource group the budget tracks.") }
        if ($scope -eq 'subscription' -and $group) { throw (New-InputProblem "$at names resource_group '$group' with scope subscription. Set scope: resource_group to track only that resource group, or remove resource_group.") }
        if ($group -and $group -notmatch $script:GroupPattern) { throw (New-InputProblem "$at.resource_group '$group' is not a valid resource group name.") }

        $subscriptionName = Get-EntryText $entry 'subscription'
        if ($subscriptionName) {
            $subscription = @($subscriptionEntries | Where-Object { (Get-EntryText $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
            if (-not $subscription) { throw (New-InputProblem "$at.subscription '$subscriptionName' is not a name in landing_zone.subscriptions.") }
            $subscriptionId = Get-EntryText $subscription 'id'
            if ($subscriptionId -notmatch $script:Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { throw (New-InputProblem "$at.subscription '$subscriptionName' has no usable id in landing_zone.subscriptions. Create the subscription first (task 02) and put its id there.") }
        }
        else {
            $subscriptionName = 'azure.subscription_id'
            $subscriptionId = $homeSubscriptionId
            if ($subscriptionId -notmatch $script:Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { throw (New-InputProblem "$at names no subscription, and azure.subscription_id is missing, not a GUID or the all-zero placeholder.") }
        }

        $rawAmount = Get-Entry $entry 'amount'
        if ($null -eq $rawAmount -or ([string]$rawAmount).Trim() -eq '') { throw (New-InputProblem "$at has no amount.") }
        $amount = ConvertTo-Number $rawAmount "$at.amount"
        if ($amount -le 0) { throw (New-InputProblem "$at.amount is $(Format-Number $amount): the amount of a budget is greater than 0.") }

        $grain = Get-EntryText $entry 'time_grain'
        if (-not $grain) { $grain = 'Monthly' }
        $grainMatch = @('Monthly', 'Quarterly', 'Annually') | Where-Object { $_ -eq $grain } | Select-Object -First 1
        if (-not $grainMatch) { throw (New-InputProblem "$at.time_grain '$grain' is not Monthly, Quarterly or Annually.") }
        $grain = $grainMatch

        $startText = Get-EntryText $entry 'start_date'
        $start = $null
        if ($startText) {
            $start = ConvertTo-Date $startText "$at.start_date"
            if ($start.Day -ne 1) { throw (New-InputProblem "$at.start_date $startText is not the first day of a month. A budget starts on the first of a month.") }
            if ($start -lt $script:EarliestStart) { throw (New-InputProblem "$at.start_date $startText is before 2017-06-01, the earliest start date Azure accepts.") }
            if ($start -gt $latestStart) { throw (New-InputProblem "$at.start_date $startText is more than twelve months ahead (latest: $($latestStart.ToString('yyyy-MM-dd', $script:Invariant))).") }
        }
        $endText = Get-EntryText $entry 'end_date'
        if ($endText) {
            $end = ConvertTo-Date $endText "$at.end_date"
            $from = if ($start) { $start } else { $firstOfMonth }
            if ($end -le $from) { throw (New-InputProblem "$at.end_date $endText is not after the start date $($from.ToString('yyyy-MM-dd', $script:Invariant)).") }
        }

        $thresholds = Get-ThresholdList (Get-Entry $entry 'thresholds') $at 'thresholds' ([decimal[]](80, 100))
        $forecast = Get-ThresholdList (Get-Entry $entry 'forecast_thresholds') $at 'forecast_thresholds' ([decimal[]]@())
        $count = $thresholds.Count + $forecast.Count
        if ($count -eq 0) { throw (New-InputProblem "$at has no threshold: list at least one percentage in thresholds or forecast_thresholds, or leave thresholds out for 80 and 100.") }
        if ($count -gt $script:MaxNotifications) { throw (New-InputProblem "$at has $count thresholds (thresholds and forecast_thresholds together); a budget has at most $($script:MaxNotifications) notifications.") }

        $rawEmails = Get-Entry $entry 'contact_emails'
        if ($rawEmails -is [string]) { $rawEmails = @($rawEmails) }
        $emails = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($rawEmails | Where-Object { $null -ne $_ })) {
            $email = ([string]$item).Trim()
            if ($email -notmatch $script:EmailPattern) { throw (New-InputProblem "$at.contact_emails: '$email' is not an e-mail address.") }
            if (@($emails | Where-Object { $_ -ieq $email }).Count) { throw (New-InputProblem "$at.contact_emails lists '$email' twice.") }
            $emails.Add($email)
        }
        if ($emails.Count -eq 0) { throw (New-InputProblem "$at has no contact_emails. List at least one address that gets the alerts.") }

        $scopeId = "/subscriptions/$subscriptionId"
        if ($scope -eq 'resource_group') { $scopeId += "/resourceGroups/$group" }
        $key = "$($scopeId.ToLowerInvariant())/$($name.ToLowerInvariant())"
        if ($seen.ContainsKey($key)) { throw (New-InputProblem "$at name '$name' is listed twice for the same $($scope.Replace('_', ' ')).") }
        $seen[$key] = $true

        [pscustomobject]@{
            Name               = $name
            Scope              = $scope
            Subscription       = $subscriptionName
            SubscriptionId     = $subscriptionId
            ResourceGroup      = $group
            ScopeId            = $scopeId
            Amount             = $amount
            TimeGrain          = $grain
            StartDate          = $(if ($start) { $start.ToString('yyyy-MM-dd', $script:Invariant) } else { '' })
            DefaultStartDate   = $firstOfMonth.ToString('yyyy-MM-dd', $script:Invariant)
            EndDate            = $endText
            Thresholds         = $thresholds
            ForecastThresholds = $forecast
            ContactEmails      = $emails.ToArray()
            Where              = $at
        }
    }
}

function Get-AzlCostBudgetPath {
    <#
    .SYNOPSIS
        The ARM path of the budget of a plan object, with the api-version: /subscriptions/<id>[/resourceGroups/<name>]/providers/Microsoft.Consumption/budgets/<name>?api-version=...
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Plan)
    "$($Plan.ScopeId)/providers/Microsoft.Consumption/budgets/$($Plan.Name)?api-version=$($script:ApiVersion)"
}

# The notifications the file asks for: one per threshold, named <Actual|Forecasted>_GreaterThan_<percent>_Percent as the Learn sample names them.
function Get-DesiredNotification([pscustomobject]$Plan) {
    $out = [ordered]@{}
    foreach ($pair in @(@($Plan.Thresholds | ForEach-Object { , @('Actual', $_) }) + @($Plan.ForecastThresholds | ForEach-Object { , @('Forecasted', $_) }))) {
        $type = $pair[0]; $value = [decimal]$pair[1]
        $out["$($type)_$($script:Operator)_$((Format-Number $value).Replace('.', '_'))_Percent"] = [ordered]@{
            enabled       = $true
            operator      = $script:Operator
            threshold     = $value
            thresholdType = $type
            contactEmails = @($Plan.ContactEmails)
        }
    }
    $out
}

# One notification as text, so two lists compare regardless of order and of the case of the e-mail addresses. The recipients the file does not set (action
# groups, contact roles) count too: the file has none, so a notification that has some differs, and the update leaves the e-mail addresses of the file only.
function Get-RecipientText([object]$Notification, [string]$Name) {
    (@(@(Get-PropertyValue $Notification $Name) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Sort-Object -Unique) -join ',')
}
function Get-NotificationSignature([object]$Notification) {
    $type = [string](Get-PropertyValue $Notification 'thresholdType'); if (-not $type) { $type = 'Actual' }
    $enabled = Get-PropertyValue $Notification 'enabled'
    '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $type.ToLowerInvariant(), ([string](Get-PropertyValue $Notification 'operator')).ToLowerInvariant(), (Format-Number ([decimal](Get-PropertyValue $Notification 'threshold'))), ([bool]$enabled),
    (Get-RecipientText $Notification 'contactEmails'), (Get-RecipientText $Notification 'contactGroups'), (Get-RecipientText $Notification 'contactRoles')
}

function Compare-AzlCostBudget {
    <#
    .SYNOPSIS
        What differs between the file and an existing budget (the GET answer). Returns Differences (reasons to update it; empty: it matches the file), Notes
        (differences that are kept on purpose: the start date of an existing budget is never changed) and Blocker (a difference no update can fix: the
        time grain, which Azure does not let a budget change; the scripts report it as a failure and do not write).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Plan, [Parameter(Mandatory)][object]$Existing)
    $differences = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $properties = Get-PropertyValue $Existing 'properties'

    $amount = Get-PropertyValue $properties 'amount'
    $currentAmount = if ($null -ne $amount) { [decimal]$amount } else { $null }
    if ($currentAmount -ne $Plan.Amount) { $differences.Add("amount $(if ($null -ne $currentAmount) { Format-Number $currentAmount } else { 'none' }) -> $(Format-Number $Plan.Amount)") }
    $grain = [string](Get-PropertyValue $properties 'timeGrain')
    # Azure refuses to change the time grain of a budget (HTTP 400 "Budget time grain cannot be updated", seen on a live run): no PUT can fix it.
    $blocker = ''
    if ($grain -ne $Plan.TimeGrain) { $blocker = "The budget in Azure has the time grain $grain, the file says $($Plan.TimeGrain), and Azure cannot change the time grain of a budget. Delete the budget (portal: Cost Management, Budgets) or give the entry another name, then run the task again." }

    $period = Get-PropertyValue $properties 'timePeriod'
    $currentStart = ConvertTo-DateText (Get-PropertyValue $period 'startDate')
    $currentEnd = ConvertTo-DateText (Get-PropertyValue $period 'endDate')
    if ($Plan.EndDate -and $currentEnd -ne $Plan.EndDate) { $differences.Add("end date $currentEnd -> $($Plan.EndDate)") }
    if ($Plan.StartDate -and $currentStart -and $currentStart -ne $Plan.StartDate) { $notes.Add("The budget starts on $currentStart, the file says $($Plan.StartDate). The start date of an existing budget is kept.") }

    $current = @()
    $currentNotifications = Get-PropertyValue $properties 'notifications'
    if ($currentNotifications -is [System.Collections.IDictionary]) { $current = @($currentNotifications.Values | ForEach-Object { Get-NotificationSignature $_ }) }
    elseif ($null -ne $currentNotifications) { $current = @($currentNotifications.PSObject.Properties | ForEach-Object { Get-NotificationSignature $_.Value }) }
    $wanted = @((Get-DesiredNotification $Plan).Values | ForEach-Object { Get-NotificationSignature $_ })
    $missing = @($wanted | Where-Object { $_ -notin $current })
    $extra = @($current | Where-Object { $_ -notin $wanted })
    if ($missing.Count -or $extra.Count) { $differences.Add('the thresholds or the contact e-mail addresses') }

    [pscustomobject]@{ Differences = $differences.ToArray(); Notes = $notes.ToArray(); Blocker = $blocker; StartDate = $currentStart; EndDate = $currentEnd }
}

function New-AzlCostBudgetBody {
    <#
    .SYNOPSIS
        The request body of the PUT (Microsoft Learn: Budgets - Create Or Update), as an ordered map for ConvertTo-Json -Depth 10.
    .DESCRIPTION
        New budget: the start date of the file, else the first day of the current month; the end date of the file, else none (Azure sets ten years).
        Existing budget (-Existing): its eTag (so a change made in between is not overwritten), its start date, its end date unless the file sets one, and its
        filter (a narrower scope set elsewhere is kept). The notifications are always the ones of the file.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][pscustomobject]$Plan, [object]$Existing)
    $properties = Get-PropertyValue $Existing 'properties'
    $period = Get-PropertyValue $properties 'timePeriod'
    $start = if ($null -ne $Existing) { ConvertTo-DateText (Get-PropertyValue $period 'startDate') } else { '' }
    if (-not $start) { $start = if ($Plan.StartDate) { $Plan.StartDate } else { $Plan.DefaultStartDate } }
    $end = if ($Plan.EndDate) { $Plan.EndDate } elseif ($null -ne $Existing) { ConvertTo-DateText (Get-PropertyValue $period 'endDate') } else { '' }

    # The end date of the file was checked against the start date of the file; an existing budget keeps its own start, so check the pair that is sent.
    if ($end -and [string]::CompareOrdinal($end, $start) -le 0) { throw (New-InputProblem "$($Plan.Where).end_date $end is not after the start date $start of the budget in Azure (an existing budget keeps its start date).") }
    $timePeriod = [ordered]@{ startDate = "$($start)T00:00:00Z" }
    if ($end) { $timePeriod.endDate = "$($end)T00:00:00Z" }
    $body = [ordered]@{}
    $eTag = Get-PropertyValue $Existing 'eTag'
    if ($eTag) { $body.eTag = [string]$eTag }
    $body.properties = [ordered]@{
        category      = 'Cost'
        amount        = $Plan.Amount
        timeGrain     = $Plan.TimeGrain
        timePeriod    = $timePeriod
        notifications = Get-DesiredNotification $Plan
    }
    $filter = Get-PropertyValue $properties 'filter'
    if ($null -ne $filter -and @($filter.PSObject.Properties).Count) { $body.properties.filter = $filter }
    $body
}

Export-ModuleMember -Function Get-AzlCostBudgetPlan, Get-AzlCostBudgetPath, New-AzlCostBudgetBody, Compare-AzlCostBudget
