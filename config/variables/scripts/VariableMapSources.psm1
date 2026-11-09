#Requires -Version 7.0
<#
.SYNOPSIS
    The facts the variable map takes from code besides "who reads a key": what writes it, what it becomes downstream.

.DESCRIPTION
    Every function parses code (nothing is run) and returns plain records. VariableMap.psm1 puts them next to the registry.

    Get-MapArmParameter        template parameter -> the keys it comes from, in New-AzlArmParameterSet (AzlArmDeployment.psm1)
    Get-MapOsStep              key -> OS configuration step, from the node spec (Get-AzlNodeSpec) and the step blocks of Compare-AzlNodeState
    Get-MapGateCheck           pre-cluster verification check id -> the keys it reads or names
    Get-MapDiscoveryWrite      keys the Dell/Redfish discovery proposes (ConvertTo-AzlDiscoveryProposal) or applies (Get-AzlDiscoveryChange)
    Get-MapSonarKey            key -> Sonar configuration key (the mapping ConvertFrom-AzlSonarInfrastructureTree documents)
    Get-MapTrailwrightQuestion key -> the Trailwright question (step, owner, kind, whether it is optional or conditional)
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VariableMapScanner.psm1')

$script:Lang = 'System.Management.Automation.Language'

function Get-MapAst {
    param([string]$Path)
    $tokens = $null; $errors = $null
    return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
}

function Get-MapFunctionAst {
    param($Ast, [string]$Name)
    $wanted = $Name
    $matcher = { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $wanted }.GetNewClosure()
    return $Ast.Find($matcher, $true)
}

# Reads of a function (scan records), optionally between two lines of its file.
function Select-MapRead {
    param([object[]]$Reader, [string]$File, [string]$Function, [int]$From = 0, [int]$To = [int]::MaxValue)
    @($Reader | Where-Object { $_.File -eq $File -and $_.Function -eq $Function -and $_.Line -ge $From -and $_.Line -le $To })
}

# ---------------------------------------------------------------------------------------------------------------------
# ARM parameters
# ---------------------------------------------------------------------------------------------------------------------

