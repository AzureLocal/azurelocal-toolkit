<#
.SYNOPSIS
    Runs Task 01 AD validation remotely on an Azure VM via Invoke-AzVMRunCommand.

.DESCRIPTION
    Validates only the artifacts created by Task 01 (New-HciAdObjectsPreCreation):
      - KDS Root Key
      - Organizational Unit (OU)
      - LCM user account

    Uses Invoke-AzVMRunCommand to execute on the domain controller VM. No RDP, VPN,
    or direct network connectivity required — commands are sent through the Azure fabric.

.PARAMETER ConfigFile
    Path to the infrastructure.yml configuration file (local path).
    Config values are extracted locally and passed as parameters to the remote script.

.PARAMETER ResourceGroupName
    Azure resource group containing the target VM.
    If not specified, reads from config: azure_vms.dc01.resource_group

.PARAMETER VMName
    Azure VM name of the domain controller.
    If not specified, reads from config: azure_vms.dc01.name

.EXAMPLE
    .\Invoke-ADValidation-AzVM.ps1 -ConfigFile "..\..\..\..\configs\infrastructure-azl-lab.yml"

.EXAMPLE
    .\Invoke-ADValidation-AzVM.ps1 -ConfigFile ".\infrastructure-azl-lab.yml" -ResourceGroupName "rg-azrlmgmt-dev-eus-01" -VMName "vm-azrldc-dev-eus-01"

.NOTES
    Requires: Az.Compute module, authenticated Azure session (Connect-AzAccount)
    Role: Contributor or Virtual Machine Contributor on the target VM
    Author: AzureLocal Cloud Team Team
    Version: 1.1.0
    Created: 2026-02-27
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VMName
)

$ErrorActionPreference = "Stop"

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================
Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
Import-Module powershell-yaml -ErrorAction Stop
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Yaml

# Resolve VM target from config if not specified
if (-not $ResourceGroupName) {
    $ResourceGroupName = $config.compute.azure_vms.dc01.resource_group
    if (-not $ResourceGroupName) {
        Write-Host "ERROR: -ResourceGroupName not specified and not found in config (azure_vms.dc01.resource_group)" -ForegroundColor Red
        exit 1
    }
}

if (-not $VMName) {
    $VMName = $config.compute.azure_vms.dc01.name
    if (-not $VMName) {
        Write-Host "ERROR: -VMName not specified and not found in config (azure_vms.dc01.name)" -ForegroundColor Red
        exit 1
    }
}

# Extract AD values from config to build the remote script
$adDomainFqdn = $config.identity.active_directory.ad_domain_fqdn
if (-not $adDomainFqdn) { $adDomainFqdn = $config.identity.active_directory.fqdn }

$clusterOUPath = $config.identity.active_directory.ad_clusters_ou_path
if (-not $clusterOUPath) { $clusterOUPath = $config.identity.active_directory.ad_clusters_ou_path }

$lcmUsername = $config.identity.accounts.account_lcm_username
$lcmSamAccount = if ($lcmUsername -match '^([^@]+)@') { $Matches[1] } else { $lcmUsername }

# ============================================================================
# BUILD REMOTE SCRIPT
# ============================================================================
# Build the script string that will execute on the remote VM.
# All config values are baked in as literals so the remote VM needs no config file.

$remoteScript = @"
`$ErrorActionPreference = 'Continue'
Import-Module ActiveDirectory -ErrorAction Stop

`$passed = 0
`$failed = 0
`$warned = 0

