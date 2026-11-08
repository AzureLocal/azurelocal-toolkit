#Requires -Version 7.0
<#
.SYNOPSIS
    The RemoteManagement step on the host side: what one node's firewall rules and listeners should be, the comparison with what
    the node reports, and the guarded apply (stage, confirm, commit or revert).

.DESCRIPTION
    New-AzlRemotingNodeSpec        One node's share of the profile: the rules (own and built-in), the listeners, RDP, the
                                   certificate. Pure.
    Compare-AzlRemotingState       The spec against a node's Read answer: plan items Ok, Change, Blocked or Info. Pure.
    Invoke-AzlRemotingApply        The guarded change. Stage (the node snapshots first and only adds), confirm (the node
                                   still answers on the current path, and the HTTPS path works when the profile uses it),
                                   commit (the exact scope; the HTTP listener and rules go only after the HTTPS path is
                                   verified), or revert (the snapshot). The four steps are script blocks on a change object, so
                                   the guarded change protocol can wrap them (-Guard), and a test injects the node commands.
    Save-AzlNodeCertificate        The node's public certificate as a .cer, with the thumbprint recomputed.
    Import-AzlNodeCertificateTrust The pre-join trust step: put that certificate in a trust store of this machine, only after the
                                   thumbprint matches the one the operator has through an authenticated channel.

    Nothing here runs a command on a node by itself: the node commands go through Invoke-AzlNodeScript and the transport.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AzlRemotingProfile.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlRemotingPayload.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlRemotingSession.psm1')
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'node-configuration' 'AzlNodeTransport.psm1'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))

$script:Rule = [ordered]@{
    Http = 'AzlOsConfig-WinRM-HTTP-In'; Https = 'AzlOsConfig-WinRM-HTTPS-In'; RdpTcp = 'AzlOsConfig-RDP-TCP-In'; RdpUdp = 'AzlOsConfig-RDP-UDP-In'
    Icmp4 = 'AzlOsConfig-ICMPv4-Echo-In'; Icmp6 = 'AzlOsConfig-ICMPv6-Echo-In'; NodeSmb = 'AzlOsConfig-Node-SMB-In'
}
# The rules Windows ships for WinRM are found on the node by port (inbound TCP 5985 or 5986), not by name, and always get the scope of the profile
# (the OS install limits the Public one to LocalSubnet). These others are switched off outside the relaxed classes.
$script:BuiltinOther = @('WINRM-HTTP-Compat-In-TCP', 'WINRM-HTTP-Compat-In-TCP-NoScope', 'RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP', 'RemoteDesktop-Shadow-In-TCP', 'FPS-ICMP4-ERQ-In', 'FPS-ICMP4-ERQ-In-NoScope', 'FPS-ICMP6-ERQ-In', 'FPS-ICMP6-ERQ-In-NoScope')

function Get-RmProp { param($Object, [string]$Name, $Default = $null) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.PSObject.Properties[$Name].Value) { return $Object.PSObject.Properties[$Name].Value } return $Default }

# ---------------------------------------------------------------------------------------------------------------------
# The spec of one node
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlRemotingNodeSpec {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure: builds an object, changes nothing.')]
    <#
    .SYNOPSIS
        One node's share of the effective profile. Pure.
    .PARAMETER ManagementIp
        The node's management address in the master file (it may not be assigned yet: the Network step runs after this one).
    .PARAMETER DnsNames
        Names for the subject alternative names of the per-node certificate (the node name, its FQDN).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$RemotingProfile, [Parameter(Mandatory)][string]$Name, [string]$ManagementIp = '', [string[]]$DnsNames = @(), [string]$CurrentAddress = '', [string]$SourceAddress = '', [int]$RevertMinutes = 10)
    $p = $RemotingProfile
    $t = $p.Transport
    $fw = $p.Firewall
    $rules = [System.Collections.Generic.List[object]]::new()
    $managed = {
        param($key, $display, $protocol, $port, $icmp, $desired, $remote)
        $rules.Add([ordered]@{ kind = 'managed'; name = $script:Rule[$key]; display = $display; protocol = $protocol; port = $port; icmpType = $icmp; desired = $desired; remote = @($remote) })
    }
    $winrmRemote = @($fw.RemoteAddress)
    $httpDesired = if ($t.HttpEnabled) { 'present' } else { 'absentAfterVerify' }
    & $managed 'Http' 'Azure Local OS configuration: WinRM HTTP' 'TCP' '5985' '' $httpDesired $winrmRemote
    & $managed 'Https' 'Azure Local OS configuration: WinRM HTTPS' 'TCP' '5986' '' $(if ($t.HttpsEnabled) { 'present' } else { 'absent' }) $winrmRemote
    $rdpDesired = if ($fw.RdpEnabled) { 'present' } else { 'absent' }
    & $managed 'RdpTcp' 'Azure Local OS configuration: Remote Desktop TCP' 'TCP' '3389' '' $rdpDesired @($fw.RdpRemoteAddress)
    & $managed 'RdpUdp' 'Azure Local OS configuration: Remote Desktop UDP' 'UDP' '3389' '' $rdpDesired @($fw.RdpRemoteAddress)
    $icmpDesired = if ($fw.IcmpEnabled) { 'present' } else { 'absent' }
    & $managed 'Icmp4' 'Azure Local OS configuration: ICMPv4 echo' 'ICMPv4' '' '8' $icmpDesired @($fw.IcmpRemoteAddress)
    & $managed 'Icmp6' 'Azure Local OS configuration: ICMPv6 echo' 'ICMPv6' '' '128' $icmpDesired @($fw.IcmpRemoteAddress)
    # Azure Local needs SMB 445 between all nodes (with ICMP and WS-Man 5985, which the scopes above carry): a node-to-node rule in every class.
    & $managed 'NodeSmb' 'Azure Local OS configuration: SMB between the nodes' 'TCP' '445' '' $(if (@($fw.NodeAddress).Count) { 'present' } else { 'absent' }) @($fw.NodeAddress)
    # The built-in WinRM rules (found by port on the node): ALWAYS enabled, on every profile, with the scope of the profile; disabled once the HTTP listener goes.
    $rules.Add([ordered]@{ kind = 'discoverWinRm'; desired = $httpDesired; remote = $winrmRemote })
    # Outside the relaxed classes the other built-in rules (Any scope) are switched off, so the scope above is the only way in.
    if (-not $p.Relaxed) {
        foreach ($ruleName in $script:BuiltinOther) { $rules.Add([ordered]@{ kind = 'disableRule'; name = $ruleName; desired = 'absent' }) }
    }
    $listeners = [System.Collections.Generic.List[object]]::new()
    if (-not $t.HttpEnabled) {
        $listeners.Add([ordered]@{ transport = 'HTTP'; address = 'ANY'; port = $t.HttpPort; desired = 'absentAfterVerify' })
    }
    elseif ($p.Listener.Bind -eq 'managementIp') {
        $listeners.Add([ordered]@{ transport = 'HTTP'; address = '*'; port = $t.HttpPort; desired = 'absentAfterVerify' })
    }
    $present = [System.Collections.Generic.List[object]]::new()
    if ($t.HttpEnabled) { $present.Add([ordered]@{ transport = 'HTTP'; port = $t.HttpPort; desired = 'present' }) }
    if ($t.HttpsEnabled) { $present.Add([ordered]@{ transport = 'HTTPS'; port = $t.HttpsPort; desired = 'present' }) }
    $ips = @($ManagementIp | Where-Object { $_ })
    [pscustomobject]@{
        Node = $Name; ManagementIp = $ManagementIp; CurrentAddress = $CurrentAddress; SourceAddress = $SourceAddress; RevertMinutes = $RevertMinutes; DnsNames = @($DnsNames | Where-Object { $_ } | Select-Object -Unique); IpAddresses = $ips
        ListenerBind = [string]$p.Listener.Bind; HttpListener = [bool]$t.HttpEnabled; HttpsListener = [bool]$t.HttpsEnabled
        Rules = $rules.ToArray(); Listeners = $listeners.ToArray(); PresentListeners = $present.ToArray()
        RuleNames = @($rules | Where-Object { $_.Contains('name') } | ForEach-Object { $_.name })
        RdpEnabled = [bool]$fw.RdpEnabled; Certificate = $p.Certificate; Profile = $p
    }
}

