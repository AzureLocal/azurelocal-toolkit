<#
.SYNOPSIS
    Creates the NAT gateway that landing_zone.connectivity.nat_gateway of infrastructure.yml describes, and puts the listed subnets behind it.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 07 (NAT gateway). Creates a Standard public IP address
    (<gateway name>-pip), the Standard NAT gateway with the TCP idle timeout of the file (Azure default when the file gives none), and then
    attaches the gateway to each subnet of landing_zone.connectivity.nat_gateway.subnets in the virtual network the entry names. It does not create
    the virtual network or its subnets (Deploy-VirtualNetworks.ps1 does).

    Idempotent, and additive. A NAT gateway that exists is reported as AlreadyExists and left alone (a different idle timeout is reported, not
    changed). A subnet that already uses a NAT gateway is reported and left alone, even when it is another one: moving a subnet to another gateway
    interrupts its outbound traffic. An existing public IP address named <gateway name>-pip is reused. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzPublicIpAddress, New-AzNatGateway, Set-AzVirtualNetworkSubnetConfig and
    Set-AzVirtualNetwork, behind -WhatIf. It does not sign in: run Connect-AzAccount to the tenant in azure.tenant_id first. You need Network
    Contributor (or Contributor) on the resource group and on the virtual network. The script changes the subscription of the session while it
    works and puts it back. The tags in the file-level tags map are put on what it creates.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.connectivity.nat_gateway.name, .resource_group, .network, .subnets, .idle_timeout_minutes
        landing_zone.networks[].name, .subscription, .resource_group, .location     where the network is
        landing_zone.subscriptions[].name, .id                                      the subscription that holds the network

    Exit codes: 0 the gateway exists and the listed subnets use it (created now, already there, or planned under -WhatIf), or the file has no NAT
    gateway; 1 an Azure call failed or a precondition failed (not signed in, wrong tenant, Az modules missing, the network is missing, a subnet is
    missing, a creation failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-NatGateway.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created and which subnets would be attached, and changes nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./New-NatGateway.ps1 -InfrastructureFile ./infrastructure.yml

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
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'

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
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzNatGateway', 'New-AzNatGateway', 'Get-AzPublicIpAddress', 'New-AzPublicIpAddress', 'Get-AzVirtualNetwork', 'Set-AzVirtualNetworkSubnetConfig', 'Set-AzVirtualNetwork') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Network modules: Install-Module Az.Accounts, Az.Network -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

$rows = [System.Collections.Generic.List[object]]::new()
try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    Write-Line "NAT gateway '$gatewayName' in '$group' ($location), subnets of '$networkName': $($subnetNames -join ', ')"

    $vnet = $null
    try { $vnet = Get-AzVirtualNetwork -ResourceGroupName $networkGroup -Name $networkName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The virtual network '$networkName' could not be read: $($_.Exception.Message)" } }
    if (-not $vnet) { Exit-Failed "The virtual network '$networkName' does not exist in '$networkGroup'. Create it first (Deploy-VirtualNetworks.ps1)." }
    foreach ($name in $subnetNames) {
        if (-not (@($vnet.Subnets) | Where-Object { $_.Name -eq $name })) { Exit-Failed "The virtual network '$networkName' has no subnet named '$name'. Add it to landing_zone.networks and run Deploy-VirtualNetworks.ps1." }
    }

    # ---- the gateway
    $row = [ordered]@{ Resource = $gatewayName; Kind = 'NatGateway'; Action = ''; Detail = '' }
    $existing = $null
    try { $existing = Get-AzNatGateway -ResourceGroupName $group -Name $gatewayName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The NAT gateway '$gatewayName' could not be read: $($_.Exception.Message)" } }
    $natGateway = $existing
    if ($existing) {
        $row.Action = 'AlreadyExists'
        Write-Line "[exists]  The NAT gateway '$gatewayName' is already there, nothing changed."
        $currentTimeout = if ($existing.PSObject.Properties['IdleTimeoutInMinutes']) { [int]$existing.IdleTimeoutInMinutes } else { 0 }
        if ($timeout -and $currentTimeout -and $currentTimeout -ne $timeout) {
            $row.Detail = "Differs from the file (the idle timeout is $currentTimeout minutes, the file says $timeout); left unchanged."
            Write-Warning "${gatewayName}: $($row.Detail)"
        }
    }
    else {
        $pip = $null
        try { $pip = Get-AzPublicIpAddress -ResourceGroupName $group -Name $publicIpName -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The public IP address '$publicIpName' could not be read: $($_.Exception.Message)" } }
        if (-not $pip -and $PSCmdlet.ShouldProcess("public IP address '$publicIpName' in '$group'", 'Create a Standard, static public IP address')) {
            $pipArgs = @{ ResourceGroupName = $group; Name = $publicIpName; Location = $location; Sku = 'Standard'; AllocationMethod = 'Static'; ErrorAction = 'Stop' }
            if ($tags.Count) { $pipArgs.Tag = $tags }
            $pip = New-AzPublicIpAddress @pipArgs
            Write-Line "[created] Public IP address '$publicIpName'."
        }
        elseif (-not $pip) { Write-Line "[plan]    Public IP address '$publicIpName' would be created." }
        else { Write-Line "[exists]  Public IP address '$publicIpName' is reused." }

        if ($PSCmdlet.ShouldProcess("NAT gateway '$gatewayName' in '$group'", 'Create (Standard)')) {
            $natArgs = @{ ResourceGroupName = $group; Name = $gatewayName; Location = $location; Sku = 'Standard'; PublicIpAddress = $pip; ErrorAction = 'Stop' }
            if ($timeout) { $natArgs.IdleTimeoutInMinutes = $timeout }
            if ($tags.Count) { $natArgs.Tag = $tags }
            $natGateway = New-AzNatGateway @natArgs
            $row.Action = 'Created'
            Write-Line "[created] The NAT gateway '$gatewayName'."
        }
        else {
            $row.Action = 'WouldCreate'
            Write-Line "[plan]    The NAT gateway '$gatewayName' would be created."
        }
    }
    $rows.Add([pscustomobject]$row)

    # ---- the subnets: one write for the network at the end
    $changed = $false
    foreach ($name in $subnetNames) {
        $subnetRow = [ordered]@{ Resource = $name; Kind = 'Subnet'; Action = ''; Detail = '' }
        $subnet = @($vnet.Subnets) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        $current = if ($subnet.PSObject.Properties['NatGateway'] -and $subnet.NatGateway) { [string]$subnet.NatGateway.Id } else { '' }
        if ($current) {
            $subnetRow.Action = 'AlreadyAttached'
            $isOurs = $current -like "*/natGateways/$gatewayName"
            if (-not $isOurs) { $subnetRow.Detail = "The subnet uses another NAT gateway ($current); left unchanged." ; Write-Warning "${name}: $($subnetRow.Detail)" }
            else { Write-Line "[exists]  Subnet '$name' already uses '$gatewayName'." }
        }
        elseif ($natGateway -and $PSCmdlet.ShouldProcess("subnet '$name' of '$networkName'", "Attach NAT gateway '$gatewayName'")) {
            $null = Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $name -AddressPrefix @($subnet.AddressPrefix) -NatGateway $natGateway -ErrorAction Stop
            $subnetRow.Action = 'Attached'
            $changed = $true
            Write-Line "[attached] Subnet '$name' now uses '$gatewayName'."
        }
        else {
            $subnetRow.Action = 'WouldAttach'
            Write-Line "[plan]    Subnet '$name' would use '$gatewayName'."
        }
        $rows.Add([pscustomobject]$subnetRow)
    }
    if ($changed) { $null = Set-AzVirtualNetwork -VirtualNetwork $vnet -ErrorAction Stop }
}
catch {
    Exit-Failed "The NAT gateway '$gatewayName' was not completed: $($_.Exception.Message)"
}
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}

$rows
exit 0
