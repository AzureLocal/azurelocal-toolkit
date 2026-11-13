#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the infrastructure.yml schema, the per-tool schemas and the templates from the master registry.

.DESCRIPTION
    config/variables/schema/master-registry.yaml is the master. The sections of infrastructure.yml are registered in it
    (explicit "properties:" form, see config/variables/README.md). This module turns them into:

    * Get-ToolCatalog                        the tools of the Azure Local set (registry section _tool_catalog)
    * Get-ToolWithKey                        the ids of the tools that have at least one key (the ones that get a template and a schema)
    * Get-InfrastructureSchemaFromRegistry   the JSON schema of infrastructure.yml (all of it, or one tool's part)
    * Get-ToolPath                           the data paths a tool needs (registry attribute used_by), with their ancestors
    * Get-InfrastructureTemplateText         the master file or a tool template, as YAML with comments and allowed values
    * Select-InfrastructureTool              cuts a real infrastructure.yml down to what one tool reads

    A tool is a program that reads part of the file (or, for Trailwright, writes it). Its id is a value of used_by. The tools are
    listed in the registry section _tool_catalog. A tool template is always a strict subset of the master file.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VariableRegistry.psm1') -Force

$script:SchemaKeywords = 'description', 'type', 'deprecated', 'default', 'const', 'enum', 'pattern', 'minimum', 'maximum',
'exclusiveMinimum', 'exclusiveMaximum', 'minLength', 'maxLength', 'minItems', 'maxItems', 'uniqueItems'

function Copy-Deep($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $c = [ordered]@{}
        foreach ($k in $Value.Keys) { $c[$k] = Copy-Deep $Value[$k] }
        return $c
    }
    if ($Value -is [System.Collections.IList]) {
        $l = [System.Collections.Generic.List[object]]::new()
        foreach ($i in $Value) { $l.Add((Copy-Deep $i)) }
        return , $l
    }
    return $Value
}

function Get-ToolCatalog {
    <#
    .SYNOPSIS
        The tools of the registry's _tool_catalog, in the order of the catalog: id -> entry (title, kind, relation, ...).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Registry)
    if (-not $Registry.Contains('_tool_catalog') -or -not $Registry['_tool_catalog'].Contains('tools')) { throw 'The registry has no _tool_catalog.tools section.' }
    return $Registry['_tool_catalog']['tools']
}

function Assert-ToolId {
    param([System.Collections.IDictionary]$Registry, [string]$Tool)
    $ids = @((Get-ToolCatalog -Registry $Registry).Keys)
    if ($Tool -notin $ids) { throw "Unknown tool '$Tool'. The tools in _tool_catalog are: $($ids -join ', ')." }
}

function Get-ToolWithKey {
    <#
    .SYNOPSIS
        The ids of the tools that read (or write) at least one key of infrastructure.yml besides the file's own _metadata. Only these get a template and a schema.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Registry)
    foreach ($id in (Get-ToolCatalog -Registry $Registry).Keys) {
        $set = Get-ToolPath -Registry $Registry -Tool $id
        $own = @($set | Where-Object { $_ -ne '_metadata' -and $_ -notlike '_metadata.*' })
        if ($own.Count) { $id }
    }
}

function Get-RegistryDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Read-RegistryYaml -Path $Path
}

function Get-SectionName([System.Collections.IDictionary]$Registry, [string]$Key) {
    $e = $Registry[$Key]
    if ($e.Contains('data_path')) { return [string]$e['data_path'] }
    return $Key
}

# The children of a registry entry that belong to infrastructure.yml: the explicit "properties:" block, plus 4.0-form children that carry file_schema.
function Get-FileChild([System.Collections.IDictionary]$Entry) {
    $out = [ordered]@{}
    if ($Entry.Contains('properties') -and $Entry['properties'] -is [System.Collections.IDictionary]) {
        foreach ($k in $Entry['properties'].Keys) { if ($Entry['properties'][$k] -is [System.Collections.IDictionary]) { $out[$k] = $Entry['properties'][$k] } }
    }
    foreach ($k in $Entry.Keys) {
        if ($k -eq 'properties' -or $k -eq 'items' -or $k -eq 'additionalProperties') { continue }
        if ($Entry[$k] -is [System.Collections.IDictionary] -and $Entry[$k].Contains('file_schema') -and -not $out.Contains($k)) { $out[$k] = $Entry[$k] }
    }
    return $out
}