function Get-MapArmParameter {
    <#
    .SYNOPSIS
        One record per ARM template parameter that New-AzlArmParameterSet sets: Name, Key (file keys read directly), ViaHelper
        (keys read by the helper functions it calls), Source (handoff, report, SBE folder, parameter), When (the condition around it).
    .PARAMETER Root
        The toolkit root.
    .PARAMETER Reader
        The toolkit scan (Find-MapReader).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][object[]]$Reader, [Parameter(Mandatory)]$Index)

    $relative = 'scripts/common/arm-deployment/AzlArmDeployment.psm1'
    $ast = Get-MapAst (Join-Path $Root $relative)
    $fn = Get-MapFunctionAst $ast 'New-AzlArmParameterSet'
    $fnName = 'New-AzlArmParameterSet'
    $fnReaders = @($Reader | Where-Object { $_.Function -eq $fnName -and $_.File -eq $relative })

    # helper functions of the toolkit by name -> their direct reads
    $byFunction = @{}
    foreach ($r in $Reader) { if (-not $byFunction.ContainsKey($r.Function)) { $byFunction[$r.Function] = [System.Collections.Generic.List[object]]::new() }; $byFunction[$r.Function].Add($r) }

    # assignments to local variables, for "$p.x = $var" indirection
    $assignments = @($fn.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    $byVariable = @{}
    foreach ($a in $assignments) {
        if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $v = $a.Left.VariablePath.UserPath.ToLowerInvariant()
            if (-not $byVariable.ContainsKey($v)) { $byVariable[$v] = [System.Collections.Generic.List[object]]::new() }
            $byVariable[$v].Add($a)
        }
    }
    $skipVariable = @('p', 'final', 'warnings', 'infrastructure', 'g', 'catalog', 'declared', 'template', 'resolvelog', '_', 'args', 'null', 'true', 'false')
    $sourceVariable = [ordered]@{ handoff = 'ZTP handoff'; handoffnode = 'ZTP handoff'; nodereport = 'OS configuration report'; adaptermap = 'OS configuration report'; resolvemap = 'OS configuration report'; sbedeployment = 'SBE folder (Get-AzlSbeBundle)'; arcresourceid = 'parameter -ArcResourceId'; hciresourceproviderobjectid = 'parameter -HciResourceProviderObjectId'; mode = 'parameter -Mode'; sanlunidsource = 'parameter -SanLunIdSource' }

    $collect = $null
    $collect = {
        param($node, $depth, $visited)
        $res = [ordered]@{ Key = [System.Collections.Generic.HashSet[string]]::new(); Via = [System.Collections.Generic.HashSet[string]]::new(); Source = [System.Collections.Generic.HashSet[string]]::new() }
        $from = $node.Extent.StartLineNumber; $to = $node.Extent.EndLineNumber
        foreach ($r in $fnReaders) { if ($r.Line -ge $from -and $r.Line -le $to -and $r.Path.Contains('.')) { [void]$res.Key.Add($r.Path) } }
        foreach ($v in $node.FindAll({ param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $n = $v.VariablePath.UserPath.ToLowerInvariant()
            if ($sourceVariable.Contains($n)) { [void]$res.Source.Add($sourceVariable[$n]) }
            if ($depth -lt 3 -and $skipVariable -notcontains $n -and $byVariable.ContainsKey($n) -and $visited.Add($n)) {
                foreach ($a in $byVariable[$n]) {
                    $sub = & $collect $a ($depth + 1) $visited
                    foreach ($k in $sub.Key) { [void]$res.Key.Add($k) }
                    foreach ($k in $sub.Via) { [void]$res.Via.Add($k) }
                    foreach ($k in $sub.Source) { [void]$res.Source.Add($k) }
                }
            }
        }
        foreach ($c in $node.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cn = $c.GetCommandName()
            if ($cn -and $byFunction.ContainsKey($cn) -and $cn -ne $fnName) { foreach ($r in $byFunction[$cn]) { if ($r.Path.Contains('.') -or $r.Path -match '\[\]') { [void]$res.Via.Add($r.Path) } } }
        }
        return $res
    }

    $rows = @{}
    $assignToParameter = {
        param($stmt, [string[]]$names, $keyHints)
        foreach ($name in $names) {
            if (-not $rows.ContainsKey($name)) { $rows[$name] = [ordered]@{ Name = $name; Key = [System.Collections.Generic.HashSet[string]]::new(); Via = [System.Collections.Generic.HashSet[string]]::new(); Source = [System.Collections.Generic.HashSet[string]]::new(); When = '' } }
            $row = $rows[$name]
            $c = & $collect $stmt 0 ([System.Collections.Generic.HashSet[string]]::new())
            if (-not @($keyHints).Count) { foreach ($k in $c.Key) { [void]$row.Key.Add($k) } }
            foreach ($k in $c.Via) { [void]$row.Via.Add($k) }
            foreach ($k in $c.Source) { [void]$row.Source.Add($k) }
            foreach ($k in $keyHints) { [void]$row.Key.Add($k) }
            # the condition around the statement
            $p = $stmt.Parent
            while ($null -ne $p -and $p -ne $fn) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($cl in $p.Clauses) {
                        if ($stmt.Extent.StartOffset -ge $cl.Item2.Extent.StartOffset -and $stmt.Extent.EndOffset -le $cl.Item2.Extent.EndOffset) {
                            $row.When = (($cl.Item1.Extent.Text -replace '\s+', ' ')).Trim()
                        }
                    }
                    if (-not $row.When -and $p.ElseClause -and $stmt.Extent.StartOffset -ge $p.ElseClause.Extent.StartOffset) { $row.When = 'else of: ' + (($p.Clauses[0].Item1.Extent.Text -replace '\s+', ' ')).Trim() }
                    if ($row.When) { break }
                }
                $p = $p.Parent
            }
        }
    }

    foreach ($a in $assignments) {
        $left = $a.Left
        $target = $null
        if ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and $left.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) { $target = $left.Expression.VariablePath.UserPath.ToLowerInvariant() }
        elseif ($left -is [System.Management.Automation.Language.IndexExpressionAst] -and $left.Target -is [System.Management.Automation.Language.VariableExpressionAst]) { $target = $left.Target.VariablePath.UserPath.ToLowerInvariant() }
        if ($target -notin 'p', 'sbe') { continue }
        $pairs = [System.Collections.Generic.List[object]]::new()
        if ($left -is [System.Management.Automation.Language.MemberExpressionAst]) { $pairs.Add(@{ Name = (Get-ConstantStringValue $left.Member); Hint = @() }) }
        else {
            $c = Get-ConstantStringValue $left.Index
            if ($null -ne $c -and $left.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $pairs.Add(@{ Name = $c; Hint = @() }) }
            else {
                # $p[$pair[0]] inside foreach over a list of @('name', 'key', ...) rows
                $loop = $a.Parent
                while ($null -ne $loop -and $loop -isnot [System.Management.Automation.Language.ForEachStatementAst]) { $loop = $loop.Parent }
                if ($loop -is [System.Management.Automation.Language.ForEachStatementAst]) {
                    $prefixes = @($loop.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) | ForEach-Object { $raw = $_.Value; $d = $raw.IndexOf('$'); if ($d -gt 1 -and $raw.Substring(0, $d).EndsWith('.')) { $raw.Substring(0, $d) } })
                    $bases = @()
                    foreach ($cmd in $loop.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                        $cn = $cmd.GetCommandName()
                        if ($cn -and $cn.ToLowerInvariant() -match '^(get|read)-\w*(prop|value|leaf)$') {
                            $first = @($cmd.CommandElements | Select-Object -Skip 1 | Select-Object -First 1)
                            if ($first.Count -and $first[0] -is [System.Management.Automation.Language.VariableExpressionAst]) {
                                $vn = $first[0].VariablePath.UserPath.ToLowerInvariant()
                                if ($byVariable.ContainsKey($vn)) { foreach ($asg in $byVariable[$vn]) { foreach ($rd in $fnReaders) { if ($rd.Line -ge $asg.Extent.StartLineNumber -and $rd.Line -le $asg.Extent.EndLineNumber) { $bases += $rd.Path } } } }
                            }
                        }
                    }
                    $rowsOfLoop = @($loop.Condition.FindAll({ param($x) $x -is [System.Management.Automation.Language.ArrayExpressionAst] -and $x.Parent -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true))
                    $rowsOfLoop = @($loop.Condition.FindAll({ param($x) $x -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true) | Where-Object { $_ -ne $loop.Condition })
                    foreach ($row in $rowsOfLoop) {
                        if (@($row.FindAll({ param($x) $x -is [System.Management.Automation.Language.ArrayExpressionAst] -and $x -ne $row }, $true)).Count) { continue }
                        $lit = @($row.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
                        if ($lit.Count -eq 0) { continue }
                        $hints = @()
                        foreach ($s in $lit | Select-Object -Skip 1) {
                            if ($Index.Paths.Contains($s)) { $hints += $s; continue }
                            foreach ($pre in $prefixes) { if ($Index.Paths.Contains($pre + $s)) { $hints += ($pre + $s) } }
                            foreach ($b in $bases) { $j = Join-MapPath -Index $Index -Base $b -Member $s; if ($j) { $hints += $j } }
                        }
                        $pairs.Add(@{ Name = $lit[0]; Hint = @($hints) })
                    }
                }
            }
        }
        foreach ($pair in $pairs) { & $assignToParameter $a @($pair.Name) $pair.Hint }
    }

    # per name keys for the loop rows: only the hints of that row would be better, but the loop assigns them all with the same code;
    # attach each row's hints to its own name
    $out = foreach ($name in (Get-MapSortedString -Value @($rows.Keys))) {
        $r = $rows[$name]
        # a section the statement reads next to its own members is only walked to reach them
        $keys = @($r.Key | Where-Object { $k = $_; -not (@($r.Key | Where-Object { $_ -ne $k -and ($_.StartsWith("$k.") -or $_.StartsWith("$k[]")) }).Count) })
        [pscustomobject]@{ Name = $name; Key = @(Get-MapSortedString -Value @($keys)); ViaHelper = @(Get-MapSortedString -Value @($r.Via | Where-Object { -not $r.Key.Contains($_) })); Source = @(Get-MapSortedString -Value @($r.Source)); When = $r.When }
    }
    return @($out)
}