function Get-AzlRemotingReadParameter {
    <#
    .SYNOPSIS
        What the Read script needs; never a secret.
    #>
    # What the Read script needs; never a secret.
    param([Parameter(Mandatory)][object]$Spec)
    $read = @{ ruleNames = @($Spec.RuleNames) }
    if ($Spec.Certificate.Mode -eq 'thumbprint') { $read.certThumbprint = $Spec.Certificate.Thumbprint }
    return $read
}

function Get-AzlRemotingChangeParameter {
    <#
    .SYNOPSIS
        The parameters of the Change script (mode stage, commit or revert). Never a secret: a Key Vault certificate travels as a
        secret (Get-AzlRemotingSecret), not here.
    #>
    param([Parameter(Mandatory)][object]$Spec, [Parameter(Mandatory)][ValidateSet('stage', 'commit', 'revert', 'disarm')][string]$Mode, [Parameter(Mandatory)][string]$ChangeId, [bool]$Verified = $false)
    @{
        mode = $Mode; changeId = $ChangeId; verified = $Verified
        # On commit the node arms a timer that puts the snapshot back by itself if the orchestrator does not confirm (mode disarm) in time.
        revertMinutes = $(if ($Mode -eq 'commit') { [int]$Spec.RevertMinutes } else { 0 })
        managementIp = $Spec.ManagementIp; currentAddress = $Spec.CurrentAddress; listenerBind = $Spec.ListenerBind
        httpListener = $Spec.HttpListener; httpsListener = $Spec.HttpsListener
        rules = @($Spec.Rules); listeners = @($Spec.Listeners); ruleNames = @($Spec.RuleNames); rdpEnabled = $Spec.RdpEnabled
        certMode = $Spec.Certificate.Mode; certThumbprint = $Spec.Certificate.Thumbprint; dnsNames = @($Spec.DnsNames); ipAddresses = @($Spec.IpAddresses); certDays = 365
    }
}

function Get-AzlRemotingCurrentAddress {
    <#
    .SYNOPSIS
        The address this session reaches the node on (WinRM transport only; an Arc session has none).
    #>
    # The address this session reaches the node on (WinRM transport only; an Arc session has none).
    param([object]$Transport, [string]$Node)
    if ($Transport -and $Transport.Kind -eq 'WinRM' -and $Transport.PSObject.Properties['State'] -and $Transport.State.Addresses.ContainsKey($Node)) { return [string]$Transport.State.Addresses[$Node] }
    return ''
}

function Get-AzlRemotingSourceAddress {
    <#
    .SYNOPSIS
        The local address of this host that routes to a destination: the source address the node sees. Nothing is sent (a UDP socket is
        connected, which only asks the routing table). Empty when it can't be worked out.
    .PARAMETER Resolver
        { param($Destination) } returns the address text. Default: a UDP socket. A test injects it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Destination, [scriptblock]$Resolver = {
            param($Destination)
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse($Destination, [ref]$ip)) { return '' }
            $socket = [System.Net.Sockets.Socket]::new($ip.AddressFamily, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
            try { $socket.Connect($ip, 5985); return $socket.LocalEndPoint.Address.ToString() } finally { $socket.Dispose() }
        })
    if (-not $Destination) { return '' }
    try { return [string](& $Resolver $Destination) } catch { return '' }
}

function Test-AzlAddressInScope {
    <#
    .SYNOPSIS
        Whether an address is inside a firewall RemoteAddress list (Any, CIDRs, addresses). LocalSubnet and the other keywords depend on the
        node and can't be judged from here: they are taken as "can't tell", which counts as inside (nothing is blocked on a guess). Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Address, [string[]]$Scope = @())
    $a = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$a)) { return $true }
    if ($a.IsIPv4MappedToIPv6) { $a = $a.MapToIPv4() }
    foreach ($entry in @($Scope | Where-Object { $_ })) {
        if ($entry -eq 'Any') { return $true }
        if ($entry -in 'LocalSubnet', 'DNS', 'DHCP', 'WINS', 'DefaultGateway', 'Internet', 'Intranet') { return $true }
        $c = ConvertTo-AzlCidr -Text $entry
        if (-not $c.Valid) { continue }
        $network = [System.Net.IPAddress]::Parse($c.Network)
        if ($network.AddressFamily -ne $a.AddressFamily) { continue }
        $x = $a.GetAddressBytes(); $y = $network.GetAddressBytes()
        $same = $true
        for ($i = 0; $i -lt $x.Length -and $same; $i++) {
            $keep = [Math]::Max(0, [Math]::Min(8, $c.Prefix - 8 * $i))
            $mask = if ($keep -eq 0) { 0 } else { (0xFF -shl (8 - $keep)) -band 0xFF }
            if (($x[$i] -band $mask) -ne $y[$i]) { $same = $false }
        }
        if ($same) { return $true }
    }
    return $false
}

