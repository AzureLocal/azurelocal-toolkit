#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RegistryPath
)

$ErrorActionPreference = "Stop"

if (-not $RegistryPath) {
    $RegistryPath = Join-Path $PSScriptRoot '../schema/master-registry.yaml'
}

if (-not (Test-Path $RegistryPath)) {
    throw "Registry file not found: $RegistryPath"
}

$lines = Get-Content -Path $RegistryPath
$expiryPattern = 'expires_on\s*:\s*"?(\d{4}-\d{2}-\d{2})"?'
$today = Get-Date
$expired = @()

foreach ($line in $lines) {
    if ($line -match $expiryPattern) {
        $dateText = $Matches[1]
        $expiry = [datetime]::ParseExact($dateText, 'yyyy-MM-dd', $null)
        if ($expiry -lt $today.Date) {
            $expired += $dateText
        }
    }
}

if ($expired.Count -gt 0) {
    throw "Alias expiry check failed: found $($expired.Count) expired alias entries"
}

Write-Host "PASS: alias expiry check passed"