function Get-ConstantStringValue {
    param($Ast)
    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $Ast.Value }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------------
# OS configuration steps
# ---------------------------------------------------------------------------------------------------------------------

function Get-MapOsStep {
    <#
    .SYNOPSIS
        Path -> the OS configuration steps that apply it. Source: which $Spec properties each 'Step' -in $Step block of Compare-AzlNodeState
        uses, which keys Get-AzlNodeSpec puts in each property, and the functions named after a step.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][object[]]$Reader)

    $relative = 'scripts/common/node-configuration/AzlNodeConfiguration.psm1'
    $ast = Get-MapAst (Join-Path $Root $relative)
    $stepNames = 'RemoteManagement', 'Drivers', 'NicNames', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe', 'ArcRegistration'
    $byFunction = @{}
    foreach ($r in $Reader) { if (-not $byFunction.ContainsKey($r.Function)) { $byFunction[$r.Function] = [System.Collections.Generic.List[object]]::new() }; $byFunction[$r.Function].Add($r) }
    $result = @{}   # path -> HashSet of steps
    $add = {
        param([string]$path, [string]$step, [string]$via)
        if (-not $result.ContainsKey($path)) { $result[$path] = @{} }
        $result[$path][$step] = $via
    }

    # 1. spec property -> keys (Get-AzlNodeSpec)
    $spec = Get-MapFunctionAst $ast 'Get-AzlNodeSpec'
    $specReaders = @($Reader | Where-Object { $_.File -eq $relative -and $_.Function -eq 'Get-AzlNodeSpec' })
    $assignments = @($spec.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    $byVariable = @{}
    foreach ($a in $assignments) { $v = $a.Left.VariablePath.UserPath.ToLowerInvariant(); if (-not $byVariable.ContainsKey($v)) { $byVariable[$v] = [System.Collections.Generic.List[object]]::new() }; $byVariable[$v].Add($a) }
    $reads = $null
    $reads = {
        param($node, $depth, $visited)
        $set = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($r in $specReaders) { if ($r.Line -ge $node.Extent.StartLineNumber -and $r.Line -le $node.Extent.EndLineNumber) { [void]$set.Add($r.Path) } }
        foreach ($c in $node.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cn = $c.GetCommandName()
            if ($cn -and $cn -ne 'Get-AzlNodeSpec' -and $byFunction.ContainsKey($cn)) { foreach ($r in $byFunction[$cn]) { [void]$set.Add($r.Path) } }
        }
        if ($depth -lt 3) {
            foreach ($v in $node.FindAll({ param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $n = $v.VariablePath.UserPath.ToLowerInvariant()
                if ($n -in 'infrastructure', 'node', '_', 'handoff') { continue }
                if ($byVariable.ContainsKey($n) -and $visited.Add($n)) { foreach ($asg in $byVariable[$n]) { foreach ($k in (& $reads $asg ($depth + 1) $visited)) { [void]$set.Add($k) } } }
            }
        }
        return $set
    }
    $propKeys = @{}
    $tables = @($spec.FindAll({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $true))
    $final = $tables | Sort-Object { $_.KeyValuePairs.Count } | Select-Object -Last 1
    foreach ($kv in $final.KeyValuePairs) {
        $prop = $kv.Item1.Value
        $propKeys[$prop] = & $reads $kv.Item2 0 ([System.Collections.Generic.HashSet[string]]::new())
    }

    # 2. step block -> spec properties (Compare-AzlNodeState)
    $compare = Get-MapFunctionAst $ast 'Compare-AzlNodeState'
    $ifs = @($compare.FindAll({ param($a) $a -is [System.Management.Automation.Language.IfStatementAst] }, $true))
    foreach ($if in $ifs) {
        foreach ($cl in $if.Clauses) {
            $cond = $cl.Item1
            $steps = @($cond.FindAll({ param($a) $a -is [System.Management.Automation.Language.BinaryExpressionAst] -and $a.Operator.ToString() -in 'Iin', 'Cin', 'In' -and $a.Left -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $a.Right -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.Right.VariablePath.UserPath -eq 'Step' }, $true) | ForEach-Object { $_.Left.Value })
            if (-not $steps.Count) { continue }
            $props = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($scopeNode in @($cond, $cl.Item2)) {
                foreach ($m in $scopeNode.FindAll({ param($a) $a -is [System.Management.Automation.Language.MemberExpressionAst] -and $a.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.Expression.VariablePath.UserPath -eq 'Spec' }, $true)) { [void]$props.Add($m.Member.Value) }
            }
            foreach ($s in $steps) {
                foreach ($p in $props) {
                    if ($propKeys.ContainsKey($p)) { foreach ($k in $propKeys[$p]) { & $add $k $s "Spec.$p" } }
                }
            }
        }
    }
    # The management address, hostname and DHCP settings all hang off Spec.Management and Spec.Name: Hostname uses Spec.Name and Spec.Hostname.

    # 3a. the line that reads a key names a step: $clearStorage = ... 'os_configuration.clear_storage' (CamelCase or snake_case, a word of its own)
    $lineCache = @{}
    foreach ($r in $Reader) {
        if ($r.File -notmatch '^scripts/common/(node-configuration|remoting)/' -and $r.File -notmatch 'phase-03-os-configuration') { continue }
        if (-not $lineCache.ContainsKey($r.File)) { $lineCache[$r.File] = [IO.File]::ReadAllLines((Join-Path $Root $r.File)) }
        $text = $lineCache[$r.File][$r.Line - 1]
        foreach ($s in $stepNames) {
            $snake = ([regex]::Replace($s, '(?<=[a-z])(?=[A-Z])', '_')).ToLowerInvariant()
            if ($s -in 'Network', 'Dns', 'Time', 'Drivers', 'Sbe', 'Hostname') { continue }   # ordinary words: only the CamelCase step names are taken from a line
            if ($text -match "(?i)(?<![A-Za-z])($s|$snake)(?![A-Za-z])") { & $add $r.Path $s "line $($r.Line) of $($r.Function)" }
        }
    }
    # 3. functions named after a step, in the OS configuration area
    foreach ($r in $Reader) {
        if ($r.File -notmatch '^scripts/common/(node-configuration|remoting)/' -and $r.File -notmatch 'phase-03-os-configuration') { continue }
        foreach ($s in $stepNames) {
            if ($r.Function -match $s -or ($s -eq 'RemoteManagement' -and $r.Function -match 'Remoting')) { & $add $r.Path $s "function $($r.Function)" }
        }
        if ($r.File -match '/remoting/') { & $add $r.Path 'RemoteManagement' "function $($r.Function)" }
    }
    return $result
}

function Get-MapOsStepFromText {
    # Steps a variable's description names: "the NicNames step", "(Mpio and SanVerify steps)". CamelCase step names are unambiguous.
    param([string]$Text)
    $steps = [System.Collections.Generic.List[string]]::new()
    foreach ($s in 'RemoteManagement', 'NicNames', 'DomainJoin', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'UnusedAdapters', 'ArcRegistration') {
        if ($Text -cmatch "\b$s\b") { $steps.Add($s) }
    }
    foreach ($s in 'Network', 'Dns', 'Time', 'Drivers', 'Sbe', 'Hostname') {
        if ($Text -cmatch "\b$s step\b" -or $Text -cmatch "\bthe $s step") { $steps.Add($s) }
    }
    return @($steps)
}

# ---------------------------------------------------------------------------------------------------------------------
# Pre-cluster verification checks
# ---------------------------------------------------------------------------------------------------------------------

function Get-MapGateCheck {
    <#
    .SYNOPSIS
        Check id -> keys. A check's keys are the keys read inside its definition, the keys read by the helper functions it calls
        (Via), and the registry paths named in its text (Named).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][object[]]$Reader, [Parameter(Mandatory)]$Index)

    $dir = Join-Path $Root 'scripts/common/arm-deployment/verification'
    $byFunction = @{}
    foreach ($r in $Reader) { if (-not $byFunction.ContainsKey($r.Function)) { $byFunction[$r.Function] = [System.Collections.Generic.List[object]]::new() }; $byFunction[$r.Function].Add($r) }
    $pathToken = [regex]'[a-z][a-z0-9_]*(?:\[[^\]]*\])?(?:\.[a-z][a-z0-9_]*(?:\[[^\]]*\])?)+'
    $checks = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.psm1' -File) {
        $relative = "scripts/common/arm-deployment/verification/$($file.Name)"
        $ast = Get-MapAst $file.FullName
        $nodes = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -or $a -is [System.Management.Automation.Language.HashtableAst] }, $true))
        foreach ($n in $nodes) {
            $id = $null
            if ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-AzlVerDefinition') {
                for ($i = 0; $i -lt $n.CommandElements.Count - 1; $i++) {
                    $e = $n.CommandElements[$i]
                    if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Id') { $id = Get-ConstantStringValue $n.CommandElements[$i + 1] }
                }
            }
            elseif ($n -is [System.Management.Automation.Language.HashtableAst]) {
                foreach ($kv in $n.KeyValuePairs) { if ($kv.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $kv.Item1.Value -eq 'Id' -and $kv.Item2.Extent.Text -match "^'?\w{2,3}-\d{3}'?$") { $id = (Get-ConstantStringValue $kv.Item2.PipelineElements[0].Expression) } }
            }
            if (-not $id) { continue }
            $scope = $n.Parent; while ($null -ne $scope -and $scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope = $scope.Parent }
            $fname = if ($scope) { $scope.Name } else { '(script)' }
            $keys = [System.Collections.Generic.HashSet[string]]::new(); $via = [System.Collections.Generic.HashSet[string]]::new(); $named = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($r in $Reader) { if ($r.File -eq $relative -and $r.Function -eq $fname -and $r.Line -ge $n.Extent.StartLineNumber -and $r.Line -le $n.Extent.EndLineNumber) { [void]$keys.Add($r.Path) } }
            foreach ($c in $n.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $cn = $c.GetCommandName()
                if ($cn -and $byFunction.ContainsKey($cn) -and $cn -ne $fname) { foreach ($r in $byFunction[$cn]) { [void]$via.Add($r.Path) } }
            }
            foreach ($s in $n.FindAll({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $a -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
                $text = if ($s -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $s.Value } else { $s.Value }
                foreach ($m in $pathToken.Matches($text)) {
                    $t = [regex]::Replace($m.Value, '\[[^\]]*\]', '[]')
                    if ($Index.Paths.Contains($t)) { [void]$named.Add($t) }
                }
            }
            $checks.Add([pscustomobject]@{ Id = $id; File = $relative; Function = $fname; Key = @(Get-MapSortedString -Value @($keys)); Via = @(Get-MapSortedString -Value @($via | Where-Object { -not $keys.Contains($_) })); Named = @(Get-MapSortedString -Value @($named | Where-Object { -not $keys.Contains($_) })) })
        }
    }
    return @(Get-MapOrdered -Item @($checks | Group-Object Id -CaseSensitive | ForEach-Object { $_.Group[0] }) -Key { $args[0].Id })
}

