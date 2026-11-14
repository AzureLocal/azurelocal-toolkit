<#
.SYNOPSIS
    Deploys the VPN gateway of the connectivity hub that infrastructure.yml describes.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 02 (VPN gateway). Creates the Standard zone-redundant public IP address
    and the route-based VPN gateway named by landing_zone.connectivity.vpn_gateway, in the GatewaySubnet of the virtual network it names, with
    BGP enabled on the ASN of the file. It does not create the virtual network (Deploy-VirtualNetworks.ps1 does) and it does not create the
    site-to-site connections or the local network gateways (task 03); both come after this task.

    A VPN gateway takes 30 to 45 minutes to create. The script waits for it, so start it first and run it from a session that stays open.

    Idempotent. If the gateway already exists the script changes nothing, reports its state, and warns when its SKU or ASN differs from the
    file (a SKU is changed with the upgrade procedure of Microsoft Learn, not by this script). An existing public IP address named
    <gateway name>-pip is reused, so a run that failed after the address was created can be repeated. -WhatIf changes nothing.

    Only SKUs of the AZ family are accepted (VpnGw1AZ to VpnGw5AZ): Microsoft no longer lets you create the non-AZ VpnGw1 to VpnGw5 gateways
    (since 1 November 2025, Microsoft Learn: VPN Gateway SKU consolidation and migration). The generation follows the SKU: VpnGw1AZ is
    Generation1; VpnGw2AZ and above are Generation2. The BGP ASN must not be one that Azure or IANA reserves (VPN Gateway FAQ, BGP).

    The script reads Azure to find the virtual network and the gateway (read only) and writes only with New-AzPublicIpAddress and
    New-AzVirtualNetworkGateway, behind -WhatIf. It does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. You need
    Network Contributor (or Contributor) on the resource group, and read access to the virtual network. The tags in the file-level tags map are
    put on what the script creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id                                       the tenant the sign-in must belong to
        azure.location                                        the region, when the network entry has none
        tags                                                  tags for the resources created (optional)
        landing_zone.connectivity.vpn_gateway.name            the gateway name
        landing_zone.connectivity.vpn_gateway.resource_group  the resource group of the gateway (else the one of the network)
        landing_zone.connectivity.vpn_gateway.network         the virtual network (an entry of landing_zone.networks)
        landing_zone.connectivity.vpn_gateway.sku             the SKU (VpnGw1AZ to VpnGw5AZ)
        landing_zone.connectivity.vpn_gateway.bgp_asn         the BGP ASN of the gateway
        landing_zone.networks[].name, .subscription, .resource_group, .location   where the network is
        landing_zone.subscriptions[].name, .id                the subscription that holds the network and so the gateway

    Exit codes: 0 the gateway exists (created now, already there, or planned under -WhatIf); 1 an Azure call failed or a precondition failed
    (not signed in, wrong tenant, Az modules missing, the network or its GatewaySubnet is missing or too small, the creation failed); 2 a
    value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here (use
    config/variables/scripts/Test-VariablesFile.ps1 or Test-InfrastructureFile.ps1 for that).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Deploy-VpnGateway.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./Deploy-VpnGateway.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the public IP address and the gateway (30 to 45 minutes). Run it again: the gateway is reported as AlreadyExists.
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
# Constants Microsoft fixes, not choices of a deployment (Microsoft Learn: VPN Gateway SKU consolidation and migration; VPN Gateway settings):
# a new gateway needs an AZ SKU; a gateway for Azure Local connectivity is a route-based VPN gateway (policy-based gateways have no BGP).
$AllowedSku = 'VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ', 'VpnGw4AZ', 'VpnGw5AZ'
$GatewayType = 'Vpn'
$VpnType = 'RouteBased'
# The generation follows the SKU (Microsoft Learn: VPN Gateway SKUs): VpnGw1AZ is Generation1, VpnGw2AZ and above are Generation2.
$Generation1Sku = 'VpnGw1AZ'
# Reserved by Azure (8074, 8075, 12076, 65517 to 65520) or by IANA (23456, 64496 to 64511, 65535 to 65551, 4294967295). 65515 is the Azure default and allowed.
$ReservedAsn = @(8074, 8075, 12076, 23456, 4294967295) + 65517..65520 + 64496..64511 + 65535..65551

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
if ($gateway -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway is missing. Describe the gateway: name, network, sku and bgp_asn.' }

$gatewayName = Get-Entry $gateway 'name'
$networkName = Get-Entry $gateway 'network'
$sku = Get-Entry $gateway 'sku'
$asnText = Get-Entry $gateway 'bgp_asn'
if (-not $gatewayName) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway.name is missing.' }
if ($gatewayName -notmatch '^[A-Za-z0-9]([A-Za-z0-9._-]{0,78}[A-Za-z0-9_])?$') { Exit-InputProblem "landing_zone.connectivity.vpn_gateway.name '$gatewayName' is not a valid name (1 to 80 letters, digits, . _ -; starts with a letter or digit)." }
if (-not $networkName) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway.network is missing. Name the virtual network (an entry of landing_zone.networks) whose GatewaySubnet holds the gateway.' }
if ($AllowedSku -notcontains $sku) { Exit-InputProblem "landing_zone.connectivity.vpn_gateway.sku '$sku' is missing or not allowed. New VPN gateways need an AZ SKU: $($AllowedSku -join ', ')." }
$asn = [uint64]0
if (-not [uint64]::TryParse($asnText, [ref]$asn) -or $asn -lt 1 -or $asn -gt 4294967295) { Exit-InputProblem "landing_zone.connectivity.vpn_gateway.bgp_asn '$asnText' is missing or is not a number from 1 to 4294967295." }
if ($ReservedAsn -contains $asn) { Exit-InputProblem "landing_zone.connectivity.vpn_gateway.bgp_asn $asn is reserved by Azure or IANA. Use a public ASN you own or a private one (64512 to 65514, 65521 to 65534)." }

$network = @($networks | Where-Object { (Get-Entry $_ 'name') -eq $networkName }) | Select-Object -First 1
if (-not $network) { Exit-InputProblem "The network '$networkName' is not an entry of landing_zone.networks, so the subscription and resource group to deploy into are not known." }
$subscriptionName = Get-Entry $network 'subscription'
$subscription = @($subscriptions | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
$subscriptionId = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
if (-not $subscriptionName) { Exit-InputProblem "The network '$networkName' has no subscription in landing_zone.networks." }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem "The subscription '$subscriptionName' of the network '$networkName' has no usable id in landing_zone.subscriptions." }
$networkGroup = Get-Entry $network 'resource_group'
$gatewayGroup = if (Get-Entry $gateway 'resource_group') { Get-Entry $gateway 'resource_group' } else { $networkGroup }
if (-not $networkGroup) { Exit-InputProblem "The network '$networkName' has no resource_group in landing_zone.networks." }
$location = if (Get-Entry $network 'location') { Get-Entry $network 'location' } else { $defaultLocation }
if (-not $location) { Exit-InputProblem "No region: the network '$networkName' has no location and azure.location is empty." }
$generation = if ($sku -eq $Generation1Sku) { 'Generation1' } else { 'Generation2' }
$publicIpName = "$gatewayName-pip"

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzVirtualNetwork', 'Get-AzVirtualNetworkSubnetConfig', 'Get-AzVirtualNetworkGateway', 'Get-AzPublicIpAddress', 'New-AzPublicIpAddress', 'New-AzVirtualNetworkGatewayIpConfig', 'New-AzVirtualNetworkGateway') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Network modules: Install-Module Az.Accounts, Az.Network -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$originalContext = $context
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    Write-Line "VPN gateway '$gatewayName' ($sku, $generation, BGP ASN $asn) in '$gatewayGroup', network '$networkName' ($location)"

    # ---- the gateway may exist already
    $existing = $null
    try { $existing = Get-AzVirtualNetworkGateway -ResourceGroupName $gatewayGroup -Name $gatewayName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The gateway '$gatewayName' could not be read: $($_.Exception.Message)" } }

    $row = [ordered]@{ Gateway = $gatewayName; Action = ''; ProvisioningState = ''; PublicIpName = $publicIpName; PublicIpAddress = ''; Detail = '' }
    if ($existing) {
        $state = if ($existing.PSObject.Properties['ProvisioningState']) { [string]$existing.ProvisioningState } else { '' }
        $row.Action = 'AlreadyExists'; $row.ProvisioningState = $state
        Write-Line "[exists]  The gateway '$gatewayName' is already there (state '$state'), nothing changed."
        $existingSku = if ($existing.PSObject.Properties['Sku'] -and $existing.Sku) { [string]$existing.Sku.Name } else { '' }
        $existingAsn = ''
        if ($existing.PSObject.Properties['BgpSettings'] -and $existing.BgpSettings) { $existingAsn = [string]$existing.BgpSettings.Asn }
        $differs = @()
        if ($existingSku -and $existingSku -ne $sku) { $differs += "SKU is $existingSku, the file says $sku" }
        if ($existingAsn -and $existingAsn -ne [string]$asn) { $differs += "BGP ASN is $existingAsn, the file says $asn" }
        if ($differs.Count) {
            $row.Detail = "Differs from the file ($($differs -join '; ')); left unchanged."
            Write-Warning "${gatewayName}: $($row.Detail)"
        }
        if ($state -and $state -ne 'Succeeded') { Write-Warning "${gatewayName}: the provisioning state is '$state', not 'Succeeded'." }
        $pip = $null
        try { $pip = Get-AzPublicIpAddress -ResourceGroupName $gatewayGroup -Name $publicIpName -ErrorAction Stop } catch { Write-Verbose "No public IP address named $publicIpName read: $($_.Exception.Message)" }
        if ($pip -and $pip.PSObject.Properties['IpAddress']) { $row.PublicIpAddress = [string]$pip.IpAddress }
    }
    else {
        # ---- the network and its GatewaySubnet
        $vnet = $null
        try { $vnet = Get-AzVirtualNetwork -ResourceGroupName $networkGroup -Name $networkName -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The virtual network '$networkName' could not be read: $($_.Exception.Message)" } }
        if (-not $vnet) { Exit-Failed "The virtual network '$networkName' does not exist in '$networkGroup'. Create it first (Deploy-VirtualNetworks.ps1)." }
        $subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet -ErrorAction SilentlyContinue
        if (-not $subnet) { Exit-Failed "The virtual network '$networkName' has no subnet named GatewaySubnet. Add it (at least a /27) to landing_zone.networks and run Deploy-VirtualNetworks.ps1." }
        $prefix = @($subnet.AddressPrefix)[0]
        if ([string]$prefix -notmatch '/(\d+)$' -or [int]$Matches[1] -gt 27) { Exit-Failed "GatewaySubnet is '$prefix'. Microsoft recommends /27 or larger for a VPN gateway; resize it before creating the gateway." }

        # ---- the public IP address: reused when it is there
        $pip = $null
        try { $pip = Get-AzPublicIpAddress -ResourceGroupName $gatewayGroup -Name $publicIpName -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The public IP address '$publicIpName' could not be read: $($_.Exception.Message)" } }
        $createPip = -not $pip
        if ($createPip -and $PSCmdlet.ShouldProcess("public IP address '$publicIpName' in '$gatewayGroup'", 'Create a Standard, static, zone-redundant public IP address')) {
            $pipArgs = @{ ResourceGroupName = $gatewayGroup; Name = $publicIpName; Location = $location; Sku = 'Standard'; AllocationMethod = 'Static'; Zone = @('1', '2', '3'); ErrorAction = 'Stop' }
            if ($tags.Count) { $pipArgs.Tag = $tags }
            $pip = New-AzPublicIpAddress @pipArgs
            Write-Line "[created] Public IP address '$publicIpName'."
        }
        elseif ($createPip) {
            Write-Line "[plan]    Public IP address '$publicIpName' would be created."
        }
        else {
            Write-Line "[exists]  Public IP address '$publicIpName' is reused."
        }

        if ($PSCmdlet.ShouldProcess("VPN gateway '$gatewayName' in '$gatewayGroup'", "Create the gateway ($sku, $generation, BGP ASN $asn); this takes 30 to 45 minutes")) {
            Write-Line 'Creating the gateway; this takes 30 to 45 minutes.'
            $ipConfig = New-AzVirtualNetworkGatewayIpConfig -Name 'default' -SubnetId $subnet.Id -PublicIpAddressId $pip.Id
            $gwArgs = @{
                ResourceGroupName = $gatewayGroup; Name = $gatewayName; Location = $location; IpConfigurations = $ipConfig
                GatewayType = $GatewayType; VpnType = $VpnType; GatewaySku = $sku; VpnGatewayGeneration = $generation
                EnableBgp = $true; Asn = [uint32]$asn; ErrorAction = 'Stop'
            }
            if ($tags.Count) { $gwArgs.Tag = $tags }
            $created = New-AzVirtualNetworkGateway @gwArgs
            $row.Action = 'Created'
            $row.ProvisioningState = if ($created -and $created.PSObject.Properties['ProvisioningState']) { [string]$created.ProvisioningState } else { '' }
            if ($pip -and $pip.PSObject.Properties['IpAddress']) { $row.PublicIpAddress = [string]$pip.IpAddress }
            $fresh = $null
            try { $fresh = Get-AzPublicIpAddress -ResourceGroupName $gatewayGroup -Name $publicIpName -ErrorAction Stop } catch { Write-Verbose "Could not read the public IP address again: $($_.Exception.Message)" }
            if ($fresh -and $fresh.PSObject.Properties['IpAddress'] -and $fresh.IpAddress) { $row.PublicIpAddress = [string]$fresh.IpAddress }
            Write-Line "[created] The gateway '$gatewayName' (state '$($row.ProvisioningState)')."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    The gateway '$gatewayName' would be created (30 to 45 minutes)."
        }
    }
    if ($row.PublicIpAddress) { Write-Line "Gateway public IP address: $($row.PublicIpAddress). Give it to the owner of the on-premises VPN device." }
    [pscustomobject]$row
}
catch {
    Exit-Failed "The gateway '$gatewayName' was not created: $($_.Exception.Message)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}
exit 0
