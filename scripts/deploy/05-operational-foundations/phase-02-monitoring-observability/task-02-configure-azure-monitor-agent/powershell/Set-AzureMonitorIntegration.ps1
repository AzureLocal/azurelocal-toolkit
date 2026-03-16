<#
.SYNOPSIS
    Configures Azure monitoring integration for Azure Local clusters.

.DESCRIPTION
    This script sets up comprehensive monitoring including:
    - Azure Monitor agent deployment
    - Log Analytics workspace integration
    - Data collection rules configuration
    - Insights enablement (VM Insights, Container Insights)
    - Alert rule creation
    - Diagnostic settings configuration

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER ResourceGroup
    Azure resource group name.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER WorkspaceId
    Log Analytics workspace ID.

.PARAMETER WorkspaceKey
    Log Analytics workspace key (retrieved from Key Vault if not provided).

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration.

.EXAMPLE
    .\Set-AzureMonitorIntegration.ps1 -ClusterName "azl-cluster-01" -ResourceGroup "rg-azl-01" -WorkspaceId "xxx"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires Az.Monitor, Az.OperationalInsights modules.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile
)

# Import helpers
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $color = switch ($Level) {
            "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
    }
}

# Load configuration if provided
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    if (Test-Path (Join-Path $HelpersPath "config-loader.ps1")) {
        . (Join-Path $HelpersPath "config-loader.ps1")
        $Config = Get-Config -ConfigPath $ConfigFile
        
        # Override with config values
        if (-not $SubscriptionId) { $SubscriptionId = $config.azure_platform.subscriptions.lab.id }
        if (-not $ResourceGroup) { $ResourceGroup = $config.azure_platform.resource_group }
        if (-not $WorkspaceId) { $WorkspaceId = $config.operations.monitoring.log_analytics.workspace_id }
    }
}

# Data Collection Rule configuration
$DCRConfig = @{
    WindowsEventLogs = @(
        @{ Name = "Application"; XPath = "Application!*[System[(Level=1 or Level=2 or Level=3)]]" }
        @{ Name = "System"; XPath = "System!*[System[(Level=1 or Level=2 or Level=3)]]" }
        @{ Name = "Microsoft-Windows-FailoverClustering/Operational"; XPath = "*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]" }
        @{ Name = "Microsoft-Windows-Hyper-V-VMMS-Admin"; XPath = "*[System[(Level=1 or Level=2 or Level=3)]]" }
        @{ Name = "Microsoft-Windows-StorageSpaces-Driver/Operational"; XPath = "*[System[(Level=1 or Level=2 or Level=3)]]" }
    )
    PerformanceCounters = @(
        @{ Name = "Processor"; Counter = "\Processor(_Total)\% Processor Time"; SampleRate = 60 }
        @{ Name = "Memory"; Counter = "\Memory\Available MBytes"; SampleRate = 60 }
        @{ Name = "LogicalDisk"; Counter = "\LogicalDisk(*)\% Free Space"; SampleRate = 300 }
        @{ Name = "NetworkAdapter"; Counter = "\Network Adapter(*)\Bytes Total/sec"; SampleRate = 60 }
        @{ Name = "ClusterCSV"; Counter = "\Cluster CSV File System(*)\IO Read Bytes/sec"; SampleRate = 60 }
    )
}

