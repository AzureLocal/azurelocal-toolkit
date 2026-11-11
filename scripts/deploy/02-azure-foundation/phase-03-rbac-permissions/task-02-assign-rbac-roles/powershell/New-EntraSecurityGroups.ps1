<#
.SYNOPSIS
    Creates the Microsoft Entra security groups that identity.entra.groups of infrastructure.yml lists.

.DESCRIPTION
    Phase 03 (RBAC and permissions), Task 02 (assign RBAC roles). The role assignments of this task go to groups, so the groups come first:
    this script creates one Microsoft Entra security group (not mail enabled, assigned membership) for each entry of identity.entra.groups.
    It adds no members and assigns no roles; Set-EntraGroupRoleAssignments.ps1 assigns the roles the same entries name.

    Idempotent. A group whose display name already exists is reported as AlreadyExists and left alone, so a second run with the same file
    creates nothing. If more than one group already has the display name, the entry is reported as Conflict and nothing is created for it,
    because the role assignment script could not tell which group is meant. -WhatIf changes nothing.

    The script reads Microsoft Entra ID and writes only with New-MgGroup, behind -WhatIf. It does not sign in: run Connect-MgGraph to the tenant
    in azure.tenant_id first, with the scope Group.ReadWrite.All (or Group.Create). The group object ids are written to the result, not to the
    file: record them where your records need them.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                       the tenant the sign-in must belong to
        identity.entra.groups[].name          the display name of the group (1 to 256 characters)
        identity.entra.groups[].purpose       the description of the group (optional, up to 1024 characters)

    Exit codes: 0 every group exists (created now, already there or planned under -WhatIf); 1 a Graph call failed, a precondition failed (not
    signed in, wrong tenant, the Microsoft.Graph.Groups module missing, missing scope), a group could not be created or the name is in conflict;
    2 the file lists no group or a value is not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-EntraSecurityGroups.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which groups would be created and which exist, and creates nothing.

.EXAMPLE
    Connect-MgGraph -TenantId <tenant-id> -Scopes Group.ReadWrite.All
    ./New-EntraSecurityGroups.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the missing groups. Run it again: every group is AlreadyExists.
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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$MaxNameLength = 256
$MaxDescriptionLength = 1024
$WriteScopes = 'Group.ReadWrite.All', 'Group.Create', 'Directory.ReadWrite.All'

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

# A mail nickname is required by Graph even for a group that is not mail enabled: letters, digits, hyphen and underscore, at most 64.
function Get-MailNickname([string]$Name) {
    $nickname = $Name -replace '[^A-Za-z0-9_-]', ''
    if (-not $nickname) { $nickname = 'group' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Name))).Substring(0, 8) }
    if ($nickname.Length -gt 64) { $nickname = $nickname.Substring(0, 64) }
    $nickname
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$rawGroups = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.entra.groups'
$entries = @(@($rawGroups) | Where-Object { $_ -is [System.Collections.IDictionary] })

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($entries.Count -eq 0) { Exit-InputProblem 'identity.entra.groups is empty. List the groups to create, each with a name.' }

$plan = foreach ($entry in $entries) {
    $name = if ($entry.Contains('name') -and $entry['name']) { ([string]$entry['name']).Trim() } else { '' }
    if (-not $name) { Exit-InputProblem 'An entry of identity.entra.groups has no name.' }
    if ($name.Length -gt $MaxNameLength) { Exit-InputProblem "identity.entra.groups: the name '$name' is longer than $MaxNameLength characters." }
    $purpose = if ($entry.Contains('purpose') -and $entry['purpose']) { ([string]$entry['purpose']).Trim() } else { '' }
    if ($purpose.Length -gt $MaxDescriptionLength) { Exit-InputProblem "identity.entra.groups '$name': the purpose is longer than $MaxDescriptionLength characters." }
    [pscustomobject]@{ Name = $name; Description = $(if ($purpose) { $purpose } else { 'Azure Local security group' }) }
}
$plan = @($plan)
$duplicate = @($plan | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -GT 1)
if ($duplicate.Count) { Exit-InputProblem "The group name '$($duplicate[0].Group[0].Name)' appears more than once in identity.entra.groups." }

# ---- preconditions (read only)
foreach ($cmd in 'Get-MgContext', 'Get-MgGroup', 'New-MgGroup') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Microsoft Graph modules: Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups -Scope CurrentUser." }
}
$context = Get-MgContext
if (-not $context) { Exit-Failed 'Not signed in to Microsoft Graph. Run Connect-MgGraph -TenantId <azure.tenant_id> -Scopes Group.ReadWrite.All.' }
if ([string]$context.TenantId -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.TenantId), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$scopes = @($context.Scopes | Where-Object { $_ })
if ($scopes.Count -gt 0 -and -not @($scopes | Where-Object { $WriteScopes -contains $_ })) {
    Exit-Failed "The Graph sign-in has the scopes $($scopes -join ', '), none of which lets it create groups. Run Connect-MgGraph -TenantId <azure.tenant_id> -Scopes Group.ReadWrite.All."
}

Write-Line "Creating $($plan.Count) Microsoft Entra security group(s)"

# ---- one group at a time
$results = foreach ($item in $plan) {
    $row = [ordered]@{ Name = $item.Name; Action = ''; Id = ''; Detail = '' }
    try {
        $filter = "displayName eq '$($item.Name.Replace("'", "''"))'"
        $found = @(Get-MgGroup -Filter $filter -ErrorAction Stop)
        if ($found.Count -gt 1) {
            $row.Action = 'Conflict'
            $row.Detail = "$($found.Count) groups already have this display name; nothing was created. Remove or rename the extra groups, then run again."
            Write-Warning "$($item.Name): $($row.Detail)"
        }
        elseif ($found.Count -eq 1) {
            $row.Action = 'AlreadyExists'; $row.Id = [string]$found[0].Id
            Write-Line "[exists]  $($item.Name): already there, nothing changed."
        }
        elseif ($PSCmdlet.ShouldProcess("group '$($item.Name)'", 'Create Microsoft Entra security group')) {
            $created = New-MgGroup -DisplayName $item.Name -Description $item.Description -MailNickname (Get-MailNickname $item.Name) -SecurityEnabled -MailEnabled:$false -ErrorAction Stop
            $row.Action = 'Created'; $row.Id = [string]$created.Id
            Write-Line "[created] $($item.Name): created."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    $($item.Name): would be created."
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
$existing = @($results | Where-Object Action -EQ 'AlreadyExists').Count
$planned = @($results | Where-Object Action -EQ 'WouldCreate').Count
$conflict = @($results | Where-Object Action -EQ 'Conflict').Count
$failed = @($results | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $created created, $existing already existed, $planned planned, $conflict in conflict, $failed failed."
if ($created -eq 0 -and $planned -eq 0 -and $conflict -eq 0 -and $failed -eq 0) { Write-Line 'Nothing to do: every group already exists.' }

[pscustomobject]@{ Created = $created; AlreadyExists = $existing; Planned = $planned; Conflict = $conflict; Failed = $failed; Groups = $results }
if ($failed -gt 0 -or $conflict -gt 0) { exit 1 }
exit 0
