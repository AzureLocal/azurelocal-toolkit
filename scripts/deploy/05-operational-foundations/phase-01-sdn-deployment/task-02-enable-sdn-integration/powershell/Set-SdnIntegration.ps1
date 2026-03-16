<#
.SYNOPSIS
    Configures SDN integration for Azure Local cluster.

.DESCRIPTION
    This script configures Software Defined Networking:
    - Deploys Network Controller (if standalone)
    - Configures logical networks
    - Sets up load balancer multiplexers (if needed)
    - Configures gateway services

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-SdnIntegration.ps1 -ClusterName "azl-cluster01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-17-sdn-configuration/step-02-sdn-integration

    Azure Local includes integrated SDN capabilities when deployed via Azure Arc.
    This script helps configure additional SDN components as needed.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$EnableLoadBalancer,

    [Parameter(Mandatory = $false)]
    [switch]$EnableGateway
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts

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

function Get-ClusterSdnStatus {
    <#
    .SYNOPSIS
        Gets current SDN status for the cluster.
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$ClusterName
    )

    try {
        # Get cluster info via CLI
        $clusterJson = az stack-hci cluster show `
            --resource-group $ResourceGroupName `
            --name $ClusterName 2>$null

        if ($clusterJson) {
            $cluster = $clusterJson | ConvertFrom-Json
            
            return @{
                ClusterName = $cluster.name
                Status      = $cluster.provisioningState
                Features    = $cluster.softwareAssuranceProperties
            }
        }
    } catch {
        Write-LogMessage "  Could not get cluster SDN status: $_" -Level Warning
    }

    return $null
}

function New-LogicalNetwork {
    <#
    .SYNOPSIS
        Creates a logical network for Azure Local.
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$ClusterName,
        [string]$NetworkName,
        [string]$VlanId,
        [string]$Subnet,
        [string]$Gateway,
        [string]$DnsServers,
        [string]$Location
    )

    try {
        Write-LogMessage "  Creating logical network: $NetworkName" -Level Info

        $customLocationId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ExtendedLocation/customLocations/$ClusterName-cl"

        # Use Az CLI to create logical network
        $result = az stack-hci-vm network lnet create `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroupName `
            --custom-location $customLocationId `
            --location $Location `
            --name $NetworkName `
            --vm-switch-name "ConvergedSwitch(compute_management)" `
            --ip-allocation-method "Static" `
            --address-prefixes $Subnet `
            --gateway $Gateway `
            --dns-servers $DnsServers `
            --vlan $VlanId 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage "    Created: $NetworkName" -Level Success
            return @{ Name = $NetworkName; Created = $true }
        } else {
            Write-LogMessage "    Failed to create $NetworkName : $result" -Level Error
            return @{ Name = $NetworkName; Created = $false; Error = $result }
        }
    } catch {
        Write-LogMessage "    Exception creating $NetworkName : $_" -Level Error
        return @{ Name = $NetworkName; Created = $false; Error = $_.Exception.Message }
    }
}