# ---------------------------------------------------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------------------------------------------------

function Get-MapDiscoveryWrite {
    <#
    .SYNOPSIS
        Keys discovery proposes (ConvertTo-AzlDiscoveryProposal in AzlDellRedfish.psm1: the YAML lines it writes) and keys it applies
        (Get-AzlDiscoveryChange in AzlInfrastructureEdit.psm1: the paths in & $add calls). Records: Path, How (proposal or applied).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Index)

    $out = [System.Collections.Generic.List[object]]::new()
    # proposal: string literals that are YAML lines; the indentation gives the nesting
    $ast = Get-MapAst (Join-Path $Root 'scripts/common/idrac-management/AzlDellRedfish.psm1')
    $fn = Get-MapFunctionAst $ast 'ConvertTo-AzlDiscoveryProposal'
    $yamlLines = foreach ($s in $fn.FindAll({ param($a) $a -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or $a -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | Sort-Object { $_.Extent.StartOffset }) {
        if ($s.Value -match '^(?<ind> *)(?<dash>- )?(?<key>[a-z_]+):') { [pscustomobject]@{ Lead = $Matches['ind'].Length; Dash = [bool]$Matches['dash']; Key = $Matches['key'] } }
    }
    # the YAML nesting: a stack of (indent, base path); a dash line opens an item of the list above it
    $stack = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($l in $yamlLines) {
        $column = $l.Lead + $(if ($l.Dash) { 2 } else { 0 })
        $popTo = $(if ($l.Dash) { $l.Lead } else { $column })
        while ($stack.Count -and $stack[$stack.Count - 1].Indent -ge $popTo) { $stack.RemoveAt($stack.Count - 1) }
        $parent = $(if ($stack.Count) { $stack[$stack.Count - 1].Base } else { '' })
        if ($l.Dash) {
            if (-not $parent) { continue }
            $parent = "$parent[]"
            $stack.Add(@{ Indent = $l.Lead; Base = $parent })
        }
        $resolved = Join-MapPath -Index $Index -Base $(if ($parent) { $parent } else { '@' }) -Member $l.Key
        if ($null -eq $resolved) { continue }
        $stack.Add(@{ Indent = $column; Base = $resolved })
        if ($seen.Add($resolved)) { $out.Add([pscustomobject]@{ Path = $resolved; How = 'proposal' }) }
    }
    # lists whose items are objects: the dash key belongs to "nodes[]" etc.
    # applied changes: & $add $name @('serial_number') ...
    $ast2 = Get-MapAst (Join-Path $Root 'scripts/common/infrastructure/AzlInfrastructureEdit.psm1')
    $fn2 = Get-MapFunctionAst $ast2 'Get-AzlDiscoveryChange'
    foreach ($c in $fn2.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.InvocationOperator -eq 'Ampersand' }, $true)) {
        $arrays = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ArrayExpressionAst] })
        if (-not $arrays.Count) { continue }
        $parts = @($arrays[0].FindAll({ param($a) $a -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $a -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) | Sort-Object { $_.Extent.StartOffset } | ForEach-Object { $_.Value })
        $p = 'nodes[]'
        foreach ($part in $parts) {
            if ($part -match '^\[name=') { $p += '[]'; continue }
            $p = if ($p.EndsWith('[]')) { "$p.$part" } else { "$p.$part" }
        }
        $p = $p -replace '\[\]\[\]', '[]'
        $p = $p -replace '^nodes\[\]\.network_adapters\[\]', 'nodes[].network_adapters[]' -replace '\[\]\.\[\]', '[]'
        if ($Index.Paths.Contains($p) -and $seen.Add("applied|$p")) { $out.Add([pscustomobject]@{ Path = $p; How = 'applied' }) }
    }
    return @($out)
}

