<#
.SYNOPSIS
    Creates the NAT gateway that landing_zone.connectivity.nat_gateway of infrastructure.yml describes, and puts the listed subnets behind it, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 07 (NAT gateway), Azure CLI variant of New-NatGateway.ps1. It does the same
    with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. It creates a Standard public IP address
    (<gateway name>-pip), the NAT gateway with the TCP idle timeout of the file (Azure default when the file gives none), and then attaches the
    gateway to each subnet of landing_zone.connectivity.nat_gateway.subnets in the virtual network the entry names. It does not create the
    virtual network or its subnets (Deploy-VirtualNetworks.ps1 or Deploy-VirtualNetworks.azcli.ps1 does).

    Idempotent, and additive. A NAT gateway that exists is reported as AlreadyExists and left alone (a different idle timeout is reported, not
    changed). A subnet that already uses a NAT gateway is reported and left alone, even when it is another one: moving a subnet to another gateway
    interrupts its outbound traffic. An existing public IP address named <gateway name>-pip is reused. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with "az network public-ip create", "az network nat gateway create" and
    "az network vnet subnet update", behind -WhatIf. It does not sign in: run "az login --tenant <azure.tenant_id>" first. You need Network
    Contributor (or Contributor) on the resource group and on the virtual network. Every az call names its subscription, so the subscription of
    the az session is not changed. The tags in the file-level tags map are put on what it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.connectivity.nat_gateway.name, .resource_group, .network, .subnets, .idle_timeout_minutes
        landing_zone.networks[].name, .subscription, .resource_group, .location     where the network is
        landing_zone.subscriptions[].name, .id                                      the subscription that holds the network

    Exit codes: 0 the gateway exists and the listed subnets use it (created now, already there, or planned under -WhatIf), or the file has no NAT
    gateway; 1 an az call failed or a precondition failed (az missing, not signed in, wrong tenant, the network is missing, a subnet is missing, a
    creation failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-NatGateway.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created and which subnets would be attached, and changes nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-NatGateway.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the gateway and attaches the subnets. Run it again: the gateway is AlreadyExists and the subnets are reported as in place.
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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'ResourceNotFound|NotFound|could not be found|was not found|does not exist|\b404\b'

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
$nat = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.nat_gateway'
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networks = @(@($rawNetworks) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptions = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($nat -isnot [System.Collections.IDictionary]) {
    Write-Line 'The file has no landing_zone.connectivity.nat_gateway: nothing to do.'
    exit 0
}

$gatewayName = Get-Entry $nat 'name'
$networkName = Get-Entry $nat 'network'
if (-not $gatewayName) { Exit-InputProblem 'landing_zone.connectivity.nat_gateway.name is missing.' }
if ($gatewayName -notmatch '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$') { Exit-InputProblem "landing_zone.connectivity.nat_gateway.name '$gatewayName' is not a valid name (1 to 80 letters, digits, . _ -; starts with a letter or digit)." }
if (-not $networkName) { Exit-InputProblem 'landing_zone.connectivity.nat_gateway.network is missing. Name the virtual network (an entry of landing_zone.networks) whose subnets use the gateway.' }
$rawSubnets = if ($nat.Contains('subnets')) { $nat['subnets'] } else { $null }
$subnetNames = @(@($rawSubnets) | Where-Object { $null -ne $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() })
if ($subnetNames.Count -eq 0) { Exit-InputProblem 'landing_zone.connectivity.nat_gateway.subnets is empty. List the subnets of the network that use the gateway.' }
$timeoutText = Get-Entry $nat 'idle_timeout_minutes'
$timeout = 0
if ($timeoutText -and (-not [int]::TryParse($timeoutText, [ref]$timeout) -or $timeout -lt 4 -or $timeout -gt 120)) { Exit-InputProblem "landing_zone.connectivity.nat_gateway.idle_timeout_minutes '$timeoutText' is not a number from 4 to 120." }

$network = @($networks | Where-Object { (Get-Entry $_ 'name') -eq $networkName }) | Select-Object -First 1
if (-not $network) { Exit-InputProblem "The network '$networkName' is not an entry of landing_zone.networks, so the subscription and resource group are not known." }
$subscriptionName = Get-Entry $network 'subscription'
$subscription = @($subscriptions | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
$subscriptionId = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
if (-not $subscriptionName) { Exit-InputProblem "The network '$networkName' has no subscription in landing_zone.networks." }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "The subscription '$subscriptionName' of the network '$networkName' has no usable id in landing_zone.subscriptions." }
$networkGroup = Get-Entry $network 'resource_group'
$group = if (Get-Entry $nat 'resource_group') { Get-Entry $nat 'resource_group' } else { $networkGroup }
if (-not $networkGroup) { Exit-InputProblem "The network '$networkName' has no resource_group in landing_zone.networks." }
$location = if (Get-Entry $network 'location') { Get-Entry $network 'location' } else { $defaultLocation }
if (-not $location) { Exit-InputProblem "No region: the network '$networkName' has no location and azure.location is empty." }
$publicIpName = "$gatewayName-pip"

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-NatGateway.ps1.' }
try { $account = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($account -ne $tenantId) { Exit-Failed "Signed in to tenant $account, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$rows = [System.Collections.Generic.List[object]]::new()
try {
    Write-Line "NAT gateway '$gatewayName' in '$group' ($location), subnets of '$networkName': $($subnetNames -join ', ')"

    $vnet = $null
    try { $vnet = Get-AzCliResource network vnet show --name $networkName --resource-group $networkGroup --subscription $subscriptionId }
    catch { Exit-Failed "The virtual network '$networkName' could not be read: $($_.Exception.Message)" }
    if (-not $vnet) { Exit-Failed "The virtual network '$networkName' does not exist in '$networkGroup'. Create it first (Deploy-VirtualNetworks.ps1)." }
    $vnetSubnets = @(Get-JsonValue $vnet 'subnets')
    foreach ($name in $subnetNames) {
        if (-not ($vnetSubnets | Where-Object { $_ -and $_.name -eq $name })) { Exit-Failed "The virtual network '$networkName' has no subnet named '$name'. Add it to landing_zone.networks and run Deploy-VirtualNetworks.ps1." }
    }

    # ---- the gateway
    $row = [ordered]@{ Resource = $gatewayName; Kind = 'NatGateway'; Action = ''; Detail = '' }
    $existing = $null
    try { $existing = Get-AzCliResource network nat gateway show --name $gatewayName --resource-group $group --subscription $subscriptionId }
    catch { Exit-Failed "The NAT gateway '$gatewayName' could not be read: $($_.Exception.Message)" }
    $natGatewayId = ''
    if ($existing) {
        $natGatewayId = [string](Get-JsonValue $existing 'id')
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  The NAT gateway '$gatewayName' is already there, nothing changed."
        $currentTimeout = [int](Get-JsonValue $existing 'idleTimeoutInMinutes')
        if ($timeout -and $currentTimeout -and $currentTimeout -ne $timeout) {
            $row.Detail = "Differs from the file (the idle timeout is $currentTimeout minutes, the file says $timeout); left unchanged."
            Write-Warning "${gatewayName}: $($row.Detail)"
        }
    }
    else {
        $pip = $null
        try { $pip = Get-AzCliResource network public-ip show --name $publicIpName --resource-group $group --subscription $subscriptionId }
        catch { Exit-Failed "The public IP address '$publicIpName' could not be read: $($_.Exception.Message)" }
        if (-not $pip -and $PSCmdlet.ShouldProcess("public IP address '$publicIpName' in '$group'", 'Create a Standard, static public IP address')) {
            $pipArgs = @('network', 'public-ip', 'create', '--name', $publicIpName, '--resource-group', $group, '--location', $location, '--subscription', $subscriptionId, '--sku', 'Standard', '--allocation-method', 'Static')
            $pipArgs += @(Get-TagArgument)
            $null = Invoke-AzJson @pipArgs
            Write-Line "[created] Public IP address '$publicIpName'."
        }
        elseif (-not $pip) { Write-Line "[plan]    Public IP address '$publicIpName' would be created." }
        else { Write-Line "[exists]  Public IP address '$publicIpName' is reused." }

        if ($PSCmdlet.ShouldProcess("NAT gateway '$gatewayName' in '$group'", 'Create (Standard)')) {
            $natArgs = @('network', 'nat', 'gateway', 'create', '--name', $gatewayName, '--resource-group', $group, '--location', $location, '--subscription', $subscriptionId, '--public-ip-addresses', $publicIpName)
            if ($timeout) { $natArgs += '--idle-timeout'; $natArgs += [string]$timeout }
            $natArgs += @(Get-TagArgument)
            $created = Invoke-AzJson @natArgs
            $natGatewayId = [string](Get-JsonValue $created 'id')
            if (-not $natGatewayId) { throw 'az created the NAT gateway but returned no resource id.' }
            $row.Action = 'Created'
            Write-Line "[created] The NAT gateway '$gatewayName'."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    The NAT gateway '$gatewayName' would be created."
        }
    }
    $rows.Add([pscustomobject]$row)

    # ---- the subnets: one update for each subnet that does not use a NAT gateway yet
    foreach ($name in $subnetNames) {
        $subnetRow = [ordered]@{ Resource = $name; Kind = 'Subnet'; Action = ''; Detail = '' }
        $subnet = @($vnetSubnets | Where-Object { $_ -and $_.name -eq $name }) | Select-Object -First 1
        $current = [string](Get-JsonValue $subnet 'natGateway.id')
        if ($current) {
            $subnetRow.Action = 'AlreadyAttached'
            $isOurs = $current -like "*/natGateways/$gatewayName"
            if (-not $isOurs) { $subnetRow.Detail = "The subnet uses another NAT gateway ($current); left unchanged."; Write-Warning "${name}: $($subnetRow.Detail)" }
            else { Write-Line "[exists]  Subnet '$name' already uses '$gatewayName'." }
        }
        elseif ($natGatewayId -and $PSCmdlet.ShouldProcess("subnet '$name' of '$networkName'", "Attach NAT gateway '$gatewayName'")) {
            $null = Invoke-AzJson network vnet subnet update --name $name --vnet-name $networkName --resource-group $networkGroup --subscription $subscriptionId --nat-gateway $natGatewayId
            $subnetRow.Action = 'Attached'
            Write-Line "[attached] Subnet '$name' now uses '$gatewayName'."
        }
        else {
            $subnetRow.Action = 'WouldAttach'
            Write-Line "[plan]    Subnet '$name' would use '$gatewayName'."
        }
        $rows.Add([pscustomobject]$subnetRow)
    }
}
catch {
    Exit-Failed "The NAT gateway '$gatewayName' was not completed: $($_.Exception.Message)"
}

$rows
exit 0
