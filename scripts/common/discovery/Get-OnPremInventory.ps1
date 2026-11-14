<#
.SYNOPSIS
    Read-only inventory of the computer objects in the Active Directory OU of the Azure Local instance.

.DESCRIPTION
    Lists every computer object in identity.active_directory.ou_path of infrastructure.yml (the dedicated OU that Microsoft's
    Active Directory preparation creates for the machines and the cluster), with its operating system, address, state and last
    logon, and marks the failover cluster name objects (a service principal name MSClusterVirtualServer/...). Use it before a
    deployment to see what the OU already holds, and after one as a record.

    Read only: nothing in Active Directory is changed. The query runs as the signed-in user, or as -Credential when given (a
    domain user can read computer objects). It asks for nothing. It needs the ActiveDirectory module (RSAT).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        scenario.identity
        identity.active_directory.domain_fqdn, ou_path, domain_controllers (the first one is queried; without them, the domain)

    Exit codes: 0 the inventory is done (or scenario.identity is local_identity: there is no domain, nothing to do); 1 the
    ActiveDirectory module is missing or the query failed; 2 a value in the file is missing or not usable, or the file cannot be
    read (nothing is queried).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER Credential
    Optional. The account for the query. Without it the signed-in user queries the domain.

.PARAMETER OutputPath
    Optional. Also write the inventory as JSON to this file. Keep it out of the repository.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.OUTPUTS
    One object per computer object: Name, DnsHostName, Kind (Computer or ClusterName), OperatingSystem, OperatingSystemVersion,
    IPv4Address, Enabled, LastLogonDate, DistinguishedName.

.EXAMPLE
    ./Get-OnPremInventory.ps1 -InfrastructureFile ./infrastructure.yml

    Lists the computer objects in the OU of the file, for example OU=AzureLocal,DC=iic,DC=improbability,DC=cloud.

.EXAMPLE
    ./Get-OnPremInventory.ps1 -InfrastructureFile ./infrastructure.yml -Credential $readerCredential -OutputPath ./out/ad-inventory.json

    Queries as another account and also writes the JSON file.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [string]$OutputPath,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-AdProperty([object]$Object, [string]$Name) {
    # A property of an AD object, or $null when the object does not carry it.
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$identity = Get-Text 'scenario.identity'
if ($identity -eq 'local_identity') {
    Write-Line 'scenario.identity is local_identity: the instance joins no domain, there is no OU to inventory. Nothing to do.'
    exit 0
}
if ($identity -ne 'active_directory') { Exit-InputProblem "scenario.identity is '$identity'. Set it to active_directory (with identity.active_directory) or local_identity." }

$domain = Get-Text 'identity.active_directory.domain_fqdn'
$ou = Get-Text 'identity.active_directory.ou_path'
if ($domain -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { Exit-InputProblem "identity.active_directory.domain_fqdn '$domain' is missing or not a domain name. Set it to the FQDN of the Active Directory domain." }
if ($ou -notmatch '^[Oo][Uu]=.+,[Dd][Cc]=.+$') { Exit-InputProblem "identity.active_directory.ou_path '$ou' is missing or not an OU distinguished name (OU=...,DC=...). Set it to the OU of the instance." }
$controllerList = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.domain_controllers'
$controllers = @(foreach ($c in @($controllerList)) { if ($c) { ([string]$c).Trim() } })
$server = if ($controllers.Count) { $controllers[0] } else { $domain }

# ---- preconditions
if (-not (Get-Command -Name 'Get-ADComputer' -ErrorAction SilentlyContinue)) {
    Exit-Failed 'Get-ADComputer was not found. Install the ActiveDirectory module (RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0, or Install-WindowsFeature RSAT-AD-PowerShell on a server).'
}

# ---- the query (read only)
Write-Line "Computer objects in $ou ($domain, queried at $server)"
$arguments = @{
    Filter      = '*'
    SearchBase  = $ou
    Server      = $server
    Properties  = @('DNSHostName', 'OperatingSystem', 'OperatingSystemVersion', 'IPv4Address', 'Enabled', 'LastLogonDate', 'ServicePrincipalName')
    ErrorAction = 'Stop'
}
if ($Credential) { $arguments.Credential = $Credential }
try { $computers = @(Get-ADComputer @arguments) }
catch { Exit-Failed "The query of $ou at $server failed: $($_.Exception.Message)" }

$rows = foreach ($computer in ($computers | Sort-Object { [string](Get-AdProperty $_ 'Name') })) {
    $spn = @(Get-AdProperty $computer 'ServicePrincipalName')
    $kind = if (@($spn | Where-Object { [string]$_ -like 'MSClusterVirtualServer/*' }).Count) { 'ClusterName' } else { 'Computer' }
    $lastLogon = Get-AdProperty $computer 'LastLogonDate'
    [pscustomobject]@{
        Name                   = [string](Get-AdProperty $computer 'Name')
        DnsHostName            = [string](Get-AdProperty $computer 'DNSHostName')
        Kind                   = $kind
        OperatingSystem        = [string](Get-AdProperty $computer 'OperatingSystem')
        OperatingSystemVersion = [string](Get-AdProperty $computer 'OperatingSystemVersion')
        IPv4Address            = [string](Get-AdProperty $computer 'IPv4Address')
        Enabled                = [bool](Get-AdProperty $computer 'Enabled')
        LastLogonDate          = if ($lastLogon) { ([datetime]$lastLogon).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        DistinguishedName      = [string](Get-AdProperty $computer 'DistinguishedName')
    }
}
$rows = @($rows)
Write-Line "Found $(@($rows | Where-Object Kind -EQ 'Computer').Count) computer object(s) and $(@($rows | Where-Object Kind -EQ 'ClusterName').Count) cluster name object(s)."

if ($OutputPath) {
    $document = [ordered]@{
        Domain        = $domain
        OuPath        = $ou
        Server        = $server
        DiscoveryDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
        Computers     = @($rows | Where-Object Kind -EQ 'Computer')
        Clusters      = @($rows | Where-Object Kind -EQ 'ClusterName')
    }
    try {
        $folder = Split-Path -Parent $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        $document | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
        Write-Line "Written: $OutputPath"
    }
    catch { Exit-Failed "The inventory could not be written to ${OutputPath}: $($_.Exception.Message)" }
}

$rows
exit 0
