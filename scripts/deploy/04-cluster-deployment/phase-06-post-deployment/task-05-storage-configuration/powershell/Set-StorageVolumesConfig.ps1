#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive helper: prompts for S2D Capacity Calculator outputs and writes
    the cluster_shared_volumes block into infrastructure.yml.

.DESCRIPTION
    Run this script from the toolkit repo root after completing the S2D Capacity
    Calculator (tools/planning/S2D_Capacity_Calculator_6.xlsx). It will:
      1. Read the existing infrastructure.yml (or the path you specify).
      2. Prompt for each required value — volume count, names, sizes, resiliency,
         and CSV cache settings.
      3. Auto-derive storage path names (sp- prefix) and paths from each volume name.
      4. Merge the cluster_shared_volumes block into the YAML and write it back.

    Existing values are pre-filled as defaults — press Enter to keep them.

.PARAMETER ConfigPath
    Path to the infrastructure YAML file.
    Defaults to configs\infrastructure.yml relative to the current working directory.
    Run this script from the repo root so the default resolves correctly.

.EXAMPLE
    # From the repo root:
    .\scripts\deploy\04-cluster-deployment\phase-06-post-deployment\task-05-storage-configuration\powershell\Set-StorageVolumesConfig.ps1

.EXAMPLE
    # With an explicit config path:
    .\scripts\...\Set-StorageVolumesConfig.ps1 -ConfigPath configs\infrastructure-iic01.yml

.NOTES
    Requires: powershell-yaml module  (Install-Module powershell-yaml -Scope CurrentUser)
#>

param(
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module powershell-yaml -ErrorAction Stop

if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

# Ensure top-level key exists
if (-not $cfg.ContainsKey('cluster_shared_volumes')) {
    $cfg['cluster_shared_volumes'] = @{}
}
$csv = $cfg['cluster_shared_volumes']

#region Helpers

function Prompt-Value {
    param(
        [string]$Label,
        $Current,
        [string]$Default = ""
    )
    $display = if ($null -ne $Current -and "$Current" -ne "") { $Current }
               elseif ($Default -ne "")                       { $Default }
               else                                           { $null }
    $hint    = if ($null -ne $display) { " [$display]" } else { "" }
    $input   = Read-Host "${Label}${hint}"
    if ([string]::IsNullOrWhiteSpace($input)) { return $display } else { return $input }
}

#endregion

Write-Host ""
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host " Storage Volume Configuration — Calculator Input" -ForegroundColor Cyan
Write-Host " Config: $ConfigPath" -ForegroundColor Cyan
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host " Press Enter to keep the current/default value." -ForegroundColor DarkGray
Write-Host ""

# ── Global settings ─────────────────────────────────────────

$csv['enabled'] = $true

Write-Host "Resiliency options: Mirror (default for ≤4 nodes) | Parity | MirrorAcceleratedParity"
$defaultResiliency = if ($csv.ContainsKey('volumes') -and $csv['volumes'].Count -gt 0) {
    $csv['volumes'][0]['resiliency']
} else { "Mirror" }
$globalResiliency = Prompt-Value -Label "Default resiliency for all volumes" -Current $defaultResiliency

Write-Host "Filesystem options: ReFS (strongly recommended) | NTFS"
$defaultFs = if ($csv.ContainsKey('volumes') -and $csv['volumes'].Count -gt 0) {
    $csv['volumes'][0]['filesystem']
} else { "ReFS" }
$globalFs = Prompt-Value -Label "Filesystem for all volumes" -Current $defaultFs

# ── Volume count ────────────────────────────────────────────

$existingCount = if ($csv.ContainsKey('volumes')) { $csv['volumes'].Count } else { 0 }
Write-Host ""
Write-Host "Number of volumes to create (Calculator output: typically equals node count, max 4)"
$volCountStr = Prompt-Value -Label "Number of CSV volumes" -Current $existingCount -Default "2"
$volCount    = [int]$volCountStr

# ── Per-volume prompts ───────────────────────────────────────

Write-Host ""
Write-Host ("-" * 56) -ForegroundColor DarkCyan
Write-Host " Volume definitions" -ForegroundColor DarkCyan
Write-Host ("-" * 56) -ForegroundColor DarkCyan

$volumes  = @()
$pathsMap = [ordered]@{}

$clusterName = $cfg.compute.azure_local.cluster_name           # compute.azure_local.cluster_name
$resShort    = switch ($globalResiliency) {
    "Mirror"                  { "m2" }
    "MirrorAcceleratedParity" { "map" }
    default                   { "par" }
}

for ($i = 1; $i -le $volCount; $i++) {
    Write-Host ""
    Write-Host "  Volume $i of $volCount" -ForegroundColor Cyan

    $defaultName  = "csv-${clusterName}-${resShort}-vmstore-prd-$('{0:D2}' -f $i)"
    $existingName = if ($existingCount -ge $i) { $csv['volumes'][$i-1]['volume_name'] } else { $defaultName }
    $volName      = Prompt-Value -Label "    volume_name (conv: csv-<cluster>-<res>-<purpose>-<seq>)" -Current $existingName

    $existingSize = if ($existingCount -ge $i) { $csv['volumes'][$i-1]['size_gb'] } else { "" }
    $sizeStr      = Prompt-Value -Label "    size_gb (usable capacity from Calculator)" -Current $existingSize
    $sizeGb       = [int]$sizeStr

    $volPath = "C:\ClusterStorage\${volName}"
    $vmPath  = "${volPath}\VMs"

    $volumes += [ordered]@{
        volume_name = $volName
        size_gb     = $sizeGb
        filesystem  = $globalFs
        resiliency  = $globalResiliency
        path        = $volPath
        purpose     = "VM storage"
    }

    # Auto-derive storage path name: replace "csv-" prefix with "sp-"
    $spName  = "sp-" + $volName.Substring(4)
    $pathKey = "vmstore_$('{0}' -f $i)"

    $pathsMap[$pathKey] = [ordered]@{
        name = $spName
        path = $vmPath
    }

    Write-Host "    → volume path  : $volPath" -ForegroundColor DarkGray
    Write-Host "    → storage path : $spName  →  $vmPath" -ForegroundColor DarkGray
}

# ── CSV Cache settings ───────────────────────────────────────

Write-Host ""
Write-Host ("-" * 56) -ForegroundColor DarkCyan
Write-Host " CSV Cache settings" -ForegroundColor DarkCyan
Write-Host ("-" * 56) -ForegroundColor DarkCyan
Write-Host "  CSV read cache consumes host RAM. Recommended for VDI / read-heavy workloads."

$cacheEnabledRaw = Prompt-Value -Label "  Enable CSV cache (true/false)" `
    -Current ($csv.ContainsKey('cache') ? $csv['cache']['enabled'] : $false)
$cacheEnabled = ($cacheEnabledRaw -eq "true" -or $cacheEnabledRaw -eq $true)

$cacheSizeMb = 1024
if ($cacheEnabled) {
    $cacheSizeRaw = Prompt-Value -Label "  cache size_mb per node (512–32768)" `
        -Current ($csv.ContainsKey('cache') ? $csv['cache']['size_mb'] : 1024)
    $cacheSizeMb = [int]$cacheSizeRaw
}

