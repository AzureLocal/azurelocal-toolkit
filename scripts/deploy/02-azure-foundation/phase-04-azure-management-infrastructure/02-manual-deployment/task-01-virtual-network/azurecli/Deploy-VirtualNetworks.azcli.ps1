<#
.SYNOPSIS
    Creates the virtual networks of the landing zone, their subnets and their peerings, from infrastructure.yml, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 01 (virtual network), Azure CLI variant of Deploy-VirtualNetworks.ps1. It
    does the same with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. For each entry of landing_zone.networks
    this script creates the virtual network with its address space, DNS servers and subnets, in the subscription and resource group the entry
    names, and then peers the networks that list each other in peer_with (a peering is made in both directions, once both networks exist).

    Idempotent, and additive. A network that already exists is not recreated and nothing is removed from it: a subnet the file lists and the
    network lacks is added; a network security group or route table the file names for a subnet that has none is attached once that resource
    exists. Everything else that differs (the address space, the DNS servers, a subnet range, a different security group on a subnet) is
    reported as a difference and left as it is, because changing it can interrupt traffic. A peering that exists is left alone. -WhatIf
    changes nothing.

    A subnet's network_security_group and route_table are names of resources in the same resource group as the network. If the resource does
    not exist yet the subnet is created without it and the script says so. Run task 06 (New-LandingZoneNsg.ps1 or New-LandingZoneNsg.azcli.ps1,
    which creates the groups of landing_zone.network_security_groups) before this script; if you did not, run this script again
    after the security groups exist and it attaches them. A peering is made with virtual network access allowed and with the options of the
    network it starts in: allow_forwarded_traffic (default true), allow_gateway_transit (default false) and use_remote_gateways (default
    false). A hub that has the VPN gateway sets allow_gateway_transit; the spokes that use it set use_remote_gateways, and the gateway must
    exist before a peering that uses it is created (the VPN gateway task, task 02).

    The script reads Azure (read only) and writes only with "az network vnet create", "az network vnet subnet create", "az network vnet subnet
    update" and "az network vnet peering create", behind -WhatIf. It does not sign in: run "az login --tenant <azure.tenant_id>" first. You
    need Network Contributor (or Contributor) on each resource group, and, for a peering to a network in another subscription, on that network
    as well. Every az call names its subscription, so the subscription of the az session is not changed. The tags in the file-level tags map are
    put on the networks it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.subscriptions[].name, .id                                 the subscription of each network
        landing_zone.networks[].name, .subscription, .resource_group, .location, .address_space, .dns_servers, .peer_with,
                                                                               .allow_forwarded_traffic, .allow_gateway_transit, .use_remote_gateways
        landing_zone.networks[].subnets[].name, .prefix, .network_security_group, .route_table

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every network and peering is in place (created now, already there, planned under -WhatIf, or reported as different and left
    alone); 1 an az call failed, a precondition failed (az missing, not signed in, wrong tenant) or a network or peering could not
    be created; 2 the file lists no network, or a value is not usable (a name, an address range that is not CIDR or lies outside the address
    space, subnets that overlap, a peer that is not in the file).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-VirtualNetworks.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which networks, subnets and peerings would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Deploy-VirtualNetworks.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the networks and peers them. Run it again: every network is AlreadyExists and every peering is left alone.
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
$Ipv4 = '^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$'

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

function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# A true or false key of an entry: the default when the key is absent; $null when it holds anything else.
function Get-EntryFlag([object]$Entry, [string]$Key, [bool]$Default) {
    $text = Get-Entry $Entry $Key
    if (-not $text) { return $Default }
    if ($text -in 'true', 'false') { return ($text -eq 'true') }
    $null
}

