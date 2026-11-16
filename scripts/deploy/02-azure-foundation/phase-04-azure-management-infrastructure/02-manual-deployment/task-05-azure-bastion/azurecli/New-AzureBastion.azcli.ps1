<#
.SYNOPSIS
    Creates the Azure Bastion host of the hub that infrastructure.yml describes, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 05 (Azure Bastion), Azure CLI variant of New-AzureBastion.ps1. It does the
    same with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. It creates the Standard, static, zone-redundant
    public IP address and the Bastion host named by landing_zone.connectivity.bastion, in the AzureBastionSubnet of the virtual network it names,
    with the SKU of the file. It does not create the virtual network or the subnet (Deploy-VirtualNetworks.ps1 does: list a subnet named
    AzureBastionSubnet of /26 or larger in landing_zone.networks).

    The Bastion features other than the SKU (copy and paste, file copy, IP-based connection, native client, shareable links) and the number of
    scale units are the Azure defaults: change them in the portal when you need them.

    Idempotent. A Bastion host that exists is reported as AlreadyExists and left alone (a different SKU is reported, not changed: Microsoft Learn
    upgrades a SKU in the portal). An existing public IP address named <host name>-pip is reused. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with "az network public-ip create" and "az network bastion create", behind -WhatIf. It
    does not sign in: run "az login --tenant <azure.tenant_id>" first. You need Network Contributor (or Contributor) on the resource group, and
    read access to the virtual network. Every az call names its subscription, so the subscription of the az session is not changed. The tags
    in the file-level tags map are put on what it creates. A Bastion host takes about 10 minutes to create and is billed by the hour from then on.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.connectivity.bastion.name, .resource_group, .sku, .network     the host, its group, its SKU and its virtual network
        landing_zone.networks[].name, .subscription, .resource_group, .location    where the network is
        landing_zone.subscriptions[].name, .id                                     the subscription that holds the network

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 the host exists (created now, already there, or planned under -WhatIf), or the file has no Bastion host; 1 an az call failed or
    a precondition failed (az missing, not signed in, wrong tenant, the network or its AzureBastionSubnet is missing or smaller than /26, the
    creation failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-AzureBastion.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-AzureBastion.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the public IP address and the Bastion host. Run it again: the host is reported as AlreadyExists.
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
$NotFound = 'ResourceNotFound|NotFound|could not be found|was not found|does not exist|\b404\b'
# What Microsoft fixes (Microsoft Learn: About Azure Bastion): the SKUs, the name of the subnet (case sensitive) and its smallest size.
$AllowedSku = 'Basic', 'Standard', 'Premium'
$BastionSubnetName = 'AzureBastionSubnet'
$BastionSubnetMaxPrefixLength = 26

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# One az call. Returns the text of standard output (warnings on standard error are dropped); throws with the error text when az fails.
function Invoke-Az {
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $args
    if ($unsafe) { Exit-InputProblem $unsafe }
    $out = @(& az @args 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ').Trim() }
    (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}
# One az call with JSON output, parsed; $null when az printed nothing.
function Invoke-AzJson {
    $text = Invoke-Az @args '--output' 'json'
    if ($text) { $text | ConvertFrom-Json }
}
# The same, for a resource that may not be there: $null when az says it was not found; any other error is thrown.
function Get-AzCliResource {
    try { Invoke-AzJson @args }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
}
# The value at a dotted path of a parsed JSON object; $null when a part is missing.
function Get-JsonValue([object]$Object, [string]$Path) {
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current -or $current -is [string] -or -not $current.PSObject.Properties[$part]) { return $null }
        $current = $current.$part
    }
    $current
}
# The --tags arguments of az, from the file-level tags map; nothing when there are none.
function Get-TagArgument { if ($tags.Count) { '--tags'; @($tags.Keys | Sort-Object | ForEach-Object { "$_=$($tags[$_])" }) } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$defaultLocation = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$bastion = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.bastion'
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networks = @(@($rawNetworks) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawNetworks)) { Exit-InputProblem 'An entry of landing_zone.networks is not a map (names with their settings).' } })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptions = @(@($rawSubscriptions) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawSubscriptions)) { Exit-InputProblem 'An entry of landing_zone.subscriptions is not a map (names with their settings).' } })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
# The tags go into az arguments: refuse a key or a value that az.cmd cannot carry before any Azure call (also under -WhatIf).
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $rawTags })
if ($problem) { Exit-InputProblem $problem }
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($bastion -isnot [System.Collections.IDictionary]) {
    Write-Line 'The file has no landing_zone.connectivity.bastion: nothing to do.'
    exit 0
}

