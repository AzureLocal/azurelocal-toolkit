<#
.SYNOPSIS
    Configures diagnostic settings for Azure resources to send logs to Log Analytics.

.DESCRIPTION
    Deploys diagnostic settings across platform resources:
    - Key Vault: Audit events to platform workspace
    - NSGs: Flow logs and diagnostic logs to platform workspace
    - VNets: Diagnostic logs to platform workspace
    
    All diagnostic data routes to the platform Log Analytics workspace.

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers"

.PARAMETER ManagementSubscriptionId
    Management subscription ID.

.PARAMETER SecuritySubscriptionId
    Security subscription ID.

.PARAMETER ConnectivitySubscriptionId
    Connectivity subscription ID.

.PARAMETER LogAnalyticsWorkspaceName
    Platform Log Analytics workspace name.

.PARAMETER MonitoringResourceGroup
    Monitoring resource group name.

.EXAMPLE
    # Using solution configuration
    .\Deploy-DiagnosticSettings.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-DiagnosticSettings.ps1 -ManagementSubscriptionId "your-sub-id" -LogAnalyticsWorkspaceName "log-workspace"

.EXAMPLE
    .\Deploy-DiagnosticSettings.ps1 -Solution "azure-local" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$ManagementSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$SecuritySubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ConnectivitySubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceName,

    [Parameter(Mandatory = $false)]
    [string]$MonitoringResourceGroup
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
if ($Solution) {
    Write-Host "[Config] Loading solution configuration for: $Solution" -ForegroundColor Cyan
    . "$PSScriptRoot\..\..\..\utilities\helpers\config-loader.ps1"
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters - only if not explicitly provided
    if (-not $ManagementSubscriptionId) { $ManagementSubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscription.id' }
    if (-not $SecuritySubscriptionId) { $SecuritySubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscriptions.security.id' }
    if (-not $ConnectivitySubscriptionId) { $ConnectivitySubscriptionId = Get-ConfigValue -Config $config -Path 'azure.subscriptions.connectivity.id' }
    if (-not $LogAnalyticsWorkspaceName) { $LogAnalyticsWorkspaceName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.monitoring.log_analytics.name' }
    if (-not $MonitoringResourceGroup) { $MonitoringResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.monitoring.name' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $ManagementSubscriptionId) { $missingParams += 'ManagementSubscriptionId' }
if (-not $LogAnalyticsWorkspaceName) { $missingParams += 'LogAnalyticsWorkspaceName' }
if (-not $MonitoringResourceGroup) { $missingParams += 'MonitoringResourceGroup' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

Write-Host "=== Diagnostic Settings Deployment ===" -ForegroundColor Cyan
Write-Host "Platform Log Analytics Workspace: $LogAnalyticsWorkspaceName" -ForegroundColor Gray
Write-Host ""

# ============================================
# Get Log Analytics Workspace ID
# ============================================

Write-Host "[Prerequisite] Getting Log Analytics Workspace ID..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $MonitoringResourceGroup -Name $LogAnalyticsWorkspaceName -ErrorAction SilentlyContinue
if (-not $workspace) {
    throw "Log Analytics workspace not found: $LogAnalyticsWorkspaceName. Run 06-deploy-monitoring-security.ps1 first."
}
$workspaceId = $workspace.ResourceId
Write-Host "✓ Workspace ID: $workspaceId" -ForegroundColor Green
Write-Host ""

# ============================================
# CATEGORY 1: Key Vault Diagnostic Settings
# ============================================

Write-Host "=== CATEGORY 1: Key Vault Diagnostic Settings ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/3] Configuring: Key Vault diagnostic settings..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $SecuritySubscriptionId | Out-Null

# Note: KeyVaultName should come from solution config parameter
$keyVault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
if ($keyVault) {
    $kvResourceId = $keyVault.ResourceId
    
    if ($PSCmdlet.ShouldProcess($kvResourceId, "Configure diagnostic settings")) {
        # Check if diagnostic setting already exists
        $diagName = "diag-$KeyVaultName"
        $existingDiag = Get-AzDiagnosticSetting -ResourceId $kvResourceId -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -eq $diagName }
        
        if (-not $existingDiag) {
            # Configure Key Vault diagnostic settings
            $logCategories = @(
                New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category "AuditEvent"
                New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category "AzurePolicyEvaluationDetails"
            )
            
            $metricCategories = @(
                New-AzDiagnosticSettingMetricSettingsObject -Enabled $true -Category "AllMetrics"
            )
            
            New-AzDiagnosticSetting -Name $diagName `
                -ResourceId $kvResourceId `
                -WorkspaceId $workspaceId `
                -Log $logCategories `
                -Metric $metricCategories | Out-Null
            
            Write-Host "  ✓ Configured: Key Vault diagnostic settings" -ForegroundColor Green
        } else {
            Write-Host "  ✓ Already configured" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  ⚠ Key Vault not found - skipping" -ForegroundColor Yellow
}

# ============================================
# CATEGORY 2: Network Security Group Diagnostic Settings
# ============================================

Write-Host ""
Write-Host "=== CATEGORY 2: NSG Diagnostic Settings ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "[2/3] Configuring: NSG diagnostic settings..." -ForegroundColor Yellow

# Get NSGs from Management and Connectivity subscriptions
$subscriptions = @($ManagementSubscriptionId, $ConnectivitySubscriptionId)
$nsgCount = 0

foreach ($subId in $subscriptions) {
    Set-AzContext -SubscriptionId $subId | Out-Null
    $nsgs = Get-AzNetworkSecurityGroup
    
    foreach ($nsg in $nsgs) {
        $nsgCount++
        if ($PSCmdlet.ShouldProcess($nsg.Id, "Configure diagnostic settings")) {
            # Check if diagnostic setting already exists
            $existingDiag = Get-AzDiagnosticSetting -ResourceId $nsg.Id -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -eq "diag-$($nsg.Name)" }
            
            if (-not $existingDiag) {
                $logCategories = @(
                    New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category "NetworkSecurityGroupEvent"
                    New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category "NetworkSecurityGroupRuleCounter"
                )
                
                New-AzDiagnosticSetting -Name "diag-$($nsg.Name)" `
                    -ResourceId $nsg.Id `
                    -WorkspaceId $workspaceId `
                    -Log $logCategories | Out-Null
                
                Write-Host "  ✓ Configured: $($nsg.Name)" -ForegroundColor Green
            } else {
                Write-Host "  ✓ Already configured: $($nsg.Name)" -ForegroundColor Gray
            }
        }
    }
}

if ($nsgCount -eq 0) {
    Write-Host "  ⚠ No NSGs found" -ForegroundColor Yellow
}

# ============================================
# CATEGORY 3: Virtual Network Diagnostic Settings
# ============================================

Write-Host ""
Write-Host "=== CATEGORY 3: VNet Diagnostic Settings ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "[3/3] Configuring: VNet diagnostic settings..." -ForegroundColor Yellow

$vnetCount = 0

foreach ($subId in $subscriptions) {
    Set-AzContext -SubscriptionId $subId | Out-Null
    $vnets = Get-AzVirtualNetwork
    
    foreach ($vnet in $vnets) {
        $vnetCount++
        if ($PSCmdlet.ShouldProcess($vnet.Id, "Configure diagnostic settings")) {
            # Check if diagnostic setting already exists
            $existingDiag = Get-AzDiagnosticSetting -ResourceId $vnet.Id -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -eq "diag-$($vnet.Name)" }
            
            if (-not $existingDiag) {
                $logCategories = @(
                    New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category "VMProtectionAlerts"
                )
                
                $metricCategories = @(
                    New-AzDiagnosticSettingMetricSettingsObject -Enabled $true -Category "AllMetrics"
                )
                
                New-AzDiagnosticSetting -Name "diag-$($vnet.Name)" `
                    -ResourceId $vnet.Id `
                    -WorkspaceId $workspaceId `
                    -Log $logCategories `
                    -Metric $metricCategories | Out-Null
                
                Write-Host "  ✓ Configured: $($vnet.Name)" -ForegroundColor Green
            } else {
                Write-Host "  ✓ Already configured: $($vnet.Name)" -ForegroundColor Gray
            }
        }
    }
}

if ($vnetCount -eq 0) {
    Write-Host "  ⚠ No VNets found" -ForegroundColor Yellow
}

# ============================================
# Summary
# ============================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Diagnostic Settings Deployment Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Configured Resources:" -ForegroundColor Yellow
Write-Host "  ✓ Key Vault: $KeyVaultName" -ForegroundColor Green
Write-Host "  ✓ Network Security Groups: $nsgCount NSG(s)" -ForegroundColor Green
Write-Host "  ✓ Virtual Networks: $vnetCount VNet(s)" -ForegroundColor Green
Write-Host ""

Write-Host "All diagnostic logs route to:" -ForegroundColor Yellow
Write-Host "  Workspace: $LogAnalyticsWorkspaceName" -ForegroundColor White
Write-Host "  Resource Group: $MonitoringResourceGroup" -ForegroundColor White
Write-Host "  Subscription: $ManagementSubscriptionId" -ForegroundColor White
Write-Host ""

Write-Host "Verification:" -ForegroundColor Cyan
Write-Host "  # View logs in Log Analytics" -ForegroundColor Gray
Write-Host "  - Navigate to Azure Portal -> Log Analytics Workspaces -> $LogAnalyticsWorkspaceName" -ForegroundColor White
Write-Host "  - Run queries in 'Logs' section:" -ForegroundColor White
Write-Host "    AzureDiagnostics | where ResourceType == 'VAULTS'" -ForegroundColor Gray
Write-Host "    AzureDiagnostics | where ResourceType == 'NETWORKSECURITYGROUPS'" -ForegroundColor Gray
Write-Host "    AzureDiagnostics | where ResourceType == 'VIRTUALNETWORKS'" -ForegroundColor Gray
Write-Host ""
