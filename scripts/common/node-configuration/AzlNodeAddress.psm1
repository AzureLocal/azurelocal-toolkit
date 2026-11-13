#Requires -Version 7.0
<#
.SYNOPSIS
    Finds the CURRENT management address of a node for the OS configuration: the address it answers on now, which is often not the one
    in the master file (a node installed from an ISO sits on a DHCP address until the Network step gives it the planned one).

.DESCRIPTION
    Resolve-AzlNodeAddress tries these sources in order, first match wins, and names the source it used:

      1. override             -NodeAddress / the nodeAddress run setting. Final: if it does not answer, no other source is used
                              (credentials never go to an address the operator did not give), and the result says so.
      2. ztp-handoff          the adapters of the node's ZTP handoff (networkAdapters[], each with ipAddress and macAddress), matched
                              by the management MAC from infrastructure.yml. ZTP nodes only.
      3. arc                  the network profile the Arc agent reports for the node's Arc machine, matched by the management MAC.
      4. infrastructure-file  the management IP in infrastructure.yml (and maintenance_address). A manual install done with the
                              planned static IP is found here.
      5. mac-lookup           from the orchestrator: the neighbor table (Get-NetNeighbor, else arp -a) matched to the management MAC.
                              When the table has no entry yet, a bounded ping sweep of the management subnet from the file fills it
                              (ARP is answered even when the node blocks ICMP). Only on a machine that is on that subnet, because only
                              then does it share the layer-2 segment with the node; otherwise the result says so. A subnet wider than
                              /22 is refused unless the run setting addressResolution.allowWideSubnet is true. Never outside that subnet.
      6. none                 nothing answered: Message names what was tried and asks for the address (the run stops with exit code 2).

    Every candidate of steps 2-5 is probed (TCP 5985, then 5986). Of the ones that answer, LIVE evidence ranks above historic:
      rank 0  an address the Arc machine reports while it is Connected, or one that two sources agree on
      rank 1  an address one source reports: the Arc machine (not Connected), the infrastructure file, the MAC lookup
      rank 2  an address only the ZTP handoff reports (historic data: a DHCP lease that may belong to another machine by now)
    Within a rank the order above decides. When several answer the result says which ones and why that one was chosen, and
    Agreement says what each source reported, so a stale handoff is visible ('handoff says .117, Arc says .11'). A candidate
    that does not answer stays in Candidates, behind the ones that do, so the caller's own reachability handling (the one-time
    bootstrap) still sees it.

    An address that answers is not yet proven to be THE node. Select-AzlVerifiedNodeAddress reads the node's computer name and
    adapter MACs over the first authenticated connection (Read-AzlNodeIdentity, a read-only node script) and compares them with the
    file (Test-AzlNodeIdentity): a machine that is not this node is dropped and the next candidate is tried; if none proves the
    identity the caller stops (exit 2) with a message that names what answered where. The override is final but identity-checked too.

    Nothing here sends a credential: the probes are TCP connects only. The module changes nothing on any node or in Azure; the sweep
    sends ICMP echo requests inside the management subnet, and nothing else leaves this machine. IPv4 only.

    Seams for tests (Pester mocks them with -ModuleName AzlNodeAddress): Test-AzlAddressPort, Get-AzlLocalIPv4Network,
    Get-AzlNeighborEntry, Invoke-AzlSubnetSweep.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'infrastructure' 'AzlInfrastructure.psm1'))
Import-Module (Join-Path $PSScriptRoot 'AzlNodePayload.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeTransport.psm1')

# A subnet wider than this is not swept unless addressResolution.allowWideSubnet is set (a /22 is 1022 addresses).
$script:MaxSweepPrefixLength = 22
$script:WinRmPort = @(5985, 5986)

# ---------------------------------------------------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlAddressMacKey {
    <#
    .SYNOPSIS
        12 lower-case hex digits for a MAC written with ':', '-', '.' or no separator, including macOS's unpadded octets
        (0:0:5e:0:53:10). $null when the text is not a MAC.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $text = $Mac.Trim()
    if ($text -match '^[0-9a-fA-F]{1,2}([:-][0-9a-fA-F]{1,2}){5}$') {
        $text = (($text -split '[:-]') | ForEach-Object { $_.PadLeft(2, '0') }) -join ''
    }
    else { $text = $text -replace '[-:\.\s]', '' }
    if ($text -notmatch '^[0-9a-fA-F]{12}$') { return $null }
    return $text.ToLowerInvariant()
}

function ConvertTo-AzlIPv4Number {
    # An IPv4 address as a number (long), or $null when the text is not a dotted-quad.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address) -or $Address.Trim() -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $null }
    $octets = @(1..4 | ForEach-Object { [long]$Matches[$_] })
    if (@($octets | Where-Object { $_ -gt 255 }).Count) { return $null }
    return ((($octets[0] * 256 + $octets[1]) * 256 + $octets[2]) * 256 + $octets[3])
}

function ConvertFrom-AzlIPv4Number {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][long]$Number)
    return "$(($Number -shr 24) -band 255).$(($Number -shr 16) -band 255).$(($Number -shr 8) -band 255).$($Number -band 255)"
}

function ConvertFrom-AzlCidr {
    <#
    .SYNOPSIS
        Network, Prefix, First and Last host (as numbers), Count and Text for an IPv4 CIDR ('192.0.2.0/24'). $null when it isn't one.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Cidr)
    if ([string]::IsNullOrWhiteSpace($Cidr) -or $Cidr.Trim() -notmatch '^(?<ip>[\d\.]+)/(?<len>\d{1,2})$') { return $null }
    $ip = ConvertTo-AzlIPv4Number -Address $Matches['ip']
    $len = [int]$Matches['len']
    if ($null -eq $ip -or $len -gt 32) { return $null }
    $mask = if ($len -eq 0) { [long]0 } else { ([long]4294967295 -shl (32 - $len)) -band [long]4294967295 }
    $network = $ip -band $mask
    $broadcast = $network -bor ([long]4294967295 -bxor $mask)
    # /31 and /32 have no network or broadcast address to leave out.
    $first = if ($len -ge 31) { $network } else { $network + 1 }
    $last = if ($len -ge 31) { $broadcast } else { $broadcast - 1 }
    [pscustomobject]@{ Network = $network; Prefix = $len; First = $first; Last = $last; Count = ($last - $first + 1); Text = "$(ConvertFrom-AzlIPv4Number $network)/$len" }
}

