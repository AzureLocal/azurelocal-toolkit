<#
.SYNOPSIS
    Test-ADDomainStatus-Standalone.ps1
    Verifies AD domain join and trust status with inline variables (no config dependency).

.DESCRIPTION
    Standalone script (Option 5). Edit the CONFIGURATION section below with your values.

.EXAMPLE
    .\Test-ADDomainStatus-Standalone.ps1

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Script Type:  Standalone (Option 5 — no config dependency)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region CONFIGURATION — Edit these values before running

$nodeIPs     = @("<NODE_IP_1>", "<NODE_IP_2>")   # compute.cluster_nodes[*].ipv4_address
$domainFqdn  = "<DOMAIN_FQDN>"                    # cluster_arm_deployment.domain_fqdn
$ouPath      = "<DOMAIN_OU_PATH>"                  # cluster_arm_deployment.domain_ou_path
$lcmUser     = "<LCM_USERNAME>"                    # accounts.lcm_admin.username
$clusterName = "<CLUSTER_NAME>"                    # cluster_arm_deployment.cluster_name

#endregion CONFIGURATION

$remoteParams = @{}
if ($Credential) { $remoteParams["Credential"] = $Credential }

Write-Host "=== AD Domain Status Verification ===" -ForegroundColor Cyan
Write-Host "Domain: $domainFqdn" -ForegroundColor Cyan
Write-Host "OU:     $ouPath" -ForegroundColor Cyan
Write-Host ""

# Test 1: Domain membership per node
Write-Host "--- Domain Membership & Secure Channel ---" -ForegroundColor Cyan
foreach ($nodeIP in $nodeIPs) {
    try {
        $result = Invoke-Command -ComputerName $nodeIP @remoteParams -ScriptBlock {
            param($expected)
            $cs = Get-WmiObject Win32_ComputerSystem
            [pscustomobject]@{
                Node = $cs.Name; Domain = $cs.Domain
                Match = ($cs.Domain -eq $expected)
                Secure = (Test-ComputerSecureChannel -ErrorAction SilentlyContinue)
            }
        } -ArgumentList $domainFqdn -ErrorAction Stop

        $color = if ($result.Match -and $result.Secure) { "Green" } else { "Red" }
        Write-Host "  $($result.Node): Domain=$($result.Domain) Match=$($result.Match) SecureChannel=$($result.Secure)" -ForegroundColor $color
    }
    catch {
        Write-Host "  $nodeIP : FAILED — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Test 2: OU exists
Write-Host ""
Write-Host "--- OU Verification ---" -ForegroundColor Cyan
try {
    $ou = Get-ADOrganizationalUnit -Identity $ouPath -ErrorAction Stop
    Write-Host "  OU exists: $($ou.DistinguishedName)" -ForegroundColor Green
}
catch {
    Write-Host "  OU not found: $ouPath" -ForegroundColor Red
}

# Test 3: LCM delegation
Write-Host ""
Write-Host "--- LCM Account Delegation ---" -ForegroundColor Cyan
try {
    $acl = Get-Acl "AD:\$ouPath" -ErrorAction Stop
    $deleg = $acl.Access | Where-Object { $_.IdentityReference -like "*$lcmUser*" -and $_.ActiveDirectoryRights -match "GenericAll" }
    if ($deleg) { Write-Host "  $lcmUser has GenericAll on OU" -ForegroundColor Green }
    else { Write-Host "  $lcmUser does NOT have GenericAll on OU" -ForegroundColor Red }
}
catch {
    Write-Host "  Failed to check ACL — $($_.Exception.Message)" -ForegroundColor Red
}

# Test 4: Cluster computer object
Write-Host ""
Write-Host "--- Cluster Computer Object ---" -ForegroundColor Cyan
try {
    $obj = Get-ADComputer -Identity $clusterName -ErrorAction Stop
    Write-Host "  Found: $($obj.DistinguishedName)" -ForegroundColor Green
}
catch {
    Write-Host "  Not found (may be expected pre-deployment)" -ForegroundColor Yellow
}
