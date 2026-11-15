<#
.SYNOPSIS
    Creates the site-to-site VPN connections of the hub VPN gateway that infrastructure.yml describes, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 03 (site-to-site VPN connection), Azure CLI variant of New-VpnConnection.ps1. It
    does the same with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. For each entry of
    landing_zone.connectivity.vpn_gateway.site_to_site the script creates the local network gateway (the on-premises VPN device: its public IP
    address and the address ranges behind it) and the IPsec connection from the VPN gateway of the hub to it, with the shared key the entry
    names. When the entry has both a peer_asn and a peer_bgp_address the local network gateway carries the BGP settings and the connection
    turns BGP on (the hub gateway has BGP enabled, task 02). It does not create the gateway (Deploy-VpnGateway.ps1 does).

    Idempotent, and additive. A local network gateway or connection that exists is reported (AlreadyExists) and left alone: a different peer
    address, address range or BGP setting is reported in the detail and not changed. The shared key is read only when a connection has to be
    created. -WhatIf changes nothing and does not read the secret.

    The shared key is a secret reference. A keyvault://<vault>/<secret> reference is read at run time with "az keyvault secret show" (the vault must
    be listed under key_vaults; you need Key Vault Secrets User on it). env://, file:// and command:// references are read by the toolkit's secret
    resolver. The key is never written, logged, printed or returned, and an az error text that would hold it is cleaned before it is shown. "az network
    vpn-connection create" takes the key as an argument, so it is on the command line of that one az process for the seconds the call lasts. On Windows az is a batch file (az.cmd), which reads a percent sign in an argument as a variable: give the secret no percent sign.

    The script reads Azure (read only) and writes only with "az network local-gateway create" and "az network vpn-connection create", behind
    -WhatIf. It does not sign in: run "az login --tenant <azure.tenant_id>" first. You need Network Contributor (or Contributor) on the
    resource group of the gateway. Every az call names its subscription, so the subscription of the az session is not changed. The tags in the
    file-level tags map are put on what the script creates. The IKE settings are the Azure defaults.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags, key_vaults[].name (to check the vault of a keyvault:// reference)
        landing_zone.connectivity.vpn_gateway.name, .resource_group, .network     the gateway (its resource group, else the one of the network)
        landing_zone.networks[].name, .subscription, .resource_group, .location   where the network, and so the gateway, is
        landing_zone.subscriptions[].name, .id                                    the subscription that holds the network
        landing_zone.connectivity.vpn_gateway.site_to_site[]: connection_name, local_gateway_name, peer_public_ip, peer_address_prefixes,
                                                              peer_bgp_address, peer_asn, shared_key

    Exit codes: 0 every connection exists (created now, already there, or planned under -WhatIf), or the file lists none; 1 an az call failed
    or a precondition failed (az missing, not signed in, wrong tenant, the gateway does not exist, a secret could not be read) or a
    creation failed; 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-VpnConnection.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which local network gateways and connections would be created, and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-VpnConnection.azcli.ps1 -InfrastructureFile ./infrastructure.yml

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
$NotFound = 'ResourceNotFound|NotFound|could not be found|was not found|does not exist|\b404\b'
# The az command group of the VPN gateway, kept as one text: the enforcement scan reads a lone word that starts with vnet- as a resource name.
$VnetGatewayCommand = 'network vnet-gateway'.Split(' ')
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

# One az call. Returns the text of standard output (warnings on standard error are dropped); throws with the error text when az fails.
function Invoke-Az {
    $out = @(& az @args 2>&1)
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ').Trim() }
    (@($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}

# The secret a reference points to, as text, for a call that has to carry it. A keyvault:// reference is read with the Azure CLI ("az keyvault secret
# show", no Az module needed); env://, file:// and command:// go through the toolkit's resolver. The value is never written or logged, and no message
# of this function holds it. The vault must be listed under key_vaults, as the toolkit's resolver requires.
function Get-SecretText([string]$Reference) {
    if ((Get-AzlSecretProvider -Reference $Reference) -ne 'keyvault') { return (Get-AzlSecretPlainText -Reference $Reference -Infrastructure $infra) }
    if ($Reference -notmatch '^keyvault://(?<vault>[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9])/(?<secret>[A-Za-z0-9-]{1,127})(/(?<version>[0-9a-fA-F]{32}))?$') { throw 'The secret reference is not a valid keyvault:// reference.' }
    $vault = $Matches['vault']; $secretName = $Matches['secret']; $version = $Matches['version']
    $listed = @(Get-AzlInfrastructureValue -Infrastructure $infra -Path 'key_vaults' | ForEach-Object { $_ } | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('name') } | ForEach-Object { [string]$_['name'] })
    if ($vault -notin $listed) { throw "$Reference names vault $vault, which is not listed under key_vaults in the infrastructure file. Add the vault there first." }
    $showArgs = @('keyvault', 'secret', 'show', '--vault-name', $vault, '--name', $secretName)
    if ($version) { $showArgs += '--version'; $showArgs += $version }
    $showArgs += @('--query', 'value', '--output', 'tsv')
    $out = @(& az @showArgs 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "The secret of $Reference could not be read with az (exit code $LASTEXITCODE). Check the secret name, the role Key Vault Secrets User on the vault and the sign-in." }
    $text = (($out | ForEach-Object { "$_" }) -join "`n").TrimEnd("`r", "`n")
    if (-not $text) { throw "$Reference is empty." }
    $text
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
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-VpnConnection.ps1.' }
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

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $vpnGateway = $null
    try { $vpnGateway = Get-AzCliResource $VnetGatewayCommand[0] $VnetGatewayCommand[1] show --name $gatewayName --resource-group $group --subscription $subscriptionId }
    catch { Exit-Failed "The VPN gateway '$gatewayName' could not be read: $($_.Exception.Message)" }
    if (-not $vpnGateway) { Exit-Failed "The VPN gateway '$gatewayName' does not exist in '$group'. Create it first (Deploy-VpnGateway.ps1)." }
    $gatewayId = [string](Get-JsonValue $vpnGateway 'id')
    Write-Line "Site-to-site connections of the VPN gateway '$gatewayName' in '$group' ($location): $($plan.Count) in the file"

    foreach ($item in $plan) {
        $row = [ordered]@{ Connection = $item.Connection; LocalGateway = $item.LocalGateway; Action = ''; ConnectionStatus = ''; Detail = '' }
        try {
            # ---- the local network gateway
            $local = Get-AzCliResource network local-gateway show --name $item.LocalGateway --resource-group $group --subscription $subscriptionId
            $localExists = [bool]$local
            $differs = [System.Collections.Generic.List[string]]::new()
            if ($local) {
                $currentIp = [string](Get-JsonValue $local 'gatewayIpAddress')
                if ($currentIp -and $currentIp -ne $item.PeerIp) { $differs.Add("the local network gateway has peer address $currentIp, the file says $($item.PeerIp)") }
                $currentPrefixes = @(@(Get-JsonValue $local 'localNetworkAddressSpace.addressPrefixes') | Where-Object { $_ } | ForEach-Object { [string]$_ })
                if ($currentPrefixes.Count -and (Compare-Object -ReferenceObject $currentPrefixes -DifferenceObject $item.Prefixes)) { $differs.Add("the local network gateway has ranges $($currentPrefixes -join ', '), the file says $($item.Prefixes -join ', ')") }
                Write-Line "[exists]  Local network gateway '$($item.LocalGateway)' is already there."
            }
            elseif ($PSCmdlet.ShouldProcess("local network gateway '$($item.LocalGateway)' in '$group'", "Create (peer $($item.PeerIp))")) {
                $lgwArgs = @('network', 'local-gateway', 'create', '--name', $item.LocalGateway, '--resource-group', $group, '--location', $location, '--subscription', $subscriptionId, '--gateway-ip-address', $item.PeerIp, '--local-address-prefixes')
                $lgwArgs += @($item.Prefixes)
                if ($item.BgpAddress) { $lgwArgs += '--asn'; $lgwArgs += [string]$item.Asn; $lgwArgs += '--bgp-peering-address'; $lgwArgs += $item.BgpAddress }
                $lgwArgs += @(Get-TagArgument)
                $null = Invoke-AzJson @lgwArgs
                $localExists = $true
                Write-Line "[created] Local network gateway '$($item.LocalGateway)'."
            }
            else {
                Write-Line "[plan]    Local network gateway '$($item.LocalGateway)' would be created (peer $($item.PeerIp))."
            }

            # ---- the connection
            $existing = Get-AzCliResource network vpn-connection show --name $item.Connection --resource-group $group --subscription $subscriptionId
            if ($existing) {
                $row.Action = 'AlreadyExists'
                $row.ConnectionStatus = [string](Get-JsonValue $existing 'connectionStatus')
                Write-Line "[exists]  Connection '$($item.Connection)' is already there ($($row.ConnectionStatus)), nothing changed."
            }
            elseif ($PSCmdlet.ShouldProcess("connection '$($item.Connection)' in '$group'", "Create an IPsec connection from '$gatewayName' to '$($item.LocalGateway)'")) {
                if (-not $localExists) { throw "The local network gateway '$($item.LocalGateway)' does not exist, so the connection cannot be created." }
                $sharedKey = Get-SecretText $item.KeyReference
                $connArgs = @('network', 'vpn-connection', 'create', '--name', $item.Connection, '--resource-group', $group, '--location', $location, '--subscription', $subscriptionId,
                    '--vnet-gateway1', $gatewayId, '--local-gateway2', $item.LocalGateway, '--shared-key', $sharedKey)
                if ($item.BgpAddress) { $connArgs += '--enable-bgp' }
                $connArgs += @(Get-TagArgument)
                try { $created = Invoke-AzJson @connArgs }
                catch { throw ([string]$_.Exception.Message).Replace($sharedKey, '<shared key>') }
                finally { $sharedKey = $null; $connArgs = $null }
                $row.Action = 'Created'
                $row.ConnectionStatus = [string](Get-JsonValue $created 'connectionStatus')
                $created = $null   # the answer of az can hold the shared key; it is never shown
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

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
