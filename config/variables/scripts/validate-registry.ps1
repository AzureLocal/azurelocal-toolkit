#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RegistryPath = (Join-Path $PSScriptRoot '..\schema\master-registry.yaml')
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $RegistryPath)) {
    throw "Registry file not found: $RegistryPath"
}

function Get-YamlKeyPaths {
    param([string]$FilePath)

    $results = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.List[object]

    foreach ($line in Get-Content -Path $FilePath) {
        if ($line -match '^\s*#' -or $line -match '^\s*$' -or $line -match '^\s*-\s') { continue }

        if ($line -match '^(\s*)([A-Za-z0-9_\-]+):(?:\s|$)') {
            $indent = $Matches[1].Length
            $key = $Matches[2]

            while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
                $stack.RemoveAt($stack.Count - 1)
            }

            $stack.Add([PSCustomObject]@{Indent=$indent;Key=$key})
            $results.Add(($stack | ForEach-Object { $_.Key }) -join '.')
        }
    }

    return $results
}

$keyPaths = Get-YamlKeyPaths -FilePath $RegistryPath
if (-not ($keyPaths -contains '_metadata')) {
    throw "Registry validation failed: missing required _metadata section"
}

$dups = $keyPaths | Group-Object | Where-Object { $_.Count -gt 1 }
if ($dups.Count -gt 0) {
    $sample = ($dups | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', '
    Write-Warning "Potential duplicate key paths detected (can occur in YAML lists). Sample: $sample"
}

$aliasNodes = $keyPaths | Where-Object { $_ -match '\.aliases\.[A-Za-z0-9_\-]+$' }
$aliasNames = $aliasNodes | ForEach-Object { ($_ -split '\.')[-1] }
$aliasDupes = $aliasNames | Group-Object | Where-Object { $_.Count -gt 1 }
if ($aliasDupes.Count -gt 0) {
    $sample = ($aliasDupes | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', '
    throw "Registry validation failed: alias conflicts detected. Sample aliases: $sample"
}

Write-Output "PASS: Registry structure validation passed"
Write-Output "- Total key paths: $($keyPaths.Count)"
Write-Output "- Alias nodes found: $($aliasNodes.Count)"