# ---------------------------------------------------------------------------------------------------------------------
# Sonar
# ---------------------------------------------------------------------------------------------------------------------

function Get-MapSonarKey {
    <#
    .SYNOPSIS
        Path -> Sonar config key, from the mapping that ConvertFrom-AzlSonarInfrastructureTree states in its help
        ("azure.subscription_id -> subscriptionId"). Records: Path, ConfigKey.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SonarRoot, [Parameter(Mandatory)]$Index)

    $file = Join-Path $SonarRoot 'src/AzlSonar/Private/Infrastructure.ps1'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $ast = Get-MapAst $file
    $fn = Get-MapFunctionAst $ast 'ConvertFrom-AzlSonarInfrastructureTree'
    $help = $fn.GetHelpContent()
    $text = (@($help.Description) + @($help.Synopsis)) -join "`n"
    if (-not $text.Trim()) { $text = $fn.Extent.Text }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($text, '(?<p>[a-z_]+(?:\.[a-z_]+|\[\]\.[a-z_]+)+)(?: \([^)]*\))? -> (?<k>[A-Za-z]+(?:\.[A-Za-z]+|\[\]\.[A-Za-z]+)?)')) {
        $p = $m.Groups['p'].Value
        if ($Index.Paths.Contains($p)) { $out.Add([pscustomobject]@{ Path = $p; ConfigKey = $m.Groups['k'].Value }) }
    }
    # nodes[].name -> nodes[].name; the evidence folder
    foreach ($m in [regex]::Matches($text, '(?<p>provisioning\.simplified\.evidence_path)\\(?<f>[A-Za-z\-\.]+)(?: \([^)]*\))? -> (?<k>[A-Za-z]+(?:\.[A-Za-z]+)?)')) {
        $out.Add([pscustomobject]@{ Path = $m.Groups['p'].Value; ConfigKey = "$($m.Groups['k'].Value) (file $($m.Groups['f'].Value))" })
    }
    return @($out)
}