function Read-AzlRemotingState {
    <#
    .SYNOPSIS
        The RemoteManagement Read on one node (changes nothing). Also records the address in use and this host's source address on the node spec.
    .PARAMETER SourceResolver
        { param($Destination) } the local address that routes to the node. Default: Get-AzlRemotingSourceAddress.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [Parameter(Mandatory)][object]$Transport, [scriptblock]$SourceResolver)
    $Spec.CurrentAddress = Get-AzlRemotingCurrentAddress -Transport $Transport -Node $Spec.Node
    $Spec.SourceAddress = $(if ($SourceResolver) { Get-AzlRemotingSourceAddress -Destination $Spec.CurrentAddress -Resolver $SourceResolver } else { Get-AzlRemotingSourceAddress -Destination $Spec.CurrentAddress })
    Invoke-AzlNodeScript -Transport $Transport -Node $Spec.Node -Script (Get-AzlRemotingPayload -Name Read) -Parameters (Get-AzlRemotingReadParameter -Spec $Spec) -TimeoutSeconds 600
}

function Get-AzlRemotingSecret {
    <#
    .SYNOPSIS
        The secrets the node needs for the profile: the certificate PFX when os_configuration.remoting.certificate is a Key Vault
        reference. Read here, passed as a secret, never printed, written or returned in a report.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecret -Reference $Ref })
    if ($Spec.Certificate.Mode -ne 'keyVault' -or -not $Spec.HttpsListener) { return @{} }
    try { return @{ certificatePfx = [string](& $SecretResolver $Spec.Certificate.Reference) } }
    catch { throw "Can't read the server certificate ($($Spec.Certificate.Reference)): $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-RmAddress {
    # One firewall address in the form the node reports it: CIDR, or Any / LocalSubnet.
    param([string]$Text)
    if ($Text -in 'Any', 'LocalSubnet', 'DNS', 'DHCP', 'WINS', 'DefaultGateway', 'Internet', 'Intranet') { return $Text }
    $c = ConvertTo-AzlCidr -Text $Text
    if ($c.Valid) { return $c.Normalized }
    return $Text
}

function Test-RmSameAddressSet([string[]]$A, [string[]]$B) {
    $x = @($A | Where-Object { $_ } | ForEach-Object { ConvertTo-RmAddress $_ } | Sort-Object -Unique)
    $y = @($B | Where-Object { $_ } | ForEach-Object { ConvertTo-RmAddress $_ } | Sort-Object -Unique)
    return (($x -join '|') -eq ($y -join '|'))
}

function Get-RmPlanItem {
    param([string]$Node, [string]$Item, [string]$Current, [string]$Desired, [string]$Action, [string]$Note = '', [hashtable]$Apply)
    [pscustomobject]@{ Node = $Node; Step = 'RemoteManagement'; Item = $Item; Current = $Current; Desired = $Desired; Action = $Action; Note = $Note; Apply = $Apply }
}

function Get-AzlRemotingListenIp {
    # The address the listener and the local scope of the rules bind to: the management address in the file, once the node holds it AND this
    # session came in on it (or has no address). Until then '' : the listener stays on * and the rules take any local address, so nothing
    # stops answering when the Network step changes the address. The next pass narrows them. Same rule as Get-BindAddress on the node.
    param([object]$Spec, [object]$State)
    $own = @(Get-RmProp $State 'addresses' @() | ForEach-Object { [string]$_ })
    if ($Spec.ManagementIp -and $Spec.ManagementIp -in $own -and (-not $Spec.CurrentAddress -or $Spec.CurrentAddress -eq $Spec.ManagementIp)) { return [string]$Spec.ManagementIp }
    return ''
}

