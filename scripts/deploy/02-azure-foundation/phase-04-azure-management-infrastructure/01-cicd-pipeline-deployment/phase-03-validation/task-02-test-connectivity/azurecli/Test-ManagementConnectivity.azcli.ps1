<#
.SYNOPSIS
    Checks with the Azure CLI the VPN connections, the BGP peers and Azure Bastion that infrastructure.yml describes. Changes nothing.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), CI/CD pipeline deployment, Phase 03 (validation), Task 02 (test connectivity). The Azure side of the
    connectivity tests of the guide, with az commands. One result row per check: Check, Target, Status (Pass or Fail) and Detail.

        VPN connection    for each landing_zone.connectivity.vpn_gateway.site_to_site[] ("az network vpn-connection show"): provisioning state
                          Succeeded and connection status Connected. Connecting is a failure for now: the tunnel and BGP can take 5 to 15 minutes
                          after the connection is created; run the script again.
        BGP peer          for each connection that has peer_bgp_address ("az network vnet-gateway list-bgp-peer-status"): the peer of that address is
                          listed and its state is Connected. The number of routes received is shown in the detail.
        Azure Bastion     landing_zone.connectivity.bastion ("az network bastion show"): provisioning state Succeeded.

    What cannot be tested from Azure is not tested here: a ping to an on-premises address, a Bastion session to a virtual machine and a DNS
    lookup need a machine inside the network (the guide's own tests); this script does not run them.

    The script only reads. It does not sign in: run "az login --tenant <azure.tenant_id>" first. Reader on the subscription is enough. Each az call
    names its subscription with --subscription, so the subscription that az has selected is not changed.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id
        landing_zone.subscriptions[].name, .id                                    the subscription that holds the network
        landing_zone.networks[].name, .subscription, .resource_group              where the network, and so the gateway, is
        landing_zone.connectivity.vpn_gateway.name, .resource_group, .network     the gateway (its resource group, else the one of the network)
        landing_zone.connectivity.vpn_gateway.site_to_site[].connection_name, .peer_bgp_address
        landing_zone.connectivity.bastion.name, .resource_group, .network

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 every check passed; 1 a check failed, an az call failed or a precondition failed (az missing, not signed in, wrong tenant); 2 the
    file describes no connection and no Bastion host, or a value is not usable (a network the file does not list, a subscription without an id).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ManagementConnectivity.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Prints one row for each check and ends with exit code 0 when all of them pass.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..', '..', 'common', 'azure-cli', 'AzlAzureCliArgument.psm1'))) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = '(?i)NotFound|not found|could not be found|does not exist|\b404\b'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# One az call. Returns the text of standard output; throws, with the error text, when az ends with an error (warnings on standard error are dropped).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgument)
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $AzArgument
    if ($unsafe) { Exit-InputProblem $unsafe }
    $all = @(& az @AzArgument 2>&1)
    $code = $LASTEXITCODE
    $errorText = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $text = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) { throw $(if ($errorText -or $text) { (@($errorText, $text) | Where-Object { $_ }) -join ' ' } else { "az ended with exit code $code." }) }
    $text
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.tenant_id')).Trim()
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptionEntries = @(@($rawSubscriptions) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawSubscriptions)) { Exit-InputProblem 'An entry of landing_zone.subscriptions is not a map (names with their settings).' } })
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networkEntries = @(@($rawNetworks) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawNetworks)) { Exit-InputProblem 'An entry of landing_zone.networks is not a map (names with their settings).' } })
$gateway = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.vpn_gateway'
$bastion = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.bastion'

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }

function Get-NetworkPlace([string]$NetworkName, [string]$At) {
    if (-not $NetworkName) { Exit-InputProblem "$At.network is missing. Name the virtual network (an entry of landing_zone.networks)." }
    $network = @($networkEntries | Where-Object { (Get-Entry $_ 'name') -eq $NetworkName }) | Select-Object -First 1
    if (-not $network) { Exit-InputProblem "$At.network '$NetworkName' is not an entry of landing_zone.networks, so the subscription and resource group are not known." }
    $group = Get-Entry $network 'resource_group'
    if (-not $group) { Exit-InputProblem "The network '$NetworkName' has no resource_group in landing_zone.networks." }
    $subscriptionName = Get-Entry $network 'subscription'
    if (-not $subscriptionName) { Exit-InputProblem "The network '$NetworkName' has no subscription in landing_zone.networks." }
    $subscription = @($subscriptionEntries | Where-Object { (Get-Entry $_ 'name') -eq $subscriptionName }) | Select-Object -First 1
    $id = if ($subscription) { Get-Entry $subscription 'id' } else { '' }
    if ($id -notmatch $Guid -or $id -eq [guid]::Empty.ToString()) { Exit-InputProblem "The subscription '$subscriptionName' of the network '$NetworkName' has no usable id in landing_zone.subscriptions." }
    [pscustomobject]@{ SubscriptionId = $id; ResourceGroup = $group }
}

$connections = [System.Collections.Generic.List[object]]::new()
$gatewayName = ''; $gatewayGroup = ''; $gatewaySubscription = ''
if ($gateway -is [System.Collections.IDictionary]) {
    $rawSites = if ($gateway.Contains('site_to_site')) { $gateway['site_to_site'] } else { $null }
    $sites = @(@($rawSites) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_ } elseif ($null -ne ($rawSites)) { Exit-InputProblem 'An entry of landing_zone.connectivity.vpn_gateway.site_to_site is not a map (names with their settings).' } })
    if ($sites.Count -gt 0) {
        $gatewayName = Get-Entry $gateway 'name'
        if (-not $gatewayName) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway.name is missing.' }
        $place = Get-NetworkPlace -NetworkName (Get-Entry $gateway 'network') -At 'landing_zone.connectivity.vpn_gateway'
        $gatewaySubscription = $place.SubscriptionId
        $gatewayGroup = if (Get-Entry $gateway 'resource_group') { Get-Entry $gateway 'resource_group' } else { $place.ResourceGroup }
        $index = -1
        foreach ($site in $sites) {
            $index++
            $name = Get-Entry $site 'connection_name'
            if (-not $name) { Exit-InputProblem "landing_zone.connectivity.vpn_gateway.site_to_site[$index].connection_name is missing." }
            $connections.Add([pscustomobject]@{ Name = $name; BgpAddress = (Get-Entry $site 'peer_bgp_address') })
        }
    }
}
$bastionName = ''; $bastionGroup = ''; $bastionSubscription = ''
if ($bastion -is [System.Collections.IDictionary] -and (Get-Entry $bastion 'name')) {
    $bastionName = Get-Entry $bastion 'name'
    $place = Get-NetworkPlace -NetworkName (Get-Entry $bastion 'network') -At 'landing_zone.connectivity.bastion'
    $bastionSubscription = $place.SubscriptionId
    $bastionGroup = if (Get-Entry $bastion 'resource_group') { Get-Entry $bastion 'resource_group' } else { $place.ResourceGroup }
}
if ($connections.Count -eq 0 -and -not $bastionName) { Exit-InputProblem 'The file describes nothing to test: list landing_zone.connectivity.vpn_gateway.site_to_site or landing_zone.connectivity.bastion.' }

# Every value of the file that goes into an az argument, checked before any Azure call (also under -WhatIf). A name that has its own pattern above is already safe.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{
        'landing_zone.connectivity.vpn_gateway.name' = $gatewayName; 'the resource group of the VPN gateway' = $gatewayGroup
        'landing_zone.connectivity.vpn_gateway.site_to_site connection_name' = @($connections | ForEach-Object { $_.Name })
        'landing_zone.connectivity.bastion.name' = $bastionName; 'the resource group of the Bastion host' = $bastionGroup
    })
if ($problem) { Exit-InputProblem $problem }

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Invoke-TestConnectivity-Orchestrated.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Check, [string]$Target, [bool]$Pass, [string]$Detail = '')
    $rows.Add([pscustomobject][ordered]@{ Check = $Check; Target = $Target; Status = $(if ($Pass) { 'Pass' } else { 'Fail' }); Detail = $Detail })
    Write-Line ('[{0}] {1}: {2}{3}' -f $(if ($Pass) { 'pass' } else { 'FAIL' }), $Check, $Target, $(if ($Detail) { " ($Detail)" } else { '' }))
}
# Reads one resource as JSON; $null when it does not exist.
function Get-Resource([string[]]$AzArgument) {
    try { return (Invoke-Az -AzArgument $AzArgument | ConvertFrom-Json) }
    catch { if ($_.Exception.Message -match $NotFound) { return $null }; throw }
}

