#Requires -Version 7.0
<#
.SYNOPSIS
    Reads the master variable registry (config/variables/schema/master-registry.yaml) and the infrastructure.yml
    JSON schema as flat lists of variable paths, so the two can be compared and kept in step.

.DESCRIPTION
    The registry is the master of every variable. This module is the one reader of its structure:

    * Read-RegistryYaml            parses the registry (duplicate keys are tolerated, the last one wins, as in PyYAML;
                                   YamlDotNet's mapping loader refuses them, so the parser events are walked directly).
    * Get-RegistryVariable         one record per variable path ("nodes[].name", "identity.local_admin.username").
    * Get-InfrastructureSchemaVariable   one record per key of infrastructure.schema.json, same path shape.
    * Compare-RegistryToSchema     the keys the schema has and the registry lacks, and the keys that disagree.

    Path shape: "." between keys, "[]" for a list item, ".*" for a map of free keys (additionalProperties).

    Registry node conventions the walker understands (the original ones, plus the explicit form):

    * a node with children written directly under it (the 4.0 form):  ad_domain_fqdn: { type: string, ... }
    * a node with "properties:" (the explicit form, needed when a variable is named type, name, default, ...)
    * a list:  type: array, items: { type: object, properties: { ... } }
    * a map of free keys:  additionalProperties: { ... }
    * "alias_for:" marks a name kept for compatibility; it is not a second variable.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop

# Keywords that describe a node. Anything else under a node (not starting with "_") is a child variable.
$script:NodeKeywords = @(
    'type', 'description', 'required', 'format', 'pattern', 'minimum', 'maximum', 'default', 'example', 'examples', 'note',
    'enum', 'allowedValues', 'minItems', 'maxItems', 'minLength', 'maxLength', 'sensitive', 'category', 'subcategory',
    'infrastructure_type', 'depends_on', 'solutions', 'tier', 'items', 'properties', 'additionalProperties', 'conflicts_with',
    'estimated_variables', 'shared_groups', 'variable_groups', 'alias_for', 'since', 'deprecated', 'replaced_by', 'used_by',
    'scenarios', 'const', 'infrastructure_types',
    'schema_extra', 'applies_when', 'data_path', 'required_in', 'uniqueItems', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf'
)

function ConvertTo-PlainScalar([string]$Value, [bool]$Quoted) {
    if ($Quoted) { return $Value }
    switch -Regex ($Value) {
        '^(true|True|TRUE)$' { return $true }
        '^(false|False|FALSE)$' { return $false }
        '^(null|Null|NULL|~)?$' { return $null }
        '^-?\d+$' { return [long]$Value }
        '^-?\d+\.\d+$' { return [double]::Parse($Value, [cultureinfo]::InvariantCulture) }
        default { return $Value }
    }
}

function Read-RegistryYaml {
    <#
    .SYNOPSIS
        Parses a YAML file into ordered dictionaries, lists and scalars; a repeated key keeps its last value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $parser = [YamlDotNet.Core.Parser]::new([System.IO.StringReader]::new($text))
    $null = $parser.MoveNext()   # StreamStart
    $null = $parser.MoveNext()   # DocumentStart

    function Read-Node($Parser) {
        $current = $Parser.Current
        if ($current -is [YamlDotNet.Core.Events.Scalar]) {
            $null = $Parser.MoveNext()
            $quoted = $current.Style -ne [YamlDotNet.Core.ScalarStyle]::Plain
            return , (ConvertTo-PlainScalar $current.Value $quoted)
        }
        if ($current -is [YamlDotNet.Core.Events.MappingStart]) {
            $null = $Parser.MoveNext()
            $map = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
            while ($Parser.Current -isnot [YamlDotNet.Core.Events.MappingEnd]) {
                $key = [string]$Parser.Current.Value
                $null = $Parser.MoveNext()
                $map[$key] = Read-Node $Parser
            }
            $null = $Parser.MoveNext()
            return $map
        }
        if ($current -is [YamlDotNet.Core.Events.SequenceStart]) {
            $null = $Parser.MoveNext()
            $list = [System.Collections.Generic.List[object]]::new()
            while ($Parser.Current -isnot [YamlDotNet.Core.Events.SequenceEnd]) { $list.Add((Read-Node $Parser)) }
            $null = $Parser.MoveNext()
            return , $list
        }
        throw "Unexpected YAML event $($current.GetType().Name)"
    }

    $null = $parser.MoveNext()
    return Read-Node $parser
}

function Get-RegistryChild([System.Collections.IDictionary]$Node) {
    # Children written directly under the node (the 4.0 form) and, as well, those under "properties:" (the explicit form).
    $direct = $Node.GetEnumerator() | Where-Object {
        $_.Key -notlike '_*' -and $script:NodeKeywords -notcontains $_.Key -and $_.Value -is [System.Collections.IDictionary]
    }
    $explicit = if ($Node.Contains('properties') -and $Node['properties'] -is [System.Collections.IDictionary]) {
        $Node['properties'].GetEnumerator() | Where-Object { $_.Value -is [System.Collections.IDictionary] }
    }
    return @($direct) + @($explicit)
}

function Get-RegistryVariable {
    <#
    .SYNOPSIS
        One record per variable path in the registry: Path, Type, Format, Enum, Default, Required, Since, Deprecated, AliasFor, UsedBy, Node.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [object]$Registry)

    if (-not $Registry) { $Registry = Read-RegistryYaml -Path $Path }
    $records = [System.Collections.Generic.List[object]]::new()

    function Add-Node([System.Collections.IDictionary]$Node, [string]$VarPath) {
        $get = { param($k) if ($Node.Contains($k)) { $Node[$k] } else { $null } }
        $enum = & $get 'enum'
        if ($null -eq $enum) { $enum = & $get 'allowedValues' }
        if ($null -eq $enum -and $Node.Contains('items') -and $Node['items'] -is [System.Collections.IDictionary] -and $Node['items'].Contains('enum')) { $enum = $Node['items']['enum'] }
        $constraints = (@('pattern', 'minimum', 'maximum', 'minLength', 'maxLength', 'minItems', 'maxItems') | Where-Object { $Node.Contains($_) } | ForEach-Object { "$_=$($Node[$_])" }) -join ';'
        $records.Add([pscustomobject]@{
                Path       = $VarPath
                Constraints = $constraints
                Shape      = $(if (($Node.Contains('items')) -or ($Node.Contains('type') -and $Node['type'] -eq 'array')) { 'array' } elseif ($Node.Contains('type') -and $Node['type'] -eq 'object') { 'object' } elseif (@(Get-RegistryChild $Node).Count -gt 0 -or $Node.Contains('additionalProperties')) { 'object' } else { 'scalar' })
                Type       = & $get 'type'
                Format     = & $get 'format'
                Enum       = $(if ($null -ne $enum) { @($enum) -join '|' } else { '' })
                Default    = & $get 'default'
                HasDefault = $Node.Contains('default')
                Required   = & $get 'required'
                Since      = & $get 'since'
                Deprecated = & $get 'deprecated'
                AliasFor   = & $get 'alias_for'
                UsedBy     = $(if ($Node.Contains('used_by')) { @($Node['used_by']) -join '|' } else { '' })
                Node       = $Node
            })
        # A list: its item is "path[]"
        if ($Node.Contains('items') -and $Node['items'] -is [System.Collections.IDictionary]) {
            $item = $Node['items']
            foreach ($child in Get-RegistryChild $item) { Add-Node $child.Value "$VarPath[].$($child.Key)" }
        }
        if ($Node.Contains('additionalProperties') -and $Node['additionalProperties'] -is [System.Collections.IDictionary]) {
            Add-Node $Node['additionalProperties'] "$VarPath.*"
        }
        foreach ($child in Get-RegistryChild $Node) { Add-Node $child.Value "$VarPath.$($child.Key)" }
    }

    foreach ($top in $Registry.GetEnumerator()) {
        if ($top.Key -like '_*' -or $top.Value -isnot [System.Collections.IDictionary]) { continue }
        $root = if ($top.Value.Contains('data_path')) { [string]$top.Value['data_path'] } else { [string]$top.Key }
        Add-Node $top.Value $root
    }
    return $records
}

