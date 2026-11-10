<#
.SYNOPSIS
    Moves existing subscriptions under the management groups infrastructure.yml names for them.

.DESCRIPTION
    Phase 01 (landing zones), Task 02 (subscriptions), "Using Existing Subscriptions". For each entry of landing_zone.subscriptions that has
    an id and a management_group, this script makes the subscription a direct child of that management group, so it inherits that group's
    policy and role assignments. It does not create subscriptions (Deploy-Subscriptions.ps1 does) and it does not create management groups
    (task 01): a target group that does not exist is reported as Failed and nothing is attempted for it.

    Idempotent. A subscription that is already a direct child of its target group is reported as AlreadyInPlace and left alone; a second run
    with the same file moves nothing. Entries with no management_group are skipped, and so are entries whose id is empty or the all-zero
    placeholder of the templates (the id is not known yet).

    WARNING. Moving a subscription changes which Azure Policy assignments and role assignments it inherits. Review what the target group
    inherits before you move a production subscription, and run with -WhatIf first.

    The script reads Azure to find out where each subscription is (read only) and writes only with New-AzManagementGroupSubscription, behind
    -WhatIf. It does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. You need write permission on the subscription
    and on the target management group (for example Management Group Contributor there, and Owner on the subscription).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                  the tenant the sign-in must belong to
        landing_zone.subscriptions[].name                the label used in messages
        landing_zone.subscriptions[].id                  the subscription to move
        landing_zone.subscriptions[].management_group    the management group it belongs under

    Exit codes: 0 every subscription is in place (moved now, already there, planned under -WhatIf, or skipped for a missing id or group);
    1 an Azure call failed, a precondition failed (not signed in, wrong tenant, Az.Resources missing), a target group does not exist or a move
    failed; 2 the file has no subscription this script can act on, or a value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-SubscriptionMove-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which subscriptions would move and which are already in place, and moves nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Invoke-SubscriptionMove-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml

    Moves the subscriptions that are not yet under their management group. Run it again: every subscription is AlreadyInPlace.
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

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'infrastructure') 'AzlInfrastructure.psm1') -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$ZeroGuid = [guid]::Empty.ToString()   # the all-zero placeholder of the templates
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}

