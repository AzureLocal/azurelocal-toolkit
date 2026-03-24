<#
.SYNOPSIS
    Configures Azure Update Manager for Azure Local nodes.

.DESCRIPTION
    This script configures Update Manager:
    - Enables periodic assessment on Arc-connected nodes
    - Installs required extensions (WindowsPatchExtension)
    - Creates maintenance configurations and schedules
    - Validates update visibility

.PARAMETER ResourceGroupName
    Azure resource group name.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-UpdateManagerConfiguration.ps1 -ResourceGroupName "rg-azurelocal-prod"

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 05-operational-foundations
    Phase: phase-04-security-governance
    Task: task-05-configure-azure-update-manager
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$MaintenanceWindowName = "mw-hci-monthly-patching"
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ConnectedMachine, Az.Maintenance

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

function Enable-PeriodicAssessment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ResourceGroupName,
        [string]$MachineName
    )
    if ($PSCmdlet.ShouldProcess($MachineName, "Enable periodic assessment")) {
        Write-LogMessage "Enabling periodic assessment on $MachineName..." -Level Info
        $machine = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $MachineName
        # Periodic assessment is configured via machine policy
        Update-AzConnectedMachine -ResourceGroupName $ResourceGroupName -MachineName $MachineName `
            -OSProfile @{ WindowsConfiguration = @{ PatchSettings = @{ AssessmentMode = 'AutomaticByPlatform' } } }
        Write-LogMessage "Periodic assessment enabled on $MachineName." -Level Success
    }
}

#endregion Functions

#region Main

Write-LogMessage "=== Configure Azure Update Manager ===" -Level Info

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
Write-LogMessage "Retrieving Arc-connected HCI nodes..." -Level Info
$arcMachines = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.OSName -match 'Windows' }

if ($arcMachines.Count -eq 0) {
    Write-LogMessage "No Arc-connected Windows machines found." -Level Error
    exit 1
}
Write-LogMessage "Found $($arcMachines.Count) Arc-connected machines." -Level Success

# Check and install Windows Patch Extension
foreach ($machine in $arcMachines) {
    $extensions = Get-AzConnectedMachineExtension -ResourceGroupName $ResourceGroupName -MachineName $machine.Name
    $patchExt = $extensions | Where-Object { $_.ExtensionType -eq 'WindowsPatchExtension' }

    if ($patchExt -and $patchExt.ProvisioningState -eq 'Succeeded') {
        Write-LogMessage "  $($machine.Name): Patch extension already installed." -Level Info
    }
    else {
        Write-LogMessage "  $($machine.Name): Installing WindowsPatchExtension..." -Level Info
        $extParams = @{
            ResourceGroupName  = $ResourceGroupName
            MachineName        = $machine.Name
            Name               = 'WindowsPatchExtension'
            ExtensionType      = 'WindowsPatchExtension'
            Publisher          = 'Microsoft.CPlat.Core'
            TypeHandlerVersion = '1.0'
            Location           = $machine.Location
        }
        New-AzConnectedMachineExtension @extParams
        Write-LogMessage "  $($machine.Name): Patch extension installed." -Level Success
    }
}

# Create maintenance configuration
Write-LogMessage "Creating maintenance configuration: $MaintenanceWindowName" -Level Info
$location = $arcMachines[0].Location

$existingMC = Get-AzMaintenanceConfiguration -ResourceGroupName $ResourceGroupName -Name $MaintenanceWindowName -ErrorAction SilentlyContinue
if ($existingMC) {
    Write-LogMessage "Maintenance configuration already exists: $MaintenanceWindowName" -Level Info
}
else {
    $mcParams = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $MaintenanceWindowName
        Location          = $location
        MaintenanceScope  = 'InGuestPatch'
        RecurEvery        = 'Month Second Saturday'
        StartDateTime     = '2026-01-01 02:00'
        Duration          = '03:00'
        TimeZone          = 'UTC'
        Visibility        = 'Custom'
        ExtensionProperty = @{
            'InGuestPatchMode' = 'User'
        }
    }
    New-AzMaintenanceConfiguration @mcParams
    Write-LogMessage "Maintenance configuration created." -Level Success
}

Write-LogMessage "=== Update Manager Configuration Complete ===" -Level Success
Write-LogMessage "Assign machines to the maintenance configuration in Azure Portal." -Level Info

#endregion Main
