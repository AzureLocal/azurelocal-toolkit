#Requires -Version 7.0
<#
.SYNOPSIS
    The remote management security profile of an OS configuration run: which firewall sources, which WinRM transport, which
    TrustedHosts policy and which bootstrap are allowed for an environment class, worked out from the master file.

.DESCRIPTION
    Resolve-AzlRemotingProfile is a pure function. It reads the parsed master file (scenario.environment_class and
    os_configuration.remoting, the networks and the node addresses) and config/remoting-profiles.json (one row per class, readable
    by an operator), and returns the effective profile: the class and where it came from, every setting with its source, the
    firewall remote addresses, the TrustedHosts value, HTTP or HTTPS, authentication, RDP and ICMP, the bootstrap permission, and
    the warnings and errors. It touches nothing: no node, no Azure, no registry.

    The classes are lab, test, dev, production and dmz. A missing class is production (fail closed); an unknown value is an error
    that names the allowed values. lab and test are relaxed with the wildcard (sources Any, TrustedHosts '*', HTTP 5985 allowed)
    and say so in a warning; dev, production and dmz take their sources only from the master file's networks and
    allowed_source_cidrs. The baseline (AllowUnencrypted false, Basic and CredSSP off, no SkipCACheck or SkipCNCheck, TLS 1.2 or
    higher, a listener never bound to * in production and dmz, explicit firewall addresses, RDP with NLA, ICMP echo only) holds in
    every class and no key or override changes it.

    Get-AzlRemotingFinding turns the same result into validator findings, rules AZL-060 to AZL-068, for AzlInfrastructure.psm1.
    No network, subscription, host or lab name appears here: every address comes from the file that is passed in.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultDataPath = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'config', 'remoting-profiles.json'))
$script:AllowedClasses = @('lab', 'test', 'dev', 'production', 'dmz')
$script:RelaxedClasses = @('lab', 'test')
# The denylist, as code: a data file that says anything else is refused (Resolve-AzlRemotingProfile adds an error).
$script:RequiredBaseline = [ordered]@{
    allowUnencrypted = $false; basicAuth = $false; credSsp = $false; cbtHardeningLevel = 'Strict'; httpSysCompatListener = $false
    skipCACheck = $false; skipCNCheck = $false; minimumTls = '1.2'; rdpNla = $true; icmpEchoOnly = $true; explicitRemoteAddress = $true
}
$script:KnownOverride = @('environment_class', 'allow_any_source', 'allowed_source_cidrs', 'trusted_hosts', 'use_https', 'isolation_confirmed', 'bootstrap_transport', 'transport', 'certificate', 'approved_bootstrap', 'approved_bootstrap_source')
$script:HttpPort = 5985
$script:HttpsPort = 5986

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function Get-RpValue {
    # A value by dotted path from a dictionary or an object; $Default when any part is missing or null.
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Path, [AllowNull()][object]$Default = $null)
    $node = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node) { return $Default }
        if ($node -is [System.Collections.IDictionary]) {
            if (-not $node.Contains($part)) { return $Default }
            $node = $node[$part]
        }
        elseif ($node -is [pscustomobject] -or $node -is [psobject]) {
            $property = $node.PSObject.Properties[$part]
            if (-not $property) { return $Default }
            $node = $property.Value
        }
        else { return $Default }
    }
    if ($null -eq $node) { return $Default }
    return , $node
}

function Get-RpList {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) { return @($Value) }
    return @($Value)
}

function ConvertTo-RpBool {
    # $true / $false for a boolean or its text; $null when it is neither.
    param([AllowNull()][object]$Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        switch ($Value.Trim().ToLowerInvariant()) { 'true' { return $true } 'false' { return $false } }
    }
    return $null
}

function New-RpIssue {
    param([string]$Id, [ValidateSet('error', 'warning', 'info')][string]$Severity, [string]$Path, [string]$Message)
    [pscustomobject]@{ Id = $Id; Severity = $Severity; Path = $Path; Message = $Message }
}

function ConvertTo-AzlCidr {
    <#
    .SYNOPSIS
        Parses an IPv4 or IPv6 address or CIDR. A bare address is a host (/32 or /128). Returns Valid, Reason, Family, Prefix,
        Network (the masked address), Normalized ('192.0.2.0/24') and IsHost.
    .EXAMPLE
        ConvertTo-AzlCidr '192.0.2.77/24'   # Normalized 192.0.2.0/24
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $bad = { param($why) [pscustomobject]@{ Valid = $false; Reason = $why; Family = ''; Prefix = -1; Network = ''; Normalized = ''; IsHost = $false; Text = $Text } }
    if ([string]::IsNullOrWhiteSpace($Text)) { return (& $bad 'empty') }
    $trimmed = $Text.Trim()
    $parts = $trimmed.Split('/')
    if ($parts.Count -gt 2) { return (& $bad 'more than one /') }
    $addressText = $parts[0]
    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($addressText, [ref]$address)) { return (& $bad 'not an IP address') }
    if ($addressText.Contains('%')) { return (& $bad 'a scope id is not allowed') }
    $isV4 = $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    if ($isV4 -and $addressText -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (& $bad 'IPv4 needs four dotted parts') }
    $max = if ($isV4) { 32 } else { 128 }
    $prefix = $max
    if ($parts.Count -eq 2) {
        if ($parts[1] -notmatch '^\d{1,3}$') { return (& $bad 'the prefix length is not a number') }
        $prefix = [int]$parts[1]
        if ($prefix -gt $max) { return (& $bad "the prefix length is above $max") }
    }
    $bytes = $address.GetAddressBytes()
    $masked = [byte[]]::new($bytes.Length)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $keep = [Math]::Max(0, [Math]::Min(8, $prefix - 8 * $i))
        $mask = if ($keep -eq 0) { 0 } else { (0xFF -shl (8 - $keep)) -band 0xFF }
        $masked[$i] = [byte]($bytes[$i] -band $mask)
    }
    $network = ([System.Net.IPAddress]::new($masked)).ToString()
    [pscustomobject]@{ Valid = $true; Reason = ''; Family = $(if ($isV4) { 'IPv4' } else { 'IPv6' }); Prefix = $prefix; Network = $network; Normalized = "$network/$prefix"; IsHost = ($prefix -eq $max); Text = $Text }
}

