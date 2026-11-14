<#
.SYNOPSIS
    Creates the optional domain join account of infrastructure.yml in Active Directory.

.DESCRIPTION
    Phase 01 (Active Directory), Task 04. The LCM deployment user is created by task 01 (Set-ADConfiguration.ps1), as Microsoft's preparation
    does it. This task creates the other account the file can name: identity.active_directory.domain_join_account, the account the OS
    configuration joins the machines with when it is not the LCM user (Microsoft Learn: the join needs the right to create and delete
    computer objects in the dedicated OU).

    The account is created in the dedicated OU (identity.active_directory.ou_path), enabled, with the user principal name <name>@<domain>.
    The password is read through the secret resolver (scripts/common/secrets/AzlSecret.psm1) from the reference in
    identity.active_directory.domain_join_account.password, in memory only; it is never generated, shown or stored here. The domain's own
    password policy applies: the script sets no "never expires" flag.

    The script creates the account only. It does not give it rights on the OU: delegate "create and delete computer objects" on the OU to it
    (Microsoft Learn: Custom Active Directory configuration for your Azure Local instance, Required permissions).

    Idempotent. An account of that name is reported as AlreadyExists and left alone. A file without a domain_join_account does nothing and
    exits 0. -WhatIf changes nothing. The script never deletes an account.

    With scenario.identity local_identity the instance has no Active Directory: the script does nothing and exits 0.

    The script asks nothing and signs in nowhere. It uses the account that runs it, or -Credential, and needs the ActiveDirectory module and
    the right to create users in the OU.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        scenario.identity
        identity.active_directory.domain_fqdn, .ou_path
        identity.active_directory.domain_join_account.username, .password

    Exit codes: 0 the account exists (created now, already there, or planned under -WhatIf) or the file names none; 1 the domain or the OU
    could not be reached, the module is missing, the secret could not be read or the account could not be created; 2 a value in the file is
    missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER Credential
    Optional. The account that creates the user. Without it the account that runs the script is used.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-ADAccounts.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows whether the account would be created, and creates nothing.
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

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'secrets', 'AzlSecret.psm1')) -Force

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
    Write-Line 'scenario.identity is local_identity: the instance has no Active Directory, so there is no account to create.'
    exit 0
}
$directory = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory'
$join = Get-Field $directory 'domain_join_account'
$joinUser = ([string](Get-Field $join 'username' '')).Trim()
if (-not $joinUser) {
    Write-Line 'The file has no identity.active_directory.domain_join_account: the LCM user joins the machines, and task 01 creates it. Nothing to do.'
    exit 0
}
$reference = ([string](Get-Field $join 'password' '')).Trim()
$domain = ([string](Get-Field $directory 'domain_fqdn' '')).Trim()
$ouPath = ([string](Get-Field $directory 'ou_path' '')).Trim()
$netbios = ([string](Get-Field $directory 'netbios_name' '')).Trim()
if (-not $domain) { Exit-InputProblem 'identity.active_directory.domain_fqdn is missing. It is the domain the account is created in.' }
if (-not $ouPath) { Exit-InputProblem 'identity.active_directory.ou_path is missing. It is the OU the account is created in.' }
if (-not $reference) { Exit-InputProblem 'identity.active_directory.domain_join_account.password is missing. It is the secret reference of the account''s password.' }

# The account name: a name, NETBIOS\name or name@domain (the forms the registry allows). Only the name part is created.
$sam = $joinUser
if ($joinUser -match '^(?<d>[^\\@]+)\\(?<n>[^\\@]+)$') {
    if ($netbios -and $Matches['d'] -ine $netbios) { Exit-InputProblem "identity.active_directory.domain_join_account.username '$joinUser' names the domain '$($Matches['d'])', not '$netbios'." }
    $sam = $Matches['n']
}
elseif ($joinUser -match '^(?<n>[^\\@]+)@(?<d>[^\\@]+)$') {
    if ($Matches['d'] -ine $domain) { Exit-InputProblem "identity.active_directory.domain_join_account.username '$joinUser' names the domain '$($Matches['d'])', not '$domain'." }
    $sam = $Matches['n']
}
# sAMAccountName: at most 20 characters, none of the characters Microsoft lists (Microsoft Learn: Naming conventions in Active Directory).
if ($sam.Length -gt 20 -or $sam -match '["/\\\[\]:;|=,+*?<>@\s]') { Exit-InputProblem "The account name '$sam' is not valid: at most 20 characters, no space and none of the characters  / \ [ ] : ; | = , + * ? < > @." }

# ---- preconditions (read only)
foreach ($cmd in 'Get-ADUser', 'New-ADUser', 'Get-ADOrganizationalUnit') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the ActiveDirectory module (Remote Server Administration Tools) or run the script on a domain controller." }
}
$adCommon = @{ Server = $domain; ErrorAction = 'Stop' }
if ($Credential) { $adCommon.Credential = $Credential }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Account, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Account = $Account; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyExists' { '[exists]  ' } 'WouldCreate' { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Account, $(if ($Detail) { " ($Detail)" } else { '' }))
}

try {
    $ouFound = [bool](Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$($ouPath.Replace("'", "''"))'" @adCommon)
    if (Get-ADUser -Filter "SamAccountName -eq '$($sam.Replace("'", "''"))'" @adCommon) { Add-Row $sam 'AlreadyExists' }
    elseif (-not $ouFound -and -not $WhatIfPreference) { Add-Row $sam 'Failed' "The OU '$ouPath' does not exist. Run task 01 (Set-ADConfiguration.ps1) first." }
    elseif ($PSCmdlet.ShouldProcess("OU $ouPath", "Create the account '$sam'")) {
        $secure = $null
        try { $secure = Get-AzlSecretValue -Reference $reference -Infrastructure $infra }
        catch {
            $code = if ($_.Exception.Data.Contains('AzlExit')) { [int]$_.Exception.Data['AzlExit'] } else { 1 }
            if ($code -eq 2) { Exit-InputProblem "identity.active_directory.domain_join_account.password: $($_.Exception.Message)" }
            Exit-Failed "The password of the account could not be read: $($_.Exception.Message)"
        }
        New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName "$sam@$domain" -Path $ouPath -AccountPassword $secure -Enabled $true @adCommon
        Add-Row $sam 'Created'
    }
    else { Add-Row $sam 'WouldCreate' }
}
catch { Add-Row $sam 'Failed' $_.Exception.Message }

$failed = @($rows | Where-Object Action -EQ 'Failed').Count
$rows
if ($failed -gt 0) { exit 1 }
exit 0
