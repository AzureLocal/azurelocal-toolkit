<#
.SYNOPSIS
    Renames existing management groups with the Azure CLI: sets the display name infrastructure.yml gives each one.

.DESCRIPTION
    Phase 01 (landing zones), Task 01 (management groups), Azure CLI variant of Set-ManagementGroupDisplayNames.ps1. For each entry of
    landing_zone.management_groups that has a display_name, this script makes the display name of the management group of that name equal to it
    ("az account management-group update --display-name"). It is for a hierarchy that already exists and was named differently (a first draft, an
    older convention): it does not create management groups (Deploy-ManagementGroups.azcli.ps1 does) and it does not move them.

    A management group's name (its id) can never be changed in Azure; only the display name can. So "rename" here always means the display name.
    If the id itself has to change, create a new group with the right id, move the subscriptions and child groups into it, and delete the old one
    (Microsoft Learn, Manage your Azure subscriptions at scale with management groups).

    Idempotent. A group whose display name already matches is reported as AlreadyCorrect and left alone, so a second run with the same file changes
    nothing. Entries with no display_name are skipped. An entry whose group does not exist is reported as Failed, with nothing attempted for it.
    -WhatIf changes nothing.

    The script reads Azure to find each group (read only) and writes only with "az account management-group update", behind -WhatIf. It does not
    sign in: run "az login --tenant <azure.tenant_id>" first. You need write permission on each group (for example Management Group Contributor on it).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                 the tenant the sign-in must belong to
        landing_zone.management_groups[].name           the management group id (the group must already exist)
        landing_zone.management_groups[].display_name   the display name it must have

    Exit codes: 0 every group with a display_name has it (renamed now, already correct or planned under -WhatIf); 1 an Azure call failed, a
    precondition failed (az missing, not signed in, wrong tenant), a group does not exist or a rename failed; 2 the file lists no management group
    with a display name, or a value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-ManagementGroupDisplayNames.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which display names would change, and changes nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Set-ManagementGroupDisplayNames.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Renames the groups whose display name differs. Run it again: every group is AlreadyCorrect.
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
$GroupId = '^[A-Za-z0-9]([A-Za-z0-9._()-]{0,88}[A-Za-z0-9_()-])?$'
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
$rawGroups = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.management_groups'
$entries = @(@($rawGroups) | Where-Object { $_ -is [System.Collections.IDictionary] })

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($entries.Count -eq 0) { Exit-InputProblem 'landing_zone.management_groups is empty. List the management groups with their name and display_name.' }

$plan = foreach ($entry in $entries) {
    $name = if ($entry.Contains('name') -and $entry['name']) { ([string]$entry['name']).Trim() } else { '' }
    if (-not $name) { Exit-InputProblem 'An entry of landing_zone.management_groups has no name.' }
    if ($name -notmatch $GroupId) { Exit-InputProblem "landing_zone.management_groups: '$name' is not a valid management group id (1 to 90 letters, digits, . _ - ( ); starts with a letter or digit, does not end with a period)." }
    $display = if ($entry.Contains('display_name') -and $entry['display_name']) { ([string]$entry['display_name']).Trim() } else { '' }
    [pscustomobject]@{ Name = $name; DisplayName = $display; Skip = $(if ($display) { '' } else { 'no display_name' }) }
}
$plan = @($plan)
if (@($plan | Where-Object { -not $_.Skip }).Count -eq 0) { Exit-InputProblem 'No entry of landing_zone.management_groups has a display_name, so there is nothing to rename.' }
$duplicate = @($plan | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -GT 1)
if ($duplicate.Count) { Exit-InputProblem "The management group '$($duplicate[0].Group[0].Name)' appears more than once in landing_zone.management_groups." }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Set-ManagementGroupDisplayNames.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Renaming management groups ($(@($plan | Where-Object { -not $_.Skip }).Count) to check, $(@($plan | Where-Object Skip).Count) skipped)"

# ---- one group at a time
$results = foreach ($item in $plan) {
    $row = [ordered]@{ ManagementGroup = $item.Name; DisplayName = $item.DisplayName; Action = ''; Detail = '' }
    if ($item.Skip) {
        $row.Action = 'Skipped'; $row.Detail = $item.Skip
        Write-Line "[skip]    $($item.Name): $($item.Skip)."
        [pscustomobject]$row
        continue
    }
    try {
        $currentName = $null
        try { $currentName = Invoke-Az -AzArgument @('account', 'management-group', 'show', '--name', $item.Name, '--query', 'displayName', '--output', 'tsv') }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($null -eq $currentName) {
            $row.Action = 'Failed'; $row.Detail = "The management group '$($item.Name)' does not exist. Create it first (Deploy-ManagementGroups.azcli.ps1)."
            Write-Warning "$($item.Name): $($row.Detail)"
        }
        elseif ($currentName -ceq $item.DisplayName) {
            $row.Action = 'AlreadyCorrect'
            Write-Line "[correct] $($item.Name): the display name is already '$($item.DisplayName)', nothing changed."
        }
        elseif ($PSCmdlet.ShouldProcess("management group '$($item.Name)'", "Change the display name from '$currentName' to '$($item.DisplayName)'")) {
            $null = Invoke-Az -AzArgument @('account', 'management-group', 'update', '--name', $item.Name, '--display-name', $item.DisplayName, '--output', 'none')
            $row.Action = 'Renamed'; $row.Detail = "was '$currentName'"
            Write-Line "[renamed] $($item.Name): '$currentName' is now '$($item.DisplayName)'."
        }
        else {
            $row.Action = 'WouldRename'; $row.Detail = "is '$currentName'"
            Write-Line "[plan]    $($item.Name): '$currentName' would become '$($item.DisplayName)'."
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        Write-Warning "$($item.Name): $($row.Detail)"
    }
    [pscustomobject]$row
}

$results = @($results)
$renamed = @($results | Where-Object Action -EQ 'Renamed').Count
$correct = @($results | Where-Object Action -EQ 'AlreadyCorrect').Count
$planned = @($results | Where-Object Action -EQ 'WouldRename').Count
$skipped = @($results | Where-Object Action -EQ 'Skipped').Count
$failed = @($results | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $renamed renamed, $correct already correct, $planned planned, $skipped skipped, $failed failed."
if ($renamed -eq 0 -and $planned -eq 0 -and $failed -eq 0) { Write-Line 'Nothing to do: every display name is already correct.' }

[pscustomobject]@{ Renamed = $renamed; AlreadyCorrect = $correct; Planned = $planned; Skipped = $skipped; Failed = $failed; ManagementGroups = $results }
if ($failed -gt 0) { exit 1 }
exit 0
