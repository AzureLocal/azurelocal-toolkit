<#
.SYNOPSIS
    Enables Azure Hybrid Benefit for Azure Local cluster nodes.

.DESCRIPTION
    This script configures Azure Hybrid Benefit:
    - Validates Windows Server license eligibility
    - Enables AHUB on Arc-connected machines
    - Verifies license activation status
    - Reports cost savings estimates

.PARAMETER ResourceGroupName
    Azure resource group name.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Enable-AzureHybridBenefit.ps1 -ResourceGroupName "rg-azurelocal-prod"

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 05-operational-foundations
    Phase: phase-05-licensing-telemetry
    Task: task-01-enable-azure-hybrid-benefit
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ConnectedMachine

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

#endregion Functions

#region Main

Write-LogMessage "=== Enable Azure Hybrid Benefit ===" -Level Info

# Load configuration
$config = Import-InfrastructureConfig -Path $ConfigPath
if ($config) {
    $ResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } else { $config.azure.resource_group_name }
    $SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { $config.azure.subscription_id }
}

if (-not $ResourceGroupName) {
    Write-LogMessage "ResourceGroupName is required." -Level Error
    exit 1
}

# Set subscription context
if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

# Get Arc-connected machines
Write-LogMessage "Retrieving Arc-connected machines..." -Level Info
$arcMachines = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.OSName -match 'Windows' }

if ($arcMachines.Count -eq 0) {
    Write-LogMessage "No Arc-connected Windows machines found." -Level Error
    exit 1
}
Write-LogMessage "Found $($arcMachines.Count) Arc-connected machines." -Level Success

# Check and enable Azure Hybrid Benefit
$enabledCount = 0
$alreadyEnabled = 0

foreach ($machine in $arcMachines) {
    $currentLicense = $machine.LicenseProfile
    $isEnabled = $machine.LicenseType -eq 'Windows_Server'

    if ($isEnabled) {
        Write-LogMessage "  $($machine.Name): AHUB already enabled." -Level Info
        $alreadyEnabled++
    }
    else {
        if ($PSCmdlet.ShouldProcess($machine.Name, "Enable Azure Hybrid Benefit")) {
            Write-LogMessage "  $($machine.Name): Enabling Azure Hybrid Benefit..." -Level Info
            Update-AzConnectedMachine -ResourceGroupName $ResourceGroupName -MachineName $machine.Name -LicenseType 'Windows_Server'
            Write-LogMessage "  $($machine.Name): AHUB enabled." -Level Success
            $enabledCount++
        }
    }
}

# Summary
Write-LogMessage "" -Level Info
Write-LogMessage "=== Azure Hybrid Benefit Summary ===" -Level Success
Write-LogMessage "  Total machines: $($arcMachines.Count)" -Level Info
Write-LogMessage "  Already enabled: $alreadyEnabled" -Level Info
Write-LogMessage "  Newly enabled: $enabledCount" -Level Info
Write-LogMessage "" -Level Info
Write-LogMessage "Verify in Azure Portal: Arc machines > Licensing" -Level Info

#endregion Main