Write-Line "Testing $($connections.Count) VPN connection(s)$(if ($bastionName) { ' and the Bastion host' })"

foreach ($connection in $connections) {
    try {
        $resource = Get-Resource @('network', 'vpn-connection', 'show', '--resource-group', $gatewayGroup, '--name', $connection.Name, '--subscription', $gatewaySubscription, '--query', '{status:connectionStatus,state:provisioningState}', '--output', 'json')
        if (-not $resource) { Add-Check -Check 'VPN connection' -Target $connection.Name -Pass $false -Detail 'not found'; continue }
        $problems = [System.Collections.Generic.List[string]]::new()
        if ([string]$resource.state -ne 'Succeeded') { $problems.Add("provisioning state is $($resource.state), not Succeeded") }
        if ([string]$resource.status -ne 'Connected') { $problems.Add("connection status is $($resource.status), not Connected (the tunnel and BGP can take 5 to 15 minutes; run again)") }
        Add-Check -Check 'VPN connection' -Target $connection.Name -Pass ($problems.Count -eq 0) -Detail ($problems -join '; ')
    }
    catch { Add-Check -Check 'VPN connection' -Target $connection.Name -Pass $false -Detail $_.Exception.Message }
}

$bgpConnections = @($connections | Where-Object { $_.BgpAddress })
if ($bgpConnections.Count -gt 0) {
    $peers = $null
    $peerError = ''
    try {
        $peerJson = Invoke-Az -AzArgument @('network', 'vnet-gateway', 'list-bgp-peer-status', '--resource-group', $gatewayGroup, '--name', $gatewayName, '--subscription', $gatewaySubscription, '--output', 'json') | ConvertFrom-Json
        $peers = @(if ($peerJson -and $peerJson.PSObject.Properties['value']) { $peerJson.value } else { $peerJson }) | Where-Object { $_ }
    }
    catch { $peerError = $_.Exception.Message }
    foreach ($connection in $bgpConnections) {
        if ($peerError) { Add-Check -Check 'BGP peer' -Target $connection.BgpAddress -Pass $false -Detail "the peer status of the gateway $gatewayName could not be read: $peerError"; continue }
        $peer = @($peers | Where-Object { [string]$_.neighbor -eq $connection.BgpAddress }) | Select-Object -First 1
        if (-not $peer) { Add-Check -Check 'BGP peer' -Target $connection.BgpAddress -Pass $false -Detail "the gateway $gatewayName lists no peer with this address (connection $($connection.Name))"; continue }
        $routes = if ($peer.PSObject.Properties['routesReceived']) { [string]$peer.routesReceived } else { 'not reported' }
        Add-Check -Check 'BGP peer' -Target $connection.BgpAddress -Pass ([string]$peer.state -eq 'Connected') -Detail "state $($peer.state), routes received: $routes (connection $($connection.Name))"
    }
}

if ($bastionName) {
    try {
        $resource = Get-Resource @('network', 'bastion', 'show', '--resource-group', $bastionGroup, '--name', $bastionName, '--subscription', $bastionSubscription, '--query', '{state:provisioningState}', '--output', 'json')
        if (-not $resource) { Add-Check -Check 'Azure Bastion' -Target $bastionName -Pass $false -Detail 'not found' }
        else { Add-Check -Check 'Azure Bastion' -Target $bastionName -Pass ([string]$resource.state -eq 'Succeeded') -Detail $(if ([string]$resource.state -ne 'Succeeded') { "provisioning state is $($resource.state), not Succeeded" } else { '' }) }
    }
    catch { Add-Check -Check 'Azure Bastion' -Target $bastionName -Pass $false -Detail $_.Exception.Message }
}

$failed = @($rows | Where-Object Status -EQ 'Fail')
Write-Line "Summary: $($rows.Count - $failed.Count) of $($rows.Count) checks passed, $($failed.Count) failed."
$rows
if ($failed.Count -gt 0) { exit 1 }
exit 0