# ── Write back ───────────────────────────────────────────────

$csv['volumes']       = $volumes
$csv['storage_paths'] = $pathsMap
$csv['cache']         = [ordered]@{
    enabled     = $cacheEnabled
    size_mb     = $cacheSizeMb
    block_cache = $true
}
$csv['network'] = [ordered]@{
    preferred_network     = "Storage"
    csv_network_isolation = $true
}

$cfg['cluster_shared_volumes'] = $csv

$updatedYaml = $cfg | ConvertTo-Yaml
[System.IO.File]::WriteAllText($ConfigPath, $updatedYaml, [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host ("=" * 56) -ForegroundColor Green
Write-Host " cluster_shared_volumes written to:" -ForegroundColor Green
Write-Host " $ConfigPath" -ForegroundColor Green
Write-Host " Review the YAML before proceeding to Section 2." -ForegroundColor Green
Write-Host ("=" * 56) -ForegroundColor Green
Write-Host ""
Write-Host "Volumes defined:" -ForegroundColor White
foreach ($v in $volumes) {
    Write-Host ("  {0,-48}  {1,6} GB  {2}  {3}" -f $v['volume_name'], $v['size_gb'], $v['resiliency'], $v['filesystem']) -ForegroundColor Cyan
}
Write-Host ""
Write-Host "Storage paths defined:" -ForegroundColor White
foreach ($k in $pathsMap.Keys) {
    Write-Host ("  [{0}]  {1}  →  {2}" -f $k, $pathsMap[$k]['name'], $pathsMap[$k]['path']) -ForegroundColor Cyan
}
Write-Host ""
