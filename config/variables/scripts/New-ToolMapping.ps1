#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the mapping from a tool's own names to registry paths, for a tool that lives outside this repository.

.DESCRIPTION
    azurelocal-ztp, azurelocal-sonar, azurelocal-ranger, azurelocal-loadtools, azurelocal-draftsman and azurelocal-trailwright are separate repositories. Their variables (script parameters, config-file keys, events,
    state and handoff fields, secret names, environment variables) are registered in the master registry under
    tools.<tool>.<kind>.<group>.<name>. This script lists them as a CSV, one row per variable: the tool, the kind, the group
    (the script, file or feed), the name as the tool writes it, the registry path and where the tool reads it.

    The CSV is committed in config/variables/tool-mappings/. tests/variables/ToolRegistry.Tests.ps1 fails when it is out of date
    or when a row names a registry path that does not exist. With -Check nothing is written and the script exits 1 when the file
    on disk differs.

.PARAMETER Tool
    One or more of: os_configuration, ztp, sonar, arm_deployment, cicd_infra, discovery, ranger, loadtools, draftsman, trailwright. Default: ztp, sonar, ranger, loadtools, draftsman and trailwright (the tools that live in other repositories).

.PARAMETER OutputDirectory
    Default: config/variables/tool-mappings.

.PARAMETER Check
    Compare instead of write.

.EXAMPLE
    ./config/variables/scripts/New-ToolMapping.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('os_configuration', 'ztp', 'sonar', 'arm_deployment', 'cicd_infra', 'discovery', 'ranger', 'loadtools', 'draftsman', 'trailwright')][string[]]$Tool = @('ztp', 'sonar', 'ranger', 'loadtools', 'draftsman', 'trailwright'),
    [string]$RegistryPath = (Join-Path $PSScriptRoot '../schema/master-registry.yaml'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../tool-mappings'),
    [object[]]$Registry,
    [switch]$Check
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VariableRegistry.psm1') -Force
if (-not $Registry) { $Registry = @(Get-RegistryVariable -Path $RegistryPath) }
$byPath = @{}; foreach ($r in $Registry) { $byPath[$r.Path] = $r }

$stale = $false
foreach ($t in $Tool) {
    $rows = foreach ($r in $Registry) {
        if ($r.Path -notmatch "^tools\.$t\.(?<kind>[^.]+)\.(?<group>[^.]+)\.(?<name>[^.]+)$") { continue }
        if (-not $r.Node.Contains('name')) { continue }
        $group = $byPath["tools.$t.$($Matches['kind']).$($Matches['group'])"]
        [pscustomobject][ordered]@{
            tool          = $t
            kind          = $Matches['kind']
            group         = $(if ($group -and $group.Node.Contains('area')) { [string]$group.Node['area'] } else { $Matches['group'] })
            name          = [string]$r.Node['name']
            registry_path = $r.Path
            read_at       = $(if ($r.Node.Contains('read_at')) { [string]$r.Node['read_at'] } else { '' })
        }
    }
    $csv = (@($rows) | ConvertTo-Csv -NoTypeInformation) -join "`n"
    $file = Join-Path $OutputDirectory "$t.csv"
    if ($Check) {
        $current = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file).Replace("`r`n", "`n").TrimEnd("`n") } else { '' }
        if ($current -ne $csv) { Write-Error "$file is out of date. Run ./config/variables/scripts/New-ToolMapping.ps1"; $stale = $true }
        else { Write-Host "$file is current ($(@($rows).Count) variables)." }
        continue
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory }
    [IO.File]::WriteAllText($file, $csv + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $file ($(@($rows).Count) variables)"
}
if ($stale) { exit 1 }
