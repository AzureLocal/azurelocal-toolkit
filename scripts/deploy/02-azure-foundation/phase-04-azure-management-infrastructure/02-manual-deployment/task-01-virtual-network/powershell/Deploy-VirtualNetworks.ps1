<#
.SYNOPSIS
    Creates the virtual networks of the landing zone, their subnets and their peerings, from infrastructure.yml.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 01 (virtual network). For each entry of landing_zone.networks this
    script creates the virtual network with its address space, DNS servers and subnets, in the subscription and resource group the entry names,
    and then peers the networks that list each other in peer_with (a peering is made in both directions, once both networks exist).

    Idempotent, and additive. A network that already exists is not recreated and nothing is removed from it: a subnet the file lists and the
    network lacks is added; a network security group or route table the file names for a subnet that has none is attached once that resource
    exists. Everything else that differs (the address space, the DNS servers, a subnet range, a different security group on a subnet) is
    reported as a difference and left as it is, because changing it can interrupt traffic. A peering that exists is left alone. -WhatIf
    changes nothing.

    A subnet's network_security_group and route_table are names of resources in the same resource group as the network. If the resource does
    not exist yet (the security group task comes after this one) the subnet is created without it and the script says so; run the script again
    after the security groups exist and it attaches them. Peerings are created with virtual network access and forwarded traffic allowed and
    with no gateway transit: add transit with the gateway once the VPN gateway task has run.

    The script reads Azure (read only) and writes only with New-AzVirtualNetwork, Add-AzVirtualNetworkSubnetConfig,
    Set-AzVirtualNetworkSubnetConfig, Set-AzVirtualNetwork and Add-AzVirtualNetworkPeering, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first. You need Network Contributor (or Contributor) on each resource group, and, for a
    peering to a network in another subscription, on that network as well. The script changes the subscription of the session while it
    works and puts it back. The tags in the file-level tags map are put on the networks it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.subscriptions[].name, .id                                 the subscription of each network
        landing_zone.networks[].name, .subscription, .resource_group, .location, .address_space, .dns_servers, .peer_with
        landing_zone.networks[].subnets[].name, .prefix, .network_security_group, .route_table

    Exit codes: 0 every network and peering is in place (created now, already there, planned under -WhatIf, or reported as different and left
    alone); 1 an Azure call failed, a precondition failed (not signed in, wrong tenant, Az modules missing) or a network or peering could not
    be created; 2 the file lists no network, or a value is not usable (a name, an address range that is not CIDR or lies outside the address
    space, subnets that overlap, a peer that is not in the file).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-VirtualNetworks.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which networks, subnets and peerings would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-VirtualNetworks.ps1 -InfrastructureFile ./infrastructure.yml

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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'
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

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$defaultLocation = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networkEntries = @(@($rawNetworks) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptionEntries = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
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
    $subnets = @(@($rawSubnets) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object {
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
    [pscustomobject]@{
        Name = $name; Subscription = $subscriptionName; SubscriptionId = $subscriptionId; ResourceGroup = $group; Location = $location
        AddressSpace = $space; DnsServers = $dns; Subnets = $subnets; PeerWith = @(Get-EntryList $entry 'peer_with')
    }
}
$plan = @($plan)
$dupNetwork = @($plan | Group-Object { "$($_.SubscriptionId)/$($_.ResourceGroup)/$($_.Name)".ToLowerInvariant() } | Where-Object Count -GT 1)
if ($dupNetwork.Count) { Exit-InputProblem "The network '$($dupNetwork[0].Group[0].Name)' appears more than once in landing_zone.networks." }
foreach ($network in $plan) {
    foreach ($peer in $network.PeerWith) {
        if ($peer -ieq $network.Name) { Exit-InputProblem "landing_zone.networks '$($network.Name)': peer_with names the network itself." }
        if (-not @($plan | Where-Object { $_.Name -ieq $peer })) { Exit-InputProblem "landing_zone.networks '$($network.Name)': peer_with names '$peer', which is not an entry of landing_zone.networks." }
    }
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzVirtualNetwork', 'New-AzVirtualNetwork', 'New-AzVirtualNetworkSubnetConfig', 'Add-AzVirtualNetworkSubnetConfig', 'Set-AzVirtualNetworkSubnetConfig',
    'Set-AzVirtualNetwork', 'Get-AzNetworkSecurityGroup', 'Get-AzRouteTable', 'Get-AzVirtualNetworkPeering', 'Add-AzVirtualNetworkPeering') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Network modules: Install-Module Az.Accounts, Az.Network -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context
$script:currentSubscription = ''

function Use-Subscription([string]$SubscriptionId) {
    if ($script:currentSubscription -ne $SubscriptionId) {
        $null = Set-AzContext -SubscriptionId $SubscriptionId -Tenant $tenantId -ErrorAction Stop
        $script:currentSubscription = $SubscriptionId
    }
}

# A network security group or route table by name in the resource group of the network; $null when it is not there yet.
function Get-Attachment([string]$Kind, [string]$Name, [string]$ResourceGroup) {
    try {
        if ($Kind -eq 'nsg') { return Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop }
        return Get-AzRouteTable -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop
    }
    catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
    $null
}

function Get-ExistingValue([object]$Object, [string]$Property) {
    if ($Object -and $Object.PSObject.Properties[$Property]) { return $Object.$Property }
    $null
}

Write-Line "Deploying $($plan.Count) virtual network(s)"

$networkRows = [System.Collections.Generic.List[object]]::new()
$networkId = @{}          # network name (lower case) -> resource id of a network that exists
$networkObject = @{}      # network name (lower case) -> the network object, for the peerings

try {
    # ---- pass 1: the networks
    foreach ($item in $plan) {
        $row = [ordered]@{ Network = $item.Name; Action = ''; SubnetsAdded = @(); Differences = @(); Detail = '' }
        try {
            Use-Subscription $item.SubscriptionId
            $existing = $null
            try { $existing = Get-AzVirtualNetwork -ResourceGroupName $item.ResourceGroup -Name $item.Name -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }

            # attachments the subnets name, looked up once
            $attach = @{}
            foreach ($subnet in $item.Subnets) {
                foreach ($pair in @(@('nsg', $subnet.Nsg), @('rt', $subnet.RouteTable))) {
                    if ($pair[1] -and -not $attach.ContainsKey("$($pair[0])|$($pair[1])")) { $attach["$($pair[0])|$($pair[1])"] = Get-Attachment $pair[0] $pair[1] $item.ResourceGroup }
                }
            }
            $missingAttach = @($attach.Keys | Where-Object { -not $attach[$_] } | ForEach-Object { $_.Split('|')[1] })

            if (-not $existing) {
                $subnetConfig = foreach ($subnet in $item.Subnets) {
                    $arguments = @{ Name = $subnet.Name; AddressPrefix = $subnet.Prefix }
                    if ($subnet.Nsg -and $attach["nsg|$($subnet.Nsg)"]) { $arguments.NetworkSecurityGroup = $attach["nsg|$($subnet.Nsg)"] }
                    if ($subnet.RouteTable -and $attach["rt|$($subnet.RouteTable)"]) { $arguments.RouteTable = $attach["rt|$($subnet.RouteTable)"] }
                    New-AzVirtualNetworkSubnetConfig @arguments
                }
                if ($PSCmdlet.ShouldProcess("virtual network '$($item.Name)' in '$($item.ResourceGroup)'", "Create ($($item.AddressSpace -join ', '), $($item.Subnets.Count) subnet(s))")) {
                    $arguments = @{ ResourceGroupName = $item.ResourceGroup; Name = $item.Name; Location = $item.Location; AddressPrefix = $item.AddressSpace; Force = $true; ErrorAction = 'Stop' }
                    if (@($subnetConfig).Count) { $arguments.Subnet = @($subnetConfig) }
                    if ($item.DnsServers.Count) { $arguments.DnsServer = $item.DnsServers }
                    if ($tags.Count) { $arguments.Tag = $tags }
                    $created = New-AzVirtualNetwork @arguments
                    $row.Action = 'Created'
                    if ($created -and $created.PSObject.Properties['Id']) { $networkId[$item.Name.ToLowerInvariant()] = [string]$created.Id; $networkObject[$item.Name.ToLowerInvariant()] = $created }
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
                $networkId[$item.Name.ToLowerInvariant()] = [string]$existing.Id
                $networkObject[$item.Name.ToLowerInvariant()] = $existing
                $differences = [System.Collections.Generic.List[string]]::new()
                $changed = $false
                $added = [System.Collections.Generic.List[string]]::new()

                $haveSpace = @((Get-ExistingValue (Get-ExistingValue $existing 'AddressSpace') 'AddressPrefixes') | ForEach-Object { [string]$_ })
                $missingSpace = @($item.AddressSpace | Where-Object { $haveSpace -notcontains $_ })
                if ($missingSpace.Count) { $differences.Add("address space lacks $($missingSpace -join ', ')") }
                $haveDns = @((Get-ExistingValue (Get-ExistingValue $existing 'DhcpOptions') 'DnsServers') | ForEach-Object { [string]$_ })
                if ($item.DnsServers.Count -and (($item.DnsServers -join ',') -ne ($haveDns -join ','))) { $differences.Add("DNS servers are '$($haveDns -join ', ')', the file says '$($item.DnsServers -join ', ')'") }

                foreach ($subnet in $item.Subnets) {
                    $have = @($existing.Subnets | Where-Object { [string]$_.Name -ieq $subnet.Name }) | Select-Object -First 1
                    if (-not $have) {
                        if ($PSCmdlet.ShouldProcess("virtual network '$($item.Name)'", "Add the subnet '$($subnet.Name)' ($($subnet.Prefix))")) {
                            $arguments = @{ Name = $subnet.Name; AddressPrefix = $subnet.Prefix; VirtualNetwork = $existing; ErrorAction = 'Stop' }
                            if ($subnet.Nsg -and $attach["nsg|$($subnet.Nsg)"]) { $arguments.NetworkSecurityGroup = $attach["nsg|$($subnet.Nsg)"] }
                            if ($subnet.RouteTable -and $attach["rt|$($subnet.RouteTable)"]) { $arguments.RouteTable = $attach["rt|$($subnet.RouteTable)"] }
                            $existing = Add-AzVirtualNetworkSubnetConfig @arguments
                            $changed = $true
                        }
                        $added.Add($subnet.Name)
                        continue
                    }
                    $havePrefix = @($have.AddressPrefix | ForEach-Object { [string]$_ })
                    if ($havePrefix -notcontains $subnet.Prefix) { $differences.Add("subnet '$($subnet.Name)' is $($havePrefix -join ', '), the file says $($subnet.Prefix)"); continue }
                    foreach ($pair in @(@('nsg', $subnet.Nsg, 'NetworkSecurityGroup', 'NetworkSecurityGroup'), @('rt', $subnet.RouteTable, 'RouteTable', 'RouteTable'))) {
                        if (-not $pair[1]) { continue }
                        $haveAttached = Get-ExistingValue $have $pair[3]
                        $haveId = [string](Get-ExistingValue $haveAttached 'Id')
                        $resource = $attach["$($pair[0])|$($pair[1])"]
                        if ($haveId) {
                            if ($resource -and $haveId -ine [string]$resource.Id) { $differences.Add("subnet '$($subnet.Name)' has another $($pair[2]) attached than '$($pair[1])'") }
                            elseif (-not $resource -and ($haveId.Split('/')[-1] -ine $pair[1])) { $differences.Add("subnet '$($subnet.Name)' has another $($pair[2]) attached than '$($pair[1])'") }
                        }
                        elseif ($resource) {
                            if ($PSCmdlet.ShouldProcess("subnet '$($subnet.Name)' of '$($item.Name)'", "Attach the $($pair[2]) '$($pair[1])'")) {
                                $arguments = @{ Name = $subnet.Name; VirtualNetwork = $existing; AddressPrefix = $subnet.Prefix; ErrorAction = 'Stop' }
                                $arguments[$pair[2]] = $resource
                                # Set-AzVirtualNetworkSubnetConfig replaces what it is not given: keep the other attachment.
                                $other = if ($pair[0] -eq 'nsg') { @('RouteTable', (Get-ExistingValue $have 'RouteTable')) } else { @('NetworkSecurityGroup', (Get-ExistingValue $have 'NetworkSecurityGroup')) }
                                if ($other[1] -and [string](Get-ExistingValue $other[1] 'Id')) { $arguments[$other[0]] = $other[1] }
                                $existing = Set-AzVirtualNetworkSubnetConfig @arguments
                                $changed = $true
                            }
                            $added.Add("$($subnet.Name):$($pair[2])")
                        }
                    }
                }
                if ($changed) {
                    $saved = Set-AzVirtualNetwork -VirtualNetwork $existing -ErrorAction Stop
                    if ($saved) { $networkObject[$item.Name.ToLowerInvariant()] = $saved }
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
                Use-Subscription $pair.Local.SubscriptionId
                $current = $null
                try { $current = Get-AzVirtualNetworkPeering -ResourceGroupName $pair.Local.ResourceGroup -VirtualNetworkName $localName -Name $peeringName -ErrorAction Stop }
                catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
                if ($current) {
                    $row.Action = 'AlreadyExists'
                    $state = [string](Get-ExistingValue $current 'PeeringState')
                    if ($state) { $row.Detail = "state $state" }
                    Write-Line "[exists]  ${peeringName}: already there$(if ($state) { " ($state)" }), nothing changed."
                }
                elseif ($PSCmdlet.ShouldProcess("virtual network '$localName'", "Peer with '$remoteName' ($peeringName)")) {
                    $null = Add-AzVirtualNetworkPeering -Name $peeringName -VirtualNetwork $networkObject[$localName.ToLowerInvariant()] -RemoteVirtualNetworkId $networkId[$remoteName.ToLowerInvariant()] -AllowForwardedTraffic -ErrorAction Stop
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
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id'] -and $script:currentSubscription) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
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