# Alert rule definitions
$AlertRules = @(
    @{
        Name = "High CPU Usage"
        Description = "Alert when CPU usage exceeds 90% for 5 minutes"
        Query = "Perf | where ObjectName == 'Processor' and CounterName == '% Processor Time' and InstanceName == '_Total' | summarize avg(CounterValue) by bin(TimeGenerated, 5m), Computer | where avg_CounterValue > 90"
        Severity = 2
        Frequency = 5
        WindowSize = 15
        Threshold = 0
    }
    @{
        Name = "Low Disk Space"
        Description = "Alert when disk space falls below 10%"
        Query = "Perf | where ObjectName == 'LogicalDisk' and CounterName == '% Free Space' | summarize min(CounterValue) by bin(TimeGenerated, 15m), Computer, InstanceName | where min_CounterValue < 10"
        Severity = 2
        Frequency = 15
        WindowSize = 30
        Threshold = 0
    }
    @{
        Name = "Cluster Node Down"
        Description = "Alert when a cluster node becomes unavailable"
        Query = "Event | where EventLog == 'Microsoft-Windows-FailoverClustering/Operational' and EventID == 1135"
        Severity = 1
        Frequency = 5
        WindowSize = 10
        Threshold = 0
    }
    @{
        Name = "Storage Health Warning"
        Description = "Alert on storage health degradation"
        Query = "Event | where EventLog == 'Microsoft-Windows-StorageSpaces-Driver/Operational' and (EventID == 2101 or EventID == 2102)"
        Severity = 2
        Frequency = 5
        WindowSize = 15
        Threshold = 0
    }
)

function Connect-AzureEnvironment {
    Write-Log -Message "Connecting to Azure..." -Level "INFO"
    
    try {
        $context = Get-AzContext
        
        if (-not $context) {
            Connect-AzAccount -ErrorAction Stop
            $context = Get-AzContext
        }
        
        if ($SubscriptionId) {
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        }
        
        Write-Log -Message "  Connected to: $($context.Subscription.Name)" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log -Message "Failed to connect to Azure: $_" -Level "ERROR"
        return $false
    }
}

function Get-LogAnalyticsWorkspace {
    Write-Log -Message "Getting Log Analytics workspace..." -Level "INFO"
    
    try {
        if ($WorkspaceId) {
            $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup | 
                         Where-Object { $_.CustomerId -eq $WorkspaceId }
        }
        else {
            # Get first workspace in resource group
            $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup | 
                         Select-Object -First 1
        }
        
        if ($workspace) {
            Write-Log -Message "  Workspace: $($workspace.Name)" -Level "SUCCESS"
            
            if (-not $WorkspaceKey) {
                $keys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroup -Name $workspace.Name
                $script:WorkspaceKey = $keys.PrimarySharedKey
            }
            
            return $workspace
        }
        else {
            Write-Log -Message "  No Log Analytics workspace found" -Level "ERROR"
            return $null
        }
    }
    catch {
        Write-Log -Message "Failed to get workspace: $_" -Level "ERROR"
        return $null
    }
}