function ConvertTo-PlainJsonValue($Value) {
    if ($Value -is [System.Collections.IList]) { return , @($Value | ForEach-Object { ConvertTo-PlainJsonValue $_ }) }
    return $Value
}

function ConvertTo-SchemaNode {
    param($Entry, [string]$Path, $Defs, $Keep, [bool]$IsItem = $false)
    $out = [ordered]@{}
    $isShared = $Entry.Contains('file_schema')
    if ($isShared) {
        $out = Copy-Deep $Entry['file_schema']
    } else {
        foreach ($k in $script:SchemaKeywords) { if ($Entry.Contains($k)) { $out[$k] = ConvertTo-PlainJsonValue $Entry[$k] } }
        if ($Entry.Contains('format')) { $out['format'] = [string]$Entry['format'] }
        if ($Entry.Contains('additionalProperties') -and $Entry['additionalProperties'] -is [bool]) { $out['additionalProperties'] = $Entry['additionalProperties'] }
        if ($Entry.Contains('schema_extra') -and $Entry['schema_extra'] -is [System.Collections.IDictionary]) {
            foreach ($k in $Entry['schema_extra'].Keys) { $out[$k] = Copy-Deep $Entry['schema_extra'][$k] }
        }
    }

    # children
    $props = [ordered]@{}
    $required = [System.Collections.Generic.List[string]]::new()
    $children = Get-FileChild $Entry
    $prefix = if ($IsItem) { "$Path[]" } else { $Path }
    foreach ($name in $children.Keys) {
        $childPath = "$prefix.$name"
        if ($null -ne $Keep -and -not $Keep.Contains($childPath)) { continue }
        $props[$name] = ConvertTo-SchemaNode -Entry $children[$name] -Path $childPath -Defs $Defs -Keep $Keep
        if (-not $isShared -and $children[$name].Contains('required') -and $children[$name]['required'] -eq $true) { $required.Add($name) }
    }
    if ($props.Keys.Count) { $out['properties'] = $props }
    if ($isShared) {
        if ($out.Contains('required')) {
            $kept = @($out['required'] | Where-Object { $props.Contains($_) })
            if ($kept.Count) { $out['required'] = $kept } else { $out.Remove('required') }
        }
    } elseif ($required.Count) { $out['required'] = $required.ToArray() }

    # items
    if ($Entry.Contains('items') -and $Entry['items'] -is [System.Collections.IDictionary]) {
        $item = $Entry['items']
        if ($item.Contains('properties')) {
            $itemNode = ConvertTo-SchemaNode -Entry $item -Path $Path -Defs $Defs -Keep $Keep -IsItem $true
            if (-not $itemNode.Contains('type') -and -not $itemNode.Contains('$ref')) { $itemNode = [ordered]@{ type = 'object' } + $itemNode }
            $out['items'] = $itemNode
        } else {
            $node = [ordered]@{}
            foreach ($k in $item.Keys) { $node[$k] = Copy-Deep $item[$k] }
            $out['items'] = Resolve-FormatRef $node $Defs
        }
    }
    # a map of free keys
    if (-not $isShared -and $Entry.Contains('additionalProperties') -and $Entry['additionalProperties'] -is [System.Collections.IDictionary]) {
        $out['additionalProperties'] = ConvertTo-SchemaNode -Entry $Entry['additionalProperties'] -Path "$Path.*" -Defs $Defs -Keep $Keep
    }

    return Resolve-FormatRef $out $Defs
}

# JSON with sorted object keys (and sorted "required" lists), to compare two schema fragments regardless of key order.
function Get-CanonicalJson($Value, [string]$Key = '') {
    function Canon($v, $k) {
        if ($v -is [System.Collections.IDictionary]) { $r = [ordered]@{}; foreach ($n in ($v.Keys | Sort-Object { [string]$_ })) { $r[$n] = Canon $v[$n] $n }; return $r }
        if ($v -is [System.Collections.IList]) { $items = @($v | ForEach-Object { Canon $_ '' }); if ($k -eq 'required') { $items = @($items | Sort-Object) }; return , $items }
        return $v
    }
    return ConvertTo-Json -InputObject (Canon $Value $Key) -Compress -Depth 60
}
# format: <name> where <name> is a named type of _schema_defs becomes "$ref"; what the type already says is not repeated.
function Resolve-FormatRef($Node, $Defs) {
    if ($Node -isnot [System.Collections.IDictionary] -or -not $Node.Contains('format')) { return $Node }
    $name = [string]$Node['format']
    if (-not $Defs.Contains($name)) { return $Node }
    $def = $Defs[$name]
    $result = [ordered]@{ '$ref' = "#/`$defs/$name" }
    foreach ($k in $Node.Keys) {
        if ($k -eq 'format') { continue }
        if ($def.Contains($k) -and ((Get-CanonicalJson $def[$k] $k) -ceq (Get-CanonicalJson $Node[$k] $k))) { continue }
        if ($k -eq 'type' -and $Node[$k] -eq 'object' -and -not $def.Contains('type')) { continue }
        $result[$k] = $Node[$k]
    }
    return $result
}