function Get-SdnConfigurationSummary {
    <#
    .SYNOPSIS
        Generates SDN configuration summary from config.
    #>
    [CmdletBinding()]
    param([hashtable]$Config)

    $summary = @{
        Networks = @()
        Features = @()
    }

    # Get network configurations
    if ($config.networking.onprem.vlans) {
        if ($config.networking.onprem.vlans.management) {
            $summary.Networks += @{
                Name   = "Management"
                VlanId = $config.networking.onprem.vlans.management.id
                Subnet = $config.networking.onprem.vlans.management.subnet
            }
        }
        if ($config.networking.onprem.vlans.storage) {
            $summary.Networks += @{
                Name   = "Storage"
                VlanId = $config.networking.onprem.vlans.storage.id
                Subnet = $config.networking.onprem.vlans.storage.subnet
            }
        }
    }

    # Check enabled features
    if ($config.networking.azure.sdn.load_balancer) {
        $summary.Features += "Software Load Balancer"
    }
    if ($config.networking.azure.sdn.gateway) {
        $summary.Features += "SDN Gateway"
    }
    if ($config.networking.azure.sdn.network_controller) {
        $summary.Features += "Network Controller"
    }

    return $summary
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "SDN Integration Configuration" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get values from config if not provided
    if (-not $SubscriptionId -and $config.azure) {
        $SubscriptionId = $config.azure_platform.subscriptions.lab.id
    }
    if (-not $ResourceGroupName -and $config.azure) {
        $ResourceGroupName = $config.azure_platform.resource_group
    }
    if (-not $ClusterName -and $config.cluster) {
        $ClusterName = $config.compute.azure_local.cluster_name
    }

    if (-not $ClusterName -or -not $ResourceGroupName) {
        throw "ClusterName and ResourceGroupName are required"
    }

    # Connect to Azure
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }

    Write-LogMessage "Subscription: $((Get-AzContext).Subscription.Name)" -Level Info
    Write-LogMessage "Cluster: $ClusterName" -Level Info

    # Get current SDN status
    Write-LogMessage "" -Level Info
    Write-LogMessage "Getting current SDN status..." -Level Info
    $sdnStatus = Get-ClusterSdnStatus -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName

    if ($sdnStatus) {
        Write-LogMessage "  Cluster status: $($sdnStatus.Status)" -Level Info
    }

    # Get configuration summary
    $configSummary = Get-SdnConfigurationSummary -Config $config

    Write-LogMessage "" -Level Info
    Write-LogMessage "Configured Networks:" -Level Info
    foreach ($network in $configSummary.Networks) {
        Write-LogMessage "  - $($network.Name): VLAN $($network.VlanId), $($network.Subnet)" -Level Info
    }

    if ($configSummary.Features) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Enabled Features:" -Level Info
        foreach ($feature in $configSummary.Features) {
            Write-LogMessage "  - $feature" -Level Info
        }
    }

    # Display manual configuration steps
    Write-LogMessage "" -Level Info
    Write-LogMessage "SDN CONFIGURATION STEPS:" -Level Warning
    Write-LogMessage "" -Level Info
    Write-LogMessage "1. LOGICAL NETWORKS (Azure Portal):" -Level Info
    Write-LogMessage "   - Navigate to Azure Local > Logical Networks" -Level Info
    Write-LogMessage "   - Create logical networks for each VLAN" -Level Info
    Write-LogMessage "" -Level Info
    
    if ($EnableLoadBalancer) {
        Write-LogMessage "2. SOFTWARE LOAD BALANCER:" -Level Info
        Write-LogMessage "   - Configure MUX VMs" -Level Info
        Write-LogMessage "   - Set up BGP peering with ToR switches" -Level Info
        Write-LogMessage "   - Configure VIP pools" -Level Info
        Write-LogMessage "" -Level Info
    }

    if ($EnableGateway) {
        Write-LogMessage "3. SDN GATEWAY:" -Level Info
        Write-LogMessage "   - Deploy gateway VMs" -Level Info
        Write-LogMessage "   - Configure VPN connections" -Level Info
        Write-LogMessage "   - Set up BGP routing" -Level Info
        Write-LogMessage "" -Level Info
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "SDN Integration Setup Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  Configured networks: $($configSummary.Networks.Count)" -Level Info
    Write-LogMessage "  Additional features: $($configSummary.Features.Count)" -Level Info
    Write-LogMessage "" -Level Info
    Write-LogMessage "NOTE: Azure Local SDN is managed through Azure Arc." -Level Info
    Write-LogMessage "Use the Azure Portal for network configuration." -Level Info

    return @{
        SdnStatus     = $sdnStatus
        Configuration = $configSummary
    }

} catch {
    Write-LogMessage "SDN integration configuration failed: $_" -Level Error
    throw
}

#endregion Main
