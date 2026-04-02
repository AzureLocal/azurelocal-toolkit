<#
.SYNOPSIS
    Deploys monitoring and security infrastructure for Phoenix platform.

.DESCRIPTION
    Creates monitoring and security foundations per CAF/WAF Landing Zone best practices:
    - Platform Log Analytics workspace in Management subscription
    - Sentinel Log Analytics workspace in Security subscription
    - Resource groups for monitoring and security resources
    
    Prepares environment for:
    - Microsoft Defender for Cloud (configured later at subscription level)
    - Microsoft Sentinel deployment (configured later)
    - Centralized platform monitoring

.PARAMETER Solution
    The solution name to load configuration from. When specified, loads parameters from the solution's 
    configuration file. Individual parameters can still override config values.
    Valid values: "azure-local", "azure-arc-servers"

.PARAMETER ManagementSubscriptionId
    Management subscription ID.

.PARAMETER SecuritySubscriptionId
    Security subscription ID.

.PARAMETER Location
    Azure region.

.PARAMETER MonitoringResourceGroup
    Monitoring resource group name.

.PARAMETER SecurityResourceGroup
    Security resource group name.

.PARAMETER PlatformWorkspaceName
    Platform Log Analytics workspace name.

.PARAMETER SentinelWorkspaceName
    Sentinel Log Analytics workspace name.

.EXAMPLE
    # Using solution configuration
    .\Deploy-MonitoringSecurity.ps1 -Solution "azure-local"

.EXAMPLE
    # Using direct parameters
    .\Deploy-MonitoringSecurity.ps1 -ManagementSubscriptionId "your-sub-id" -Location "eastus2"

.EXAMPLE
    .\Deploy-MonitoringSecurity.ps1 -Solution "azure-local" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$ManagementSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$SecuritySubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$MonitoringResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$SecurityResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$PlatformWorkspaceName,

    [Parameter(Mandatory = $false)]
    [string]$SentinelWorkspaceName
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
    if (-not $Location) { $Location = Get-ConfigValue -Config $config -Path 'azure.location' }
    if (-not $MonitoringResourceGroup) { $MonitoringResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.monitoring.name' }
    if (-not $SecurityResourceGroup) { $SecurityResourceGroup = Get-ConfigValue -Config $config -Path 'azure_infrastructure.resource_groups.security.name' }
    if (-not $PlatformWorkspaceName) { $PlatformWorkspaceName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.monitoring.log_analytics.name' }
    if (-not $SentinelWorkspaceName) { $SentinelWorkspaceName = Get-ConfigValue -Config $config -Path 'azure_infrastructure.monitoring.sentinel_workspace.name' }
    
    Write-Host "[Config] Configuration loaded successfully" -ForegroundColor Green
}

# Validate required parameters
$missingParams = @()
if (-not $ManagementSubscriptionId) { $missingParams += 'ManagementSubscriptionId' }
if (-not $Location) { $missingParams += 'Location' }

if ($missingParams.Count -gt 0) {
    throw "Missing required parameters: $($missingParams -join ', '). Provide -Solution or specify parameters directly."
}

Write-Host "=== Monitoring and Security Infrastructure Deployment ===" -ForegroundColor Cyan
Write-Host "Management Subscription: $ManagementSubscriptionId" -ForegroundColor Gray
Write-Host "Security Subscription: $SecuritySubscriptionId" -ForegroundColor Gray
Write-Host "Location: $Location" -ForegroundColor Gray
Write-Host ""

# ============================================
# PHASE 1: Platform Monitoring (Management Subscription)
# ============================================

Write-Host "=== PHASE 1: Platform Monitoring Infrastructure ===" -ForegroundColor Yellow
Write-Host ""

# Set context to Management subscription
Write-Host "[1/6] Setting subscription context to Management..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
$currentContext = Get-AzContext
if ($currentContext.Subscription.Id -ne $ManagementSubscriptionId) {
    throw "Failed to set subscription context to Management subscription"
}
Write-Host "✓ Context set to: $($currentContext.Subscription.Name)" -ForegroundColor Green

# Create Monitoring Resource Group
Write-Host "[2/6] Creating monitoring resource group..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($MonitoringResourceGroup, "Create resource group")) {
    $monitoringRg = Get-AzResourceGroup -Name $MonitoringResourceGroup -ErrorAction SilentlyContinue
    if (-not $monitoringRg) {
        New-AzResourceGroup -Name $MonitoringResourceGroup -Location $Location -Tag @{
            "Environment" = "Production"
            "Purpose" = "Platform Monitoring"
            "ManagedBy" = "PowerShell"
            "Subscription" = "local-management-001"
        } | Out-Null
        Write-Host "✓ Resource group created: $MonitoringResourceGroup" -ForegroundColor Green
    } else {
        Write-Host "✓ Resource group already exists: $MonitoringResourceGroup" -ForegroundColor Green
    }
}

