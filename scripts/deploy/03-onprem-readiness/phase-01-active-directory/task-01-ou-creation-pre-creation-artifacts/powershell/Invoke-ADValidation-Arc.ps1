<#
.SYNOPSIS
    Runs Task 01 AD validation remotely on an Azure Arc-enabled server via New-AzConnectedMachineRunCommand.

.DESCRIPTION
    Validates only the artifacts created by Task 01 (New-HciAdObjectsPreCreation):
      - KDS Root Key
      - Organizational Unit (OU)
      - LCM user account

    Uses New-AzConnectedMachineRunCommand to execute on an Arc-enrolled domain controller.
    No RDP, VPN, or direct network connectivity required — commands are routed through
    the Azure Arc agent. Arc run commands are persistent resources; this script creates,
    monitors, retrieves output, and cleans up the run command automatically.

.PARAMETER ConfigFile
    Path to the infrastructure.yml configuration file (local path).
    Config values are extracted locally and baked into the remote script.

.PARAMETER ResourceGroupName
    Azure resource group containing the Arc-enrolled machine.
    If not specified, reads from config: azure_vms.dc01.resource_group

.PARAMETER MachineName
    Arc-enrolled machine name (hostname as registered in Azure Arc).
    If not specified, reads from config: azure_vms.dc01.hostname

.PARAMETER Location
    Azure region of the Arc resource.
    If not specified, reads from config: azure_vms.dc01.location

.PARAMETER SkipCleanup
    If specified, the Arc run command resource is NOT deleted after execution.

.EXAMPLE
    .\Invoke-ADValidation-Arc.ps1 -ConfigFile "..\..\..\..\configs\infrastructure-azl-lab.yml"

.EXAMPLE
    .\Invoke-ADValidation-Arc.ps1 -ConfigFile ".\infrastructure-azl-lab.yml" -MachineName "azrsdc-eus-01" -ResourceGroupName "rg-azrlmgmt-dev-eus-01" -Location "eastus"

.NOTES
    Requires: Az.ConnectedMachine module, authenticated Azure session (Connect-AzAccount)
    Role: Azure Connected Machine Resource Administrator or Contributor on the Arc resource
    Author: Azure Local Cloudnology Team
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
    [string]$MachineName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================
Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
Import-Module powershell-yaml -ErrorAction Stop
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Yaml

# Resolve Arc target from config if not specified
if (-not $ResourceGroupName) {
    $ResourceGroupName = $config.compute.azure_vms.dc01.resource_group
    if (-not $ResourceGroupName) {
        Write-Host "ERROR: -ResourceGroupName not specified and not found in config" -ForegroundColor Red
        exit 1
    }
}

if (-not $MachineName) {
    $MachineName = $config.compute.azure_vms.dc01.hostname
    if (-not $MachineName) {
        Write-Host "ERROR: -MachineName not specified and not found in config (azure_vms.dc01.hostname)" -ForegroundColor Red
        exit 1
    }
}

if (-not $Location) {
    $Location = $config.compute.azure_vms.dc01.location
    if (-not $Location) { $Location = "eastus" }
}

# Extract AD values from config
$adDomainFqdn = $config.identity.active_directory.ad_domain_fqdn
if (-not $adDomainFqdn) { $adDomainFqdn = $config.identity.active_directory.fqdn }

$clusterOUPath = $config.identity.active_directory.ad_clusters_ou_path
if (-not $clusterOUPath) { $clusterOUPath = $config.identity.active_directory.ad_clusters_ou_path }

$lcmUsername = $config.identity.accounts.account_lcm_username
$lcmSamAccount = if ($lcmUsername -match '^([^@]+)@') { $Matches[1] } else { $lcmUsername }

