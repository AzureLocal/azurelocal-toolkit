<#
.SYNOPSIS
    Configures point-to-site VPN on the hub VPN gateway that infrastructure.yml describes, with the Azure CLI.

.DESCRIPTION
    Phase 04 (Azure management infrastructure), manual deployment, Task 04 (point-to-site VPN), Azure CLI variant of Configure-P2sVpn.ps1. It does the
    same with az commands, for a host that has the Azure CLI and not the Az PowerShell modules. It adds the point-to-site configuration of
    landing_zone.connectivity.vpn_gateway.point_to_site to the gateway with "az network vnet-gateway update": the address pool for the clients,
    the tunnel types and the way clients sign in.

        entra_id     Microsoft Entra ID sign-in. The tunnel type is OpenVPN (Microsoft Learn: Configure P2S VPN Gateway for Microsoft Entra ID
                     authentication). The tenant is azure.tenant_id, the audience is the Microsoft-registered Azure VPN Client application of
                     the Azure public cloud, the issuer is https://sts.windows.net/<tenant>/.
        certificate  Certificate sign-in. The root certificate is a public value: root_certificate is a secret reference to its data
                     (the base64 text of the .cer file), root_certificate_name is the name it gets on the gateway. The tunnel types are
                     protocols (default OpenVPN and IkeV2).

    RADIUS is not built here: it needs the server address and its secret, which the file has no key for. The script stops with exit code 2.

    Idempotent, and never destructive. A gateway that has no point-to-site configuration gets it. A gateway that has one is reported as
    AlreadyConfigured when it matches the file, and as different (and left alone) when it does not: changing the client configuration of a
    working gateway is done on purpose, not by this script. -WhatIf changes nothing and does not read the certificate.

    A keyvault://<vault>/<secret> reference of the root certificate is read at run time with "az keyvault secret show" (the vault must be listed
    under key_vaults; you need Key Vault Secrets User on it); env://, file:// and command:// references go through the toolkit's secret resolver.

    The script reads Azure (read only) and writes only with "az network vnet-gateway update", behind -WhatIf. It does not sign in: run
    "az login --tenant <azure.tenant_id>" first. You need Network Contributor (or Contributor) on the gateway's resource group. Every az call
    names its subscription, so the subscription of the az session is not changed. The change of a gateway can take several minutes.
    Give the Azure VPN Client profile to your users from the Azure portal (VPN gateway, Point-to-site configuration, Download VPN client).

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        azure.tenant_id, azure.location, key_vaults[].name (to check the vault of a keyvault:// reference)
        landing_zone.connectivity.vpn_gateway.name, .resource_group, .network            the gateway
        landing_zone.networks[].name, .subscription, .resource_group                     where the network, and so the gateway, is
        landing_zone.subscriptions[].name, .id                                           the subscription that holds the network
        landing_zone.connectivity.vpn_gateway.point_to_site.address_pool, .authentication, .protocols, .root_certificate_name, .root_certificate

    Exit codes: 0 the gateway has the configuration (set now, already there, left as it is and reported, or planned under -WhatIf); 1 an az
    call failed or a precondition failed (az missing, not signed in, wrong tenant, the gateway does not exist, the certificate could
    not be read); 2 a value in the file is missing or not usable.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Configure-P2sVpn.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows what would be set on the gateway, and changes nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Configure-P2sVpn.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Configures point-to-site. Run it again: the gateway is reported as AlreadyConfigured.
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
$Cidr = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)/([0-9]|[12]\d|3[0-2])$'
# The Azure VPN Client application of the Azure public cloud, the audience of Microsoft Entra ID sign-in (Microsoft Learn: Configure P2S VPN Gateway for Microsoft Entra ID authentication).
$AzureVpnClientApplication = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'

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
$gateway = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.connectivity.vpn_gateway'
$rawNetworks = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.networks'
$networks = @(@($rawNetworks) | Where-Object { $_ -is [System.Collections.IDictionary] })
$rawSubscriptions = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'landing_zone.subscriptions'
$subscriptions = @(@($rawSubscriptions) | Where-Object { $_ -is [System.Collections.IDictionary] })

