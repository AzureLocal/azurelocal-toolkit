<#
.SYNOPSIS
    Assigns the Azure roles that identity.entra.groups of infrastructure.yml gives each Microsoft Entra group, at the scope it names, with the Azure CLI.

.DESCRIPTION
    Phase 03 (RBAC and permissions), Task 02 (assign RBAC roles), Azure CLI variant of Set-EntraGroupRoleAssignments.ps1. For each entry of
    identity.entra.groups that has roles, this script finds the Microsoft Entra group of that display name ("az ad group list"; New-EntraSecurityGroups.azcli.ps1
    creates it) and makes sure the group holds each listed Azure role at the entry's scope ("az role assignment create"). The scope is
    identity.entra.groups[].scope; when an entry has none, it is the resource group of the instance (azure.subscription_id and azure.resource_group).
    A scope is a subscription, a resource group, a resource, or a management group.

    Idempotent. A role the group already holds at exactly that scope is reported as AlreadyAssigned and left alone, so a second run with the same
    file assigns nothing. A role assignment made at a higher scope does not count: the file says where the role belongs, and the script puts it
    there. The script never removes a role assignment. A group that does not exist, or whose display name two groups share, is reported as Failed and
    nothing is assigned to it; a role name Azure does not know is reported as Failed. -WhatIf changes nothing.

    WARNING. Owner and User Access Administrator let the group grant access to others. The script assigns exactly the roles the file lists; review
    the file before you run it for a role that carries those permissions.

    The script reads Azure and Microsoft Entra ID (read only) and writes only with "az role assignment create", behind -WhatIf. It does not sign in:
    run "az login --tenant <azure.tenant_id>" first. You need a role that can write role assignments at each scope (for example Role Based Access
    Control Administrator or User Access Administrator), and permission to read groups.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                        the tenant the sign-in must belong to
        azure.subscription_id, azure.resource_group   the default scope of an entry that has none
        identity.entra.groups[].name           the display name of the group
        identity.entra.groups[].roles          the Azure role names to assign
        identity.entra.groups[].scope          where to assign them (optional)

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every listed role is assigned (now, already, or planned under -WhatIf); 1 an Azure call failed, a precondition failed (az missing,
    not signed in, wrong tenant), a group or role was not found or an assignment failed; 2 the file lists no group with roles, or a value is not
    usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-EntraGroupRoleAssignments.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which role assignments would be made, and makes none.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Set-EntraGroupRoleAssignments.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Assigns the roles that are missing. Run it again: every role is AlreadyAssigned.
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

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$ScopePattern = '^/(subscriptions/[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(/resourceGroups/[^/]+(/providers/.+)?)?|providers/Microsoft\.Management/managementGroups/[^/]+)$'

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
$subscriptionId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.subscription_id')).Trim()
$resourceGroup = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.resource_group')).Trim()
$rawGroups = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.entra.groups'
$entries = @(@($rawGroups) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawGroups)) { Exit-InputProblem 'An entry of identity.entra.groups is not a map (names with their settings).' } })

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($entries.Count -eq 0) { Exit-InputProblem 'identity.entra.groups is empty. List the groups with their roles and scope.' }

$defaultScope = ''
if ($subscriptionId -match $Guid -and $subscriptionId -ne [guid]::Empty.ToString() -and $resourceGroup) {
    $defaultScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
}

$plan = foreach ($entry in $entries) {
    $name = if ($entry.Contains('name') -and $entry['name']) { ([string]$entry['name']).Trim() } else { '' }
    if (-not $name) { Exit-InputProblem 'An entry of identity.entra.groups has no name.' }
    $roles = @(@($(if ($entry.Contains('roles')) { $entry['roles'] })) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
    $scope = if ($entry.Contains('scope') -and $entry['scope']) { ([string]$entry['scope']).Trim().TrimEnd('/') } else { $defaultScope }
    if ($roles.Count -gt 0) {
        if (-not $scope) { Exit-InputProblem "identity.entra.groups '$name': no scope, and azure.subscription_id and azure.resource_group do not give a default. Set the scope of the entry." }
        if ($scope -notmatch $ScopePattern) { Exit-InputProblem "identity.entra.groups '$name': the scope '$scope' is not a subscription, resource group, resource or management group scope (for example /subscriptions/<id>/resourceGroups/<name>)." }
    }
    [pscustomobject]@{ Name = $name; Roles = $roles; Scope = $scope }
}
$plan = @($plan)
$duplicate = @($plan | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -GT 1)
if ($duplicate.Count) { Exit-InputProblem "The group name '$($duplicate[0].Group[0].Name)' appears more than once in identity.entra.groups." }
if (@($plan | Where-Object { $_.Roles.Count -gt 0 }).Count -eq 0) { Exit-InputProblem 'No entry of identity.entra.groups lists a role, so there is nothing to assign.' }

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
foreach ($item in $plan) {
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "identity.entra.groups '$($item.Name)' name" = $item.Name; "identity.entra.groups '$($item.Name)' roles" = $item.Roles; "identity.entra.groups '$($item.Name)' scope" = $item.Scope })
    if ($problem) { Exit-InputProblem $problem }
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Set-EntraGroupRoleAssignments.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$wanted = @($plan | ForEach-Object { foreach ($role in $_.Roles) { [pscustomobject]@{ Group = $_.Name; Role = $role; Scope = $_.Scope } } })
Write-Line "Assigning roles to Microsoft Entra groups ($($wanted.Count) assignment(s) for $(@($plan | Where-Object { $_.Roles.Count -gt 0 }).Count) group(s), $(@($plan | Where-Object { $_.Roles.Count -eq 0 }).Count) skipped)"

