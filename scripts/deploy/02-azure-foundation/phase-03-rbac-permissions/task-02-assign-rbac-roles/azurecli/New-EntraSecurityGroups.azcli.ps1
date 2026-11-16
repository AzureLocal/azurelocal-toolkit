<#
.SYNOPSIS
    Creates the Microsoft Entra security groups that identity.entra.groups of infrastructure.yml lists, with the Azure CLI.

.DESCRIPTION
    Phase 03 (RBAC and permissions), Task 02 (assign RBAC roles), Azure CLI variant of New-EntraSecurityGroups.ps1. The role assignments of this task
    go to groups, so the groups come first: this script creates one Microsoft Entra security group (not mail enabled, assigned membership) with
    "az ad group create" for each entry of identity.entra.groups. It adds no members and assigns no roles; Set-EntraGroupRoleAssignments.azcli.ps1
    assigns the roles the same entries name.

    Idempotent. A group whose display name already exists is reported as AlreadyExists and left alone, so a second run with the same file creates
    nothing. If more than one group already has the display name, the entry is reported as Conflict and nothing is created for it, because the role
    assignment script could not tell which group is meant. The same holds for one group of that name that is not a security group (a Microsoft 365
    group or a distribution list): it cannot take the role assignments. -WhatIf changes nothing.

    The script reads Microsoft Entra ID with "az ad group list" and writes only with "az ad group create", behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first, as an account that may create groups (Groups Administrator, or the tenant setting that lets users
    create security groups). The group object ids are written to the result, not to the file: record them where your records need them.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                       the tenant the sign-in must belong to
        identity.entra.groups[].name          the display name of the group (1 to 256 characters)
        identity.entra.groups[].purpose       the description of the group (optional, up to 1024 characters)

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every group exists (created now, already there or planned under -WhatIf); 1 a Graph call failed, a precondition failed (az
    missing, not signed in, wrong tenant), a group could not be created or the name is in conflict; 2 the file lists no group or a value is not
    usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-EntraSecurityGroups.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which groups would be created and which exist, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-EntraSecurityGroups.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$MaxNameLength = 256
$MaxDescriptionLength = 1024

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

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$rawGroups = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.entra.groups'
$entries = @(@($rawGroups) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawGroups)) { Exit-InputProblem 'An entry of identity.entra.groups is not a map (names with their settings).' } })

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

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
foreach ($item in $plan) {
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ "identity.entra.groups '$($item.Name)' name" = $item.Name; "identity.entra.groups '$($item.Name)' purpose" = $item.Description })
    if ($problem) { Exit-InputProblem $problem }
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-EntraSecurityGroups.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

Write-Line "Creating $($plan.Count) Microsoft Entra security group(s)"

# ---- one group at a time
$results = foreach ($item in $plan) {
    $row = [ordered]@{ Name = $item.Name; Action = ''; Id = ''; Detail = '' }
    try {
        $filter = "displayName eq '$($item.Name.Replace("'", "''"))'"
        $found = @(Invoke-Az -AzArgument @('ad', 'group', 'list', '--filter', $filter, '--query', '[].{id:id,securityEnabled:securityEnabled}', '--output', 'json') | ConvertFrom-Json)
        if ($found.Count -gt 1) {
            $row.Action = 'Conflict'
            $row.Detail = "$($found.Count) groups already have this display name; nothing was created. Remove or rename the extra groups, then run again."
            Write-Warning "$($item.Name): $($row.Detail)"
        }
        elseif ($found.Count -eq 1 -and $found[0].PSObject.Properties['securityEnabled'] -and $found[0].securityEnabled -eq $false) {
            # A group of this name that is not a security group (a Microsoft 365 group or a distribution list) cannot take the Azure role
            # assignments of this task, and a second group of the same name would make the role assignment script unable to tell them apart.
            $row.Action = 'Conflict'; $row.Id = [string]$found[0].id
            $row.Detail = 'A group with this display name already exists, but it is not a security group; nothing was created. Rename that group or choose another name, then run again.'
            Write-Warning "$($item.Name): $($row.Detail)"
        }
        elseif ($found.Count -eq 1) {
            $row.Action = 'AlreadyExists'; $row.Id = [string]$found[0].id
            Write-Line "[exists]  $($item.Name): already there, nothing changed."
        }
        elseif ($PSCmdlet.ShouldProcess("group '$($item.Name)'", 'Create Microsoft Entra security group')) {
            $created = Invoke-Az -AzArgument @('ad', 'group', 'create', '--display-name', $item.Name, '--mail-nickname', (Get-MailNickname $item.Name), '--description', $item.Description, '--query', 'id', '--output', 'tsv')
            $row.Action = 'Created'; $row.Id = $created
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