# ============================================================================
# BUILD REMOTE SCRIPT
# ============================================================================

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
Write-Output "Task 01: OU & Pre-Creation Validation (Arc Remote)"
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
# EXECUTE ON ARC-ENROLLED SERVER
# ============================================================================
$runCommandName = "ValidateADConfig-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "New-AzConnectedMachineRunCommand" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Target Machine:    $MachineName" -ForegroundColor White
Write-Host "  Resource Group:    $ResourceGroupName" -ForegroundColor White
Write-Host "  Location:          $Location" -ForegroundColor White
Write-Host "  Run Command Name:  $runCommandName" -ForegroundColor White
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

# Verify Az.ConnectedMachine module
try {
    Import-Module Az.ConnectedMachine -ErrorAction Stop
}
catch {
    Write-Host "ERROR: Az.ConnectedMachine module not installed. Run: Install-Module Az.ConnectedMachine -Force" -ForegroundColor Red
    exit 1
}

# Create and execute the run command
Write-Host ""
Write-Host "Creating run command on Arc server..." -ForegroundColor Cyan
Write-Host "(This may take 60-120 seconds)" -ForegroundColor Yellow
Write-Host ""

try {
    $null = New-AzConnectedMachineRunCommand `
        -MachineName $MachineName `
        -ResourceGroupName $ResourceGroupName `
        -RunCommandName $runCommandName `
        -Location $Location `
        -SourceScript $remoteScript `
        -ErrorAction Stop

    # Retrieve the result
    $cmd = Get-AzConnectedMachineRunCommand `
        -MachineName $MachineName `
        -ResourceGroupName $ResourceGroupName `
        -RunCommandName $runCommandName

    Write-Host "Execution State: $($cmd.InstanceViewExecutionState)" -ForegroundColor $(
        if ($cmd.InstanceViewExecutionState -eq 'Succeeded') { 'Green' }
        elseif ($cmd.InstanceViewExecutionState -eq 'Failed') { 'Red' }
        else { 'Yellow' }
    )
    Write-Host ""

    if ($cmd.InstanceViewOutput) {
        Write-Host $cmd.InstanceViewOutput
    }

    if ($cmd.InstanceViewError) {
        Write-Host ""
        Write-Host "--- Script Errors ---" -ForegroundColor Red
        Write-Host $cmd.InstanceViewError -ForegroundColor Red
    }
}
catch {
    Write-Host "ERROR: Arc run command failed: $_" -ForegroundColor Red
    # Attempt cleanup even on failure
    try {
        Remove-AzConnectedMachineRunCommand `
            -MachineName $MachineName `
            -ResourceGroupName $ResourceGroupName `
            -RunCommandName $runCommandName `
            -ErrorAction SilentlyContinue
    } catch {}
    exit 1
}

# ============================================================================
# CLEANUP
# ============================================================================
if (-not $SkipCleanup) {
    Write-Host ""
    Write-Host "Cleaning up Arc run command resource..." -ForegroundColor Cyan
    try {
        Remove-AzConnectedMachineRunCommand `
            -MachineName $MachineName `
            -ResourceGroupName $ResourceGroupName `
            -RunCommandName $runCommandName `
            -ErrorAction Stop
        Write-Host "  ✓ Run command '$runCommandName' removed" -ForegroundColor Green
    }
    catch {
        Write-Host "  ⚠ Cleanup failed: $_" -ForegroundColor Yellow
        Write-Host "  Manual cleanup: Remove-AzConnectedMachineRunCommand -MachineName $MachineName -ResourceGroupName $ResourceGroupName -RunCommandName $runCommandName" -ForegroundColor Yellow
    }
}
else {
    Write-Host ""
    Write-Host "  ⚠ Skipping cleanup (-SkipCleanup). Run command '$runCommandName' persists as an Azure resource." -ForegroundColor Yellow
    Write-Host "  Manual cleanup: Remove-AzConnectedMachineRunCommand -MachineName $MachineName -ResourceGroupName $ResourceGroupName -RunCommandName $runCommandName" -ForegroundColor Yellow
}