function Get-InfrastructureSchemaVariable {
    <#
    .SYNOPSIS
        One record per key of infrastructure.schema.json (all of 5.x): Path, Type, Format, Enum, Default, Required, Since, Deprecated, Description.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SchemaPath)

    $schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json -AsHashtable
    $defs = $schema['$defs']
    $records = [System.Collections.Generic.List[object]]::new()

    function Resolve-SchemaNode($Node) {
        $ref = $null
        while ($Node -is [System.Collections.IDictionary] -and $Node.Contains('$ref')) {
            $ref = ([string]$Node['$ref']) -replace '^#/\$defs/', ''
            $merged = [ordered]@{}
            foreach ($k in $defs[$ref].Keys) { $merged[$k] = $defs[$ref][$k] }
            foreach ($k in $Node.Keys) { if ($k -ne '$ref') { $merged[$k] = $Node[$k] } }
            $Node = $merged
        }
        [pscustomobject]@{ Node = $Node; Ref = $ref }
    }

    function Add-Schema($Resolved, [string]$VarPath, [bool]$IsRequired) {
        $n = $Resolved.Node
        if ($n -isnot [System.Collections.IDictionary]) { return }
        $desc = [string]$(if ($n.Contains('description')) { $n['description'] } else { '' })
        $since = if ($desc -match '^Schema (5\.\d+(?:\.\d+)?)\.') { $Matches[1] } else { '' }
        $enum = if ($n.Contains('enum')) { @($n['enum']) -join '|' } else { '' }
        $itemEnum = ''
        if ($n['type'] -eq 'array' -and $n.Contains('items') -and $n['items'] -is [System.Collections.IDictionary]) {
            $ri = Resolve-SchemaNode $n['items']
            if ($ri.Node.Contains('enum')) { $itemEnum = @($ri.Node['enum']) -join '|' }
        }
        if ($VarPath) {
            $records.Add([pscustomobject]@{
                    Path        = $VarPath
                    Type        = $(if ($n.Contains('type')) { [string]$n['type'] } elseif ($n.Contains('const')) { 'const' } else { '' })
                    Format      = [string]$Resolved.Ref
                    Enum        = $enum
                    ItemEnum    = $itemEnum
                    Constraints = (@('pattern', 'minimum', 'maximum', 'minLength', 'maxLength', 'minItems', 'maxItems') | Where-Object { $n.Contains($_) } | ForEach-Object { "$_=$($n[$_])" }) -join ';'
                    Shape       = $(if ($n['type'] -eq 'array') { 'array' } elseif ($n['type'] -eq 'object' -or $n.Contains('properties') -or $n.Contains('additionalProperties')) { 'object' } else { 'scalar' })
                    Default    = $(if ($n.Contains('default')) { $n['default'] } else { $null })
                    HasDefault  = $n.Contains('default')
                    Required    = $IsRequired
                    Since       = $since
                    Deprecated  = ($n.Contains('deprecated') -and $n['deprecated'] -eq $true)
                    Description = $desc
                    Node        = $n
                })
        }
        if ($n.Contains('properties') -and $n['properties'] -is [System.Collections.IDictionary]) {
            $req = @($(if ($n.Contains('required')) { $n['required'] }))
            foreach ($k in $n['properties'].Keys) {
                Add-Schema (Resolve-SchemaNode $n['properties'][$k]) $(if ($VarPath) { "$VarPath.$k" } else { [string]$k }) ($req -contains $k)
            }
        }
        elseif ($n['type'] -eq 'array' -and $n.Contains('items') -and $n['items'] -is [System.Collections.IDictionary]) {
            $ri = Resolve-SchemaNode $n['items']
            if ($ri.Node.Contains('properties')) { Add-Schema $ri "$VarPath[]" $false | Out-Null }
        }
        elseif ($n['type'] -eq 'object' -and $n.Contains('additionalProperties') -and $n['additionalProperties'] -is [System.Collections.IDictionary]) {
            Add-Schema (Resolve-SchemaNode $n['additionalProperties']) "$VarPath.*" $false
        }
    }

    Add-Schema ([pscustomobject]@{ Node = $schema; Ref = $null }) '' $false
    # An item path "x[]" duplicates its list "x"; keep only the members "x[].name".
    return @($records | Where-Object { $_.Path -notmatch '\[\]$' })
}