# ---------------------------------------------------------------------------------------------------------------------
# Trailwright
# ---------------------------------------------------------------------------------------------------------------------

function Get-MapTrailwrightQuestion {
    <#
    .SYNOPSIS
        The questions of Trailwright's catalog (apps/trailwright/src/questions/catalog/*.ts): Path, Id, Step, Owner, Kind, Optional, Conditional, File.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TrailwrightRoot)

    $dir = Join-Path $TrailwrightRoot 'apps/trailwright/src/questions/catalog'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.ts' -File | Where-Object Name -ne 'index.ts') {
        $text = [IO.File]::ReadAllText($f.FullName)
        $chunks = [regex]::Split($text, "(?=\bid:\s*')")
        foreach ($c in $chunks) {
            if ($c -notmatch "^id:\s*'(?<id>[^']+)'") { continue }
            $id = $Matches['id']
            if ($c -notmatch "\bpath:\s*'(?<path>[^']+)'") { continue }
            $path = $Matches['path']
            $step = if ($c -match "\bstep:\s*'(?<v>[^']+)'") { $Matches['v'] } else { '' }
            $owner = if ($c -match "\bowner:\s*'(?<v>[^']+)'") { $Matches['v'] } else { '' }
            $kind = if ($c -match "\bkind:\s*'(?<v>[^']+)'") { $Matches['v'] } else { '' }
            $optional = $c -match 'requiredWhen:\s*\(\)\s*=>\s*false'
            $conditional = ($c -match '\bappliesWhen:') -or ($c -match '\brequiredWhen:' -and -not $optional)
            $out.Add([pscustomobject]@{ Path = $path; Id = $id; Step = $step; Owner = $owner; Kind = $kind; Optional = $optional; Conditional = $conditional; File = "apps/trailwright/src/questions/catalog/$($f.Name)" })
        }
    }
    return @($out)
}

Export-ModuleMember -Function Get-MapArmParameter, Get-MapOsStep, Get-MapOsStepFromText, Get-MapGateCheck, Get-MapDiscoveryWrite, Get-MapSonarKey, Get-MapTrailwrightQuestion, Get-MapAst
