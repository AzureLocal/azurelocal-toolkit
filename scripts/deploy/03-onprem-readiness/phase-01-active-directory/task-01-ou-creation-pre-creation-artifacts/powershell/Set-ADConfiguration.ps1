<#
.SYNOPSIS
    Prepares Active Directory for Azure Local from infrastructure.yml: the dedicated OU and the LCM deployment user, and, when the file asks,
    the computer objects of the machines and the cluster.

.DESCRIPTION
    Phase 01 (Active Directory), Task 01. Azure Local needs a dedicated organizational unit (OU) with group policy inheritance blocked, and a
    deployment (LCM) user that has the rights on that OU (Microsoft Learn: Prepare Active Directory for Azure Local deployment). Microsoft's
    own module does this: New-HciAdObjectsPreCreation of AsHciADArtifactsPreCreationTool (Install-Module AsHciADArtifactsPreCreationTool
    -Repository PSGallery). This script calls that cmdlet with the OU and the LCM user of the file, so the toolkit builds nothing of its own.

    The LCM user name and the OU are the keys of the file; the password is read through the secret resolver
    (scripts/common/secrets/AzlSecret.psm1) from the reference in identity.active_directory.lcm_user.password, in memory only.

    When identity.active_directory.precreate_computer_objects is true, the script also creates a computer object for each machine (nodes[].name)
    and the cluster (cluster.name) in the OU, as Microsoft Learn allows instead of letting the deployment create them (Custom Active Directory
    configuration for your Azure Local instance; Prestage cluster computer objects). The cluster object is created disabled, as that page says.
    Without the key, or with false, the objects are created by the OS configuration (the domain join) and the deployment.

    Idempotent. When the OU and the LCM user both exist, nothing is sent to the preparation module. When only one of the two exists, the
    script stops and says so: the module creates both, and a half-made preparation has to be looked at by a person. A computer object that
    exists is reported and left alone. -WhatIf changes nothing. The script never deletes anything.

    With scenario.identity local_identity the instance has no Active Directory: the script does nothing and exits 0.

    The script asks nothing and signs in nowhere. It uses the account that runs it, or -Credential, and needs the ActiveDirectory module
    (Remote Server Administration Tools or a domain controller), the AsHciADArtifactsPreCreationTool module, and the right to create an OU
    and a user in the domain.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        scenario.identity
        identity.active_directory.domain_fqdn, .ou_path, .lcm_user.username, .lcm_user.password, .precreate_computer_objects
        cluster.name, nodes[].name                  (only with precreate_computer_objects)

    Exit codes: 0 the OU, the user (and the objects) are in place (created now, already there, or planned under -WhatIf); 1 a precondition or a
    call failed (module missing, domain not reachable, a half-made preparation, the secret could not be read); 2 a value in the file is missing
    or not usable (no domain, an OU that is not in the domain, a user name Microsoft does not allow, no password reference).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER Credential
    Optional. The account that creates the objects. Without it the account that runs the script is used.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Set-ADConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created, and creates nothing.

