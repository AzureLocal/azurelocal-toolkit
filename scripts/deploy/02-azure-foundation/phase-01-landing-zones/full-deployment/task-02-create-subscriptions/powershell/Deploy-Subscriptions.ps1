#Requires -Modules Az.Subscription, Az.Resources
<#
.SYNOPSIS
    Create Azure subscriptions and associate them to management groups.
.DESCRIPTION
    Creates Identity, Management, Connectivity, Corp, and Online subscriptions
    using the EA enrollment account from config, then places each into the
    correct management group.
.PARAMETER ConfigPath
    Path to the YAML variables file. Defaults to ./config/variables.yml.
.PARAMETER WhatIf
    Preview changes without making them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "./config/variables.yml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$azure  = $config.azure

# ── Get EA enrollment account ─────────────────────────────────────────────────
Write-Host "Retrieving EA enrollment account..." -ForegroundColor Cyan
$enrollmentAccount = Get-AzEnrollmentAccount | Select-Object -First 1
if (-not $enrollmentAccount) {
    throw "No EA enrollment account found. Ensure the account has billing permissions."
}
$enrollmentAccountId = $enrollmentAccount.ObjectId
Write-Host "  Using enrollment account: $enrollmentAccountId"

# ── Subscription definitions ──────────────────────────────────────────────────
$subscriptions = @(
    @{ Alias = "sub-identity";     DisplayName = "Identity Subscription";    MgName = $azure.management_groups.platform.name }
    @{ Alias = "sub-management";   DisplayName = "Management Subscription";   MgName = $azure.management_groups.platform.name }
    @{ Alias = "sub-connectivity"; DisplayName = "Connectivity Subscription"; MgName = $azure.management_groups.platform.name }
    @{ Alias = "sub-corp";         DisplayName = "Corp Landing Zone";         MgName = $azure.management_groups.landing_zone.name }
    @{ Alias = "sub-online";       DisplayName = "Online Landing Zone";       MgName = $azure.management_groups.landing_zone.name }
)

# ── Create and associate ──────────────────────────────────────────────────────
foreach ($sub in $subscriptions) {
    Write-Host ""
    Write-Host "Processing: $($sub.DisplayName)..." -ForegroundColor Cyan

    # Check if alias already exists
    $existing = Get-AzSubscriptionAlias -AliasName $sub.Alias -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  [SKIP] Subscription alias '$($sub.Alias)' already exists." -ForegroundColor Yellow
        $subId = $existing.SubscriptionId
    } else {
        if ($PSCmdlet.ShouldProcess($sub.DisplayName, "Create subscription")) {
            $newSub = New-AzSubscriptionAlias `
                -AliasName $sub.Alias `
                -SubscriptionName $sub.DisplayName `
                -BillingScope "/providers/Microsoft.Billing/enrollmentAccounts/$enrollmentAccountId" `
                -Workload "Production"
            $subId = $newSub.SubscriptionId
            Write-Host "  [CREATED] $subId" -ForegroundColor Green
        }
    }

    if ($PSCmdlet.ShouldProcess($sub.MgName, "Add subscription $subId")) {
        Write-Host "  Associating to management group: $($sub.MgName)..."
        New-AzManagementGroupSubscription -GroupName $sub.MgName -SubscriptionId $subId
        Write-Host "  [DONE]" -ForegroundColor Green
    }
}

Write-Host "`nAll subscriptions deployed and associated." -ForegroundColor Cyan