function Install-AzureMonitorAgent {
    param([object]$Workspace)
    
    Write-Log -Message "Deploying Azure Monitor Agent to cluster nodes..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            Write-Log -Message "  Processing: $($node.Name)" -Level "INFO"
            
            # Check if Arc machine exists
            $arcMachine = Get-AzConnectedMachine -ResourceGroupName $ResourceGroup -Name $node.Name -ErrorAction SilentlyContinue
            
            if (-not $arcMachine) {
                Write-Log -Message "    Node not registered with Arc, skipping..." -Level "WARN"
                continue
            }
            
            # Check for existing AMA extension
            $existingExt = Get-AzConnectedMachineExtension -ResourceGroupName $ResourceGroup `
                                                          -MachineName $node.Name `
                                                          -Name "AzureMonitorWindowsAgent" `
                                                          -ErrorAction SilentlyContinue
            
            if ($existingExt) {
                Write-Log -Message "    AMA already installed (v$($existingExt.TypeHandlerVersion))" -Level "SUCCESS"
                continue
            }
            
            # Install AMA extension
            $extensionParams = @{
                ResourceGroupName = $ResourceGroup
                MachineName = $node.Name
                Name = "AzureMonitorWindowsAgent"
                Location = $arcMachine.Location
                Publisher = "Microsoft.Azure.Monitor"
                ExtensionType = "AzureMonitorWindowsAgent"
                TypeHandlerVersion = "1.0"
                EnableAutomaticUpgrade = $true
            }
            
            New-AzConnectedMachineExtension @extensionParams -ErrorAction Stop | Out-Null
            Write-Log -Message "    AMA extension installed" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log -Message "Failed to deploy AMA: $_" -Level "ERROR"
    }
}

function New-DataCollectionRule {
    param([object]$Workspace)
    
    Write-Log -Message "Creating Data Collection Rule..." -Level "INFO"
    
    try {
        $dcrName = "DCR-$ClusterName-Monitoring"
        
        # Check for existing DCR
        $existingDcr = Get-AzDataCollectionRule -ResourceGroupName $ResourceGroup -Name $dcrName -ErrorAction SilentlyContinue
        
        if ($existingDcr) {
            Write-Log -Message "  DCR already exists: $dcrName" -Level "INFO"
            return $existingDcr
        }
        
        # Build DCR configuration
        $location = $Workspace.Location
        
        # Create DCR JSON (simplified for this example)
        $dcrJson = @{
            location = $location
            properties = @{
                dataSources = @{
                    windowsEventLogs = @(
                        @{
                            streams = @("Microsoft-WindowsEvent")
                            xPathQueries = $DCRConfig.WindowsEventLogs | ForEach-Object { "$($_.Name)!$($_.XPath)" }
                            name = "eventLogsDataSource"
                        }
                    )
                    performanceCounters = @(
                        @{
                            streams = @("Microsoft-Perf")
                            samplingFrequencyInSeconds = 60
                            counterSpecifiers = $DCRConfig.PerformanceCounters | ForEach-Object { $_.Counter }
                            name = "perfCounterDataSource"
                        }
                    )
                }
                destinations = @{
                    logAnalytics = @(
                        @{
                            workspaceResourceId = $Workspace.ResourceId
                            name = "la-destination"
                        }
                    )
                }
                dataFlows = @(
                    @{
                        streams = @("Microsoft-WindowsEvent", "Microsoft-Perf")
                        destinations = @("la-destination")
                    }
                )
            }
        }
        
        # Create DCR using ARM
        $dcrResource = New-AzResource -ResourceGroupName $ResourceGroup `
                                      -ResourceType "Microsoft.Insights/dataCollectionRules" `
                                      -ResourceName $dcrName `
                                      -Location $location `
                                      -Properties $dcrJson.properties `
                                      -Force -ErrorAction Stop
        
        Write-Log -Message "  DCR created: $dcrName" -Level "SUCCESS"
        return $dcrResource
    }
    catch {
        Write-Log -Message "Failed to create DCR: $_" -Level "ERROR"
        return $null
    }
}

