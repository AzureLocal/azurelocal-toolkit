#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the variable map (VARIABLE-MAP.md and variable-map.csv) from the master registry and a scan of the code.

.DESCRIPTION
    Nothing here is hand-maintained data. The map is the registry (what a variable is, its purposes, its status) joined with what the code does
    with it:

      registry               config/variables/schema/master-registry.yaml, through VariableRegistry.psm1 (the one reader of its structure)
      infrastructure.yml     config/variables/schema/infrastructure.schema.json (which registry variables are keys of the file)
      toolkit code           VariableMapScanner.psm1 parses scripts/**/*.ps1 and *.psm1: who reads which key (file, function)
      ZTP, Sonar, Trailwright  the same scan of their checkouts, plus Trailwright's question catalog and Sonar's key mapping. They are
                             separate repositories, so the result is committed as reports/variable-map-external-readers.csv and used as it is
                             unless -RescanExternal is given (New-VariableMap.ps1). A test can compare the snapshot to the checkouts.
      downstream             VariableMapSources.psm1: ARM template parameter names (New-AzlArmParameterSet), the OS configuration step that
                             applies a key (Compare-AzlNodeState and Get-AzlNodeSpec), pre-cluster verification check ids, what discovery
                             proposes or applies, Sonar's configuration key, Trailwright's question.

    Get-VariableMapOutput returns the three files' text. New-VariableMap.ps1 writes them or, with -Check, compares them.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VariableRegistry.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VariableMapScanner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VariableMapSources.psm1') -Force


# Tool ids, the phase each belongs to, in flow order. A tool id is what the scan reports as the reader.
$script:PhaseOrder = [ordered]@{
    'Design'                   = @('trailwright')
    'Discovery'                = @('discovery')
    'ZTP'                      = @('ztp')
    'OS configuration'         = @('os-configuration')
    'Pre-cluster verification' = @('pre-cluster-verification')
    'ARM Validate/Deploy'      = @('arm-deployment')
    'Sonar'                    = @('sonar')
    'Outside the flow'         = @('cicd-infra', 'infrastructure-helpers', 'validator', 'toolkit-legacy-scripts')
}
$script:ToolPhase = @{}
foreach ($p in $script:PhaseOrder.Keys) { foreach ($t in $script:PhaseOrder[$p]) { $script:ToolPhase[$t] = $p } }

$script:ToolOwner = @{ 'os_configuration' = 'os-configuration'; 'arm_deployment' = 'arm-deployment'; 'ztp' = 'ztp'; 'sonar' = 'sonar'; 'discovery' = 'discovery'; 'cicd_infra' = 'cicd-infra' }

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function Format-MapValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [System.Collections.IDictionary]) { return '{...}' }
    if ($Value -is [System.Collections.IList]) { return '[' + ((@($Value) | ForEach-Object { Format-MapValue $_ }) -join ', ') + ']' }
    return [string]$Value
}

function Get-MapFirstSentence {
    param([string]$Text, [int]$Max = 160)
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    $t = $t -replace '^Schema \d+\.\d+(\.\d+)?\.\s*', ''
    $m = [regex]::Match($t, '^.+?[.!?](?=\s+[A-Z(`]|$)')
    $s = if ($m.Success) { $m.Value } else { $t }
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 1).TrimEnd() + '...' }
    return $s
}

function ConvertTo-MapCell {
    param([string]$Text)
    return (($Text -replace '\|', '\|') -replace '\s*[\r\n]+\s*', ' ')
}

function Hide-MapGuid {
    # The map carries no identifier: a GUID in a registry description or default (an example or a default of some script) is shown as <guid>.
    # The one exception is Microsoft's public application ID of the Azure Local resource provider, which the registry quotes.
    param([string]$Text)
    return [regex]::Replace($Text, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', { param($m) if ($m.Value -eq '1412d89f-b8a8-4111-b4fd-e82905cbd85d') { $m.Value } else { '<guid>' } })
}

function Get-MapAncestor {
    # nodes[].network_adapters[].mac_address -> nodes[].network_adapters, nodes
    param([string]$Path)
    $out = [System.Collections.Generic.List[string]]::new()
    $cur = $Path
    while ($true) {
        $i = $cur.LastIndexOf('.')
        if ($i -lt 0) { break }
        $cur = $cur.Substring(0, $i)
        $name = if ($cur.EndsWith('[]')) { $cur.Substring(0, $cur.Length - 2) } else { $cur }
        $out.Add($name)
    }
    return , $out.ToArray()
}

function Get-MapToolOfFile {
    # The tool a toolkit script or module belongs to.
    param([string]$File, [string]$Function)
    if ($File -match '/(Test-InfrastructureFile|Test-VariablesFile|validate-variables|validate-registry|Compare-InfrastructureSchemaToRegistry|Test-ToolParameterRegistration)\.ps1$') { return 'validator' }
    if ($File -match '/AzlInfrastructure\.psm1$' -and $Function -match 'Finding|^Test-AzlInfrastructure$|^Get-SchemaFinding|^Read-InfrastructureFile') { return 'validator' }
    if ($File -match '/(node-configuration|remoting)/' -or $File -match 'phase-03-os-configuration') { return 'os-configuration' }
    if ($File -match 'arm-deployment/verification/' -or $File -match '/AzlPreCluster') { return 'pre-cluster-verification' }
    if ($File -match 'scripts/common/arm-deployment/' -or $File -match 'phase-05-cluster-deployment') { return 'arm-deployment' }
    if ($File -match 'scripts/common/(discovery|redfish|idrac-management)/' -or $File -match 'phase-01-hardware-provisioning') { return 'discovery' }
    if ($File -match 'scripts/common/cicd-infra/' -or $File -match 'scripts/deploy/01-cicd-infra') { return 'cicd-infra' }
    if ($File -match 'scripts/common/infrastructure/') { return 'infrastructure-helpers' }
    return 'toolkit-legacy-scripts'
}

# ---------------------------------------------------------------------------------------------------------------------
# The registry model
# ---------------------------------------------------------------------------------------------------------------------

function Get-VariableMapModel {
    <#
    .SYNOPSIS
        The registry's variables (one record per path), which are leaves, and which are keys of infrastructure.yml.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath, [Parameter(Mandatory)][string]$SchemaPath)

    $all = @(Get-RegistryVariable -Path $RegistryPath)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $all) { if ($seen.Add($r.Path)) { $records.Add($r) } }
    $parents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in $records) { foreach ($a in (Get-MapAncestor $r.Path)) { [void]$parents.Add($a) } }
    $leaves = @($records | Where-Object { -not $parents.Contains($_.Path) })
    $infra = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($s in (Get-InfrastructureSchemaVariable -SchemaPath $SchemaPath)) { [void]$infra.Add($s.Path) }
    [pscustomobject]@{ Record = $records.ToArray(); Leaf = $leaves; Infra = $infra; Index = (Get-MapIndex -Record $records.ToArray()); ByPath = @{} }
}

# ---------------------------------------------------------------------------------------------------------------------
# The scan: toolkit live, the other repositories from the snapshot or a fresh scan
# ---------------------------------------------------------------------------------------------------------------------

