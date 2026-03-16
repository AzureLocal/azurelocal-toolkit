<#
.SYNOPSIS
    Configures Network Security Groups for Azure Local.

.DESCRIPTION
    This script configures NSGs for Azure Local VMs:
    - Creates NSG rules for common scenarios
    - Applies baseline security rules
    - Configures application-specific rules

.PARAMETER ResourceGroupName
    Azure resource group name.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-NsgConfiguration.ps1 -ResourceGroupName "rg-azurelocal-prod"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 06-operational-foundations
    Step: stage-17-sdn-configuration/step-03-nsg-configuration
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$ApplyBaseline
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

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

function Get-BaselineNsgRules {
    <#
    .SYNOPSIS
        Returns baseline NSG rules for Azure Local VMs.
    #>
    return @(
        # Deny rules (high priority)
        @{
            Name                   = "DenyAllInbound"
            Priority               = 4096
            Direction              = "Inbound"
            Access                 = "Deny"
            Protocol               = "*"
            SourcePortRange        = "*"
            DestinationPortRange   = "*"
            SourceAddressPrefix    = "*"
            DestinationAddressPrefix = "*"
            Description            = "Deny all inbound traffic by default"
        }

        # Allow rules
        @{
            Name                   = "AllowRDP"
            Priority               = 100
            Direction              = "Inbound"
            Access                 = "Allow"
            Protocol               = "TCP"
            SourcePortRange        = "*"
            DestinationPortRange   = "3389"
            SourceAddressPrefix    = "VirtualNetwork"
            DestinationAddressPrefix = "*"
            Description            = "Allow RDP from virtual network"
        }
        @{
            Name                   = "AllowSSH"
            Priority               = 110
            Direction              = "Inbound"
            Access                 = "Allow"
            Protocol               = "TCP"
            SourcePortRange        = "*"
            DestinationPortRange   = "22"
            SourceAddressPrefix    = "VirtualNetwork"
            DestinationAddressPrefix = "*"
            Description            = "Allow SSH from virtual network"
        }
        @{
            Name                   = "AllowWinRM"
            Priority               = 120
            Direction              = "Inbound"
            Access                 = "Allow"
            Protocol               = "TCP"
            SourcePortRange        = "*"
            DestinationPortRange   = "5985-5986"
            SourceAddressPrefix    = "VirtualNetwork"
            DestinationAddressPrefix = "*"
            Description            = "Allow WinRM from virtual network"
        }
        @{
            Name                   = "AllowICMP"
            Priority               = 130
            Direction              = "Inbound"
            Access                 = "Allow"
            Protocol               = "ICMP"
            SourcePortRange        = "*"
            DestinationPortRange   = "*"
            SourceAddressPrefix    = "VirtualNetwork"
            DestinationAddressPrefix = "*"
            Description            = "Allow ICMP from virtual network"
        }
    )
}

function Get-WebServerNsgRules {
    <#
    .SYNOPSIS
        Returns NSG rules for web server workloads.
    #>
    return @(
        @{
            Name                   = "AllowHTTP"
            Priority               = 200
            Direction              = "Inbound"
            Access                 = "Allow"
            Protocol               = "TCP"
            SourcePortRange        = "*"
            DestinationPortRange   = "80"
            SourceAddressPrefix    = "*"
            DestinationAddressPrefix = "*"
            Description            = "Allow HTTP traffic"
        }
        @{
            Name                   = "AllowHTTPS"
            Priority               = 210
            Direction              = "Inbound"
            Access                 = "Allow"
            Protocol               = "TCP"
            SourcePortRange        = "*"
            DestinationPortRange   = "443"
            SourceAddressPrefix    = "*"
            DestinationAddressPrefix = "*"
            Description            = "Allow HTTPS traffic"
        }
    )
}

function Get-SqlServerNsgRules {
    <#
    .SYNOPSIS
        Returns NSG rules for SQL Server workloads.
    #>
    return @(
        @{
            Name                   = "AllowSQL"
            Priority               = 300
            Direction              = "Inbound"
            Access                 = "Allow"
            Protocol               = "TCP"
            SourcePortRange        = "*"
            DestinationPortRange   = "1433"
            SourceAddressPrefix    = "VirtualNetwork"
            DestinationAddressPrefix = "*"
            Description            = "Allow SQL Server from virtual network"
        }
    )
}

