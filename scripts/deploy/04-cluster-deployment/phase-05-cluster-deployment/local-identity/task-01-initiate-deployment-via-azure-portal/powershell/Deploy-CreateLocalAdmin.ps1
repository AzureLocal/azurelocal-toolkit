<#
.SYNOPSIS
    Deploy-CreateLocalAdmin.ps1
    Creates the required non-built-in local administrator account directly on this node.

.DESCRIPTION
    Run this script directly ON each cluster node (via RDP or console session).
    Creates a non-built-in local administrator account required for Local Identity
    authentication. The user name and the password are parameters — no infrastructure.yml or
    toolkit helpers needed. Nothing is written in the script.

    Microsoft requirements:
      - Account must NOT be the built-in Administrator account
      - Username and password must be IDENTICAL on every cluster node
      - Password must be at least 14 characters
    Ref: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault

.PARAMETER Username
    The name of the local administrator account to create (identity.local_admin.username of the
    infrastructure file). It must be the same on every node and must not be Administrator.

.PARAMETER Password
    The password of the account, as a secure string (identity.local_admin.password of the
    infrastructure file holds the reference to it). At least 14 characters; the same on every node.

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-01-initiate-deployment-via-azure-portal (Local Identity pre-deployment)
    Execution:    Run directly ON each cluster node (console/RDP) — NOT from mgmt server
    Run before:   Portal deployment — Local Identity via Azure Key Vault

.EXAMPLE
    # Run on each cluster node via RDP or console
    .\Deploy-CreateLocalAdmin.ps1 -Username <account> -Password (Read-Host -AsSecureString 'Password')
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Username,
    [Parameter(Mandatory)][securestring]$Password
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region VALIDATION

if ($Username -ieq 'Administrator') {
    throw "Do NOT use the built-in 'Administrator' account. Create a custom non-default local account. See: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault"
}

if ($Password.Length -lt 14) {
    throw "Password must be at least 14 characters. Current length: $($Password.Length)"
}

#endregion VALIDATION

#region MAIN

Write-Host "`n=== Deploy-CreateLocalAdmin.ps1 ===" -ForegroundColor Cyan
Write-Host "  Node     : $env:COMPUTERNAME"
Write-Host "  Account  : $Username"
Write-Host ""

$secPwd   = $Password
$existing = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue

if (-not $existing) {
    New-LocalUser -Name $Username -Password $secPwd -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Write-Host "[PASS] Account '$Username' created on $env:COMPUTERNAME" -ForegroundColor Green
} else {
    Set-LocalUser -Name $Username -Password $secPwd
    Write-Host "[PASS] Account '$Username' password updated on $env:COMPUTERNAME" -ForegroundColor Green
}

$inAdmins = [bool](
    Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*$Username" }
)
if (-not $inAdmins) {
    Add-LocalGroupMember -Group 'Administrators' -Member $Username
    Write-Host "[PASS] '$Username' added to local Administrators group" -ForegroundColor Green
} else {
    Write-Host "[PASS] '$Username' already in Administrators group" -ForegroundColor Green
}

Write-Host "`nVerification on $env:COMPUTERNAME :" -ForegroundColor Cyan
Get-LocalUser -Name $Username | Format-Table Name, Enabled, PasswordNeverExpires, AccountNeverExpires -AutoSize

Write-Host "[DONE] Run this script on every other cluster node before starting portal deployment." -ForegroundColor Cyan

#endregion MAIN