# a group, and a role at a scope, is looked up once
$groupLookup = @{}
function Get-GroupLookup([string]$Name) {
    if ($groupLookup.ContainsKey($Name)) { return $groupLookup[$Name] }
    $filter = "displayName eq '$($Name.Replace("'", "''"))'"
    $found = @(Invoke-Az -AzArgument @('ad', 'group', 'list', '--filter', $filter, '--query', '[].id', '--output', 'json') | ConvertFrom-Json)
    $groupLookup[$Name] = $found
    $found
}
$roleKnown = @{}
function Test-RoleKnown([string]$Role, [string]$Scope) {
    $key = "$Role|$Scope"
    if ($roleKnown.ContainsKey($key)) { return $roleKnown[$key] }
    $found = @(Invoke-Az -AzArgument @('role', 'definition', 'list', '--name', $Role, '--scope', $Scope, '--query', '[].id', '--output', 'json') | ConvertFrom-Json)
    $roleKnown[$key] = ($found.Count -gt 0)
    $roleKnown[$key]
}

# ---- one assignment at a time
$results = foreach ($entry in $plan) {
    if ($entry.Roles.Count -eq 0) {
        Write-Line "[skip]     $($entry.Name): no roles listed."
        [pscustomobject][ordered]@{ Group = $entry.Name; Role = ''; Scope = ''; Action = 'Skipped'; Detail = 'no roles listed' }
        continue
    }
    foreach ($role in $entry.Roles) {
        $row = [ordered]@{ Group = $entry.Name; Role = $role; Scope = $entry.Scope; Action = ''; Detail = '' }
        try {
            $groups = @(Get-GroupLookup $entry.Name)
            if ($groups.Count -eq 0) {
                $row.Action = 'Failed'; $row.Detail = "The group '$($entry.Name)' was not found in Microsoft Entra ID. Create it first (New-EntraSecurityGroups.azcli.ps1)."
                Write-Warning "$($entry.Name) / ${role}: $($row.Detail)"
            }
            elseif ($groups.Count -gt 1) {
                $row.Action = 'Failed'; $row.Detail = "$($groups.Count) groups have the display name '$($entry.Name)', so the group to assign to is not known. Remove or rename the extra groups."
                Write-Warning "$($entry.Name) / ${role}: $($row.Detail)"
            }
            elseif (-not (Test-RoleKnown $role $entry.Scope)) {
                $row.Action = 'Failed'; $row.Detail = "The role '$role' was not found at $($entry.Scope). Check the spelling against az role definition list."
                Write-Warning "$($entry.Name) / ${role}: $($row.Detail)"
            }
            else {
                $objectId = [string]$groups[0]
                $held = @(Invoke-Az -AzArgument @('role', 'assignment', 'list', '--assignee', $objectId, '--role', $role, '--scope', $entry.Scope, '--query', '[].scope', '--output', 'json') | ConvertFrom-Json |
                        Where-Object { $_ -and [string]$_ -ieq $entry.Scope })
                if ($held.Count -gt 0) {
                    $row.Action = 'AlreadyAssigned'
                    Write-Line "[held]     $($entry.Name): $role at $($entry.Scope), nothing changed."
                }
                elseif ($PSCmdlet.ShouldProcess("group '$($entry.Name)'", "Assign the role '$role' at $($entry.Scope)")) {
                    $null = Invoke-Az -AzArgument @('role', 'assignment', 'create', '--assignee-object-id', $objectId, '--assignee-principal-type', 'Group', '--role', $role, '--scope', $entry.Scope, '--output', 'none')
                    $row.Action = 'Assigned'
                    Write-Line "[assigned] $($entry.Name): $role at $($entry.Scope)."
                }
                else {
                    $row.Action = 'WouldAssign'
                    Write-Line "[plan]     $($entry.Name): would get $role at $($entry.Scope)."
                }
            }
        }
        catch {
            $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
            Write-Warning "$($entry.Name) / ${role}: $($row.Detail)"
        }
        [pscustomobject]$row
    }
}

$results = @($results)
$assigned = @($results | Where-Object Action -EQ 'Assigned').Count
$alreadyHeld = @($results | Where-Object Action -EQ 'AlreadyAssigned').Count
$planned = @($results | Where-Object Action -EQ 'WouldAssign').Count
$skipped = @($results | Where-Object Action -EQ 'Skipped').Count
$failed = @($results | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $assigned assigned, $alreadyHeld already assigned, $planned planned, $skipped skipped, $failed failed."
if ($assigned -eq 0 -and $planned -eq 0 -and $failed -eq 0) { Write-Line 'Nothing to do: every listed role is already assigned.' }

[pscustomobject]@{ Assigned = $assigned; AlreadyAssigned = $alreadyHeld; Planned = $planned; Skipped = $skipped; Failed = $failed; Assignments = $results }
if ($failed -gt 0) { exit 1 }
exit 0
