#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$WorkspaceRoot = "E:\git",
    [string]$OutputRoot = "E:\git\azurelocal-toolkit\config\variables\reports"
)

$ErrorActionPreference = "Stop"

$repoFiles = @{
    "azurelocal-toolkit"              = @("config/variables/variables.example.yml")
    "azurelocal-avd"                  = @("config/variables.example.yml")
    "azurelocal-sofs-fslogix"         = @("config/variables.example.yml")
    "azurelocal-loadtools"            = @("config/variables.example.yml", "config/variables/variables.yml")
    "azurelocal-vm-conversion-toolkit"= @("config/variables.example.yml")
}

function Get-YamlKeyPaths {
    param(
        [string]$FilePath
    )

    $results = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.List[object]

    foreach ($line in Get-Content -Path $FilePath) {
        if ($line -match '^\s*#' -or $line -match '^\s*$' -or $line -match '^\s*-\s') {
            continue
        }

        if ($line -match '^(\s*)([A-Za-z0-9_\-]+):(?:\s|$)') {
            $indent = $Matches[1].Length
            $key = $Matches[2]

            while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
                $stack.RemoveAt($stack.Count - 1)
            }

            $entry = [PSCustomObject]@{
                Indent = $indent
                Key    = $key
            }
            $stack.Add($entry)

            $path = ($stack | ForEach-Object { $_.Key }) -join '.'
            $results.Add($path)
        }
    }

    return $results
}

if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$inventory = New-Object System.Collections.Generic.List[object]

foreach ($repoName in $repoFiles.Keys) {
    $repoPath = Join-Path $WorkspaceRoot $repoName

    foreach ($relativeFile in $repoFiles[$repoName]) {
        $fullPath = Join-Path $repoPath $relativeFile
        if (-not (Test-Path $fullPath)) {
            Write-Warning "Missing file: $fullPath"
            continue
        }

        $paths = Get-YamlKeyPaths -FilePath $fullPath
        foreach ($path in $paths) {
            $inventory.Add([PSCustomObject]@{
                repo = $repoName
                file = $relativeFile
                key_path = $path
            })
        }
    }
}

$inventory = $inventory | Sort-Object repo, file, key_path -Unique

$csvPath = Join-Path $OutputRoot "variable-inventory.csv"
$jsonPath = Join-Path $OutputRoot "variable-inventory.json"
$summaryPath = Join-Path $OutputRoot "variable-inventory-summary.txt"

$inventory | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$inventory | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonPath -Encoding UTF8

$repoSummary = $inventory | Group-Object repo | ForEach-Object {
    [PSCustomObject]@{
        repo = $_.Name
        key_count = $_.Count
    }
}

$totalKeys = $inventory.Count
$uniqueKeyPaths = ($inventory | Select-Object -ExpandProperty key_path -Unique).Count

$lines = @()
$lines += "Variable Inventory Summary"
$lines += "Generated: $(Get-Date -Format s)"
$lines += "Total key entries: $totalKeys"
$lines += "Unique key paths: $uniqueKeyPaths"
$lines += ""
$lines += "Per-repo counts:"
foreach ($row in $repoSummary) {
    $lines += "- $($row.repo): $($row.key_count)"
}

$lines | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host "Wrote: $csvPath"
Write-Host "Wrote: $jsonPath"
Write-Host "Wrote: $summaryPath"
Write-Host "Total key entries: $totalKeys"
Write-Host "Unique key paths: $uniqueKeyPaths"
