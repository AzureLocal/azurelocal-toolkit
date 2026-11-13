#Requires -Version 7.0
<#
.SYNOPSIS
    Finds, in PowerShell code, where the keys of infrastructure.yml are read: the code half of the variable map.

.DESCRIPTION
    New-VariableMap.ps1 builds config/variables/docs/VARIABLE-MAP.md from the master registry and from this scan. The scan parses each
    .ps1 and .psm1 file (the PowerShell parser, nothing is run) and resolves key paths three ways. Every record says which one it used.

    chain     A property or index chain that starts at the file (a variable named Infrastructure, Config, ...; a variable the code
              assigned from such a chain; the item variable of a foreach over a list; $_ in Where-Object and ForEach-Object):
              $infra.cluster.name, $node['bmc']['ip_address'], foreach ($n in $infra.nodes) { $n.serial_number }.
    literal   A string that is exactly a registry path ('cluster.name', 'nodes[].name'), or a reader command given a base and a key:
              Get-AzlProp $node 'bmc.ip_address' (any command named Get-*Prop|Value|Leaf), .Contains('x') / .ContainsKey('x').
    inferred  A path built from a prefix and a literal in the same statement:  & $v "networking.management.$k" with
              foreach ($k in 'subnet', 'gateway') ..., or $item[$k] with a foreach over literal keys.

    A record is: Path (registry path), File, Function, Mode. Reading a list or a section counts for that path only; the map then
    shows a key under it as "read as part of" the parent, never as read by name.

    Limits, stated in the map: only PowerShell is parsed; a path that code builds at run time from data (not from literals in the same
    statement) is not seen; a value passed to another function is followed only where that function reads the key itself.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootName = '@'
# Variables that hold the whole file. A variable the code assigns from the result of a loader command is added to them.
$script:RootVariable = @('infrastructure', 'infra', 'inf', 'config', 'cfg', 'environment', 'env', 'envdata', 'environmentdata', 'data', 'tree', 'doc', 'document', 'master', 'parsed', 'yaml', 'masterfile', 'infradata', 'infrastructuredata', 'siteconfig', 'ztpenvironment')
$script:LoaderCommand = @('import-azlinfrastructure', 'convertfrom-yaml', 'read-infrastructurefile', 'read-azlsonarinfrastructurefile', 'read-azlyaml', 'get-ztpenvironment', 'read-ztpenvironment', 'convertfrom-azlsonaryaml', 'import-ztpenvironment', 'get-ztpenvironmentdata')
# A parameter with this name holds this part of the file (a node of nodes[] is passed to the functions that work on one node).
$script:ParameterPath = @{ node = 'nodes[]'; infrastructure = '@'; infra = '@' }
# Commands that return their first object argument unchanged for the purpose of the path.
$script:PassThroughCommand = @('convertto-list', 'get-list', 'convertto-azlverlist', 'convertto-azlpcllist', 'select-object', 'where-object', 'sort-object', 'foreach-object', 'out-object')
$script:FilterCommand = @('where-object', 'sort-object', 'select-object', 'group-object')
# Functions that return the items of a list of the file (the code names them; nothing else tells the scanner).
$script:ReturnPath = @{ "get-azlnodenetworkadapter" = "nodes[].network_adapters[]"; "get-azlverinfra" = "@"; "get-vfidinfra" = "@"; "get-azlverifyinfrastructure" = "@" }
$script:ReaderCommandPattern = '^(get|read)-\w*(prop|value|leaf|setting|key)$'
# Members every list or dictionary has; reading one is not reading a key of the file (only used with -ReportUnknown).
$script:CollectionMember = @('count', 'length', 'keys', 'values', 'psobject', 'issynchronized', 'isreadonly', 'isfixedsize', 'syncroot', 'comparer', 'capacity', 'psbase', 'psextended', 'pstypenames')

