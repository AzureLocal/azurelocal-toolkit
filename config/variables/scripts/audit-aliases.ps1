<#
.SYNOPSIS
    Audit aliases in the master registry against the alias policy.

.DESCRIPTION
    Scans master-registry.yaml for alias_for entries and validates them
    against alias-policy.json. Reports:
    - Aliases in registry not tracked in policy
    - Policy aliases not found in registry
    - Expired aliases (older than max_alias_age_days)
    - Retired aliases that still exist in registry

.PARAMETER RegistryPath
    Path to master-registry.yaml.

.PARAMETER PolicyPath
    Path to alias-policy.json.

.PARAMETER Strict
    Fail on any policy violation.
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RegistryPath = "E:\git\azurelocal-toolkit\config\variables\schema\master-registry.yaml",
    [string]$PolicyPath = "E:\git\azurelocal-toolkit\config\variables\schema\alias-policy.json",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

foreach ($p in @($RegistryPath, $PolicyPath)) {
    if (-not (Test-Path $p)) { throw "File not found: $p" }
}

# Extract aliases from registry using Python
$pyScript = @"
import yaml, json, sys
def extract_aliases(node, path=""):
    if not isinstance(node, dict): return {}
    result = {}
    for k, v in node.items():
        if k in ("_meta", "infrastructure_type"): continue
        cp = f"{path}.{k}" if path else k
        if isinstance(v, dict):
            if "alias_for" in v:
                result[cp] = str(v["alias_for"])
            result.update(extract_aliases(v, cp))
    return result
with open(sys.argv[1], encoding="utf-8") as f:
    reg = yaml.safe_load(f)
print(json.dumps(extract_aliases(reg or {})))
"@

$env:PYTHONIOENCODING = 'utf-8'
$registryAliasesJson = python -c $pyScript $RegistryPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract aliases from registry: $registryAliasesJson"
}
$registryAliases = $registryAliasesJson | ConvertFrom-Json -AsHashtable

$policy = Get-Content -Raw $PolicyPath | ConvertFrom-Json
$policyAliases = @{}
foreach ($a in $policy.active_aliases) {
    $policyAliases[$a.alias_path] = $a
}
$retiredPaths = @{}
foreach ($r in $policy.retired_aliases) {
    $retiredPaths[$r.alias_path] = $r
}
$deprecatedKeys = @{}
foreach ($d in $policy.deprecated_keys) {
    $deprecatedKeys[$d] = $true
}

$violations = @()
$warnings = @()

# Check 1: Aliases in registry not tracked in policy
foreach ($alias in $registryAliases.Keys) {
    if (-not $policyAliases.ContainsKey($alias)) {
        $violations += "UNTRACKED: Alias '$alias' -> '$($registryAliases[$alias])' exists in registry but not in alias-policy.json"
    }
}

# Check 2: Policy aliases not found in registry
foreach ($alias in $policyAliases.Keys) {
    if (-not $registryAliases.ContainsKey($alias)) {
        $warnings += "MISSING: Alias '$alias' tracked in policy but not found in registry"
    }
}

# Check 3: Retired aliases still in registry
foreach ($alias in $retiredPaths.Keys) {
    if ($registryAliases.ContainsKey($alias)) {
        $violations += "RETIRED: Alias '$alias' was retired but still exists in registry"
    }
}

# Check 4: Alias expiry
$maxAge = $policy.rules.max_alias_age_days
$today = Get-Date
foreach ($alias in $policyAliases.Keys) {
    $entry = $policyAliases[$alias]
    if ($entry.created) {
        $created = [datetime]::Parse($entry.created)
        $age = ($today - $created).Days
        if ($age -gt $maxAge) {
            $warnings += "EXPIRED: Alias '$alias' is $age days old (max: $maxAge days, created: $($entry.created))"
        }
    }
}

# Check 5: Frozen aliases
if ($policy.rules.new_aliases_frozen) {
    $registryOnly = $registryAliases.Keys | Where-Object { -not $policyAliases.ContainsKey($_) }
    foreach ($alias in $registryOnly) {
        $violations += "FROZEN: New alias '$alias' added while alias creation is frozen"
    }
}

# Report
Write-Host "`n=== Alias Policy Audit ===" -ForegroundColor Cyan
Write-Host "Registry aliases: $($registryAliases.Count)"
Write-Host "Policy tracked:   $($policyAliases.Count)"
Write-Host "Retired:          $($retiredPaths.Count)"

if ($warnings) {
    Write-Host "`nWarnings:" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "  $w" -ForegroundColor Yellow }
}

if ($violations) {
    Write-Host "`nViolations:" -ForegroundColor Red
    foreach ($v in $violations) { Write-Host "  $v" -ForegroundColor Red }
    if ($Strict) {
        throw "Alias policy violations found ($($violations.Count))"
    }
} else {
    Write-Host "`nPASS: No alias policy violations" -ForegroundColor Green
}

if (-not $warnings -and -not $violations) {
    Write-Host "PASS: Alias audit clean" -ForegroundColor Green
}
