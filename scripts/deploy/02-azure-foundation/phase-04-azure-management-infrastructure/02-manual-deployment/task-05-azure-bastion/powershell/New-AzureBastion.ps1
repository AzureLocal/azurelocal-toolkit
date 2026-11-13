<#
.SYNOPSIS
    Creates the Azure Bastion host of the hub that infrastructure.yml describes.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 05 (Azure Bastion). Creates the Standard, static public IP address and
    the Bastion host named by landing_zone.connectivity.bastion, in the AzureBastionSubnet of the virtual network it names, with the SKU of the
    file. It does not create the virtual network or the subnet (Deploy-VirtualNetworks.ps1 does: list a subnet named AzureBastionSubnet of /26
    or larger in landing_zone.networks).

    The Bastion features other than the SKU (copy and paste, file copy, IP-based connection, native client, shareable links) and the number of
    scale units are the Azure defaults: change them in the portal when you need them.

    Idempotent. A Bastion host that exists is reported as AlreadyExists and left alone (a different SKU is reported, not changed: Microsoft Learn
    upgrades a SKU in the portal). An existing public IP address named <host name>-pip is reused. -WhatIf changes nothing.

    The script reads Azure (read only) and writes only with New-AzPublicIpAddress and New-AzBastion, behind -WhatIf. It does not sign in: run
    Connect-AzAccount to the tenant in azure.tenant_id first. You need Network Contributor (or Contributor) on the resource group, and read
    access to the virtual network. The script changes the subscription of the session while it works and puts it back. The tags in the
    file-level tags map are put on what it creates. A Bastion host takes about 10 minutes to create and is billed by the hour from then on.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, tags
        landing_zone.connectivity.bastion.name, .resource_group, .sku, .network     the host, its group, its SKU and its virtual network
        landing_zone.networks[].name, .subscription, .resource_group, .location    where the network is
        landing_zone.subscriptions[].name, .id                                     the subscription that holds the network

    Exit codes: 0 the host exists (created now, already there, or planned under -WhatIf), or the file has no Bastion host; 1 an Azure call failed
    or a precondition failed (not signed in, wrong tenant, Az modules missing, the network or its AzureBastionSubnet is missing or smaller
    than /26, the creation failed); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-AzureBastion.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be created, and creates nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    ./New-AzureBastion.ps1 -InfrastructureFile ./infrastructure.yml

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

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|does not exist|\b404\b'
$AllowedSku = 'Basic', 'Standard', 'Premium'

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
$bastion = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.bastion'
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networks = @(@($rawNetworks) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptions = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawTags = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'tags'
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
if (-not $networkName) { Exit-InputProblem 'landing_zone.connectivity.bastion.network is missing. Name the virtual network (an entry of landing_zone.networks) whose AzureBastionSubnet holds the host.' }
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

# ---- preconditions (read only)
foreach ($cmd in 'Get-AzContext', 'Set-AzContext', 'Get-AzVirtualNetwork', 'Get-AzBastion', 'Get-AzPublicIpAddress', 'New-AzPublicIpAddress', 'New-AzBastion') {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { Exit-Failed "$cmd was not found. Install the Az.Accounts and Az.Network modules: Install-Module Az.Accounts, Az.Network -Scope CurrentUser." }
}
$context = Get-AzContext
if (-not $context) { Exit-Failed 'Not signed in to Azure. Run Connect-AzAccount -Tenant <azure.tenant_id>.' }
if ([string]$context.Tenant.Id -ne $tenantId) { Exit-Failed "Signed in to tenant $($context.Tenant.Id), but azure.tenant_id is $tenantId. Sign in to the right tenant." }
$originalContext = $context

try {
    $null = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId -ErrorAction Stop
    Write-Line "Bastion host '$bastionName' ($sku) in '$group', network '$networkName' ($location)"
    $row = [ordered]@{ Bastion = $bastionName; Action = ''; Sku = $sku; PublicIpName = $publicIpName; Detail = '' }

    $existing = $null
    try { $existing = Get-AzBastion -ResourceGroupName $group -Name $bastionName -ErrorAction Stop }
    catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The Bastion host '$bastionName' could not be read: $($_.Exception.Message)" } }

    if ($existing) {
        $row.Action = 'AlreadyExists'
        $existingSku = if ($existing.PSObject.Properties['Sku'] -and $existing.Sku) { [string]$existing.Sku.Name } else { '' }
        Write-Line "[exists]  The Bastion host '$bastionName' is already there, nothing changed."
        if ($existingSku -and $existingSku -ne $sku) {
            $row.Detail = "Differs from the file (the SKU is $existingSku, the file says $sku); left unchanged."
            Write-Warning "${bastionName}: $($row.Detail)"
        }
    }
    else {
        $vnet = $null
        try { $vnet = Get-AzVirtualNetwork -ResourceGroupName $networkGroup -Name $networkName -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The virtual network '$networkName' could not be read: $($_.Exception.Message)" } }
        if (-not $vnet) { Exit-Failed "The virtual network '$networkName' does not exist in '$networkGroup'. Create it first (Deploy-VirtualNetworks.ps1)." }
        $subnet = @($vnet.Subnets) | Where-Object { $_.Name -ceq 'AzureBastionSubnet' } | Select-Object -First 1
        if (-not $subnet) { Exit-Failed "The virtual network '$networkName' has no subnet named AzureBastionSubnet (the name is case sensitive). Add it (/26 or larger) to landing_zone.networks and run Deploy-VirtualNetworks.ps1." }
        $prefix = @($subnet.AddressPrefix)[0]
        if ([string]$prefix -notmatch '/(\d+)$' -or [int]$Matches[1] -gt 26) { Exit-Failed "AzureBastionSubnet is '$prefix'. Azure Bastion needs /26 or larger." }

        $pip = $null
        try { $pip = Get-AzPublicIpAddress -ResourceGroupName $group -Name $publicIpName -ErrorAction Stop }
        catch { if ($_.Exception.Message -notmatch $NotFound) { Exit-Failed "The public IP address '$publicIpName' could not be read: $($_.Exception.Message)" } }
        $createPip = -not $pip
        if ($createPip -and $PSCmdlet.ShouldProcess("public IP address '$publicIpName' in '$group'", 'Create a Standard, static, zone-redundant public IP address')) {
            $pipArgs = @{ ResourceGroupName = $group; Name = $publicIpName; Location = $location; Sku = 'Standard'; AllocationMethod = 'Static'; Zone = @('1', '2', '3'); ErrorAction = 'Stop' }
            if ($tags.Count) { $pipArgs.Tag = $tags }
            $pip = New-AzPublicIpAddress @pipArgs
            Write-Line "[created] Public IP address '$publicIpName'."
        }
        elseif ($createPip) { Write-Line "[plan]    Public IP address '$publicIpName' would be created." }
        else { Write-Line "[exists]  Public IP address '$publicIpName' is reused." }

        if ($PSCmdlet.ShouldProcess("Bastion host '$bastionName' in '$group'", "Create the host ($sku); this takes about 10 minutes")) {
            Write-Line 'Creating the Bastion host; this takes about 10 minutes.'
            $bastionArgs = @{ ResourceGroupName = $group; Name = $bastionName; VirtualNetworkId = $vnet.Id; PublicIpAddressId = $pip.Id; Sku = $sku; ErrorAction = 'Stop' }
            if ($tags.Count) { $bastionArgs.Tag = $tags }
            $null = New-AzBastion @bastionArgs
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
finally {
    if ($originalContext -and $originalContext.PSObject.Properties['Subscription'] -and $originalContext.Subscription -and $originalContext.Subscription.PSObject.Properties['Id']) {
        try { $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -Tenant $tenantId -ErrorAction Stop } catch { Write-Verbose "Could not restore the original subscription context: $($_.Exception.Message)" }
    }
}
exit 0