$bastionName = Get-Entry $bastion 'name'
$networkName = Get-Entry $bastion 'network'
$sku = Get-Entry $bastion 'sku'
if (-not $bastionName) { Exit-InputProblem 'landing_zone.connectivity.bastion.name is missing.' }
if ($bastionName -notmatch '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$') { Exit-InputProblem "landing_zone.connectivity.bastion.name '$bastionName' is not a valid name (1 to 80 letters, digits, . _ -; starts with a letter or digit)." }
if (-not $networkName) { Exit-InputProblem "landing_zone.connectivity.bastion.network is missing. Name the virtual network (an entry of landing_zone.networks) whose $BastionSubnetName holds the host." }
if ($AllowedSku -notcontains $sku) { Exit-InputProblem "landing_zone.connectivity.bastion.sku '$sku' is missing or not allowed. Use one of: $($AllowedSku -join ', ')." }

$network = @($networks | Where-Object { (Get-Entry $_ 'name') -eq $networkName }) | Select-Object -First 1
if (-not $network) { Exit-InputProblem "The network '$networkName' is not an entry of landing_zone.networks, so the subscription and resource group to deploy into are not known." }
$subscriptionName = Get-Entry $network 'subscription'
$subscription = @($subscriptions | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
$subscriptionId = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
if (-not $subscriptionName) { Exit-InputProblem "The network '$networkName' has no subscription in landing_zone.networks." }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "The subscription '$subscriptionName' of the network '$networkName' has no usable id in landing_zone.subscriptions." }
$networkGroup = Get-Entry $network 'resource_group'
$group = if (Get-Entry $bastion 'resource_group') { Get-Entry $bastion 'resource_group' } else { $networkGroup }
if (-not $networkGroup) { Exit-InputProblem "The network '$networkName' has no resource_group in landing_zone.networks." }
$location = if (Get-Entry $network 'location') { Get-Entry $network 'location' } else { $defaultLocation }
if (-not $location) { Exit-InputProblem "No region: the network '$networkName' has no location and azure.location is empty." }
$publicIpName = "$bastionName-pip"

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'landing_zone.connectivity.bastion.network' = $networkName; 'the resource group of the Bastion host' = $group; 'the resource group of the network' = $networkGroup; 'the location' = $location })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-AzureBastion.ps1.' }
try { $account = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($account -ne $tenantId) { Exit-Failed "Signed in to tenant $account, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

try {
    Write-Line "Bastion host '$bastionName' ($sku) in '$group', network '$networkName' ($location)"
    $row = [ordered]@{ Bastion = $bastionName; Action = ''; Sku = $sku; PublicIpName = $publicIpName; Detail = '' }

    $existing = $null
    try { $existing = Get-AzCliResource network bastion show --name $bastionName --resource-group $group --subscription $subscriptionId }
    catch { Exit-Failed "The Bastion host '$bastionName' could not be read: $($_.Exception.Message)" }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        $existingSku = [string](Get-JsonValue $existing 'sku.name')
        Write-Line "[exists]  The Bastion host '$bastionName' is already there, nothing changed."
        if ($existingSku -and $existingSku -ne $sku) {
            $row.Detail = "Differs from the file (the SKU is $existingSku, the file says $sku); left unchanged."
            Write-Warning "${bastionName}: $($row.Detail)"
        }
    }
    else {
        $vnet = $null
        try { $vnet = Get-AzCliResource network vnet show --name $networkName --resource-group $networkGroup --subscription $subscriptionId }
        catch { Exit-Failed "The virtual network '$networkName' could not be read: $($_.Exception.Message)" }
        if (-not $vnet) { Exit-Failed "The virtual network '$networkName' does not exist in '$networkGroup'. Create it first (Deploy-VirtualNetworks.ps1)." }
        $subnet = @(Get-JsonValue $vnet 'subnets') | Where-Object { $_ -and $_.name -ceq $BastionSubnetName } | Select-Object -First 1
        if (-not $subnet) { Exit-Failed "The virtual network '$networkName' has no subnet named $BastionSubnetName (the name is case sensitive). Add it (/$BastionSubnetMaxPrefixLength or larger) to landing_zone.networks and run Deploy-VirtualNetworks.ps1." }
        $prefix = [string](@(Get-JsonValue $subnet 'addressPrefix'; @(Get-JsonValue $subnet 'addressPrefixes')) | Where-Object { $_ } | Select-Object -First 1)
        if ($prefix -notmatch '/(\d+)$' -or [int]$Matches[1] -gt $BastionSubnetMaxPrefixLength) { Exit-Failed "$BastionSubnetName is '$prefix'. Azure Bastion needs /$BastionSubnetMaxPrefixLength or larger." }

        $pip = $null
        try { $pip = Get-AzCliResource network public-ip show --name $publicIpName --resource-group $group --subscription $subscriptionId }
        catch { Exit-Failed "The public IP address '$publicIpName' could not be read: $($_.Exception.Message)" }
        # No --zone is given: a Standard public IP address without zones is zone-redundant in a region that has availability zones and
        # regional in one that does not (Microsoft Learn: Public IP addresses), and a Bastion host deployed without zones takes any public
        # IP address, zonal or not (Microsoft Learn: Bastion configuration settings), so the same call works in every region.
        if (-not $pip -and $PSCmdlet.ShouldProcess("public IP address '$publicIpName' in '$group'", 'Create a Standard, static public IP address (zone-redundant where the region has zones)')) {
            $pipArgs = @('network', 'public-ip', 'create', '--name', $publicIpName, '--resource-group', $group, '--location', $location, '--subscription', $subscriptionId, '--sku', 'Standard', '--allocation-method', 'Static')
            $pipArgs += @(Get-TagArgument)
            $null = Invoke-AzJson @pipArgs
            Write-Line "[created] Public IP address '$publicIpName'."
        }
        elseif (-not $pip) { Write-Line "[plan]    Public IP address '$publicIpName' would be created." }
        else { Write-Line "[exists]  Public IP address '$publicIpName' is reused." }

        if ($PSCmdlet.ShouldProcess("Bastion host '$bastionName' in '$group'", "Create the host ($sku); this takes about 10 minutes")) {
            Write-Line 'Creating the Bastion host; this takes about 10 minutes.'
            $bastionArgs = @('network', 'bastion', 'create', '--name', $bastionName, '--resource-group', $group, '--location', $location, '--subscription', $subscriptionId, '--vnet-name', [string](Get-JsonValue $vnet 'id'), '--public-ip-address', $publicIpName, '--sku', $sku)
            $bastionArgs += @(Get-TagArgument)
            $null = Invoke-AzJson @bastionArgs
            $row.Action = 'Created'
            Write-Line "[created] The Bastion host '$bastionName' ($sku)."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    The Bastion host '$bastionName' would be created ($sku)."
        }
    }
    [pscustomobject]$row
}
catch {
    Exit-Failed "The Bastion host '$bastionName' was not created: $($_.Exception.Message)"
}
exit 0
