#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-cluster verification, category NETWORK (NW-): the file's network intents against the adapters the nodes really have, and the
    node side of the network (management, DNS, outbound path, proxy, drivers, leftovers).

.DESCRIPTION
    Harvested, not written from scratch: azl-toolkit 03-onprem-readiness phase-03-network-infrastructure task-04 Test-NetworkReadiness.ps1
    and task-03 firewall endpoint verification (outbound endpoints), 04-cluster-deployment phase-03-os-configuration task-03/04/05/06/09
    (static IP, DHCP, DNS, unused adapters) and task-13 verification, the toolkit's scripts/validation/network-tests
    Test-NetworkConfiguration.ps1, and Microsoft Learn (azloc-2610) host-network-requirements and cloud-deployment-network-considerations.

    Real failure of the lab that is a check here: the RDMA operational check failed on a MANAGEMENT intent (NW-002): RDMA / Network
    Direct is only for the storage intent; asking for it on an intent whose adapters are not RDMA capable (or not operational) fails
    Network ATC's RDMA operational check after about 40 minutes.

    Contract with the engine: see AzlVerification.NodeCommon.psm1. Read only.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlVerification.NodeCommon.psm1'))

$script:Src = Get-AzlVerConstant Source

function ConvertTo-AzlVerMacKey {
    # A MAC address as 12 lower case hex digits, whatever separator the file or the node uses.
    param([AllowNull()][string]$Mac)
    (([string]$Mac) -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
}

function Format-AzlVerMac {
    param([AllowNull()][string]$Mac)
    $k = ConvertTo-AzlVerMacKey $Mac
    if ($k.Length -eq 12) { return (($k -split '(?<=\G.{2})(?!$)') -join ':').ToUpperInvariant() }
    return $k
}

function Get-AzlVerFilePort {
    <#
    .SYNOPSIS
        The ports of one node as the file spells them (nodes[].network_adapters[]): Name, Mac (normalised), Roles (lower case), Used (any role but unused),
        Slot, SpeedGbps, VlanId, Ip. Nothing here depends on how a vendor or an installer names a port.
    #>
    param($NodeInfo)
    if (-not $NodeInfo) { return @() }
    @(foreach ($a in @($NodeInfo.Adapters)) {
            $roles = @(ConvertTo-AzlVerList (Get-AzlProp $a 'roles' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $vlan = Get-AzlProp $a 'vlan_id' $null
            [pscustomobject]@{
                Name = [string](Get-AzlProp $a 'name' ''); Mac = (ConvertTo-AzlVerMacKey ([string](Get-AzlProp $a 'mac_address' ''))); Roles = $roles
                Used = ($roles.Count -gt 0 -and 'unused' -notin $roles); Slot = [string](Get-AzlProp $a 'slot' ''); SpeedGbps = [double](Get-AzlProp $a 'speed_gbps' 0)
                VlanId = $(if ($null -ne $vlan -and "$vlan" -ne '') { [int]$vlan } else { $null }); Ip = [string](Get-AzlProp $a 'ip_address' '')
            }
        })
}

function Get-AzlVerOsReportMap {
    # node -> (MAC -> OS name) from the OS configuration report in the context, or $null when there is none.
    param([Parameter(Mandatory)]$Context)
    $report = Get-AzlProp $Context 'OsReport'
    if (-not $report) { return $null }
    $map = @{}
    foreach ($n in @(ConvertTo-AzlVerList (Get-AzlProp $report 'nodes' @()))) {
        $byMac = @{}
        foreach ($port in @(ConvertTo-AzlVerList (Get-AzlProp $n 'ports' @()))) {
            $mac = ConvertTo-AzlVerMacKey ([string](Get-AzlProp $port 'mac' ''))
            if ($mac) { $byMac[$mac] = [string](Get-AzlProp $port 'osName' '') }
        }
        $map[[string](Get-AzlProp $n 'name' '')] = $byMac
    }
    return $map
}

function Find-AzlVerNic {
    <#
    .SYNOPSIS
        The NIC of the node's snapshot that a port of the file is. With the node of the file (-Node) and a MAC in the file, by MAC: the file's name and the OS name
        are two different things and may differ per vendor, slot and node. Without a MAC in the file, by name (case insensitive), or $null.
    #>
    param($Nics, [string]$Name, $Node)
    if ($Node) {
        $port = @(Get-AzlVerFilePort $Node | Where-Object { $_.Name -ieq $Name -and $_.Mac }) | Select-Object -First 1
        if ($port) { return (@(ConvertTo-AzlVerList $Nics | Where-Object { (ConvertTo-AzlVerMacKey ([string](Get-AzlProp $_ 'mac' ''))) -eq $port.Mac }) | Select-Object -First 1) }
    }
    @(ConvertTo-AzlVerList $Nics | Where-Object { [string](Get-AzlProp $_ 'n' '') -ieq $Name }) | Select-Object -First 1
}
function Get-AzlVerIntentAdapter {
    param($Intent)
    @($Intent | ForEach-Object { $_.Adapters } | ForEach-Object { $_ })
}

function Get-AzlVerificationCheckDefinition {
    <#
    .SYNOPSIS
        The check definitions of the NETWORK category (NW-001 to NW-013).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The per node script blocks take the one signature (Name, Data, NodeInfo) whether a check needs all three or not.')]
    [CmdletBinding()]
    param()
    $defs = [System.Collections.Generic.List[object]]::new()
    $hasIntents = { param($Context) if (@(Get-AzlVerIntent $Context).Count) { $true } else { $false } }

    $defs.Add((New-AzlVerDefinition -Id 'NW-001' -Category network -Title 'Intents against adapters: every adapter of every intent exists under the same name on every node, link up, at least two per intent' `
                -Source "$($script:Src.HostNet); $($script:Src.NetPlan) (Decision 6, 7); azl-toolkit phase-03-os-configuration task-03 Set-StaticIPAddress / task-13 Task0304_StaticIP" -Run {
                param($Context)
                $intents = @(Get-AzlVerIntent $Context)
                if (-not $intents.Count) { return New-AzlVerResult Failed 'networking.intents is empty: the deployment needs at least one network intent.' 'Define the intents in infrastructure.yml (networking.intents).' }
                $nodeCount = @(Get-AzlVerNodeList $Context).Count
                # File-only findings first, once.
                foreach ($i in $intents) {
                    $count = @($i.Adapters).Count
                    if ($count -eq 0) { New-AzlVerResult Failed "Intent $($i.Name) has no adapter." "Add adapters to networking.intents[$($i.Name)].adapters." -Evidence "intent=$($i.Name)" }
                    elseif ($count -lt 2 -and 'storage' -in $i.Traffic -and $nodeCount -gt 1) { New-AzlVerResult Warning "The storage intent $($i.Name) has one adapter: no fault tolerance (Learn: at least two ports per intent recommended; a storage intent needs at least two for the multi-node storage networks)." "Add a second adapter to networking.intents[$($i.Name)].adapters." -Evidence "adapters=$($i.Adapters -join ',')" }
                    elseif ($count -lt 2) { New-AzlVerResult Warning "Intent $($i.Name) has one adapter (Learn recommends at least two for resiliency)." "Add a second adapter to networking.intents[$($i.Name)].adapters unless this is a deliberate single-port design." -Evidence "adapters=$($i.Adapters -join ',')" }
                }
                $all = @(Get-AzlVerIntentAdapter $intents)
                $dup = @($all | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
                if ($dup) { New-AzlVerResult Failed "Adapter(s) $(Join-AzlVerList $dup) are in more than one intent." 'Each adapter belongs to exactly one intent: fix networking.intents[].adapters.' -Evidence ($dup -join ',') }
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $problems = @()
                    foreach ($i in $intents) {
                        foreach ($a in $i.Adapters) {
                            $nic = Find-AzlVerNic $nics $a $N
                            if (-not $nic) { $problems += "adapter '$a' of intent $($i.Name) does not exist (the node has: $(Join-AzlVerList @($nics | ForEach-Object { $_.n })))" }
                            elseif ([string]$nic.st -ne 'Up') { $problems += "adapter '$a' of intent $($i.Name) is $($nic.st), not Up" }
                        }
                    }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; '). Network ATC takes the adapter names from the deployment, so they must exist and be identical on every node." 'Rename the adapters on the nodes (the OS configuration run maps them by MAC), fix networking.intents[].adapters, and connect the cables of the adapters that are not Up.' -Node $Name -Evidence ($problems -join ' | ') }
                    else { New-AzlVerResult Passed "$Name has all $($all.Count) intent adapters, each Up." -Node $Name -Evidence "adapters=$($all -join ',')" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-002' -Category network -Title 'RDMA (Network Direct) only on the storage intent, on adapters that are RDMA capable; never required on management or compute' `
                -Source "$($script:Src.NetPlan) (Decision 6: Network Direct); $($script:Src.HostNet); lab failure: RDMA operational check failed on a management intent" -Applies $hasIntents -Run {
                param($Context)
                $intents = @(Get-AzlVerIntent $Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $failed = @(); $warned = @(); $ok = 0
                    foreach ($i in $intents) {
                        $isStorage = ('storage' -in $i.Traffic)
                        $wantRdma = Test-AzlVerNetworkDirect $i
                        foreach ($a in $i.Adapters) {
                            $nic = Find-AzlVerNic $nics $a $N
                            if (-not $nic) { continue }   # NW-001 reports it
                            $capable = [bool](Get-AzlProp $nic 'rdmaCapable' $false)
                            $enabled = [bool](Get-AzlProp $nic 'rdmaEnabled' $false)
                            $op = Get-AzlProp $nic 'rdmaOp' $null
                            if ($isStorage) {
                                if ($wantRdma -and -not $capable) { $failed += "storage intent $($i.Name): '$a' ($($nic.desc)) is not RDMA capable (Get-NetAdapterRdma shows none) but Network Direct is on" }
                                elseif (-not $wantRdma) { $warned += "storage intent $($i.Name): Network Direct is off, so storage traffic runs without RDMA (supported but slower)" }
                                else { $ok++ }
                            }
                            else {
                                if ($wantRdma -and -not $capable) { $failed += "intent $($i.Name) ($($i.Traffic -join '+')): Network Direct is Enabled but '$a' ($($nic.desc)) is not RDMA capable, so Network ATC's RDMA operational check fails" }
                                elseif ($wantRdma) { $warned += "intent $($i.Name) ($($i.Traffic -join '+')): RDMA is not needed for $($i.Traffic -join '+') traffic; only the storage intent uses it" }
                                elseif ($enabled -and $op -eq $false) { $warned += "'$a' of intent $($i.Name): RDMA is enabled on the adapter but not operational; set Network Direct to Disabled for this intent so the operational check is not asked" }
                                else { $ok++ }
                            }
                        }
                    }
                    $fix = 'In infrastructure.yml set networking.intents[<management or compute intent>].overrides.adapter.network_direct: false (RDMA belongs to the storage intent only); on the node: Disable-NetAdapterRdma -Name <adapter> for an adapter that is RDMA capable but not needed.'
                    if ($failed) { New-AzlVerResult Failed "${Name}: $($failed -join '; ')." $fix -Node $Name -Evidence ($failed -join ' | ') }
                    elseif ($warned) { New-AzlVerResult Warning "${Name}: $($warned -join '; ')." $fix -Node $Name -Evidence ($warned -join ' | ') }
                    else { New-AzlVerResult Passed "$Name's intents match RDMA: storage adapters are RDMA capable, management and compute ask for none." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-003' -Category network -Title 'Link speed: at least 10 Gbps for compute and storage, the adapters of an intent run at one speed on every node' `
                -Source "$($script:Src.HostNet); $($script:Src.NetPlan) (Decision 6)" -Applies $hasIntents -Run {
                param($Context)
                $intents = @(Get-AzlVerIntent $Context)
                $min = [double](Get-AzlVerSetting $Context 'verificationMinLinkGbps')
                $seen = @{}
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $problems = @(); $warnings = @(); $shown = @()
                    foreach ($i in $intents) {
                        $speeds = @()
                        foreach ($a in $i.Adapters) {
                            $nic = Find-AzlVerNic $nics $a $N
                            if (-not $nic) { continue }
                            $g = [math]::Round([double](Get-AzlProp $nic 'speed' 0) / 1e9, 1)
                            $speeds += $g; $shown += "$a=${g}G"
                            if (-not $seen.ContainsKey($a)) { $seen[$a] = @{} }
                            $seen[$a][$Name] = $g
                            $needs10 = ('storage' -in $i.Traffic) -or ('compute' -in $i.Traffic)
                            if ($needs10 -and $g -lt $min) { $problems += "'$a' of intent $($i.Name) runs at ${g} Gbps (Learn: at least $min Gbps for compute and storage)" }
                            elseif (-not $needs10 -and $g -lt 1) { $warnings += "'$a' of intent $($i.Name) runs at ${g} Gbps" }
                        }
                        if (@($speeds | Select-Object -Unique).Count -gt 1) { $problems += "the adapters of intent $($i.Name) run at different speeds ($($speeds -join ', ') Gbps); Learn: adapters in an intent must be symmetric" }
                    }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; ')." 'Use adapters of the same speed in an intent, at least 10 Gbps for compute and storage; check cables, transceivers and switch ports (Get-NetAdapter | ft Name, LinkSpeed).' -Node $Name -Evidence ($shown -join ',') }
                    elseif ($warnings) { New-AzlVerResult Warning "${Name}: $($warnings -join '; ')." 'Check the cable and the switch port.' -Node $Name -Evidence ($shown -join ',') }
                    else { New-AzlVerResult Passed "$Name's intent adapters run at $($shown -join ', ')." -Node $Name -Evidence ($shown -join ',') }
                }
                foreach ($a in $seen.Keys) { if (@($seen[$a].Values | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Warning "Adapter '$a' runs at different speeds on the nodes: $((@($seen[$a].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)G" })) -join ', ')." 'Use the same adapter model and speed on every node.' -Evidence $a } }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-004' -Category network -Title 'Management network: the management adapter has the file''s address, a static IP and the default gateway, and the gateway and DNS servers answer' `
                -Source "$($script:Src.NetPlan) (Node and cluster IP assignment, DNS server and Management IP pool considerations); azl-toolkit phase-03-os-configuration task-03/04 and task-13 Task0304_StaticIP" -Run {
                param($Context)
                $infra = Get-AzlVerInfra $Context
                $gateway = [string](Get-AzlProp $infra 'networking.management.gateway' '')
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $mgmtIp = [string]$N.ManagementIp
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $problems = @(); $warnings = @()
                    $owner = $null
                    if ($mgmtIp) { $owner = @($nics | Where-Object { $mgmtIp -in @(ConvertTo-AzlVerList (Get-AzlProp $_ 'ips' @())) }) | Select-Object -First 1 }
                    if (-not $mgmtIp) { $problems += 'the file has no management address for this node' }
                    elseif (-not $owner) { $problems += "no adapter holds the management address $mgmtIp of the file (the node has: $(Join-AzlVerList @($nics | ForEach-Object { "$($_.n)=$(@($_.ips) -join '/')" }))" }
                    else {
                        if ([string](Get-AzlProp $owner 'dhcp' '') -eq 'Enabled') { $problems += "DHCP is enabled on '$($owner.n)' (Learn: static addresses for the management network)" }
                        $gw = @(ConvertTo-AzlVerList (Get-AzlProp $owner 'gw' @()))
                        if ($gateway -and $gw.Count -and $gateway -notin $gw) { $problems += "the default gateway of '$($owner.n)' is $($gw -join ', '), the file says $gateway" }
                        elseif ($gateway -and -not $gw.Count) { $problems += "'$($owner.n)' has no default gateway" }
                        if (@($owner.ips).Count -gt 1) { $problems += "'$($owner.n)' has more than one IPv4 address ($(@($owner.ips) -join ', ')); the network validator fails an adapter with two addresses" }
                    }
                    $probes = Get-AzlVerNodeData -Context $Context -Node $Name -Section 'GetProbes'
                    if ($probes.Ok) {
                        $dns = @(ConvertTo-AzlVerList (Get-AzlProp $probes.Data 'tcp' @()) | Where-Object { $_.p -eq 53 })
                        $down = @($dns | Where-Object { -not $_.ok })
                        if ($dns.Count -and $down.Count -eq $dns.Count) { $problems += "no DNS server answers on TCP 53 ($(Join-AzlVerList @($down | ForEach-Object { $_.h })))" }
                        elseif ($down.Count) { $warnings += "DNS server(s) $(Join-AzlVerList @($down | ForEach-Object { $_.h })) do not answer on TCP 53" }
                        $gwp = @(ConvertTo-AzlVerList (Get-AzlProp $probes.Data 'ping' @()) | Where-Object { $_.a -eq $gateway })
                        if ($gwp.Count -and -not $gwp[0].ok) { $warnings += "the default gateway $gateway does not answer ping (the Environment Checker tests ICMP from the management range to the gateway)" }
                    }
                    if ($problems) { New-AzlVerResult Failed "${Name}: $($problems -join '; ')." 'Fix the management adapter with the OS configuration (StaticIp, Dhcp and Dns steps) or the addresses in the file; open DNS (53) and ICMP from the management subnet.' -Node $Name -Evidence ($problems -join ' | ') }
                    elseif ($warnings) { New-AzlVerResult Warning "${Name}: $($warnings -join '; ')." 'Allow ICMP echo on the gateway and TCP 53 to the DNS servers for the management subnet.' -Node $Name -Evidence ($warnings -join ' | ') }
                    else { New-AzlVerResult Passed "$Name holds $mgmtIp on '$($owner.n)' (static, gateway $gateway) and reaches DNS and the gateway." -Node $Name -Evidence "ip=$mgmtIp" }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-005' -Category network -Title 'Nodes reach the documented outbound endpoints (443, and 80 for revocation lists), directly or through the proxy' `
                -Source "$($script:Src.Firewall) (consolidated endpoint list of the region); $($script:Src.EnvChecker) (connectivity validator, RD-002, covers them again); AzlVerification.Endpoints.psm1" `
                -Applies { param($Context) if ([string](Get-AzlProp (Get-AzlVerInfra $Context) 'scenario.connectivity' 'connected') -ne 'connected') { $false } elseif ([string](Get-AzlProp (Get-AzlVerInfra $Context) 'scenario.cloud' 'public') -ne 'public') { 'The documented endpoint lists are for the Azure public cloud; this design uses another cloud (the lists for it are on the Learn firewall page).' } else { $true } } -Run {
                param($Context)
                $set = @(Get-AzlVerEndpointList $Context)
                $location = [string](Get-AzlProp (Get-AzlVerInfra $Context) 'azure.location' '')
                Invoke-AzlVerPerNode -Context $Context -Section 'GetProbes' -Body {
                    param($Name, $D, $N)
                    $web = @(ConvertTo-AzlVerList (Get-AzlProp $D 'https' @()))
                    $tcp = @(ConvertTo-AzlVerList (Get-AzlProp $D 'tcp' @()))
                    $result = foreach ($e in $set) {
                        $row = if ($e.Port -eq 443) { $web | Where-Object { [string]$_.u -eq "https://$($e.Host)" } | Select-Object -First 1 } else { $tcp | Where-Object { [string]$_.h -eq $e.Host -and [int]$_.p -eq $e.Port } | Select-Object -First 1 }
                        [pscustomobject]@{ Host = $e.Host; Port = $e.Port; Tier = $e.Tier; Row = $row }
                    }
                    $missing = @($result | Where-Object { -not $_.Row })
                    if ($missing.Count -eq $result.Count) { return New-AzlVerResult Skipped "$Name returned no endpoint probe." 'Run the verification again; if it persists, run Invoke-AzStackHciConnectivityValidation on the node (RD-002).' -Node $Name }
                    if ($missing.Count) { return New-AzlVerResult Skipped "$Name did not probe $($missing.Count) of $($result.Count) documented endpoint(s) ($(Join-AzlVerList @($missing | Select-Object -First 5 | ForEach-Object { $_.Host }))), so they were not verified." 'Run the verification again.' -Node $Name }
                    $bad = @($result | Where-Object { -not [bool]$_.Row.ok })
                    $badRequired = @($bad | Where-Object { $_.Tier -ne 'Optional' })
                    $shown = { param($list) Join-AzlVerList @($list | ForEach-Object { "$($_.Host):$($_.Port) ($($why = [string](Get-AzlProp $_.Row 'err' ''); if ($why) { $why } else { 'no answer' }))" }) }
                    $note = Format-AzlEndpointNotTested -Location $location
                    $fix = 'Open the endpoints on the firewall or proxy (Learn: Firewall requirements for Azure Local, the consolidated endpoint list of the region); a name that does not resolve needs DNS forwarding to a resolver that answers external names. TLS inspection is not supported.'
                    if ($badRequired.Count) { New-AzlVerResult Failed "$Name cannot reach $($badRequired.Count) of $($result.Count) documented endpoints: $(& $shown $badRequired). $note" $fix -Node $Name -Evidence "failed=$($badRequired.Count) of $($result.Count)" }
                    elseif ($bad.Count) { New-AzlVerResult Warning "$Name cannot reach the optional documented endpoint(s) $(& $shown $bad) (revocation lists, previous URLs and alternatives are optional in the list). $note" $fix -Node $Name }
                    else { New-AzlVerResult Passed "$Name reaches all $($result.Count) documented endpoints. $note" -Node $Name -Evidence "endpoints=$($result.Count)" }
                }
            }))
    $defs.Add((New-AzlVerDefinition -Id 'NW-006' -Category network -Title 'Proxy: the node''s proxy settings follow the file (none for a direct path; the file''s proxy for a proxy path; no PAC, no credentials)' `
                -Source "$($script:Src.NetPlan) (Proxy requirements); $($script:Src.Firewall)" -Run {
                param($Context)
                $infra = Get-AzlVerInfra $Context
                $path = [string](Get-AzlProp $infra 'scenario.outbound_path' 'direct')
                $url = [string](Get-AzlProp $infra 'networking.outbound.proxy.url' '')
                $wantProxy = $path -in 'proxy', 'proxy_arc_gateway'
                if ($wantProxy -and -not $url) { New-AzlVerResult Failed "scenario.outbound_path is $path but networking.outbound.proxy.url is empty." 'Set networking.outbound.proxy.url (for example http://proxy.example.test:3128).' }
                if ($url -match '(?i)\.pac(\?|$)' -or $url -match '@') { New-AzlVerResult Failed 'The proxy URL is a PAC file or carries credentials. Learn: PAC files and authenticated proxies are not supported.' 'Use a plain http://host:port proxy without credentials.' }
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $p = Get-AzlProp $D 'proxy' $null
                    $winhttp = [string](Get-AzlProp $p 'winhttp' '')
                    $direct = ($winhttp -match '(?i)Direct access \(no proxy server\)') -or (-not $winhttp)
                    $envp = (@([string](Get-AzlProp $p 'envHttps' ''), [string](Get-AzlProp $p 'envHttp' '')) | Where-Object { $_ }) -join ','
                    $ie = [string](Get-AzlProp $p 'wininet' '')
                    if (-not $wantProxy) {
                        if (-not $direct -or $envp -or $ie) { New-AzlVerResult Warning "$Name has a proxy set ($(@(if (-not $direct) { 'WinHTTP' }; if ($envp) { 'environment' }; if ($ie) { 'WinINET' }) -join ', ')) but the file's outbound path is $path." 'Clear it if the path is direct: netsh winhttp reset proxy (and remove HTTP(S)_PROXY), or set scenario.outbound_path to proxy.' -Node $Name -Evidence "winhttp=$($winhttp -replace '\s+', ' ') env=$envp wininet=$ie" }
                        else { New-AzlVerResult Passed "$Name uses no proxy, as the direct outbound path says." -Node $Name }
                    }
                    elseif ($url) {
                        $host_ = ([uri]$url).Authority
                        if ($winhttp -notmatch [regex]::Escape($host_)) { New-AzlVerResult Failed "$Name's WinHTTP proxy is not the file's ($url)." "On the node: netsh winhttp set proxy proxy-server=`"$host_`" bypass-list=`"<local>`" (or the OS configuration Proxy step)." -Node $Name -Evidence ($winhttp -replace '\s+', ' ') }
                        else { New-AzlVerResult Passed "$Name's WinHTTP proxy is the file's ($host_)." -Node $Name }
                    }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-007' -Category network -Title 'Cluster service does not exclude adapters (ClusSvc exclusion registry values)' `
                -Source "$($script:Src.HostNet); lab finding (ClusSvc\Parameters Exclude* values)" -Blocking $false -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $ex = Get-AzlProp $D 'clusSvc' $null
                    $values = @()
                    if ($ex -is [System.Collections.IDictionary]) { $values = @($ex.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) }
                    elseif ($ex) { $values = @($ex.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) }
                    if ($values.Count) { New-AzlVerResult Warning "$Name has cluster service adapter exclusions ($($values -join '; ')). An excluded adapter is not used for a cluster network; if it is an intent adapter the storage or management network is missing from the cluster." 'If an intent adapter is excluded, remove the value: Remove-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc\Parameters -Name <ValueName> (then restart the node); keep it only for adapters outside the intents (for example the BMC USB NIC).' -Node $Name -Evidence ($values -join '; ') }
                    else { New-AzlVerResult Passed "$Name excludes no adapter from the cluster service." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-008' -Category network -Title 'Remote NDIS device (BMC USB NIC) is noted and kept out of the way of the management network' `
                -Source "azl-toolkit phase-03-os-configuration task-04 Disable-DHCPOnAllAdapters.ps1 (Remote NDIS keeps DHCP); lab finding" -Blocking $false -Run {
                param($Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $r = @(ConvertTo-AzlVerList (Get-AzlProp $D 'remoteNdis' @()))
                    $excluded = $false
                    $ex = Get-AzlProp $D 'clusSvc' $null
                    if ($ex) { $excluded = ("$(if ($ex -is [System.Collections.IDictionary]) { ($ex.Values -join ';') } else { ($ex.PSObject.Properties | ForEach-Object { $_.Value }) -join ';' })" -match 'Remote NDIS') }
                    if (-not $r.Count) { return New-AzlVerResult Passed "$Name has no Remote NDIS device." -Node $Name }
                    $up = @($r | Where-Object { $_.st -eq 'Up' })
                    if ($up.Count -and -not $excluded) { New-AzlVerResult Warning "$Name has $($up.Count) Remote NDIS device(s) Up ($(Join-AzlVerList @($up | ForEach-Object { $_.n }))), usually the BMC (iDRAC) pass-through NIC with a link-local address. It must not be taken as a management or cluster adapter." 'Leave DHCP on it (the OS configuration does), keep it out of every intent, and if cluster validation complains exclude it: Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc\Parameters -Name ExcludeAdaptersByDescription -Value "Remote NDIS Compatible Device"; or disable it in the iDRAC (OS to iDRAC Pass-through).' -Node $Name -Evidence (($up | ForEach-Object { "$($_.n):$($_.desc)" }) -join ',') }
                    else { New-AzlVerResult Passed "$Name has a Remote NDIS device ($(Join-AzlVerList @($r | ForEach-Object { "$($_.n) $($_.st)" }))); it is $(if ($excluded) { 'excluded from the cluster service' } else { 'not Up' })." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-009' -Category network -Title 'Intent adapters use the OEM driver, not the inbox Microsoft driver' `
                -Source "$($script:Src.NetPlan) (Decision 6); $($script:Src.Install)" -Applies $hasIntents -Run {
                param($Context)
                $intents = @(Get-AzlVerIntent $Context)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $inbox = @()
                    foreach ($i in $intents) { foreach ($a in $i.Adapters) { $nic = Find-AzlVerNic $nics $a $N; if ($nic -and [string](Get-AzlProp $nic 'drvProv' '') -match '^Microsoft') { $inbox += "$a ($($nic.desc), driver $($nic.drvVer))" } } }
                    if ($inbox) { New-AzlVerResult Failed "$Name uses the inbox Microsoft driver on: $($inbox -join '; '). Learn: install the latest OEM driver before configuring networking; important capabilities may not surface with the inbox driver." 'Install the OEM driver (pnputil /add-driver <inf> /install, or the OS configuration Drivers step from an SBE), then restart.' -Node $Name -Evidence ($inbox -join '; ') }
                    else { New-AzlVerResult Passed "$Name's intent adapters use vendor drivers." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-010' -Category network -Title 'No Network ATC intent and no stray virtual switch left from an earlier attempt' `
                -Source "config/known-issues/arm-deployment.json (vmswitch-not-bound); $($script:Src.NetPlan)" -Applies $hasIntents -Run {
                param($Context)
                $intents = @(Get-AzlVerIntent $Context)
                $mine = @(Get-AzlVerIntentAdapter $intents)
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $vms = Get-AzlProp $D 'vms' $null
                    $atc = @(ConvertTo-AzlVerList (Get-AzlProp $vms 'intents' @()))
                    $switches = @(ConvertTo-AzlVerList (Get-AzlProp $vms 'switches' @()))
                    if ($atc.Count) { return New-AzlVerResult Failed "$Name already has Network ATC intent(s): $($atc -join ', '). The deployment creates the intents; existing ones conflict (an earlier deployment, or manual intents)." 'On a machine that is being redeployed: Get-NetIntent | Remove-NetIntent' -Node $Name -Evidence ($atc -join ',') }
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $uses = @($switches | Where-Object { $sw = $_; @($nics | Where-Object { $mine -contains $_.n -and (@($sw.uplinks) -contains $_.desc) }).Count })
                    if ($uses.Count) { return New-AzlVerResult Warning "$Name has virtual switch(es) $(Join-AzlVerList @($uses | ForEach-Object { $_.n })) on intent adapters. A switch left by a failed validation makes the next one fail ('not bound to the management virtual switch'); a switch pre-created for a DHCP management setup is fine." 'If it is a leftover: Remove-VMSwitch -Name <name> -Force; Restart-Service DeviceManagementService.' -Node $Name -Evidence (($uses | ForEach-Object { $_.n }) -join ',') }
                    New-AzlVerResult Passed "$Name has no Network ATC intent and no virtual switch on the intent adapters." -Node $Name
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-011' -Category network -Title 'Unused adapters that are disconnected are disabled' `
                -Source "azl-toolkit phase-03-os-configuration task-09 Disable-UnusedAdapters.ps1 / task-13 Task09_Adapters" -Blocking $false -Run {
                param($Context)
                $mine = @(Get-AzlVerIntentAdapter @(Get-AzlVerIntent $Context))
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $still = @($nics | Where-Object { [string]$_.st -eq 'Disconnected' -and [string](Get-AzlProp $_ 'admin' 'Up') -eq 'Up' -and $_.n -notin $mine })
                    if ($still.Count) { New-AzlVerResult Warning "$Name has $($still.Count) disconnected adapter(s) that are still enabled: $(Join-AzlVerList @($still | ForEach-Object { $_.n })). Network ATC and the cluster can pick up an unused port." ('Disable-NetAdapter -Name ' + (($still | ForEach-Object { "'$($_.n)'" }) -join ',') + ' -Confirm:$false (or the OS configuration DisableAdapters step)') -Node $Name -Evidence (($still | ForEach-Object { $_.n }) -join ',') }
                    else { New-AzlVerResult Passed "$Name has no disconnected adapter left enabled." -Node $Name }
                }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-012' -Category network -Title 'Jumbo frames only for storage, the same MTU setting for an adapter on all nodes' `
                -Source "$($script:Src.NetPlan) (Decision 6: Jumbo Packets)" -Blocking $false -Applies $hasIntents -Run {
                param($Context)
                $intents = @(Get-AzlVerIntent $Context)
                $mtus = @{}
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $warn = @()
                    foreach ($i in $intents) {
                        foreach ($a in $i.Adapters) {
                            $nic = Find-AzlVerNic $nics $a $N
                            if (-not $nic) { continue }
                            $j = [string](Get-AzlProp $nic 'jumbo' '')
                            if (-not $mtus.ContainsKey($a)) { $mtus[$a] = @{} }
                            $mtus[$a][$Name] = $j
                            if ($j -match '^\d+$' -and [int]$j -gt 1514 -and 'storage' -notin $i.Traffic) { $warn += "'$a' of intent $($i.Name) has jumbo packets ($j) but carries no storage traffic" }
                        }
                    }
                    if ($warn) { New-AzlVerResult Warning "${Name}: $($warn -join '; ')." 'Jumbo frames are for the storage intent (the switch ports must match); leave the default elsewhere.' -Node $Name -Evidence ($warn -join ' | ') }
                    else { New-AzlVerResult Passed "$Name has jumbo frames only where storage traffic runs." -Node $Name }
                }
                foreach ($a in $mtus.Keys) { if (@($mtus[$a].Values | Select-Object -Unique).Count -gt 1) { New-AzlVerResult Warning "Adapter '$a' has different jumbo packet values on the nodes: $((@($mtus[$a].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })) -join ', ')." 'Set the same value on every node (Network ATC applies one per intent).' -Evidence $a } }
            }))

    $defs.Add((New-AzlVerDefinition -Id 'NW-013' -Category network -Title 'Physical ports against the file, per node: every used port of the file is a real NIC (found by MAC), Up, at speed, not virtual, with one OS name on every node; intents and storage networks point at them' `
                -Source "$($script:Src.HostNet); $($script:Src.NetPlan) (Decision 6, 7); the file: nodes[].network_adapters, networking.intents[].adapters, networking.cluster_networks[]" -Run {
                param($Context)
                $infra = Get-AzlVerInfra $Context
                $intents = @(Get-AzlVerIntent $Context)
                $min = [double](Get-AzlVerSetting $Context 'verificationMinLinkGbps')
                $arch = Get-AzlVerArchitecture $Context
                $clusterNets = @(ConvertTo-AzlVerList (Get-AzlProp $infra 'networking.cluster_networks' @()))
                $mgmtVlan = Get-AzlProp $infra 'networking.management.vlan_id' $null
                $reportMap = Get-AzlVerOsReportMap $Context
                $osNames = @{}
                # File only: no adapter in two intents (the same adapter name may appear once in the file's intents).
                $dup = @(Get-AzlVerIntentAdapter $intents | Group-Object { $_.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group[0] })
                if ($dup.Count) { New-AzlVerResult Failed "Adapter(s) $(Join-AzlVerList $dup) are in more than one intent of the file." 'Each adapter belongs to exactly one intent: fix networking.intents[].adapters.' -Evidence ($dup -join ',') }
                Invoke-AzlVerPerNode -Context $Context -Section 'GetAdapters' -Body {
                    param($Name, $D, $N)
                    $nics = @(ConvertTo-AzlVerList (Get-AzlProp $D 'nics' @()))
                    $ndis = @(ConvertTo-AzlVerList (Get-AzlProp $D 'remoteNdis' @()) | ForEach-Object { [string](Get-AzlProp $_ 'n' '') } | Where-Object { $_ })
                    $ports = @(Get-AzlVerFilePort $N)
                    if (-not $ports.Count) { return New-AzlVerResult Skipped "The file lists no network_adapters for $Name, so its ports cannot be compared with the node." 'Fill nodes[].network_adapters (name, mac_address, roles) in the file.' -Node $Name }
                    $failed = [System.Collections.Generic.List[string]]::new(); $unread = [System.Collections.Generic.List[string]]::new(); $warn = [System.Collections.Generic.List[string]]::new()
                    $byName = @{}; foreach ($p in $ports) { $byName[$p.Name.ToLowerInvariant()] = $p }
                    $inIntent = @{}   # lower file name -> intent
                    foreach ($i in $intents) { foreach ($a in $i.Adapters) { $inIntent[$a.ToLowerInvariant()] = $i } }
                    $rows = [System.Collections.Generic.List[string]]::new()
                    $resolved = @{}
                    foreach ($p in @($ports | Where-Object Used)) {
                        if (-not $p.Mac) { $unread.Add("file port '$($p.Name)' has no mac_address, so it cannot be matched to a NIC of $Name"); $rows.Add("file '$($p.Name)' | MAC (none in the file) | OS name ? | link ? | roles $($p.Roles -join '+')"); continue }
                        $nic = Find-AzlVerNic $nics $p.Name $N
                        if (-not $nic) {
                            $failed.Add("file port '$($p.Name)' (MAC $(Format-AzlVerMac $p.Mac)) is not on the node: no physical NIC has that MAC (the node has $(Join-AzlVerList @($nics | ForEach-Object { "$($_.n)=$(Format-AzlVerMac (Get-AzlProp $_ 'mac' ''))" })))")
                            $rows.Add("file '$($p.Name)' | MAC $(Format-AzlVerMac $p.Mac) | NOT ON THE NODE | roles $($p.Roles -join '+')"); continue
                        }
                        $resolved[$p.Name] = $nic
                        $os = [string]$nic.n
                        if (-not $osNames.ContainsKey($p.Name.ToLowerInvariant())) { $osNames[$p.Name.ToLowerInvariant()] = @{ File = $p.Name; Nodes = @{} } }
                        $osNames[$p.Name.ToLowerInvariant()].Nodes[$Name] = $os
                        if ([string]$nic.desc -match '(?i)remote ndis|rndis|\busb\b|virtual|vethernet|multiplexor|wi-?fi|bluetooth' -or $os -in $ndis) { $failed.Add("file port '$($p.Name)' resolves to '$os' ($($nic.desc)), which is a virtual, USB or Remote NDIS device, not a physical port") }
                        if ($reportMap) {
                            if ($reportMap.ContainsKey($Name) -and $reportMap[$Name].ContainsKey($p.Mac)) {
                                if ([string]$reportMap[$Name][$p.Mac] -cne $os) { $failed.Add("file port '$($p.Name)': the node calls the NIC '$os' but the OS configuration report says '$($reportMap[$Name][$p.Mac])' (the deployment uses the report's name; run the OS configuration again or read the node again)") }
                            }
                            else { $unread.Add("the OS configuration report has no port with MAC $(Format-AzlVerMac $p.Mac) for $Name, so the name the deployment will use was not compared") }
                        }
                        $mine = $inIntent[$p.Name.ToLowerInvariant()]
                        $g = [math]::Round([double](Get-AzlProp $nic 'speed' 0) / 1e9, 1)
                        $up = ([string]$nic.st -eq 'Up')
                        if (-not $up) {
                            $why = "file port '$($p.Name)' ('$os') is $($nic.st), not Up$(if ($mine) { " (it is in intent $($mine.Name))" })"
                            if ($mine) { $failed.Add($why) } else { $warn.Add($why) }
                        }
                        if ($up -and $mine) {
                            $need = if (('storage' -in $mine.Traffic) -or ('compute' -in $mine.Traffic)) { $min } else { 1 }
                            if ($g -lt $need) { $failed.Add("file port '$($p.Name)' ('$os') runs at $g Gbps; intent $($mine.Name) ($($mine.Traffic -join '+')) needs at least $need Gbps") }
                        }
                        if ($up -and $p.SpeedGbps -gt 0 -and $g -gt 0 -and $g -lt ($p.SpeedGbps * 0.9)) { $warn.Add("file port '$($p.Name)' ('$os') runs at $g Gbps, the file says $($p.SpeedGbps) Gbps") }
                        $vlan = Get-AzlProp $nic 'vlan' $null
                        $rows.Add("file '$($p.Name)' | MAC $(Format-AzlVerMac $p.Mac) | OS '$os' | $($nic.st) | ${g}G | roles $($p.Roles -join '+') | intent $(if ($mine) { $mine.Name } else { '-' })$(if ($null -ne $vlan -and "$vlan" -ne '') { " | VLAN $vlan" })")
                    }
                    if (-not $reportMap) { $unread.Add('no OS configuration report was given, so the names the deployment will use were not compared with the node') }
                    # Speed of the ports of one intent is one speed.
                    foreach ($i in $intents) {
                        $sp = @($i.Adapters | Where-Object { $resolved.ContainsKey($_) -or ($byName.ContainsKey($_.ToLowerInvariant()) -and $resolved.ContainsKey($byName[$_.ToLowerInvariant()].Name)) } | ForEach-Object { $key = if ($resolved.ContainsKey($_)) { $_ } else { $byName[$_.ToLowerInvariant()].Name }; [math]::Round([double](Get-AzlProp $resolved[$key] 'speed' 0) / 1e9, 1) })
                        if (@($sp | Select-Object -Unique).Count -gt 1) { $failed.Add("the ports of intent $($i.Name) run at different speeds ($($sp -join ', ') Gbps); adapters in an intent must be symmetric") }
                    }
                    # Intents point at ports of this node, and the roles agree.
                    foreach ($i in $intents) {
                        foreach ($a in $i.Adapters) {
                            if (-not $byName.ContainsKey($a.ToLowerInvariant())) { $failed.Add("intent $($i.Name) names '$a', which the file does not list for $Name"); continue }
                            $p = $byName[$a.ToLowerInvariant()]
                            if (-not $p.Used) { $failed.Add("intent $($i.Name) uses '$a', but the file marks that port unused"); continue }
                            $lacking = @($i.Traffic | Where-Object { $_ -in 'management', 'compute', 'storage' -and $_ -notin $p.Roles })
                            if ($lacking.Count) { $failed.Add("port '$a' is in intent $($i.Name) (traffic $($i.Traffic -join '+')) but the file gives it the roles $($p.Roles -join '+'), without $($lacking -join '+')") }
                        }
                    }
                    foreach ($p in @($ports | Where-Object Used)) {
                        foreach ($r in @($p.Roles | Where-Object { $_ -in 'management', 'compute', 'storage' })) {
                            $carrier = $inIntent[$p.Name.ToLowerInvariant()]
                            if (-not $carrier -or $r -notin $carrier.Traffic) { $failed.Add("port '$($p.Name)' has the role $r in the file but is in no intent that carries $r") }
                        }
                    }
                    # Storage networks (networking.cluster_networks): on ports of this node; in the storage intent unless the design keeps them on standalone SAN ports.
                    foreach ($cn in $clusterNets) {
                        $a = [string](Get-AzlProp $cn 'adapter' '')
                        if (-not $a) { continue }
                        $cnName = [string](Get-AzlProp $cn 'name' $a)
                        if (-not $byName.ContainsKey($a.ToLowerInvariant())) { $failed.Add("storage network '$cnName' names the adapter '$a', which the file does not list for $Name"); continue }
                        $p = $byName[$a.ToLowerInvariant()]
                        $carrier = $inIntent[$a.ToLowerInvariant()]
                        $storageIntent = @($intents | Where-Object { 'storage' -in $_.Traffic })
                        if ($arch -ne 'san' -and $storageIntent.Count -and (-not $carrier -or 'storage' -notin $carrier.Traffic)) { $failed.Add("storage network '$cnName' is on '$a', which is not a port of the storage intent") }
                        $fv = Get-AzlProp $cn 'vlan_id' $null
                        if ($null -ne $fv -and $null -ne $p.VlanId -and [int]$fv -ne [int]$p.VlanId) { $failed.Add("storage network '$cnName' says VLAN $fv, the file's port '$a' says VLAN $($p.VlanId)") }
                        if ($resolved.ContainsKey($p.Name)) {
                            $live = Get-AzlProp $resolved[$p.Name] 'vlan' $null
                            if ($null -ne $fv -and $null -ne $live -and "$live" -ne '' -and [int]$live -ne 0 -and [int]$live -ne [int]$fv) { $warn.Add("storage network '$cnName': the node's '$($resolved[$p.Name].n)' carries VLAN $live now, the file says $fv (the deployment sets it)") }
                        }
                    }
                    # The management port holds the management address of the file.
                    if ($N.ManagementIp) {
                        $holder = @($nics | Where-Object { $N.ManagementIp -in @(ConvertTo-AzlVerList (Get-AzlProp $_ 'ips' @())) }) | Select-Object -First 1
                        $mgmtPort = @($ports | Where-Object { $_.Used -and 'management' -in $_.Roles -and $_.Ip -eq $N.ManagementIp }) | Select-Object -First 1
                        if (-not $holder) { $failed.Add("no NIC of $Name holds the management address $($N.ManagementIp) of the file") }
                        elseif ($mgmtPort -and $mgmtPort.Mac -and (ConvertTo-AzlVerMacKey (Get-AzlProp $holder 'mac' '')) -ne $mgmtPort.Mac) { $failed.Add("the management address $($N.ManagementIp) is on '$($holder.n)', but the file puts it on port '$($mgmtPort.Name)' (MAC $(Format-AzlVerMac $mgmtPort.Mac))") }
                        if ($mgmtPort -and $resolved.ContainsKey($mgmtPort.Name) -and $null -ne $mgmtVlan -and "$mgmtVlan" -ne '' -and [int]$mgmtVlan -ne 0) {
                            $live = Get-AzlProp $resolved[$mgmtPort.Name] 'vlan' $null
                            if ($null -ne $live -and "$live" -ne '' -and [int]$live -ne [int]$mgmtVlan) { $warn.Add("the management port '$($resolved[$mgmtPort.Name].n)' carries VLAN $live, the file says $mgmtVlan") }
                        }
                    }
                    $table = $rows -join "`n"
                    $fixPorts = 'Compare the file with the node: Get-NetAdapter -Physical | ft Name, MacAddress, Status, LinkSpeed. Fix nodes[].network_adapters[].mac_address and the names in networking.intents[].adapters, replug or enable the port, and run the OS configuration so the names agree (it finds ports by MAC).'
                    if ($failed.Count) { New-AzlVerResult Failed "${Name}: $($failed -join '; ').`n$table" $fixPorts -Node $Name -Evidence ($failed -join ' | ') }
                    elseif ($unread.Count) { New-AzlVerResult Skipped "${Name}: not everything could be compared: $($unread -join '; ').`n$table" 'Give every used port its mac_address in the file, and the OS configuration report (-OsConfigurationReport), then run the verification again.' -Node $Name }
                    elseif ($warn.Count) { New-AzlVerResult Warning "${Name}: $($warn -join '; ').`n$table" $fixPorts -Node $Name -Evidence ($warn -join ' | ') }
                    else { New-AzlVerResult Passed "$Name's $(@($resolved.Keys).Count) used port(s) are the file's, by MAC:`n$table" -Node $Name -Evidence "ports=$(@($resolved.Keys).Count)" }
                }
                # Across the nodes: the same file port is the same OS adapter name everywhere (Network ATC takes the names from the deployment).
                foreach ($k in $osNames.Keys) {
                    $entry = $osNames[$k]
                    if (@($entry.Nodes.Values | Select-Object -Unique).Count -gt 1) {
                        New-AzlVerResult Failed "File port '$($entry.File)' is $((@($entry.Nodes.GetEnumerator() | Sort-Object Name | ForEach-Object { "'$($_.Value)' on $($_.Key)" })) -join ', '). Network ATC needs the same adapter name on every node." 'Rename the adapters on the nodes so the same file port has the same OS name everywhere (the OS configuration run maps them by MAC), or fix the MAC in the file.' -Evidence "port=$($entry.File)"
                    }
                }
            }))

    return $defs.ToArray()
}

function Get-AzlVerificationAdapterDefault {
    <#
    .SYNOPSIS
        The real, read only adapter members of the NETWORK checks: Remote.Invoke and the Node.* members they read (one remote call
        per node, cached in the Context). The engine merges them with the other categories' members; tests replace any of them.
    #>
    [CmdletBinding()]
    param([pscredential]$Credential, [hashtable]$Address = @{}, [switch]$UseSsl, [string]$Authentication = 'Default')
    @{
        Remote = @{ Invoke = (New-AzlVerRemoteDefault -Credential $Credential -Address $Address -UseSsl:$UseSsl -Authentication $Authentication) }
        Node   = (New-AzlVerNodeAdapterDefault)
    }
}

Export-ModuleMember -Function Get-AzlVerificationCheckDefinition, Get-AzlVerificationAdapterDefault