function Compare-AzlRemotingState {
    <#
    .SYNOPSIS
        Compares the node spec with what the Read script reported and returns plan items (Ok, Change, Blocked, Info). Pure.
    .DESCRIPTION
        Every Change item carries Apply = @{ id; kind = 'remoting' }: one guarded apply handles all of them together.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [Parameter(Mandatory)][AllowNull()][object]$State)
    $n = $Spec.Node
    $p = $Spec.Profile
    $items = [System.Collections.Generic.List[object]]::new()
    $change = { param($id) @{ id = "RemoteManagement/$id"; kind = 'remoting'; item = $id } }
    if (-not $State) {
        $items.Add((Get-RmPlanItem $n 'remote management' 'unreadable' 'readable' Info 'The node did not report its remote management state.'))
        return $items.ToArray()
    }
    $service = Get-RmProp $State 'service'
    $listeners = @(Get-RmProp $State 'listeners' @())
    $rules = @(Get-RmProp $State 'rules' @())
    $listenIp = Get-AzlRemotingListenIp -Spec $Spec -State $State

    # ---- the WinRM baseline (the denylist)
    if ($service) {
        $bad = [System.Collections.Generic.List[string]]::new()
        if (-not (Get-RmProp $service 'running' $false)) { $bad.Add('service not running') }
        else {
            if ([string](Get-RmProp $service 'allowUnencrypted' '') -ne 'false') { $bad.Add('AllowUnencrypted') }
            if ([string](Get-RmProp $service 'basic' '') -ne 'false') { $bad.Add('Basic') }
            if ([string](Get-RmProp $service 'credSsp' '') -ne 'false') { $bad.Add('CredSSP') }
            if ([string](Get-RmProp $service 'cbt' '') -ne 'Strict') { $bad.Add('CbtHardeningLevel') }
            if ([string](Get-RmProp $service 'compatHttp' 'false') -ne 'false' -or [string](Get-RmProp $service 'compatHttps' 'false') -ne 'false') { $bad.Add('HTTP.sys compatibility listener') }
        }
        $items.Add((Get-RmPlanItem $n 'WinRM baseline' $(if ($bad.Count) { "off baseline: $($bad -join ', ')" } else { 'AllowUnencrypted false, Basic and CredSSP off, CBT Strict' }) 'AllowUnencrypted false, Basic and CredSSP off, CBT Strict, no compatibility listener' $(if ($bad.Count) { 'Change' } else { 'Ok' }) '' $(if ($bad.Count) { & $change 'baseline' })))
    }
    $tls = Get-RmProp $State 'tls'
    if ($p.Transport.HttpsEnabled -and $tls -and (Get-RmProp $tls 'tls12ServerEnabled') -eq 0) {
        $items.Add((Get-RmPlanItem $n 'TLS 1.2' 'TLS 1.2 is disabled for servers on this node' 'TLS 1.2 or higher' Blocked 'The baseline needs TLS 1.2 or higher for the HTTPS listener. Enable it in the SCHANNEL registry settings or by policy; this step does not change the cipher suite settings.'))
    }

    # ---- the listeners
    $wantsIp = $p.Listener.Bind -eq 'managementIp'
    # Bound to the management IP only when the node holds it (and this session came in on it). Before that the listener stays on * : binding to the
    # address in use would stop answering when the Network step changes the address.
    $bindIp = $wantsIp -and [bool]$listenIp
    if ($wantsIp -and -not $listenIp) {
        $items.Add((Get-RmPlanItem $n 'listener address' "management IP '$($Spec.ManagementIp)' not on the node (or not the address in use)" 'bound to the management IP' Info "Until this node holds $($Spec.ManagementIp) and this session uses it, the listener stays on * and the firewall rules take any local address. The Network step sets the address; the next pass binds the listener and the rules to it."))
    }
    if ($true) {
        $wantAddress = if ($bindIp) { "IP:$listenIp" } else { '*' }
        foreach ($l in @($Spec.PresentListeners)) {
            $haveL = @($listeners | Where-Object { $_.transport -eq $l.transport -and ((-not $bindIp) -or $_.address -eq $wantAddress) })
            $ok = $haveL.Count -gt 0
            $note = ''
            if ($ok -and $l.transport -eq 'HTTPS') {
                $thumb = [string]$haveL[0].thumbprint
                $wantThumb = [string]$Spec.Certificate.Thumbprint
                if ($Spec.Certificate.Mode -eq 'thumbprint' -and $thumb -ne $wantThumb) { $ok = $false; $note = "The HTTPS listener uses $thumb, the master file says $wantThumb." }
                else {
                    $cert = @(Get-RmProp $State 'certs' @()) | Where-Object { $_.thumbprint -eq $thumb } | Select-Object -First 1
                    if ($cert -and $listenIp -and $listenIp -notin @($cert.ips) -and @($cert.ips).Count -gt 0) { $ok = $false; $note = "The listener certificate $thumb has no IP subject alternative name for $listenIp." }
                }
            }
            $items.Add((Get-RmPlanItem $n "$($l.transport) listener" $(if ($haveL.Count) { "present ($(($haveL | ForEach-Object { $_.address }) -join ', '))" } else { 'absent' }) "present$(if ($bindIp) { " on $wantAddress" })" $(if ($ok) { 'Ok' } else { 'Change' }) $note $(if (-not $ok) { & $change "listener-$($l.transport.ToLowerInvariant())" })))
        }
        foreach ($l in @($Spec.Listeners)) {
            $keptTransport = @($Spec.PresentListeners | Where-Object { $_.transport -eq $l.transport }).Count -gt 0
            $stay = @($listeners | Where-Object { $_.transport -eq $l.transport -and ($l.address -eq 'ANY' -or $_.address -eq $l.address) -and -not ($keptTransport -and (-not $bindIp -or $_.address -eq $wantAddress)) })
            $items.Add((Get-RmPlanItem $n "$($l.transport) listener to remove ($($l.address))" $(if ($stay.Count) { "present ($(($stay | ForEach-Object { $_.address }) -join ', '))" } else { 'absent' }) 'absent' $(if ($stay.Count) { 'Change' } else { 'Ok' }) $(if ($stay.Count) { 'Removed after the new path is verified from this host (HTTPS with a full name check). If it is not, it stays; install the certificate trust (docs) and run again.' } else { '' }) $(if ($stay.Count) { & $change "listener-remove-$($l.transport.ToLowerInvariant())" })))
        }
    }

    # ---- the firewall rules
    $desiredLocal = @(@($listenIp) | Where-Object { $_ } | ForEach-Object { ConvertTo-RmAddress $_ })
    if ($desiredLocal.Count -eq 0) { $desiredLocal = @('Any') }
    foreach ($r in $Spec.Rules) {
        $ruleName = if ($r.Contains('name')) { [string]$r['name'] } else { '' }
        $have = @($rules | Where-Object { $ruleName -and $_.name -eq $ruleName }) | Select-Object -First 1
        $label = "firewall $ruleName"
        switch ($r.kind) {
            'managed' {
                if ($r.desired -eq 'present') {
                    $reasons = @()
                    if (-not $have) { $reasons += 'absent' }
                    else {
                        if (-not $have.enabled) { $reasons += 'disabled' }
                        if ($have.profile -ne 'Any') { $reasons += "profile $($have.profile)" }
                        if (-not (Test-RmSameAddressSet @($have.remote) @($r.remote))) { $reasons += "from $(@($have.remote) -join ', ')" }
                        if (-not (Test-RmSameAddressSet @($have.local) $desiredLocal)) { $reasons += "to $(@($have.local) -join ', ')" }
                    }
                    $items.Add((Get-RmPlanItem $n $label $(if ($have) { "$(if ($have.enabled) { 'on' } else { 'off' }), $($have.profile), from $(@($have.remote) -join ', ')" } else { 'absent' }) "on, every profile, from $(@($r.remote) -join ', ') to $($desiredLocal -join ', ')" $(if ($reasons.Count) { 'Change' } else { 'Ok' }) $(if ($reasons.Count) { $reasons -join '; ' } else { '' }) $(if ($reasons.Count) { & $change "rule-$($r.name)" })))
                }
                else {
                    $items.Add((Get-RmPlanItem $n $label $(if ($have) { 'present' } else { 'absent' }) 'absent' $(if ($have) { 'Change' } else { 'Ok' }) $(if ($have -and $r.desired -eq 'absentAfterVerify') { 'Removed with the HTTP listener, after the HTTPS path is verified.' } else { '' }) $(if ($have) { & $change "rule-$($r.name)" })))
                }
            }
            'discoverWinRm' {
                $found = @(Get-RmProp $State 'winrmRules' @())
                if ($found.Count -eq 0) {
                    $items.Add((Get-RmPlanItem $n 'firewall built-in WinRM rules' 'none found on the node' "on, every profile, from $(@($r.remote) -join ', ')" Change 'Enable-PSRemoting creates them; they are found by port (5985, 5986), not by name.' (& $change 'rule-winrm-builtin')))
                    continue
                }
                foreach ($f in $found) {
                    # Only a rule that allows exactly 5985 goes with the HTTP listener. A rule that allows 5986 keeps the scope of the profile, whatever happens to HTTP.
                    $httpRule = ([string]$f.port -eq '5985')
                    if ($r.desired -eq 'present' -or -not $httpRule) {
                        $reasons = @()
                        if (-not $f.enabled) { $reasons += 'disabled' }
                        if ($f.profile -ne 'Any') { $reasons += "profile $($f.profile)" }
                        if (-not (Test-RmSameAddressSet @($f.remote) @($r.remote))) { $reasons += "from $(@($f.remote) -join ', ')" }
                        $items.Add((Get-RmPlanItem $n "firewall $($f.name)" "$(if ($f.enabled) { 'on' } else { 'off' }), $($f.profile), from $(@($f.remote) -join ', ')" "on, every profile, from $(@($r.remote) -join ', ')" $(if ($reasons.Count) { 'Change' } else { 'Ok' }) $(if ($reasons.Count) { $reasons -join '; ' } else { '' }) $(if ($reasons.Count) { & $change "rule-$($f.name)" })))
                    }
                    else {
                        $items.Add((Get-RmPlanItem $n "firewall $($f.name)" "$(if ($f.enabled) { 'on' } else { 'off' })" 'off' $(if ($f.enabled) { 'Change' } else { 'Ok' }) $(if ($f.enabled) { 'Disabled with the HTTP listener, after the HTTPS path is verified.' } else { '' }) $(if ($f.enabled) { & $change "rule-$($f.name)" })))
                    }
                }
            }
            'disableRule' {
                if ($have -and $have.enabled) { $items.Add((Get-RmPlanItem $n $label 'on' 'off' Change 'A built-in rule with an open scope; the scope of the profile is the only way in.' (& $change "rule-$($r.name)"))) }
            }
        }
    }

    # ---- RDP
    $rdp = Get-RmProp $State 'rdp'
    if ($rdp) {
        $reasons = @()
        $deny = [int](Get-RmProp $rdp 'deny' 1)
        if ($Spec.RdpEnabled) {
            if ($deny -ne 0) { $reasons += 'RDP denied' }
            if ((Get-RmProp $rdp 'nla') -ne 1) { $reasons += 'NLA not required' }
        }
        elseif ($deny -eq 0) { $reasons += 'RDP allowed' }
        $items.Add((Get-RmPlanItem $n 'RDP' "deny=$deny, NLA=$(Get-RmProp $rdp 'nla' '?')" $(if ($Spec.RdpEnabled) { 'allowed, NLA required' } else { 'denied' }) $(if ($reasons.Count) { 'Change' } else { 'Ok' }) $(if ($reasons.Count) { $reasons -join '; ' } else { '' }) $(if ($reasons.Count) { & $change 'rdp' })))
    }

    # ---- what is only worth knowing
    $domain = [bool](Get-RmProp $State 'domainJoined' $false)
    $categories = @(Get-RmProp $State 'categories' @())
    if ($categories.Count) {
        $text = ($categories | ForEach-Object { "$($_.alias)=$($_.category)" }) -join ', '
        $items.Add((Get-RmPlanItem $n 'network category' $text 'any: the rules are on every profile' Info "The rules apply on Domain, Private and Public, so the join (which changes the category to DomainAuthenticated) does not close them.$(if ($domain -and @($categories | Where-Object { $_.category -ne 'DomainAuthenticated' }).Count) { ' The node is joined but a connection is not DomainAuthenticated: check Group Policy has applied.' })"))
    }
    if ($domain) { $items.Add((Get-RmPlanItem $n 'authentication' "domain joined, class $($p.Class)" $p.Authentication.Mode Info "$($p.Authentication.Description) Connect by FQDN with Kerberos and remove this host's TrustedHosts entries; after the join, check Group Policy did not widen the scope.")) }
    $pending = Get-RmProp $State 'pending'
    if ($pending) { $items.Add((Get-RmPlanItem $n 'staged change' "change $($pending.changeId) staged $($pending.taken) and not committed" 'none' Info 'An earlier run staged a change and did not commit it. The next apply restores its snapshot first.')) }

    # ---- the operator must stay inside the scope the commit narrows the firewall to. The commit sets the exact scope of the profile; a source address
    # of this host that is outside it would lock this host out of the node. Nothing of this step is applied then: every change becomes Blocked.
    $source = [string]$Spec.SourceAddress
    $scope = @($p.Firewall.RemoteAddress)
    if ($source -and -not (Test-AzlAddressInScope -Address $source -Scope $scope)) {
        $why = "This host reaches $n from $source, which is not in the firewall scope the class $($p.Class) sets on the node ($($scope -join ', ')). Applying it would lock this host out. Add $source (or its network) to os_configuration.remoting.allowed_source_cidrs, or run from a host inside the scope."
        foreach ($i in @($items | Where-Object { $_.Action -eq 'Change' -and $_.Apply -and $_.Apply.kind -eq 'remoting' })) { $i.Action = 'Blocked'; $i.Apply = $null; $i.Note = ("Not applied: " + $why) }
        $items.Insert(0, (Get-RmPlanItem $n 'operator access' "this host connects from $source" "inside $($scope -join ', ')" Blocked $why))
    }
    return $items.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# The guarded apply
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlDefaultRemotingGuard {
    <#
    .SYNOPSIS
        The default guard: stage; if that failed, revert; confirm; if that failed, revert; commit; if that failed, revert.
        The guarded change protocol replaces this with its own wrapper (Invoke-AzlRemotingApply -Guard); it gets the same change
        object and returns the same result. Each step is a script block that takes the change object as its first argument.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Change)
    $stage = & $Change.Stage $Change
    if (-not $stage.Ok) {
        $revert = if ($stage.Reverted) { $null } else { & $Change.Revert $Change }
        return [pscustomobject]@{ Status = 'reverted'; Stage = $stage; Confirm = $null; Commit = $null; Revert = $revert; Reason = $stage.Reason }
    }
    $confirm = & $Change.Confirm $Change $stage
    if (-not $confirm.Ok) {
        $revert = & $Change.Revert $Change
        return [pscustomobject]@{ Status = 'reverted'; Stage = $stage; Confirm = $confirm; Commit = $null; Revert = $revert; Reason = $confirm.Reason }
    }
    $commit = & $Change.Commit $Change $confirm
    if (-not $commit.Ok) {
        $revert = & $Change.Revert $Change
        return [pscustomobject]@{ Status = 'reverted'; Stage = $stage; Confirm = $confirm; Commit = $commit; Revert = $revert; Reason = $commit.Reason }
    }
    [pscustomobject]@{ Status = 'committed'; Stage = $stage; Confirm = $confirm; Commit = $commit; Revert = $null; Reason = '' }
}

