#Requires -Modules Az.Subscription, Az.Resources
<#
.SYNOPSIS
    Create a single Azure subscription and associate it to a management group
    (simplified deployment).
.DESCRIPTION
    Creates one subscription using the EA enrollment account from config and
    places it into the management group specified in config/variables.yml.
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
$sub    = $config.azure.subscription
$mgName = $config.azure.management_group.name

Write-Host "Retrieving EA enrollment account..." -ForegroundColor Cyan
$enrollmentAccount = Get-AzEnrollmentAccount | Select-Object -First 1
if (-not $enrollmentAccount) {
    throw "No EA enrollment account found. Ensure the account has billing permissions."
}
$enrollmentAccountId = $enrollmentAccount.ObjectId
Write-Host "  Using enrollment account: $enrollmentAccountId"

Write-Host ""
Write-Host "Creating subscription: $($sub.display_name)..." -ForegroundColor Cyan

$existing = Get-AzSubscriptionAlias -AliasName $sub.alias -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  [SKIP] Subscription alias '$($sub.alias)' already exists." -ForegroundColor Yellow
    $subId = $existing.SubscriptionId
} else {
    if ($PSCmdlet.ShouldProcess($sub.display_name, "Create subscription")) {
        $newSub = New-AzSubscriptionAlias `
            -AliasName        $sub.alias `
            -SubscriptionName $sub.display_name `
            -BillingScope     "/providers/Microsoft.Billing/enrollmentAccounts/$enrollmentAccountId" `
            -Workload         "Production"
        $subId = $newSub.SubscriptionId
        Write-Host "  [CREATED] $subId" -ForegroundColor Green
    }
}

if ($PSCmdlet.ShouldProcess($mgName, "Add subscription $subId")) {
    Write-Host "  Associating to management group: $mgName..."
    New-AzManagementGroupSubscription -GroupName $mgName -SubscriptionId $subId
    Write-Host "  [DONE]" -ForegroundColor Green
}

Write-Host "`nSubscription deployment complete." -ForegroundColor Cyan