function New-NsgWithRules {
    <#
    .SYNOPSIS
        Creates an NSG with specified rules.
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$ResourceGroupName,
        [string]$Location,
        [array]$Rules,
        [hashtable]$Tags
    )

    # Check if NSG exists
    $existingNsg = Get-AzNetworkSecurityGroup -Name $Name -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

    if ($existingNsg) {
        Write-LogMessage "  NSG exists: $Name" -Level Info
        return $existingNsg
    }

    # Create security rules
    $securityRules = @()
    foreach ($rule in $Rules) {
        $ruleConfig = New-AzNetworkSecurityRuleConfig `
            -Name $rule.Name `
            -Priority $rule.Priority `
            -Direction $rule.Direction `
            -Access $rule.Access `
            -Protocol $rule.Protocol `
            -SourcePortRange $rule.SourcePortRange `
            -DestinationPortRange $rule.DestinationPortRange `
            -SourceAddressPrefix $rule.SourceAddressPrefix `
            -DestinationAddressPrefix $rule.DestinationAddressPrefix `
            -Description $rule.Description

        $securityRules += $ruleConfig
    }

    # Create NSG
    $nsgParams = @{
        Name              = $Name
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        SecurityRules     = $securityRules
    }
    
    if ($Tags) {
        $nsgParams['Tag'] = $Tags
    }

    $nsg = New-AzNetworkSecurityGroup @nsgParams

    Write-LogMessage "  Created NSG: $Name with $($securityRules.Count) rules" -Level Success
    return $nsg
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "NSG Configuration" -Level Info
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
    if (-not $Location -and $config.azure) {
        $Location = $config.azure_platform.location
    }

    if (-not $ResourceGroupName) {
        throw "ResourceGroupName is required"
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
    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info
    Write-LogMessage "Location: $Location" -Level Info

    $tags = @{
        Environment = "Production"
        ManagedBy   = "Azure Local Cloud"
        Purpose     = "AzureLocal"
    }

    $results = @()

    # Create baseline NSG
    if ($ApplyBaseline -or $PSCmdlet.ShouldProcess("Baseline NSG", "Create")) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Creating baseline NSG..." -Level Info
        
        $baselineRules = Get-BaselineNsgRules
        $baselineNsg = New-NsgWithRules `
            -Name "nsg-azurelocal-baseline" `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Rules $baselineRules `
            -Tags $tags

        $results += @{
            Name  = "nsg-azurelocal-baseline"
            Rules = $baselineRules.Count
            Type  = "Baseline"
        }
    }

    # Create web server NSG
    if ($PSCmdlet.ShouldProcess("Web Server NSG", "Create")) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Creating web server NSG..." -Level Info
        
        $webRules = Get-BaselineNsgRules + Get-WebServerNsgRules
        $webNsg = New-NsgWithRules `
            -Name "nsg-azurelocal-web" `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Rules $webRules `
            -Tags $tags

        $results += @{
            Name  = "nsg-azurelocal-web"
            Rules = $webRules.Count
            Type  = "WebServer"
        }
    }

    # Create SQL Server NSG
    if ($PSCmdlet.ShouldProcess("SQL Server NSG", "Create")) {
        Write-LogMessage "" -Level Info
        Write-LogMessage "Creating SQL Server NSG..." -Level Info
        
        $sqlRules = Get-BaselineNsgRules + Get-SqlServerNsgRules
        $sqlNsg = New-NsgWithRules `
            -Name "nsg-azurelocal-sql" `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Rules $sqlRules `
            -Tags $tags

        $results += @{
            Name  = "nsg-azurelocal-sql"
            Rules = $sqlRules.Count
            Type  = "SqlServer"
        }
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "NSG Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    foreach ($nsg in $results) {
        Write-LogMessage "  $($nsg.Name): $($nsg.Rules) rules ($($nsg.Type))" -Level Info
    }

    Write-LogMessage "" -Level Info
    Write-LogMessage "NEXT STEPS:" -Level Warning
    Write-LogMessage "  1. Associate NSGs with logical networks in Azure Portal" -Level Info
    Write-LogMessage "  2. Apply NSGs to VMs as needed" -Level Info
    Write-LogMessage "  3. Monitor NSG flow logs for security analysis" -Level Info

    return @{
        Results = $results
    }

} catch {
    Write-LogMessage "NSG configuration failed: $_" -Level Error
    throw
}

#endregion Main
