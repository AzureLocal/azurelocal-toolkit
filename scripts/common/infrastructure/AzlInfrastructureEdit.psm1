#Requires -Version 7.0
<#
.SYNOPSIS
    Writes discovered hardware values into infrastructure.yml without reformatting the file.

.DESCRIPTION
    The file is edited line by line: only the value of one scalar changes (or one line is inserted under an existing parent),
    so comments, order and quoting stay as the operator wrote them. A flow-style entry (- { name: ..., mac_address: ... } or
    bmc: { ip_address: ... }) is edited inside its braces. A key path that is not found is reported and skipped, never guessed.

    Get-AzlDiscoveryChange          What discovery would change for each machine: serial_number, the BMC MAC and type, and
                                    the MAC and the hardware facts of each port (owner decision O7).
    Get-AzlHardwareFactChange       What an inventory would change in hardware.*: the keys every machine agrees on.
    ConvertTo-AzlInventoryDiscoveryView   One node of a Get-HardwareInventory.ps1 inventory as the view the two above read.
    Edit-AzlYamlValue               One edit on a list of lines. Path: 'nodes', '[name=node-1]', 'serial_number'.
    Test-AzlYamlEdit                Where each change would land, on a copy in memory: nothing is written.
    Invoke-AzlYamlEdit              Applies the changes to a file, with a backup, after a confirmation.

    Roles, IP assignment and addresses are never written: discovery cannot read them from hardware. Firmware, BIOS and BMC
    versions, the TPM and Secure Boot state and per-drive serials are evidence (they stay in the discovery files), never keys.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'redfish', 'AzlRedfishCore.psm1'))
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'redfish', 'AzlRedfishDell.psm1'))
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'idrac-management', 'AzlDellRedfish.psm1'))

$script:NotReported = 'not reported'

#region YAML line editing

function Get-LineIndent([string]$Line) { return $Line.Length - $Line.TrimStart().Length }
function Test-SkippableLine([string]$Line) { $t = $Line.Trim(); return ($t -eq '' -or $t.StartsWith('#')) }

function Get-ScopeEnd {
    # The first line after $From that leaves the block of a key at $Indent. A sequence at the key's own indent belongs to it.
    param([System.Collections.Generic.List[string]]$Lines, [int]$From, [int]$Indent, [int]$Limit, [bool]$SequenceAtIndent)
    for ($i = $From; $i -lt $Limit; $i++) {
        $line = $Lines[$i]
        if (Test-SkippableLine $line) { continue }
        $ind = Get-LineIndent $line
        if ($ind -gt $Indent) { continue }
        if ($SequenceAtIndent -and $ind -eq $Indent -and $line.TrimStart().StartsWith('-')) { continue }
        return $i
    }
    return $Limit
}

function ConvertTo-YamlScalar($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) { return ([double]$Value).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [System.Collections.IDictionary]) { return '{ ' + (@($Value.Keys | ForEach-Object { "${_}: $(ConvertTo-YamlScalar $Value[$_])" }) -join ', ') + ' }' }
    return '"' + (([string]$Value) -replace '\\', '\\' -replace '"', '\"') + '"'
}

