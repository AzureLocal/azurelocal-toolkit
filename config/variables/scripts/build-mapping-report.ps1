#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$InventoryCsv = "E:\git\azurelocal-toolkit\config\variables\reports\variable-inventory.csv",
    [string]$OutputRoot = "E:\git\azurelocal-toolkit\config\variables\reports"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InventoryCsv)) {
    throw "Inventory file not found: $InventoryCsv. Run inventory-repo-variables.ps1 first."
}

if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$rows = Import-Csv -Path $InventoryCsv

$sharedPaths = $rows |
    Group-Object key_path |
    Where-Object { ($_.Group.repo | Select-Object -Unique).Count -gt 1 } |
    ForEach-Object {
        [PSCustomObject]@{
            key_path = $_.Name
            repo_count = ($_.Group.repo | Select-Object -Unique).Count
            repos = (($_.Group.repo | Select-Object -Unique) -join ',')
        }
    } |
    Sort-Object -Property repo_count, key_path -Descending

$leafRows = $rows | ForEach-Object {
    $leaf = ($_.key_path -split '\.')[-1]
    [PSCustomObject]@{
        repo = $_.repo
        file = $_.file
        key_path = $_.key_path
        leaf = $leaf
    }
}

$leafCollisions = $leafRows |
    Group-Object leaf |
    Where-Object {
        ($_.Group.key_path | Select-Object -Unique).Count -gt 1 -and
        ($_.Group.repo | Select-Object -Unique).Count -gt 1
    } |
    ForEach-Object {
        [PSCustomObject]@{
            leaf = $_.Name
            path_count = ($_.Group.key_path | Select-Object -Unique).Count
            repo_count = ($_.Group.repo | Select-Object -Unique).Count
            key_paths = (($_.Group.key_path | Select-Object -Unique) -join ';')
            repos = (($_.Group.repo | Select-Object -Unique) -join ',')
        }
    } |
    Sort-Object -Property path_count, repo_count, leaf -Descending

$unmappedTemplate = $rows |
    Select-Object repo, file, key_path,
        @{Name='canonical_key_path';Expression={''}},
        @{Name='classification';Expression={''}},
        @{Name='notes';Expression={''}}

$sharedPathFile = Join-Path $OutputRoot "shared-key-paths.csv"
$leafCollisionFile = Join-Path $OutputRoot "leaf-collisions.csv"
$mappingTemplateFile = Join-Path $OutputRoot "canonical-mapping-template.csv"
$summaryFile = Join-Path $OutputRoot "mapping-report-summary.txt"

$sharedPaths | Export-Csv -Path $sharedPathFile -NoTypeInformation -Encoding UTF8
$leafCollisions | Export-Csv -Path $leafCollisionFile -NoTypeInformation -Encoding UTF8
$unmappedTemplate | Export-Csv -Path $mappingTemplateFile -NoTypeInformation -Encoding UTF8

$lines = @()
$lines += "Mapping Report Summary"
$lines += "Generated: $(Get-Date -Format s)"
$lines += "Source inventory: $InventoryCsv"
$lines += ""
$lines += "Total inventory rows: $($rows.Count)"
$lines += "Shared key paths across repos: $($sharedPaths.Count)"
$lines += "Leaf collisions across repos: $($leafCollisions.Count)"
$lines += ""
$lines += "Outputs:"
$lines += "- $sharedPathFile"
$lines += "- $leafCollisionFile"
$lines += "- $mappingTemplateFile"

$lines | Set-Content -Path $summaryFile -Encoding UTF8

Write-Host "Wrote: $sharedPathFile"
Write-Host "Wrote: $leafCollisionFile"
Write-Host "Wrote: $mappingTemplateFile"
Write-Host "Wrote: $summaryFile"
Write-Host "Shared key paths: $($sharedPaths.Count)"
Write-Host "Leaf collisions: $($leafCollisions.Count)"
