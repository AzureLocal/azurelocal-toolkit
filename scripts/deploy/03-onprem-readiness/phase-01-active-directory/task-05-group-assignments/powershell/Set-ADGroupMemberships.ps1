<#
.SYNOPSIS
    Adds the members that identity.active_directory.security_groups[].members of infrastructure.yml lists to their Active Directory security groups.

.DESCRIPTION
    Phase 01 (Active Directory), Task 05 (group assignments). For each entry of identity.active_directory.security_groups that lists members the
    script finds the group in the domain (identity.active_directory.domain_fqdn) and adds each member that is not in it yet, with Add-ADGroupMember
    (Microsoft Learn: Add-ADGroupMember, Get-ADGroupMember, Get-ADObject in the ActiveDirectory module).

    A member is an account name: a sAMAccountName (a computer account ends in $) or a user principal name (name@domain). It can be a user, a
    computer or a group. The script looks the member up in the domain first and refuses to guess: a member that is not found is reported and
    the others are still added. The group has to exist already: this script does not create groups.

    Idempotent, and additive. A member that is in the group is reported as AlreadyMember. The script never removes a member, never creates
    or deletes a group or an account, and never changes anything but the membership list. -WhatIf changes nothing.

    With scenario.identity local_identity the instance has no Active Directory: the script does nothing and exits 0.

    The script does not sign in anywhere and asks nothing. It uses the account that runs it, or -Credential, and needs the ActiveDirectory module
    (Remote Server Administration Tools or a domain controller) and the right to change the membership of the groups.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        scenario.identity, identity.active_directory.domain_fqdn
        identity.active_directory.security_groups[].name, .members

    Exit codes: 0 every member is in its group (added now, already there, planned under -WhatIf) or the file lists no member; 1 the domain could
    not be reached, the ActiveDirectory module is missing, a group does not exist or a member could not be added or found; 2 a value in the file
    is missing or not usable (no domain_fqdn, a group with no name, a member that is not a name, a name listed twice).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER Credential
    Optional. The account that changes the groups. Without it the account that runs the script is used.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-ADGroupMemberships.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which accounts would be added to which groups. Changes nothing.

.EXAMPLE
    ./Set-ADGroupMemberships.ps1 -InfrastructureFile ./infrastructure.yml

    Adds the members. Run it again: they are reported as AlreadyMember.
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
# Escapes a value for an LDAP filter (RFC 4515).
function ConvertTo-LdapValue([string]$Value) {
    $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

if (([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.identity')).Trim().ToLowerInvariant() -eq 'local_identity') {
    Write-Line 'scenario.identity is local_identity: the instance has no Active Directory, so there is no group to fill.'
    exit 0
}
$identity = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity'
$directory = Get-Field $identity 'active_directory'
$groupList = @(@(Get-Field $directory 'security_groups' @()) | Where-Object { $null -ne $_ })

$plans = [System.Collections.Generic.List[object]]::new()
$seenGroup = @{}
$index = -1
foreach ($group in $groupList) {
    $index++
    $at = "identity.active_directory.security_groups[$index]"
    if ($group -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a group (a map with name and members)." }
    $name = ([string](Get-Field $group 'name' '')).Trim()
    if (-not $name) { Exit-InputProblem "$at has no name." }
    if ($seenGroup.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seenGroup[$name.ToLowerInvariant()] = $true
    $members = [System.Collections.Generic.List[string]]::new()
    foreach ($member in @(@(Get-Field $group 'members' @()) | Where-Object { $null -ne $_ })) {
        if ($member -isnot [string] -or [string]::IsNullOrWhiteSpace($member)) { Exit-InputProblem "$at.members holds a value that is not an account name." }
        $text = $member.Trim()
        if ($text -notmatch '^[A-Za-z0-9._$ -]+$' -and $text -notmatch '^[^@\s\\/"\[\]:;|=,+*?<>]+@[A-Za-z0-9.-]+$') { Exit-InputProblem "$at.members: '$text' is not an account name. Use a sAMAccountName or a user principal name (name@domain)." }
        if (-not ($members | Where-Object { $_ -ieq $text })) { $members.Add($text) }
    }
    if ($members.Count -gt 0) { $plans.Add([pscustomobject]@{ Group = $name; Members = @($members) }) }
}
if ($plans.Count -eq 0) {
    Write-Line 'The file lists no identity.active_directory.security_groups[].members: nothing to do.'
    exit 0
}
$domain = ([string](Get-Field $directory 'domain_fqdn' '')).Trim()
if (-not $domain) { Exit-InputProblem 'identity.active_directory.domain_fqdn is missing. It is the domain whose groups are changed.' }

# ---- preconditions (read only)
foreach ($cmd in 'Get-ADGroup', 'Get-ADGroupMember', 'Get-ADObject', 'Add-ADGroupMember') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the ActiveDirectory module (Remote Server Administration Tools: Install-WindowsFeature RSAT-AD-PowerShell on a server, or Add-WindowsCapability for Windows 11) or run the script on a domain controller." }
}
$adCommon = @{ Server = $domain; ErrorAction = 'Stop' }
if ($Credential) { $adCommon.Credential = $Credential }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Group, [string]$Member, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Group = $Group; Member = $Member; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed] ' } 'AlreadyMember' { '[exists] ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[done]   ' } }
    Write-Line ("{0}{1} / {2}: {3}{4}" -f $tag, $Group, $Member, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

foreach ($plan in $plans) {
    $adGroup = $null
    try { $adGroup = Get-ADGroup -Identity $plan.Group @adCommon }
    catch {
        $detail = if ($_.Exception.Message -match 'Cannot find an object|not find|does not exist|ADIdentityNotFound') { "The group '$($plan.Group)' does not exist in $domain. Create it first." } else { $_.Exception.Message }
        foreach ($member in $plan.Members) { Add-Row $plan.Group $member 'Failed' $detail }
        continue
    }
    try { $current = @(Get-ADGroupMember -Identity $adGroup @adCommon | ForEach-Object { [string]$_.DistinguishedName }) }
    catch { foreach ($member in $plan.Members) { Add-Row $plan.Group $member 'Failed' "The members of '$($plan.Group)' could not be read: $($_.Exception.Message)" }; continue }

    foreach ($member in $plan.Members) {
        try {
            $filter = if ($member -match '^[^@]+@[^@]+$') { "(userPrincipalName=$(ConvertTo-LdapValue $member))" } else { "(sAMAccountName=$(ConvertTo-LdapValue $member))" }
            $found = @(Get-ADObject -LDAPFilter $filter @adCommon)
            if ($found.Count -eq 0) { Add-Row $plan.Group $member 'Failed' "No account '$member' was found in $domain."; continue }
            if ($found.Count -gt 1) { Add-Row $plan.Group $member 'Failed' "More than one object matches '$member' in $domain. Use the user principal name."; continue }
            $distinguishedName = [string]$found[0].DistinguishedName
            if ($current -contains $distinguishedName) { Add-Row $plan.Group $member 'AlreadyMember'; continue }
            if ($PSCmdlet.ShouldProcess("$member -> $($plan.Group)", 'Add group membership')) {
                Add-ADGroupMember -Identity $adGroup -Members $distinguishedName @adCommon
                Add-Row $plan.Group $member 'Added'
            }
            else { Add-Row $plan.Group $member 'WouldAdd' }
        }
        catch { Add-Row $plan.Group $member 'Failed' $_.Exception.Message }
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
