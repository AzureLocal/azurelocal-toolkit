#Requires -Version 7.0
<#
.SYNOPSIS
    Lists every key of infrastructure.schema.json and says whether the master registry has it, lacks it, or disagrees.

.DESCRIPTION
    The registry (config/variables/schema/master-registry.yaml) is the master of every variable. Run this after any change to
    infrastructure.schema.json, or to the registry, to see the gap. Status per key:

    * ok        the registry has the key and agrees on shape, type, enum, default and constraints.
    * missing   the schema has the key, the registry does not. Register it in the registry first.
    * conflict  both have it and they differ (the Problems column says how).

    Writes a CSV (path, status, registry and schema type, enum, default, since, problems). The same check runs as a test
    (tests/variables/RegistryFirst.Tests.ps1): a key in the schema that the registry lacks fails the suite.

.PARAMETER RegistryPath
    The registry. Default: config/variables/schema/master-registry.yaml.

.PARAMETER SchemaPath
    The generated schema. Default: config/variables/schema/infrastructure.schema.json.

.PARAMETER OutputCsv
    The report. Default: config/variables/reports/infrastructure-vs-registry.csv.

.PARAMETER FailOnGap
    Exit 1 when any key is missing or in conflict.

.EXAMPLE
    ./config/variables/scripts/Compare-InfrastructureSchemaToRegistry.ps1 -FailOnGap
#>
[CmdletBinding()]
param(
    [string]$RegistryPath = (Join-Path $PSScriptRoot '../schema/master-registry.yaml'),
    [string]$SchemaPath = (Join-Path $PSScriptRoot '../schema/infrastructure.schema.json'),
    [string]$OutputCsv = (Join-Path $PSScriptRoot '../reports/infrastructure-vs-registry.csv'),
    [switch]$FailOnGap
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VariableRegistry.psm1') -Force

$registry = @(Get-RegistryVariable -Path $RegistryPath)
$schema = @(Get-InfrastructureSchemaVariable -SchemaPath $SchemaPath)
$cmp = Compare-RegistryToSchema -Registry $registry -Schema $schema

$byPath = @{}; foreach ($r in $registry) { $byPath[$r.Path] = $r }
$missing = @{}; foreach ($m in $cmp.Missing) { $missing[$m.Path] = $true }
$conflict = @{}; foreach ($c in $cmp.Conflict) { $conflict[$c.Path] = $c.Problems }

$rows = foreach ($s in $schema) {
    $status = if ($missing.ContainsKey($s.Path)) { 'missing' } elseif ($conflict.ContainsKey($s.Path)) { 'conflict' } else { 'ok' }
    $r = if ($byPath.ContainsKey($s.Path)) { $byPath[$s.Path] } else { $null }
    [pscustomobject][ordered]@{
        path          = $s.Path
        status        = $status
        schema_type   = $s.Type
        registry_type = $(if ($r) { $r.Type } else { '' })
        schema_enum   = $(if ($s.Enum) { $s.Enum } else { $s.ItemEnum })
        registry_enum = $(if ($r) { $r.Enum } else { '' })
        schema_default = $(if ($s.HasDefault) { "$($s.Default)" } else { '' })
        registry_default = $(if ($r -and $r.HasDefault) { "$($r.Default)" } else { '' })
        since         = $s.Since
        problems      = $(if ($conflict.ContainsKey($s.Path)) { $conflict[$s.Path] } else { '' })
    }
}
$dir = Split-Path -Parent $OutputCsv
if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
$rows | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding utf8

$counts = $rows | Group-Object status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "Schema keys: $($schema.Count); registry variables: $($registry.Count); $($counts -join ', ')"
Write-Host "Wrote $OutputCsv"
if ($FailOnGap -and ($cmp.Missing.Count -or $cmp.Conflict.Count)) { exit 1 }
