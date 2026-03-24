<#
.SYNOPSIS
    Enables Microsoft Defender for Cloud on Azure Local resources.

.DESCRIPTION
    This script configures Defender for Cloud:
    - Enables Defender for Servers plan
    - Enables Defender for Storage plan
    - Configures auto-provisioning of agents
    - Validates Defender enrollment and secure score

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER ResourceGroupName
    Azure resource group name.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Enable-DefenderForCloud.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 05-operational-foundations
    Phase: phase-04-security-governance
    Task: task-01-enable-defender-for-cloud
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml"
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Security

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

function Enable-DefenderPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$PlanName,
        [string]$Tier = 'Standard'
    )
    if ($PSCmdlet.ShouldProcess($PlanName, "Enable Defender plan")) {
        Write-LogMessage "Enabling Defender plan: $PlanName ($Tier)" -Level Info
        Set-AzSecurityPricing -Name $PlanName -PricingTier $Tier
        Write-LogMessage "Defender plan enabled: $PlanName" -Level Success
    }
}

#endregion Functions

#region Main

Write-LogMessage "=== Enable Defender for Cloud ===" -Level Info

# Load configuration
$config = Import-InfrastructureConfig -Path $ConfigPath
if ($config) {
    $SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { $config.azure.subscription_id }
    $ResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } else { $config.azure.resource_group_name }
}

if (-not $SubscriptionId) {
    Write-LogMessage "SubscriptionId is required." -Level Error
    exit 1
}

# Set subscription context
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-LogMessage "Working in subscription: $SubscriptionId" -Level Info

# Check current Defender status
Write-LogMessage "Checking current Defender for Cloud status..." -Level Info
$currentPricing = Get-AzSecurityPricing

foreach ($plan in $currentPricing) {
    $status = if ($plan.PricingTier -eq 'Standard') { 'Enabled' } else { 'Disabled' }
    Write-LogMessage "  $($plan.Name): $status" -Level Info
}

# Enable required Defender plans
$requiredPlans = @(
    @{ Name = 'VirtualMachines'; Description = 'Defender for Servers' }
    @{ Name = 'StorageAccounts'; Description = 'Defender for Storage' }
    @{ Name = 'KeyVaults'; Description = 'Defender for Key Vault' }
    @{ Name = 'Arm'; Description = 'Defender for Resource Manager' }
)

foreach ($plan in $requiredPlans) {
    $current = $currentPricing | Where-Object { $_.Name -eq $plan.Name }
    if ($current -and $current.PricingTier -eq 'Standard') {
        Write-LogMessage "$($plan.Description) already enabled." -Level Info
    }
    else {
        Enable-DefenderPlan -PlanName $plan.Name
    }
}

# Configure auto-provisioning
Write-LogMessage "Configuring auto-provisioning settings..." -Level Info
$autoProvision = Get-AzSecurityAutoProvisioningSetting -Name 'default'
if ($autoProvision.AutoProvision -ne 'On') {
    Set-AzSecurityAutoProvisioningSetting -Name 'default' -EnableAutoProvision
    Write-LogMessage "Auto-provisioning enabled." -Level Success
}
else {
    Write-LogMessage "Auto-provisioning already enabled." -Level Info
}

# Display secure score
Write-LogMessage "Retrieving secure score..." -Level Info
$secureScore = Get-AzSecuritySecureScore
foreach ($score in $secureScore) {
    Write-LogMessage "  Secure Score: $($score.CurrentScore)/$($score.MaxScore) ($([math]::Round($score.Percentage, 1))%)" -Level Info
}

Write-LogMessage "=== Defender for Cloud Configuration Complete ===" -Level Success
Write-LogMessage "Allow up to 24 hours for initial assessment data to populate." -Level Info

#endregion Main
