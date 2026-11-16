<#
.SYNOPSIS
    Creates the Azure management group hierarchy that landing_zone.management_groups of infrastructure.yml lists, with the Azure CLI.

.DESCRIPTION
    Phase 01 (landing zones), Task 01 (management groups), Azure CLI variant of Deploy-ManagementGroups.ps1. It does the same with az commands,
    for a host that has the Azure CLI and not the Az PowerShell modules. For every entry of landing_zone.management_groups the script creates the
    management group with its name (the id), its display name and its parent ("az account management-group create"). An entry with no parent goes
    directly under the tenant root group. A parent has to be an entry of the same list; the script creates parents before children, whatever the
    order of the file.

    A file with one entry makes one group under the tenant root, which is all the simplified deployment needs. The script does not create
    subscriptions (task 02) and does not rename a group (Set-ManagementGroupDisplayNames.azcli.ps1 does).

    Idempotent, and additive. A management group that exists is reported as AlreadyExists and left alone: a different display name or a different
    parent is reported in the detail and not changed (a parent change moves everything below the group; do it on purpose in the portal or with
    "az account management-group update --parent"). -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with "az account management-group create", behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first. You need Management Group Contributor on the tenant root group (or on the parent group); when the
    tenant setting "require authorization for management group creation" is on, you also need the write permission on the root (Microsoft Learn,
    Manage your Azure subscriptions at scale with management groups).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                 the tenant the sign-in must belong to
        landing_zone.management_groups[].name           the management group id
        landing_zone.management_groups[].display_name   the display name (default: the name)
        landing_zone.management_groups[].parent         the name of the parent entry; empty for the tenant root

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every group exists (created now, already there, or planned under -WhatIf); 1 an Azure call failed, a precondition failed (az
    missing, not signed in, wrong tenant) or a creation failed; 2 the file lists no group, or a value is not usable (a name that Azure refuses, a
    name listed twice, a parent that is not in the list, a loop of parents).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-ManagementGroups.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which management groups would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Deploy-ManagementGroups.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the hierarchy. Run it again: every group is reported as AlreadyExists.
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
$GroupId = '^[A-Za-z0-9]([A-Za-z0-9._()-]{0,88}[A-Za-z0-9_()-])?$'
$NotFound = '(?i)NotFound|not found|could not be found|does not exist|\b404\b'
$Prefix = '/providers/Microsoft.Management/managementGroups/'

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
$rawGroups = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.management_groups'
$entries = @(@($rawGroups) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawGroups)) { Exit-InputProblem 'An entry of landing_zone.management_groups is not a map (names with their settings).' } })

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($entries.Count -eq 0) { Exit-InputProblem 'landing_zone.management_groups is empty. List the management groups with their name, display_name and parent.' }

$plan = [System.Collections.Generic.List[object]]::new()
$seen = @{}
foreach ($entry in $entries) {
    $name = if ($entry.Contains('name') -and $entry['name']) { ([string]$entry['name']).Trim() } else { '' }
    if (-not $name) { Exit-InputProblem 'An entry of landing_zone.management_groups has no name.' }
    if ($name -notmatch $GroupId) { Exit-InputProblem "landing_zone.management_groups: '$name' is not a valid management group id (1 to 90 letters, digits, . _ - ( ); starts with a letter or digit, does not end with a period)." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "The management group '$name' appears more than once in landing_zone.management_groups." }
    $seen[$name.ToLowerInvariant()] = $true
    $display = if ($entry.Contains('display_name') -and $entry['display_name']) { ([string]$entry['display_name']).Trim() } else { $name }
    $parent = if ($entry.Contains('parent') -and $entry['parent']) { ([string]$entry['parent']).Trim() } else { '' }
    $plan.Add([pscustomobject]@{ Name = $name; DisplayName = $display; Parent = $parent })
}
foreach ($item in $plan) {
    if ($item.Parent -and -not $seen.ContainsKey($item.Parent.ToLowerInvariant())) { Exit-InputProblem "The parent '$($item.Parent)' of '$($item.Name)' is not an entry of landing_zone.management_groups." }
    if ($item.Parent -and $item.Parent -ieq $item.Name) { Exit-InputProblem "The management group '$($item.Name)' is its own parent." }
}