.EXAMPLE
    ./Set-ADConfiguration.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the OU and the LCM user. Run it again: both are reported as AlreadyExists.
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
# Escapes a value for an LDAP filter (RFC 4515).
function ConvertTo-LdapValue([string]$Value) {
    $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

if (([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.identity')).Trim().ToLowerInvariant() -eq 'local_identity') {
    Write-Line 'scenario.identity is local_identity: the instance has no Active Directory, so there is nothing to prepare.'
    exit 0
}
$directory = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory'
$domain = ([string](Get-Field $directory 'domain_fqdn' '')).Trim()
$ouPath = ([string](Get-Field $directory 'ou_path' '')).Trim()
$lcm = Get-Field $directory 'lcm_user'
$lcmName = ([string](Get-Field $lcm 'username' '')).Trim()
$lcmReference = ([string](Get-Field $lcm 'password' '')).Trim()
$precreate = [string](Get-Field $directory 'precreate_computer_objects' 'false')

if (-not $domain) { Exit-InputProblem 'identity.active_directory.domain_fqdn is missing. It is the domain that is prepared.' }
if (-not $ouPath) { Exit-InputProblem 'identity.active_directory.ou_path is missing. It is the distinguished name of the dedicated OU.' }
if ($ouPath -notmatch '^OU=') { Exit-InputProblem "identity.active_directory.ou_path '$ouPath' is not the distinguished name of an OU (it has to start with OU=)." }
if ($ouPath -match '[&"''<>]') { Exit-InputProblem "identity.active_directory.ou_path '$ouPath' has a character Microsoft does not support in the path: & `" ' < >." }
$expectedSuffix = (@($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ',')
if (-not $ouPath.EndsWith($expectedSuffix, [StringComparison]::OrdinalIgnoreCase)) { Exit-InputProblem "identity.active_directory.ou_path '$ouPath' is not in the domain $domain (it has to end with $expectedSuffix)." }
if (-not $lcmName) { Exit-InputProblem 'identity.active_directory.lcm_user.username is missing. It is the deployment user the preparation creates.' }
# Microsoft Learn: 1 to 20 characters, letters, numbers, hyphens and underscores, not starting with a hyphen or a number; not "admin"; no domain.
if ($lcmName -notmatch '^[A-Za-z_][A-Za-z0-9_-]{0,19}$') { Exit-InputProblem "identity.active_directory.lcm_user.username '$lcmName' is not allowed: 1 to 20 letters, numbers, hyphens and underscores, not starting with a hyphen or a number, and no domain name." }
if ($lcmName -ieq 'admin') { Exit-InputProblem "identity.active_directory.lcm_user.username can't be 'admin'." }
if (-not $lcmReference) { Exit-InputProblem 'identity.active_directory.lcm_user.password is missing. It is the secret reference of the deployment user''s password.' }
if ($precreate.Trim().ToLowerInvariant() -notin 'true', 'false') { Exit-InputProblem "identity.active_directory.precreate_computer_objects '$precreate' is not true or false." }
$precreateObjects = $precreate.Trim().ToLowerInvariant() -eq 'true'

$objectNames = [System.Collections.Generic.List[object]]::new()
if ($precreateObjects) {
    $clusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
    if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing. It is the name of the cluster object that is pre-created.' }
    $rawNodes = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'nodes'
    $nodeNames = @(@($rawNodes) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { ([string](Get-Field $_ 'name' '')).Trim() } | Where-Object { $_ })
    if ($nodeNames.Count -eq 0) { Exit-InputProblem 'nodes[].name is empty. The machines whose objects are pre-created are listed there.' }
    foreach ($n in $nodeNames) { $objectNames.Add([pscustomobject]@{ Name = $n; Kind = 'machine'; Enabled = $true }) }
    $objectNames.Add([pscustomobject]@{ Name = $clusterName; Kind = 'cluster'; Enabled = $false })
}

# ---- preconditions (read only)
$needed = @('Get-ADOrganizationalUnit', 'Get-ADUser', 'New-HciAdObjectsPreCreation')
if ($precreateObjects) { $needed += 'Get-ADComputer', 'New-ADComputer' }
foreach ($cmd in $needed) {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
        $hint = if ($cmd -eq 'New-HciAdObjectsPreCreation') { 'Install the module: Install-Module AsHciADArtifactsPreCreationTool -Repository PSGallery.' } else { 'Install the ActiveDirectory module (Remote Server Administration Tools) or run the script on a domain controller.' }
        Exit-Failed "$cmd was not found. $hint"
    }
}
$adCommon = @{ Server = $domain; ErrorAction = 'Stop' }
if ($Credential) { $adCommon.Credential = $Credential }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([string]$Item, [string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $Item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed]  ' } 'AlreadyExists' { '[exists]  ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[created] ' } }
    Write-Line ("{0}{1}{2}" -f $tag, $Item, $(if ($Detail) { " ($Detail)" } else { '' }))
}

# ---- the OU and the LCM user
$ouFilter = "DistinguishedName -eq '$($ouPath.Replace("'", "''"))'"
$userFilter = "SamAccountName -eq '$lcmName'"
try {
    $ouExists = [bool](Get-ADOrganizationalUnit -Filter $ouFilter @adCommon)
    $userExists = [bool](Get-ADUser -Filter $userFilter @adCommon)
}
catch { Exit-Failed "The domain $domain could not be read: $($_.Exception.Message)" }

if ($ouExists -and $userExists) {
    Add-Row "OU $ouPath" 'AlreadyExists'
    Add-Row "LCM user $lcmName" 'AlreadyExists'
}
elseif ($ouExists -or $userExists) {
    $what = if ($ouExists) { "The OU '$ouPath' exists and the user '$lcmName' does not" } else { "The user '$lcmName' exists and the OU '$ouPath' does not" }
    Add-Row "OU $ouPath / LCM user $lcmName" 'Failed' "$what. New-HciAdObjectsPreCreation creates both, so the script stops: finish or undo the earlier preparation by hand, then run it again."
}
elseif ($PSCmdlet.ShouldProcess("domain $domain", "Create the OU '$ouPath' and the LCM user '$lcmName' (New-HciAdObjectsPreCreation)")) {
    $secure = $null
    try { $secure = Get-AzlSecretValue -Reference $lcmReference -Infrastructure $infra }
    catch {
        $code = if ($_.Exception.Data.Contains('AzlExit')) { [int]$_.Exception.Data['AzlExit'] } else { 1 }
        if ($code -eq 2) { Exit-InputProblem "identity.active_directory.lcm_user.password: $($_.Exception.Message)" }
        Exit-Failed "The password of the LCM user could not be read: $($_.Exception.Message)"
    }
    try {
        $lcmCredential = [pscredential]::new($lcmName, $secure)
        New-HciAdObjectsPreCreation -AzureStackLCMUserCredential $lcmCredential -AsHciOUName $ouPath
        Add-Row "OU $ouPath" 'Created'
        Add-Row "LCM user $lcmName" 'Created'
    }
    catch { Add-Row "OU $ouPath / LCM user $lcmName" 'Failed' $_.Exception.Message }
}
else {
    Add-Row "OU $ouPath" 'WouldCreate'
    Add-Row "LCM user $lcmName" 'WouldCreate'
}

# ---- the computer objects, when the file asks for them
$ready = @($rows | Where-Object Action -EQ 'Failed').Count -eq 0
foreach ($object in $objectNames) {
    $item = "computer $($object.Name) ($($object.Kind))"
    if (-not $ready) { Add-Row $item 'Skipped' 'the OU or the user is not in place'; continue }
    try {
        if (Get-ADComputer -Filter "Name -eq '$(ConvertTo-LdapValue $object.Name)'" @adCommon) { Add-Row $item 'AlreadyExists'; continue }
        if ($PSCmdlet.ShouldProcess("OU $ouPath", "Create the computer object '$($object.Name)' (enabled: $($object.Enabled))")) {
            New-ADComputer -Name $object.Name -Path $ouPath -Enabled $object.Enabled @adCommon
            Add-Row $item 'Created'
        }
        else { Add-Row $item 'WouldCreate' }
    }
    catch { Add-Row $item 'Failed' $_.Exception.Message }
}

$failed = @($rows | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $(@($rows | Where-Object Action -EQ 'Created').Count) created, $(@($rows | Where-Object Action -EQ 'AlreadyExists').Count) already existed, $(@($rows | Where-Object Action -Like 'Would*').Count) planned, $failed failed."
$rows
if ($failed -gt 0) { exit 1 }
exit 0