function Test-AzlAddressInCidr {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][object]$Subnet)
    $n = ConvertTo-AzlIPv4Number -Address $Address
    if ($null -eq $n) { return $false }
    $mask = if ($Subnet.Prefix -eq 0) { [long]0 } else { ([long]4294967295 -shl (32 - $Subnet.Prefix)) -band [long]4294967295 }
    return (($n -band $mask) -eq $Subnet.Network)
}

function ConvertFrom-AzlArpOutput {
    <#
    .SYNOPSIS
        Parses the text of `arp -a` (Windows, Linux or macOS) into IPAddress and Mac (12 hex digits) rows. Incomplete entries are left out.
    #>
    [CmdletBinding()]
    param([AllowNull()][string[]]$Line)
    foreach ($text in @($Line)) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $ip = $null; $mac = $null
        if ($text -match '^\s*(?<ip>\d{1,3}(?:\.\d{1,3}){3})\s+(?<mac>[0-9a-fA-F]{1,2}(?:[-:][0-9a-fA-F]{1,2}){5})\s+\S+') { $ip = $Matches['ip']; $mac = $Matches['mac'] }
        elseif ($text -match '\((?<ip>\d{1,3}(?:\.\d{1,3}){3})\)\s+at\s+(?<mac>[0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5})') { $ip = $Matches['ip']; $mac = $Matches['mac'] }
        if (-not $ip) { continue }
        $key = ConvertTo-AzlAddressMacKey -Mac $mac
        if ($key) { [pscustomobject]@{ IPAddress = $ip; Mac = $key; State = 'Unknown'; Source = 'arp -a' } }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Seams: the only places that touch the network or this machine
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlAddressPort {
    # Seam: does the address accept a TCP connection on the port? A connect and nothing else; no credential, no data.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMilliseconds = 2000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync($Address, $Port)
        return ($connect.Wait($TimeoutMilliseconds) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-AzlLocalIPv4Network {
    # Seam: this machine's IPv4 addresses (Address, PrefixLength, Interface) on interfaces that are up. Works on Windows, Linux and macOS.
    [CmdletBinding()]
    param()
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        foreach ($u in $nic.GetIPProperties().UnicastAddresses) {
            if ($u.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $maskNumber = ConvertTo-AzlIPv4Number -Address $u.IPv4Mask.ToString()
            $prefix = 0
            for ($bit = 31; $bit -ge 0; $bit--) { if (($maskNumber -shr $bit) -band 1) { $prefix++ } else { break } }
            [pscustomobject]@{ Address = $u.Address.ToString(); PrefixLength = $prefix; Interface = $nic.Name }
        }
    }
}

function Get-AzlNeighborEntry {
    <#
    .SYNOPSIS
        Seam: the IPv4 neighbor (ARP) table of this machine. Get-NetNeighbor where it exists, else `arp -a`.
    .OUTPUTS
        Available ($false when this platform has neither), Source, Entries (IPAddress, Mac as 12 hex digits, State, Source).
    #>
    [CmdletBinding()]
    param()
    if (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue) {
        try {
            $rows = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop | Where-Object { "$($_.State)" -notin 'Incomplete', 'Unreachable' } | ForEach-Object {
                    $key = ConvertTo-AzlAddressMacKey -Mac ([string]$_.LinkLayerAddress)
                    if ($key) { [pscustomobject]@{ IPAddress = [string]$_.IPAddress; Mac = $key; State = "$($_.State)"; Source = 'Get-NetNeighbor' } }
                })
            return [pscustomobject]@{ Available = $true; Source = 'Get-NetNeighbor'; Entries = $rows }
        }
        catch { Write-Verbose "Get-NetNeighbor failed ($($_.Exception.Message)); trying arp -a." }
    }
    if (Get-Command arp -CommandType Application -ErrorAction SilentlyContinue) {
        try {
            $text = @(& arp -a 2>$null)
            return [pscustomobject]@{ Available = $true; Source = 'arp -a'; Entries = @(ConvertFrom-AzlArpOutput -Line $text) }
        }
        catch { Write-Verbose "arp -a failed: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Available = $false; Source = ''; Entries = @() }
}

function Invoke-AzlSubnetSweep {
    <#
    .SYNOPSIS
        Seam: one ICMP echo to every host address of the subnet (never outside it, never this machine), so the neighbor table
        learns who is there. The replies are not used: the ARP exchange that precedes each echo is what fills the table.
        Returns how many addresses were pinged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Subnet, [string[]]$Exclude = @(), [int]$TimeoutMilliseconds = 500, [int]$ThrottleLimit = 64)
    $targets = [System.Collections.Generic.List[string]]::new()
    for ($n = $Subnet.First; $n -le $Subnet.Last; $n++) {
        $text = ConvertFrom-AzlIPv4Number -Number $n
        if ($text -notin $Exclude -and (Test-AzlAddressInCidr -Address $text -Subnet $Subnet)) { $targets.Add($text) }
    }
    $timeout = $TimeoutMilliseconds
    $targets | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        try { $null = $ping.Send($_, $using:timeout) } catch { Write-Verbose "ping $_ : $($_.Exception.Message)" } finally { $ping.Dispose() }
    }
    return $targets.Count
}

# ---------------------------------------------------------------------------------------------------------------------
# Candidates from each source
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlHandoffAddressCandidate {
    # The IPv4 addresses a ZTP handoff entry reports for the adapter with the management MAC. Never link-local.
    [CmdletBinding()]
    param([AllowNull()][object]$HandoffEntry, [string]$MacKey)
    if (-not $HandoffEntry -or -not $MacKey) { return }
    foreach ($adapter in @(Get-AzlProp $HandoffEntry 'networkAdapters' @())) {
        if ((ConvertTo-AzlAddressMacKey -Mac ([string](Get-AzlProp $adapter 'macAddress' ''))) -ne $MacKey) { continue }
        $ip = [string](Get-AzlProp $adapter 'ipAddress' '')
        if ($null -ne (ConvertTo-AzlIPv4Number -Address $ip) -and $ip -notlike '169.254.*') {
            [pscustomobject]@{ Address = $ip.Trim(); Detail = "adapter $(Get-AzlProp $adapter 'name' '?') ($(Get-AzlProp $adapter 'ipAssignment' '?'))" }
        }
    }
}

function Get-AzlArcAddressCandidate {
    # The IPv4 addresses the Arc agent reports for the NIC with the management MAC (a NIC that reports no MAC is not used). Never link-local.
    [CmdletBinding()]
    param([AllowNull()][object]$ArcMachine, [string]$MacKey)
    if (-not $ArcMachine -or -not $MacKey) { return }
    foreach ($nic in @(Get-AzlProp $ArcMachine 'Interfaces' @())) {
        if ((ConvertTo-AzlAddressMacKey -Mac ([string](Get-AzlProp $nic 'macAddress' ''))) -ne $MacKey) { continue }
        foreach ($ip in @(Get-AzlProp $nic 'ipAddresses' @())) {
            $text = if ($ip -is [string]) { $ip } else { [string](Get-AzlProp $ip 'address' '') }
            if ($null -ne (ConvertTo-AzlIPv4Number -Address $text) -and $text -notlike '169.254.*') {
                [pscustomobject]@{ Address = $text.Trim(); Detail = "NIC $(Get-AzlProp $nic 'name' '?') of Arc machine $(Get-AzlProp $ArcMachine 'Name' '?') ($(Get-AzlProp $ArcMachine 'Status' '?'))"; Connected = ([string](Get-AzlProp $ArcMachine 'Status' '') -eq 'Connected') }
            }
        }
    }
}

function Get-AzlFileAddressCandidate {
    # The management address in the file: the management port's ip_address, nodes[].management.ip_address, maintenance_address.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $adapter = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $pairs = @(
        @{ Value = $(if ($adapter) { $adapter.IpAddress } else { $null }); Detail = 'management port ip_address' }
        @{ Value = (Get-AzlProp $Node 'management.ip_address'); Detail = 'nodes[].management.ip_address' }
        @{ Value = (Get-AzlProp $Node 'maintenance_address'); Detail = 'nodes[].maintenance_address' }
    )
    foreach ($p in $pairs) {
        $text = [string]$p.Value
        if ($text -and $seen.Add($text)) { [pscustomobject]@{ Address = $text.Trim(); Detail = $p.Detail } }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Ranking: live evidence above historic
# ---------------------------------------------------------------------------------------------------------------------

$script:SourceLabel = @{ 'override' = 'override'; 'ztp-handoff' = 'ZTP handoff'; 'arc' = 'Arc machine'; 'infrastructure-file' = 'infrastructure file'; 'mac-lookup' = 'MAC lookup' }

function Set-AzlCandidateRank {
    <#
    .SYNOPSIS
        Rank 0: reported by the Arc machine while it is Connected, or by two sources. Rank 1: one source (Arc not Connected, file, MAC
        lookup). Rank 2: the ZTP handoff alone (historic). RankReason says why, in words for the operator.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets a property on an in-memory object.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Candidate)
    $sources = @($Candidate.Sources)
    if ($sources -contains 'override') { $Candidate.Rank = 0; $Candidate.RankReason = 'it is the address you gave'; return }
    if ($Candidate.Live -and 'arc' -in $sources) {
        $Candidate.Rank = 0
        $agree = @($sources | Where-Object { $_ -ne 'arc' } | ForEach-Object { $script:SourceLabel[$_] })
        $Candidate.RankReason = "the Arc machine reports it and is Connected (live data)$(if ($agree.Count) { ", and the $($agree -join ' and ') agree" })"
    }
    elseif ($sources.Count -ge 2) {
        $Candidate.Rank = 0
        $Candidate.RankReason = "$(@($sources | ForEach-Object { $script:SourceLabel[$_] }) -join ' and ') both report it (two sources agree)"
    }
    elseif ($sources[0] -eq 'ztp-handoff') {
        $Candidate.Rank = 2
        $Candidate.RankReason = 'only the ZTP handoff reports it (historic data: a last resort among the addresses that answer)'
    }
    else {
        $Candidate.Rank = 1
        $Candidate.RankReason = "the $($script:SourceLabel[$sources[0]]) reports it and nothing live contradicts it (order of trust: Arc Connected or two sources agreeing, then Arc, the file, MAC lookup, and the ZTP handoff last)"
    }
}

function Format-AzlSourceAgreement {
    # 'ZTP handoff says 192.0.2.117; Arc machine says 192.0.2.11 (Connected); infrastructure file says 192.0.2.11'. '' when no source reported anything.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$Candidate = @())
    $parts = foreach ($source in 'ztp-handoff', 'arc', 'infrastructure-file', 'mac-lookup') {
        $addresses = @($Candidate | Where-Object { $source -in @($_.Sources) } | ForEach-Object { $_.Address })
        if ($addresses.Count) { "$($script:SourceLabel[$source]) says $($addresses -join ', ')$(if ($source -eq 'arc' -and @($Candidate | Where-Object { $_.Live }).Count) { ' (Connected)' })" }
    }
    return (@($parts) -join '; ')
}

function Test-AzlSourcesAgree {
    # $true when every source that reported an address reported the same one; $false when two sources named different addresses.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()][object[]]$Candidate = @())
    $bySource = @{}
    foreach ($c in @($Candidate | Where-Object { 'override' -notin @($_.Sources) })) {
        foreach ($s in $c.Sources) { if (-not $bySource.ContainsKey($s)) { $bySource[$s] = @() }; $bySource[$s] += $c.Address }
    }
    if ($bySource.Count -le 1) { return $true }
    return (@($bySource.Values | ForEach-Object { (@($_ | Sort-Object -Unique)) -join ',' } | Select-Object -Unique).Count -le 1)
}

# ---------------------------------------------------------------------------------------------------------------------
# The resolution
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlNodeAddress {
    <#
    .SYNOPSIS
        The current management address of one node, the source it came from, and everything that was tried. See the module description.
    .PARAMETER Infrastructure
        The master file as Import-AzlInfrastructure returns it.
    .PARAMETER Node
        The node's entry (nodes[]).
    .PARAMETER Override
        The operator's address (-NodeAddress / nodeAddress). When given it is the only candidate.
    .PARAMETER HandoffEntry
        The node's entry from its ZTP handoff, if there is one. A node without a handoff is normal (a manual ISO install).
    .PARAMETER ArcMachine
        The node's Arc machine as Find-AzlArcMachine returns it (Interfaces), if it is registered and the caller is signed in.
    .PARAMETER PortTest
        { param($Address, $Port) } returning $true when the TCP port accepts a connection. Default: a plain TCP connect.
    .PARAMETER Setting
        addressResolution run settings: sweep (default true), allowWideSubnet (default false), pingTimeoutMilliseconds (500).
    .OUTPUTS
        Node, Address (where it answers now, or '' when nothing does), Source, Port, Answered, Candidates (Address, Source, Detail, Answers,
        Port; the answering ones first, then in source order), Tried (one line per source, in order), Notes (several answer, etc.),
        Layer2 ($true, $false, or $null when not checked), Message (what to tell the operator; for a failure it asks for the address).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Node,
        [string]$Override,
        [AllowNull()][object]$HandoffEntry,
        [AllowNull()][object]$ArcMachine,
        [scriptblock]$PortTest,
        [AllowNull()][System.Collections.IDictionary]$Setting
    )
    $name = [string]$Node['name']
    if (-not $Setting) { $Setting = @{} }
    $portTestBlock = $PortTest
    $probeCache = @{}
    $probe = {
        param([string]$Address)
        if ($probeCache.ContainsKey($Address)) { return $probeCache[$Address] }
        $hit = 0
        foreach ($port in $script:WinRmPort) {
            $ok = if ($portTestBlock) { [bool](& $portTestBlock $Address $port) } else { [bool](Test-AzlAddressPort -Address $Address -Port $port) }
            if ($ok) { $hit = $port; break }
        }
        $probeCache[$Address] = $hit
        return $hit
    }
    $candidates = [System.Collections.Generic.List[object]]::new()
    $tried = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([string]$Address, [string]$Source, [string]$Detail, [bool]$Live = $false)
        $same = @($candidates | Where-Object { $_.Address -eq $Address })
        if ($same.Count) {
            # The same address from another source: one candidate, every source that reported it (two sources agreeing is evidence).
            if ($Source -notin $same[0].Sources) { $same[0].Sources = @($same[0].Sources) + $Source }
            if ($Live) { $same[0].Live = $true }
            return
        }
        $port = & $probe $Address
        $candidates.Add([pscustomobject]@{ Address = $Address; Source = $Source; Sources = @($Source); Detail = $Detail; Answers = ($port -ne 0); Port = $port; Live = $Live; Rank = 1; RankReason = '' })
    }
    $portText = ($script:WinRmPort -join '/')
    $result = {
        param([string]$Address, [string]$Source, [int]$Port, [bool]$Answered, [object]$Layer2, [string]$Message)
        foreach ($c in $candidates) { Set-AzlCandidateRank -Candidate $c }
        $answeringOrdered = @($candidates | Where-Object { $_.Answers } | Sort-Object -Property Rank -Stable)
        $ordered = @($answeringOrdered + @($candidates | Where-Object { -not $_.Answers }))
        [pscustomobject]@{
            Node = $name; Address = $Address; Source = $Source; Port = $Port; Answered = $Answered; Candidates = $ordered
            Tried = $tried.ToArray(); Notes = $notes.ToArray(); Layer2 = $Layer2; Message = $Message
            Agreement = (Format-AzlSourceAgreement -Candidate @($candidates)); SourcesAgree = (Test-AzlSourcesAgree -Candidate @($candidates))
        }
    }

    # ---- 1. override: final
    if ($Override) {
        $port = & $probe $Override
        $candidates.Add([pscustomobject]@{ Address = $Override; Source = 'override'; Sources = @('override'); Detail = '-NodeAddress / nodeAddress setting'; Answers = ($port -ne 0); Port = $port; Live = $false; Rank = 0; RankReason = 'it is the address you gave' })
        $tried.Add("1. override: $Override ($(if ($port) { "answers on TCP $port" } else { "no answer on TCP $portText" }))")
        foreach ($skipped in 'ZTP handoff', 'Arc machine', 'infrastructure file', 'MAC lookup') { $tried.Add("   $($skipped): not used, an explicit address is final") }
        if (-not $port) { $notes.Add("The address you gave for $name ($Override) does not answer on TCP $portText. No other source was tried, so credentials are never sent to an address you did not give. Fix the address, or remove it so the run resolves one.") }
        return & $result $Override 'override' $port ($port -ne 0) $null $(if ($port) { "$name : using the address you gave, $Override (answers on TCP $port)." } else { $notes[0] })
    }
    $tried.Add('1. override: none given')

    $adapter = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
    $macKey = if ($adapter -and $adapter.MacAddress) { ConvertTo-AzlAddressMacKey -Mac ([string]$adapter.MacAddress) } else { $null }
    $macText = if ($adapter -and $adapter.MacAddress) { [string]$adapter.MacAddress } else { 'not in the file' }

    # ---- 2. ZTP handoff
    if (-not $HandoffEntry) { $tried.Add('2. ZTP handoff: no handoff for this node (normal for a manual ISO install)') }
    elseif (-not $macKey) { $tried.Add('2. ZTP handoff: skipped, the file has no management MAC to match its adapters') }
    else {
        $found = @(Get-AzlHandoffAddressCandidate -HandoffEntry $HandoffEntry -MacKey $macKey)
        if (-not $found.Count) { $tried.Add("2. ZTP handoff: no adapter with MAC $macText reports an IPv4 address") }
        foreach ($c in $found) {
            & $add $c.Address 'ztp-handoff' $c.Detail
            $tried.Add("2. ZTP handoff: $($c.Address) from $($c.Detail) ($(if ($probeCache[$c.Address]) { "answers on TCP $($probeCache[$c.Address])" } else { "no answer on TCP $portText" }))")
        }
    }

    # ---- 3. Arc machine
    if (-not $ArcMachine) { $tried.Add('3. Arc machine: none found, or not signed in to Azure') }
    elseif (-not $macKey) { $tried.Add('3. Arc machine: skipped, the file has no management MAC to match its NICs') }
    else {
        $found = @(Get-AzlArcAddressCandidate -ArcMachine $ArcMachine -MacKey $macKey)
        if (-not $found.Count) { $tried.Add("3. Arc machine: no NIC with MAC $macText reports an IPv4 address") }
        foreach ($c in $found) {
            & $add $c.Address 'arc' $c.Detail ([bool]$c.Connected)
            $tried.Add("3. Arc machine: $($c.Address) from $($c.Detail) ($(if ($probeCache[$c.Address]) { "answers on TCP $($probeCache[$c.Address])" } else { "no answer on TCP $portText" }))")
        }
    }

    # ---- 4. the file
    $found = @(Get-AzlFileAddressCandidate -Infrastructure $Infrastructure -Node $Node)
    if (-not $found.Count) { $tried.Add('4. infrastructure file: no management IP for this node') }
    foreach ($c in $found) {
        $existing = @($candidates | Where-Object { $_.Address -eq $c.Address })
        & $add $c.Address 'infrastructure-file' $c.Detail
        $tried.Add("4. infrastructure file: $($c.Address) ($($c.Detail)$(if ($existing.Count) { "; also reported by $($existing[0].Source)" }); $(if ($probeCache[$c.Address]) { "answers on TCP $($probeCache[$c.Address])" } else { "no answer on TCP $portText" }))")
    }

    # ---- 5. MAC lookup, only when nothing above answered
    $layer2 = $null
    if (@($candidates | Where-Object { $_.Answers }).Count -eq 0) {
        $subnetText = [string](Get-AzlProp $Infrastructure 'networking.management.subnet' '')
        $subnet = ConvertFrom-AzlCidr -Cidr $subnetText
        if (-not $macKey) { $tried.Add('5. MAC lookup: skipped, the file has no management MAC for this node') }
        elseif (-not $subnet) { $tried.Add("5. MAC lookup: skipped, networking.management.subnet in the file is $(if ($subnetText) { "'$subnetText', not an IPv4 CIDR" } else { 'not set' })") }
        else {
            $local = @(Get-AzlLocalIPv4Network)
            $mine = @($local | Where-Object { Test-AzlAddressInCidr -Address $_.Address -Subnet $subnet })
            $layer2 = [bool]$mine.Count
            if (-not $layer2) {
                $tried.Add("5. MAC lookup: skipped, this machine ($(if ($local.Count) { @($local | ForEach-Object { $_.Address }) -join ', ' } else { 'no IPv4 address' })) is not on the management subnet $($subnet.Text), so it does not share the layer-2 segment with the node and ARP cannot see it. Run from a host on that subnet, or pass the address")
            }
            else {
                $findMatch = {
                    $table = Get-AzlNeighborEntry
                    if (-not $table.Available) { return [pscustomobject]@{ Available = $false; Source = ''; Rows = @() } }
                    [pscustomobject]@{ Available = $true; Source = $table.Source; Rows = @($table.Entries | Where-Object { $_.Mac -eq $macKey -and (Test-AzlAddressInCidr -Address $_.IPAddress -Subnet $subnet) }) }
                }
                $hit = & $findMatch
                if (-not $hit.Available) { $tried.Add('5. MAC lookup: skipped, neither Get-NetNeighbor nor arp is available on this machine') }
                else {
                    $sweepNote = ''
                    if (-not $hit.Rows.Count) {
                        $sweepOn = if ($Setting.ContainsKey('sweep')) { [bool]$Setting['sweep'] } else { $true }
                        $wideOk = $Setting.ContainsKey('allowWideSubnet') -and [bool]$Setting['allowWideSubnet']
                        if (-not $sweepOn) { $sweepNote = 'sweep switched off (addressResolution.sweep is false)' }
                        elseif ($subnet.Prefix -lt $script:MaxSweepPrefixLength -and -not $wideOk) { $sweepNote = "sweep refused: $($subnet.Text) is wider than /$($script:MaxSweepPrefixLength) ($($subnet.Count) addresses). Set addressResolution.allowWideSubnet to true in the run settings to allow it, or pass the address" }
                        else {
                            $timeout = if ($Setting.ContainsKey('pingTimeoutMilliseconds')) { [int]$Setting['pingTimeoutMilliseconds'] } else { 500 }
                            $count = Invoke-AzlSubnetSweep -Subnet $subnet -Exclude @($local | ForEach-Object { $_.Address }) -TimeoutMilliseconds $timeout
                            $sweepNote = "ping sweep of $($subnet.Text) ($count addresses)"
                            $hit = & $findMatch
                        }
                    }
                    if (-not $hit.Rows.Count) { $tried.Add("5. MAC lookup: $($hit.Source) has no entry for MAC $macText on $($subnet.Text)$(if ($sweepNote) { " after $sweepNote" }). The node may be off, on another VLAN, or not on DHCP yet") }
                    foreach ($row in $hit.Rows) {
                        & $add $row.IPAddress 'mac-lookup' "$($hit.Source), MAC $macText$(if ($sweepNote) { ", after $sweepNote" })"
                        $tried.Add("5. MAC lookup: $($row.IPAddress) has MAC $macText in $($hit.Source)$(if ($sweepNote) { " after $sweepNote" }) ($(if ($probeCache[$row.IPAddress]) { "answers on TCP $($probeCache[$row.IPAddress])" } else { "no answer on TCP $portText" }))")
                    }
                }
            }
        }
    }
    else { $tried.Add('5. MAC lookup: not needed, an address above answers') }

    # ---- the verdict
    $answering = @($candidates | Where-Object { $_.Answers })
    if ($answering.Count) {
        foreach ($c in $candidates) { Set-AzlCandidateRank -Candidate $c }
        $answering = @($answering | Sort-Object -Property Rank -Stable)
        $winner = $answering[0]
        if ($answering.Count -gt 1) {
            $others = @($answering | Select-Object -Skip 1 | ForEach-Object { "$($_.Address) ($($_.Sources -join '+'))" }) -join ', '
            $notes.Add("Several addresses answer for ${name}: $($winner.Address) ($($winner.Sources -join '+')) and $others. Using $($winner.Address) because $($winner.RankReason). If the others are another machine, give the right one with -NodeAddress.")
        }
        if (-not (Test-AzlSourcesAgree -Candidate @($candidates))) {
            $notes.Add("The sources disagree for ${name}: $(Format-AzlSourceAgreement -Candidate @($candidates)).")
            foreach ($s in @($candidates | Where-Object { $_.Sources.Count -eq 1 -and $_.Sources[0] -eq 'ztp-handoff' -and $_.Address -ne $winner.Address })) {
                $notes.Add("The ZTP handoff is historic data: its address $($s.Address)$(if ($s.Answers) { ' answers, but' } else { ' does not answer, and' }) $($winner.Address) is backed by $(if ($winner.Live) { 'the live Arc machine' } else { ($winner.Sources | ForEach-Object { $script:SourceLabel[$_] }) -join ' and ' }). $($s.Address) is only a last resort, never used unless the machine that answers there proves to be $name.")
            }
        }
        $message = "${name}: current management address $($winner.Address), found by $($winner.Source) ($($winner.Detail)); answers on TCP $($winner.Port)."
        if ($notes.Count) { $message += ' ' + ($notes -join ' ') }
        return & $result $winner.Address $winner.Source $winner.Port $true $layer2 $message
    }
    $reachable = if ($candidates.Count) { "Found, but nothing answers on TCP ${portText}: $(@($candidates | ForEach-Object { "$($_.Address) ($($_.Source))" }) -join ', '). WinRM may be closed or not enabled on the node." } else { 'No candidate address was found.' }
    $message = "Cannot find the current management address of $name (management MAC $macText). $reachable Tried:" + [Environment]::NewLine + (($tried | ForEach-Object { "  $_" }) -join [Environment]::NewLine) + [Environment]::NewLine +
    "Give the address the node answers on now: -NodeAddress @{ '$name' = '<ip>' } (or nodeAddress in the run settings). Nothing was changed."
    return & $result '' 'none' 0 $false $layer2 $message
}