function ConvertFrom-YamlScalarText([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'")))) { return $t.Substring(1, $t.Length - 2) }
    return $t
}

function Test-ScalarStart {
    # A quote opens a quoted scalar only where a scalar starts: after '{', '[', ',' or ':' (spaces ignored). An apostrophe inside a
    # plain scalar (O'Brien) is just text.
    param([string]$Line, [int]$Index)
    for ($k = $Index - 1; $k -ge 0; $k--) {
        if ($Line[$k] -eq ' ') { continue }
        return ($Line[$k] -in '{', '[', ',', ':')
    }
    return $true
}

function Get-FlowMapSpan {
    # The braces of a flow mapping that starts at or after $Start (only spaces before it), on this one line; $null when the value
    # is not a flow mapping or does not close on the line.
    param([string]$Line, [int]$Start)
    $i = $Start
    while ($i -lt $Line.Length -and $Line[$i] -eq ' ') { $i++ }
    if ($i -ge $Line.Length -or $Line[$i] -ne '{') { return $null }
    $depth = 0
    $quote = ''
    for ($j = $i; $j -lt $Line.Length; $j++) {
        $c = [string]$Line[$j]
        if ($quote) {
            if ($quote -eq '"' -and $c -eq '\') { $j++; continue }
            if ($c -eq $quote) { $quote = '' }
            continue
        }
        if (($c -eq '"' -or $c -eq "'") -and (Test-ScalarStart -Line $Line -Index $j)) { $quote = $c; continue }
        if ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') {
            $depth--
            if ($depth -eq 0) { return [pscustomobject]@{ Open = $i; Close = $j } }
        }
    }
    return $null
}

function Get-FlowMapEntry {
    # The key: value pairs of a flow mapping, split at the commas of its own level. Value is unquoted; ValueStart and
    # ValueLength locate the value text on the line.
    param([string]$Line, $Span)
    $entries = [System.Collections.Generic.List[object]]::new()
    $segStart = $Span.Open + 1
    $depth = 0
    $quote = ''
    for ($j = $Span.Open + 1; $j -le $Span.Close; $j++) {
        $c = [string]$Line[$j]
        if ($j -lt $Span.Close -and $quote) {
            if ($quote -eq '"' -and $c -eq '\') { $j++; continue }
            if ($c -eq $quote) { $quote = '' }
            continue
        }
        if ($j -eq $Span.Close -or ($depth -eq 0 -and $c -eq ',')) {
            $seg = $Line.Substring($segStart, $j - $segStart)
            $m = [regex]::Match($seg, '^\s*(?<key>[A-Za-z0-9_.-]+)\s*:(?:\s+|$)(?<val>.*?)\s*$')
            if ($m.Success) {
                $entries.Add([pscustomobject]@{
                        Key = $m.Groups['key'].Value; Raw = $m.Groups['val'].Value; Value = (ConvertFrom-YamlScalarText $m.Groups['val'].Value)
                        ValueStart = $segStart + $m.Groups['val'].Index; ValueLength = $m.Groups['val'].Length
                    })
            }
            $segStart = $j + 1
            continue
        }
        if (($c -eq '"' -or $c -eq "'") -and (Test-ScalarStart -Line $Line -Index $j)) { $quote = $c; continue }
        if ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') { $depth-- }
    }
    return $entries.ToArray()
}

function Set-FlowMapValue {
    # Sets one key of the flow mapping on a line: the value text is replaced in place, or the key is added before the closing brace.
    param([string]$Line, $Span, [string]$Key, $Value, [string]$ValueText, [bool]$Insert)
    $hit = @(Get-FlowMapEntry -Line $Line -Span $Span) | Where-Object { $_.Key -ceq $Key } | Select-Object -First 1
    if ($hit) {
        if ($hit.Raw -eq $ValueText -or ($Value -isnot [System.Collections.IDictionary] -and $hit.Value -eq [string]$Value)) { return [pscustomobject]@{ Result = 'Unchanged'; Old = $hit.Value; Line = $Line } }
        $new = $Line.Substring(0, $hit.ValueStart) + $ValueText + $Line.Substring($hit.ValueStart + $hit.ValueLength)
        return [pscustomobject]@{ Result = 'Changed'; Old = $hit.Value; Line = $new }
    }
    if (-not $Insert) { return [pscustomobject]@{ Result = 'NotFound'; Old = $null; Line = $Line } }
    $inner = $Line.Substring($Span.Open + 1, $Span.Close - $Span.Open - 1)
    if (-not $inner.Trim()) { $new = $Line.Substring(0, $Span.Open) + "{ ${Key}: $ValueText }" + $Line.Substring($Span.Close + 1) }
    else {
        $at = $Span.Close
        while ($at -gt $Span.Open + 1 -and $Line[$at - 1] -eq ' ') { $at-- }
        # a trailing comma ({ name: X, }) is reused, never doubled
        $lead = if ($Line[$at - 1] -eq ',') { ' ' } else { ', ' }
        $new = $Line.Substring(0, $at) + "${lead}${Key}: $ValueText" + $Line.Substring($at)
    }
    return [pscustomobject]@{ Result = 'Inserted'; Old = $null; Line = $new }
}

function Find-YamlListItem {
    # The list item whose name key is $Wanted, in block style (name on the dash line or on a line of the item) or flow style
    # (- { name: X, ... }). Returns Line, Column (the indent of the item's keys), Span (flow style) and End, or $null.
    param([System.Collections.Generic.List[string]]$Lines, [int]$Start, [int]$End, [string]$Wanted)
    $first = $null
    for ($i = $Start; $i -lt $End; $i++) { if (-not (Test-SkippableLine $Lines[$i])) { $first = $i; break } }
    if ($null -eq $first) { return $null }
    $seqIndent = Get-LineIndent $Lines[$first]
    for ($i = $first; $i -lt $End; $i++) {
        $line = $Lines[$i]
        if ((Test-SkippableLine $line) -or (Get-LineIndent $line) -ne $seqIndent) { continue }
        $dash = [regex]::Match($line, '^\s*-\s+')
        if (-not $dash.Success) { continue }
        $column = $dash.Length
        $itemEnd = Get-ScopeEnd -Lines $Lines -From ($i + 1) -Indent $seqIndent -Limit $End -SequenceAtIndent $false
        $span = Get-FlowMapSpan -Line $line -Start $column
        if ($span) {
            $name = @(Get-FlowMapEntry -Line $line -Span $span) | Where-Object { $_.Key -eq 'name' } | Select-Object -First 1
            if ($name -and $name.Value -eq $Wanted) { return [pscustomobject]@{ Line = $i; Column = $column; Span = $span; End = $itemEnd } }
            continue
        }
        for ($k = $i; $k -lt $itemEnd; $k++) {
            if ($k -gt $i -and ((Test-SkippableLine $Lines[$k]) -or (Get-LineIndent $Lines[$k]) -ne $column)) { continue }
            $text = if ($k -eq $i) { $Lines[$k].Substring($column) } else { $Lines[$k].TrimStart() }
            if ($text -match '^name\s*:\s*(?<v>.*)$' -and (ConvertFrom-YamlScalarText ($Matches['v'] -replace '\s+#.*$', '')) -eq $Wanted) {
                return [pscustomobject]@{ Line = $i; Column = $column; Span = $null; End = $itemEnd }
            }
        }
    }
    return $null
}

function Edit-AzlYamlValue {
    <#
    .SYNOPSIS
        Sets one value in a YAML document held as a list of lines. Returns Result (Changed, Unchanged, Inserted, NotFound or
        NotScalar), the old value and the line number.
    .PARAMETER Path
        Keys and list-item selectors: @('nodes', '[name=node-1]', 'network_adapters', '[name=Slot 3 Port 1]', 'mac_address').
        A selector '[name=X]' picks the list item whose name key is X, in block or flow style.
    .PARAMETER Value
        A string, number or boolean; a dictionary is written as a flow mapping ({ bus: 1, device: 0, function: 0 }).
    .PARAMETER InsertIfMissing
        Adds the last key under its existing parent when it is not there. A missing parent is never created, except with
        -CreateParents.
    .PARAMETER CreateParents
        With -InsertIfMissing: also creates missing parent keys (mappings only, never a list item), for example
        hardware.drives.capacity before hardware.drives.capacity.model.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$InsertIfMissing,
        [switch]$CreateParents
    )
    $result = { param($r, $old = $null, $line = -1) [pscustomobject]@{ Result = $r; Old = $old; Line = $line } }
    $valueText = ConvertTo-YamlScalar $Value
    $isPlainKey = { param([string[]]$Keys) @($Keys | Where-Object { $_ -match '^\[' }).Count -eq 0 }
    $nested = {
        # The lines of a key path that does not exist yet: one mapping per key, the value on the last.
        param([string[]]$Keys, [int]$Indent)
        $out = for ($k = 0; $k -lt $Keys.Count; $k++) {
            $pad = ' ' * ($Indent + 2 * $k)
            if ($k -lt $Keys.Count - 1) { "$pad$($Keys[$k]):" } else { "$pad$($Keys[$k]): $valueText" }
        }
        return , @($out)
    }
    $flowEdit = {
        # The rest of the path is one key inside the flow mapping on line $at.
        param([int]$at, $span, [string[]]$rest)
        if ($rest.Count -ne 1 -or $rest[0] -match '^\[') { return (& $result 'NotFound' $null $at) }
        $r = Set-FlowMapValue -Line $Lines[$at] -Span $span -Key $rest[0] -Value $Value -ValueText $valueText -Insert $InsertIfMissing.IsPresent
        if ($r.Result -in 'Changed', 'Inserted') { $Lines[$at] = $r.Line }
        return (& $result $r.Result $r.Old $at)
    }
    $start = 0; $end = $Lines.Count; $keyIndent = 0; $firstIsItem = $false
    for ($s = 0; $s -lt $Path.Count; $s++) {
        $segment = $Path[$s]; $isLast = ($s -eq $Path.Count - 1)
        $rest = [string[]]@()
        if (-not $isLast) { $rest = [string[]]$Path[($s + 1)..($Path.Count - 1)] }
        if ($segment -match '^\[name=(?<n>.+)\]$') {
            $item = Find-YamlListItem -Lines $Lines -Start $start -End $end -Wanted $Matches['n']
            if (-not $item) { return (& $result 'NotFound') }
            if ($item.Span) { return (& $flowEdit $item.Line $item.Span $rest) }
            $end = $item.End
            $start = $item.Line; $keyIndent = $item.Column; $firstIsItem = $true
            continue
        }
        $foundKey = -1
        for ($i = $start; $i -lt $end; $i++) {
            $line = $Lines[$i]
            if (Test-SkippableLine $line) { continue }
            if ($i -eq $start -and $firstIsItem) { $text = $line.Substring($keyIndent); $ind = $keyIndent } else { $text = $line.TrimStart(); $ind = Get-LineIndent $line }
            if ($ind -eq $keyIndent -and $text -match "^$([regex]::Escape($segment))\s*:") { $foundKey = $i; break }
        }
        if ($foundKey -lt 0) {
            $keys = [string[]](@($segment) + $rest)
            if ($InsertIfMissing -and ($isLast -or ($CreateParents -and (& $isPlainKey $rest)))) {
                $at = $end
                while ($at -gt $start + 1 -and (Test-SkippableLine $Lines[$at - 1])) { $at--}
                $new = & $nested $keys $keyIndent
                $Lines.InsertRange($at, [string[]]$new)
                return (& $result 'Inserted' $null $at)
            }
            return (& $result 'NotFound')
        }
        $keyText = $Lines[$foundKey]
        $keyMatch = [regex]::Match($keyText.Substring($keyIndent), "^$([regex]::Escape($segment))\s*:")
        $valueStart = $keyIndent + $keyMatch.Length
        if ($isLast) {
            $pattern = "^(?<pre>.*?\b$([regex]::Escape($segment))\s*:\s*)(?<val>`"(?:[^`"\\]|\\.)*`"|'[^']*'|[^#]*?)(?<post>\s+#.*)?\s*$"
            if ($keyText -notmatch $pattern) { return (& $result 'NotScalar' $null $foundKey) }
            $old = ConvertFrom-YamlScalarText $Matches['val']
            $pre = $Matches['pre']; $post = $Matches['post']
            if ($old -eq '') {
                $next = Get-ScopeEnd -Lines $Lines -From ($foundKey + 1) -Indent $keyIndent -Limit $end -SequenceAtIndent $true
                if ($next -gt $foundKey + 1 -and ($Lines[($foundKey + 1)..($next - 1)] | Where-Object { -not (Test-SkippableLine $_) })) { return (& $result 'NotScalar' $null $foundKey) }
            }
            if ($old -eq [string]$Value -or $Matches['val'].Trim() -eq $valueText) { return (& $result 'Unchanged' $old $foundKey) }
            $Lines[$foundKey] = $pre + $valueText + $post
            return (& $result 'Changed' $old $foundKey)
        }
        $span = Get-FlowMapSpan -Line $keyText -Start $valueStart
        if ($span) { return (& $flowEdit $foundKey $span $rest) }
        $bodyEnd = Get-ScopeEnd -Lines $Lines -From ($foundKey + 1) -Indent $keyIndent -Limit $end -SequenceAtIndent $true
        $first = $null
        for ($i = $foundKey + 1; $i -lt $bodyEnd; $i++) { if (-not (Test-SkippableLine $Lines[$i])) { $first = $i; break } }
        if ($null -eq $first) {
            # The key is there with no value: its children go right under it.
            $emptyValue = ($keyText.Substring($valueStart) -replace '\s+#.*$', '').Trim() -eq ''
            if ($emptyValue -and $InsertIfMissing -and ($rest.Count -eq 1 -or $CreateParents) -and (& $isPlainKey $rest)) {
                $new = & $nested $rest ($keyIndent + 2)
                $Lines.InsertRange($foundKey + 1, [string[]]$new)
                return (& $result 'Inserted' $null ($foundKey + 1))
            }
            return (& $result 'NotFound')
        }
        $start = $foundKey + 1; $end = $bodyEnd; $firstIsItem = $false
        $keyIndent = Get-LineIndent $Lines[$first]
    }
    return (& $result 'NotFound')
}

function Invoke-AzlYamlChangeOnLines {
    param([System.Collections.Generic.List[string]]$Lines, [object[]]$Change)
    foreach ($c in $Change) {
        $create = [bool]($c.PSObject.Properties['CreateParents'] -and $c.CreateParents)
        $r = Edit-AzlYamlValue -Lines $Lines -Path $c.Path -Value $c.New -InsertIfMissing -CreateParents:$create
        [pscustomobject]@{ Display = $c.Display; Result = $r.Result; Old = $r.Old; New = $c.New }
    }
}

function Test-AzlYamlEdit {
    <#
    .SYNOPSIS
        Where each change would land (Changed, Unchanged, Inserted, NotFound or NotScalar), worked out on a copy of the file in
        memory. The file is not written. A preview uses it to flag every value it cannot place before anything is applied.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Change)
    $raw = Get-Content -LiteralPath $Path -Raw
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($raw -split '\r?\n'))
    return @(Invoke-AzlYamlChangeOnLines -Lines $lines -Change $Change)
}

function Invoke-AzlYamlEdit {
    <#
    .SYNOPSIS
        Applies changes from Get-AzlDiscoveryChange and Get-AzlHardwareFactChange to a file. Writes a backup first; changes
        nothing without confirmation.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Change)
    $raw = Get-Content -LiteralPath $Path -Raw
    $newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($raw -split '\r?\n'))
    $applied = @()
    $backup = $null
    if ($Change.Count -gt 0 -and $PSCmdlet.ShouldProcess($Path, "Write $($Change.Count) discovered value(s)")) {
        $applied = @(Invoke-AzlYamlChangeOnLines -Lines $lines -Change $Change)
        $backup = "$Path.bak.$([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
        Copy-Item -LiteralPath $Path -Destination $backup
        [System.IO.File]::WriteAllText($Path, ($lines -join $newline), [System.Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]@{ Backup = $backup; Results = @($applied) }
}

#endregion

#region What discovery changes

function Get-ViewValue($Object, [string]$Name) {
    # A property of a view or report entry; $null when it is missing, empty or 'not reported'.
    $v = Get-RfProp $Object $Name
    if ($null -eq $v) { return $null }
    if ($v -is [string] -and (-not $v.Trim() -or $v -eq $script:NotReported)) { return $null }
    return $v
}

function ConvertTo-SlotKey([string]$Slot) { return (($Slot -replace '\s+', ' ').Trim()).ToLowerInvariant() }

function Get-AzlPortFact {
    # The hardware facts of one discovered port that nodes[].network_adapters[] keeps (owner decision O7).
    param($Port)
    $facts = [ordered]@{}
    $index = Get-ViewValue $Port 'PortIndex'
    if ($null -ne $index -and "$index" -match '^\d+$' -and [int]"$index" -ge 1) { $facts['port_index'] = [int]"$index" }
    $vendor = Get-ViewValue $Port 'AdapterManufacturer'
    if ($vendor) { $facts['vendor'] = ([string]$vendor).Trim() }
    $model = Get-ViewValue $Port 'AdapterModel'
    if ($model -and -not (Test-AzlDellGenericLabel -Text ([string]$model))) { $facts['model'] = ([string]$model).Trim() }
    $link = Get-ViewValue $Port 'LinkSpeedMbps'
    $max = Get-ViewValue $Port 'MaxSpeedMbps'
    $linkUp = [bool](Get-RfProp $Port 'LinkUp' $false)
    $mbps = if ($linkUp -and $link) { $link } elseif ($max) { $max } else { $link }
    if ($null -ne $mbps -and "$mbps" -match '^\d+(\.\d+)?$' -and [double]"$mbps" -gt 0) { $facts['speed_gbps'] = [double]("$mbps") / 1000 }
    $pci = Get-ViewValue $Port 'PciLocation'
    if ($pci) {
        $bus = Get-RfProp $pci 'bus'; $device = Get-RfProp $pci 'device'; $function = Get-RfProp $pci 'function'
        if ($null -ne $bus -and $null -ne $device -and $null -ne $function) { $facts['pci_location'] = [ordered]@{ bus = [int]$bus; device = [int]$device; function = [int]$function } }
    }
    $rdma = [string](Get-ViewValue $Port 'Rdma')
    if ($rdma -in 'none', 'iwarp', 'roce', 'roce_v2') { $facts['rdma'] = $rdma }
    return $facts
}

function Test-SameFact($Planned, $Found) {
    if ($Found -is [System.Collections.IDictionary]) {
        if ($Planned -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($k in $Found.Keys) { if ([string]$Planned[$k] -ne [string]$Found[$k]) { return $false } }
        return $true
    }
    if ($Found -is [double]) { return ($null -ne $Planned -and "$Planned" -match '^-?\d+(\.\d+)?$' -and [math]::Abs([double]"$Planned" - $Found) -lt 0.0005) }
    return ([string]$Planned -eq [string]$Found)
}

function Get-AzlDiscoveryChange {
    <#
    .SYNOPSIS
        What discovery would change in infrastructure.yml for each machine, what it cannot resolve, and what it only notes.
    .DESCRIPTION
        For each node: serial_number from the service tag (or the inventory's serial number), bmc.mac_address and (when
        missing) bmc.type. For a node with network_adapters, each file entry is paired with a discovered port: by MAC, then by
        the same name, then by slot and port_index, then by slot when that slot has one unpaired entry and one free port. A
        paired entry gets the port's MAC and its hardware facts (port_index, vendor, model, pci_location; speed_gbps, rdma and
        slot only when missing). A node described with management only gets management.mac_address when the management port is
        confirmed (-ManagementPort, or the MAC already in the file); a management MAC that no port of the machine has is
        replaced only with -ManagementPort.
        Problems are what the write-back cannot settle: an entry whose MAC is empty or on no port of the machine and that no
        port pairs with, and a wrong management MAC without -ManagementPort. The caller exits 1 for them.
        Notes are information only: ports the file does not list (the proposal file lists them), a guessed management port, a
        fact that differs where the file is the authority.
    .PARAMETER Infrastructure
        The parsed file (ordered dictionary).
    .PARAMETER Item
        Objects with NodeName, Discovery (the view of ConvertTo-AzlDiscoveryLegacyView or ConvertTo-AzlInventoryDiscoveryView)
        and optional ManagementPort.
    .OUTPUTS
        Changes (NodeName, Path, Display, Old, New), Problems and Notes (strings).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item)
    $changes = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $add = {
        param($node, [string[]]$path, $old, $new)
        $changes.Add([pscustomobject]@{ NodeName = $node; Path = ([string[]](@('nodes', "[name=$node]") + $path)); Display = "nodes[$node].$($path -join '.')"; Old = $old; New = $new; CreateParents = $false })
    }
    foreach ($i in $Item) {
        $name = [string]$i.NodeName
        $node = @($Infrastructure['nodes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -eq $name } | Select-Object -First 1
        if (-not $node) { $notes.Add("Node '$name' is not in the file: skipped."); continue }
        $d = $i.Discovery
        $tag = [string](Get-ViewValue (Get-RfProp $d 'Identity') 'ServiceTag')
        if ($tag -and [string]$node['serial_number'] -ne $tag) { & $add $name @('serial_number') $node['serial_number'] $tag }

        # The BMC: its MAC (the DHCP reservation of its address) and, when the file has none, its kind.
        $bmcView = Get-RfProp $d 'Bmc'
        $bmcMac = ConvertTo-AzlMacAddress ([string](Get-ViewValue $bmcView 'MacAddress'))
        $bmcEntry = $node['bmc']
        if ($bmcMac) {
            if ($bmcEntry -is [System.Collections.IDictionary]) {
                if ((ConvertTo-AzlMacAddress ([string]$bmcEntry['mac_address'])) -ne $bmcMac) { & $add $name @('bmc', 'mac_address') $bmcEntry['mac_address'] $bmcMac }
            }
            else { $notes.Add("${name}: the BMC MAC is $bmcMac; the file has no bmc block to hold it.") }
        }
        $bmcType = [string](Get-ViewValue $bmcView 'Type')
        if ($bmcType -and $bmcEntry -is [System.Collections.IDictionary] -and -not $bmcEntry['type']) { & $add $name @('bmc', 'type') $null $bmcType }

        $ports = @(Get-RfProp $d 'NetworkPorts' @() | Where-Object { $_ -and (ConvertTo-AzlMacAddress ([string](Get-RfProp $_ 'MacAddress'))) })
        if ($node.Contains('network_adapters')) {
            $adapters = @(@($node['network_adapters']) | Where-Object { $_ -is [System.Collections.IDictionary] })
            $pairOf = @{}     # adapter index -> port
            $how = @{}        # adapter index -> how it was paired
            $taken = [System.Collections.Generic.HashSet[string]]::new()
            $macOf = { param($p) ConvertTo-AzlMacAddress ([string](Get-RfProp $p 'MacAddress')) }
            $pair = { param([int]$ai, $p, [string]$reason) $pairOf[$ai] = $p; $how[$ai] = $reason; [void]$taken.Add((& $macOf $p)) }
            $free = { $ports | Where-Object { -not $taken.Contains((& $macOf $_)) } }
            for ($ai = 0; $ai -lt $adapters.Count; $ai++) {
                $mac = ConvertTo-AzlMacAddress ([string]$adapters[$ai]['mac_address'])
                $hit = if ($mac) { & $free | Where-Object { (& $macOf $_) -eq $mac } | Select-Object -First 1 }
                if ($hit) { & $pair $ai $hit 'MAC' }
            }
            for ($ai = 0; $ai -lt $adapters.Count; $ai++) {
                if ($pairOf.ContainsKey($ai)) { continue }
                $entryName = [string]$adapters[$ai]['name']
                if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
                $hit = & $free | Where-Object { [string](Get-RfProp $_ 'Name') -eq $entryName } | Select-Object -First 1
                if ($hit) { & $pair $ai $hit 'name' }
            }
            for ($ai = 0; $ai -lt $adapters.Count; $ai++) {
                if ($pairOf.ContainsKey($ai)) { continue }
                $a = $adapters[$ai]
                if (-not $a['slot'] -or $null -eq $a['port_index']) { continue }
                $hit = & $free | Where-Object { (ConvertTo-SlotKey ([string](Get-RfProp $_ 'Slot'))) -eq (ConvertTo-SlotKey ([string]$a['slot'])) -and [string](Get-RfProp $_ 'PortIndex') -eq [string]$a['port_index'] } | Select-Object -First 1
                if ($hit) { & $pair $ai $hit 'slot and port_index' }
            }
            $openSlots = @(@(for ($ai = 0; $ai -lt $adapters.Count; $ai++) { if (-not $pairOf.ContainsKey($ai) -and $adapters[$ai]['slot']) { ConvertTo-SlotKey ([string]$adapters[$ai]['slot']) } }) | Select-Object -Unique)
            foreach ($slot in $openSlots) {
                $waiting = @(for ($ai = 0; $ai -lt $adapters.Count; $ai++) { if (-not $pairOf.ContainsKey($ai) -and $adapters[$ai]['slot'] -and (ConvertTo-SlotKey ([string]$adapters[$ai]['slot'])) -eq $slot) { $ai } })
                $candidates = @(& $free | Where-Object { (ConvertTo-SlotKey ([string](Get-RfProp $_ 'Slot'))) -eq $slot })
                if ($waiting.Count -eq 1 -and $candidates.Count -eq 1) { & $pair $waiting[0] $candidates[0] 'slot (the only free port of that slot)' }
            }
            for ($ai = 0; $ai -lt $adapters.Count; $ai++) {
                $a = $adapters[$ai]
                $label = [string]$a['name']
                if (-not $pairOf.ContainsKey($ai)) {
                    $mac = ConvertTo-AzlMacAddress ([string]$a['mac_address'])
                    $problems.Add("${name}: network_adapters '$label' has $(if ($mac) { "MAC $mac, which no port of the machine has" } else { 'no MAC' }), and no discovered port matches it by name, by slot and port_index, or as the only free port of its slot. Set its slot and port_index (or the port name discovery reports), then run again.")
                    continue
                }
                $p = $pairOf[$ai]
                $sel = @('network_adapters', "[name=$label]")
                $portMac = & $macOf $p
                if ((ConvertTo-AzlMacAddress ([string]$a['mac_address'])) -ne $portMac) { & $add $name ($sel + 'mac_address') $a['mac_address'] $portMac }
                if ($how[$ai] -ne 'MAC' -and $how[$ai] -ne 'name') { $notes.Add("${name}: network_adapters '$label' is paired with port '$(Get-RfProp $p 'Name')' by $($how[$ai]).") }
                $slot = [string](Get-ViewValue $p 'Slot')
                if ($slot) {
                    if (-not $a['slot']) { & $add $name ($sel + 'slot') $null $slot }
                    elseif ((ConvertTo-SlotKey ([string]$a['slot'])) -ne (ConvertTo-SlotKey $slot)) { $notes.Add("${name}: network_adapters '$label' says slot '$($a['slot'])'; discovery reports '$slot'. The file is kept.") }
                }
                $facts = Get-AzlPortFact -Port $p
                foreach ($k in $facts.Keys) {
                    $planned = $a[$k]
                    if ($null -ne $planned -and (Test-SameFact $planned $facts[$k])) { continue }
                    if ($null -ne $planned -and $k -in 'speed_gbps', 'rdma') {
                        # The design value wins: a link can run below the card's speed, and the RDMA mode is a choice.
                        $notes.Add("${name}: network_adapters '$label' $k is $planned; discovery reports $($facts[$k]). The file is kept.")
                        continue
                    }
                    & $add $name ($sel + $k) $planned $facts[$k]
                }
            }
            foreach ($p in @(& $free)) { $notes.Add("${name}: port '$(Get-RfProp $p 'Name')' ($(& $macOf $p)) is not in network_adapters: see the proposal file.") }
        }
        else {
            $existing = [string](Get-AzlYamlManagementMac $node)
            $given = [string]$(if ($i.PSObject.Properties['ManagementPort']) { $i.ManagementPort })
            $choice = Select-AzlManagementPort -Ports $ports -Name $given -ExistingMac $existing
            $onMachine = $existing -and ($ports | Where-Object { (ConvertTo-AzlMacAddress ([string]$_.MacAddress)) -eq (ConvertTo-AzlMacAddress $existing) })
            if ($existing -and -not $onMachine) {
                if ($given -and $choice.Port) { & $add $name @('management', 'mac_address') $existing $choice.Port.MacAddress }
                else { $problems.Add("${name}: management.mac_address $existing is not a MAC of this machine. Give -ManagementPort (a port name or MAC) to replace it$(if ($choice.Port) { "; the suggestion is '$($choice.Port.Name)' ($($choice.Port.MacAddress)), $($choice.Reason)" }).") }
            }
            elseif (-not $existing -and $choice.Port -and $choice.Confirmed) { & $add $name @('management', 'mac_address') $null $choice.Port.MacAddress }
            elseif (-not $existing -and $choice.Port) { $notes.Add("${name}: suggested management port '$($choice.Port.Name)' ($($choice.Port.MacAddress)), $($choice.Reason). Give -ManagementPort to write it.") }
        }
    }
    return [pscustomobject]@{ Changes = @($changes); Problems = @($problems); Notes = @($notes) }
}

function Get-AzlYamlManagementMac($Node) {
    $m = $Node['management']
    if ($m -is [System.Collections.IDictionary] -and $m.Contains('mac_address')) { return $m['mac_address'] }
    return $null
}

function Get-AzlHardwareFactChange {
    <#
    .SYNOPSIS
        What the inventory would change in hardware.*: vendor (when missing), model, cpu_cores, memory_gib, drives (media,
        count, size_tb, model of the capacity and the cache drives), boot_drives and gpu.
    .DESCRIPTION
        hardware.* describes every machine, so a key is written only when every node read reports the same value; otherwise
        it is a note. A planned value within 5 percent (drive size) or the same vendor family (Dell against Dell Inc.) is kept.
        hardware.vendor is never changed once set: azurelocal-ztp picks config/oem/<vendor>.json by it.
    .PARAMETER Infrastructure
        The parsed file.
    .PARAMETER View
        The views of ConvertTo-AzlInventoryDiscoveryView (their Hardware block). A view without one is ignored.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$View)
    $changes = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $hardware = @($View | Where-Object { $_ -and (Get-RfProp $_ 'Hardware') } | ForEach-Object { $_.Hardware })
    if ($hardware.Count -eq 0) { return [pscustomobject]@{ Changes = @(); Notes = @() } }
    $planned = { param([string]$p) Get-AzlInfrastructureValueOrNull $Infrastructure $p }
    $agreed = {
        # The one value every node reports, or $null (with a note when they differ).
        param([string]$Key, [scriptblock]$Read)
        $values = @($hardware | ForEach-Object { & $Read $_ })
        if (@($values | Where-Object { $null -eq $_ }).Count -gt 0) { return $null }
        $distinct = @($values | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { ($_ | ConvertTo-Json -Compress) } else { [string]$_ } } | Select-Object -Unique)
        if ($distinct.Count -gt 1) { $notes.Add("hardware.${Key}: the machines report different values ($($distinct -join ', ')): not written. Check the hardware symmetry in the inventory."); return $null }
        return $values[0]
    }
    $set = {
        param([string]$Key, $Found, [scriptblock]$Same)
        if ($null -eq $Found) { return }
        $p = & $planned "hardware.$Key"
        if ($null -ne $p -and (& $Same $p $Found)) { return }
        $changes.Add([pscustomobject]@{ NodeName = ''; Path = [string[]](@('hardware') + ($Key -split '\.')); Display = "hardware.$Key"; Old = $p; New = $Found; CreateParents = $true })
    }
    $equalText = { param($a, $b) ([string]$a).Trim() -ieq ([string]$b).Trim() }
    $equalNumber = { param($a, $b) "$a" -match '^-?\d+(\.\d+)?$' -and [math]::Abs([double]"$a" - [double]$b) -lt 0.0005 }
    $within5 = { param($a, $b) "$a" -match '^\d+(\.\d+)?$' -and [double]$b -gt 0 -and [math]::Abs([double]"$a" - [double]$b) / [double]$b -le 0.05 }

    $vendor = & $agreed 'vendor' { param($h) $h.Vendor }
    $plannedVendor = & $planned 'hardware.vendor'
    if ($vendor -and $null -eq $plannedVendor) { & $set 'vendor' $vendor $equalText }
    elseif ($vendor -and -not (([string]$plannedVendor).Trim().ToLowerInvariant().StartsWith(([string]$vendor).Trim().ToLowerInvariant()) -or ([string]$vendor).Trim().ToLowerInvariant().StartsWith(([string]$plannedVendor).Trim().ToLowerInvariant()))) {
        $notes.Add("hardware.vendor is '$plannedVendor'; the BMCs report '$vendor'. Not changed: azurelocal-ztp picks config/oem/<vendor>.json by this key.")
    }
    & $set 'model' (& $agreed 'model' { param($h) $h.Model }) $equalText
    & $set 'cpu_cores' (& $agreed 'cpu_cores' { param($h) $h.CpuCores }) $equalNumber
    & $set 'memory_gib' (& $agreed 'memory_gib' { param($h) $h.MemoryGiB }) $equalNumber
    foreach ($group in 'capacity', 'cache') {
        $count = & $agreed "drives.$group.count" { param($h) $h.Drives[$group].Count }
        if ($null -eq $count) { continue }
        if ($count -eq 0) {
            if ($null -ne (& $planned "hardware.drives.$group")) { $notes.Add("hardware.drives.${group}: the file lists $group drives; the BMCs report none in that role. Not changed.") }
            continue
        }
        & $set "drives.$group.media" (& $agreed "drives.$group.media" { param($h) $h.Drives[$group].Media }) $equalText
        & $set "drives.$group.count" $count $equalNumber
        & $set "drives.$group.size_tb" (& $agreed "drives.$group.size_tb" { param($h) $h.Drives[$group].SizeTb }) $within5
        & $set "drives.$group.model" (& $agreed "drives.$group.model" { param($h) $h.Drives[$group].Model }) $equalText
    }
    $bootType = & $agreed 'boot_drives.type' { param($h) $h.BootDrives.Type }
    if ($bootType) {
        & $set 'boot_drives.type' $bootType $equalText
        & $set 'boot_drives.count' (& $agreed 'boot_drives.count' { param($h) $h.BootDrives.Count }) $equalNumber
        & $set 'boot_drives.size_gb' (& $agreed 'boot_drives.size_gb' { param($h) $h.BootDrives.SizeGb }) $within5
        & $set 'boot_drives.model' (& $agreed 'boot_drives.model' { param($h) $h.BootDrives.Model }) $equalText
    }
    $gpuCount = & $agreed 'gpu.count_per_node' { param($h) $h.Gpu.Count }
    if ($null -ne $gpuCount) {
        if ($gpuCount -gt 0) {
            & $set 'gpu.enabled' $true { param($a, $b) [string]$a -eq [string]$b }
            & $set 'gpu.count_per_node' $gpuCount $equalNumber
            & $set 'gpu.model' (& $agreed 'gpu.model' { param($h) $h.Gpu.Model }) $equalText
        }
        elseif ((& $planned 'hardware.gpu.enabled') -eq $true) { & $set 'gpu.enabled' $false { param($a, $b) [string]$a -eq [string]$b } }
    }
    return [pscustomobject]@{ Changes = @($changes); Notes = @($notes) }
}