function Write-Check(`$Name, `$Status, `$Detail) {
    `$icon = switch (`$Status) { 'PASS' { '✓' } 'FAIL' { '✗' } 'WARN' { '⚠' } 'INFO' { 'ℹ' } }
    `$msg = "  `$icon `$Name"
    if (`$Detail) { `$msg += " - `$Detail" }
    Write-Output `$msg
    switch (`$Status) { 'PASS' { `$script:passed++ } 'FAIL' { `$script:failed++ } 'WARN' { `$script:warned++ } }
}

Write-Output "========================================="
Write-Output "Task 01: OU & Pre-Creation Validation (Remote)"
Write-Output "========================================="
Write-Output "  Domain:       $adDomainFqdn"
Write-Output "  Cluster OU:   $clusterOUPath"
Write-Output "  LCM Account:  $lcmSamAccount"
Write-Output ""

# CHECK: KDS Root Key
Write-Output "Checking KDS Root Key..."
try {
    `$kds = Get-KdsRootKey -ErrorAction SilentlyContinue
    if (`$kds) { Write-Check 'KDS Root Key' 'PASS' "Key ID: `$(`$kds[0].KeyId.ToString().Substring(0,8))..." }
    else { Write-Check 'KDS Root Key' 'FAIL' 'Not found' }
} catch { Write-Check 'KDS Root Key' 'WARN' "Cannot check: `$_" }

# CHECK: OU Structure
Write-Output ""
Write-Output "Checking OU structure..."
try {
    `$ou = Get-ADOrganizationalUnit -Identity "$clusterOUPath" -ErrorAction Stop
    Write-Check 'Cluster OU' 'PASS' "$clusterOUPath"
} catch {
    Write-Check 'Cluster OU' 'FAIL' "Not found: $clusterOUPath"
}

# CHECK: LCM User
Write-Output ""
Write-Output "Checking LCM user account..."
try {
    `$user = Get-ADUser -Filter "SamAccountName -eq '$lcmSamAccount'" -Properties Enabled, DistinguishedName
    if (`$user) {
        Write-Check 'LCM user exists' 'PASS' "$lcmSamAccount (`$(`$user.DistinguishedName))"
        if (`$user.Enabled) { Write-Check 'LCM user enabled' 'PASS' }
        else { Write-Check 'LCM user enabled' 'FAIL' 'Account is disabled' }
    } else { Write-Check 'LCM user exists' 'FAIL' "Not found: $lcmSamAccount" }
} catch { Write-Check 'LCM user exists' 'FAIL' "Query failed: `$_" }

# SUMMARY
Write-Output ""
Write-Output "========================================="
Write-Output "SUMMARY: Passed=`$passed  Failed=`$failed  Warnings=`$warned"
Write-Output "========================================="
if (`$failed -eq 0) { Write-Output '✓ AD configuration validation passed!' }
else { Write-Output "✗ `$failed check(s) failed. Review above and remediate." }
"@

# ============================================================================
# EXECUTE ON REMOTE VM
# ============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Invoke-AzVMRunCommand" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Target VM:         $VMName" -ForegroundColor White
Write-Host "  Resource Group:    $ResourceGroupName" -ForegroundColor White
Write-Host ""

# Verify Azure context
try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw "No Azure context" }
    Write-Host "  Azure Account:     $($ctx.Account.Id)" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Not authenticated to Azure. Run Connect-AzAccount first." -ForegroundColor Red
    exit 1
}

# Verify VM exists and is running
Write-Host "  Checking VM status..." -ForegroundColor Cyan
try {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction Stop
    $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
    Write-Host "  VM Power State:    $powerState" -ForegroundColor $(if ($powerState -eq 'VM running') { 'Green' } else { 'Red' })
    if ($powerState -ne 'VM running') {
        Write-Host "ERROR: VM is not running. Start the VM first." -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "ERROR: Cannot find VM '$VMName' in resource group '$ResourceGroupName': $_" -ForegroundColor Red
    exit 1
}

# Execute the remote script
Write-Host ""
Write-Host "Executing AD validation on remote VM..." -ForegroundColor Cyan
Write-Host "(This may take 30-60 seconds)" -ForegroundColor Yellow
Write-Host ""

try {
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -CommandId "RunPowerShellScript" `
        -ScriptString $remoteScript `
        -ErrorAction Stop

    # Display output
    $stdout = $result.Value | Where-Object { $_.Code -eq "ComponentStatus/StdOut/succeeded" }
    $stderr = $result.Value | Where-Object { $_.Code -eq "ComponentStatus/StdErr/succeeded" }

    if ($stdout.Message) {
        Write-Host $stdout.Message
    }

    if ($stderr.Message) {
        Write-Host ""
        Write-Host "--- Script Errors ---" -ForegroundColor Red
        Write-Host $stderr.Message -ForegroundColor Red
    }
}
catch {
    Write-Host "ERROR: Invoke-AzVMRunCommand failed: $_" -ForegroundColor Red
    exit 1
}
