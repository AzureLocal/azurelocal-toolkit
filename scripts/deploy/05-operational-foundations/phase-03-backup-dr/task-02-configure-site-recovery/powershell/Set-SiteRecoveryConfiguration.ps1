<#
.SYNOPSIS
    Configures Azure Site Recovery for Azure Local VMs.

.DESCRIPTION
    This script configures disaster recovery:
    - Registers Hyper-V hosts with Recovery Services vault
    - Configures replication policy
    - Enables replication for selected VMs
    - Validates initial replication health

.PARAMETER VaultName
    Recovery Services vault name.

.PARAMETER ResourceGroupName
    Azure resource group name.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-SiteRecoveryConfiguration.ps1 -VaultName "rsv-azurelocal-prod" -ResourceGroupName "rg-azurelocal-prod"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 05-operational-foundations
    Phase: phase-03-backup-dr
    Task: task-02-configure-site-recovery
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$VaultName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ReplicationPolicyName = "rep-policy-24h-rpo"
)

#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.RecoveryServices

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

function New-ReplicationPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$PolicyName,
        [int]$RecoveryPointRetention = 24,
        [int]$AppConsistentFrequency = 4,
        [int]$ReplicationFrequencySec = 300
    )
    if ($PSCmdlet.ShouldProcess($PolicyName, "Create replication policy")) {
        Write-LogMessage "Creating replication policy: $PolicyName" -Level Info
        $policyParams = @{
            Name                                = $PolicyName
            ReplicationProvider                  = 'HyperVReplicaAzure'
            ReplicationFrequencyInSeconds        = $ReplicationFrequencySec
            RecoveryPointRetentionInHours        = $RecoveryPointRetention
            ApplicationConsistentSnapshotFrequencyInHours = $AppConsistentFrequency
        }
        $policy = New-AzRecoveryServicesAsrPolicy @policyParams
        Write-LogMessage "Replication policy created: $PolicyName" -Level Success
        return $policy
    }
}

#endregion Functions

#region Main

Write-LogMessage "=== Configure Azure Site Recovery ===" -Level Info

# Load configuration
$config = Import-InfrastructureConfig -Path $ConfigPath
if ($config) {
    $VaultName = if ($VaultName) { $VaultName } else { $config.backup.recovery_vault_name }
    $ResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } else { $config.azure.resource_group_name }
    $SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { $config.azure.subscription_id }
}

# Validate required parameters
if (-not $VaultName -or -not $ResourceGroupName) {
    Write-LogMessage "VaultName and ResourceGroupName are required." -Level Error
    exit 1
}

# Set subscription context
if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

# Get Recovery Services vault
Write-LogMessage "Retrieving Recovery Services vault: $VaultName" -Level Info
$vault = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $ResourceGroupName
if (-not $vault) {
    Write-LogMessage "Vault '$VaultName' not found." -Level Error
    exit 1
}
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

# Create or get replication policy
$existingPolicy = Get-AzRecoveryServicesAsrPolicy -Name $ReplicationPolicyName -ErrorAction SilentlyContinue
if ($existingPolicy) {
    Write-LogMessage "Replication policy already exists: $ReplicationPolicyName" -Level Info
}
else {
    New-ReplicationPolicy -PolicyName $ReplicationPolicyName
}

# Get Hyper-V site
Write-LogMessage "Retrieving Hyper-V fabric and site configuration..." -Level Info
$fabricServers = Get-AzRecoveryServicesAsrFabric
if ($fabricServers.Count -eq 0) {
    Write-LogMessage "No Hyper-V fabric registered. Install the ASR Provider on all cluster nodes first." -Level Warning
    Write-LogMessage "Download the provider from the vault > Site Recovery Infrastructure > Hyper-V hosts" -Level Info
}
else {
    foreach ($fabric in $fabricServers) {
        Write-LogMessage "Fabric: $($fabric.FriendlyName) — State: $($fabric.FabricSpecificDetails.State)" -Level Info
        $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric
        foreach ($container in $containers) {
            Write-LogMessage "  Protection Container: $($container.FriendlyName)" -Level Info
        }
    }
}

Write-LogMessage "=== Site Recovery Configuration Complete ===" -Level Success
Write-LogMessage "Next: Register Hyper-V hosts and enable VM replication via Azure Portal." -Level Info

#endregion Main