function Get-ExternalRepositoryRoot {
    param([string]$Explicit, [string]$EnvName, [string[]]$Candidate)
    if ($Explicit) { return $Explicit }
    $e = [Environment]::GetEnvironmentVariable($EnvName)
    if ($e -and (Test-Path -LiteralPath $e)) { return $e }
    foreach ($c in $Candidate) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Get-GitHeadShort {
    param([string]$Root)
    try { $h = (& git -C $Root rev-parse --short HEAD 2>$null); if ($LASTEXITCODE -eq 0 -and $h) { return [string]$h } } catch { Write-Verbose "no git in $Root" }
    return 'unknown'
}

function Get-ExternalScan {
    <#
    .SYNOPSIS
        Rescans azurelocal-ztp, azurelocal-sonar and Trailwright. Returns the snapshot rows (tool, file, function, path, mode, detail).
    #>
    [CmdletBinding()]
    param($Model, [string]$ZtpRoot, [string]$SonarRoot, [string]$TrailwrightRoot)
    $rows = [System.Collections.Generic.List[object]]::new()
    $add = { param($tool, $file, $function, $path, $mode, $detail) $rows.Add([pscustomobject][ordered]@{ tool = $tool; file = $file; function = $function; path = $path; mode = $mode; detail = $detail }) }
    foreach ($spec in @(@('ztp', $ZtpRoot, @('scripts')), @('sonar', $SonarRoot, @('src')))) {
        $tool, $root, $subs = $spec
        if (-not $root) { throw "The $tool checkout was not found. Give its path (New-VariableMap.ps1 -${tool}Root) or set the environment variable, or do not use -RescanExternal." }
        $files = foreach ($s in $subs) { Get-ChildItem -LiteralPath (Join-Path $root $s) -Recurse -File -Include '*.ps1', '*.psm1' | ForEach-Object FullName }
        foreach ($r in (Find-MapReader -Root $root -File @($files) -Index $Model.Index)) { & $add $tool $r.File $r.Function $r.Path $r.Mode '' }
        & $add '_source' $tool 'commit' '' '' (Get-GitHeadShort $root)
    }
    foreach ($k in (Get-MapSonarKey -SonarRoot $SonarRoot -Index $Model.Index)) { & $add 'sonar' 'src/AzlSonar/Private/Infrastructure.ps1' 'ConvertFrom-AzlSonarInfrastructureTree' $k.Path 'config-key' $k.ConfigKey }
    if (-not $TrailwrightRoot) { throw 'The Trailwright checkout was not found.' }
    foreach ($q in (Get-MapTrailwrightQuestion -TrailwrightRoot $TrailwrightRoot)) {
        $detail = "$($q.Step)/$($q.Owner)/$($q.Kind)" + $(if ($q.Optional) { '; optional' } else { '' }) + $(if ($q.Conditional) { '; conditional' } else { '' })
        & $add 'trailwright' $q.File $q.Id $q.Path 'question' $detail
    }
    & $add '_source' 'trailwright' 'commit' '' '' (Get-GitHeadShort $TrailwrightRoot)
    return @(Get-MapOrdered -Item $rows -Key { $args[0].tool }, { $args[0].path }, { $args[0].file }, { $args[0].function }, { $args[0].mode }, { $args[0].detail })
}

function Read-ExternalSnapshot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Import-Csv -LiteralPath $Path)
}

function ConvertTo-ExternalSnapshotText {
    param([object[]]$Row)
    $sorted = @(Get-MapOrdered -Item $Row -Key { [string]$args[0].tool }, { [string]$args[0].path }, { [string]$args[0].file }, { [string]$args[0].function }, { [string]$args[0].mode }, { [string]$args[0].detail })
    $text = ((@($sorted | ConvertTo-Csv -NoTypeInformation)) -join "`n") + "`n"
    return $text
}

# ---------------------------------------------------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------------------------------------------------