# ---------------------------------------------------------------------------------------------------------------------
# The data file
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlRemotingProfileData {
    <#
    .SYNOPSIS
        Reads config/remoting-profiles.json (or -Path) as nested hashtables and checks it has every class.
    #>
    [CmdletBinding()]
    param([string]$Path = $script:DefaultDataPath)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The remote management profile table isn't there: $Path" }
    try { $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20 }
    catch { throw "The remote management profile table $Path isn't valid JSON: $($_.Exception.Message)" }
    foreach ($class in $script:AllowedClasses) {
        if (-not $data.ContainsKey('classes') -or -not $data.classes.ContainsKey($class)) { throw "The remote management profile table $Path has no row for the class '$class'." }
    }
    return $data
}

function Get-AzlRemotingClass {
    <#
    .SYNOPSIS
        The environment classes the profile table knows, in the order of the table.
    #>
    [CmdletBinding()]
    param()
    return $script:AllowedClasses
}

# ---------------------------------------------------------------------------------------------------------------------
# Where the nodes and the networks are (all from the master file)
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlRemotingNodeAddress {
    <#
    .SYNOPSIS
        The management addresses of the nodes in the master file: nodes[].management.ip_address and the address of a
        network_adapters[] port with the role management. Returns Node, Address, Path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Infrastructure)
    $found = [System.Collections.Generic.List[object]]::new()
    $nodes = @(Get-RpList (Get-RpValue $Infrastructure 'nodes'))
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $node = $nodes[$i]
        $name = [string](Get-RpValue $node 'name' '')
        $address = [string](Get-RpValue $node 'management.ip_address' '')
        if ($address) { $found.Add([pscustomobject]@{ Node = $name; Address = $address; Path = "nodes[$i].management.ip_address" }) }
        $ports = @(Get-RpList (Get-RpValue $node 'network_adapters'))
        for ($p = 0; $p -lt $ports.Count; $p++) {
            $roles = @(Get-RpList (Get-RpValue $ports[$p] 'roles') | ForEach-Object { [string]$_ })
            $portAddress = [string](Get-RpValue $ports[$p] 'ip_address' '')
            if ('management' -in $roles -and $portAddress -and $portAddress -ne $address) { $found.Add([pscustomobject]@{ Node = $name; Address = $portAddress; Path = "nodes[$i].network_adapters[$p].ip_address" }) }
        }
    }
    return $found.ToArray()
}

function Get-RpNetworkSource {
    # The networks the master file marks as management or out-of-band: the management network, the oob network, and every vlan,
    # logical network or cluster network whose purpose is one of $Purposes.
    param([AllowNull()][object]$Infrastructure, [string[]]$Purposes)
    $list = [System.Collections.Generic.List[object]]::new()
    $add = { param($cidr, $from, $purpose) if ($cidr) { $list.Add([pscustomobject]@{ Cidr = [string]$cidr; From = $from; Purpose = $purpose }) } }
    if ('management' -in $Purposes) { & $add (Get-RpValue $Infrastructure 'networking.management.subnet') 'networking.management.subnet' 'management' }
    if ('oob' -in $Purposes) { & $add (Get-RpValue $Infrastructure 'networking.oob.subnet') 'networking.oob.subnet' 'oob' }
    foreach ($spec in @(@('networking.vlans', 'subnet'), @('networking.logical_networks', 'address_prefix'), @('networking.cluster_networks', 'subnet'))) {
        $items = @(Get-RpList (Get-RpValue $Infrastructure $spec[0]))
        for ($i = 0; $i -lt $items.Count; $i++) {
            $purpose = ([string](Get-RpValue $items[$i] 'purpose' '')).Trim().ToLowerInvariant()
            if ($purpose -in $Purposes -and $purpose -in 'management', 'oob') { & $add (Get-RpValue $items[$i] $spec[1]) "$($spec[0])[$i].$($spec[1])" $purpose }
        }
    }
    return $list.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# The one-time bootstrap: is it permitted?
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlBootstrapPermitted {
    <#
    .SYNOPSIS
        Whether the one-time bootstrap (Arc Run Command or SMB) may run: the class allows it, the operator chose a route
        (bootstrap_transport arc, smb or auto), and where the class needs a pipeline approval, it was given. Returns Permitted and
        Reason. Pure.
    .PARAMETER Bootstrap
        The Bootstrap part of a resolved profile.
    .PARAMETER ApprovedBootstrap
        Approves the run on top of what the profile recorded (the -ApprovedBootstrap parameter of the run).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Bootstrap, [string]$Class = '', [switch]$ApprovedBootstrap)
    $b = $Bootstrap
    $approved = $b.Approved -or $ApprovedBootstrap.IsPresent
    if (-not $b.Allowed) { return [pscustomobject]@{ Permitted = $false; Reason = "The class $Class doesn't allow a bootstrap." } }
    if (-not $b.Chosen) {
        $why = if ($b.RequiresExplicitChoice) { "The class $Class allows the one-time bootstrap only with bootstrap_transport: arc, smb or auto in os_configuration.remoting and a pipeline approval (-ApprovedBootstrap). Otherwise open WinRM from the console or the BMC." } else { 'Not chosen: os_configuration.remoting.bootstrap_transport is none.' }
        return [pscustomobject]@{ Permitted = $false; Reason = $why }
    }
    if ($b.Approval -ne 'none' -and -not $approved) {
        return [pscustomobject]@{ Permitted = $false; Reason = "The class $Class needs the bootstrap approved by the pipeline$(if ($b.Approval -eq 'perRun') { ' on every run' }) (-ApprovedBootstrap). It is chosen (bootstrap_transport: $($b.Transport)) but not approved." }
    }
    [pscustomobject]@{ Permitted = $true; Reason = $(if ($b.Approval -ne 'none') { "Chosen ($($b.Transport): $(@($b.Routes) -join ', ')) and approved." } else { "Chosen ($($b.Transport): $(@($b.Routes) -join ', ')); the class allows it without an approval." }) }
}