function Get-MapSortedString {
    <#
    .SYNOPSIS
        Strings in ordinal order, so generated output is the same on every machine (Sort-Object follows the culture of the host).
    #>
    param([AllowEmptyCollection()][string[]]$Value)
    $arr = [string[]]@($Value)
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

function Get-MapOrdered {
    <#
    .SYNOPSIS
        Items ordered by key scriptblocks (each gets the item as $args[0]): strings ordinal, numbers numerically; ties keep the input order.
    .PARAMETER Key
        One or more scriptblocks, each returning the sort value of an item.
    .PARAMETER Descending
        Per key, whether that key sorts descending.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Descending is read inside the comparison closure, which the analyzer does not follow.')]
    param([AllowEmptyCollection()][object[]]$Item, [scriptblock[]]$Key, [bool[]]$Descending = @())
    $wrapped = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($x in @($Item)) {
        $values = foreach ($k in $Key) { & $k $x }
        $wrapped.Add([pscustomobject]@{ Item = $x; Value = @($values); Index = $i })
        $i++
    }
    $compare = [System.Comparison[object]] {
        param($a, $b)
        for ($n = 0; $n -lt $Key.Count; $n++) {
            $va = $a.Value[$n]; $vb = $b.Value[$n]
            $c = if ($va -is [string] -or $vb -is [string]) { [string]::CompareOrdinal([string]$va, [string]$vb) } else { ([System.IComparable]$va).CompareTo($vb) }
            if ($c -ne 0) { if ($n -lt $Descending.Count -and $Descending[$n]) { return -$c } else { return $c } }
        }
        return $a.Index.CompareTo($b.Index)
    }.GetNewClosure()
    $wrapped.Sort($compare)
    return @($wrapped | ForEach-Object { $_.Item })
}

function Get-MapIndex {
    <#
    .SYNOPSIS
        The registry paths as sets, for the scanner: all paths, the lists (paths whose members are written path[].member) and the maps of free keys.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Record)
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $arrays = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $maps = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $top = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in $Record) {
        [void]$paths.Add($r.Path)
        if ($r.Path -notmatch '[.\[]') { [void]$top.Add($r.Path) }
        if ($r.Shape -eq 'array') { [void]$arrays.Add($r.Path) }
        if ($r.Path.EndsWith('.*')) { [void]$maps.Add($r.Path.Substring(0, $r.Path.Length - 2)) }
    }
    [pscustomobject]@{ Paths = $paths; Arrays = $arrays; Maps = $maps; Top = $top }
}

function Join-MapPath {
    # The registry path of member $Member of the node at $Base, or $null.
    param($Index, [string]$Base, [string]$Member)
    if ($null -eq $Base -or [string]::IsNullOrEmpty($Member)) { return $null }
    if ($Base -eq $script:RootName) { if ($Index.Top.Contains($Member)) { return $Member } else { return $null } }
    if ($Base.EndsWith('[]')) {
        $c = "$Base.$Member"
        if ($Index.Paths.Contains($c)) { return $c }
        return $null
    }
    $c = "$Base.$Member"
    if ($Index.Paths.Contains($c)) { return $c }
    if ($Index.Arrays.Contains($Base)) { $c = "$Base[].$Member"; if ($Index.Paths.Contains($c)) { return $c } }
    if ($Index.Maps.Contains($Base)) { return "$Base.*" }
    return $null
}

function Get-MapElement {
    # The item of a list node (nodes -> nodes[]); anything else stays.
    param($Index, [string]$Path)
    if ($null -eq $Path) { return $null }
    if ($Index.Arrays.Contains($Path)) { return "$Path[]" }
    return $Path
}

function Get-ConstantString {
    param($Ast)
    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $Ast.Value }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) { return [string]$Ast.Value }
    return $null
}