function Get-AzlInfrastructureValueOrNull([System.Collections.IDictionary]$Infrastructure, [string]$Path) {
    $cur = $Infrastructure
    foreach ($part in $Path -split '\.') {
        if ($cur -isnot [System.Collections.IDictionary] -or -not $cur.Contains($part)) { return $null }
        $cur = $cur[$part]
    }
    return $cur
}

function ConvertTo-AzlInventoryDiscoveryView {
    <#
    .SYNOPSIS
        One node of a Get-HardwareInventory.ps1 inventory (kind hardware-inventory) as the view Get-AzlDiscoveryChange reads,
        plus the Hardware block Get-AzlHardwareFactChange reads. $null for a node that was not read.
    .DESCRIPTION
        The inventory is vendor-neutral (standard Redfish only). The port name and slot come from the inventory when it has
        them; otherwise from the adapter ID and the port number (Dell FQDDs: NIC.Slot.3 port 1 is 'Slot 3 Port 1' in slot
        'Slot 3'), else from the adapter's reported location. The serial number is the system serial number.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$InventoryNode)
    if ([string](Get-RfProp $InventoryNode 'status') -ne 'read') { return $null }
    $identity = Get-RfProp $InventoryNode 'identity'
    $ports = @(foreach ($p in @(Get-RfProp (Get-RfProp $InventoryNode 'network') 'ports' @())) {
            $mac = ConvertTo-AzlMacAddress ([string](Get-ViewValue $p 'mac'))
            if (-not $mac) { continue }
            $adapterId = [string](Get-ViewValue $p 'adapter')
            $number = Get-ViewValue $p 'portNumber'
            $portName = [string](Get-ViewValue $p 'name')
            $slot = [string](Get-ViewValue $p 'slot')
            if (-not $portName -or -not $slot) {
                $label = Get-AzlDellPortLabel -AdapterId $adapterId -PortId ([string](Get-ViewValue $p 'portId')) -PhysicalPortNumber $number -Ordinal ([int](Get-RfProp $p 'order' 1))
                $location = [string](Get-ViewValue $p 'adapterLocation')
                if (-not $portName) { $portName = $label.Name }
                if (-not $slot) { $slot = if ($label.Slot -ne $adapterId -or -not $location) { $label.Slot } else { $location } }
            }
            $linkStatus = [string](Get-ViewValue $p 'linkStatus')
            $model = [string](Get-ViewValue $p 'model')
            [ordered]@{
                Name = $portName; Slot = $slot; MacAddress = $mac; PortIndex = $number; AdapterId = $adapterId
                AdapterManufacturer = (Get-ViewValue $p 'manufacturer'); AdapterModel = $(if ($model -and -not (Test-AzlDellGenericLabel -Text $model)) { $model } else { $null })
                LinkStatus = $linkStatus; LinkUp = ($linkStatus -in 'Up', 'LinkUp'); LinkSpeedMbps = (Get-ViewValue $p 'speedMbps'); MaxSpeedMbps = (Get-ViewValue $p 'maxSpeedMbps')
                PciLocation = (Get-ViewValue $p 'pciLocation'); Rdma = [string](Get-ViewValue $p 'rdma')
            }
        })
    $drives = @(Get-RfProp $InventoryNode 'drives' @())
    $group = {
        param([string]$Role)
        $set = @($drives | Where-Object { [string](Get-RfProp $_ 'role') -eq $Role })
        $media = @($set | ForEach-Object { ([string](Get-ViewValue $_ 'mediaType')).ToLowerInvariant() } | Select-Object -Unique)
        $sizes = @($set | ForEach-Object { Get-ViewValue $_ 'sizeTB' } | Select-Object -Unique)
        $models = @($set | ForEach-Object { [string](Get-ViewValue $_ 'model') } | Select-Object -Unique)
        [pscustomobject]@{
            Count = $set.Count
            Media = $(if ($media.Count -eq 1 -and $media[0] -in 'nvme', 'ssd', 'hdd') { $media[0] } else { $null })
            SizeTb = $(if ($sizes.Count -eq 1 -and $null -ne $sizes[0]) { [math]::Round([double]$sizes[0], 2) } else { $null })
            Model = $(if ($models.Count -eq 1 -and $models[0]) { $models[0] } else { $null })
        }
    }
    # Boot drives: the drives the inventory excluded because they are members of a RAID volume, all on one controller.
    $raid = @($drives | Where-Object { [string](Get-RfProp $_ 'role') -eq 'excluded' -and ([string](Get-RfProp $_ 'roleReason')) -match 'RAID' })
    $boot = [pscustomobject]@{ Type = $null; Count = 0; SizeGb = $null; Model = $null }
    $controllers = @($raid | ForEach-Object { [string](Get-RfProp $_ 'controller') } | Select-Object -Unique)
    if ($raid.Count -gt 0 -and $controllers.Count -eq 1) {
        $sizes = @($raid | ForEach-Object { Get-ViewValue $_ 'sizeBytes' } | Select-Object -Unique)
        $models = @($raid | ForEach-Object { [string](Get-ViewValue $_ 'model') } | Select-Object -Unique)
        $boot = [pscustomobject]@{
            Type = $(if ($controllers[0] -match '(?i)boss') { 'boss' } else { 'raid' }); Count = $raid.Count
            SizeGb = $(if ($sizes.Count -eq 1 -and $null -ne $sizes[0]) { [math]::Round([double]$sizes[0] / 1e9) } else { $null })
            Model = $(if ($models.Count -eq 1 -and $models[0]) { $models[0] } else { $null })
        }
    }
    $gpuDevices = @(Get-RfProp (Get-RfProp $InventoryNode 'gpu') 'devices' @())
    $gpuModels = @($gpuDevices | ForEach-Object { [string](Get-ViewValue $_ 'model') } | Select-Object -Unique)
    $vendor = [string](Get-ViewValue (Get-RfProp $InventoryNode 'vendor') 'detected')
    $bmcType = switch -Regex ($vendor) { '^(?i)dell' { 'idrac' } '^(?i)(hpe|hp)$' { 'ilo' } '^(?i)lenovo' { 'xcc' } default { $null } }
    $cores = Get-ViewValue (Get-RfProp $InventoryNode 'cpu') 'cores'
    $memory = Get-ViewValue (Get-RfProp $InventoryNode 'memory') 'totalGiB'
    return [ordered]@{
        SchemaVersion = 'hardware-inventory (view)'; CollectedAt = [string](Get-RfProp $InventoryNode 'collectedAt' ''); BmcAddress = [string](Get-RfProp $InventoryNode 'bmcAddress' '')
        NodeName = [string](Get-RfProp $InventoryNode 'name' '')
        Identity = [ordered]@{
            ServiceTag = [string](Get-ViewValue $identity 'serialNumber'); SerialNumber = [string](Get-ViewValue $identity 'serialNumber')
            Model = [string](Get-ViewValue $identity 'model'); Manufacturer = [string](Get-ViewValue $identity 'manufacturer')
        }
        Bmc = [ordered]@{ MacAddress = (Get-ViewValue (Get-RfProp $InventoryNode 'bmc') 'mac'); Type = $bmcType }
        NetworkPorts = $ports
        Boss = [ordered]@{ Present = ($boot.Type -eq 'boss'); ControllerId = $(if ($boot.Type -eq 'boss') { $controllers[0] } else { $null }); DriveCount = $boot.Count; HasVirtualDisk = ($boot.Count -gt 0); NeedsVirtualDisk = $false }
        Hardware = [ordered]@{
            Vendor = $(if ($vendor) { $vendor } else { $null })
            Model = $(if ([string](Get-ViewValue $identity 'model')) { [string](Get-ViewValue $identity 'model') } else { $null })
            CpuCores = $(if ($null -ne $cores -and "$cores" -match '^\d+$') { [int]"$cores" } else { $null })
            MemoryGiB = $(if ($null -ne $memory -and "$memory" -match '^\d+(\.\d+)?$') { [int][math]::Round([double]"$memory") } else { $null })
            Drives = [ordered]@{ capacity = (& $group 'capacity'); cache = (& $group 'cache') }
            BootDrives = $boot
            Gpu = [pscustomobject]@{ Count = $gpuDevices.Count; Model = $(if ($gpuModels.Count -eq 1 -and $gpuModels[0]) { $gpuModels[0] } else { $null }) }
        }
        Warnings = @(Get-RfProp $InventoryNode 'warnings' @())
    }
}

#endregion

function Read-AzlDiscoveryFile {
    <#
    .SYNOPSIS
        Reads one discovery or hardware inventory file (.json, .yml or .yaml) as an object. JSON gives objects, YAML gives
        ordered dictionaries; Get-RfProp reads both.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    if ([System.IO.Path]::GetExtension($Path) -eq '.json') { return ($text | ConvertFrom-Json -Depth 60) }
    return (ConvertFrom-Yaml $text -Ordered)
}

Export-ModuleMember -Function Read-AzlDiscoveryFile, Edit-AzlYamlValue, Get-AzlDiscoveryChange, Get-AzlHardwareFactChange, ConvertTo-AzlInventoryDiscoveryView, Test-AzlYamlEdit, Invoke-AzlYamlEdit