function Switch-AzlWinRmTransportToSsl {
    <#
    .SYNOPSIS
        After the HTTP listener is gone: the WinRM transport's next session is opened over HTTPS (the open ones are closed).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Transport)
    if ($Transport.Kind -ne 'WinRM' -or -not $Transport.PSObject.Properties['State']) { return $false }
    if (-not $PSCmdlet.ShouldProcess('WinRM transport', 'Switch to HTTPS')) { return $false }
    foreach ($key in @($Transport.State.Sessions.Keys)) { try { Remove-PSSession -Session $Transport.State.Sessions[$key] -ErrorAction SilentlyContinue } catch { Write-Verbose "Session $key not closed: $($_.Exception.Message)" } }
    $Transport.State.Sessions = @{}
    $Transport.State.Ssl = $true
    return $true
}

function Test-AzlRemotingPath {
    <#
    .SYNOPSIS
        The default confirmation. Ok: the node still answers on the path in use (a Read). Verified: the HTTPS listener answers with a
        full certificate check (a Read over a new HTTPS session); when the profile has no HTTPS, Verified follows Ok.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$Transport,
        [scriptblock]$HttpsRead,
        [scriptblock]$PortTest = { param($Address, $Port) $c = [System.Net.Sockets.TcpClient]::new(); try { $a = $c.ConnectAsync($Address, $Port); $a.Wait(4000) -and $c.Connected } catch { $false } finally { $c.Dispose() } }
    )
    $node = $Spec.Node
    try { $null = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlRemotingPayload -Name Read) -Parameters (Get-AzlRemotingReadParameter -Spec $Spec) -TimeoutSeconds 300 -Tries 2 }
    catch { return [pscustomobject]@{ Ok = $false; Verified = $false; Reason = "The node does not answer on the path in use after the change: $($_.Exception.Message)" } }
    if (-not $Spec.HttpsListener) { return [pscustomobject]@{ Ok = $true; Verified = $true; Reason = '' } }
    $address = if ($Spec.CurrentAddress) { $Spec.CurrentAddress } else { $Spec.ManagementIp }
    if (-not $HttpsRead) {
        $HttpsRead = {
            param($Spec, $Transport, $Address)
            if ($Transport.Kind -ne 'WinRM') { return [pscustomobject]@{ Ok = $false; Reason = 'No credential path to open an HTTPS session from this host (the node is reached through Arc Run Command).' } }
            $https = New-AzlWinRmTransport -Address @{ $Spec.Node = $Address } -Credential $Transport.State.Credential -UseSsl
            try { $null = Invoke-AzlNodeScript -Transport $https -Node $Spec.Node -Script (Get-AzlRemotingPayload -Name Read) -Parameters (Get-AzlRemotingReadParameter -Spec $Spec) -TimeoutSeconds 300 -Tries 1; return [pscustomobject]@{ Ok = $true; Reason = '' } }
            catch { return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
        }
    }
    if ($address -and -not (& $PortTest $address 5986)) { return [pscustomobject]@{ Ok = $true; Verified = $false; Reason = "TCP 5986 on $address is not reachable from this host, so the HTTPS path is not verified." } }
    $read = & $HttpsRead $Spec $Transport $address
    [pscustomobject]@{ Ok = $true; Verified = [bool]$read.Ok; Reason = $(if ($read.Ok) { '' } else { "The HTTPS path is not verified: $($read.Reason) Install the node's certificate in this host's trust store (docs: the pre-join certificate trust procedure), then run again." }) }
}