function Compare-RegistryToSchema {
    <#
    .SYNOPSIS
        Missing: schema keys with no registry entry. Conflict: keys both have that differ in type, enum or default.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Registry, [Parameter(Mandatory)][object[]]$Schema)

    $byPath = @{}
    foreach ($r in $Registry) { $byPath[$r.Path] = $r }
    $missing = [System.Collections.Generic.List[object]]::new()
    $conflict = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $Schema) {
        if (-not $byPath.ContainsKey($s.Path)) { $missing.Add($s); continue }
        $r = $byPath[$s.Path]
        $problems = @()
        $sType = [string]$s.Type; $rType = [string]$r.Type
        if ($sType -and $rType -and $sType -ne $rType) { $problems += "type: registry $rType, schema $sType" }
        if ($s.Shape -ne 'scalar' -and $r.Shape -eq 'scalar' -or $s.Shape -eq 'scalar' -and $r.Shape -ne 'scalar' -or ($s.Shape -eq 'array' -and $r.Shape -eq 'object') -or ($s.Shape -eq 'object' -and $r.Shape -eq 'array')) { $problems += "shape: registry $($r.Shape), schema $($s.Shape)" }
        if ($s.Constraints -and @($s.Constraints -split ';' | Where-Object { ($r.Constraints -split ';') -notcontains $_ }).Count) { $problems += "constraints: registry [$($r.Constraints)], schema [$($s.Constraints)]" }
        $sEnum = if ($s.Enum) { $s.Enum } else { $s.ItemEnum }
        if ($sEnum -and $r.Enum -and $sEnum -ne $r.Enum) { $problems += "enum: registry $($r.Enum), schema $sEnum" }
        elseif ($sEnum -and -not $r.Enum) { $problems += "enum: registry has none, schema $sEnum" }
        if ($s.HasDefault -and $r.HasDefault -and "$($s.Default)".ToLowerInvariant() -ne "$($r.Default)".ToLowerInvariant()) { $problems += "default: registry $($r.Default), schema $($s.Default)" }
        elseif ($s.HasDefault -and -not $r.HasDefault) { $problems += "default: registry has none, schema $($s.Default)" }
        if ($problems.Count) { $conflict.Add([pscustomobject]@{ Path = $s.Path; Problems = ($problems -join '; ') }) }
    }
    [pscustomobject]@{ Missing = $missing; Conflict = $conflict }
}

Export-ModuleMember -Function Read-RegistryYaml, Get-RegistryVariable, Get-InfrastructureSchemaVariable, Compare-RegistryToSchema