# Removes required, anyOf, oneOf, allOf, if/then/else, not, contains and dependentRequired, at every depth.
function Select-WithoutCompletenessKeyword($Node) {
    $drop = 'required', 'anyOf', 'oneOf', 'allOf', 'if', 'then', 'else', 'not', 'contains', 'minContains', 'maxContains', 'dependentRequired'
    if ($Node -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $Node.Keys) {
            # inside "properties" and "$defs" the keys are names, not keywords
            if ($drop -contains $k) { continue }
            $v = $Node[$k]
            if (($k -eq 'properties' -or $k -eq '$defs') -and $v -is [System.Collections.IDictionary]) {
                $named = [ordered]@{}
                foreach ($n in $v.Keys) { $named[$n] = Select-WithoutCompletenessKeyword $v[$n] }
                $out[$k] = $named
            } else { $out[$k] = Select-WithoutCompletenessKeyword $v }
        }
        return $out
    }
    if ($Node -is [System.Collections.IList]) { return , @($Node | ForEach-Object { Select-WithoutCompletenessKeyword $_ }) }
    return $Node
}
function Get-InfrastructureSchemaFromRegistry {
    <#
    .SYNOPSIS
        The JSON schema of infrastructure.yml, built from the registry. With -Tool: only the keys that tool reads (or writes), no scenario rules.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Registry, [string]$Tool)

    $rootInfo = $Registry['_schema_root']
    $defs = $Registry['_schema_defs']
    $keep = if ($Tool) { Get-ToolPath -Registry $Registry -Tool $Tool } else { $null }

    $schema = [ordered]@{}
    foreach ($k in $rootInfo.Keys) { if ($k -ne 'sections') { $schema[$k] = Copy-Deep $rootInfo[$k] } }
    if ($Tool) {
        $verb = if ((Get-ToolCatalog -Registry $Registry)[$Tool]['relation'] -eq 'writes') { 'writes' } else { 'reads' }
        $schema['$id'] = ([string]$schema['$id']) -replace 'infrastructure\.schema\.json$', "infrastructure.$($Tool -replace '_', '-').schema.json"
        $schema['title'] = "$($schema['title']) ($Tool)"
        $schema['description'] = "The part of infrastructure.yml that the tool '$Tool' $verb. Generated from master-registry.yaml; every key is also in the full schema."
    }
    $props = [ordered]@{}
    foreach ($section in $rootInfo['sections']) {
        $name = Get-SectionName $Registry $section
        if ($null -ne $keep -and -not $keep.Contains($name)) { continue }
        $props[$name] = ConvertTo-SchemaNode -Entry $Registry[$section] -Path $name -Defs $defs -Keep $keep
    }
    $schema['properties'] = $props
    if (-not $Tool) {
        $schema['$defs'] = Copy-Deep $defs
        $rules = $Registry['_schema_rules']
        if ($rules -and $rules.Contains('allOf')) { $schema['allOf'] = Copy-Deep $rules['allOf'] }
    } else {
        $schema['$defs'] = Copy-Deep $defs
        # A tool schema checks the shape and the values of the keys the tool reads, not that the whole file is complete: the
        # completeness rules (required keys, alternatives, conditions) belong to the full schema and the rules of Test-InfrastructureFile.
        $schema = Select-WithoutCompletenessKeyword $schema
    }
    return $schema
}