function Test-AzlRemotingFreshSession {
    <#
    .SYNOPSIS
        After the commit: can this host open a NEW session to the node (the open one may survive a firewall change that a new one does not)?
        A node reached through Arc has no firewall path to test. Returns Ok and Reason.
    .PARAMETER Verified
        The HTTPS path was verified, so a commit that removes HTTP leaves HTTPS only: the fresh session uses it.
    .PARAMETER OpenAndRead
        { param($Spec, $Transport, $Address, $Ssl) } returns Ok and Reason. Default: a new WinRM transport and a Read through it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [object]$Transport, [bool]$Verified = $false, [scriptblock]$OpenAndRead)
    if (-not $Transport -or $Transport.Kind -ne 'WinRM' -or -not $Transport.PSObject.Properties['State']) { return [pscustomobject]@{ Ok = $true; Reason = '' } }
    $state = $Transport.State
    $address = if ($Spec.CurrentAddress) { [string]$Spec.CurrentAddress } elseif ($state.Addresses.ContainsKey($Spec.Node)) { [string]$state.Addresses[$Spec.Node] } else { '' }
    $ssl = [bool]$state.Ssl -or ($Spec.Profile.Transport.RemoveHttpAfterHttps -and $Verified)
    if (-not $OpenAndRead) {
        if (-not $state.ContainsKey('Credential') -or -not $state.Credential -or -not $address) { return [pscustomobject]@{ Ok = $true; Reason = '' } }
        $OpenAndRead = {
            param($Spec, $Transport, $Address, $Ssl)
            $arguments = @{ Address = @{ $Spec.Node = $Address }; Credential = $Transport.State.Credential; UseSsl = [bool]$Ssl; Authentication = $Transport.State.Authentication; SkipCertificateCheck = [bool]$Transport.State.SkipCertificateCheck }
            $fresh = New-AzlWinRmTransport @arguments
            try { $null = Invoke-AzlNodeScript -Transport $fresh -Node $Spec.Node -Script (Get-AzlRemotingPayload -Name Read) -Parameters (Get-AzlRemotingReadParameter -Spec $Spec) -TimeoutSeconds 180 -Tries 1; return [pscustomobject]@{ Ok = $true; Reason = '' } }
            catch { return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
            finally { try { & $fresh.CloseSession $fresh $Spec.Node } catch { Write-Verbose "fresh session not closed: $($_.Exception.Message)" } }
        }
    }
    $r = & $OpenAndRead $Spec $Transport $address $ssl
    [pscustomobject]@{ Ok = [bool]$r.Ok; Reason = [string]$r.Reason }
}