function Get-VariableMapData {
    <#
    .SYNOPSIS
        Everything the renderers need: the rows, the ARM table, the per-tool and per-phase tables.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExternalRow
    )
    $index = $Model.Index

    # ---- toolkit scan
    $files = @(Get-ChildItem -LiteralPath (Join-Path $ToolkitRoot 'scripts') -Recurse -File -Include '*.ps1', '*.psm1' | ForEach-Object FullName)
    $files = @(Get-MapSortedString -Value $files)
    $scan = @(Find-MapReader -Root $ToolkitRoot -File $files -Index $index)
    foreach ($r in $scan) { $r | Add-Member -NotePropertyName Tool -NotePropertyValue (Get-MapToolOfFile $r.File $r.Function) }

    # readers by path: distinct (tool, file, function, mode)
    $readers = @{}
    $addReader = {
        param($tool, $file, $function, $path, $mode)
        if (-not $readers.ContainsKey($path)) { $readers[$path] = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal) }
        $k = "$tool|$file|$function|$mode"
        if (-not $readers[$path].ContainsKey($k)) { $readers[$path][$k] = [pscustomobject]@{ Tool = $tool; File = $file; Function = $function; Mode = $mode } }
    }
    foreach ($r in $scan) { & $addReader $r.Tool $r.File $r.Function $r.Path $r.Mode }
    $ext = @($ExternalRow | Where-Object { $_.tool -in 'ztp', 'sonar' -and $_.mode -in 'chain', 'literal', 'inferred' })
    foreach ($r in $ext) { & $addReader $r.tool $r.file $r.function $r.path $r.mode }
    $navigated = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in $readers.Keys) { foreach ($x in $readers[$p].Values) { foreach ($a in (Get-MapAncestor $p)) { [void]$navigated.Add("$($x.Tool)|$a") } } }
    $questions = @{}
    foreach ($r in @($ExternalRow | Where-Object { $_.tool -eq 'trailwright' -and $_.mode -eq 'question' })) {
        if (-not $questions.ContainsKey($r.path)) { $questions[$r.path] = [System.Collections.Generic.List[object]]::new() }
        $questions[$r.path].Add($r)
    }
    $sonarKey = @{}
    foreach ($r in @($ExternalRow | Where-Object { $_.tool -eq 'sonar' -and $_.mode -eq 'config-key' })) {
        if (-not $sonarKey.ContainsKey($r.path)) { $sonarKey[$r.path] = [System.Collections.Generic.List[string]]::new() }
        $sonarKey[$r.path].Add($r.detail)
    }
    $sources = @($ExternalRow | Where-Object { $_.tool -eq '_source' } | ForEach-Object { "$($_.file) $($_.detail)" })

    # ---- downstream facts
    $arm = @(Get-MapArmParameter -Root $ToolkitRoot -Reader $scan -Index $index)
    $os = Get-MapOsStep -Root $ToolkitRoot -Reader $scan
    $gate = @(Get-MapGateCheck -Root $ToolkitRoot -Reader $scan -Index $index)
    $discovery = @(Get-MapDiscoveryWrite -Root $ToolkitRoot -Index $index)

    $armByPath = @{}
    foreach ($p in $arm) { foreach ($k in $p.Key) { if (-not $armByPath.ContainsKey($k)) { $armByPath[$k] = [System.Collections.Generic.HashSet[string]]::new() }; [void]$armByPath[$k].Add($p.Name) } }
    $gateByPath = @{}
    foreach ($g in $gate) {
        foreach ($k in @($g.Key) + @($g.Via)) { if (-not $gateByPath.ContainsKey($k)) { $gateByPath[$k] = [System.Collections.Generic.HashSet[string]]::new() }; [void]$gateByPath[$k].Add($g.Id) }
        foreach ($k in @($g.Named)) { if (-not $gateByPath.ContainsKey($k)) { $gateByPath[$k] = [System.Collections.Generic.HashSet[string]]::new() }; if (-not $gateByPath[$k].Contains($g.Id)) { [void]$gateByPath[$k].Add($g.Id + ' (named)') } }
    }
    $discoveryByPath = @{}
    foreach ($d in $discovery) { if (-not $discoveryByPath.ContainsKey($d.Path)) { $discoveryByPath[$d.Path] = [System.Collections.Generic.List[string]]::new() }; $discoveryByPath[$d.Path].Add($d.How) }

    # ---- rows
    $usedByPath = @{}
    foreach ($r in $Model.Record) { $usedByPath[$r.Path] = $r.UsedBy }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Model.Leaf) {
        $node = $r.Node
        $path = $r.Path
        $kind = if ($Model.Infra.Contains($path)) { 'infrastructure.yml' } elseif ($path.StartsWith('tools.')) { 'tool' } else { 'variables-file' }
        $section = ($path -split '[.\[]')[0]
        $ownerTool = ''
        $toolKind = ''
        if ($kind -eq 'tool') { $parts = $path.Split('.'); $ownerTool = $parts[1]; $toolKind = $parts[2]; $section = "tools.$ownerTool" }
        $description = if ($node.Contains('description')) { [string]$node['description'] } elseif ($node.Contains('file_schema') -and $node['file_schema'].Contains('description')) { [string]$node['file_schema']['description'] } else { '' }
        $deprecated = ($null -ne $r.Deprecated -and "$($r.Deprecated)".ToLowerInvariant() -in 'true', 'yes')
        $replacedBy = if ($node.Contains('replaced_by')) { Format-MapValue $node['replaced_by'] } else { '' }
        $sensitive = (($node.Contains('sensitive') -and $node['sensitive'] -eq $true) -or $r.Format -eq 'kv_ref')
        $required = switch -Regex ("$($r.Required)") { '^(True|true|Y|y|yes)$' { 'yes' } '^(False|false|N|n|no)$' { 'no' } default { '' } }
        $usedBy = $r.UsedBy
        if (-not $usedBy -and $path.EndsWith('.*')) { $usedBy = $usedByPath[$path.Substring(0, $path.Length - 2)] }   # tags.* is carried by the tools that carry tags
        $purposes = @(if ($usedBy) { @($usedBy -split '\|') } else { @() })

        # readers
        $direct = @(if ($readers.ContainsKey($path)) { @($readers[$path].Values) } else { @() })
        $partOf = [System.Collections.Generic.List[object]]::new()
        # A section or list that a tool reads wholesale (it reads none of its members by name) is consumed as a whole. One it only walks to get at
        # named members (nodes, then nodes[].name) says nothing about the members it does not name.
        foreach ($a in (Get-MapAncestor $path)) { if ($readers.ContainsKey($a)) { foreach ($x in $readers[$a].Values) { if (-not $navigated.Contains("$($x.Tool)|$a")) { $partOf.Add($x) } } } }
        $consumers = @($direct | Where-Object { $_.Tool -ne 'validator' })
        $validators = @($direct | Where-Object { $_.Tool -eq 'validator' })
        $consumerTools = @($consumers | ForEach-Object Tool | Select-Object -Unique)
        $partTools = @($partOf | Where-Object { $_.Tool -ne 'validator' } | ForEach-Object Tool | Select-Object -Unique | Where-Object { $_ -notin $consumerTools })

        # provided by
        $provided = [System.Collections.Generic.List[string]]::new()
        if ($kind -eq 'tool') {
            switch -Regex ($toolKind) {
                '^(parameters|run_settings|guard_settings|config_keys)$' { $provided.Add('operator (command line or config file)') }
                '^env_vars$' { $provided.Add('operator (environment)') }
                '^url_parameters$' { $provided.Add('operator (query string of the link)') }
                '^secret_names$' { $provided.Add('Key Vault secret') }
                '^(event_fields|report_fields|state_fields|handoff_fields)$' { $provided.Add("tool output ($ownerTool)") }
                default { $provided.Add('operator (pipeline or Terraform input)') }
            }
        }
        else {
            $provided.Add('operator by hand')
            if ($questions.ContainsKey($path)) { $provided.Add('Trailwright questionnaire') }
            if ($discoveryByPath.ContainsKey($path)) { $provided.Add($(if ($discoveryByPath[$path] -contains 'applied') { 'Dell/Redfish discovery (proposed, applied on request)' } else { 'Dell/Redfish discovery (proposed)' })) }
            if ($sensitive -and $r.Format -eq 'kv_ref') { $provided.Add('Key Vault reference (keyvault://)') }
            if ($r.HasDefault) { $provided.Add('default') }
        }

        # downstream
        $armNames = [System.Collections.Generic.HashSet[string]]::new()
        if ($armByPath.ContainsKey($path)) { foreach ($n in $armByPath[$path]) { [void]$armNames.Add($n) } }
        foreach ($a in (Get-MapAncestor $path)) { if ($a -match '[.\[]' -and $armByPath.ContainsKey($a)) { foreach ($n in $armByPath[$a]) { if (-not $armNames.Contains($n)) { [void]$armNames.Add("~$n") } } } }
        $steps = [System.Collections.Generic.HashSet[string]]::new()
        if ($os.ContainsKey($path)) { foreach ($s in $os[$path].Keys) { [void]$steps.Add($s) } }
        if ($kind -eq 'infrastructure.yml') { foreach ($s in (Get-MapOsStepFromText $description)) { [void]$steps.Add($s) } }
        foreach ($a in (Get-MapAncestor $path)) { if ($a -match '[.\[]' -and $os.ContainsKey($a)) { foreach ($s in $os[$a].Keys) { if (-not $steps.Contains($s)) { [void]$steps.Add("~$s") } } } }
        $gates = [System.Collections.Generic.HashSet[string]]::new()
        if ($gateByPath.ContainsKey($path)) { foreach ($g in $gateByPath[$path]) { [void]$gates.Add($g) } }
        $sonar = @(if ($sonarKey.ContainsKey($path)) { @($sonarKey[$path]) } else { @() })
        $tw = @(if ($questions.ContainsKey($path)) { @($questions[$path] | ForEach-Object { $_.detail }) } else { @() })

        # status
        $status = ''
        $note = ''
        if ($deprecated) { $status = 'deprecated'; $note = $(if ($replacedBy) { "replaced by $replacedBy" } else { 'no replacement named' }) }
        elseif ($kind -eq 'tool') {
            $readAt = if ($node.Contains('read_at')) { [string]$node['read_at'] } else { '' }
            if ($readAt -match 'not read by code') { $status = 'placeholder'; $note = 'the tool documents it and does not read it yet' } else { $status = 'read'; $note = "tool-owned; $readAt" }
        }
        elseif ($consumers.Count) { $status = 'read' }
        elseif ($partTools.Count) { $status = 'read-as-part'; $first = @($partOf | Where-Object { $_.Tool -in $partTools } | Select-Object -First 1); $status = 'read-as-part'; $note = "no tool names it; $($first[0].Tool) reads the section or list that holds it ($($first[0].Function))" }
        elseif ($validators.Count) { $status = 'validated-only'; $note = 'only the validator names it' }
        else { $status = 'placeholder'; $note = 'documented in the registry; no tool in the scan reads it' }

        $readerTexts = @(foreach ($x in (Get-MapOrdered -Item $direct -Key { $args[0].Tool }, { $args[0].File }, { $args[0].Function }, { $args[0].Mode })) { "$($x.Tool):$($x.File):$($x.Function):$($x.Mode)" })
        if ($kind -eq 'tool') { $readerTexts = @("${ownerTool}: $(if ($node.Contains('read_at')) { [string]$node['read_at'] } else { '' })") }

        $rows.Add([pscustomobject][ordered]@{
                path                  = $path
                kind                  = $kind
                section               = $section
                owner_tool            = $ownerTool
                tool_kind             = $toolKind
                type                  = [string]$r.Type
                format                = [string]$r.Format
                default               = $(if ($r.HasDefault) { Format-MapValue $r.Default } else { '' })
                allowed_values        = [string]$r.Enum
                required              = $required
                since                 = [string]$r.Since
                sensitive             = $(if ($sensitive) { 'yes' } else { '' })
                applies_when          = $(if ($node.Contains('applies_when')) { [string]$node['applies_when'] } else { '' })
                description           = (Get-MapFirstSentence $description)
                purposes              = ($purposes -join '; ')
                provided_by           = ($provided -join '; ')
                read_by_tools         = ((Get-MapSortedString $consumerTools) -join '; ')
                validated_by          = $(if ($validators.Count) { 'validator' } else { '' })
                read_as_part_by       = ((Get-MapSortedString $partTools) -join '; ')
                readers               = ($readerTexts -join ' | ')
                arm_parameters        = ((Get-MapSortedString @($armNames)) -join '; ')
                os_steps              = ((Get-MapSortedString @($steps)) -join '; ')
                sonar_config_key      = ((Get-MapSortedString $sonar) -join '; ')
                gate_checks           = ((Get-MapSortedString @($gates)) -join '; ')
                trailwright           = ((Get-MapSortedString $tw) -join ' | ')
                status                = $status
                deprecated            = $(if ($deprecated) { 'yes' } else { '' })
                replaced_by           = $replacedBy
                note                  = $note
            })
    }

    [pscustomobject]@{
        Row = $rows.ToArray(); Arm = $arm; Gate = $gate; Discovery = $discovery; Scan = $scan; Readers = $readers
        Questions = $questions; Sources = $sources; Model = $Model; External = $ExternalRow
        ArmCatalog = (Get-Content -LiteralPath (Join-Path $ToolkitRoot 'config/azure/arm-templates/template-parameters.json') -Raw | ConvertFrom-Json -AsHashtable)
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-VariableMapCsv {
    param([object[]]$Row)
    return ((@($Row | ConvertTo-Csv -NoTypeInformation)) -join "`n") + "`n"
}

# ---------------------------------------------------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------------------------------------------------

function Format-MapAllowed {
    param([string]$Allowed)
    if (-not $Allowed) { return '' }
    $v = @($Allowed -split '\|')
    if ($v.Count -gt 6) { return (($v | Select-Object -First 6 | ForEach-Object { "``$_``" }) -join ', ') + ", ... ($($v.Count))" }
    return (($v | ForEach-Object { "``$_``" }) -join ', ')
}

function Get-MapToolList {
    param([string]$Text)
    if (-not $Text) { return '' }
    return $Text
}

function ConvertTo-VariableMapMarkdown {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$RegistryVersion)

    $rows = $Data.Row
    $sb = [System.Text.StringBuilder]::new()
    $line = { param([string]$t = '') [void]$sb.Append($t).Append("`n") }

    $infraRows = @($rows | Where-Object kind -eq 'infrastructure.yml')
    $toolRows = @($rows | Where-Object kind -eq 'tool')
    $platformRows = @($rows | Where-Object kind -eq 'variables-file')

    & $line '# Variable map: what variable goes where'
    & $line
    & $line '**This page is generated. Do not edit it.** It is built from the master registry ([`master-registry.yaml`](../schema/master-registry.yaml), the only master of every variable) and from a scan of the code that reads the variables. Because it is generated, it cannot drift: a test regenerates it and fails when the committed copy differs.'
    & $line
    & $line '```powershell'
    & $line './config/variables/scripts/New-VariableMap.ps1           # regenerate (rescans the toolkit; ZTP, Sonar and Trailwright from the committed snapshot)'
    & $line './config/variables/scripts/New-VariableMap.ps1 -RescanExternal   # also rescan the ZTP, Sonar and Trailwright checkouts, refreshing the snapshot'
    & $line './config/variables/scripts/New-VariableMap.ps1 -Check    # exit 1 when a committed file is out of date (the tests run this)'
    & $line '```'
    & $line
    & $line 'The machine-readable copy, one row per variable with every column, is [`reports/variable-map.csv`](../reports/variable-map.csv). This page shows the variables of `infrastructure.yml` in full; the variables owned by a tool and the older variables-file sections are summarised (their rows are in the CSV). The diagram of the same flow is [`variable-flow.drawio`](diagrams/variable-flow.drawio) ([PNG](diagrams/variable-flow.png)).'
    & $line
    & $line "Registry version $RegistryVersion. Sources of the scan: toolkit (this repository), $((@($Data.Sources) | ForEach-Object { $_ }) -join ', ')."
    & $line

    # ---- counts
    & $line '## In numbers'
    & $line
    & $line '| | Variables | read | read as part | validated only | placeholder | deprecated |'
    & $line '| --- | ---: | ---: | ---: | ---: | ---: | ---: |'
    foreach ($set in @(@('Keys of infrastructure.yml', $infraRows), @('Owned by a tool (`tools.*`)', $toolRows), @('Older variables-file sections', $platformRows), @('All registry leaves', $rows))) {
        $s = @($set[1])
        & $line ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $set[0], $s.Count, @($s | Where-Object status -eq 'read').Count, @($s | Where-Object status -eq 'read-as-part').Count, @($s | Where-Object status -eq 'validated-only').Count, @($s | Where-Object status -eq 'placeholder').Count, @($s | Where-Object status -eq 'deprecated').Count)
    }
    & $line
    & $line 'A "leaf" is a registry variable with no variable below it (`nodes[].name`, not `nodes`). Status: **read**: a tool names the key in code; **read as part**: no tool names it, but one reads the section or list that holds it; **validated only**: only the validator names it; **placeholder**: documented in the registry, no tool in the scan reads it; **deprecated**: kept for compatibility (`replaced_by` says what replaces it). For a tool-owned variable, read means the registry points at the code that reads or writes it.'
    & $line

    # ---- how to read
    & $line '## How to read the rows'
    & $line
    & $line '| Column | Meaning |'
    & $line '| --- | --- |'
    & $line '| Provided by | Who gives the key its value. **operator by hand**: you write it. **Trailwright questionnaire**: a question in Trailwright''s catalog writes it. **Dell/Redfish discovery**: `ConvertTo-AzlDiscoveryProposal` writes it into the proposal (you review it; `Get-AzlDiscoveryChange` can apply some on request). **Key Vault reference**: the file holds a secret reference (`keyvault://<vault>/<secret>`, or the `env://`, `file://` or `command://` form), never the secret. **default**: the registry has a default for when the key is left out. Values that no person gives (the ZTP handoff, the OS configuration report) are in the ARM table below, because they feed the ARM parameters, not the file. |'
    & $line '| Tools | The tools that read the key (registry `used_by`; Trailwright writes it): the ids in `_tool_catalog` of the registry, for example `ztp` (azurelocal-ztp), `monitoring` (azurelocal-sonar), `os_configuration`, `deployment`, `cicd_infra`, `discovery`, `trailwright`, `ranger`. Each tool with keys has a generated template, a subset of the master file ([templates/tools](../templates/tools)). |'
    & $line '| Read by | The tools whose code reads the key by name (`chain` or `literal` in the scan, see Limits). In parentheses, a key that is read only as part of a section: `(part: tool)`. |'
    & $line '| Becomes | What the key turns into downstream: **ARM** template parameter, **OS** configuration step, **Sonar** configuration key, **Gate** pre-cluster verification check id. A leading `~` means the parameter or step is built from the whole parent section or list that holds the key. |'
    & $line

    # ---- by phase
    & $line '## By phase: Design, Discovery, ZTP, OS configuration, Pre-cluster verification, ARM Validate/Deploy, Sonar'
    & $line
    & $line 'The master `infrastructure.yml` is the one file every phase reads. Each phase reads its own part (its tool template); nobody edits a tool template by hand.'
    & $line
    $phaseOfTool = $script:ToolPhase
    $readersByPhase = @{}   # phase -> set of paths read
    foreach ($row in $infraRows) {
        foreach ($t in ($row.read_by_tools -split '; ' | Where-Object { $_ })) {
            $ph = if ($phaseOfTool.ContainsKey($t)) { $phaseOfTool[$t] } else { 'Outside the flow' }
            if (-not $readersByPhase.ContainsKey($ph)) { $readersByPhase[$ph] = [System.Collections.Generic.HashSet[string]]::new() }
            [void]$readersByPhase[$ph].Add($row.path)
        }
        if ($Data.Questions.ContainsKey($row.path)) { if (-not $readersByPhase.ContainsKey('Design')) { $readersByPhase['Design'] = [System.Collections.Generic.HashSet[string]]::new() }; [void]$readersByPhase['Design'].Add($row.path) }
    }
    $discoveryPaths = @($infraRows | Where-Object { $_.provided_by -like '*Redfish discovery*' } | ForEach-Object path)
    $ownByTool = @{}
    foreach ($tr in $toolRows) { if (-not $ownByTool.ContainsKey($tr.owner_tool)) { $ownByTool[$tr.owner_tool] = 0 }; $ownByTool[$tr.owner_tool]++ }
    & $line '| Phase | Tool | Keys of infrastructure.yml it reads or fills | Sections | Tool id | Hands on |'
    & $line '| --- | --- | ---: | --- | --- | --- |'
    $purposeOfPhase = @{ 'Design' = 'any (it writes the whole file)'; 'Discovery' = 'discovery'; 'ZTP' = 'ztp'; 'OS configuration' = 'os_configuration'; 'Pre-cluster verification' = 'deployment'; 'ARM Validate/Deploy' = 'deployment'; 'Sonar' = 'monitoring'; 'Outside the flow' = 'cicd_infra' }
    $handsOn = @{
        'Design'                   = 'infrastructure.yml (Trailwright exports it)'
        'Discovery'                = 'a proposal for nodes[] (serial number, ports, MACs), reviewed by you'
        'ZTP'                      = 'ztp-handoff.json (Arc machine IDs, installed build, management address verified), ztp-events.jsonl'
        'OS configuration'         = 'the OS configuration report (ports and OS adapter names by MAC, SAN disks), os-configuration-events.jsonl'
        'Pre-cluster verification' = 'the verification report (verdict and check results), precluster-verification-events.jsonl'
        'ARM Validate/Deploy'      = 'deploymentParameters.json (the ARM parameters), arm-deployment-events.jsonl, the deployment on Azure'
        'Sonar'                    = 'a live view; reads the feeds above'
        'Outside the flow'         = 'CI/CD runners, the validator, shared helpers and the older numbered deploy scripts'
    }
    $toolOfPhase = @{ 'Design' = 'Trailwright'; 'Discovery' = 'Get-HardwareInventory.ps1, Invoke-HardwareDiscovery.ps1'; 'ZTP' = 'azurelocal-ztp'; 'OS configuration' = 'Set-AzureLocalNodeConfiguration.ps1, Invoke-AzureLocalOsConfiguration.ps1'; 'Pre-cluster verification' = 'AzlPreClusterVerification.psm1'; 'ARM Validate/Deploy' = 'Invoke-AzureLocalArmDeployment.ps1 (New-AzlArmParameterSet)'; 'Sonar' = 'azurelocal-sonar'; 'Outside the flow' = 'cicd-infra, validator, helpers, legacy scripts' }
    foreach ($ph in $script:PhaseOrder.Keys) {
        $set = @(if ($readersByPhase.ContainsKey($ph)) { @($readersByPhase[$ph]) } else { @() })
        if ($ph -eq 'Discovery') { $set = @($set + $discoveryPaths | Select-Object -Unique) }
        $sections = (Get-MapSortedString @($set | ForEach-Object { ($_ -split '[.\[]')[0] } | Select-Object -Unique)) -join ', '
        & $line ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $ph, $toolOfPhase[$ph], $set.Count, $sections, $purposeOfPhase[$ph], $handsOn[$ph])
    }
    & $line
    & $line '### Which section is read in which phase (number of keys)'
    & $line
    $phases = @($script:PhaseOrder.Keys)
    & $line ('| Section | ' + ($phases -join ' | ') + ' |')
    & $line ('| --- | ' + (($phases | ForEach-Object { '---:' }) -join ' | ') + ' |')
    $sectionList = @($infraRows | ForEach-Object section | Select-Object -Unique)
    foreach ($sec in $sectionList) {
        $cells = foreach ($ph in $phases) {
            $set = @(if ($readersByPhase.ContainsKey($ph)) { @($readersByPhase[$ph]) } else { @() })
            if ($ph -eq 'Discovery') { $set = @($set + $discoveryPaths | Select-Object -Unique) }
            $n = @($set | Where-Object { ($_ -split '[.\[]')[0] -eq $sec }).Count
            if ($n) { "$n" } else { '' }
        }
        & $line ("| ``$sec`` | " + ($cells -join ' | ') + ' |')
    }
    & $line
    $multi = @($infraRows | Where-Object {
            $p = $_.path
            $count = 0
            foreach ($ph in $script:PhaseOrder.Keys) { if ($ph -ne 'Outside the flow' -and $readersByPhase.ContainsKey($ph) -and $readersByPhase[$ph].Contains($p)) { $count++ } }
            $count -ge 3
        })
    & $line "### Keys that three or more phases read ($($multi.Count))"
    & $line
    & $line 'These are the keys to get right first: a wrong value reaches every phase that reads it.'
    & $line
    & $line ((@($multi | ForEach-Object { "``$($_.path)``" })) -join ', ')
    & $line

    # ---- by tool
    & $line '## By tool: the variables it reads and writes'
    & $line
    & $line 'Reads are keys of `infrastructure.yml` the code names (from the scan). Writes are what the tool puts into the file or into a handoff. "Owns" is the number of variables the registry lists for the tool itself (`tools.<tool>.*`: parameters, settings, events, secrets).'
    & $line
    $toolOrder = @('trailwright', 'discovery', 'ztp', 'os-configuration', 'pre-cluster-verification', 'arm-deployment', 'sonar', 'cicd-infra', 'infrastructure-helpers', 'validator', 'toolkit-legacy-scripts')
    $registryToolFor = @{ 'trailwright' = ''; 'discovery' = 'discovery'; 'ztp' = 'ztp'; 'os-configuration' = 'os_configuration'; 'pre-cluster-verification' = ''; 'arm-deployment' = 'arm_deployment'; 'sonar' = 'sonar'; 'cicd-infra' = 'cicd_infra'; 'infrastructure-helpers' = ''; 'validator' = ''; 'toolkit-legacy-scripts' = '' }
    & $line '| Tool | Phase | Reads (keys) | Writes or fills (keys) | Owns (tool variables) |'
    & $line '| --- | --- | ---: | ---: | ---: |'
    $readsOfTool = @{}
    foreach ($row in $infraRows) { foreach ($t in ($row.read_by_tools -split '; ' | Where-Object { $_ })) { if (-not $readsOfTool.ContainsKey($t)) { $readsOfTool[$t] = [System.Collections.Generic.List[string]]::new() }; $readsOfTool[$t].Add($row.path) } }
    foreach ($row in $infraRows) { if ($row.validated_by) { if (-not $readsOfTool.ContainsKey('validator')) { $readsOfTool['validator'] = [System.Collections.Generic.List[string]]::new() }; $readsOfTool['validator'].Add($row.path) } }
    $writesOfTool = @{ 'trailwright' = @($infraRows | Where-Object { $Data.Questions.ContainsKey($_.path) } | ForEach-Object path); 'discovery' = $discoveryPaths }
    foreach ($t in $toolOrder) {
        $own = if ($registryToolFor[$t] -and $ownByTool.ContainsKey($registryToolFor[$t])) { $ownByTool[$registryToolFor[$t]] } else { 0 }
        $rd = if ($readsOfTool.ContainsKey($t)) { $readsOfTool[$t].Count } else { 0 }
        $wr = if ($writesOfTool.ContainsKey($t)) { @($writesOfTool[$t]).Count } else { 0 }
        $ph = if ($script:ToolPhase.ContainsKey($t)) { $script:ToolPhase[$t] } else { '' }
        & $line ('| {0} | {1} | {2} | {3} | {4} |' -f $t, $ph, $rd, $wr, $own)
    }
    & $line
    foreach ($t in $toolOrder) {
        $rd = @(if ($readsOfTool.ContainsKey($t)) { @($readsOfTool[$t] | Select-Object -Unique) } else { @() })
        $wr = @(if ($writesOfTool.ContainsKey($t)) { $writesOfTool[$t] })
        if (-not $rd.Count -and -not $wr.Count) { continue }
        & $line "### $t"
        & $line
        if ($wr.Count) { & $line "**Writes or fills ($($wr.Count)):**" }
        if ($wr.Count) { & $line ((@($wr | ForEach-Object { "``$_``" })) -join ', ') ; & $line }
        if ($rd.Count) {
            if ($rd.Count -gt 150) {
                & $line "**Reads ($($rd.Count)):** the keys are listed by section; the CSV has each key with the file and function."
                & $line
                foreach ($g in ($rd | Group-Object { ($_ -split '[.\[]')[0] })) { & $line ("- ``{0}``: {1} keys" -f $g.Name, $g.Count) }
                & $line
            }
            else {
                & $line "**Reads ($($rd.Count)):**"
                & $line ((@($rd | ForEach-Object { "``$_``" })) -join ', ')
                & $line
            }
            # where in the code: file and function, with the number of keys of infrastructure.yml each reads by name
            $byPlace = @{}
            foreach ($row in $infraRows) {
                if (-not $Data.Readers.ContainsKey($row.path)) { continue }
                foreach ($x in $Data.Readers[$row.path].Values) {
                    if ($x.Tool -ne $t) { continue }
                    $k = "$($x.File)|$($x.Function)"
                    if (-not $byPlace.ContainsKey($k)) { $byPlace[$k] = [System.Collections.Generic.HashSet[string]]::new() }
                    [void]$byPlace[$k].Add($row.path)
                }
            }
            if ($byPlace.Count) {
                $places = @(Get-MapOrdered -Item @($byPlace.GetEnumerator()) -Key { $args[0].Value.Count }, { $args[0].Key } -Descending @($true, $false))
                $more = if ($places.Count -gt 12) { ', the first 12' } else { '' }
                & $line "Where in the code (file, function, keys read by name; $($places.Count) places$more):"
                & $line
                & $line '| File | Function | Keys |'
                & $line '| --- | --- | ---: |'
                foreach ($pl in ($places | Select-Object -First 12)) { $file, $function = $pl.Key.Split('|'); & $line ('| `{0}` | `{1}` | {2} |' -f $file, $function, $pl.Value.Count) }
                & $line
            }
        }
    }

    # ---- by ARM parameter
    & $line '## By ARM parameter: the template parameter and the file key it comes from'
    & $line
    & $line 'From `New-AzlArmParameterSet` (`scripts/common/arm-deployment/AzlArmDeployment.psm1`), which builds the parameters of Microsoft''s quickstart template. **Direct**: keys the statement reads. **Through a helper**: keys read by a function the statement calls (for example `Get-AzlManagementAdapter`). **Also from**: values that are not in the file (the ZTP handoff, the OS configuration report, the SBE folder, a parameter of the command). **When**: the condition around the statement. Templates: how many of the seven quickstart templates declare the parameter (`config/azure/arm-templates/template-parameters.json`).'
    & $line
    & $line '| ARM parameter | Direct (file keys) | Through a helper | Also from | When | Templates | Secret |'
    & $line '| --- | --- | --- | --- | --- | ---: | --- |'
    $catalog = $Data.ArmCatalog
    $templateNames = @($catalog.templates.Keys)
    $armNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in $Data.Arm) { [void]$armNames.Add($p.Name) }
    foreach ($tn in $templateNames) { foreach ($pn in $catalog.templates[$tn].parameters.Keys) { [void]$armNames.Add($pn) } }
    $armByName = @{}; foreach ($p in $Data.Arm) { $armByName[$p.Name] = $p }
    foreach ($name in (Get-MapSortedString @($armNames))) {
        $p = if ($armByName.ContainsKey($name)) { $armByName[$name] } else { $null }
        $n = @($templateNames | Where-Object { $catalog.templates[$_].parameters.Contains($name) }).Count
        $secret = ''
        foreach ($tn in $templateNames) { if ($catalog.templates[$tn].parameters.Contains($name) -and $catalog.templates[$tn].parameters[$name].type -eq 'securestring') { $secret = 'securestring' } }
        if ($p) {
            $direct = (@($p.Key | Where-Object { $Data.Model.Index.Paths.Contains($_) } | ForEach-Object { "``$_``" }) -join ', ')
            $via = (@($p.ViaHelper | Select-Object -First 6 | ForEach-Object { "``$_``" }) -join ', ') + $(if (@($p.ViaHelper).Count -gt 6) { ", ... ($(@($p.ViaHelper).Count))" } else { '' })
            & $line ('| `{0}` | {1} | {2} | {3} | {4} | {5} | {6} |' -f $name, $direct, $via, (ConvertTo-MapCell (@($p.Source) -join ', ')), (ConvertTo-MapCell $(if ($p.When) { "``$($p.When)``" } else { '' })), $n, $secret)
        }
        else {
            & $line ('| `{0}` | not set by the builder (the template default applies) | | | | {1} | {2} |' -f $name, $n, $secret)
        }
    }
    & $line

    # ---- where do I set X
    & $line '## Where do I set X: the 40 most used variables'
    & $line
    & $line 'Ranked by how many different tools read the key, then how many places in the code. All of these are keys of `infrastructure.yml`: you set them in the file (or answer the Trailwright question that writes it), then run the phase that reads them.'
    & $line
    & $line '| Variable | What it is | Set it by | Read by | Becomes |'
    & $line '| --- | --- | --- | --- | --- |'
    $candidates = @($infraRows | Where-Object { $_.read_by_tools } | ForEach-Object {
            $row = $_
            $places = if ($Data.Readers.ContainsKey($row.path)) { $Data.Readers[$row.path].Count } else { 0 }
            [pscustomobject]@{ Row = $row; Tools = @($row.read_by_tools -split '; ').Count; Places = $places }
        })
    $ranked = @(Get-MapOrdered -Item $candidates -Key { $args[0].Tools }, { $args[0].Places }, { $args[0].Row.path } -Descending @($true, $true, $false) | Select-Object -First 40)
    foreach ($x in $ranked) {
        $row = $x.Row
        $becomes = @()
        if ($row.arm_parameters) { $becomes += "ARM $($row.arm_parameters)" }
        if ($row.os_steps) { $becomes += "OS $($row.os_steps)" }
        if ($row.sonar_config_key) { $becomes += "Sonar $($row.sonar_config_key)" }
        if ($row.gate_checks) { $becomes += "Gate $($row.gate_checks)" }
        & $line ('| `{0}` | {1} | {2} | {3} | {4} |' -f $row.path, (ConvertTo-MapCell $row.description), (ConvertTo-MapCell $row.provided_by), (ConvertTo-MapCell $row.read_by_tools), (ConvertTo-MapCell ($becomes -join '; ')))
    }
    & $line

    # ---- unread / placeholder
    & $line '## Unread and placeholder variables'
    & $line
    & $line 'Variables the registry documents that no tool in the scan reads by name. Each is either a key a coming phase will read, a key only the validator checks, or a name kept for compatibility. Nothing here is an error; it is the list to look at before you spend time filling a key in that nothing uses yet.'
    & $line
    foreach ($st in @(@('placeholder', 'Placeholder: documented, not read by any tool in the scan'), @('validated-only', 'Validated only: the validator names it, nothing consumes it'), @('read-as-part', 'Read as part: no tool names the key; a tool reads the section or list that holds it'))) {
        $set = @($infraRows | Where-Object status -eq $st[0])
        & $line "### $($st[1]) ($($set.Count))"
        & $line
        if ($set.Count) {
            & $line '| Variable | Tools | Provided by | Note |'
            & $line '| --- | --- | --- | --- |'
            foreach ($row in $set) {
                $note = if ($st[0] -eq 'read-as-part') { "read as part by $($row.read_as_part_by)" } else { $row.note }
                & $line ('| `{0}` | {1} | {2} | {3} |' -f $row.path, (ConvertTo-MapCell $row.purposes), (ConvertTo-MapCell $row.provided_by), (ConvertTo-MapCell $note))
            }
        }
        else { & $line 'None.' }
        & $line
    }
    $dep = @($rows | Where-Object status -eq 'deprecated')
    & $line "### Deprecated, with what replaces them ($($dep.Count))"
    & $line
    if ($dep.Count) {
        & $line '| Variable | Replaced by | Still read by |'
        & $line '| --- | --- | --- |'
        foreach ($row in $dep) { & $line ('| `{0}` | {1} | {2} |' -f $row.path, (ConvertTo-MapCell $(if ($row.replaced_by) { "``$($row.replaced_by)``" } else { '(none named)' })), (ConvertTo-MapCell $row.read_by_tools)) }
    }
    else { & $line 'None.' }
    & $line
    $toolPlaceholder = @($toolRows | Where-Object status -eq 'placeholder')
    & $line "### Tool variables the tool documents and does not read yet ($($toolPlaceholder.Count))"
    & $line
    if ($toolPlaceholder.Count) {
        & $line '| Variable | Owner | Kind |'
        & $line '| --- | --- | --- |'
        foreach ($row in $toolPlaceholder) { & $line ('| `{0}` | {1} | {2} |' -f $row.path, $row.owner_tool, $row.tool_kind) }
    }
    else { & $line 'None.' }
    & $line
    $legacy = @(Get-MapOrdered -Item @($platformRows | Group-Object section) -Key { $args[0].Name })
    & $line "### Older variables-file sections ($($platformRows.Count) variables)"
    & $line
    & $line 'These registry sections (`compute`, `identity.accounts`, `azure_platform`, ...) describe the earlier variables file, not `infrastructure.yml`. The numbered deploy scripts under `scripts/deploy` read some of them. They are in the CSV (`kind` = `variables-file`).'
    & $line
    & $line '| Section | Variables | read | placeholder | deprecated |'
    & $line '| --- | ---: | ---: | ---: | ---: |'
    foreach ($g in $legacy) {
        $s = @($g.Group)
        & $line ('| `{0}` | {1} | {2} | {3} | {4} |' -f $g.Name, $s.Count, @($s | Where-Object status -in 'read', 'read-as-part').Count, @($s | Where-Object status -eq 'placeholder').Count, @($s | Where-Object status -eq 'deprecated').Count)
    }
    & $line

    # ---- full map of infrastructure.yml
    & $line '## The map: every key of infrastructure.yml'
    & $line
    & $line 'Grouped by section, in the order of the file. `req`: yes when the registry marks the key required (the schema has conditional rules on top of this; see [VARIABLES.md](VARIABLES.md)).'
    & $line
    $bySection = $infraRows | Group-Object section
    foreach ($g in $bySection) {
        & $line "### $($g.Name)"
        & $line
        & $line '| Path | Type, default, allowed | Provided by | Tools | Read by | Becomes | Status |'
        & $line '| --- | --- | --- | --- | --- | --- | --- |'
        foreach ($row in $g.Group) {
            $parts = [System.Collections.Generic.List[string]]::new()
            $typeText = $row.type
            if ($row.format -and $row.format -ne $row.type) { $typeText = $(if ($typeText) { "$typeText ($($row.format))" } else { $row.format }) }
            if ($typeText) { $parts.Add($typeText) }
            if ($row.required -eq 'yes') { $parts.Add('required') }
            if ($row.default -ne '') { $parts.Add("default ``$($row.default)``") }
            $al = Format-MapAllowed $row.allowed_values
            if ($al) { $parts.Add("one of $al") }
            $t = $parts -join ', '
            $becomes = @()
            if ($row.arm_parameters) { $becomes += "ARM $($row.arm_parameters)" }
            if ($row.os_steps) { $becomes += "OS $($row.os_steps)" }
            if ($row.sonar_config_key) { $becomes += "Sonar $($row.sonar_config_key)" }
            if ($row.gate_checks) { $becomes += "Gate $($row.gate_checks)" }
            $readBy = $row.read_by_tools
            if ($row.read_as_part_by -and -not $readBy) { $readBy = "(part: $($row.read_as_part_by))" }
            $status = $row.status
            if ($row.deprecated) { $status = "deprecated" + $(if ($row.replaced_by) { " -> ``$($row.replaced_by)``" } else { '' }) }
            $prov = $row.provided_by -replace 'operator by hand', 'operator' -replace ' \(proposed, applied on request\)', ' (proposes, applies)' -replace ' \(proposed\)', ' (proposes)' -replace 'Trailwright questionnaire', 'Trailwright' -replace 'Key Vault reference \(keyvault://\)', 'Key Vault ref'
            & $line ('| `{0}` | {1} | {2} | {3} | {4} | {5} | {6} |' -f $row.path, (ConvertTo-MapCell $t), (ConvertTo-MapCell $prov), (ConvertTo-MapCell $row.purposes), (ConvertTo-MapCell $readBy), (ConvertTo-MapCell ($becomes -join '; ')), $status)
        }
        & $line
    }

    # ---- tool variables
    & $line '## Variables owned by a tool'
    & $line
    & $line 'The registry lists the variables of each tool under `tools.<tool>.<kind>.<group>.<name>`: command parameters, settings, config keys, events, state and handoff fields, secret names, environment variables. Each row in the CSV says where the tool reads or writes it (`readers`). The kinds:'
    & $line
    & $line '| Tool | Kind | Variables | read | placeholder |'
    & $line '| --- | --- | ---: | ---: | ---: |'
    foreach ($g in ($toolRows | Group-Object { "$($_.owner_tool)|$($_.tool_kind)" })) {
        $s = @($g.Group)
        $o, $k = $g.Name.Split('|')
        & $line ('| {0} | {1} | {2} | {3} | {4} |' -f $o, $k, $s.Count, @($s | Where-Object status -eq 'read').Count, @($s | Where-Object status -eq 'placeholder').Count)
    }
    & $line

    # ---- limits
    & $line '## How the scan works, and what it cannot see'
    & $line
    & $line 'The scan parses PowerShell with the language parser (nothing is run) and records a key when code reads it in one of three ways: `chain` (`$infra.cluster.name`, `$node[''bmc''][''ip_address'']`, the item of a `foreach` over `$infra.nodes`, `$_` in `Where-Object`), `literal` (a string that is exactly a registry path, or `Get-AzlProp $node ''bmc.ip_address''`, `.Contains(''x'')`), or `inferred` (a prefix plus a literal key in the same loop). The Trailwright catalog and Sonar''s documented key mapping are read as text.'
    & $line
    & $line 'What it cannot see: a key read by a path built at run time from data; a value passed to another function that reads it there under another name (the map follows only functions that read the key by name; the ARM and OS tables follow one helper level); code that is not PowerShell (the Ansible roles, the Trailwright exporters, which still write the schema 4 shape); the tools'' own feeds read by other tools (for example Sonar reading ZTP events). A variable shown as placeholder or read as part may still be used in one of those ways.'
    & $line
    return $sb.ToString()
}

