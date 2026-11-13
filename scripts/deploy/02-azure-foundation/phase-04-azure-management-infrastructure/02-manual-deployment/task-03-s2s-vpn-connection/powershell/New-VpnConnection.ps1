<#
.SYNOPSIS
    Creates the site-to-site VPN connections of the hub VPN gateway that infrastructure.yml describes.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 03 (site-to-site VPN connection). For each entry of
    landing_zone.connectivity.vpn_gateway.site_to_site the script creates the local network gateway (the on-premises VPN device: its public IP
    address and the address ranges behind it) and the IPsec connection from the VPN gateway of the hub to it, with the shared key the entry
    names. When the entry has both a peer_asn and a peer_bgp_address the local network gateway carries the BGP settings and the connection
    turns BGP on (the hub gateway has BGP enabled, task 02). It does not create the gateway (Deploy-VpnGateway.ps1 does).

    Idempotent, and additive. A local network gateway or connection that exists is reported (AlreadyExists) and left alone: a different peer
    address, address range or BGP setting is reported in the detail and not changed. The shared key is read only when a connection has to be
    created. -WhatIf changes nothing and does not read the secret.

    The script reads Azure (read only) and writes only with New-AzLocalNetworkGateway and New-AzVirtualNetworkGatewayConnection, behind -WhatIf.
    It does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. You need Network Contributor (or Contributor) on the
    resource group of the gateway. The shared key is a secret reference (keyvault://, env://, file:// or command://) read by the toolkit's
    secret resolver; it is never written, logged or returned. The script changes the subscription of the session while it works and puts it
    back. The tags in the file-level tags map are put on what the script creates. The IKE settings are the Azure defaults.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.connectivity.vpn_gateway.name, .resource_group, .network     the gateway (its resource group, else the one of the network)
        landing_zone.networks[].name, .subscription, .resource_group, .location   where the network, and so the gateway, is
        landing_zone.subscriptions[].name, .id                                    the subscription that holds the network
        landing_zone.connectivity.vpn_gateway.site_to_site[]: connection_name, local_gateway_name, peer_public_ip, peer_address_prefixes,
                                                              peer_bgp_address, peer_asn, shared_key

    Exit codes: 0 every connection exists (created now, already there, or planned under -WhatIf), or the file lists none; 1 an Azure call failed
    or a precondition failed (not signed in, wrong tenant, Az modules missing, the gateway does not exist, a secret could not be read) or a
    creation failed; 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-VpnConnection.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which local network gateways and connections would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./New-VpnConnection.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the connections. Run it again: they are reported as AlreadyExists.
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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'
$Ipv4 = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
$Cidr = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)/([0-9]|[12]\d|3[0-2])$'
$ResourceName = '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$'

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

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')
$defaultLocation = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$gateway = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.vpn_gateway'
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networks = @(@($rawNetworks) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptions = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
$tags = @{}
if ($rawTags -is [System.Collections.IDictionary]) { foreach ($k in $rawTags.Keys) { if ($null -ne $rawTags[$k]) { $tags[[string]$k] = [string]$rawTags[$k] } } }

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($gateway -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway is missing. Describe the gateway (task 02) and its site_to_site connections.' }
$rawSites = if ($gateway.Contains('site_to_site')) { $gateway['site_to_site'] } else { $null }
$sites = @(@($rawSites) | Where-Object { $null -ne $_ })
if ($sites.Count -eq 0) {
    Write-Line 'The file lists no landing_zone.connectivity.vpn_gateway.site_to_site: nothing to do.'
    exit 0
}

$gatewayName = Get-Entry $gateway 'name'
$networkName = Get-Entry $gateway 'network'
if (-not $gatewayName) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway.name is missing.' }
if (-not $networkName) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway.network is missing. Name the virtual network (an entry of landing_zone.networks) the gateway is in.' }
$network = @($networks | Where-Object { (Get-Entry $_ 'name') -eq $networkName }) | Select-Object -First 1
if (-not $network) { Exit-InputProblem "The network '$networkName' is not an entry of landing_zone.networks, so the subscription and resource group are not known." }
$subscriptionName = Get-Entry $network 'subscription'
$subscription = @($subscriptions | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
$subscriptionId = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
if (-not $subscriptionName) { Exit-InputProblem "The network '$networkName' has no subscription in landing_zone.networks." }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "The subscription '$subscriptionName' of the network '$networkName' has no usable id in landing_zone.subscriptions." }
$networkGroup = Get-Entry $network 'resource_group'
$group = if (Get-Entry $gateway 'resource_group') { Get-Entry $gateway 'resource_group' } else { $networkGroup }
if (-not $group) { Exit-InputProblem "Neither the gateway nor the network '$networkName' has a resource_group." }
$location = if (Get-Entry $network 'location') { Get-Entry $network 'location' } else { $defaultLocation }
if (-not $location) { Exit-InputProblem "No region: the network '$networkName' has no location and azure.location is empty." }

$plan = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($site in $sites) {
    $index++
    $at = "landing_zone.connectivity.vpn_gateway.site_to_site[$index]"
    if ($site -isnot [System.Collections.IDictionary]) { Exit-InputProblem "$at is not a connection (a map with connection_name, peer_public_ip ...)." }
    $connection = Get-Entry $site 'connection_name'
    if ($connection -notmatch $ResourceName) { Exit-InputProblem "$at.connection_name '$connection' is missing or is not a valid name (1 to 80 letters, digits, . _ -)." }
    if ($seen.ContainsKey($connection.ToLowerInvariant())) { Exit-InputProblem "$at.connection_name '$connection' is listed twice." }
    $seen[$connection.ToLowerInvariant()] = $true
    $localName = if (Get-Entry $site 'local_gateway_name') { Get-Entry $site 'local_gateway_name' } else { "$connection-lgw" }
    if ($localName -notmatch $ResourceName) { Exit-InputProblem "$at.local_gateway_name '$localName' is not a valid name." }
    $peerIp = Get-Entry $site 'peer_public_ip'
    if ($peerIp -notmatch $Ipv4) { Exit-InputProblem "$at.peer_public_ip '$peerIp' is missing or is not an IPv4 address. It is the public address of the on-premises VPN device." }
    $rawPrefixes = if ($site.Contains('peer_address_prefixes')) { $site['peer_address_prefixes'] } else { $null }
    $prefixes = @(@($rawPrefixes) | Where-Object { $null -ne $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() })
    if ($prefixes.Count -eq 0) { Exit-InputProblem "$at.peer_address_prefixes is missing. List the address ranges behind the on-premises VPN device, in CIDR form." }
    foreach ($p in $prefixes) { if ($p -notmatch $Cidr) { Exit-InputProblem "$at.peer_address_prefixes: '$p' is not an IPv4 range in CIDR form." } }
    $bgpAddress = Get-Entry $site 'peer_bgp_address'
    $asnText = Get-Entry $site 'peer_asn'
    $asn = [uint64]0
    if (($bgpAddress -and -not $asnText) -or ($asnText -and -not $bgpAddress)) { Exit-InputProblem "$at needs both peer_asn and peer_bgp_address for BGP, or neither." }
    if ($bgpAddress -and $bgpAddress -notmatch $Ipv4) { Exit-InputProblem "$at.peer_bgp_address '$bgpAddress' is not an IPv4 address." }
    if ($asnText -and (-not [uint64]::TryParse($asnText, [ref]$asn) -or $asn -lt 1 -or $asn -gt 4294967295)) { Exit-InputProblem "$at.peer_asn '$asnText' is not a number from 1 to 4294967295." }
    $key = Get-Entry $site 'shared_key'
    if (-not $key) { Exit-InputProblem "$at.shared_key is missing. It is a secret reference (for example keyvault://<vault>/<secret>), never the key itself." }
    if (-not (Get-AzlSecretProvider -Reference $key)) { Exit-InputProblem "$at.shared_key is not a secret reference (keyvault://, env://, file:// or command://). The key itself is never written to the file." }
    $plan.Add([pscustomobject]@{ Connection = $connection; LocalGateway = $localName; PeerIp = $peerIp; Prefixes = $prefixes; BgpAddress = $bgpAddress; Asn = $asn; KeyReference = $key })
}

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzVirtualNetworkGateway', 'Get-AzLocalNetworkGateway', 'New-AzLocalNetworkGateway', 'Get-AzVirtualNetworkGatewayConnection', 'New-AzVirtualNetworkGatewayConnection') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Network modules: Install-Module Az.Accounts, Az.Network -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    $vpnGateway = $null
    try { $vpnGateway = Get-AzVirtualNetworkGateway -ResourceGroupName $group -Name $gatewayName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The VPN gateway '$gatewayName' could not be read: $($_.Exception.Message)" } }
    if (-not $vpnGateway) { Exit-Failed "The VPN gateway '$gatewayName' does not exist in '$group'. Create it first (Deploy-VpnGateway.ps1)." }
    Write-Line "Site-to-site connections of the VPN gateway '$gatewayName' in '$group' ($location): $($plan.Count) in the file"

    foreach ($item in $plan) {
        $row = [ordered]@{ Connection = $item.Connection; LocalGateway = $item.LocalGateway; Action = ''; ConnectionStatus = ''; Detail = '' }
        try {
            # ---- the local network gateway
            $local = $null
            try { $local = Get-AzLocalNetworkGateway -ResourceGroupName $group -Name $item.LocalGateway -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
            $differs = [System.Collections.Generic.List[string]]::new()
            if ($local) {
                $currentIp = if ($local.PSObject.Properties['GatewayIpAddress']) { [string]$local.GatewayIpAddress } else { '' }
                if ($currentIp -and $currentIp -ne $item.PeerIp) { $differs.Add("the local network gateway has peer address $currentIp, the file says $($item.PeerIp)") }
                $currentPrefixes = @(if ($local.PSObject.Properties['LocalNetworkAddressSpace'] -and $local.LocalNetworkAddressSpace) { $local.LocalNetworkAddressSpace.AddressPrefixes })
                if ($currentPrefixes.Count -and (Compare-Object -ReferenceObject $currentPrefixes -DifferenceObject $item.Prefixes)) { $differs.Add("the local network gateway has ranges $($currentPrefixes -join ', '), the file says $($item.Prefixes -join ', ')") }
                Write-Line "[exists]  Local network gateway '$($item.LocalGateway)' is already there."
            }
            elseif ($PSCmdlet.ShouldProcess("local network gateway '$($item.LocalGateway)' in '$group'", "Create (peer $($item.PeerIp))")) {
                $lgwArgs = @{ ResourceGroupName = $group; Name = $item.LocalGateway; Location = $location; GatewayIpAddress = $item.PeerIp; AddressPrefix = $item.Prefixes; ErrorAction = 'Stop' }
                if ($item.BgpAddress) { $lgwArgs.Asn = [uint32]$item.Asn; $lgwArgs.BgpPeeringAddress = $item.BgpAddress }
                if ($tags.Count) { $lgwArgs.Tag = $tags }
                $local = New-AzLocalNetworkGateway @lgwArgs
                Write-Line "[created] Local network gateway '$($item.LocalGateway)'."
            }
            else {
                Write-Line "[plan]    Local network gateway '$($item.LocalGateway)' would be created (peer $($item.PeerIp))."
            }

            # ---- the connection
            $existing = $null
            try { $existing = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $group -Name $item.Connection -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch $NotFound) { throw } }
            if ($existing) {
                $row.Action = 'AlreadyExists'
                $row.ConnectionStatus = if ($existing.PSObject.Properties['ConnectionStatus']) { [string]$existing.ConnectionStatus } else { '' }
                Write-Line "[exists]  Connection '$($item.Connection)' is already there ($($row.ConnectionStatus)), nothing changed."
            }
            elseif ($PSCmdlet.ShouldProcess("connection '$($item.Connection)' in '$group'", "Create an IPsec connection from '$gatewayName' to '$($item.LocalGateway)'")) {
                if (-not $local) { throw "The local network gateway '$($item.LocalGateway)' does not exist, so the connection cannot be created." }
                $sharedKey = Get-AzlSecretPlainText -Reference $item.KeyReference -Infrastructure $infra
                if (-not $sharedKey) { throw "The shared key of '$($item.Connection)' is empty." }
                $connArgs = @{ ResourceGroupName = $group; Name = $item.Connection; Location = $location; VirtualNetworkGateway1 = $vpnGateway; LocalNetworkGateway2 = $local; ConnectionType = 'IPsec'; SharedKey = $sharedKey; ErrorAction = 'Stop' }
                if ($item.BgpAddress) { $connArgs.EnableBgp = $true }
                if ($tags.Count) { $connArgs.Tag = $tags }
                $created = New-AzVirtualNetworkGatewayConnection @connArgs
                $sharedKey = $null
                $row.Action = 'Created'
                $row.ConnectionStatus = if ($created -and $created.PSObject.Properties['ConnectionStatus']) { [string]$created.ConnectionStatus } else { '' }
                Write-Line "[created] Connection '$($item.Connection)'. Configure the matching shared key on the on-premises VPN device."
            }
            else {
                $row.Action = 'WouldCreate'
                Write-Line "[plan]    Connection '$($item.Connection)' would be created."
            }
            if ($differs.Count) {
                $row.Detail = 'Differs from the file: ' + ($differs -join '; ') + '. Left unchanged.'
                Write-Warning "$($item.Connection): $($row.Detail)"
            }
        }
        catch {
            $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
            Write-Warning "$($item.Connection): $($row.Detail)"
        }
        $rows.Add([pscustomobject]$row)
    }
}
catch { Exit-Failed "The subscription $subscriptionId could not be used: $($_.Exception.Message)" }
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