function Get-EntryList([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) {
        return @(@($Entry[$Key]) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    }
    @()
}

# IPv4 CIDR as first address, last address and prefix length (as numbers); $null when it is not a CIDR.
function ConvertFrom-Cidr([string]$Cidr) {
    if ($Cidr -notmatch '^(?<ip>[^/]+)/(?<len>\d{1,2})$') { return $null }
    $ip = $Matches['ip']
    $length = [int]$Matches['len']
    if ($ip -notmatch $Ipv4 -or $length -gt 32) { return $null }
    $octet = $ip.Split('.') | ForEach-Object { [uint64]$_ }
    $address = $octet[0] * 16777216 + $octet[1] * 65536 + $octet[2] * 256 + $octet[3]
    $size = [uint64]1 -shl (32 - $length)
    $first = [uint64]([Math]::Floor($address / $size)) * $size
    [pscustomobject]@{ First = $first; Last = $first + $size - 1; Length = $length }
}

# One az call. Returns the text of standard output (warnings on standard error are dropped); throws with the error text when az fails.
function Invoke-Az {
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $args
    if ($unsafe) { Exit-InputProblem $unsafe }
    $out = @(& az @args 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ').Trim() }
    (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$defaultLocation = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networkEntries = @(@($rawNetworks) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawNetworks)) { Exit-InputProblem 'An entry of landing_zone.networks is not a map (names with their settings).' } })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptionEntries = @(@($rawSubscriptions) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawSubscriptions)) { Exit-InputProblem 'An entry of landing_zone.subscriptions is not a map (names with their settings).' } })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
# The tags go into az arguments: refuse a key or a value that az.cmd cannot carry before any Azure call (also under -WhatIf).
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ tags = $rawTags })
if ($problem) { Exit-InputProblem $problem }
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($networkEntries.Count -eq 0) { Exit-InputProblem 'landing_zone.networks is empty. List the virtual networks with their address space and subnets.' }