# ---------------------------------------------------------------------------------------------------------------------
# The resolver
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlRemotingProfile {
    <#
    .SYNOPSIS
        The effective remote management security profile for a master file. Pure: nothing on this machine or any node changes.
    .DESCRIPTION
        Order of precedence for every setting: -Override, then the master file, then the class table
        (config/remoting-profiles.json). Override keys are the file's keys in snake_case: environment_class, allow_any_source,
        allowed_source_cidrs, trusted_hosts, use_https, isolation_confirmed, bootstrap_transport, transport, certificate, and
        approved_bootstrap (the pipeline approval of the one-time Arc bootstrap, never read from the file). A baseline setting
        (allow_unencrypted, basic, credssp, skip_ca_check, skip_cn_check, ...) in the overrides is an error: no override changes
        the denylist.
    .PARAMETER Infrastructure
        The parsed master file (Import-AzlInfrastructure).
    .PARAMETER Override
        A hashtable of overrides (see above).
    .PARAMETER DataPath
        The profile table; default config/remoting-profiles.json.
    .PARAMETER Data
        An already loaded table (for a test).
    .OUTPUTS
        Class, ClassSource, Valid, Relaxed, Posture, Summary, Settings, Firewall, TrustedHosts, Transport, Listener,
        Authentication, Rdp, Icmp, Certificate, Bootstrap, Baseline, NodeToNode, AfterDomainJoin, ServerIdentity, NodeAddresses,
        Issues, Warnings, Errors. Errors is empty when the profile can be used.
    .EXAMPLE
        $profile = Resolve-AzlRemotingProfile -Infrastructure (Import-AzlInfrastructure -Path ./infrastructure.yml)
        $profile.Firewall.RemoteAddress
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Infrastructure,
        [hashtable]$Override = @{},
        [string]$DataPath = $script:DefaultDataPath,
        [hashtable]$Data
    )
    if (-not $Data) { $Data = Get-AzlRemotingProfileData -Path $DataPath }
    $issues = [System.Collections.Generic.List[object]]::new()
    $issue = { param($id, $severity, $path, $message) $issues.Add((New-RpIssue $id $severity $path $message)) }
    $settings = [ordered]@{}
    $set = { param($name, $value, $source) $settings[$name] = [pscustomobject]@{ Value = $value; Source = $source } }
    $ov = @{}
    foreach ($key in $Override.Keys) { $ov[([string]$key).Trim().ToLowerInvariant().Replace('-', '_')] = $Override[$key] }

    # ---- the baseline: the table must keep it, and no override may touch it
    foreach ($name in $script:RequiredBaseline.Keys) {
        $have = Get-RpValue $Data "baseline.$name"
        $want = $script:RequiredBaseline[$name]
        $same = if ($want -is [bool]) { ($have -is [bool]) -and ($have -eq $want) } else { [string]$have -eq [string]$want }
        if (-not $same) { & $issue 'RP-BASELINE' 'error' "baseline.$name" "The profile table weakens the baseline: baseline.$name must be '$want' in every class and is '$have'. The denylist can't be changed." }
    }
    $profilesWanted = @('Domain', 'Private', 'Public')
    $haveProfiles = (@(Get-RpList (Get-RpValue $Data 'baseline.firewallProfiles')) | Sort-Object) -join ','
    if ($haveProfiles -ne (($profilesWanted | Sort-Object) -join ',')) {
        & $issue 'RP-BASELINE' 'error' 'baseline.firewallProfiles' 'The profile table must apply the firewall rules on Domain, Private and Public.'
    }
    $denied = @(Get-RpList (Get-RpValue $Data 'deniedOverrideKeys') | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($key in $ov.Keys) {
        if ($key -in $denied) { & $issue 'RP-BASELINE' 'error' "override.$key" "The override '$key' would change the baseline (AllowUnencrypted false, Basic and CredSSP off, no SkipCACheck or SkipCNCheck, TLS 1.2 or higher). No override can change it." }
        elseif ($key -notin $script:KnownOverride) { & $issue 'RP-OVERRIDE' 'error' "override.$key" "Unknown override '$key'. Known: $($script:KnownOverride -join ', ')." }
    }

    # ---- the class
    $fileClass = Get-RpValue $Infrastructure 'scenario.environment_class'
    $rawClass = $null
    $classSource = ''
    if ($ov.ContainsKey('environment_class') -and $null -ne $ov['environment_class']) { $rawClass = $ov['environment_class']; $classSource = 'override environment_class' }
    elseif ($null -ne $fileClass) { $rawClass = $fileClass; $classSource = 'master file scenario.environment_class' }
    else { $rawClass = [string](Get-RpValue $Data 'defaultClass' 'production'); $classSource = "default (scenario.environment_class is missing, so it is $rawClass)" }
    $class = ([string]$rawClass).Trim().ToLowerInvariant()
    $valid = $class -in $script:AllowedClasses
    if (-not $valid) {
        & $issue 'AZL-060' 'error' 'scenario.environment_class' "The environment class '$rawClass' isn't valid. Allowed values: $($script:AllowedClasses -join ', '). A missing class means production."
        $class = 'production'   # only to keep the rest of the arithmetic meaningful; the profile is not Valid
    }
    $row = $Data.classes[$class]
    & $set 'class' $class $classSource
    $relaxed = $class -in $script:RelaxedClasses
    $remote = Get-RpValue $Infrastructure 'os_configuration.remoting'
    $get = {
        # override, then file; returns Present, Value, Source
        param($key)
        if ($ov.ContainsKey($key) -and $null -ne $ov[$key]) { return [pscustomobject]@{ Present = $true; Value = $ov[$key]; Source = "override $key" } }
        $v = Get-RpValue $remote $key
        if ($null -ne $v) { return [pscustomobject]@{ Present = $true; Value = $v; Source = "master file os_configuration.remoting.$key" } }
        return [pscustomobject]@{ Present = $false; Value = $null; Source = "class table ($class)" }
    }

    # ---- Any
    $anySetting = & $get 'allow_any_source'
    $anyValue = ConvertTo-RpBool $anySetting.Value
    if ($anySetting.Present -and $null -eq $anyValue) { & $issue 'AZL-061' 'error' 'os_configuration.remoting.allow_any_source' "allow_any_source must be true or false, not '$($anySetting.Value)'." }
    $effectiveAny = $false
    if ($relaxed) {
        if ($anySetting.Present -and $null -ne $anyValue) { $effectiveAny = $anyValue; & $set 'allowAnySource' $effectiveAny $anySetting.Source }
        else { $effectiveAny = [bool]$row.sources.any; & $set 'allowAnySource' $effectiveAny "class table ($class implies it unless set to false)" }
    }
    else {
        if ($anyValue -eq $true) { & $issue 'AZL-061' 'error' 'os_configuration.remoting.allow_any_source' "allow_any_source: true is honoured only in the classes lab and test, and the class is $class. List the controllers in allowed_source_cidrs instead." }
        & $set 'allowAnySource' $false $(if ($anySetting.Present) { "$($anySetting.Source) (not honoured in $class)" } else { "class table ($class)" })
    }

    # ---- the isolation statement
    $isoSetting = & $get 'isolation_confirmed'
    $isoValue = ConvertTo-RpBool $isoSetting.Value
    if ($isoValue -eq $true -and -not $relaxed) { & $issue 'AZL-066' 'error' 'os_configuration.remoting.isolation_confirmed' "isolation_confirmed: true is not allowed in the class ${class}: Any is never accepted outside lab and test, whatever the network is." }
    $isolation = ($relaxed -and $isoValue -eq $true)
    & $set 'isolationConfirmed' $isolation $isoSetting.Source

    # ---- HTTPS
    $httpsSetting = & $get 'use_https'
    $transportSetting = & $get 'transport'
    $httpsText = if ($httpsSetting.Present) { ([string]$httpsSetting.Value).Trim().ToLowerInvariant() } else { 'auto' }
    if ($httpsText -notin 'auto', 'true', 'false') { & $issue 'AZL-065' 'error' 'os_configuration.remoting.use_https' "use_https must be auto, true or false, not '$($httpsSetting.Value)'."; $httpsText = 'auto' }
    $policy = [string]$row.transport.httpsPolicy
    $httpsSource = $httpsSetting.Source
    switch ($httpsText) {
        'true' { $httpsWanted = $true }
        'false' { $httpsWanted = $false }
        default {
            if ([string]$transportSetting.Value -eq 'winrm_https') { $httpsWanted = $true; $httpsSource = $transportSetting.Source }
            else { $httpsWanted = ([string]$row.transport.defaultScheme -eq 'https'); $httpsSource = "class table ($class)" }
        }
    }
    if (-not $httpsWanted -and $httpsText -eq 'false') {
        switch ($policy) {
            'required' { & $issue 'AZL-065' 'error' 'os_configuration.remoting.use_https' "use_https: false is not allowed in the class ${class}: WinRM must use HTTPS (5986) from the first privileged session."; $httpsWanted = $true; $httpsSource = "class table ($class; use_https false refused)" }
            'warn' { & $issue 'AZL-065' 'warning' 'os_configuration.remoting.use_https' "use_https: false keeps WinRM on HTTP in the class $class. HTTP with Negotiate encrypts but does not authenticate the node; HTTPS is required before any second hop." }
        }
    }
    $httpsEnabled = [bool]$httpsWanted
    $httpEnabled = if (-not $httpsEnabled) { $true } else { $policy -eq 'preferred' }
    $scheme = if ($httpsEnabled) { 'https' } else { 'http' }
    $transport = [pscustomobject]@{
        Scheme = $scheme; HttpsEnabled = $httpsEnabled; HttpEnabled = $httpEnabled; RemoveHttpAfterHttps = ($httpsEnabled -and -not $httpEnabled)
        HttpPort = $script:HttpPort; HttpsPort = $script:HttpsPort; HttpsPolicy = $policy
        OrchestratorMayFallBackToHttp = ($httpsEnabled -and [bool]$row.transport.orchestratorMayUseHttp); BootstrapWindowHttp = [bool]$row.transport.bootstrapWindowHttp
        Configured = $(if ($transportSetting.Present) { [string]$transportSetting.Value } else { 'winrm' })
    }
    & $set 'transport.scheme' $scheme $httpsSource
    & $set 'transport.httpListener' $httpEnabled "class table ($class)$(if (-not $httpEnabled) { ' (removed after HTTPS is verified)' })"

    # ---- TrustedHosts
    $thSetting = & $get 'trusted_hosts'
    $thText = if ($thSetting.Present) { ([string]$thSetting.Value).Trim().ToLowerInvariant() } else { 'auto' }
    if ($thText -notin 'auto', 'exact', 'wildcard') { & $issue 'AZL-061' 'error' 'os_configuration.remoting.trusted_hosts' "trusted_hosts must be auto, exact or wildcard, not '$($thSetting.Value)'."; $thText = 'auto' }
    $thMode = [string]$row.trustedHosts.mode
    $thSource = "class table ($class)"
    switch ($thText) {
        'wildcard' {
            if ($relaxed) { $thMode = 'wildcard'; $thSource = $thSetting.Source }
            else { & $issue 'AZL-061' 'error' 'os_configuration.remoting.trusted_hosts' "trusted_hosts: wildcard is honoured only in the classes lab and test, and the class is $class. Use exact (the nodes' addresses) or leave it auto." }
        }
        'exact' {
            if ($class -eq 'dmz') { & $issue 'AZL-061' 'error' 'os_configuration.remoting.trusted_hosts' 'trusted_hosts: exact is not allowed in the class dmz: it uses no TrustedHosts entries (HTTPS with a full certificate check).' }
            else { $thMode = 'exact'; $thSource = $thSetting.Source }
        }
    }
    if ($thMode -eq 'wildcard' -and -not $effectiveAny -and $thText -ne 'wildcard') { $thMode = 'exact'; $thSource = "class table ($class), exact because allow_any_source is false" }
    # exactIfHttp: exact entries only when the session can be plain HTTP: the class uses HTTP, or a bootstrap (Arc or SMB) was chosen, which opens an HTTP window.
    $bootChosenEarly = (((& $get 'bootstrap_transport').Value -as [string]) -in 'arc', 'smb', 'auto')
    if ($thMode -eq 'exactIfHttp') { $thMode = if ($scheme -eq 'http' -or ($bootChosenEarly -and [bool]$row.transport.bootstrapWindowHttp)) { 'exact' } else { 'none' } }
    $nodeAddresses = @(Get-AzlRemotingNodeAddress -Infrastructure $Infrastructure)
    & $set 'trustedHosts.mode' $thMode $thSource
    $trustedHosts = [pscustomobject]@{
        Mode = $thMode; Value = $(if ($thMode -eq 'wildcard') { '*' } else { '' }); RestoreAfterRun = [bool]$row.trustedHosts.restoreAfterRun
        Addresses = $(if ($thMode -eq 'exact') { @($nodeAddresses | ForEach-Object { $_.Address } | Select-Object -Unique) } else { @() })
    }

    # ---- firewall sources
    $sourceRow = $row.sources
    $widest4 = [int]$sourceRow.widestPrefixV4
    $widest6 = [int]$sourceRow.widestPrefixV6
    $floor4 = [int](Get-RpValue $Data 'widestPrefix.hardFloorV4' 9)
    $floor6 = [int](Get-RpValue $Data 'widestPrefix.hardFloorV6' 9)
    $limitFor = { param($info) if ($info.Family -eq 'IPv4') { $widest4 } else { $widest6 } }
    $floorFor = { param($info) if ($info.Family -eq 'IPv4') { $floor4 } else { $floor6 } }
    $sources = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $addSource = { param($info, $from, $kind) if (-not $seen.ContainsKey($info.Normalized)) { $seen[$info.Normalized] = $true; $sources.Add([pscustomobject]@{ Cidr = $info.Normalized; From = $from; Kind = $kind }) } }
    $listed = @()
    $listedSetting = & $get 'allowed_source_cidrs'
    if ($listedSetting.Present) { $listed = @(Get-RpList $listedSetting.Value) }
    $remoteAddress = @()
    $networkRemote = @()
    if ($effectiveAny) {
        $remoteAddress = @('Any')
        $networkRemote = @('Any')
    }
    else {
        foreach ($network in @(Get-RpNetworkSource -Infrastructure $Infrastructure -Purposes @($sourceRow.networkPurposes))) {
            $info = ConvertTo-AzlCidr -Text $network.Cidr
            if (-not $info.Valid) { continue }   # the schema reports a malformed subnet
            if ($info.Prefix -lt (& $limitFor $info)) {
                & $issue 'AZL-062' 'warning' $network.From "The $($network.Purpose) network $($info.Normalized) is wider than the class $class allows ($($info.Family) /$(& $limitFor $info)), so it is left out of the nodes' firewall scope. List the controller addresses in os_configuration.remoting.allowed_source_cidrs."
                continue
            }
            & $addSource $info $network.From 'network'
        }
        $networkSources = @($sources.ToArray())
        if ($sourceRow.includeAllowedSourceCidrs) {
            for ($i = 0; $i -lt $listed.Count; $i++) {
                $path = "os_configuration.remoting.allowed_source_cidrs[$i]"
                $info = ConvertTo-AzlCidr -Text ([string]$listed[$i])
                if (-not $info.Valid) { & $issue 'AZL-062' 'error' $path "'$($listed[$i])' isn't an IPv4 or IPv6 address or CIDR ($($info.Reason))."; continue }
                if ($info.Prefix -lt (& $floorFor $info)) { & $issue 'AZL-062' 'error' $path "'$($listed[$i])' is /$($info.Prefix): networks from /0 to /8 are never allowed as a source. List the controller addresses."; continue }
                if ([bool]$sourceRow.hostOnly -and -not $info.IsHost) { & $issue 'AZL-064' 'error' $path "'$($listed[$i])' is a network. The class $class takes single controller addresses only (/32 or /128)."; continue }
                if ($info.Prefix -lt (& $limitFor $info)) { & $issue 'AZL-062' 'error' $path "'$($listed[$i])' is wider than the class $class allows ($($info.Family) /$(& $limitFor $info) or narrower). List the controller addresses."; continue }
                & $addSource $info $path 'listed'
            }
        }
        elseif ($listed.Count) { & $issue 'AZL-062' 'warning' 'os_configuration.remoting.allowed_source_cidrs' "allowed_source_cidrs isn't used in the class $class." }
        $controllerCount = $sources.Count
        $networkRemote = @($sources | Where-Object { $_.Kind -eq 'network' } | ForEach-Object { $_.Cidr })
        if ($sourceRow.includeNodeAddresses) {
            foreach ($n in $nodeAddresses) {
                $info = ConvertTo-AzlCidr -Text $n.Address
                if ($info.Valid) { & $addSource $info $n.Path 'node' }
            }
        }
        $remoteAddress = @($sources | ForEach-Object { $_.Cidr })
        if ($controllerCount -eq 0) {
            switch ([string]$sourceRow.requireAtLeastOne) {
                'error' { & $issue 'AZL-063' 'error' 'os_configuration.remoting.allowed_source_cidrs' "The class $class needs at least one allowed source (the management network, an out-of-band network, or an address in allowed_source_cidrs) and none is left. The nodes' firewall would accept nobody." }
                'warning' { & $issue 'AZL-063' 'warning' 'os_configuration.remoting.allowed_source_cidrs' "The class $class has no allowed source besides the nodes themselves. List the controller addresses in allowed_source_cidrs." }
                default {
                    & $issue 'AZL-063' 'warning' 'os_configuration.remoting.allowed_source_cidrs' "No allowed source is left in the class $class. The nodes' firewall scope falls back to the local subnet."
                    $remoteAddress = @('LocalSubnet'); $networkRemote = @('LocalSubnet')
                }
            }
        }
    }
    & $set 'firewall.remoteAddress' ($remoteAddress -join ', ') $(if ($effectiveAny) { "class table ($class): Any" } else { 'computed from the master file networks, allowed_source_cidrs and the node addresses' })

    # ---- RDP and ICMP
    $scopeOf = {
        param($scopeName)
        switch ($scopeName) {
            'sameAsWinRm' { return @($remoteAddress) }
            'managementNetworks' { return @($networkRemote) }
            default { return @() }
        }
    }
    $rdpRemote = @(& $scopeOf ([string]$row.rdp.scope))
    $icmpRemote = @(& $scopeOf ([string]$row.icmp.scope))
    $rdpEnabled = [bool]$row.rdp.enabled -and $rdpRemote.Count -gt 0
    $icmpEnabled = [bool]$row.icmp.enabled -and $icmpRemote.Count -gt 0
    if ([bool]$row.rdp.enabled -and -not $rdpEnabled) { & $issue 'AZL-063' 'warning' 'networking.management.subnet' "RDP has no allowed source in the class $class (no management or out-of-band network is narrow enough), so it stays off." }
    if ([bool]$row.icmp.enabled -and -not $icmpEnabled) { & $issue 'AZL-063' 'warning' 'networking.management.subnet' "ICMP echo has no allowed source in the class $class, so it stays off." }
    & $set 'rdp' $(if ($rdpEnabled) { "on, from $($rdpRemote -join ', ')" } else { 'off' }) "class table ($class)"
    & $set 'icmp' $(if ($icmpEnabled) { "echo on, from $($icmpRemote -join ', ')" } else { 'off' }) "class table ($class)"

    # ---- the server certificate
    $certSetting = & $get 'certificate'
    $certText = if ($certSetting.Present) { ([string]$certSetting.Value).Trim() } else { '' }
    $certMode = 'none'; $certThumbprint = ''; $certReference = ''
    if ($certText) {
        $compact = $certText -replace '[\s:]', ''
        if ($compact -match '^[0-9A-Fa-f]{40}$') { $certMode = 'thumbprint'; $certThumbprint = $compact.ToUpperInvariant() }
        elseif ($certText -match '^keyvault://[^/\s]+/[^/\s]+$') { $certMode = 'keyVault'; $certReference = $certText }
        else { & $issue 'AZL-067' 'error' 'os_configuration.remoting.certificate' "certificate must be the 40-hex thumbprint of a certificate in the node's LocalMachine\My store, or keyvault://<vault>/<secret>." }
    }
    if ($certMode -eq 'none' -and -not $certText) {
        if ($httpsEnabled) {
            if ([bool]$row.certificate.allowSelfSigned) { $certMode = 'selfSigned' }
            else { & $issue 'AZL-067' 'error' 'os_configuration.remoting.certificate' "The class $class needs an enterprise certificate for the HTTPS listener (os_configuration.remoting.certificate: a thumbprint or a keyvault:// PFX reference). A self-signed per-node certificate isn't accepted." }
        }
    }
    elseif ($certText -and -not $httpsEnabled) { & $issue 'AZL-067' 'warning' 'os_configuration.remoting.certificate' 'certificate is set but WinRM does not use HTTPS in this profile, so it is not used.' }
    & $set 'certificate' $(switch ($certMode) { 'selfSigned' { 'self-signed per node (pre-join bootstrap)' } 'thumbprint' { "thumbprint $certThumbprint" } 'keyVault' { $certReference } default { 'none (no HTTPS listener)' } }) $certSetting.Source
    $certificate = [pscustomobject]@{
        Mode = $certMode; Thumbprint = $certThumbprint; Reference = $certReference
        AllowSelfSigned = [bool]$row.certificate.allowSelfSigned; SelfSignedOnlyBeforeJoin = [bool]$row.certificate.selfSignedOnlyBeforeJoin
    }

    # ---- the one-time Arc bootstrap
    $bootSetting = & $get 'bootstrap_transport'
    $bootText = if ($bootSetting.Present) { ([string]$bootSetting.Value).Trim().ToLowerInvariant() } else { 'none' }
    if ($bootText -notin 'none', 'arc', 'smb', 'auto') { & $issue 'AZL-060' 'error' 'os_configuration.remoting.bootstrap_transport' "bootstrap_transport must be none, arc, smb or auto, not '$($bootSetting.Value)'."; $bootText = 'none' }
    $approval = [string]$row.bootstrap.approval
    $approved = ($ov.ContainsKey('approved_bootstrap') -and (ConvertTo-RpBool $ov['approved_bootstrap']) -eq $true)
    $approvalSource = if ($approved) { [string]$(if ($ov.ContainsKey('approved_bootstrap_source')) { $ov['approved_bootstrap_source'] } else { 'parameter' }) } else { '' }
    if ($approved -and $approval -eq 'perRun' -and $approvalSource -eq 'settings') {
        $approved = $false
        & $issue 'RP-BOOTSTRAP' 'warning' 'approved_bootstrap' "The class $class needs the bootstrap approved on every run (-ApprovedBootstrap); an approval kept in a settings file doesn't count."
    }
    $chosen = ($bootText -ne 'none')
    $routes = @(switch ($bootText) { 'arc' { 'arc' } 'smb' { 'smb' } 'auto' { 'smb'; 'arc' } })
    $bootstrap = [pscustomobject]@{
        Allowed = [bool]$row.bootstrap.allowed; Chosen = $chosen; Transport = $bootText; Routes = $routes; Approval = $approval
        RequiresExplicitChoice = [bool]$row.bootstrap.requiresExplicitChoice; Approved = $approved; ApprovalSource = $approvalSource
        Permitted = $false; Logged = [bool]$row.bootstrap.logged; Reason = ''
    }
    $verdict = Test-AzlBootstrapPermitted -Bootstrap $bootstrap -Class $class
    $bootstrap.Permitted = $verdict.Permitted
    $bootstrap.Reason = $verdict.Reason
    & $set 'bootstrap' $(if ($bootstrap.Permitted) { "bootstrap permitted ($($routes -join ', '))" } elseif ($chosen) { 'bootstrap chosen, not permitted' } else { 'no bootstrap' }) $bootSetting.Source
    # ---- the rest of the row
    & $set 'listener.bind' ([string]$row.listener.bind) "class table ($class)"
    & $set 'authentication' ([string]$row.authentication.mode) "class table ($class)"
    $locator = if ($effectiveAny -or $thMode -eq 'wildcard') { 'relaxed-wildcard' } elseif ($relaxed) { 'relaxed-restricted' } else { 'restricted' }

    # ---- what a relaxed class says out loud
    if ($relaxed) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($effectiveAny) { $parts.Add("the nodes accept WinRM, RDP and ICMP from any source") }
        if ($thMode -eq 'wildcard') { $parts.Add("TrustedHosts is '*' on the machine running the automation (restored afterwards)") }
        if ($httpEnabled) { $parts.Add("WinRM over HTTP 5985 is allowed") }
        if ($parts.Count -eq 0) { $parts.Add('allow_any_source is false, so the sources are restricted') }
        $isolationText = if ($isolation) { 'You confirmed the nodes'' network has no route to production.' } else { 'Isolation is not confirmed (os_configuration.remoting.isolation_confirmed).' }
        & $issue 'AZL-068' 'warning' 'scenario.environment_class' "Relaxed remote management posture (class $class): $($parts -join '; '). The baseline still holds (no unencrypted traffic, no Basic or CredSSP, no SkipCACheck or SkipCNCheck, TLS 1.2 or higher). $isolationText Never use this class where the nodes can be reached from a production network."
    }
    elseif ($thMode -eq 'wildcard') { & $issue 'AZL-061' 'error' 'os_configuration.remoting.trusted_hosts' "A TrustedHosts wildcard is never used in the class $class." }

    $issueArray = $issues.ToArray()
    [pscustomobject]@{
        Class           = $class
        ClassSource     = $classSource
        Valid           = ($valid -and @($issueArray | Where-Object Severity -eq 'error').Count -eq 0)
        ClassValid      = $valid
        Relaxed         = $relaxed
        Posture         = $locator
        Summary         = [string]$row.summary
        Settings        = $settings
        Firewall        = [pscustomobject]@{
            AnySource = $effectiveAny; RemoteAddress = $remoteAddress; Profiles = @('Domain', 'Private', 'Public'); LocalAddress = 'management IP of the node when known'
            RdpEnabled = $rdpEnabled; RdpRemoteAddress = $rdpRemote; IcmpEnabled = $icmpEnabled; IcmpRemoteAddress = $icmpRemote; Sources = $sources.ToArray()
        }
        TrustedHosts    = $trustedHosts
        Transport       = $transport
        Listener        = [pscustomobject]@{ Bind = [string]$row.listener.bind }
        Authentication  = [pscustomobject]@{ Mode = [string]$row.authentication.mode; Description = [string]$row.authentication.description }
        Rdp             = [pscustomobject]@{ Enabled = $rdpEnabled; Nla = $true }
        Icmp            = [pscustomobject]@{ Enabled = $icmpEnabled; EchoOnly = $true }
        Certificate     = $certificate
        Bootstrap       = $bootstrap
        Baseline        = [pscustomobject]$Data.baseline
        NodeToNode      = [string]$row.nodeToNode
        AfterDomainJoin = [pscustomobject]$row.afterDomainJoin
        ServerIdentity  = [string]$row.serverIdentity
        NodeAddresses   = $nodeAddresses
        DataVersion     = [string](Get-RpValue $Data 'version' '')
        Issues          = $issueArray
        Warnings        = @($issueArray | Where-Object Severity -eq 'warning' | ForEach-Object { $_.Message })
        Errors          = @($issueArray | Where-Object Severity -eq 'error' | ForEach-Object { $_.Message })
    }
}