function Get-VariableMapOutput {
    <#
    .SYNOPSIS
        The text of VARIABLE-MAP.md, variable-map.csv and the external snapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [string]$RegistryPath,
        [string]$SchemaPath,
        [string]$SnapshotPath,
        [switch]$RescanExternal,
        [string]$ZtpRoot, [string]$SonarRoot, [string]$TrailwrightRoot
    )
    if (-not $RegistryPath) { $RegistryPath = Join-Path $ToolkitRoot 'config/variables/schema/master-registry.yaml' }
    if (-not $SchemaPath) { $SchemaPath = Join-Path $ToolkitRoot 'config/variables/schema/infrastructure.schema.json' }
    if (-not $SnapshotPath) { $SnapshotPath = Join-Path $ToolkitRoot 'config/variables/reports/variable-map-external-readers.csv' }
    $model = Get-VariableMapModel -RegistryPath $RegistryPath -SchemaPath $SchemaPath
    if ($RescanExternal) {
        $ztp = Get-ExternalRepositoryRoot -Explicit $ZtpRoot -EnvName 'AZL_ZTP_REPO' -Candidate @((Join-Path $ToolkitRoot '../azurelocal-ztp'), 'D:\git\azurelocal\azurelocal-ztp')
        $sonar = Get-ExternalRepositoryRoot -Explicit $SonarRoot -EnvName 'AZL_SONAR_REPO' -Candidate @((Join-Path $ToolkitRoot '../azurelocal-sonar'), 'D:\git\azurelocal\azurelocal-sonar')
        $tw = Get-ExternalRepositoryRoot -Explicit $TrailwrightRoot -EnvName 'AZL_TRAILWRIGHT_REPO' -Candidate @((Join-Path $ToolkitRoot '../azurelocal-trailwright'), 'D:\git\hybrid-solutions-cloud\azurelocal-trailwright')
        $external = @(Get-ExternalScan -Model $model -ZtpRoot $ztp -SonarRoot $sonar -TrailwrightRoot $tw)
    }
    else { $external = @(Read-ExternalSnapshot -Path $SnapshotPath) }
    $data = Get-VariableMapData -Model $model -ToolkitRoot $ToolkitRoot -ExternalRow $external
    $registry = Read-RegistryYaml -Path $RegistryPath
    $version = [string]$registry['_metadata']['version']
    [pscustomobject]@{
        Markdown = (Hide-MapGuid (ConvertTo-VariableMapMarkdown -Data $data -RegistryVersion $version))
        Csv      = (Hide-MapGuid (ConvertTo-VariableMapCsv -Row $data.Row))
        External = (ConvertTo-ExternalSnapshotText -Row $external)
        Data     = $data
    }
}

Export-ModuleMember -Function Get-VariableMapOutput, Get-VariableMapModel, Get-VariableMapData, ConvertTo-VariableMapMarkdown, ConvertTo-VariableMapCsv, Get-ExternalScan, Read-ExternalSnapshot, ConvertTo-ExternalSnapshotText