function Invoke-AzlRemotingApply {
    <#
    .SYNOPSIS
        Applies the RemoteManagement step to one node as a guarded change. Never leaves the node worse off: stage only adds, the
        node snapshots first, and any failure or lost path restores the snapshot.
    .PARAMETER Invoke
        { param($Mode, $Parameters, $Secrets) } returns the node's answer for mode stage, commit or revert. Default: the Change
        script through Invoke-AzlNodeScript on -Transport. A test injects it.
    .PARAMETER ConfirmPath
        { param($Stage) } returns Ok and Verified (the new path works; the HTTPS path is verified). Default: Test-AzlRemotingPath.
    .PARAMETER Guard
        { param($Change) } returns Status committed or reverted. Default: Invoke-AzlDefaultRemotingGuard. The guarded change
        protocol passes its own and gets the change object: Stage { param($Self) }, Confirm { param($Self, $Stage) }, Commit { param($Self, $Confirmation) }, Revert { param($Self) }.
    .OUTPUTS
        Status (committed, reverted, failed), Verified, HttpKept, Thumbprint, CertPublic, Results (the node's), Changes (one per
        plan item id), Detail, TransportChanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [object]$Transport,
        [object[]]$Item = @(),
        [object]$State,
        [hashtable]$Secrets = @{},
        [scriptblock]$Invoke,
        [scriptblock]$ConfirmPath,
        [scriptblock]$Guard,
        [scriptblock]$Reconnect,
        [string]$ChangeId = ('rm-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    )
    if (-not $Reconnect) { $Reconnect = { param($Verified) Test-AzlRemotingFreshSession -Spec $Spec -Transport $Transport -Verified $Verified } }
    $node = $Spec.Node
    if (-not $Invoke) {
        $Invoke = { param($Mode, $Parameters, $Secrets2) Write-Verbose "$node change call: $Mode"; Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlRemotingPayload -Name Change) -Parameters $Parameters -Secrets $Secrets2 -TimeoutSeconds 600 -Tries 1 }
    }
    if (-not $ConfirmPath) { $ConfirmPath = { param($Stage) Write-Verbose "confirm after stage $($Stage.Ok)"; Test-AzlRemotingPath -Spec $Spec -Transport $Transport } }
    if (-not $Guard) { $Guard = { param($Change) Invoke-AzlDefaultRemotingGuard -Change $Change } }

    # A change an earlier run staged and never committed: put it back first.
    $pending = if ($State) { Get-RmProp $State 'pending' } else { $null }
    if ($pending) {
        $old = [string]$pending.changeId
        try { $null = & $Invoke 'revert' (Get-AzlRemotingChangeParameter -Spec $Spec -Mode revert -ChangeId $old) $Secrets }
        catch { Write-Warning "${node}: the earlier staged change $old could not be reverted: $($_.Exception.Message)" }
    }

    $change = [pscustomobject]@{
        Name = 'RemoteManagement'; Node = $node; ChangeId = $ChangeId; Spec = $Spec; Secrets = $Secrets; Invoke = $Invoke; ConfirmPath = $ConfirmPath; Reconnect = $Reconnect
        Stage = {
            param($Self)
            try {
                $r = & $Self.Invoke 'stage' (Get-AzlRemotingChangeParameter -Spec $Self.Spec -Mode stage -ChangeId $Self.ChangeId) $Self.Secrets
                $failed = @($r.results | Where-Object { $_.status -eq 'failed' })
                [pscustomobject]@{ Ok = ([bool]$r.ok -and $failed.Count -eq 0); Reverted = [bool]$r.reverted; Reason = $(if ($failed.Count) { ($failed | ForEach-Object { "$($_.id): $($_.detail)" }) -join '; ' } else { '' }); Answer = $r }
            }
            catch { [pscustomobject]@{ Ok = $false; Reverted = $false; Reason = "The stage call failed: $($_.Exception.Message)"; Answer = $null } }
        }
        Confirm = { param($Self, $Stage) & $Self.ConfirmPath $Stage }
        Commit = {
            param($Self, $Confirmation)
            try {
                $r = & $Self.Invoke 'commit' (Get-AzlRemotingChangeParameter -Spec $Self.Spec -Mode commit -ChangeId $Self.ChangeId -Verified ([bool]$Confirmation.Verified)) $Self.Secrets
                $failed = @($r.results | Where-Object { $_.status -eq 'failed' })
                $ok = ([bool]$r.ok -and $failed.Count -eq 0)
                $reason = $(if ($failed.Count) { ($failed | ForEach-Object { "$($_.id): $($_.detail)" }) -join '; ' } else { '' })
                if ($ok) {
                    # The commit narrowed the firewall: prove this host still gets in through a NEW session. If not, the guard reverts (and the node's own timer
                    # would revert it anyway). Only when it does is the timer taken away.
                    $fresh = & $Self.Reconnect ([bool]$Confirmation.Verified)
                    if (-not $fresh.Ok) { $ok = $false; $reason = "After the commit this host could not open a new session to the node, so the change is reverted: $($fresh.Reason)" }
                    else {
                        $d = & $Self.Invoke 'disarm' (Get-AzlRemotingChangeParameter -Spec $Self.Spec -Mode disarm -ChangeId $Self.ChangeId) $Self.Secrets
                        $dFailed = @((Get-RmProp $d 'results' @()) | Where-Object { $_.status -eq 'failed' })
                        if ($dFailed.Count) { $ok = $false; $reason = "The node's revert timer could not be removed, so the change is reverted now rather than by the timer later: $(($dFailed | ForEach-Object { $_.detail }) -join '; ')" }
                    }
                }
                [pscustomobject]@{ Ok = $ok; Reason = $reason; Answer = $r }
            }
            catch { [pscustomobject]@{ Ok = $false; Reason = "The commit call failed: $($_.Exception.Message)"; Answer = $null } }
        }
        Revert = {
            param($Self)
            try { $r = & $Self.Invoke 'revert' (Get-AzlRemotingChangeParameter -Spec $Self.Spec -Mode revert -ChangeId $Self.ChangeId) $Self.Secrets; [pscustomobject]@{ Ok = [bool]$r.ok; Answer = $r } }
            catch { [pscustomobject]@{ Ok = $false; Answer = $null; Reason = $_.Exception.Message } }
        }
    }
    $outcome = & $Guard $change
    $stageAnswer = Get-RmProp $outcome.Stage 'Answer'
    $thumbprint = [string](Get-RmProp $stageAnswer 'thumbprint' '')
    $certPublic = [string](Get-RmProp $stageAnswer 'certPublic' '')
    $results = @(@(Get-RmProp $stageAnswer 'results' @()) + @(Get-RmProp (Get-RmProp $outcome.Commit 'Answer') 'results' @()))
    $verified = [bool](Get-RmProp $outcome.Confirm 'Verified' $false)
    $committed = $outcome.Status -eq 'committed'
    $t = $Spec.Profile.Transport
    $httpKept = $committed -and $t.RemoveHttpAfterHttps -and -not $verified
    $transportChanged = $false
    if ($committed -and $verified -and $t.RemoveHttpAfterHttps -and $Transport) { $transportChanged = [bool](Switch-AzlWinRmTransportToSsl -Transport $Transport -Confirm:$false) }

    $detail = if ($committed) { "committed$(if ($httpKept) { '; the HTTP listener and its rules were KEPT because the HTTPS path is not verified from this host' })" } else { "reverted: $($outcome.Reason)" }
    $status = if ($committed) { 'changed' } else { 'failed' }
    $changes = @(@($Item | ForEach-Object { $_.Apply.id }) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ Id = $_; Status = $status; Detail = $detail } })

    # ---- events
    $ruleResults = @($results | Where-Object { $_.id -like 'AzlOsConfig-*' -or $_.id -in 'WINRM-HTTP-In-TCP', 'WINRM-HTTP-In-TCP-PUBLIC' -or $_.id -like 'WINRM-*' -or $_.id -like 'RemoteDesktop-*' -or $_.id -like 'FPS-*' })
    Write-AzlRemotingEvent -State RemotingFirewallChange -Node $node -Level $(if ($committed) { 'Info' } else { 'Warning' }) -Evidence "Firewall scope $(if ($committed) { 'applied' } else { 'NOT applied (reverted)' }) for class $($Spec.Profile.Class): WinRM from $(@($Spec.Profile.Firewall.RemoteAddress) -join ', ')" -Data ([ordered]@{ changeId = $ChangeId; class = $Spec.Profile.Class; remoteAddress = @($Spec.Profile.Firewall.RemoteAddress); rules = @($ruleResults | ForEach-Object { $_.id }); status = $outcome.Status })
    Write-AzlRemotingEvent -State RemotingListenerChange -Node $node -Level $(if ($committed -and -not $httpKept) { 'Info' } else { 'Warning' }) -Evidence "Listeners $(if ($committed) { 'applied' } else { 'NOT applied (reverted)' }): HTTPS $($t.HttpsEnabled), HTTP $($t.HttpEnabled)$(if ($thumbprint) { ", certificate $thumbprint" })$(if ($httpKept) { '; HTTP kept until HTTPS is verified' })" -Data ([ordered]@{ changeId = $ChangeId; https = $t.HttpsEnabled; http = $t.HttpEnabled; thumbprint = $thumbprint; verified = $verified; httpKept = $httpKept; status = $outcome.Status })

    [pscustomobject]@{
        Node = $node; Status = $(if ($committed) { 'committed' } else { 'reverted' }); ChangeId = $ChangeId; Verified = $verified; HttpKept = $httpKept
        Thumbprint = $thumbprint; CertPublic = $certPublic; Results = $results; Changes = $changes; Detail = $detail; TransportChanged = $transportChanged; Reason = [string]$outcome.Reason
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The pre-join certificate trust procedure
# ---------------------------------------------------------------------------------------------------------------------

function Save-AzlNodeCertificate {
    <#
    .SYNOPSIS
        Writes the node's public certificate (from the stage answer) to <Path>\<node>.cer and returns its thumbprint, recomputed
        from the bytes. A thumbprint that differs from the one the node claimed is an error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][string]$CertPublic, [string]$ClaimedThumbprint = '', [Parameter(Mandatory)][string]$Path)
    $bytes = [Convert]::FromBase64String($CertPublic)
    $thumb = [System.BitConverter]::ToString([System.Security.Cryptography.SHA1]::HashData($bytes)).Replace('-', '')
    if ($ClaimedThumbprint -and $thumb -ne $ClaimedThumbprint.ToUpperInvariant()) { throw "The certificate of $Node hashes to $thumb but the node reported $ClaimedThumbprint." }
    $file = Join-Path $Path ("$Node.cer")
    if ($PSCmdlet.ShouldProcess($file, 'Write the node certificate')) {
        $null = New-Item -ItemType Directory -Force -Path $Path
        [IO.File]::WriteAllBytes($file, $bytes)
    }
    [pscustomobject]@{ Node = $Node; Path = $file; Thumbprint = $thumb }
}