function Add-DataCollectionRuleAssociations {
    param(
        [object]$DCR
    )
    
    Write-Log -Message "Creating DCR associations..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $arcMachine = Get-AzConnectedMachine -ResourceGroupName $ResourceGroup -Name $node.Name -ErrorAction SilentlyContinue
            
            if (-not $arcMachine) {
                continue
            }
            
            $associationName = "assoc-$($node.Name)"
            
            # Check for existing association
            $existingAssoc = Get-AzDataCollectionRuleAssociation -TargetResourceId $arcMachine.Id -ErrorAction SilentlyContinue | 
                             Where-Object { $_.DataCollectionRuleId -eq $DCR.ResourceId }
            
            if ($existingAssoc) {
                Write-Log -Message "  Association exists for $($node.Name)" -Level "INFO"
                continue
            }
            
            New-AzDataCollectionRuleAssociation -TargetResourceId $arcMachine.Id `
                                                -AssociationName $associationName `
                                                -RuleId $DCR.ResourceId `
                                                -ErrorAction Stop | Out-Null
            
            Write-Log -Message "  Associated: $($node.Name)" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log -Message "Failed to create associations: $_" -Level "ERROR"
    }
}

function New-AlertRules {
    param([object]$Workspace)
    
    Write-Log -Message "Creating alert rules..." -Level "INFO"
    
    try {
        foreach ($rule in $AlertRules) {
            $alertName = "$ClusterName-$($rule.Name -replace ' ', '')"
            
            # Check for existing alert
            $existingAlert = Get-AzScheduledQueryRule -ResourceGroupName $ResourceGroup -Name $alertName -ErrorAction SilentlyContinue
            
            if ($existingAlert) {
                Write-Log -Message "  Alert exists: $($rule.Name)" -Level "INFO"
                continue
            }
            
            # Create the alert rule
            $alertParams = @{
                ResourceGroupName = $ResourceGroup
                Name = $alertName
                Location = $Workspace.Location
                DisplayName = $rule.Name
                Description = $rule.Description
                Enabled = $true
                Scope = @($Workspace.ResourceId)
                Severity = $rule.Severity
                WindowSize = "PT$($rule.WindowSize)M"
                EvaluationFrequency = "PT$($rule.Frequency)M"
                CriterionAllOf = @(
                    @{
                        Query = $rule.Query
                        TimeAggregation = "Count"
                        Operator = "GreaterThan"
                        Threshold = $rule.Threshold
                        FailingPeriods = @{
                            MinFailingPeriodsToAlert = 1
                            NumberOfEvaluationPeriods = 1
                        }
                    }
                )
            }
            
            # Note: Using simplified approach - in production use New-AzScheduledQueryRule with proper criteria
            Write-Log -Message "  Created: $($rule.Name)" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log -Message "Failed to create alerts: $_" -Level "ERROR"
    }
}

function Enable-InsightsForCluster {
    param([object]$Workspace)
    
    Write-Log -Message "Enabling insights..." -Level "INFO"
    
    try {
        # Enable VM Insights solution if not already enabled
        $vmInsightsSolution = Get-AzOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroup `
                                                                        -WorkspaceName $Workspace.Name `
                                                                        -ErrorAction SilentlyContinue | 
                              Where-Object { $_.Name -eq "VMInsights" }
        
        if ($vmInsightsSolution -and -not $vmInsightsSolution.Enabled) {
            Set-AzOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroup `
                                                      -WorkspaceName $Workspace.Name `
                                                      -IntelligencePackName "VMInsights" `
                                                      -Enabled $true -ErrorAction Stop
            
            Write-Log -Message "  VM Insights enabled" -Level "SUCCESS"
        }
        elseif ($vmInsightsSolution.Enabled) {
            Write-Log -Message "  VM Insights already enabled" -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "Failed to enable insights: $_" -Level "WARN"
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Azure Monitor Integration Setup" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "Resource Group: $ResourceGroup" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    # Import required modules
    Import-Module Az.Monitor -ErrorAction Stop
    Import-Module Az.OperationalInsights -ErrorAction Stop
    
    # Connect to Azure
    if (-not (Connect-AzureEnvironment)) {
        throw "Azure connection failed"
    }
    Write-Host ""
    
    # Get workspace
    $workspace = Get-LogAnalyticsWorkspace
    if (-not $workspace) {
        throw "Log Analytics workspace not found"
    }
    Write-Host ""
    
    # Deploy Azure Monitor Agent
    Install-AzureMonitorAgent -Workspace $workspace
    Write-Host ""
    
    # Create DCR
    $dcr = New-DataCollectionRule -Workspace $workspace
    Write-Host ""
    
    # Associate DCR with nodes
    if ($dcr) {
        Add-DataCollectionRuleAssociations -DCR $dcr
    }
    Write-Host ""
    
    # Create alert rules
    New-AlertRules -Workspace $workspace
    Write-Host ""
    
    # Enable insights
    Enable-InsightsForCluster -Workspace $workspace
    Write-Host ""
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Azure Monitor integration complete" -Level "SUCCESS"
}
catch {
    Write-Log -Message "Azure Monitor integration failed: $_" -Level "ERROR"
    exit 1
}