function Get-ToolPath {
    <#
    .SYNOPSIS
        The set of data paths (nodes[].name) a tool reads: every variable with the tool in used_by, their ancestors, and the file's _metadata.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Registry, [Parameter(Mandatory)][string]$Tool)
    Assert-ToolId -Registry $Registry -Tool $Tool
    $set = [System.Collections.Generic.HashSet[string]]::new()
    $wanted = $Tool

    function Visit($Entry, [string]$Path, [bool]$IsItem) {
        $prefix = if ($IsItem) { "$Path[]" } else { $Path }
        $any = $false
        $children = Get-FileChild $Entry
        foreach ($name in $children.Keys) { if (Visit $children[$name] "$prefix.$name" $false) { $any = $true } }
        if ($Entry.Contains('items') -and $Entry['items'] -is [System.Collections.IDictionary] -and $Entry['items'].Contains('properties')) {
            $item = $Entry['items']
            foreach ($name in (Get-FileChild $item).Keys) { if (Visit (Get-FileChild $item)[$name] "$Path[].$name" $false) { $any = $true } }
        }
        $own = $Entry.Contains('used_by') -and (@($Entry['used_by']) -contains $wanted)
        if ($own -or $any) { [void]$set.Add($Path); return $true }
        return $false
    }
    foreach ($section in $Registry['_schema_root']['sections']) {
        $name = Get-SectionName $Registry $section
        if ($section -eq 'file_metadata') {
            [void]$set.Add($name)
            foreach ($child in (Get-FileChild $Registry[$section]).Keys) { [void]$set.Add("$name.$child") }
            continue
        }
        [void](Visit $Registry[$section] $name $false)
    }
    return , $set
}

# ---------------------------------------------------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-YamlScalar($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [string]) { return ConvertTo-Json -InputObject $Value -Compress }
    if ($Value -is [System.Collections.IList]) { return '[' + ((@($Value) | ForEach-Object { ConvertTo-YamlScalar $_ }) -join ', ') + ']' }
    return [string]$Value
}

function Get-FirstSentence([string]$Text, [int]$Max = 140) {
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    $m = [regex]::Match($t, '^.+?[.!?](?=\s+[A-Z(`]|$)')
    $s = if ($m.Success) { $m.Value } else { $t }
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 1).TrimEnd() + '...' }
    return $s
}

# applies_when "scenario.a is x or y and scenario.b is z" -> @(@{Key='a'; Values=@('x','y')}, ...)
function ConvertFrom-AppliesWhen([string]$Text) {
    $clauses = @()
    if (-not $Text) { return $clauses }
    foreach ($part in ($Text -split ' and ')) {
        if ($part -match '^scenario\.(?<k>\w+) is (?<v>.+)$') { $clauses += [pscustomobject]@{ Key = $Matches['k']; Values = @($Matches['v'] -split ' or ' | ForEach-Object { $_.Trim() }) } }
    }
    return $clauses
}

function Test-ScenarioMatch($Clauses, [hashtable]$Scenario) {
    foreach ($c in $Clauses) { if ($Scenario.ContainsKey($c.Key) -and $c.Values -notcontains $Scenario[$c.Key]) { return $false } }
    return $true
}

function Get-PlaceholderValue($Entry, [string]$Name, [string]$Tool = '') {
    if ($Tool -eq 'ztp' -and $Name -eq 'scope' -and $Entry.Contains('enum') -and @($Entry['enum']) -contains 'ztp') { return 'ztp' }
    if ($Entry.Contains('enum') -and $Entry.Contains('default')) { return $Entry['default'] }
    if ($Entry.Contains('example')) { return $Entry['example'] }
    if ($Entry.Contains('default')) { return $Entry['default'] }
    if ($Entry.Contains('const')) { return $Entry['const'] }
    if ($Entry.Contains('enum') -and @($Entry['enum']).Count) { return @($Entry['enum'])[0] }
    $f = if ($Entry.Contains('format')) { [string]$Entry['format'] } else { '' }
    switch ($f) {
        'kv_ref' { return "keyvault://kv-example-01/$($Name -replace '_', '-')" }
        'ipv4' { return '192.0.2.10' }
        'cidr' { return '192.0.2.0/24' }
        'mac' { return '00:00:5E:00:53:01' }
        'guid' { return '00000000-0000-0000-0000-000000000000' }
    }
    $min = if ($Entry.Contains('minimum')) { $Entry['minimum'] } else { 0 }
    switch ([string]$(if ($Entry.Contains('type')) { $Entry['type'] } else { '' })) {
        'integer' { return $min }
        'number' { return $min }
        'boolean' { return $false }
        'array' { return , @() }
        default { if ($Entry.Contains('minLength') -and -not $Entry.Contains('pattern')) { return 'example' } else { return '' } }
    }
}

