<#
.SYNOPSIS
    Test-ADPrerequisites-Standalone.ps1
    Verifies Active Directory prerequisites for Azure Local ARM template deployment.

.DESCRIPTION
    Standalone script (Option 5). No infrastructure.yml dependency. All values are
    set as inline variables. Edit the CONFIGURATION section below before running.

    Checks:
      1. Domain connectivity from each node (Test-ComputerSecureChannel via PSRemoting)
      2. OU existence (Get-ADOrganizationalUnit)
      3. LCM account GenericAll delegation on OU

    Requires:
      - ActiveDirectory module (RSAT)
      - PSRemoting access to cluster nodes

.EXAMPLE
    .\Test-ADPrerequisites-Standalone.ps1

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Script Type:  Standalone (Option 5 — no config dependency)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION — Edit these values before running

$nodeIPs    = @("<NODE_IP_1>", "<NODE_IP_2>")                                    # compute.cluster_nodes[*].management_ip
$ouPath     = "<DOMAIN_OU_PATH>"                                                 # cluster_arm_deployment.domain_ou_path
$lcmUser    = "<LCM_USERNAME>"                                                   # accounts.lcm_admin.username

#endregion CONFIGURATION

$allPassed = $true

# --- Credential ---
$cred = Get-Credential -Message "Enter local admin credentials for node access"

# --- Step 1: Domain Connectivity ---
Write-Host "`n--- Step 1: Domain Connectivity ---" -ForegroundColor Cyan
foreach ($ip in $nodeIPs) {
    try {
        $result = Invoke-Command -ComputerName $ip -Credential $cred -ScriptBlock {
            Test-ComputerSecureChannel -ErrorAction SilentlyContinue
        }
        if ($result) {
            Write-Host "  $ip : Domain secure channel OK" -ForegroundColor Green
        }
        else {
            Write-Host "  $ip : Domain secure channel FAILED" -ForegroundColor Red
            $allPassed = $false
        }
    }
    catch {
        Write-Host "  $ip : Connection failed — $($_.Exception.Message)" -ForegroundColor Red
        $allPassed = $false
    }
}

# --- Step 2: OU Exists ---
Write-Host "`n--- Step 2: OU Verification ---" -ForegroundColor Cyan
try {
    Get-ADOrganizationalUnit -Identity $ouPath -ErrorAction Stop | Out-Null
    Write-Host "  OU exists: $ouPath" -ForegroundColor Green
}
catch {
    Write-Host "  OU not found: $ouPath" -ForegroundColor Red
    $allPassed = $false
}

# --- Step 3: LCM Delegation ---
Write-Host "`n--- Step 3: LCM Account Delegation ---" -ForegroundColor Cyan
try {
    $acl = Get-Acl "AD:\$ouPath" -ErrorAction Stop
    $delegation = $acl.Access | Where-Object {
        $_.IdentityReference -like "*$lcmUser*" -and
        $_.ActiveDirectoryRights -match "GenericAll"
    }
    if ($delegation) {
        Write-Host "  $lcmUser has GenericAll on OU" -ForegroundColor Green
        $delegation | Format-Table IdentityReference, ActiveDirectoryRights -AutoSize
    }
    else {
        Write-Host "  $lcmUser does NOT have GenericAll on OU" -ForegroundColor Red
        $allPassed = $false
    }
}
catch {
    Write-Host "  Could not read ACL: $($_.Exception.Message)" -ForegroundColor Red
    $allPassed = $false
}

# --- Summary ---
Write-Host ""
if ($allPassed) {
    Write-Host "AD Prerequisites: ALL PASSED" -ForegroundColor Green
}
else {
    Write-Host "AD Prerequisites: FAILED — fix issues above before deploying" -ForegroundColor Red
}
