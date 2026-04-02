#Requires -Modules Az.KeyVault
<#
.SYNOPSIS
    Validate Phase 04 management infrastructure configuration via Key Vault.
.DESCRIPTION
    Tests Key Vault write and read access, validates secret round-trips,
    and confirms expected secrets are accessible.
.PARAMETER ConfigPath
    Path to the YAML variables file. Defaults to ./config/variables.yml.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "./config/variables.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config   = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$kvName   = $config.azure.key_vault.name
$expected = $config.azure.key_vault.required_secrets   # array of secret names

$errors = 0

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Validating Phase 04 Key Vault Configuration"
Write-Host "======================================================" -ForegroundColor Cyan

# ── Write/read round-trip ────────────────────────────────────────────────────
Write-Host "`n[1/2] Key Vault write/read test: $kvName"
$testSecretName  = "config-validation-test"
$testSecretValue = ConvertTo-SecureString "validated-$(Get-Date -Format 'yyyyMMddHHmmss')" -AsPlainText -Force

try {
    Set-AzKeyVaultSecret -VaultName $kvName -Name $testSecretName -SecretValue $testSecretValue | Out-Null
    $readBack = (Get-AzKeyVaultSecret -VaultName $kvName -Name $testSecretName -AsPlainText)
    $expected_plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($testSecretValue))

    if ($readBack -eq $expected_plain) {
        Write-Host "  [PASS] Key Vault read/write round-trip verified" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Value mismatch on read-back" -ForegroundColor Red
        $errors++
    }
} catch {
    Write-Host "  [FAIL] Key Vault access error: $_" -ForegroundColor Red
    $errors++
}

# ── Verify required secrets exist ─────────────────────────────────────────────
Write-Host "`n[2/2] Checking required secrets in: $kvName"
foreach ($secretName in $expected) {
    try {
        $secret = Get-AzKeyVaultSecret -VaultName $kvName -Name $secretName -ErrorAction Stop
        if ($secret) {
            Write-Host "  [PASS] Secret exists: $secretName" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [FAIL] Secret missing: $secretName" -ForegroundColor Red
        $errors++
    }
}

# ── Summary ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================"
if ($errors -eq 0) {
    Write-Host " CONFIGURATION VALIDATION PASSED (0 errors)" -ForegroundColor Green
} else {
    Write-Host " CONFIGURATION VALIDATION FAILED ($errors errors)" -ForegroundColor Red
    exit 1
}
Write-Host "======================================================"
