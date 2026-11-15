#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the configuration of every top-of-rack switch of infrastructure.yml from the vendor's switch template. Sends nothing to a switch.

.DESCRIPTION
    Phase 03 (network infrastructure), Task 02 (switches). For each entry of network_devices whose type is switch, the script picks the template
    of its vendor (config/network-devices/switches/<vendor>/*.template; Dell: tor.os10.template), fills every placeholder from
    infrastructure.yml and writes <OutputDirectory>/<hostname>.cfg. The network team reviews the file and applies it on the switch; the script
    never connects to a switch, a node or Azure.

    Every value of a site comes from the file (the template names each key, see its header): the switch's hostname, management address,
    ports, MTU and pair (network_devices[]), the out-of-band network (networking.oob), the VLANs of the management, out-of-band, storage
    and workload networks, the DNS and NTP servers, the time zone of the site, and the QoS of the storage intent. The QoS follows Network ATC:
    the priorities and the SMB bandwidth are networking.intents[].overrides.qos of the storage intent, or their registry defaults (cluster 7,
    SMB 3, 50 percent; Learn: Network ATC default values), and the cluster heartbeat reservation is 1 percent when the storage adapters are
    faster than 10 Gbps, else 2 (the same page). A key the file lacks falls back to its registry default (read from the generated
    infrastructure.schema.json); a key with no default that the template needs stops the run with its name.

    No password is read or written: network_devices[].credentials.password is a secret reference and the output only names it. Syslog and
    SNMP forwarding are parked (owner) and not in the template. A switch whose vendor has no template is reported and skipped.

    -WhatIf renders and checks everything and writes nothing (the rendered text is in the output objects).

    Exit codes: 0 every switch was written (or rendered with -WhatIf), or the file lists none; 1 a file could not be written or a rendered
    configuration still holds a placeholder; 2 a value in the file is missing or not usable (the message names the key).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys the template names are read; the whole file is not validated here.

.PARAMETER OutputDirectory
    Where the configurations go, one <hostname>.cfg per switch. Keep it out of the repository: the files hold the site's addresses.

.PARAMETER Hostname
    Optional. Only the switches with these host names.

.PARAMETER TemplateRoot
    The folder with one folder per vendor. Default: config/network-devices/switches of this toolkit.

.EXAMPLE
    ./New-SwitchConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory ./switch-config -WhatIf

    Renders the configuration of every switch and shows it without writing a file.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string[]]$Hostname,
    [string]$TemplateRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', '..'))
Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', 'secrets', 'AzlSecret.psm1')) -Force
if (-not $TemplateRoot) { $TemplateRoot = [IO.Path]::Combine($repo, 'config', 'network-devices', 'switches') }
$schemaPath = [IO.Path]::Combine($repo, 'config', 'variables', 'schema', 'infrastructure.schema.json')

# The kind of device this script renders (a type value of network_devices).
$DeviceType = 'switch'
# 802.1p priorities 0 to 7 (IEEE 802.1Q); the default class takes the ones the storage intent does not use.
$AllPriorities = 0..7
# Network ATC's cluster heartbeat reservation (Learn: Network ATC default values): 1 percent above 10 Gbps, else 2 percent.
$AtcFastAdapterGbps = 10
$AtcClusterPercentFast = 1
$AtcClusterPercentSlow = 2

function Write-Line([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }
function Exit-InputProblem([string[]]$Message) { foreach ($m in $Message) { Write-Error $m -ErrorAction Continue }; exit 2 }

# ---------------------------------------------------------------------------------------------------------------------
# Reading values
# ---------------------------------------------------------------------------------------------------------------------
function Get-Child([object]$Node, [string]$Name) {
    if ($Node -is [System.Collections.IDictionary] -and $Node.Contains($Name)) { return , $Node[$Name] }
    return $null
}
function Test-Empty([object]$Value) {
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return -not $Value.Trim() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) { return @($Value).Count -eq 0 }
    return $false
}
function Test-Contains([object]$Value, [string]$Wanted) {
    foreach ($v in @($Value)) { if ([string]$v -ieq $Wanted) { return $true } }
    return $false
}

# The registry default of a key, from the generated infrastructure.schema.json (selectors read as []).
function Get-SchemaDefault([string]$Path) {
    $node = $script:Schema
    foreach ($segment in ($Path -split '\.')) {
        $m = [regex]::Match($segment, '^(?<name>[A-Za-z0-9_]+)(?<sel>\[[^\]]*\])?$')
        if (-not $m.Success) { return $null }
        $properties = Get-Child $node 'properties'
        $node = Get-Child $properties $m.Groups['name'].Value
        if ($null -eq $node) { return $null }
        if ($m.Groups['sel'].Success) { $node = Get-Child $node 'items'; if ($null -eq $node) { return $null } }
    }
    return Get-Child $node 'default'
}

# One term: a dotted path with [] (every element) or [key=value] (the first element whose key is or contains value).
# network_devices[] is the switch being rendered; a path that starts with . is relative to the element of the {{#each}}.
# Returns @{ Values; IsList; Path }.
function Resolve-Term([string]$Term, [hashtable]$Scope) {
    $term = $Term.Trim()
    if ($term -eq '.') { return @{ Values = @($Scope.Element); IsList = $false; Path = $Scope.ElementPath } }
    if ($term.StartsWith('.')) {
        $nodes = @(, $Scope.Element); $rest = $term.Substring(1); $base = $Scope.ElementPath
    }
    elseif ($term.StartsWith('atc.')) { return @{ Values = @(Get-AtcValue $term.Substring(4)); IsList = $false; Path = $term } }
    elseif ($term.StartsWith('network_devices[].')) {
        $nodes = @(, $Scope.Device); $rest = $term.Substring('network_devices[].'.Length); $base = 'network_devices[]'
    }
    else { $nodes = @(, $script:Infra); $rest = $term; $base = '' }
    $isList = $false
    foreach ($segment in ($rest -split '\.')) {
        $m = [regex]::Match($segment, '^(?<name>[A-Za-z0-9_]+)(?:\[(?<filter>[^\]]*)\])?$')
        if (-not $m.Success) { throw "Template placeholder '$Term' has a part '$segment' that is not a key." }
        $next = [System.Collections.Generic.List[object]]::new()
        foreach ($n in $nodes) {
            $child = Get-Child $n $m.Groups['name'].Value
            if ($null -eq $child) { continue }
            if (-not $m.Groups['filter'].Success) { $next.Add($child); continue }
            $filter = $m.Groups['filter'].Value
            if (-not $filter) { $isList = $true; foreach ($e in @($child)) { if ($null -ne $e) { $next.Add($e) } }; continue }
            $kv = $filter -split '=', 2
            $hit = @(@($child) | Where-Object { Test-Contains (Get-Child $_ $kv[0]) $kv[1] }) | Select-Object -First 1
            if ($null -ne $hit) { $next.Add($hit) }
        }
        $nodes = @($next)
    }
    $path = if ($base) { "$base.$rest".TrimEnd('.') } else { $rest }
    # A key whose value is a list (ntp_servers, ports.node_ports) gives its elements.
    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $nodes) {
        if ($n -is [System.Collections.IEnumerable] -and $n -isnot [string] -and $n -isnot [System.Collections.IDictionary]) {
            $isList = $true
            foreach ($e in $n) { if (-not (Test-Empty $e)) { $values.Add($e) } }
        }
        elseif (-not (Test-Empty $n)) { $values.Add($n) }
    }
    # A key the file lacks takes its registry default (selectors read as []).
    if (-not $values.Count -and -not $isList) {
        $default = Get-SchemaDefault ($path -replace '\[[^\]]+\]', '[]')
        if ($null -ne $default) { $values.Add($default) }
    }
    return @{ Values = @($values); IsList = $isList; Path = $path }
}

function ConvertTo-VlanList([object[]]$Values, [object[]]$Except) {
    $skip = @($Except | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    @($Values | Where-Object { $null -ne $_ -and [string]$_ -match '^\d+$' } | ForEach-Object { [int]$_ } |
            Where-Object { $_ -gt 0 -and $_ -notin $skip } | Sort-Object -Unique)
}

# An expression: terms joined by +, then an optional filter. Returns @{ Values; IsList; Paths }.
function Resolve-Expression([string]$Expression, [hashtable]$Scope) {
    $parts = $Expression -split '\|', 2
    $terms = @($parts[0] -split '\+' | ForEach-Object { Resolve-Term $_ $Scope })
    $values = @($terms | ForEach-Object { $_.Values })
    $isList = $terms.Count -gt 1 -or @($terms | Where-Object { $_.IsList }).Count -gt 0
    $paths = @($terms | ForEach-Object { $_.Path })
    if ($parts.Count -eq 2) {
        $filter = $parts[1].Trim()
        switch ($filter) {
            'vlan_set' { $values = @(ConvertTo-VlanList $values @()); $isList = $true }
            'vlan_list' { $list = @(ConvertTo-VlanList $values @()); $values = $(if ($list.Count) { @($list -join ',') } else { @() }); $isList = $true }
            'trunk_vlans' {
                $native = (Resolve-Term 'network_devices[].ports.native_vlan_id' $Scope).Values
                $list = @(ConvertTo-VlanList $values $native); $values = $(if ($list.Count) { @($list -join ',') } else { @() }); $isList = $true
            }
            'prefix_length' { $values = @($values | ForEach-Object { ([string]$_ -split '/')[1] } | Where-Object { $_ }) }
            'colon_mac' { $values = @($values | ForEach-Object { ([string]$_).Replace('-', ':').ToLowerInvariant() }) }
            'os10_timezone' { $values = @($values | ForEach-Object { ConvertTo-Os10TimeZone ([string]$_) }) }
            default { throw "Template filter '$filter' is not known." }
        }
    }
    return @{ Values = @($values | Where-Object { $null -ne $_ }); IsList = $isList; Paths = $paths }
}

# Dell OS10 'clock timezone <name> <hours> <minutes>': the standard (not daylight) UTC offset of the Windows time zone ID.
function ConvertTo-Os10TimeZone([string]$Id) {
    try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($Id) }
    catch { $script:Problems.Add("site.time_zone '$Id' is not a Windows time zone ID this machine knows (for example UTC or Eastern Standard Time)."); return $null }
    $offset = $zone.BaseUtcOffset
    $name = if ($Id -match '\s') { -join @($Id -split '\s+' | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() }) } else { $Id }
    $sign = if ($offset -lt [TimeSpan]::Zero) { '-' } else { '' }
    '{0} {1}{2} {3}' -f $name, $sign, [Math]::Abs($offset.Hours), [Math]::Abs($offset.Minutes)
}

# The values Network ATC derives (Learn: Network ATC default values), for the intent whose traffic includes storage.
function Get-AtcValue([string]$Name) {
    $scope = @{ Device = $script:Device; Element = $null; ElementPath = '' }
    $qos = 'networking.intents[traffic=storage].overrides.qos.'
    $smb = @((Resolve-Term ($qos + 'smb_priority') $scope).Values)[0]
    $cluster = @((Resolve-Term ($qos + 'cluster_priority') $scope).Values)[0]
    switch ($Name) {
        'default_priorities' {
            $rest = @($AllPriorities | Where-Object { $_ -ne [int]$smb -and $_ -ne [int]$cluster })
            # 0,1,2,4,5,6 -> 0-2,4-6
            $ranges = [System.Collections.Generic.List[string]]::new(); $start = $rest[0]; $previous = $rest[0]
            foreach ($p in @($rest | Select-Object -Skip 1) + @(-1)) {
                if ($p -eq $previous + 1) { $previous = $p; continue }
                $ranges.Add($(if ($start -eq $previous) { "$start" } else { "$start-$previous" })); $start = $p; $previous = $p
            }
            return ($ranges -join ',')
        }
        'cluster_bandwidth_percent' { return (Get-AtcClusterPercent) }
        'default_bandwidth_percent' {
            $smbPercent = [int](@((Resolve-Term ($qos + 'smb_bandwidth_percent') $scope).Values)[0])
            $clusterPercent = Get-AtcClusterPercent
            if ($null -eq $clusterPercent) { return $null }
            return (100 - $smbPercent - [int]$clusterPercent)
        }
        default { throw "Template value atc.$Name is not known." }
    }
}
function Get-AtcClusterPercent {
    $scope = @{ Device = $script:Device; Element = $null; ElementPath = '' }
    $adapters = @((Resolve-Term 'networking.intents[traffic=storage].adapters' $scope).Values | ForEach-Object { @($_) } | ForEach-Object { [string]$_ })
    $speeds = [System.Collections.Generic.List[double]]::new()
    $ports = @((Resolve-Term 'hardware.network_cards[].ports[]' $scope).Values) + @((Resolve-Term 'nodes[].network_adapters[]' $scope).Values)
    foreach ($port in $ports) {
        if ((Test-Contains $adapters ([string](Get-Child $port 'name'))) -and -not (Test-Empty (Get-Child $port 'speed_gbps'))) { $speeds.Add([double](Get-Child $port 'speed_gbps')) }
    }
    if (-not $speeds.Count) {
        $script:Problems.Add("The storage intent's adapters ($($adapters -join ', ')) have no speed: set hardware.network_cards[].ports[].speed_gbps (or nodes[].network_adapters[].speed_gbps). Network ATC reserves 1 percent for the cluster heartbeat above 10 Gbps and 2 percent otherwise, and the switch must match.")
        return $null
    }
    if (@($speeds | Where-Object { $_ -gt $AtcFastAdapterGbps }).Count) { return $AtcClusterPercentFast }
    return $AtcClusterPercentSlow
}

# ---------------------------------------------------------------------------------------------------------------------
# The template
# ---------------------------------------------------------------------------------------------------------------------
# Lines -> a tree of @{ Kind = text|each|if; Text; Expression; Children }.
function ConvertTo-TemplateTree([string[]]$Lines) {
    $root = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $current = $root
    $lineNumber = 0
    foreach ($line in $Lines) {
        $lineNumber++
        $open = [regex]::Match($line, '^\s*\{\{#(?<kind>each|if)\s+(?<expr>.+?)\}\}\s*$')
        $close = [regex]::Match($line, '^\s*\{\{/(?<kind>each|if)\}\}\s*$')
        if ($open.Success) {
            $node = @{ Kind = $open.Groups['kind'].Value; Expression = $open.Groups['expr'].Value; Children = [System.Collections.Generic.List[object]]::new(); Line = $lineNumber }
            $current.Add($node); $stack.Push(@{ Node = $node; Parent = $current }); $current = $node.Children
        }
        elseif ($close.Success) {
            if (-not $stack.Count) { throw "Template line ${lineNumber}: {{/$($close.Groups['kind'].Value)}} without an opening block." }
            $top = $stack.Pop()
            if ($top.Node.Kind -ne $close.Groups['kind'].Value) { throw "Template line ${lineNumber}: {{/$($close.Groups['kind'].Value)}} closes {{#$($top.Node.Kind)}} of line $($top.Node.Line)." }
            $current = $top.Parent
        }
        else { $current.Add(@{ Kind = 'text'; Text = $line; Line = $lineNumber }) }
    }
    if ($stack.Count) { throw "Template: {{#$($stack.Peek().Node.Kind)}} of line $($stack.Peek().Node.Line) is not closed." }
    return $root
}

function Test-Condition([string]$Condition, [hashtable]$Scope) {
    # path=value: the = outside a selector ([traffic=storage] is part of the path).
    $depth = 0; $at = -1
    for ($i = 0; $i -lt $Condition.Length; $i++) {
        switch ($Condition[$i]) { '[' { $depth++ } ']' { $depth-- } '=' { if ($depth -eq 0) { $at = $i } } }
    }
    $path = if ($at -ge 0) { $Condition.Substring(0, $at) } else { $Condition }
    $r = Resolve-Expression $path $Scope
    if ($at -ge 0) { $wanted = $Condition.Substring($at + 1).Trim(); return (@($r.Values | Where-Object { [string]$_ -ieq $wanted }).Count -gt 0) }
    return ($r.Values.Count -gt 0)
}

function Invoke-TemplateNode([object[]]$Nodes, [hashtable]$Scope, [System.Collections.Generic.List[string]]$Out) {
    foreach ($node in $Nodes) {
        switch ($node.Kind) {
            'if' { if (Test-Condition $node.Expression $Scope) { Invoke-TemplateNode $node.Children $Scope $Out } }
            'each' {
                $r = Resolve-Expression $node.Expression $Scope
                foreach ($element in $r.Values) {
                    $inner = @{ Device = $Scope.Device; Element = $element; ElementPath = (($r.Paths | Select-Object -First 1) -replace '\[[^\]]*\]$', '[]') }
                    Invoke-TemplateNode $node.Children $inner $Out
                }
            }
            default {
                $line = $node.Text
                $drop = $false
                $rendered = [regex]::Replace($line, '\{\{(?<expr>[^#/][^}]*)\}\}', {
                        param($match)
                        $r = Resolve-Expression $match.Groups['expr'].Value $Scope
                        if (-not $r.Values.Count) {
                            if ($r.IsList) { $script:DropLine = $true }
                            else { $script:Problems.Add("$($script:DeviceName): $($r.Paths -join ' + ') has no value (template line $($node.Line)).") }
                            return $match.Value
                        }
                        return (@($r.Values | ForEach-Object { [string]$_ }) -join ',')
                    })
                if ($script:DropLine) { $drop = $true; $script:DropLine = $false }
                if (-not $drop) { $Out.Add($rendered) }
            }
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The switches
# ---------------------------------------------------------------------------------------------------------------------
try { $script:Infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
$script:Schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$script:DropLine = $false

$listed = Get-Child $script:Infra 'network_devices'
$devices = @(@($listed) | Where-Object { $_ -is [System.Collections.IDictionary] -and ([string](Get-Child $_ 'type')) -ieq $DeviceType })
if ($Hostname) { $devices = @($devices | Where-Object { [string](Get-Child $_ 'hostname') -in $Hostname }) }
if ($devices.Count -eq 0) { Write-Line "The file lists no network_devices of type $DeviceType$(if ($Hostname) { " named $($Hostname -join ', ')" }): nothing to do."; exit 0 }

$inputProblems = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$seen = @{}
foreach ($device in $devices) {
    $script:Device = $device
    $script:DeviceName = ([string](Get-Child $device 'hostname')).Trim()
    $script:Problems = [System.Collections.Generic.List[string]]::new()
    if (-not $script:DeviceName) { $inputProblems.Add('A network_devices entry of type switch has no hostname.'); continue }
    if ($seen.ContainsKey($script:DeviceName.ToLowerInvariant())) { $inputProblems.Add("network_devices: the hostname '$($script:DeviceName)' is listed twice."); continue }
    $seen[$script:DeviceName.ToLowerInvariant()] = $true

    $vendor = ([string](Get-Child $device 'vendor')).Trim().ToLowerInvariant()
    $folder = if ($vendor) { [IO.Path]::Combine($TemplateRoot, $vendor) } else { '' }
    $templates = @(if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) { Get-ChildItem -LiteralPath $folder -File -Filter '*.template' })
    if ($templates.Count -ne 1) {
        Write-Line "[skip]    $($script:DeviceName): no switch template for vendor '$vendor' ($(if ($templates.Count) { 'more than one' } else { 'none' }) in config/network-devices/switches/$vendor)."
        $results.Add([pscustomobject]@{ Hostname = $script:DeviceName; Template = ''; Path = ''; Action = 'Skipped'; Text = '' })
        continue
    }

    # The checks the template cannot make itself.
    $scope = @{ Device = $device; Element = $null; ElementPath = '' }
    if (Test-Empty (Resolve-Term 'network_devices[].mtu' $scope).Values) { $script:Problems.Add("$($script:DeviceName): network_devices[].mtu is not set (the frame size of the switch ports, for example 9216).") }
    if (Test-Empty (Resolve-Term 'network_devices[].ports.node_ports' $scope).Values) { $script:Problems.Add("$($script:DeviceName): network_devices[].ports.node_ports is empty (the ports cabled to the machines).") }
    $managementVlan = @((Resolve-Term 'networking.management.vlan_id' $scope).Values)
    if ((-not $managementVlan.Count -or [int]$managementVlan[0] -eq 0) -and (Test-Empty (Resolve-Term 'network_devices[].ports.native_vlan_id' $scope).Values)) {
        $script:Problems.Add("$($script:DeviceName): networking.management.vlan_id is 0 (untagged), so network_devices[].ports.native_vlan_id must name the switch VLAN of the untagged management traffic.")
    }
    if (-not (Test-Empty (Resolve-Term 'network_devices[].ha.domain_id' $scope).Values)) {
        foreach ($k in 'ha.peer_address', 'ha.priority', 'ha.system_mac', 'ports.peer_link') {
            if (Test-Empty (Resolve-Term "network_devices[].$k" $scope).Values) { $script:Problems.Add("$($script:DeviceName): network_devices[].ha.domain_id is set, so network_devices[].$k is needed.") }
        }
    }
    $passwordReference = @((Resolve-Term 'network_devices[].credentials.password' $scope).Values)
    if ($passwordReference.Count -and -not (Get-AzlSecretProvider -Reference ([string]$passwordReference[0]))) {
        $script:Problems.Add("$($script:DeviceName): network_devices[].credentials.password is a value, not a secret reference (keyvault://, env://, file:// or command://). It is never written.")
        $passwordReference = @()
    }

    $lines = @(Get-Content -LiteralPath $templates[0].FullName | Where-Object { -not $_.StartsWith('!!') })
    $out = [System.Collections.Generic.List[string]]::new()
    Invoke-TemplateNode (ConvertTo-TemplateTree $lines) $scope $out
    if ($script:Problems.Count) { $inputProblems.AddRange($script:Problems); continue }
    $text = ($out -join "`n") + "`n"
    $left = [regex]::Matches($text, '\{\{[^}]*\}\}')
    if ($left.Count) {
        Write-Error "$($script:DeviceName): the rendered configuration still holds $($left.Count) placeholder(s), for example $($left[0].Value). The template is wrong." -ErrorAction Continue
        exit 1
    }
    $results.Add([pscustomobject]@{ Hostname = $script:DeviceName; Template = $templates[0].Name; Path = [IO.Path]::Combine($OutputDirectory, "$($script:DeviceName).cfg"); Action = 'Rendered'; Text = $text })
}
if ($inputProblems.Count) { Exit-InputProblem @($inputProblems) }

$failed = 0
foreach ($r in $results | Where-Object { $_.Action -eq 'Rendered' }) {
    if ($PSCmdlet.ShouldProcess($r.Path, "Write the switch configuration of $($r.Hostname)")) {
        try {
            if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { $null = New-Item -ItemType Directory -Path $OutputDirectory -Force }
            [IO.File]::WriteAllText($r.Path, $r.Text, [Text.UTF8Encoding]::new($false))
            $r.Action = 'Written'
            Write-Line "[written] $($r.Hostname): $($r.Path) (template $($r.Template))"
        }
        catch { $failed++; $r.Action = 'Failed'; Write-Error "$($r.Hostname): cannot write $($r.Path): $($_.Exception.Message)" -ErrorAction Continue }
    }
    else { Write-Line "[whatif]  $($r.Hostname): would write $($r.Path) (template $($r.Template))" }
}
$results
if ($failed) { exit 1 }
exit 0