function Get-InfrastructureTemplateText {
    <#
    .SYNOPSIS
        The master infrastructure.yml (every variable) or a tool template (only what the tool reads, or writes), as YAML with comments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Registry,
        [string]$Tool,
        [hashtable]$Scenario = @{},
        [string]$Title = 'infrastructure.yml'
    )
    $keep = if ($Tool) { Get-ToolPath -Registry $Registry -Tool $Tool } else { $null }
    $lines = [System.Collections.Generic.List[string]]::new()
    $version = ($Registry['_metadata']['infrastructure_schema_version'])

    function Add-CommentLine($Entry, [string]$Ind, $Clauses, [bool]$Req) {
        $eff = if ($Entry.Contains('file_schema')) { $Entry['file_schema'] } else { $Entry }
        $desc = Get-FirstSentence ([string]$(if ($eff.Contains('description')) { $eff['description'] } else { '' }))
        $desc = $desc -replace '^Schema (\d+\.\d+(\.\d+)?)\.\s*', '(since $1) '
        if ($desc) { $lines.Add("$Ind# $desc") }
        $notes = @()
        if ($Req) { $notes += 'required' }
        if ($Entry.Contains('applies_when')) { $notes += "when $($Entry['applies_when'])" }
        if ($Entry.Contains('enum') -and @($Entry['enum']).Count) { $notes += 'one of: ' + ((@($Entry['enum']) | ForEach-Object { [string]$_ }) -join ' | ') }
        if ($Entry.Contains('default')) { $notes += "default: $(ConvertTo-YamlScalar $Entry['default'])" }
        if ($Entry.Contains('used_by')) { $notes += 'used by: ' + (@($Entry['used_by']) -join ', ') }
        if ($notes.Count) { $lines.Add("$Ind# " + ($notes -join '; ')) }
    }

    function Add-MemberNode($Entry, [string]$Path, [int]$Depth, $Clauses, [bool]$IsItem, [bool]$AsListItem) {
        $prefix = if ($IsItem) { "$Path[]" } else { $Path }
        $children = Get-FileChild $Entry
        $sharedReq = if ($Entry.Contains('file_schema') -and $Entry['file_schema'].Contains('required')) { @($Entry['file_schema']['required']) } else { $null }
        foreach ($name in $children.Keys) {
            $childPath = "$prefix.$name"
            if ($null -ne $keep -and -not $keep.Contains($childPath)) { continue }
            $child = $children[$name]
            $childClauses = @($Clauses) + @(ConvertFrom-AppliesWhen ([string]$(if ($child.Contains('applies_when')) { $child['applies_when'] } else { '' })))
            if (-not (Test-ScenarioMatch $childClauses $Scenario)) { continue }
            $req = if ($null -ne $sharedReq) { $sharedReq -contains $name } else { $child.Contains('required') -and $child['required'] -eq $true }
            Add-Node $child $childPath $name $Depth $childClauses $req
        }
    }

    function Add-Node($Entry, [string]$Path, [string]$Name, [int]$Depth, $Clauses, [bool]$Req) {
        $ind = '  ' * $Depth
        $key = if ($Name -match '^[A-Za-z_][A-Za-z0-9_\-]*$') { $Name } else { ConvertTo-Json -InputObject $Name -Compress }
        Add-CommentLine $Entry $ind $Clauses $Req
        $hasItems = $Entry.Contains('items') -and $Entry['items'] -is [System.Collections.IDictionary]
        $kids = Get-FileChild $Entry
        if ($hasItems -and $Entry['items'].Contains('properties')) {
            $lines.Add("${ind}${key}:")
            $start = $lines.Count
            $itemEntry = $Entry['items']
            Add-MemberNode $itemEntry $Path ($Depth + 2) $Clauses $true $true
            # the first line of the item starts the list element
            if ($lines.Count -gt $start) {
                $i = $start
                while ($i -lt $lines.Count -and $lines[$i].TrimStart().StartsWith('#')) { $i++ }
                if ($i -lt $lines.Count) {
                    $lines[$i] = ('  ' * $Depth) + '  - ' + $lines[$i].TrimStart()
                    # keep comments above the dash at the item's indent
                    for ($j = $start; $j -lt $i; $j++) { $lines[$j] = ('  ' * $Depth) + '  ' + $lines[$j].TrimStart() }
                } else { $lines.Add(('  ' * $Depth) + '  - {}') }
            } else { $lines[$lines.Count - 1] = "${ind}${key}: []" }
            return
        }
        if ($kids.Keys.Count -gt 0 -or ($Entry.Contains('type') -and $Entry['type'] -eq 'object' -and $Entry.Contains('properties'))) {
            $lines.Add("${ind}${key}:")
            $before = $lines.Count
            Add-MemberNode $Entry $Path ($Depth + 1) $Clauses $false $false
            if ($lines.Count -eq $before) { $lines[$lines.Count - 1] = "${ind}${key}: {}" }
            return
        }
        $eff = if ($Entry.Contains('file_schema')) { $Entry['file_schema'] } else { $Entry }
        if ($eff.Contains('additionalProperties') -and $eff['additionalProperties'] -is [System.Collections.IDictionary] -and $eff.Contains('type') -and $eff['type'] -eq 'object') {
            $lines.Add("${ind}${key}:")
            $v = Get-PlaceholderValue $eff['additionalProperties'] 'name'
            if ($v -is [string] -and -not $v) { $v = 'value' }
            $lines.Add("${ind}  example_name: $(ConvertTo-YamlScalar $v)")
            return
        }
        $value = Get-PlaceholderValue $Entry $Name $Tool
        if ($Entry.Contains('type') -and $Entry['type'] -eq 'object') { $lines.Add("${ind}${key}: {}"); return }
        $lines.Add("${ind}${key}: $(ConvertTo-YamlScalar $value)")
    }

    $lines.Add("# GENERATED from config/variables/schema/master-registry.yaml by config/variables/scripts/New-InfrastructureArtifacts.ps1. Do not edit.")
    $lines.Add("# Change the registry, then run the generator. A test regenerates this file and fails when it differs.")
    $what = if ($Tool) {
        $catalogEntry = (Get-ToolCatalog -Registry $Registry)[$Tool]
        $verb = if ($catalogEntry['relation'] -eq 'writes') { 'writes' } else { 'reads' }
        "the part of $Title that $($catalogEntry['title']) ('$Tool') $verb (a strict subset of the master file)"
    } else { "$Title with every variable" }
    $sc = if ($Scenario.Count) { ' Scenario: ' + (($Scenario.Keys | Sort-Object | ForEach-Object { "$_=$($Scenario[$_])" }) -join ', ') + '.' } else { '' }
    $lines.Add("# Template for $what. Schema $version.$sc")
    $lines.Add('# Values are placeholders (RFC 5737 addresses, keyvault:// references). Secrets are never values.')
    $lines.Add('')
    foreach ($section in $Registry['_schema_root']['sections']) {
        $name = Get-SectionName $Registry $section
        if ($null -ne $keep -and -not $keep.Contains($name)) { continue }
        $entry = $Registry[$section]
        $clauses = @(ConvertFrom-AppliesWhen ([string]$(if ($entry.Contains('applies_when')) { $entry['applies_when'] } else { '' })))
        if (-not (Test-ScenarioMatch $clauses $Scenario)) { continue }
        Add-Node $entry $name $name 0 $clauses $false
        $lines.Add('')
    }
    # _metadata.schema_version carries the version
    $text = ($lines -join "`n").TrimEnd("`n") + "`n"
    return $text
}

function Select-InfrastructureTool {
    <#
    .SYNOPSIS
        Cuts a loaded infrastructure.yml (ordered dictionary) down to the keys one tool reads. Nothing is added or changed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Registry, [Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Tool)
    $keep = Get-ToolPath -Registry $Registry -Tool $Tool

    function Cut($Node, [string]$Path) {
        if ($Node -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($k in $Node.Keys) {
                $p = if ($Path) { "$Path.$k" } else { [string]$k }
                if ($keep.Contains($p)) { $out[$k] = Cut $Node[$k] $p }
                elseif ($keep.Contains($Path) -and $Path -in $script:MapPaths) { $out[$k] = $Node[$k] }
            }
            return $out
        }
        if ($Node -is [System.Collections.IList]) {
            $out = [System.Collections.Generic.List[object]]::new()
            foreach ($i in $Node) { $out.Add((Cut $i "$Path[]")) }
            return , $out
        }
        return $Node
    }
    $script:MapPaths = @('tags')
    return Cut $Document ''
}

Export-ModuleMember -Function Get-RegistryDocument, Get-ToolCatalog, Get-ToolWithKey, Get-InfrastructureSchemaFromRegistry, Get-ToolPath, Get-InfrastructureTemplateText, Select-InfrastructureTool