if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($gateway -isnot [System.Collections.IDictionary]) { Exit-InputProblem 'landing_zone.connectivity.vpn_gateway is missing. Describe the gateway (task 02) and its point_to_site settings.' }
$p2s = if ($gateway.Contains('point_to_site')) { $gateway['point_to_site'] } else { $null }
if ($p2s -isnot [System.Collections.IDictionary]) {
    Write-Line 'The file has no landing_zone.connectivity.vpn_gateway.point_to_site: nothing to do.'
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
$group = if (Get-Entry $gateway 'resource_group') { Get-Entry $gateway 'resource_group' } else { Get-Entry $network 'resource_group' }
if (-not $group) { Exit-InputProblem "Neither the gateway nor the network '$networkName' has a resource_group." }

$pool = Get-Entry $p2s 'address_pool'
if ($pool -notmatch $Cidr) { Exit-InputProblem "landing_zone.connectivity.vpn_gateway.point_to_site.address_pool '$pool' is missing or is not an IPv4 range in CIDR form." }
$authentication = Get-Entry $p2s 'authentication'
$rawProtocols = if ($p2s.Contains('protocols')) { $p2s['protocols'] } else { $null }
$protocols = @(@($rawProtocols) | Where-Object { $null -ne $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() })
foreach ($p in $protocols) { if ($p -notin 'OpenVPN', 'IkeV2', 'SSTP') { Exit-InputProblem "point_to_site.protocols: '$p' is not OpenVPN, IkeV2 or SSTP." } }
$certificateName = Get-Entry $p2s 'root_certificate_name'
$certificateReference = Get-Entry $p2s 'root_certificate'
switch ($authentication) {
    'entra_id' {
        if ($protocols.Count -eq 0) { $protocols = @('OpenVPN') }
        if ($protocols.Count -ne 1 -or $protocols[0] -ne 'OpenVPN') { Exit-InputProblem 'point_to_site.protocols: Microsoft Entra ID sign-in works with the OpenVPN tunnel type only.' }
    }
    'certificate' {
        if ($protocols.Count -eq 0) { $protocols = @('OpenVPN', 'IkeV2') }
        if (-not $certificateName) { Exit-InputProblem 'point_to_site.root_certificate_name is missing. It is the name of the root certificate on the gateway.' }
        if (-not $certificateReference) { Exit-InputProblem 'point_to_site.root_certificate is missing. It is a secret reference to the public data of the root certificate.' }
        if (-not (Get-AzlSecretProvider -Reference $certificateReference)) { Exit-InputProblem 'point_to_site.root_certificate is not a secret reference (keyvault://, env://, file:// or command://).' }
    }
    'radius' { Exit-InputProblem 'point_to_site.authentication radius is not built by this script: the file has no key for the RADIUS server and its secret. Use entra_id or certificate.' }
    default { Exit-InputProblem "point_to_site.authentication '$authentication' is missing or not usable. Use entra_id or certificate." }
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use Configure-P2sVpn.ps1.' }
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

$row = [ordered]@{ Gateway = $gatewayName; Authentication = $authentication; Action = ''; Detail = '' }
try {
    $vpnGateway = $null
    try { $vpnGateway = Get-AzCliResource $VnetGatewayCommand[0] $VnetGatewayCommand[1] show --name $gatewayName --resource-group $group --subscription $subscriptionId }
    catch { Exit-Failed "The VPN gateway '$gatewayName' could not be read: $($_.Exception.Message)" }
    if (-not $vpnGateway) { Exit-Failed "The VPN gateway '$gatewayName' does not exist in '$group'. Create it first (Deploy-VpnGateway.ps1)." }

    $currentPool = @(@(Get-JsonValue $vpnGateway 'vpnClientConfiguration.vpnClientAddressPool.addressPrefixes') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $currentProtocols = @(@(Get-JsonValue $vpnGateway 'vpnClientConfiguration.vpnClientProtocols') | Where-Object { $_ } | ForEach-Object { [string]$_ })

    if ($currentPool.Count -gt 0) {
        $differs = [System.Collections.Generic.List[string]]::new()
        if ($currentPool -notcontains $pool -or $currentPool.Count -ne 1) { $differs.Add("the address pool is $($currentPool -join ', '), the file says $pool") }
        if ($currentProtocols.Count -and (Compare-Object -ReferenceObject ($currentProtocols | Sort-Object) -DifferenceObject ($protocols | Sort-Object))) { $differs.Add("the tunnel types are $($currentProtocols -join ', '), the file says $($protocols -join ', ')") }
        if ($differs.Count) {
            $row.Action = 'AlreadyConfigured'
            $row.Detail = 'Differs from the file: ' + ($differs -join '; ') + '. Left unchanged.'
            Write-Warning "${gatewayName}: $($row.Detail)"
        }
        else {
            $row.Action = 'AlreadyConfigured'
            Write-Line "[exists]  The gateway '$gatewayName' already has this point-to-site configuration, nothing changed."
        }
    }
    elseif ($PSCmdlet.ShouldProcess("VPN gateway '$gatewayName' in '$group'", "Configure point-to-site ($authentication, $($protocols -join ' and '), pool $pool)")) {
        $updateArgs = @($VnetGatewayCommand[0], $VnetGatewayCommand[1], 'update', '--name', $gatewayName, '--resource-group', $group, '--subscription', $subscriptionId, '--address-prefixes', $pool, '--client-protocol')
        $updateArgs += @($protocols)
        $certificateData = $null
        if ($authentication -eq 'entra_id') {
            $updateArgs += @('--vpn-auth-type', 'AAD', '--aad-tenant', "https://login.microsoftonline.com/$tenantId", '--aad-issuer', "https://sts.windows.net/$tenantId/", '--aad-audience', $AzureVpnClientApplication)
        }
        else {
            $certificateData = Get-SecretText $certificateReference
            $updateArgs += @('--vpn-auth-type', 'Certificate', '--root-cert-name', $certificateName, '--root-cert-data', $certificateData)
        }
        Write-Line "Configuring point-to-site on '$gatewayName'; this can take several minutes."
        try { $null = Invoke-AzJson @updateArgs }
        catch { throw $(if ($certificateData) { ([string]$_.Exception.Message).Replace($certificateData, '<certificate data>') } else { [string]$_.Exception.Message }) }
        finally { $certificateData = $null; $updateArgs = $null }
        $row.Action = 'Configured'
        Write-Line "[set]     Point-to-site ($authentication) on '$gatewayName'. Give your users the VPN client profile from the Azure portal."
    }
    else {
        $row.Action = 'WouldConfigure'
        Write-Line "[plan]    Point-to-site ($authentication, $($protocols -join ' and '), pool $pool) would be set on '$gatewayName'."
    }
}
catch {
    $row.Action = 'Failed'; $row.Detail = $_.Exception.Message
    Write-Warning "${gatewayName}: $($row.Detail)"
}

[pscustomobject]$row
if ($row.Action -eq 'Failed') { exit 1 }
exit 0
