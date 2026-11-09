#Requires -Version 7.0
<#
.SYNOPSIS
    Generates the variable map: which variable goes where, who provides it, who reads it, what it becomes.

.DESCRIPTION
    The map is built from the master registry (config/variables/schema/master-registry.yaml) and from a scan of the code that reads
    the variables. Nothing in it is written by hand, so it cannot drift: -Check fails when a committed file differs.

    Writes:
      config/variables/docs/VARIABLE-MAP.md                              the readable map (views by phase, tool, ARM parameter; "where do I set X"; unread variables)
      config/variables/reports/variable-map.csv                          the machine copy, one row per registry leaf
      config/variables/reports/variable-map-external-readers.csv         the scan of azurelocal-ztp, azurelocal-sonar and Trailwright (separate repositories)

    The toolkit's scripts are scanned every time. The other three repositories are read from the committed snapshot, so the result is the
    same on a machine without those checkouts; -RescanExternal rescans them (from -ZtpRoot, -SonarRoot, -TrailwrightRoot, the environment
    variables AZL_ZTP_REPO, AZL_SONAR_REPO, AZL_TRAILWRIGHT_REPO, or the usual sibling folders) and refreshes the snapshot.

    With -Check nothing is written. The script exits 1 when a file is out of date; with -RescanExternal -Check it also compares the
    snapshot to the checkouts.

.PARAMETER Check
    Compare, do not write.

.PARAMETER RescanExternal
    Rescan azurelocal-ztp, azurelocal-sonar and Trailwright instead of reading the snapshot.

.PARAMETER RegistryPath
    Default: config/variables/schema/master-registry.yaml.

.EXAMPLE
    ./config/variables/scripts/New-VariableMap.ps1

.EXAMPLE
    ./config/variables/scripts/New-VariableMap.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$RescanExternal,
    [string]$RegistryPath,
    [string]$ZtpRoot,
    [string]$SonarRoot,
    [string]$TrailwrightRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VariableMap.psm1') -Force

$toolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$arguments = @{ ToolkitRoot = $toolkitRoot; RescanExternal = $RescanExternal; ZtpRoot = $ZtpRoot; SonarRoot = $SonarRoot; TrailwrightRoot = $TrailwrightRoot }
if ($RegistryPath) { $arguments['RegistryPath'] = $RegistryPath }
$out = Get-VariableMapOutput @arguments

$files = [ordered]@{
    (Join-Path $toolkitRoot 'config/variables/docs/VARIABLE-MAP.md')                          = $out.Markdown
    (Join-Path $toolkitRoot 'config/variables/reports/variable-map.csv')                      = $out.Csv
    (Join-Path $toolkitRoot 'config/variables/reports/variable-map-external-readers.csv')     = $out.External
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
    Write-Output "Wrote $path"
}

if ($Check) {
    if ($stale.Count) {
        $stale | ForEach-Object { Write-Error "Out of date: $_" -ErrorAction Continue }
        Write-Error 'Run ./config/variables/scripts/New-VariableMap.ps1 and commit the result.' -ErrorAction Continue
        exit 1
    }
    Write-Output "The variable map is current ($(@($out.Data.Row).Count) variables)."
}
else {
    Write-Output "$(@($out.Data.Row).Count) variables mapped."
}
