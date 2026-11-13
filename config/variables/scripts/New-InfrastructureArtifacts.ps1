#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the infrastructure.yml schema, the master template, and one template and one schema per tool, from the master registry.

.DESCRIPTION
    config/variables/schema/master-registry.yaml is the master of every variable. Nothing below is edited by hand:

    * schema/infrastructure.schema.json         the full schema of infrastructure.yml (the validator reads this one)
    * schema/tools/<tool>.schema.json           the part of the schema one tool reads (or, for Trailwright, writes)
    * templates/infrastructure.master.yml       every variable, with comments and allowed values
    * templates/scenarios/master.<key>-<value>.yml   the master for one scenario choice (scenario.identity: local_identity, ...)
    * templates/tools/<tool>.yml                only the variables one tool reads: a strict subset of the master
    * docs/VARIABLES.md                         the variables reference (New-InfrastructureVariablesReference.ps1, run at the end)

    The tools are the ones in the registry section _tool_catalog. A tool gets a template and a schema when at least one key of
    infrastructure.yml names it in used_by; a tool that reads no key gets none. The file name is the tool id with hyphens for
    underscores (os_configuration: os-configuration.yml).

    The curated worked examples (config/variables/examples/*.yml) are written by hand and tested against the schema and the rules.

    -Check regenerates everything in memory and exits 1 when a file on disk differs, or when a file in templates/tools or
    schema/tools belongs to no tool (the Pester tests run this).
    -Cut <tool> -From <infrastructure.yml> -Out <file> cuts a real file down to what one tool reads, for example the file
    azurelocal-ztp or Sonar validates against its tool schema.

.PARAMETER RegistryPath
    Default: config/variables/schema/master-registry.yaml.

.PARAMETER Check
    Compare, do not write.

.PARAMETER Cut
    A tool id from _tool_catalog that has keys: ztp, os_configuration, deployment, cicd_infra, monitoring (Sonar), discovery,
    trailwright, ranger.

.PARAMETER From
    With -Cut: the infrastructure.yml to cut.

.PARAMETER Out
    With -Cut: where to write the cut file. Default: next to -From, named <name>.<tool>.yml.

.EXAMPLE
    ./config/variables/scripts/New-InfrastructureArtifacts.ps1

.EXAMPLE
    ./config/variables/scripts/New-InfrastructureArtifacts.ps1 -Cut ztp -From ./infrastructure.yml -Out ./infrastructure.ztp.yml
#>
[CmdletBinding(DefaultParameterSetName = 'Generate')]
param(
    [string]$RegistryPath = (Join-Path $PSScriptRoot '../schema/master-registry.yaml'),
    [Parameter(ParameterSetName = 'Generate')][switch]$Check,
    [Parameter(ParameterSetName = 'Cut', Mandatory)][string]$Cut,
    [Parameter(ParameterSetName = 'Cut', Mandatory)][string]$From,
    [Parameter(ParameterSetName = 'Cut')][string]$Out
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'InfrastructureArtifacts.psm1') -Force

$variablesRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../../..')
$registry = Get-RegistryDocument -Path $RegistryPath
$tools = @(Get-ToolWithKey -Registry $registry)

if ($PSCmdlet.ParameterSetName -eq 'Cut') {
    if ($Cut -notin $tools) {
        $known = @((Get-ToolCatalog -Registry $registry).Keys)
        if ($Cut -in $known) { throw "The tool '$Cut' reads no key of infrastructure.yml, so there is nothing to cut. See its note in _tool_catalog." }
        throw "Unknown tool '$Cut'. Tools with keys: $($tools -join ', ')."
    }
    $doc = ConvertFrom-Yaml (Get-Content -LiteralPath $From -Raw) -Ordered
    $result = Select-InfrastructureTool -Registry $registry -Document $doc -Tool $Cut
    if (-not $Out) { $Out = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $From)) ("{0}.{1}.yml" -f [IO.Path]::GetFileNameWithoutExtension($From), ($Cut -replace '_', '-')) }
    $header = "# Cut from $(Split-Path -Leaf $From) for the tool '$Cut' by New-InfrastructureArtifacts.ps1 -Cut. Validate against schema/tools/$($Cut -replace '_', '-').schema.json.`n"
    [IO.File]::WriteAllText($Out, $header + (ConvertTo-Yaml $result), [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $Out"
    return
}

function ConvertTo-JsonText($Object, [string]$Comment) {
    if ($Comment) { $Object = [ordered]@{ '$comment' = $Comment } + $Object }
    return ((ConvertTo-Json -InputObject $Object -Depth 100) -replace "`r`n", "`n") + "`n"
}

$generatedNote = 'GENERATED from config/variables/schema/master-registry.yaml by config/variables/scripts/New-InfrastructureArtifacts.ps1. Do not edit: change the registry and run the generator.'
$files = [ordered]@{}   # absolute path -> text

# schemas
$fullSchema = Get-InfrastructureSchemaFromRegistry -Registry $registry
$files[(Join-Path $variablesRoot 'schema/infrastructure.schema.json')] = ConvertTo-JsonText $fullSchema $generatedNote
foreach ($t in $tools) {
    $files[(Join-Path $variablesRoot "schema/tools/$($t -replace '_', '-').schema.json")] = ConvertTo-JsonText (Get-InfrastructureSchemaFromRegistry -Registry $registry -Tool $t) $generatedNote
}

# templates
$masterText = Get-InfrastructureTemplateText -Registry $registry
$files[(Join-Path $variablesRoot 'templates/infrastructure.master.yml')] = $masterText
foreach ($t in $tools) {
    $files[(Join-Path $variablesRoot "templates/tools/$($t -replace '_', '-').yml")] = Get-InfrastructureTemplateText -Registry $registry -Tool $t
}
$scenario = $registry['scenario']['properties']
foreach ($key in $scenario.Keys) {
    $entry = $scenario[$key]
    if (-not $entry.Contains('enum')) { continue }
    foreach ($value in $entry['enum']) {
        $text = Get-InfrastructureTemplateText -Registry $registry -Scenario @{ $key = [string]$value } -Title "infrastructure.yml for scenario.$key = $value"
        # a choice that changes nothing in the file (cloud, deploy_method, environment_class) has no scenario file
        $sameAsMaster = ((@($text -split "`n") | Select-Object -Skip 4) -join "`n") -ceq ((@($masterText -split "`n") | Select-Object -Skip 4) -join "`n")
        if ($sameAsMaster) { continue }
        $files[(Join-Path $variablesRoot "templates/scenarios/master.$($key -replace '_', '-')-$($value -replace '_', '-').yml")] = $text
    }
}

# one spelling of each path (the keys above mix / and \)
$normalized = [ordered]@{}
foreach ($k in $files.Keys) { $normalized[[IO.Path]::GetFullPath($k)] = $files[$k] }
$files = $normalized

# a file in a tools folder that no tool owns any more (a tool lost its last key, or was renamed)
$orphans = @()
foreach ($spec in @(@{ Dir = 'templates/tools'; Filter = '*.yml' }, @{ Dir = 'schema/tools'; Filter = '*.json' })) {
    $dir = Join-Path $variablesRoot $spec.Dir
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Filter $spec.Filter)) {
        if (-not $files.Contains($f.FullName)) { $orphans += $f.FullName }
    }
}

$stale = @()
foreach ($path in $files.Keys) {
    $text = $files[$path]
    $current = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path).Replace("`r`n", "`n") } else { $null }
    if ($Check) {
        if ($current -ne $text) { $stale += $path }
        continue
    }
    if ($current -eq $text) { continue }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $path"
}
foreach ($path in $orphans) {
    if ($Check) { $stale += $path; continue }
    Remove-Item -LiteralPath $path -Force
    Write-Host "Removed $path (no tool owns it)"
}

$reference = Join-Path $repoRoot 'config/variables/scripts/New-InfrastructureVariablesReference.ps1'
if ($Check) {
    $global:LASTEXITCODE = 0
    & $reference -Check *>$null
    if ($LASTEXITCODE -ne 0) { $stale += (Join-Path $variablesRoot 'docs/VARIABLES.md') }
    if ($stale.Count) {
        $stale | ForEach-Object { Write-Error "Out of date: $_" -ErrorAction Continue }
        Write-Error 'Run ./config/variables/scripts/New-InfrastructureArtifacts.ps1 and commit the result.'
        exit 1
    }
    Write-Host "All $($files.Count) generated files are current."
}
else {
    & $reference
}