# Parents before children. A group is ready when its parent is already in the order; no progress means a loop.
$ordered = [System.Collections.Generic.List[object]]::new()
$placed = @{}
$left = [System.Collections.Generic.List[object]]::new($plan)
while ($left.Count -gt 0) {
    $ready = @($left | Where-Object { -not $_.Parent -or $placed.ContainsKey($_.Parent.ToLowerInvariant()) })
    if ($ready.Count -eq 0) { Exit-InputProblem "The parents in landing_zone.management_groups form a loop: $(($left | ForEach-Object Name) -join ', ')." }
    foreach ($item in $ready) { $ordered.Add($item); $placed[$item.Name.ToLowerInvariant()] = $true; [void]$left.Remove($item) }
}

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). The names are checked by their own pattern above.
foreach ($item in $plan) {
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "landing_zone.management_groups '$($item.Name)' display_name" = $item.DisplayName })
    if ($problem) { Exit-InputProblem $problem }
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-ManagementGroups.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Management groups: $($ordered.Count) in the file"

# ---- one group at a time, parents first
$failedGroup = @{}
$results = foreach ($item in $ordered) {
    $row = [ordered]@{ ManagementGroup = $item.Name; Parent = $item.Parent; Action = ''; Detail = '' }
    $parentId = if ($item.Parent) { $Prefix + $item.Parent } else { $Prefix + $tenantId }
    try {
        if ($item.Parent -and $failedGroup.ContainsKey($item.Parent.ToLowerInvariant())) { throw "The parent '$($item.Parent)' was not created, so '$($item.Name)' is not attempted." }
        $current = $null
        try { $current = Invoke-Az -AzArgument @('account', 'management-group', 'show', '--name', $item.Name, '--query', '{displayName:displayName,parent:details.parent.id}', '--output', 'json') | ConvertFrom-Json }
        catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

        if ($current) {
            $row.Action = 'AlreadyExists'
            Write-Line "[exists]  $($item.Name) is already there, nothing changed."
            $differences = [System.Collections.Generic.List[string]]::new()
            if ([string]$current.displayName -cne $item.DisplayName) { $differences.Add("display name is '$($current.displayName)' (the file says '$($item.DisplayName)'; Set-ManagementGroupDisplayNames.azcli.ps1 renames it)") }
            $currentParent = if ($current.PSObject.Properties['parent'] -and $current.parent) { [string]$current.parent } else { '' }
            if ($currentParent -and $currentParent -ine $parentId) { $differences.Add("parent is $currentParent (the file says $parentId); left where it is") }
            if ($differences.Count) {
                $row.Detail = 'Differs from the file: ' + ($differences -join '; ') + '.'
                Write-Warning "$($item.Name): $($row.Detail)"
            }
        }
        elseif ($PSCmdlet.ShouldProcess("management group '$($item.Name)'", "Create under $parentId")) {
            $create = @('account', 'management-group', 'create', '--name', $item.Name, '--display-name', $item.DisplayName)
            if ($item.Parent) { $create += @('--parent', $item.Parent) }
            $null = Invoke-Az -AzArgument ($create + @('--output', 'none'))
            $row.Action = 'Created'
            Write-Line "[created] $($item.Name) ('$($item.DisplayName)') under $parentId."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    $($item.Name) ('$($item.DisplayName)') would be created under $parentId."
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        $failedGroup[$item.Name.ToLowerInvariant()] = $true
        Write-Warning "$($item.Name): $($row.Detail)"
    }
    [pscustomobject]$row
}

$results = @($results)
$created = @($results | Where-Object Action -EQ 'Created').Count
$exists = @($results | Where-Object Action -EQ 'AlreadyExists').Count
$planned = @($results | Where-Object Action -EQ 'WouldCreate').Count
$failed = @($results | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $created created, $exists already there, $planned planned, $failed failed."

$results
if ($failed -gt 0) { exit 1 }
exit 0
