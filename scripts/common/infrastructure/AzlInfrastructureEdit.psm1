#Requires -Version 7.0
<#
.SYNOPSIS
    Writes discovered hardware values into infrastructure.yml without reformatting the file.

.DESCRIPTION
    The file is edited line by line: only the value of one scalar changes (or one line is inserted under an existing parent),
    so comments, order and quoting stay as the operator wrote them. A key path that is not found is reported and skipped,
    never guessed.

    Get-AzlDiscoveryChange   What discovery would change in the file: serial_number, and the MAC of each port.
    Edit-AzlYamlValue         One edit on a list of lines. Path: 'nodes', '[name=node-1]', 'serial_number'.
    Invoke-AzlYamlEdit       Applies the changes to a file, with a backup, after a confirmation.

    Roles, IP assignment and addresses are never written: discovery cannot read them from hardware.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'redfish', 'AzlRedfishCore.psm1'))
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'idrac-management', 'AzlDellRedfish.psm1'))

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
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    return '"' + (([string]$Value) -replace '\\', '\\' -replace '"', '\"') + '"'
}

function ConvertFrom-YamlScalarText([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'")))) { return $t.Substring(1, $t.Length - 2) }
    return $t
}

function Edit-AzlYamlValue {
    <#
    .SYNOPSIS
        Sets one scalar in a YAML document held as a list of lines. Returns Result (Changed, Unchanged, Inserted, NotFound or
        NotScalar), the old value and the line number.
    .PARAMETER Path
        Keys and list-item selectors: @('nodes', '[name=node-1]', 'network_adapters', '[name=Slot 3 Port 1]', 'mac_address').
        A selector '[name=X]' picks the list item whose name key is X.
    .PARAMETER InsertIfMissing
        Adds the last key under its existing parent when it is not there. A missing parent is never created.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$InsertIfMissing
    )
    $result = { param($r, $old = $null, $line = -1) [pscustomobject]@{ Result = $r; Old = $old; Line = $line } }
    $start = 0; $end = $Lines.Count; $keyIndent = 0; $firstIsItem = $false
    for ($s = 0; $s -lt $Path.Count; $s++) {
        $segment = $Path[$s]; $isLast = ($s -eq $Path.Count - 1)
        if ($segment -match '^\[name=(?<n>.+)\]$') {
            $wanted = $Matches['n']
            $first = $null
            for ($i = $start; $i -lt $end; $i++) { if (-not (Test-SkippableLine $Lines[$i])) { $first = $i; break } }
            if ($null -eq $first) { return (& $result 'NotFound') }
            $seqIndent = Get-LineIndent $Lines[$first]
            $found = -1; $column = 0
            for ($i = $first; $i -lt $end; $i++) {
                if (Test-SkippableLine $Lines[$i]) { continue }
                if ((Get-LineIndent $Lines[$i]) -ne $seqIndent) { continue }
                if ($Lines[$i] -match '^(?<pre>\s*-\s+)name\s*:\s*(?<v>.*)$' -and (ConvertFrom-YamlScalarText (($Matches['v'] -replace '\s+#.*$', ''))) -eq $wanted) { $found = $i; $column = $Matches['pre'].Length; break }
            }
            if ($found -lt 0) { return (& $result 'NotFound') }
            $end = Get-ScopeEnd -Lines $Lines -From ($found + 1) -Indent $seqIndent -Limit $end -SequenceAtIndent $false
            $start = $found; $keyIndent = $column; $firstIsItem = $true
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
            if ($isLast -and $InsertIfMissing) {
                $at = $end
                while ($at -gt $start + 1 -and (Test-SkippableLine $Lines[$at - 1])) { $at-- }
                $Lines.Insert($at, ((' ' * $keyIndent) + "${segment}: $(ConvertTo-YamlScalar $Value)"))
                return (& $result 'Inserted' $null $at)
            }
            return (& $result 'NotFound')
        }
        if ($isLast) {
            $pattern = "^(?<pre>.*?\b$([regex]::Escape($segment))\s*:\s*)(?<val>`"(?:[^`"\\]|\\.)*`"|'[^']*'|[^#]*?)(?<post>\s+#.*)?\s*$"
            if ($Lines[$foundKey] -notmatch $pattern) { return (& $result 'NotScalar' $null $foundKey) }
            $old = ConvertFrom-YamlScalarText $Matches['val']
            if ($old -eq '') {
                $next = Get-ScopeEnd -Lines $Lines -From ($foundKey + 1) -Indent $keyIndent -Limit $end -SequenceAtIndent $true
                if ($next -gt $foundKey + 1 -and ($Lines[($foundKey + 1)..($next - 1)] | Where-Object { -not (Test-SkippableLine $_) })) { return (& $result 'NotScalar' $null $foundKey) }
            }
            if ($old -eq [string]$Value) { return (& $result 'Unchanged' $old $foundKey) }
            $Lines[$foundKey] = $Matches['pre'] + (ConvertTo-YamlScalar $Value) + $Matches['post']
            return (& $result 'Changed' $old $foundKey)
        }
        $bodyEnd = Get-ScopeEnd -Lines $Lines -From ($foundKey + 1) -Indent $keyIndent -Limit $end -SequenceAtIndent $true
        $first = $null
        for ($i = $foundKey + 1; $i -lt $bodyEnd; $i++) { if (-not (Test-SkippableLine $Lines[$i])) { $first = $i; break } }
        if ($null -eq $first) { return (& $result 'NotFound') }
        $start = $foundKey + 1; $end = $bodyEnd; $firstIsItem = $false
        $keyIndent = Get-LineIndent $Lines[$first]
    }
    return (& $result 'NotFound')
}

function Get-AzlDiscoveryChange {
    <#
    .SYNOPSIS
        What discovery would change in infrastructure.yml, and what it only notes.
    .DESCRIPTION
        For each node: serial_number from the service tag; and for each discovered port the MAC of the file's network_adapters
        entry of the same name (an entry whose MAC already matches is left alone). A node described with management only gets
        management.mac_address when the management port is confirmed (-ManagementPort, or the MAC already in the file).
        Ports the file does not list, and file entries whose MAC no port has, are Notes: the proposal file lists the ports.
    .PARAMETER Infrastructure
        The parsed file (ordered dictionary).
    .PARAMETER Item
        Objects with NodeName, Discovery and optional ManagementPort.
    .OUTPUTS
        Changes (NodeName, Path, Display, Old, New) and Notes (strings).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][object[]]$Item)
    $changes = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $add = {
        param($node, [string[]]$path, $old, $new)
        $changes.Add([pscustomobject]@{ NodeName = $node; Path = ([string[]](@('nodes', "[name=$node]") + $path)); Display = "nodes[$node].$($path -join '.')"; Old = $old; New = $new })
    }
    foreach ($i in $Item) {
        $name = [string]$i.NodeName
        $node = @($Infrastructure['nodes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -eq $name } | Select-Object -First 1
        if (-not $node) { $notes.Add("Node '$name' is not in the file: skipped."); continue }
        $d = $i.Discovery
        $tag = [string]$d.Identity.ServiceTag
        if ($tag -and [string]$node['serial_number'] -ne $tag) { & $add $name @('serial_number') $node['serial_number'] $tag }
        $ports = @($d.NetworkPorts)
        if ($node.Contains('network_adapters')) {
            $adapters = @($node['network_adapters'])
            foreach ($p in $ports) {
                $byMac = $adapters | Where-Object { (ConvertTo-AzlMacAddress ([string]$_['mac_address'])) -eq $p.MacAddress } | Select-Object -First 1
                if ($byMac) { continue }
                $byName = $adapters | Where-Object { [string]$_['name'] -eq $p.Name } | Select-Object -First 1
                if ($byName) { & $add $name @('network_adapters', "[name=$($p.Name)]", 'mac_address') $byName['mac_address'] $p.MacAddress }
                else { $notes.Add("${name}: port '$($p.Name)' ($($p.MacAddress)) is not in network_adapters: see the proposal file.") }
            }
            foreach ($a in $adapters) {
                $mac = ConvertTo-AzlMacAddress ([string]$a['mac_address'])
                if ($mac -and -not ($ports | Where-Object { $_.MacAddress -eq $mac })) { $notes.Add("${name}: network_adapters '$($a['name'])' has MAC $mac, which no port of the machine has.") }
            }
        }
        else {
            $existing = [string](Get-AzlYamlManagementMac $node)
            $choice = Select-AzlManagementPort -Ports $ports -Name ([string]$(if ($i.PSObject.Properties['ManagementPort']) { $i.ManagementPort })) -ExistingMac $existing
            if ($existing -and -not ($ports | Where-Object { $_.MacAddress -eq (ConvertTo-AzlMacAddress $existing) })) { $notes.Add("${name}: management.mac_address $existing is not a MAC of this machine.") }
            elseif (-not $existing -and $choice.Port -and $choice.Confirmed) { & $add $name @('management', 'mac_address') $null $choice.Port.MacAddress }
            elseif (-not $existing -and $choice.Port) { $notes.Add("${name}: suggested management port '$($choice.Port.Name)' ($($choice.Port.MacAddress)), $($choice.Reason). Give -ManagementPort to write it.") }
        }
    }
    return [pscustomobject]@{ Changes = @($changes); Notes = @($notes) }
}

function Get-AzlYamlManagementMac($Node) {
    $m = $Node['management']
    if ($m -is [System.Collections.IDictionary] -and $m.Contains('mac_address')) { return $m['mac_address'] }
    return $null
}

function Invoke-AzlYamlEdit {
    <#
    .SYNOPSIS
        Applies changes from Get-AzlDiscoveryChange to a file. Writes a backup first; changes nothing without confirmation.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Change)
    $raw = Get-Content -LiteralPath $Path -Raw
    $newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($raw -split '\r?\n'))
    $applied = [System.Collections.Generic.List[object]]::new()
    $backup = $null
    if ($Change.Count -gt 0 -and $PSCmdlet.ShouldProcess($Path, "Write $($Change.Count) discovered value(s)")) {
        foreach ($c in $Change) {
            $r = Edit-AzlYamlValue -Lines $lines -Path $c.Path -Value $c.New -InsertIfMissing
            $applied.Add([pscustomobject]@{ Display = $c.Display; Result = $r.Result; Old = $r.Old; New = $c.New })
        }
        $backup = "$Path.bak.$([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
        Copy-Item -LiteralPath $Path -Destination $backup
        [System.IO.File]::WriteAllText($Path, ($lines -join $newline), [System.Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]@{ Backup = $backup; Results = @($applied) }
}

Export-ModuleMember -Function Edit-AzlYamlValue, Get-AzlDiscoveryChange, Invoke-AzlYamlEdit