function Exit-InputProblem([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 2
}

function Exit-Failed([string]$Message) {
    Write-Error $Message -ErrorAction Continue
    exit 1
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$rawEntries = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$entries = @(@($rawEntries) | Where-Object { $_ -is [System.Collections.IDictionary] })

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($entries.Count -eq 0) { Exit-InputProblem 'landing_zone.subscriptions is empty. List the subscriptions with their id and management_group.' }

$plan = foreach ($entry in $entries) {
    $label = if ($entry.Contains('name') -and $entry['name']) { [string]$entry['name'] } else { '(unnamed)' }
    $id = if ($entry.Contains('id') -and $entry['id']) { ([string]$entry['id']).Trim() } else { '' }
    $group = if ($entry.Contains('management_group') -and $entry['management_group']) { ([string]$entry['management_group']).Trim() } else { '' }
    $skip = ''
    if (-not $group) { $skip = 'no management_group' }
    elseif (-not $id -or $id -eq $ZeroGuid) { $skip = 'the subscription id is not set yet' }
    elseif ($id -notmatch $Guid) { Exit-InputProblem "landing_zone.subscriptions '$label': id '$id' is not a GUID." }
    elseif ($group -notmatch '^[A-Za-z0-9]([A-Za-z0-9._()-]{0,88}[A-Za-z0-9_()-])?$') { Exit-InputProblem "landing_zone.subscriptions '$label': management_group '$group' is not a valid management group id (1 to 90 letters, digits, . _ - ( ); starts with a letter or digit, does not end with a period)." }
    [pscustomobject]@{ Name = $label; Id = $id; Group = $group; Skip = $skip }
}
$plan = @($plan)
if (@($plan | Where-Object { -not $_.Skip }).Count -eq 0) {
    Exit-InputProblem 'No subscription in landing_zone.subscriptions has both an id (not the all-zero placeholder) and a management_group, so there is nothing to move.'
}
$duplicate = @($plan | Where-Object { -not $_.Skip } | Group-Object { $_.Id.ToLowerInvariant() } | Where-Object Count -GT 1)
if ($duplicate.Count) { Exit-InputProblem "The subscription id $($duplicate[0].Name) appears more than once in landing_zone.subscriptions." }

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Get-AzManagementGroup', 'Get-AzManagementGroupSubscription', 'New-AzManagementGroupSubscription') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Resources modules: Install-Module Az.Accounts, Az.Resources -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Moving subscriptions under their management groups ($(@($plan | Where-Object { -not $_.Skip }).Count) to check, $(@($plan | Where-Object Skip).Count) skipped)"

# a target group is looked up once
$groupExists = @{}
foreach ($group in ($plan | Where-Object { -not $_.Skip } | ForEach-Object { $_.Group } | Select-Object -Unique)) {
    try { $groupExists[$group] = [bool](Get-AzManagementGroup -GroupName $group -ErrorAction Stop) }
    catch {
        if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "Management group '$group' could not be read: $($_.Exception.Message)" }
        $groupExists[$group] = $false
    }
}

# ---- one subscription at a time
$results = foreach ($item in $plan) {
    $row = [ordered]@{ Subscription = $item.Name; ManagementGroup = $item.Group; Action = ''; Detail = '' }
    if ($item.Skip) {
        $row.Action = 'Skipped'; $row.Detail = $item.Skip
        Write-Line "[skip]    $($item.Name): $($item.Skip)."
        [pscustomobject]$row
        continue
    }
    try {
        if (-not $groupExists[$item.Group]) {
            $row.Action = 'Failed'; $row.Detail = "The management group '$($item.Group)' does not exist. Create it first (task 01)."
            Write-Warning "$($item.Name): $($row.Detail)"
            [pscustomobject]$row
            continue
        }
        $current = $null
        try { $current = Get-AzManagementGroupSubscription -GroupName $item.Group -SubscriptionId $item.Id -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($current) {
            $row.Action = 'AlreadyInPlace'
            Write-Line "[in place] $($item.Name): already under '$($item.Group)', nothing changed."
        }
        elseif ($PSCmdlet.ShouldProcess("subscription '$($item.Name)'", "Move under management group '$($item.Group)' (it then inherits that group's policy and role assignments)")) {
            $null = New-AzManagementGroupSubscription -GroupName $item.Group -SubscriptionId ([guid]$item.Id) -ErrorAction Stop
            $row.Action = 'Moved'
            Write-Line "[moved]   $($item.Name): now under '$($item.Group)'."
        }
        else {
            $row.Action = 'WouldMove'
            Write-Line "[plan]    $($item.Name): would be moved under '$($item.Group)'."
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        Write-Warning "$($item.Name): $($row.Detail)"
    }
    [pscustomobject]$row
}

$results = @($results)
$moved = @($results | Where-Object Action -EQ 'Moved').Count
$inPlace = @($results | Where-Object Action -EQ 'AlreadyInPlace').Count
$planned = @($results | Where-Object Action -EQ 'WouldMove').Count
$skipped = @($results | Where-Object Action -EQ 'Skipped').Count
$failed = @($results | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $moved moved, $inPlace already in place, $planned planned, $skipped skipped, $failed failed."
if ($moved -eq 0 -and $planned -eq 0 -and $failed -eq 0) { Write-Line 'Nothing to do: every subscription is already under its management group.' }

[pscustomobject]@{ Moved = $moved; AlreadyInPlace = $inPlace; Planned = $planned; Skipped = $skipped; Failed = $failed; Subscriptions = $results }
if ($failed -gt 0) { exit 1 }
exit 0