function Find-MapReader {
    <#
    .SYNOPSIS
        Parses the files and returns the key paths they read: Path, File (relative to -Root, forward slashes), Function, Mode.
    .PARAMETER Root
        The repository root; File is relative to it.
    .PARAMETER File
        The .ps1 and .psm1 files to scan.
    .PARAMETER Index
        From Get-MapIndex.
    .PARAMETER ReportUnknown
        Also return a record with Mode 'unknown' for each key a chain or a reader command reads from the file that the registry does
        not have (tests/variables/Enforcement.Tests.ps1). The variable map does not use it; without it the result is unchanged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$File, [Parameter(Mandatory)]$Index, [switch]$ReportUnknown)

    $found = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')

    foreach ($path in $File) {
        $relative = ($path.Substring($rootFull.Length).TrimStart('\', '/')) -replace '\\', '/'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { continue }

        $scopeOf = {
            param($node)
            $p = $node.Parent
            while ($null -ne $p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
                $p = $p.Parent
            }
            return '(script)'
        }

        $binding = @{}   # "scope|variable" -> path
        $lookup = {
            param([string]$name, [string]$scope)
            $n = $name.ToLowerInvariant()
            if ($n.Contains(':')) { $n = $n.Substring($n.IndexOf(':') + 1) }
            if ($binding.ContainsKey("$scope|$n")) { return $binding["$scope|$n"] }
            if ($binding.ContainsKey("(script)|$n")) { return $binding["(script)|$n"] }
            if ($script:RootVariable -contains $n) { return $script:RootName }
            if ($scope -ne '(script)' -and $script:ParameterPath.ContainsKey($n) -and $binding.ContainsKey("$scope|param|$n")) { return $script:ParameterPath[$n] }
            return $null
        }

        # Declared parameters named like a node or the file.
        foreach ($p in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
            $n = $p.Name.VariablePath.UserPath.ToLowerInvariant()
            if ($script:ParameterPath.ContainsKey($n)) {
                $scope = & $scopeOf $p
                $binding["$scope|param|$n"] = $script:ParameterPath[$n]
                $binding["$scope|$n"] = $script:ParameterPath[$n]
            }
        }

        $resolve = $null
        $resolveUnderscore = $null
        $resolve = {
            param($node)
            if ($null -eq $node) { return $null }
            switch ($node.GetType().Name) {
                'CommandExpressionAst' { return (& $resolve $node.Expression) }
                'ParenExpressionAst' { return (& $resolve $node.Pipeline) }
                'ConvertExpressionAst' { return (& $resolve $node.Child) }
                'ArrayExpressionAst' { if ($node.SubExpression.Statements.Count -eq 1) { return (& $resolve $node.SubExpression.Statements[0]) } return $null }
                'SubExpressionAst' { if ($node.SubExpression.Statements.Count -eq 1) { return (& $resolve $node.SubExpression.Statements[0]) } return $null }
                'ArrayLiteralAst' { if ($node.Elements.Count -eq 1) { return (& $resolve $node.Elements[0]) } return $null }
                'PipelineAst' {
                    $first = $node.PipelineElements[0]
                    for ($i = 1; $i -lt $node.PipelineElements.Count; $i++) {
                        $e = $node.PipelineElements[$i]
                        if ($e -isnot [System.Management.Automation.Language.CommandAst] -or $script:FilterCommand -notcontains $e.GetCommandName().ToLowerInvariant()) { return $null }
                    }
                    return (& $resolve $first)
                }
                'VariableExpressionAst' {
                    $name = $node.VariablePath.UserPath
                    if ($name -eq '_' -or $name -eq 'PSItem') { return (& $resolveUnderscore $node) }
                    return (& $lookup $name (& $scopeOf $node))
                }
                'MemberExpressionAst' {
                    $m = Get-ConstantString $node.Member
                    if ($m -eq "Infrastructure") { return $script:RootName }
                    $base = & $resolve $node.Expression
                    if ($null -eq $base) { return $null }
                    if ($null -eq $m) { return $null }
                    return (Join-MapPath -Index $Index -Base $base -Member $m)
                }
                'IndexExpressionAst' {
                    $base = & $resolve $node.Target
                    if ($null -eq $base) { return $null }
                    $k = Get-ConstantString $node.Index
                    if ($null -ne $k -and $node.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return (Join-MapPath -Index $Index -Base $base -Member $k) }
                    return (Get-MapElement $Index $base)
                }
                'InvokeMemberExpressionAst' {
                    $m = Get-ConstantString $node.Member
                    if ($m -in 'Where', 'GetEnumerator', 'ToArray', 'Sort') { return (& $resolve $node.Expression) }
                    return $null
                }
                'CommandAst' {
                    $name = $node.GetCommandName()
                    if (-not $name) {
                        # & $get "cluster.name": a getter held in a variable, given a path from the file
                        if ($node.InvocationOperator -eq "Ampersand" -and $node.CommandElements.Count -ge 2 -and $node.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            $cur = $script:RootName
                            foreach ($seg in $node.CommandElements[1].Value.Split(".")) { $cur = Join-MapPath -Index $Index -Base $cur -Member $seg; if ($null -eq $cur) { return $null } }
                            return $cur
                        }
                        return $null
                    }
                    $n = $name.ToLowerInvariant()
                    $args1 = @($node.CommandElements | Select-Object -Skip 1)
                    if ($script:PassThroughCommand -contains $n -or $n -match '^(convertto|get)-\w*(list|array)$') {
                        foreach ($a in $args1) { if ($a -is [System.Management.Automation.Language.CommandParameterAst]) { continue }; $r = & $resolve $a; if ($null -ne $r) { return $r }; break }
                        return $null
                    }
                    if ($script:LoaderCommand -contains $n) { return $script:RootName }
                    if ($script:ReturnPath.ContainsKey($n)) { return $script:ReturnPath[$n] }
                    if ($n -match $script:ReaderCommandPattern) {
                        $base = $null; $key = $null
                        foreach ($a in $args1) {
                            if ($a -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                            if ($null -eq $base) { $r = & $resolve $a; if ($null -ne $r) { $base = $r; continue } }
                            if ($null -eq $key) { $c = Get-ConstantString $a; if ($null -ne $c -and $a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $key = $c } }
                        }
                        if ($null -ne $base -and $null -ne $key) {
                            $cur = $base
                            foreach ($seg in $key.Split('.')) { $cur = Join-MapPath -Index $Index -Base $cur -Member ($seg); if ($null -eq $cur) { return $null } ; $cur = $cur }
                            return $cur
                        }
                        return $null
                    }
                    return $null
                }
                'AssignmentStatementAst' { return (& $resolve $node.Right) }
                default { return $null }
            }
        }

        $resolveUnderscore = {
            param($node)
            $p = $node.Parent
            $hops = 0
            while ($null -ne $p -and $hops -lt 4) {
                if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $holder = $p.Parent
                    if ($holder -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                        $m = Get-ConstantString $holder.Member
                        if ($m -in 'Where', 'ForEach', 'Any', 'All', 'Exists') { $t = & $resolve $holder.Expression; if ($null -ne $t) { return (Get-MapElement $Index $t) } }
                    }
                    elseif ($holder -is [System.Management.Automation.Language.CommandAst]) {
                        $pl = $holder.Parent
                        if ($pl -is [System.Management.Automation.Language.PipelineAst]) {
                            $idx = $pl.PipelineElements.IndexOf($holder)
                            if ($idx -gt 0) {
                                # the objects flowing in: the previous element, through the filters
                                $j = $idx - 1
                                while ($j -gt 0 -and $pl.PipelineElements[$j] -is [System.Management.Automation.Language.CommandAst] -and $script:FilterCommand -contains $pl.PipelineElements[$j].GetCommandName().ToLowerInvariant()) { $j-- }
                                $src = $pl.PipelineElements[$j]
                                $t = & $resolve $src
                                if ($null -ne $t) { return (Get-MapElement $Index $t) }
                            }
                        }
                    }
                    $hops++
                }
                $p = $p.Parent
            }
            return $null
        }

        # Pass 1..4: bindings from assignments and foreach statements, until nothing changes.
        $assigns = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -or $a -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))
        for ($pass = 0; $pass -lt 4; $pass++) {
            $changed = $false
            foreach ($a in $assigns) {
                $scope = & $scopeOf $a
                if ($a -is [System.Management.Automation.Language.ForEachStatementAst]) {
                    $name = $a.Variable.VariablePath.UserPath.ToLowerInvariant()
                    $p1 = & $resolve $a.Condition
                    if ($null -eq $p1) { continue }
                    $elem = Get-MapElement $Index $p1
                    $key = "$scope|$name"
                    if ($p1 -ne $script:RootName -and ((-not $binding.ContainsKey($key)) -or $binding[$key] -ne $elem)) { $binding[$key] = $elem; $changed = $true }
                    continue
                }
                if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                $name = $a.Left.VariablePath.UserPath.ToLowerInvariant()
                if ($name.Contains(':')) { $name = $name.Substring($name.IndexOf(':') + 1) }
                $p1 = & $resolve $a.Right
                if ($null -eq $p1) { continue }
                $key = "$scope|$name"
                if ((-not $binding.ContainsKey($key)) -or $binding[$key] -ne $p1) { $binding[$key] = $p1; $changed = $true }
            }
            if (-not $changed) { break }
        }

        # The variable a chain starts at ("infra" for $infra.cluster.name); only -ReportUnknown uses it.
        $rootOf = {
            param($node)
            $cur = $node
            while ($null -ne $cur) {
                if ($cur -is [System.Management.Automation.Language.VariableExpressionAst]) { return ($cur.VariablePath.UserPath.ToLowerInvariant() -replace '^.*:', '') }
                if ($cur -is [System.Management.Automation.Language.MemberExpressionAst] -or $cur -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) { $cur = $cur.Expression; continue }
                if ($cur -is [System.Management.Automation.Language.IndexExpressionAst]) { $cur = $cur.Target; continue }
                if ($cur -is [System.Management.Automation.Language.ParenExpressionAst]) { $cur = $cur.Pipeline; continue }
                if ($cur -is [System.Management.Automation.Language.PipelineAst] -and $cur.PipelineElements.Count -ge 1) { $cur = $cur.PipelineElements[0]; continue }
                if ($cur -is [System.Management.Automation.Language.CommandExpressionAst]) { $cur = $cur.Expression; continue }
                break
            }
            return '(other)'
        }

        $emit = {
            param([string]$p, $node, [string]$mode, [string]$root = '')
            if ([string]::IsNullOrEmpty($p) -or $p -eq $script:RootName) { return }
            if ($p.EndsWith('[]')) { $p = $p.Substring(0, $p.Length - 2) }
            $scope = & $scopeOf $node
            $k = "$relative|$scope|$p|$mode|$($node.Extent.StartLineNumber)"
            if ($seen.Add($k)) { $found.Add([pscustomobject]@{ Path = $p; File = $relative; Function = $scope; Mode = $mode; Line = $node.Extent.StartLineNumber; Root = $root }) }
        }

        # chains (member, index, and the reader commands)
        $nodes = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.MemberExpressionAst] -or $a -is [System.Management.Automation.Language.IndexExpressionAst] -or $a -is [System.Management.Automation.Language.CommandAst] -or $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or $a -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $a -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
        foreach ($n in $nodes) {
            if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                $m = Get-ConstantString $n.Member
                if ($m -in 'Contains', 'ContainsKey', 'TryGetValue', 'Remove') {
                    $base = & $resolve $n.Expression
                    $k = if ($n.Arguments.Count -gt 0) { Get-ConstantString $n.Arguments[0] } else { $null }
                    if ($null -ne $base -and $null -ne $k) { $j = Join-MapPath -Index $Index -Base $base -Member $k; if ($j) { & $emit $j $n 'literal' } }
                    elseif ($null -ne $base -and $n.Arguments.Count -gt 0 -and $null -eq $k) {
                        # .Contains($k) inside foreach over literal keys
                        $loop = $n.Parent
                        while ($null -ne $loop -and $loop -isnot [System.Management.Automation.Language.ForEachStatementAst]) { $loop = $loop.Parent }
                        if ($loop -is [System.Management.Automation.Language.ForEachStatementAst]) {
                            $lits = $loop.Condition.FindAll({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
                            foreach ($l in $lits) { $j = Join-MapPath -Index $Index -Base $base -Member $l.Value; if ($j) { & $emit $j $n 'inferred' } }
                        }
                    }
                }
                continue
            }
            if ($n -is [System.Management.Automation.Language.MemberExpressionAst]) {
                if ($n.Static) { continue }
                $r = & $resolve $n
                if ($r) { & $emit $r $n 'chain' }
                elseif ($ReportUnknown) {
                    $m = Get-ConstantString $n.Member
                    $b = & $resolve $n.Expression
                    if ($b -and $m -and $script:CollectionMember -notcontains $m.ToLowerInvariant()) { & $emit ($(if ($b -eq $script:RootName) { $m } else { "$b.$m" })) $n 'unknown' (& $rootOf $n.Expression) }
                }
                continue
            }
            if ($n -is [System.Management.Automation.Language.IndexExpressionAst]) {
                $r = & $resolve $n
                if ($ReportUnknown -and -not $r -and $n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $b = & $resolve $n.Target
                    if ($b) { & $emit ($(if ($b -eq $script:RootName) { $n.Index.Value } else { "$b.$($n.Index.Value)" })) $n 'unknown' (& $rootOf $n.Target) }
                }
                if ($r -and $n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) { & $emit $r $n 'chain' }
                elseif ($n.Index -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    # $item[$k] where $k loops over literals in the enclosing foreach
                    $base = & $resolve $n.Target
                    if ($base) {
                        $loop = $n.Parent
                        while ($null -ne $loop -and $loop -isnot [System.Management.Automation.Language.ForEachStatementAst]) { $loop = $loop.Parent }
                        if ($loop -is [System.Management.Automation.Language.ForEachStatementAst]) {
                            $lits = $loop.Condition.FindAll({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
                            foreach ($l in $lits) { $j = Join-MapPath -Index $Index -Base $base -Member $l.Value; if ($j) { & $emit $j $n 'inferred' } }
                        }
                    }
                }
                continue
            }
            if ($n -is [System.Management.Automation.Language.CommandAst]) {
                $name = $n.GetCommandName()
                if ($name -and $name.ToLowerInvariant() -match $script:ReaderCommandPattern) {
                    $r = & $resolve $n
                    if ($r) { & $emit $r $n 'literal' }
                    elseif ($ReportUnknown) {
                        # the same walk as the resolver, up to the first segment the registry does not have
                        $base = $null; $key = $null
                        foreach ($a in @($n.CommandElements | Select-Object -Skip 1)) {
                            if ($a -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                            if ($null -eq $base) { $br = & $resolve $a; if ($null -ne $br) { $base = $br; continue } }
                            if ($null -eq $key -and $a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $key = $a.Value }
                        }
                        if ($null -ne $base -and $null -ne $key) {
                            $cur = $base
                            foreach ($seg in $key.Split('.')) {
                                $next = Join-MapPath -Index $Index -Base $cur -Member $seg
                                if ($null -eq $next) { & $emit ($(if ($cur -eq $script:RootName) { $seg } else { "$cur.$seg" })) $n 'unknown' '(reader)'; break }
                                $cur = $next
                            }
                        }
                    }
                }
                elseif ($ReportUnknown -and -not $name -and $n.InvocationOperator -eq 'Ampersand' -and $n.CommandElements.Count -ge 2 -and $n.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    # & $get 'networking.management.gatway': a getter held in a variable, given a path that starts at a top-level key of the file
                    $key = $n.CommandElements[1].Value
                    $segments = $key.Split('.')
                    if ($segments.Count -ge 2 -and $key -cmatch '^[a-z_][a-z0-9_]*(\.[a-z0-9_]+)+$' -and $Index.Top.Contains($segments[0])) {
                        $cur = $script:RootName
                        foreach ($seg in $segments) {
                            $next = Join-MapPath -Index $Index -Base $cur -Member $seg
                            if ($null -eq $next) { & $emit ($(if ($cur -eq $script:RootName) { $seg } else { "$cur.$seg" })) $n 'unknown' '(getter)'; break }
                            $cur = $next
                        }
                    }
                }
                continue
            }
            if ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $v = $n.Value
                if ($v.Length -gt 3 -and $v.Length -lt 140 -and $v.Contains('.') -and $Index.Paths.Contains($v)) { & $emit $v $n 'literal' }
                continue
            }
            if ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                $raw = $n.Value
                $dollar = $raw.IndexOf('$')
                if ($dollar -lt 2) { continue }
                $prefix = $raw.Substring(0, $dollar)
                if (-not $prefix.EndsWith('.')) { continue }
                # the enclosing foreach (or command) holds the literal keys
                $scopeNode = $n.Parent
                while ($null -ne $scopeNode -and $scopeNode -isnot [System.Management.Automation.Language.ForEachStatementAst]) { $scopeNode = $scopeNode.Parent }
                if ($null -eq $scopeNode) { continue }
                $lits = $scopeNode.Condition.FindAll({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
                foreach ($l in $lits) { $c = $prefix + $l.Value; if ($Index.Paths.Contains($c)) { & $emit $c $n 'inferred' } }
            }
        }
    }
    return $found.ToArray()
}

Export-ModuleMember -Function Get-MapSortedString, Get-MapOrdered, Get-MapIndex, Find-MapReader, Join-MapPath, Get-MapElement