# Create Platform Log Analytics Workspace
Write-Host "[3/6] Creating platform Log Analytics workspace..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($PlatformWorkspaceName, "Create Log Analytics workspace")) {
    $platformWorkspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $MonitoringResourceGroup -Name $PlatformWorkspaceName -ErrorAction SilentlyContinue
    if (-not $platformWorkspace) {
        New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $MonitoringResourceGroup `
            -Name $PlatformWorkspaceName `
            -Location $Location `
            -Sku PerGB2018 `
            -RetentionInDays 90 `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Platform Monitoring"
                "Workload" = "All Platform Resources"
            } | Out-Null
        Write-Host "✓ Platform Log Analytics workspace created: $PlatformWorkspaceName" -ForegroundColor Green
        Write-Host "  - SKU: PerGB2018" -ForegroundColor Gray
        Write-Host "  - Retention: 90 days" -ForegroundColor Gray
    } else {
        Write-Host "✓ Platform Log Analytics workspace already exists: $PlatformWorkspaceName" -ForegroundColor Green
    }
}

# ============================================
# PHASE 2: Security Monitoring (Security Subscription)
# ============================================

Write-Host ""
Write-Host "=== PHASE 2: Security Monitoring Infrastructure ===" -ForegroundColor Yellow
Write-Host ""

# Set context to Security subscription
Write-Host "[4/6] Setting subscription context to Security..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $SecuritySubscriptionId | Out-Null
$currentContext = Get-AzContext
if ($currentContext.Subscription.Id -ne $SecuritySubscriptionId) {
    throw "Failed to set subscription context to Security subscription"
}
Write-Host "✓ Context set to: $($currentContext.Subscription.Name)" -ForegroundColor Green

# Verify Security Resource Group exists (created by 05-deploy-keyvault.ps1)
Write-Host "[5/6] Verifying security resource group..." -ForegroundColor Yellow
$securityRg = Get-AzResourceGroup -Name $SecurityResourceGroup -ErrorAction SilentlyContinue
if (-not $securityRg) {
    if ($PSCmdlet.ShouldProcess($SecurityResourceGroup, "Create resource group")) {
        New-AzResourceGroup -Name $SecurityResourceGroup -Location $Location -Tag @{
            "Environment" = "Production"
            "Purpose" = "Security & Compliance"
            "ManagedBy" = "PowerShell"
            "Subscription" = "local-security-001"
        } | Out-Null
        Write-Host "✓ Resource group created: $SecurityResourceGroup" -ForegroundColor Green
    }
} else {
    Write-Host "✓ Resource group already exists: $SecurityResourceGroup" -ForegroundColor Green
}

# Create Sentinel Log Analytics Workspace
Write-Host "[6/6] Creating Sentinel Log Analytics workspace..." -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess($SentinelWorkspaceName, "Create Log Analytics workspace")) {
    $sentinelWorkspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $SecurityResourceGroup -Name $SentinelWorkspaceName -ErrorAction SilentlyContinue
    if (-not $sentinelWorkspace) {
        New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $SecurityResourceGroup `
            -Name $SentinelWorkspaceName `
            -Location $Location `
            -Sku PerGB2018 `
            -RetentionInDays 90 `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Security Operations Center (SOC)"
                "Workload" = "Microsoft Sentinel"
            } | Out-Null
        Write-Host "✓ Sentinel Log Analytics workspace created: $SentinelWorkspaceName" -ForegroundColor Green
        Write-Host "  - SKU: PerGB2018" -ForegroundColor Gray
        Write-Host "  - Retention: 90 days" -ForegroundColor Gray
        Write-Host "  - Ready for Sentinel onboarding" -ForegroundColor Gray
    } else {
        Write-Host "✓ Sentinel Log Analytics workspace already exists: $SentinelWorkspaceName" -ForegroundColor Green
    }
}

# ============================================
# Summary and Next Steps
# ============================================

# ============================================
# PHASE 3: Data Collection Rules (DCRs)
# ============================================

Write-Host ""
Write-Host "=== PHASE 3: Data Collection Rules (DCRs) ===" -ForegroundColor Yellow
Write-Host ""

# Set context back to Management subscription
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
$platformWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName $MonitoringResourceGroup -Name $PlatformWorkspaceName

# Create Windows Performance Counters DCR
Write-Host "[7/11] Creating Windows Performance Counters DCR..." -ForegroundColor Yellow
$windowsPerfDcrName = "dcr-local-windows-perf-eastus2-001"
$existingDcr = Get-AzDataCollectionRule -ResourceGroupName $MonitoringResourceGroup -Name $windowsPerfDcrName -ErrorAction SilentlyContinue