$plan = foreach ($entry in $networkEntries) {
    $name = Get-Entry $entry 'name'
    if (-not $name) { Exit-InputProblem 'An entry of landing_zone.networks has no name.' }
    if ($name -notmatch '^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9_])?$') { Exit-InputProblem "landing_zone.networks: '$name' is not a valid virtual network name (1 to 64 letters, digits, . _ -; starts with a letter or digit, ends with a letter, digit or underscore)." }
    $subscriptionName = Get-Entry $entry 'subscription'
    $subscription = @($subscriptionEntries | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
    $subscriptionId = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
    if (-not $subscriptionName) { Exit-InputProblem "landing_zone.networks '$name': no subscription." }
    if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "landing_zone.networks '$name': the subscription '$subscriptionName' has no usable id in landing_zone.subscriptions." }
    $group = Get-Entry $entry 'resource_group'
    if (-not $group) { Exit-InputProblem "landing_zone.networks '$name': no resource_group." }
    $location = if (Get-Entry $entry 'location') { Get-Entry $entry 'location' } else { $defaultLocation }
    if (-not $location) { Exit-InputProblem "landing_zone.networks '$name': no location, and azure.location is empty." }

    $space = @(Get-EntryList $entry 'address_space')
    if ($space.Count -eq 0) { Exit-InputProblem "landing_zone.networks '$name': address_space is empty." }
    $spaceRange = foreach ($cidr in $space) {
        $range = ConvertFrom-Cidr $cidr
        if (-not $range) { Exit-InputProblem "landing_zone.networks '$name': address_space '$cidr' is not an IPv4 range in CIDR form (for example 198.51.100.0/24)." }
        $range
    }
    $dns = @(Get-EntryList $entry 'dns_servers')
    foreach ($server in $dns) { if ($server -notmatch $Ipv4) { Exit-InputProblem "landing_zone.networks '$name': the DNS server '$server' is not an IPv4 address." } }

    $rawSubnets = if ($entry.Contains('subnets')) { $entry['subnets'] } else { $null }
    $subnets = @(@($rawSubnets) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawSubnets)) { Exit-InputProblem 'An entry of landing_zone.networks[].subnets is not a map (names with their settings).' } } | ForEach-Object {
            $subnetName = Get-Entry $_ 'name'
            if (-not $subnetName) { Exit-InputProblem "landing_zone.networks '$name': a subnet has no name." }
            $prefix = Get-Entry $_ 'prefix'
            $range = ConvertFrom-Cidr $prefix
            if (-not $range) { Exit-InputProblem "landing_zone.networks '$name': the subnet '$subnetName' has prefix '$prefix', which is not an IPv4 range in CIDR form." }
            if (-not @($spaceRange | Where-Object { $range.First -ge $_.First -and $range.Last -le $_.Last })) { Exit-InputProblem "landing_zone.networks '$name': the subnet '$subnetName' ($prefix) is outside the address space of the network." }
            [pscustomobject]@{ Name = $subnetName; Prefix = $prefix; Range = $range; Nsg = (Get-Entry $_ 'network_security_group'); RouteTable = (Get-Entry $_ 'route_table') }
        })
    $dupSubnet = @($subnets | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object Count -GT 1)
    if ($dupSubnet.Count) { Exit-InputProblem "landing_zone.networks '$name': the subnet '$($dupSubnet[0].Group[0].Name)' appears more than once." }
    for ($i = 0; $i -lt $subnets.Count; $i++) {
        for ($j = $i + 1; $j -lt $subnets.Count; $j++) {
            if ($subnets[$i].Range.First -le $subnets[$j].Range.Last -and $subnets[$j].Range.First -le $subnets[$i].Range.Last) {
                Exit-InputProblem "landing_zone.networks '$name': the subnets '$($subnets[$i].Name)' and '$($subnets[$j].Name)' overlap."
            }
        }
    }
    # The options of the peerings that start in this network (Microsoft Learn: Virtual network peering). The defaults are the registry's.
    $forwarded = Get-EntryFlag $entry 'allow_forwarded_traffic' $true
    $transit = Get-EntryFlag $entry 'allow_gateway_transit' $false
    $remoteGateways = Get-EntryFlag $entry 'use_remote_gateways' $false
    foreach ($flag in @(@('allow_forwarded_traffic', $forwarded), @('allow_gateway_transit', $transit), @('use_remote_gateways', $remoteGateways))) {
        if ($null -eq $flag[1]) { Exit-InputProblem "landing_zone.networks '$name': $($flag[0]) is '$(Get-Entry $entry $flag[0])'. It has to be true or false." }
    }
    if ($transit -and $remoteGateways) { Exit-InputProblem "landing_zone.networks '$name': allow_gateway_transit and use_remote_gateways cannot both be true on one network (a network either offers its gateway or uses a remote one)." }
    [pscustomobject]@{
        Name = $name; Subscription = $subscriptionName; SubscriptionId = $subscriptionId; ResourceGroup = $group; Location = $location
        AddressSpace = $space; DnsServers = $dns; Subnets = $subnets; PeerWith = @(Get-EntryList $entry 'peer_with')
        AllowForwardedTraffic = [bool]$forwarded; AllowGatewayTransit = [bool]$transit; UseRemoteGateways = [bool]$remoteGateways
    }
}
$plan = @($plan)
$dupNetwork = @($plan | Group-Object { "$($_.SubscriptionId)/$($_.ResourceGroup)/$($_.Name)".ToLowerInvariant() } | Where-Object Count -GT 1)
if ($dupNetwork.Count) { Exit-InputProblem "The network '$($dupNetwork[0].Group[0].Name)' appears more than once in landing_zone.networks." }
foreach ($network in $plan) {
    foreach ($peer in $network.PeerWith) {
        if ($peer -ieq $network.Name) { Exit-InputProblem "landing_zone.networks '$($network.Name)': peer_with names the network itself." }
        if (-not @($plan | Where-Object { $_.Name -ieq $peer })) { Exit-InputProblem "landing_zone.networks '$($network.Name)': peer_with names '$peer', which is not an entry of landing_zone.networks." }
        # A network that uses the gateway of its peer needs that peer to offer it (Microsoft Learn: Virtual network peering, gateway transit).
        $remote = @($plan | Where-Object { $_.Name -ieq $peer }) | Select-Object -First 1
        if ($network.UseRemoteGateways -and -not $remote.AllowGatewayTransit) { Exit-InputProblem "landing_zone.networks '$($network.Name)': use_remote_gateways is true, but its peer '$peer' does not set allow_gateway_transit to true." }
    }
}

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
foreach ($network in $plan) {
    $problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{
            "landing_zone.networks '$($network.Name)' resource_group" = $network.ResourceGroup; "landing_zone.networks '$($network.Name)' location" = $network.Location
            "landing_zone.networks '$($network.Name)' subnet names" = @($network.Subnets | ForEach-Object { $_.Name })
            "landing_zone.networks '$($network.Name)' network_security_group" = @($network.Subnets | ForEach-Object { $_.Nsg })
            "landing_zone.networks '$($network.Name)' route_table" = @($network.Subnets | ForEach-Object { $_.RouteTable })
            "landing_zone.networks '$($network.Name)' peer_with" = @($network.PeerWith)
        })
    if ($problem) { Exit-InputProblem $problem }
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Deploy-VirtualNetworks.ps1.' }
try { $account = Invoke-Az account show --query tenantId --output tsv }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($account -ne $tenantId) { Exit-Failed "Signed in to tenant $account, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

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

# A network security group or route table by name in the resource group of the network; $null when it is not there yet.
function Get-Attachment([string]$Kind, [string]$Name, [object]$Item) {
    if ($Kind -eq 'nsg') { return Get-AzCliResource network nsg show --name $Name --resource-group $Item.ResourceGroup --subscription $Item.SubscriptionId }
    Get-AzCliResource network route-table show --name $Name --resource-group $Item.ResourceGroup --subscription $Item.SubscriptionId
}
# The prefixes of a subnet as az returns them: addressPrefix (one) or addressPrefixes (a list).
function Get-SubnetPrefix([object]$Subnet) {
    $single = Get-JsonValue $Subnet 'addressPrefix'
    $many = Get-JsonValue $Subnet 'addressPrefixes'
    @(@($single) + @($many)) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique
}

Write-Line "Deploying $($plan.Count) virtual network(s)"

$networkRows = [System.Collections.Generic.List[object]]::new()
$networkId = @{}          # network name (lower case) -> resource id of a network that exists

# ---- pass 1: the networks
foreach ($item in $plan) {
    $row = [ordered]@{ Network = $item.Name; Action = ''; SubnetsAdded = @(); Differences = @(); Detail = '' }
    try {
        $existing = Get-AzCliResource network vnet show --name $item.Name --resource-group $item.ResourceGroup --subscription $item.SubscriptionId

        # attachments the subnets name, looked up once
        $attach = @{}
        foreach ($subnet in $item.Subnets) {
            foreach ($pair in @(@('nsg', $subnet.Nsg), @('rt', $subnet.RouteTable))) {
                if ($pair[1] -and -not $attach.ContainsKey("$($pair[0])|$($pair[1])")) { $attach["$($pair[0])|$($pair[1])"] = Get-Attachment $pair[0] $pair[1] $item }
            }
        }
        $missingAttach = @($attach.Keys | Where-Object { -not $attach[$_] } | ForEach-Object { $_.Split('|')[1] })

        # The arguments that attach a group or a route table to a subnet, for the ones that exist.
        $attachArgs = {
            param([object]$Subnet)
            $extra = @()
            if ($Subnet.Nsg -and $attach["nsg|$($Subnet.Nsg)"]) { $extra += '--network-security-group'; $extra += [string](Get-JsonValue $attach["nsg|$($Subnet.Nsg)"] 'id') }
            if ($Subnet.RouteTable -and $attach["rt|$($Subnet.RouteTable)"]) { $extra += '--route-table'; $extra += [string](Get-JsonValue $attach["rt|$($Subnet.RouteTable)"] 'id') }
            $extra
        }

        if (-not $existing) {
            if ($PSCmdlet.ShouldProcess("virtual network '$($item.Name)' in '$($item.ResourceGroup)'", "Create ($($item.AddressSpace -join ', '), $($item.Subnets.Count) subnet(s))")) {
                $createArgs = @('network', 'vnet', 'create', '--name', $item.Name, '--resource-group', $item.ResourceGroup, '--location', $item.Location, '--subscription', $item.SubscriptionId, '--address-prefixes')
                $createArgs += @($item.AddressSpace)
                if ($item.DnsServers.Count) { $createArgs += '--dns-servers'; $createArgs += @($item.DnsServers) }
                $createArgs += @(Get-TagArgument)
                $created = Invoke-AzJson @createArgs
                foreach ($subnet in $item.Subnets) {
                    $subnetArgs = @('network', 'vnet', 'subnet', 'create', '--name', $subnet.Name, '--vnet-name', $item.Name, '--resource-group', $item.ResourceGroup, '--subscription', $item.SubscriptionId, '--address-prefixes', $subnet.Prefix)
                    $subnetArgs += @(& $attachArgs $subnet)
                    $null = Invoke-AzJson @subnetArgs
                }
                $row.Action = 'Created'
                $networkId[$item.Name.ToLowerInvariant()] = [string](Get-JsonValue $created 'newVNet.id')
                if (-not $networkId[$item.Name.ToLowerInvariant()]) { $networkId[$item.Name.ToLowerInvariant()] = [string](Get-JsonValue $created 'id') }
                Write-Line "[created] $($item.Name): $($item.AddressSpace -join ', '), $($item.Subnets.Count) subnet(s)."
            }
            else {
                $row.Action = 'WouldCreate'
                Write-Line "[plan]    $($item.Name): would be created ($($item.AddressSpace -join ', '), $($item.Subnets.Count) subnet(s))."
            }
            if ($missingAttach.Count) {
                $row.Detail = "Not attached yet, the resource does not exist: $($missingAttach -join ', '). Run the script again once it exists."
                Write-Warning "$($item.Name): $($row.Detail)"
            }
        }
        else {
            $networkId[$item.Name.ToLowerInvariant()] = [string](Get-JsonValue $existing 'id')
            $differences = [System.Collections.Generic.List[string]]::new()
            $changed = $false
            $added = [System.Collections.Generic.List[string]]::new()

            $haveSpace = @(@(Get-JsonValue $existing 'addressSpace.addressPrefixes') | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $missingSpace = @($item.AddressSpace | Where-Object { $haveSpace -notcontains $_ })
            if ($missingSpace.Count) { $differences.Add("address space lacks $($missingSpace -join ', ')") }
            $haveDns = @(@(Get-JsonValue $existing 'dhcpOptions.dnsServers') | Where-Object { $_ } | ForEach-Object { [string]$_ })
            if ($item.DnsServers.Count -and (($item.DnsServers -join ',') -ne ($haveDns -join ','))) { $differences.Add("DNS servers are '$($haveDns -join ', ')', the file says '$($item.DnsServers -join ', ')'") }

            $haveSubnets = @(Get-JsonValue $existing 'subnets')
            foreach ($subnet in $item.Subnets) {
                $have = @($haveSubnets | Where-Object { $_ -and [string]$_.name -ieq $subnet.Name }) | Select-Object -First 1
                if (-not $have) {
                    if ($PSCmdlet.ShouldProcess("virtual network '$($item.Name)'", "Add the subnet '$($subnet.Name)' ($($subnet.Prefix))")) {
                        $subnetArgs = @('network', 'vnet', 'subnet', 'create', '--name', $subnet.Name, '--vnet-name', $item.Name, '--resource-group', $item.ResourceGroup, '--subscription', $item.SubscriptionId, '--address-prefixes', $subnet.Prefix)
                        $subnetArgs += @(& $attachArgs $subnet)
                        $null = Invoke-AzJson @subnetArgs
                        $changed = $true
                    }
                    $added.Add($subnet.Name)
                    continue
                }
                $havePrefix = @(Get-SubnetPrefix $have)
                if ($havePrefix -notcontains $subnet.Prefix) { $differences.Add("subnet '$($subnet.Name)' is $($havePrefix -join ', '), the file says $($subnet.Prefix)"); continue }
                foreach ($pair in @(@('nsg', $subnet.Nsg, 'NetworkSecurityGroup', 'networkSecurityGroup', '--network-security-group'), @('rt', $subnet.RouteTable, 'RouteTable', 'routeTable', '--route-table'))) {
                    if (-not $pair[1]) { continue }
                    $haveId = [string](Get-JsonValue $have "$($pair[3]).id")
                    $resource = $attach["$($pair[0])|$($pair[1])"]
                    if ($haveId) {
                        if ($resource -and $haveId -ine [string](Get-JsonValue $resource 'id')) { $differences.Add("subnet '$($subnet.Name)' has another $($pair[2]) attached than '$($pair[1])'") }
                        elseif (-not $resource -and ($haveId.Split('/')[-1] -ine $pair[1])) { $differences.Add("subnet '$($subnet.Name)' has another $($pair[2]) attached than '$($pair[1])'") }
                    }
                    elseif ($resource) {
                        if ($PSCmdlet.ShouldProcess("subnet '$($subnet.Name)' of '$($item.Name)'", "Attach the $($pair[2]) '$($pair[1])'")) {
                            # "az network vnet subnet update" changes only what it is given, so the other attachment stays.
                            $null = Invoke-AzJson network vnet subnet update --name $subnet.Name --vnet-name $item.Name --resource-group $item.ResourceGroup --subscription $item.SubscriptionId $pair[4] ([string](Get-JsonValue $resource 'id'))
                            $changed = $true
                        }
                        $added.Add("$($subnet.Name):$($pair[2])")
                    }
                }
            }
            $row.SubnetsAdded = @($added)
            $row.Differences = @($differences)
            if ($added.Count) {
                $row.Action = if ($changed) { 'Updated' } else { 'WouldUpdate' }
                Write-Line "[$(if ($changed) { 'updated' } else { 'plan' })]  $($item.Name): $(if ($changed) { 'added' } else { 'would add' }) $($added -join ', ')."
            }
            else {
                $row.Action = 'AlreadyExists'
                Write-Line "[exists]  $($item.Name): already there, nothing changed."
            }
            if ($differences.Count) {
                $row.Detail = "Differs from the file ($($differences -join '; ')); left unchanged."
                Write-Warning "$($item.Name): $($row.Detail)"
            }
            if ($missingAttach.Count) {
                $row.Detail = ($row.Detail + " Not attached yet, the resource does not exist: $($missingAttach -join ', ').").Trim()
                Write-Warning "$($item.Name): Not attached yet, the resource does not exist: $($missingAttach -join ', '). Run the script again once it exists."
            }
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        Write-Warning "$($item.Name): $($row.Detail)"
    }
    $networkRows.Add([pscustomobject]$row)
}

# ---- pass 2: the peerings, in both directions, between networks that exist
$peeringRows = [System.Collections.Generic.List[object]]::new()
$pairs = [System.Collections.Generic.List[object]]::new()
foreach ($item in $plan) {
    foreach ($peer in $item.PeerWith) {
        $other = @($plan | Where-Object { $_.Name -ieq $peer }) | Select-Object -First 1
        foreach ($direction in @(@($item, $other), @($other, $item))) {
            $key = "$($direction[0].Name)>$($direction[1].Name)".ToLowerInvariant()
            if (-not @($pairs | Where-Object { $_.Key -eq $key })) { $pairs.Add([pscustomobject]@{ Key = $key; Local = $direction[0]; Remote = $direction[1] }) }
        }
    }
}
foreach ($pair in $pairs) {
    $localName = $pair.Local.Name; $remoteName = $pair.Remote.Name
    $peeringName = "peer-$localName-to-$remoteName"
    if ($peeringName.Length -gt 80) { $peeringName = $peeringName.Substring(0, 80) }
    $row = [ordered]@{ Peering = $peeringName; Action = ''; Detail = '' }
    try {
        $localRow = @($networkRows | Where-Object { $_.Network -eq $localName }) | Select-Object -First 1
        $remoteRow = @($networkRows | Where-Object { $_.Network -eq $remoteName }) | Select-Object -First 1
        if ($localRow.Action -eq 'Failed' -or $remoteRow.Action -eq 'Failed') {
            $row.Action = 'Skipped'; $row.Detail = 'one of the two networks failed'
            Write-Warning "${peeringName}: skipped, one of the two networks failed."
        }
        elseif (-not $networkId.ContainsKey($localName.ToLowerInvariant()) -or -not $networkId.ContainsKey($remoteName.ToLowerInvariant())) {
            $row.Action = 'WouldPeer'; $row.Detail = 'once both networks exist'
            Write-Line "[plan]    ${peeringName}: would be created once both networks exist."
        }
        else {
            $current = Get-AzCliResource network vnet peering show --name $peeringName --vnet-name $localName --resource-group $pair.Local.ResourceGroup --subscription $pair.Local.SubscriptionId
            if ($current) {
                $row.Action = 'AlreadyExists'
                $state = [string](Get-JsonValue $current 'peeringState')
                if ($state) { $row.Detail = "state $state" }
                Write-Line "[exists]  ${peeringName}: already there$(if ($state) { " ($state)" }), nothing changed."
            }
            elseif ($PSCmdlet.ShouldProcess("virtual network '$localName'", "Peer with '$remoteName' ($peeringName)")) {
                # The boolean options of "az network vnet peering create" default to false, so each is passed.
                $peeringArgs = @('network', 'vnet', 'peering', 'create', '--name', $peeringName, '--vnet-name', $localName, '--resource-group', $pair.Local.ResourceGroup, '--subscription', $pair.Local.SubscriptionId,
                    '--remote-vnet', $networkId[$remoteName.ToLowerInvariant()], '--allow-vnet-access', 'true',
                    '--allow-forwarded-traffic', ([string]$pair.Local.AllowForwardedTraffic).ToLowerInvariant(), '--allow-gateway-transit', ([string]$pair.Local.AllowGatewayTransit).ToLowerInvariant(),
                    '--use-remote-gateways', ([string]$pair.Local.UseRemoteGateways).ToLowerInvariant())
                $null = Invoke-AzJson @peeringArgs
                $row.Action = 'Created'
                Write-Line "[created] ${peeringName}."
            }
            else {
                $row.Action = 'WouldPeer'
                Write-Line "[plan]    ${peeringName}: would be created."
            }
        }
    }
    catch {
        $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
        Write-Warning "${peeringName}: $($row.Detail)"
    }
    $peeringRows.Add([pscustomobject]$row)
}

$count = { param($rows, $action) @($rows | Where-Object Action -EQ $action).Count }
$created = & $count $networkRows 'Created'
$updated = & $count $networkRows 'Updated'
$existingCount = & $count $networkRows 'AlreadyExists'
$plannedNetworks = (& $count $networkRows 'WouldCreate') + (& $count $networkRows 'WouldUpdate')
$failedNetworks = & $count $networkRows 'Failed'
$peered = & $count $peeringRows 'Created'
$peeringsExisting = & $count $peeringRows 'AlreadyExists'
$plannedPeerings = & $count $peeringRows 'WouldPeer'
$failedPeerings = & $count $peeringRows 'Failed'
Write-Line "Summary: networks $created created, $updated updated, $existingCount already existed, $plannedNetworks planned, $failedNetworks failed; peerings $peered created, $peeringsExisting already existed, $plannedPeerings planned, $failedPeerings failed."
if ($created -eq 0 -and $updated -eq 0 -and $plannedNetworks -eq 0 -and $failedNetworks -eq 0 -and $peered -eq 0 -and $plannedPeerings -eq 0 -and $failedPeerings -eq 0) { Write-Line 'Nothing to do: every network and peering is already in place.' }

[pscustomobject]@{
    NetworksCreated = $created; NetworksUpdated = $updated; NetworksExisting = $existingCount; NetworksPlanned = $plannedNetworks; NetworksFailed = $failedNetworks
    PeeringsCreated = $peered; PeeringsExisting = $peeringsExisting; PeeringsPlanned = $plannedPeerings; PeeringsFailed = $failedPeerings
    Networks = @($networkRows); Peerings = @($peeringRows)
}
if ($failedNetworks -gt 0 -or $failedPeerings -gt 0) { exit 1 }
exit 0
