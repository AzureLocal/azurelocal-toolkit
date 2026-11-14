<#
.SYNOPSIS
    Creates the Active Directory security groups that identity.active_directory.security_groups[] of infrastructure.yml lists.

.DESCRIPTION
    Phase 01 (Active Directory), Task 02. For each entry of identity.active_directory.security_groups the script creates a global security
    group with the entry's name, in the dedicated OU of the instance (identity.active_directory.ou_path), with the entry's purpose as its
    description. The names are the file's: this script has none of its own, and Set-ADGroupMemberships.ps1 (task 05) fills the same groups
    from the same entries, so the two scripts always agree.

    Idempotent. A group of that name that exists anywhere in the domain is reported as AlreadyExists and left alone (its OU, scope and
    description are not changed). The script never deletes a group and never changes a membership. -WhatIf changes nothing.

    With scenario.identity local_identity the instance has no Active Directory: the script does nothing and exits 0.

    The script asks nothing and signs in nowhere. It uses the account that runs it, or -Credential, and needs the ActiveDirectory module
    (Remote Server Administration Tools or a domain controller) and the right to create groups in the OU. Run task 01
    (Set-ADConfiguration.ps1) first: it creates the OU.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        scenario.identity
        identity.active_directory.domain_fqdn, .ou_path
        identity.active_directory.security_groups[].name, .purpose

    Exit codes: 0 every listed group exists (created now, already there, or planned under -WhatIf) or the file lists none; 1 the domain or
    the OU could not be reached, the ActiveDirectory module is missing or a group could not be created; 2 a value in the file is missing or
    not usable (no domain or OU, a group with no name, a name listed twice).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER Credential
    Optional. The account that creates the groups. Without it the account that runs the script is used.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-ADSecurityGroups.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which groups would be created, and creates none.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# A security group of one domain that holds accounts has the scope Global (Microsoft Learn: Active Directory security groups, group scopes).
$GroupScope = 'Global'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Field($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and "$($Map[$Key])" -ne '') { return $Map[$Key] }
    $Default
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

if (([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.identity')).Trim().ToLowerInvariant() -eq 'local_identity') {
    Write-Line 'scenario.identity is local_identity: the instance has no Active Directory, so there is no group to create.'
    exit 0
}
$directory = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory'
$groupList = @(@(Get-Field $directory 'security_groups' @()) | Where-Object { $null -ne $_ })
if ($groupList.Count -eq 0) {
    Write-Line 'The file lists no identity.active_directory.security_groups: nothing to do.'
    exit 0
}
$domain = ([string](Get-Field $directory 'domain_fqdn' '')).Trim()
$ouPath = ([string](Get-Field $directory 'ou_path' '')).Trim()
if (-not $domain) { Exit-InputProblem 'identity.active_directory.domain_fqdn is missing. It is the domain the groups are created in.' }
if (-not $ouPath) { Exit-InputProblem 'identity.active_directory.ou_path is missing. It is the OU the groups are created in.' }

$plans = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($group in $groupList) {
    $index++
    $at = "identity.active_directory.security_groups[$index]"
    if ($group -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a group (a map with a name)." }
    $name = ([string](Get-Field $group 'name' '')).Trim()
    if (-not $name) { Exit-InputProblem "$at has no name." }
    # A group name (sAMAccountName) is at most 256 characters and has none of these characters (Microsoft Learn: Naming conventions in Active Directory).
    if ($name.Length -gt 256 -or $name -match '["/\\\[\]:;|=,+*?<>@]') { Exit-InputProblem "$at.name '$name' is not a valid group name." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seen[$name.ToLowerInvariant()] = $true
    $plans.Add([pscustomobject]@{ Name = $name; Description = ([string](Get-Field $group 'purpose' '')).Trim() })
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-ADGroup', 'New-ADGroup', 'Get-ADOrganizationalUnit') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the ActiveDirectory module (Remote Server Administration Tools) or run the script on a domain controller." }
}
$adCommon = @{ Server = $domain; ErrorAction = 'Stop' }
if ($Credential) { $adCommon.Credential = $Credential }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Group, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Group = $Group; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyExists' { '[exists]  ' } 'WouldCreate' { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Group, $(if ($Detail) { " ($Detail)" } else { '' }))
}

$ouFound = $false
try { $ouFound = [bool](Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$($ouPath.Replace("'", "''"))'" @adCommon) }
catch { Exit-Failed "The domain $domain could not be read: $($_.Exception.Message)" }

foreach ($plan in $plans) {
    try {
        if (Get-ADGroup -Filter "Name -eq '$($plan.Name.Replace("'", "''"))'" @adCommon) { Add-Row $plan.Name 'AlreadyExists'; continue }
        if (-not $ouFound -and -not $WhatIfPreference) { Add-Row $plan.Name 'Failed' "The OU '$ouPath' does not exist. Run task 01 (Set-ADConfiguration.ps1) first."; continue }
        if ($PSCmdlet.ShouldProcess("OU $ouPath", "Create the security group '$($plan.Name)'")) {
            $arguments = @{ Name = $plan.Name; GroupScope = $GroupScope; GroupCategory = 'Security'; Path = $ouPath }
            if ($plan.Description) { $arguments.Description = $plan.Description }
            New-ADGroup @arguments @adCommon
            Add-Row $plan.Name 'Created'
        }
        else { Add-Row $plan.Name 'WouldCreate' }
    }
    catch { Add-Row $plan.Name 'Failed' $_.Exception.Message }
}

$failed = @($rows | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $(@($rows | Where-Object Action -EQ 'Created').Count) created, $(@($rows | Where-Object Action -EQ 'AlreadyExists').Count) already existed, $(@($rows | Where-Object Action -EQ 'WouldCreate').Count) planned, $failed failed."
$rows
if ($failed -gt 0) { exit 1 }
exit 0