if (-not $existingDcr) {
    if ($PSCmdlet.ShouldProcess($windowsPerfDcrName, "Create Windows Performance Counters DCR")) {
        # Define performance counter data source
        $perfCounters = New-AzPerfCounterDataSourceObject -Name "perfCounterDataSource" `
            -Stream "Microsoft-Perf" `
            -SamplingFrequencyInSecond 60 `
            -CounterSpecifier @(
                "\Processor(_Total)\% Processor Time",
                "\Memory\Available Bytes",
                "\Memory\% Committed Bytes In Use",
                "\LogicalDisk(_Total)\% Free Space",
                "\LogicalDisk(_Total)\Disk Reads/sec",
                "\LogicalDisk(_Total)\Disk Writes/sec",
                "\Network Interface(*)\Bytes Total/sec",
                "\System\Processor Queue Length"
            )
        
        # Define Log Analytics destination
        $logAnalyticsDestination = New-AzLogAnalyticsDestinationObject `
            -Name "centralWorkspace" `
            -WorkspaceResourceId $platformWs.ResourceId
        
        # Define data flow
        $dataFlow = New-AzDataFlowObject `
            -Stream "Microsoft-Perf" `
            -Destination "centralWorkspace"
        
        # Create DCR
        New-AzDataCollectionRule `
            -Name $windowsPerfDcrName `
            -ResourceGroupName $MonitoringResourceGroup `
            -Location $Location `
            -DataFlow $dataFlow `
            -DataSourcePerformanceCounter $perfCounters `
            -DestinationLogAnalytic $logAnalyticsDestination `
            -Description "Windows Performance Counters for Platform" `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Performance Monitoring"
                "Platform" = "Windows"
            } | Out-Null
        
        Write-Host "✓ Windows Performance Counters DCR created: $windowsPerfDcrName" -ForegroundColor Green
    }
} else {
    Write-Host "✓ Windows Performance Counters DCR already exists: $windowsPerfDcrName" -ForegroundColor Green
}

# Create Windows Event Logs DCR
Write-Host "[8/11] Creating Windows Event Logs DCR..." -ForegroundColor Yellow
$windowsEventDcrName = "dcr-local-windows-events-eastus2-001"
$existingEventDcr = Get-AzDataCollectionRule -ResourceGroupName $MonitoringResourceGroup -Name $windowsEventDcrName -ErrorAction SilentlyContinue

if (-not $existingEventDcr) {
    if ($PSCmdlet.ShouldProcess($windowsEventDcrName, "Create Windows Event Logs DCR")) {
        # Define Windows event log data source
        $windowsEvents = New-AzWindowsEventLogDataSourceObject -Name "eventLogsDataSource" `
            -Stream "Microsoft-Event" `
            -XPathQuery @(
                "Application!*[System[(Level=1 or Level=2 or Level=3)]]",
                "System!*[System[(Level=1 or Level=2 or Level=3)]]",
                "Security!*[System[(band(Keywords,13510798882111488))]]"
            )
        
        # Define data flow
        $eventDataFlow = New-AzDataFlowObject `
            -Stream "Microsoft-Event" `
            -Destination "centralWorkspace"
        
        # Create DCR
        New-AzDataCollectionRule `
            -Name $windowsEventDcrName `
            -ResourceGroupName $MonitoringResourceGroup `
            -Location $Location `
            -DataFlow $eventDataFlow `
            -DataSourceWindowsEventLog $windowsEvents `
            -DestinationLogAnalytic $logAnalyticsDestination `
            -Description "Windows Event Logs (Application, System, Security) for Platform" `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "Event Monitoring"
                "Platform" = "Windows"
            } | Out-Null
        
        Write-Host "✓ Windows Event Logs DCR created: $windowsEventDcrName" -ForegroundColor Green
    }
} else {
    Write-Host "✓ Windows Event Logs DCR already exists: $windowsEventDcrName" -ForegroundColor Green
}

# Create Linux Syslog DCR
Write-Host "[9/11] Creating Linux Syslog DCR..." -ForegroundColor Yellow
$linuxSyslogDcrName = "dcr-local-linux-syslog-eastus2-001"
$existingSyslogDcr = Get-AzDataCollectionRule -ResourceGroupName $MonitoringResourceGroup -Name $linuxSyslogDcrName -ErrorAction SilentlyContinue

if (-not $existingSyslogDcr) {
    if ($PSCmdlet.ShouldProcess($linuxSyslogDcrName, "Create Linux Syslog DCR")) {
        # Define syslog data source
        $syslog = New-AzSyslogDataSourceObject -Name "syslogDataSource" `
            -Stream "Microsoft-Syslog" `
            -FacilityName @("auth", "authpriv", "cron", "daemon", "kern", "syslog") `
            -LogLevel @("Warning", "Error", "Critical", "Alert", "Emergency")
        
        # Define data flow
        $syslogDataFlow = New-AzDataFlowObject `
            -Stream "Microsoft-Syslog" `
            -Destination "centralWorkspace"
        
        # Create DCR
        New-AzDataCollectionRule `
            -Name $linuxSyslogDcrName `
            -ResourceGroupName $MonitoringResourceGroup `
            -Location $Location `
            -DataFlow $syslogDataFlow `
            -DataSourceSyslog $syslog `
            -DestinationLogAnalytic $logAnalyticsDestination `
            -Description "Linux Syslog for Platform" `
            -Tag @{
                "Environment" = "Production"
                "Purpose" = "System Logging"
                "Platform" = "Linux"
            } | Out-Null
        
        Write-Host "✓ Linux Syslog DCR created: $linuxSyslogDcrName" -ForegroundColor Green
    }
} else {
    Write-Host "✓ Linux Syslog DCR already exists: $linuxSyslogDcrName" -ForegroundColor Green
}