function Assert-AzlRemotingProfile {
    <#
    .SYNOPSIS
        Throws an input error (the run exits with code 2) when the profile has errors; the message names every one. A bad class
        names the allowed values.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Profile)
    if ($Profile.Errors.Count -eq 0) { return }
    $exception = [System.ArgumentException]::new("The remote management profile can't be used:`n$(($Profile.Errors | ForEach-Object { "- $_" }) -join "`n")")
    $exception.Data['AzlInput'] = $true
    throw $exception
}

function Get-AzlRemotingFinding {
    <#
    .SYNOPSIS
        Validator findings (rules AZL-060 to AZL-068) for a master file, from the same resolver the run uses.
    .OUTPUTS
        Id, Severity, Path, Message, LearnUrl: the shape of AzlInfrastructure's findings.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Infrastructure, [string]$DataPath = $script:DefaultDataPath)
    $profile = $null
    try { $profile = Resolve-AzlRemotingProfile -Infrastructure $Infrastructure -DataPath $DataPath }
    catch { return }   # a missing table is a toolkit problem, not a finding on the master file
    foreach ($i in @($profile.Issues | Where-Object { $_.Id -like 'AZL-*' })) {
        [pscustomobject]@{ Id = $i.Id; Severity = $i.Severity; Path = $i.Path; Message = $i.Message; LearnUrl = '' }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# What the run shows and records
# ---------------------------------------------------------------------------------------------------------------------

function Format-AzlRemotingProfile {
    <#
    .SYNOPSIS
        The effective profile as text lines: the class and where it came from, each setting with its source, then warnings and
        errors. Printed at the start of the run and kept in the report.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object]$Profile)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Remote management profile: class $($Profile.Class) ($($Profile.ClassSource)); posture $($Profile.Posture)")
    $lines.Add("  $($Profile.Summary)")
    foreach ($name in $Profile.Settings.Keys) {
        if ($name -eq 'class') { continue }
        $s = $Profile.Settings[$name]
        $lines.Add(("  {0,-24} {1}  [{2}]" -f $name, $s.Value, $s.Source))
    }
    $lines.Add("  WinRM $(if ($Profile.Transport.HttpsEnabled) { "HTTPS $($Profile.Transport.HttpsPort)" })$(if ($Profile.Transport.HttpsEnabled -and $Profile.Transport.HttpEnabled) { ' and ' })$(if ($Profile.Transport.HttpEnabled) { "HTTP $($Profile.Transport.HttpPort)" })$(if ($Profile.Transport.RemoveHttpAfterHttps) { '; the HTTP listener is removed once HTTPS is verified' })")
    $lines.Add("  authentication: $($Profile.Authentication.Description)")
    $lines.Add("  Arc bootstrap: $($Profile.Bootstrap.Reason)")
    foreach ($w in $Profile.Warnings) { $lines.Add("  WARNING: $w") }
    foreach ($e in $Profile.Errors) { $lines.Add("  ERROR: $e") }
    return $lines.ToArray()
}

function ConvertTo-AzlRemotingReport {
    <#
    .SYNOPSIS
        The profile as an ordered hashtable for report.json: class, posture, the firewall scope, the TrustedHosts mode, transport,
        bootstrap and the warnings. Holds no secret (a certificate is a thumbprint or a keyvault:// reference).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Profile)
    $settings = [ordered]@{}
    foreach ($k in $Profile.Settings.Keys) { $settings[$k] = [ordered]@{ value = [string]$Profile.Settings[$k].Value; source = $Profile.Settings[$k].Source } }
    [ordered]@{
        class           = $Profile.Class
        classSource     = $Profile.ClassSource
        posture         = $Profile.Posture
        relaxed         = $Profile.Relaxed
        settings        = $settings
        firewall        = [ordered]@{
            anySource = $Profile.Firewall.AnySource; remoteAddress = @($Profile.Firewall.RemoteAddress); rdpEnabled = $Profile.Firewall.RdpEnabled; rdpRemoteAddress = @($Profile.Firewall.RdpRemoteAddress)
            icmpEnabled = $Profile.Firewall.IcmpEnabled; icmpRemoteAddress = @($Profile.Firewall.IcmpRemoteAddress); profiles = @($Profile.Firewall.Profiles)
            sources = @($Profile.Firewall.Sources | ForEach-Object { [ordered]@{ cidr = $_.Cidr; from = $_.From; kind = $_.Kind } })
        }
        trustedHosts    = [ordered]@{ mode = $Profile.TrustedHosts.Mode; value = $Profile.TrustedHosts.Value; restoreAfterRun = $Profile.TrustedHosts.RestoreAfterRun }
        transport       = [ordered]@{ scheme = $Profile.Transport.Scheme; https = $Profile.Transport.HttpsEnabled; http = $Profile.Transport.HttpEnabled; removeHttpAfterHttps = $Profile.Transport.RemoveHttpAfterHttps }
        authentication  = $Profile.Authentication.Mode
        certificate     = [ordered]@{ mode = $Profile.Certificate.Mode; thumbprint = $Profile.Certificate.Thumbprint; reference = $Profile.Certificate.Reference }
        bootstrap       = [ordered]@{ chosen = $Profile.Bootstrap.Chosen; permitted = $Profile.Bootstrap.Permitted; approval = $Profile.Bootstrap.Approval; approved = $Profile.Bootstrap.Approved; reason = $Profile.Bootstrap.Reason }
        baseline        = $Profile.Baseline
        warnings        = @($Profile.Warnings)
        errors          = @($Profile.Errors)
    }
}

Export-ModuleMember -Function ConvertTo-AzlCidr, Get-AzlRemotingProfileData, Get-AzlRemotingClass, Get-AzlRemotingNodeAddress, Resolve-AzlRemotingProfile, Assert-AzlRemotingProfile, Test-AzlBootstrapPermitted, Get-AzlRemotingFinding, Format-AzlRemotingProfile, ConvertTo-AzlRemotingReport