# ---------------------------------------------------------------------------------------------------------------------
# Identity: is the machine that answers on this address the node?
# ---------------------------------------------------------------------------------------------------------------------

function Format-AzlMacText {
    # '02:00:00:00:6E:28' for 12 hex digits (as ConvertTo-AzlAddressMacKey returns them).
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$MacKey)
    if ([string]::IsNullOrWhiteSpace($MacKey) -or $MacKey.Length -ne 12) { return [string]$MacKey }
    return ((0..5 | ForEach-Object { $MacKey.Substring($_ * 2, 2) }) -join ':').ToUpperInvariant()
}

function Get-AzlNodeExpectedIdentity {
    <#
    .SYNOPSIS
        What the file says the node is: Name (the host name, nodes[].name), ManagementMac (12 hex digits, or '' when the file has none) and
        OtherName (the names of the file's other nodes: a machine that reports one of those is not this node).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $name = [string]$Node['name']
    $adapter = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
    $mac = if ($adapter -and $adapter.MacAddress) { [string](ConvertTo-AzlAddressMacKey -Mac ([string]$adapter.MacAddress)) } else { '' }
    $others = @(@($Infrastructure['nodes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -ine $name } | ForEach-Object { [string]$_['name'] })
    [pscustomobject]@{ Name = $name; ManagementMac = $mac; OtherName = $others }
}

function Test-AzlNodeIdentity {
    <#
    .SYNOPSIS
        Compares what a machine reports (computer name, adapter MACs) with what the file says the node is.
    .DESCRIPTION
        The management MAC is the proof: when the file has one, the machine must have an adapter with it, and it must not carry the name
        of another node of the file. A computer name that differs while the MAC is there is accepted with a note (a node installed from an
        ISO keeps its installer name until the Hostname step renames it). When the file has no management MAC the name decides.
    .OUTPUTS
        Match, Reason (why not, or the note), Found (the text 'NAME/MAC,MAC' for messages), Expected (the text of what was expected).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Expected, [Parameter(Mandatory)][AllowNull()][object]$Found)
    $foundName = [string](Get-AzlProp $Found 'ComputerName' '')
    $foundMacs = @(@(Get-AzlProp $Found 'Mac' @()) | ForEach-Object { ConvertTo-AzlAddressMacKey -Mac ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
    $foundText = "$(if ($foundName) { $foundName } else { 'unknown name' })/$(if ($foundMacs.Count) { ($foundMacs | ForEach-Object { Format-AzlMacText -MacKey $_ }) -join ',' } else { 'no MAC reported' })"
    $mac = [string](Get-AzlProp $Expected 'ManagementMac' '')
    $expectedText = "$($Expected.Name)$(if ($mac) { " (management MAC $(Format-AzlMacText -MacKey $mac))" } else { ' (no management MAC in the file)' })"
    $nameOk = $foundName -ieq [string]$Expected.Name
    $isOther = [bool]($foundName -and @(@(Get-AzlProp $Expected 'OtherName' @()) | Where-Object { $_ -ieq $foundName }).Count -gt 0)
    $reason = ''
    $match = $false
    if ($mac) {
        if ($mac -notin $foundMacs) { $reason = "no adapter has the management MAC $(Format-AzlMacText -MacKey $mac)" }
        elseif ($isOther) { $reason = "it carries the management MAC but reports the name of another node ($foundName)" }
        else {
            $match = $true
            if (-not $nameOk) { $reason = "management MAC found; computer name is $foundName, not yet $($Expected.Name)" }
        }
    }
    else {
        if ($nameOk) { $match = $true } else { $reason = "computer name is $foundName and the file has no management MAC to prove it" }
    }
    [pscustomobject]@{ Match = $match; Reason = $reason; Found = $foundText; Expected = $expectedText }
}

function Read-AzlNodeIdentity {
    <#
    .SYNOPSIS
        The computer name and adapter MACs a node reports, through a transport (the first authenticated connection). Read only. A fake transport in a test
        answers with the same AZLRESULT line the Identity node script writes.
    .OUTPUTS
        ComputerName, Mac (12 hex digits each).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][string]$Node, [int]$TimeoutSeconds = 120)
    $seen = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlNodePayload -Name Identity) -Tries 1 -TimeoutSeconds $TimeoutSeconds
    [pscustomobject]@{
        ComputerName = [string](Get-AzlProp $seen 'host' '')
        Mac          = @(@(Get-AzlProp $seen 'macs' @()) | ForEach-Object { ConvertTo-AzlAddressMacKey -Mac ([string]$_) } | Where-Object { $_ })
    }
}

function Get-AzlSessionFailureKind {
    <#
    .SYNOPSIS
        What a failed attempt to open a session or read a node means: 'Refused' (the node answered and said no to the credential), 'Unreachable' (it did not
        answer: down, restarting, a timeout, a connection reset or closed) or 'Other' (anything else; quoted as it is).
    .DESCRIPTION
        Only a real refusal is a credential problem: WinRM 'Access is denied', 0x80070005, 'The user name or password is incorrect', HTTP 401. A node that is
        shutting down or starting up gives timeouts, resets and 'the connection was closed'; those are retried, never reported as a refused credential. The phrases
        are specific on purpose: the word 'authentication' alone also appears in WinRM errors about a domain controller that cannot be reached.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return 'Other' }
    if ($Message -match 'access is denied|0x80070005|user name or password is incorrect|\b401\b|logon failure|unauthori[sz]ed|refused the credential|credentials? (was|were|is|are) (refused|rejected|not accepted)|authentication failed|bad credentials') { return 'Refused' }
    if ($Message -match 'timed out|time out|timeout|did not (answer|respond|finish)|no response|connection (was )?(reset|closed|aborted|lost)|closed by the remote host|forcibly closed|actively refused|connection refused|0x80338[0-9a-f]{3}|0x80072e[ef][0-9a-f]|cannot be resolved|name resolution|network (path|is unreachable)|host is (down|unreachable)|no route to host|broken pipe|i/o operation has been aborted|is shutting down|restarting|abandoned|cannot complete the operation') { return 'Unreachable' }
    return 'Other'
}

function Select-AzlVerifiedNodeAddress {
    <#
    .SYNOPSIS
        Walks the addresses that answer, best first, and returns the first whose machine proves to be the node. A machine that is not the node is
        dropped with 'address X answered but is NAME/MACS, not EXPECTED' and the next candidate is tried.
    .PARAMETER Resolution
        What Resolve-AzlNodeAddress returned (Candidates in rank order; only those that Answer are tried).
    .PARAMETER Expected
        Get-AzlNodeExpectedIdentity of the node.
    .PARAMETER IdentityReader
        { param([string]$Address, [bool]$UseSsl, $State) } returning ComputerName and Mac, or throwing. The caller owns the credential. $null: no check
        (no credential): the first address with an endpoint is returned and the result says Checked is false.
    .PARAMETER EndpointResolver
        { param([string]$Address, $State) } returning Answers and UseSsl (the environment class decides HTTP or HTTPS). Default: the port the probe found.
    .PARAMETER ReaderState
        Handed to IdentityReader and EndpointResolver as their last argument (a script block runs in the session state it was written in, so the
        caller's local variables are not visible to it).
    .OUTPUTS
        Verified, Checked, Address, Source, UseSsl, Port, Dropped (Address, Source, Reason, Text), Log (one line per candidate), Message (why none
        proved the identity; '' when one did).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Resolution,
        [Parameter(Mandatory)][object]$Expected,
        [AllowNull()][scriptblock]$IdentityReader,
        [AllowNull()][scriptblock]$EndpointResolver,
        [AllowNull()][object]$ReaderState,
        # A read that finds the node unreachable (restarting, a timeout, a reset) is tried again: this many tries, this many seconds apart. A refusal is never retried.
        [ValidateRange(1, 20)][int]$UnreachableTries = 3,
        [ValidateRange(0, 300)][int]$UnreachableDelaySeconds = 10,
        [AllowNull()][scriptblock]$Sleeper
    )
    $name = [string]$Expected.Name
    $log = [System.Collections.Generic.List[string]]::new()
    $dropped = [System.Collections.Generic.List[object]]::new()
    $unread = [System.Collections.Generic.List[object]]::new()
    $answering = @($Resolution.Candidates | Where-Object { $_.Answers })
    foreach ($c in $answering) {
        $endpoint = if ($EndpointResolver) { & $EndpointResolver $c.Address $ReaderState } else { [pscustomobject]@{ Answers = $true; UseSsl = ($c.Port -eq 5986); Port = $c.Port } }
        if (-not $endpoint.Answers) { $log.Add("address $($c.Address) ($($c.Source)) was not tried: no WinRM endpoint the profile allows answers there."); continue }
        $useSsl = [bool]$endpoint.UseSsl
        if (-not $IdentityReader) {
            $log.Add("address $($c.Address) ($($c.Source)) was not identity-checked: no credential to read the node with.")
            return [pscustomobject]@{ Verified = $true; Checked = $false; Address = $c.Address; Source = $c.Source; UseSsl = $useSsl; Port = [int](Get-AzlProp $endpoint 'Port' $c.Port); Dropped = @(); Log = $log.ToArray(); Message = '' }
        }
        $found = $null
        $failure = $null
        for ($try = 1; $try -le $UnreachableTries; $try++) {
            try { $found = & $IdentityReader $c.Address $useSsl $ReaderState; $failure = $null; break }
            catch {
                $kind = Get-AzlSessionFailureKind -Message $_.Exception.Message
                $failure = [pscustomobject]@{ Kind = $kind; Message = $_.Exception.Message }
                if ($kind -ne 'Unreachable') { break }
                if ($try -lt $UnreachableTries) {
                    $log.Add("address $($c.Address) ($($c.Source)) did not answer (restarting?), try $try of ${UnreachableTries}: $($_.Exception.Message) Trying again in $UnreachableDelaySeconds s.")
                    if ($Sleeper) { & $Sleeper $UnreachableDelaySeconds } elseif ($UnreachableDelaySeconds -gt 0) { Start-Sleep -Seconds $UnreachableDelaySeconds }
                }
            }
        }
        if ($failure) {
            $unread.Add([pscustomobject]@{ Address = $c.Address; Source = $c.Source; Kind = $failure.Kind; Message = $failure.Message })
            $log.Add($(switch ($failure.Kind) {
                        'Refused' { "address $($c.Address) ($($c.Source)) refused the local administrator: $($failure.Message)" }
                        'Unreachable' { "address $($c.Address) ($($c.Source)) did not answer (restarting?) after $UnreachableTries tries: $($failure.Message)" }
                        default { "address $($c.Address) ($($c.Source)) answered but its identity could not be read: $($failure.Message)" }
                    }))
            continue
        }
        $verdict = Test-AzlNodeIdentity -Expected $Expected -Found $found
        if ($verdict.Match) {
            $log.Add("address $($c.Address) ($($c.Source)) is $name$(if ($verdict.Reason) { " ($($verdict.Reason))" }): $($verdict.Found).")
            return [pscustomobject]@{ Verified = $true; Checked = $true; Address = $c.Address; Source = $c.Source; UseSsl = $useSsl; Port = [int](Get-AzlProp $endpoint 'Port' $c.Port); Dropped = $dropped.ToArray(); Log = $log.ToArray(); Message = '' }
        }
        $text = "address $($c.Address) answered but is $($verdict.Found), not $($verdict.Expected)"
        $dropped.Add([pscustomobject]@{ Address = $c.Address; Source = $c.Source; Reason = $verdict.Reason; Text = $text })
        $log.Add("$text ($($verdict.Reason)); dropped ($($c.Source)).")
    }
    # Only a real refusal is said to be a refusal (a credential problem, not a wrong machine); a node that did not answer is said to have not answered (restarting?);
    # anything else that stopped the read is quoted.
    $lines = @($dropped | ForEach-Object { "$($_.Text) ($($_.Reason)), found by $($_.Source)" }) + @($unread | ForEach-Object {
            $u = $_
            switch ($u.Kind) {
                'Refused' { "the local administrator was refused at $($u.Address) ($($u.Source)): $($u.Message)" }
                'Unreachable' { "$($u.Address) ($($u.Source)) did not answer (restarting?): $($u.Message)" }
                default { "could not read the identity at $($u.Address) ($($u.Source)): $($u.Message)" }
            }
        })
    $onlyUnreachable = ($dropped.Count -eq 0 -and $unread.Count -gt 0 -and @($unread | Where-Object { $_.Kind -ne 'Unreachable' }).Count -eq 0)
    $silent = @($Resolution.Candidates | Where-Object { -not $_.Answers } | ForEach-Object { "$($_.Address) ($($_.Source))" })
    $viaOverride = @($Resolution.Candidates | Where-Object { $_.Source -eq 'override' }).Count -gt 0
    $message = if (($dropped.Count + $unread.Count) -eq 0) { '' }
    elseif ($onlyUnreachable) { "$name did not answer (restarting?) at $(@($unread | ForEach-Object { "$($_.Address) ($($_.Source))" }) -join ', '), so its identity could not be proven and nothing was changed: $($lines -join '; '). Run it again when the node is back; a node that was restarted needs a few minutes." }
    elseif ($viaOverride) { "The address you gave for $name $(if ($dropped.Count) { 'does not belong to it' } else { 'answered, but its identity could not be proven' }): $($lines -join '; '). It was not used and nothing was changed. Give the address of $name with -NodeAddress, or remove it so the run resolves one." }
    else { "No address proved to be $name, so nothing was changed: $($lines -join '; ').$(if ($silent.Count) { " Not answering: $($silent -join ', ')." }) Give the address $name answers on now with -NodeAddress @{ '$name' = '<ip>' } (or nodeAddress in the run settings)." }
    [pscustomobject]@{ Verified = $false; Checked = $true; Address = ''; Source = ''; UseSsl = $false; Port = 0; Dropped = $dropped.ToArray(); Log = $log.ToArray(); Message = $message; Unreachable = $onlyUnreachable }
}

Export-ModuleMember -Function Get-AzlSessionFailureKind, Get-AzlNodeExpectedIdentity, Test-AzlNodeIdentity, Read-AzlNodeIdentity, Select-AzlVerifiedNodeAddress, Format-AzlSourceAgreement, Resolve-AzlNodeAddress,ConvertTo-AzlAddressMacKey, ConvertFrom-AzlArpOutput, ConvertFrom-AzlCidr, Test-AzlAddressInCidr, Get-AzlNeighborEntry, Get-AzlLocalIPv4Network, Test-AzlAddressPort, Invoke-AzlSubnetSweep