# ============================================
# Summary and Next Steps
# ============================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Monitoring & Security Infrastructure Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Get workspace details
Set-AzContext -SubscriptionId $ManagementSubscriptionId | Out-Null
$platformWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName $MonitoringResourceGroup -Name $PlatformWorkspaceName
Set-AzContext -SubscriptionId $SecuritySubscriptionId | Out-Null
$sentinelWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName $SecurityResourceGroup -Name $SentinelWorkspaceName

Write-Host "Platform Monitoring (Management Subscription):" -ForegroundColor Yellow
Write-Host "  Resource Group: $MonitoringResourceGroup" -ForegroundColor White
Write-Host "  Workspace: $PlatformWorkspaceName" -ForegroundColor White
Write-Host "  Workspace ID: $($platformWs.CustomerId)" -ForegroundColor Gray
Write-Host "  Purpose: Operational monitoring for all platform resources" -ForegroundColor Gray
Write-Host ""

Write-Host "Security Monitoring (Security Subscription):" -ForegroundColor Yellow
Write-Host "  Resource Group: $SecurityResourceGroup" -ForegroundColor White
Write-Host "  Workspace: $SentinelWorkspaceName" -ForegroundColor White
Write-Host "  Workspace ID: $($sentinelWs.CustomerId)" -ForegroundColor Gray
Write-Host "  Purpose: Microsoft Sentinel SIEM/SOAR" -ForegroundColor Gray
Write-Host ""

Write-Host "Data Collection Rules Created:" -ForegroundColor Yellow
Write-Host "  Windows Performance Counters: $windowsPerfDcrName" -ForegroundColor White
Write-Host "  Windows Event Logs: $windowsEventDcrName" -ForegroundColor White
Write-Host "  Linux Syslog: $linuxSyslogDcrName" -ForegroundColor White
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Run Azure Policy deployment (07-deploy-azure-policies.ps1)" -ForegroundColor White
Write-Host "     - Deploys Azure Monitor Agent via policy (auto-installs on VMs)" -ForegroundColor Gray
Write-Host "     - Associates DCRs with VMs automatically" -ForegroundColor Gray
Write-Host "     - Configures patch orchestration prerequisite" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. For existing VMs: Create Policy Remediation Tasks" -ForegroundColor White
Write-Host "     - New VMs auto-comply; existing VMs need remediation" -ForegroundColor Gray
Write-Host "     - See 07-deploy-azure-policies.ps1 for remediation examples" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Enable Microsoft Defender for Cloud on all subscriptions" -ForegroundColor White
Write-Host "     - Navigate to Microsoft Defender for Cloud in Azure Portal" -ForegroundColor Gray
Write-Host "     - Enable enhanced security for Connectivity, Security, Management subscriptions" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Onboard Microsoft Sentinel" -ForegroundColor White
Write-Host "     - Navigate to Microsoft Sentinel in Azure Portal" -ForegroundColor Gray
Write-Host "     - Add Sentinel to workspace: $SentinelWorkspaceName" -ForegroundColor Gray
Write-Host "     - Configure data connectors (Azure Activity, Defender for Cloud, etc.)" -ForegroundColor Gray
Write-Host ""
Write-Host "  5. Configure Diagnostic Settings" -ForegroundColor White
Write-Host "     - Send platform resource logs to: $PlatformWorkspaceName" -ForegroundColor Gray
Write-Host "     - Send security logs to: $SentinelWorkspaceName" -ForegroundColor Gray
Write-Host ""

Write-Host "Workspace Resource IDs:" -ForegroundColor Cyan
Write-Host "  Platform: $($platformWs.ResourceId)" -ForegroundColor Gray
Write-Host "  Sentinel: $($sentinelWs.ResourceId)" -ForegroundColor Gray
Write-Host ""