function Import-AzlNodeCertificateTrust {
    <#
    .SYNOPSIS
        Puts a node's self-signed certificate in a trust store of this machine so WinRM over HTTPS passes the full certificate check
        (never SkipCACheck or SkipCNCheck). Only when the thumbprint equals the one given through an authenticated channel (the Arc
        run command output, the console, the BMC). A self-signed certificate in the Root store is trusted for any name: remove it
        with Remove-AzlNodeCertificateTrust as soon as the node has its enterprise certificate.
    .PARAMETER Importer
        { param($Path, $StoreName, $StoreLocation) } default: Import-Certificate. A test injects it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedThumbprint,
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$StoreLocation = 'CurrentUser',
        [scriptblock]$Importer = { param($Path, $StoreName, $StoreLocation) Import-Certificate -FilePath $Path -CertStoreLocation "Cert:\$StoreLocation\$StoreName" | Out-Null }
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    $thumb = [System.BitConverter]::ToString([System.Security.Cryptography.SHA1]::HashData($bytes)).Replace('-', '')
    $expected = ($ExpectedThumbprint -replace '[\s:]', '').ToUpperInvariant()
    if ($thumb -ne $expected) { throw "$Path has thumbprint $thumb, not the $expected given. It is not imported." }
    if ($PSCmdlet.ShouldProcess("Cert:\$StoreLocation\Root", "Trust $thumb")) { & $Importer $Path 'Root' $StoreLocation }
    [pscustomobject]@{ Thumbprint = $thumb; Store = "Cert:\$StoreLocation\Root"; Imported = $true }
}

function Remove-AzlNodeCertificateTrust {
    <#
    .SYNOPSIS
        Removes a node's bootstrap certificate from the trust store again (by thumbprint).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Thumbprint,
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$StoreLocation = 'CurrentUser',
        [scriptblock]$Remover = { param($Thumbprint, $StoreLocation) Remove-Item -LiteralPath "Cert:\$StoreLocation\Root\$Thumbprint" -Force }
    )
    if ($PSCmdlet.ShouldProcess("Cert:\$StoreLocation\Root\$Thumbprint", 'Remove')) { & $Remover $Thumbprint $StoreLocation }
}

Export-ModuleMember -Function Read-AzlRemotingState, Get-AzlRemotingCurrentAddress, New-AzlRemotingNodeSpec, Get-AzlRemotingReadParameter, Get-AzlRemotingChangeParameter, Get-AzlRemotingSecret, Compare-AzlRemotingState, Invoke-AzlDefaultRemotingGuard, Switch-AzlWinRmTransportToSsl, Test-AzlRemotingPath, Test-AzlRemotingFreshSession, Get-AzlRemotingSourceAddress, Test-AzlAddressInScope, Invoke-AzlRemotingApply, Save-AzlNodeCertificate, Import-AzlNodeCertificateTrust, Remove-AzlNodeCertificateTrust
