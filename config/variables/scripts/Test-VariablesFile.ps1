#Requires -Version 7.0
<#
.SYNOPSIS
    Validates a variables file against variables.schema.json and the master registry, in PowerShell (no Python).

.DESCRIPTION
    The same two checks as validate-variables.ps1, which needs Python with PyYAML and jsonschema:

    1. The file is valid against variables.schema.json (types, enums, required keys).
    2. Every key path in the file is known to the registry (a registry variable, a legacy-compatible root, or on the drift
       allowlist). Unknown paths are listed; with -StrictUnknown they fail the run.

    validate-variables.ps1 calls this script when Python is not installed.

.PARAMETER VariablesPath
    The file to check. Default: config/variables/variables.example.yml.

.PARAMETER StrictUnknown
    Exit 1 when a path is not in the registry.

.EXAMPLE
    ./config/variables/scripts/Test-VariablesFile.ps1 -StrictUnknown
#>
[CmdletBinding()]
param(
    [string]$VariablesPath = (Join-Path $PSScriptRoot '../variables.example.yml'),
    [string]$RegistryPath = (Join-Path $PSScriptRoot '../schema/master-registry.yaml'),
    [string]$SchemaPath = (Join-Path $PSScriptRoot '../schema/variables.schema.json'),
    [string]$LegacyRootsPath = (Join-Path $PSScriptRoot '../schema/legacy-compatible-roots.json'),
    [string]$CanonicalDriftAllowlistPath = (Join-Path $PSScriptRoot '../schema/canonical-drift-allowlist.json'),
    [string]$UnknownReportCsv = (Join-Path $PSScriptRoot '../reports/canonical-unknown-paths.csv'),
    [switch]$StrictUnknown
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'VariableRegistry.psm1') -Force

foreach ($p in @($VariablesPath, $RegistryPath, $SchemaPath, $LegacyRootsPath, $CanonicalDriftAllowlistPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required file not found: $p" }
}

$variables = Read-RegistryYaml -Path $VariablesPath
if ($variables -isnot [System.Collections.IDictionary]) { throw 'variables file must deserialize to a YAML mapping' }

# 1. schema
$json = $variables | ConvertTo-Json -Depth 100
$errors = $null
if (-not (Test-Json -Json $json -Schema (Get-Content -LiteralPath $SchemaPath -Raw) -ErrorVariable errors -ErrorAction SilentlyContinue)) {
    throw "Schema validation failed: $(($errors | ForEach-Object { $_.Exception.Message }) -join '; ')"
}
Write-Host 'PASS: schema validation passed'

# 2. unknown paths
function Get-DataPath($Obj, [string]$Prefix, [System.Collections.Generic.HashSet[string]]$Into) {
    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($k in $Obj.Keys) {
            $p = if ($Prefix) { "$Prefix.$k" } else { [string]$k }
            [void]$Into.Add($p)
            Get-DataPath $Obj[$k] $p $Into
        }
    } elseif ($Obj -is [System.Collections.IList]) {
        foreach ($item in $Obj) { Get-DataPath $item "$Prefix[]" $Into }
    }
}
$dataPaths = [System.Collections.Generic.HashSet[string]]::new()
Get-DataPath $variables '' $dataPaths

$registry = Get-RegistryVariable -Path $RegistryPath
$direct = [System.Collections.Generic.HashSet[string]]::new()
$wild = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $registry) {
    [void]$direct.Add($r.Path)
    # a list item path: "x[]" is the list "x"
    if ($r.Path -match '\.\*') { [void]$wild.Add($r.Path) }
    [void]$direct.Add(($r.Path -replace '\[\]$', ''))
}
$legacyRoots = @((Get-Content -LiteralPath $LegacyRootsPath -Raw | ConvertFrom-Json).roots)
$allow = @((Get-Content -LiteralPath $CanonicalDriftAllowlistPath -Raw | ConvertFrom-Json).paths)

function Test-Known([string]$Path) {
    if ($direct.Contains($Path)) { return $true }
    $parts = $Path -split '\.'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $cand = (@($parts[0..($i - 1)] | Where-Object { $_ }) + '*' + @($(if ($i + 1 -lt $parts.Count) { $parts[($i + 1)..($parts.Count - 1)] }))) -join '.'
        if ($wild.Contains($cand)) { return $true }
    }
    return $false
}
$unknown = foreach ($p in ($dataPaths | Sort-Object)) {
    $root = ($p -split '[.\[]')[0]
    if ($p -like '_metadata.*' -or $legacyRoots -contains $root -or $allow -contains $p) { continue }
    if (-not (Test-Known $p)) { $p }
}
$unknown = @($unknown)
if ($unknown.Count) {
    Write-Warning "canonical unknown variable paths not found in registry: $($unknown.Count)"
    $unknown | Select-Object -First 20 | ForEach-Object { Write-Host "  - $_" }
    $dir = Split-Path -Parent $UnknownReportCsv
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    (@('path') + $unknown) | Set-Content -LiteralPath $UnknownReportCsv -Encoding utf8
    if ($StrictUnknown) { throw 'Unknown variable paths detected (strict mode)' }
} else {
    Write-Host 'PASS: no canonical unknown variable paths'
}
Write-Host "Variables key paths: $($dataPaths.Count)"
Write-Host "Registry variables: $($registry.Count)"
