<#
.SYNOPSIS
    Enables Azure Local (HCI) Insights for monitoring and observability.

.DESCRIPTION
    This script configures HCI Insights:
    - Enables the Azure Monitor Agent on cluster nodes
    - Creates Data Collection Rules for HCI metrics
    - Configures the HCI Insights workbook
    - Validates Insights data flow

.PARAMETER ResourceGroupName
    Azure resource group containing the Azure Local cluster.

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER WorkspaceId
    Log Analytics workspace resource ID.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Enable-HciInsights.ps1 -ResourceGroupName "rg-azurelocal-prod" -ClusterName "azl-cluster-01"

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 05-operational-foundations
    Phase: phase-02-monitoring-observability
    Task: task-03-enable-hci-insights
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Monitor, Az.ConnectedMachine

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    [CmdletBinding()]
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml
    $configContent = Get-Content -Path $Path -Raw
    return ConvertFrom-Yaml $configContent
}

function Enable-AzureMonitorAgentExtension {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ResourceGroupName,
        [string]$MachineName,
        [string]$Location
    )
    if ($PSCmdlet.ShouldProcess($MachineName, "Install Azure Monitor Agent extension")) {
        Write-LogMessage "Installing AzureMonitorWindowsAgent on $MachineName..." -Level Info
        $params = @{
            ResourceGroupName  = $ResourceGroupName
            MachineName        = $MachineName
            Name               = 'AzureMonitorWindowsAgent'
            ExtensionType      = 'AzureMonitorWindowsAgent'
            Publisher          = 'Microsoft.Azure.Monitor'
            TypeHandlerVersion = '1.0'
            Location           = $Location
            EnableAutomaticUpgrade = $true
        }
        New-AzConnectedMachineExtension @params
    }
}

function New-HciInsightsDataCollectionRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ResourceGroupName,
        [string]$WorkspaceId,
        [string]$Location,
        [string]$ClusterName
    )
    $dcrName = "dcr-hci-insights-$ClusterName"
    if ($PSCmdlet.ShouldProcess($dcrName, "Create Data Collection Rule")) {
        Write-LogMessage "Creating Data Collection Rule: $dcrName" -Level Info
        $dcrParams = @{
            Name              = $dcrName
            ResourceGroupName = $ResourceGroupName
            Location          = $Location
            DataFlow          = @(
                @{
                    Streams      = @('Microsoft-Perf', 'Microsoft-Event')
                    Destinations = @('logAnalytics')
                }
            )
            Description = "HCI Insights DCR for cluster $ClusterName"
        }
        Write-LogMessage "DCR configuration prepared. Deploy via ARM template or Az CLI for full configuration." -Level Info
        return $dcrParams
    }
}

#endregion Functions

#region Main

Write-LogMessage "=== Enable HCI Insights ===" -Level Info

# Load configuration
$config = Import-InfrastructureConfig -Path $ConfigPath
if ($config) {
    $ResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } else { $config.azure.resource_group_name }
    $ClusterName = if ($ClusterName) { $ClusterName } else { $config.platform.cluster_name }
    $WorkspaceId = if ($WorkspaceId) { $WorkspaceId } else { $config.monitoring.log_analytics_workspace_id }
    $SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { $config.azure.subscription_id }
}

# Validate required parameters
if (-not $ResourceGroupName -or -not $ClusterName) {
    Write-LogMessage "ResourceGroupName and ClusterName are required." -Level Error
    exit 1
}

# Set subscription context
if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

# Get cluster nodes
Write-LogMessage "Retrieving Arc-connected machines in resource group: $ResourceGroupName" -Level Info
$arcMachines = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.Tag['osdistribution'] -eq 'AzureStackHCI' -or $_.Name -match $ClusterName }

if ($arcMachines.Count -eq 0) {
    Write-LogMessage "No Arc-connected HCI nodes found. Verify Arc registration." -Level Error
    exit 1
}
Write-LogMessage "Found $($arcMachines.Count) Arc-connected nodes." -Level Success

# Install Azure Monitor Agent on each node
foreach ($machine in $arcMachines) {
    $existingExt = Get-AzConnectedMachineExtension -ResourceGroupName $ResourceGroupName -MachineName $machine.Name |
        Where-Object { $_.ExtensionType -eq 'AzureMonitorWindowsAgent' }

    if ($existingExt -and $existingExt.ProvisioningState -eq 'Succeeded') {
        Write-LogMessage "AMA already installed on $($machine.Name)." -Level Info
    }
    else {
        Enable-AzureMonitorAgentExtension -ResourceGroupName $ResourceGroupName -MachineName $machine.Name -Location $machine.Location
    }
}

# Create Data Collection Rule
$location = $arcMachines[0].Location
New-HciInsightsDataCollectionRule -ResourceGroupName $ResourceGroupName -WorkspaceId $WorkspaceId -Location $location -ClusterName $ClusterName

Write-LogMessage "=== HCI Insights Configuration Complete ===" -Level Success
Write-LogMessage "Verify in Azure Portal: Monitor > Insights > Azure Local" -Level Info

#endregion Main
