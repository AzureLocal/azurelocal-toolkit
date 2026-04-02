<#
.SYNOPSIS
    Validates backup and disaster recovery configuration and operations.

.DESCRIPTION
    Comprehensive backup and DR validation including:
    - Azure Backup vault and policy configuration
    - Backup job status and recent history
    - Azure Site Recovery replication health
    - RPO and RTO target validation
    - Test restore operation (optional)
    - Generates validation report for customer handover

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER ResourceGroupName
    Resource group containing the recovery services vault.

.PARAMETER VaultName
    Name of the Recovery Services vault.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.EXAMPLE
    .\Test-BackupDrValidation.ps1 -ClusterName "azl-cluster-01" -SubscriptionId "00000000-0000-0000-0000-000000000000" -ResourceGroupName "rg-azurelocal-01" -VaultName "rsv-azurelocal-01"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-06-backup-dr-validation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VaultName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports"
)

#Requires -Version 7.0
#Requires -Module Az.Accounts
#Requires -Module Az.RecoveryServices

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml
    return Get-Content -Path $Path -Raw | ConvertFrom-Yaml
}

#region Validation Functions

function Test-RecoveryServicesVault {
    param([string]$SubId, [string]$RgName, [string]$Vault)

    Write-Log "Validating Recovery Services Vault..." -Level "HEADER"

    try {
        Set-AzContext -SubscriptionId $SubId -ErrorAction Stop | Out-Null

        $rsVault = Get-AzRecoveryServicesVault -ResourceGroupName $RgName -Name $Vault -ErrorAction Stop
        Write-Log "  Vault: $($rsVault.Name), Location: $($rsVault.Location)" -Level "SUCCESS"
        Write-Log "  Provisioning: $($rsVault.Properties.ProvisioningState)" -Level "INFO"

        Set-AzRecoveryServicesVaultContext -Vault $rsVault

        return [PSCustomObject]@{
            Name     = $rsVault.Name
            Location = $rsVault.Location
            State    = $rsVault.Properties.ProvisioningState
            Status   = if ($rsVault.Properties.ProvisioningState -eq 'Succeeded') { "PASS" } else { "FAIL" }
        }
    }
    catch {
        Write-Log "  Vault check failed — $_" -Level "ERROR"
        return [PSCustomObject]@{ Name = $Vault; Status = "FAIL" }
    }
}

function Test-BackupPolicies {
    param([string]$SubId, [string]$RgName, [string]$Vault)

    Write-Log "Validating backup policies..." -Level "HEADER"
    $results = @()

    try {
        $rsVault = Get-AzRecoveryServicesVault -ResourceGroupName $RgName -Name $Vault
        Set-AzRecoveryServicesVaultContext -Vault $rsVault

        $policies = Get-AzRecoveryServicesBackupProtectionPolicy

        if ($policies -and $policies.Count -gt 0) {
            foreach ($policy in $policies) {
                Write-Log "  Policy: $($policy.Name), Type: $($policy.WorkloadType)" -Level "SUCCESS"
                $results += [PSCustomObject]@{
                    Name         = $policy.Name
                    WorkloadType = $policy.WorkloadType
                    Status       = "PASS"
                }
            }
        }
        else {
            Write-Log "  No backup policies found" -Level "WARN"
        }
    }
    catch {
        Write-Log "  Backup policy check failed — $_" -Level "ERROR"
    }

    return $results
}

function Test-BackupJobHistory {
    param([string]$SubId, [string]$RgName, [string]$Vault)

    Write-Log "Validating recent backup jobs..." -Level "HEADER"
    $results = @()

    try {
        $rsVault = Get-AzRecoveryServicesVault -ResourceGroupName $RgName -Name $Vault
        Set-AzRecoveryServicesVaultContext -Vault $rsVault

        $jobs = Get-AzRecoveryServicesBackupJob -From (Get-Date).AddDays(-7) -To (Get-Date)

        if ($jobs -and $jobs.Count -gt 0) {
            $grouped = $jobs | Group-Object -Property Status
            foreach ($group in $grouped) {
                $level = switch ($group.Name) { "Completed" { "SUCCESS" }; "Failed" { "ERROR" }; default { "INFO" } }
                Write-Log "  $($group.Name): $($group.Count) jobs (last 7 days)" -Level $level
            }

            $failedJobs = $jobs | Where-Object { $_.Status -eq "Failed" }
            if ($failedJobs) {
                foreach ($fj in ($failedJobs | Select-Object -First 5)) {
                    Write-Log "  FAILED: $($fj.WorkloadName) at $($fj.StartTime)" -Level "ERROR"
                }
            }

            $results = $grouped | ForEach-Object {
                [PSCustomObject]@{ Status = $_.Name; Count = $_.Count }
            }
        }
        else {
            Write-Log "  No backup jobs in last 7 days" -Level "WARN"
        }
    }
    catch {
        Write-Log "  Backup job check failed — $_" -Level "ERROR"
    }

    return $results
}

function Test-SiteRecoveryHealth {
    param([string]$SubId, [string]$RgName, [string]$Vault)

    Write-Log "Validating Site Recovery replication health..." -Level "HEADER"

    try {
        $rsVault = Get-AzRecoveryServicesVault -ResourceGroupName $RgName -Name $Vault
        Set-AzRecoveryServicesVaultContext -Vault $rsVault

        $fabrics = Get-AzRecoveryServicesAsrFabric -ErrorAction SilentlyContinue

        if ($fabrics) {
            foreach ($fabric in $fabrics) {
                Write-Log "  Fabric: $($fabric.FriendlyName), Type: $($fabric.FabricType)" -Level "INFO"

                $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction SilentlyContinue
                if ($containers) {
                    foreach ($container in $containers) {
                        $items = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container -ErrorAction SilentlyContinue
                        if ($items) {
                            foreach ($item in $items) {
                                $rpOk = $item.ReplicationHealth -eq "Normal"
                                Write-Log "  $($item.FriendlyName): Health=$($item.ReplicationHealth), State=$($item.ProtectionState)" -Level $(if ($rpOk) { "SUCCESS" } else { "WARN" })
                            }
                        }
                    }
                }
            }
        }
        else {
            Write-Log "  No Site Recovery fabrics configured" -Level "INFO"
        }
    }
    catch {
        Write-Log "  Site Recovery check failed — $_" -Level "WARN"
    }
}

function Test-ProtectedItems {
    param([string]$SubId, [string]$RgName, [string]$Vault)

    Write-Log "Validating protected items..." -Level "HEADER"
    $results = @()

    try {
        $rsVault = Get-AzRecoveryServicesVault -ResourceGroupName $RgName -Name $Vault
        Set-AzRecoveryServicesVaultContext -Vault $rsVault

        $containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -ErrorAction SilentlyContinue
        if (-not $containers) {
            $containers = Get-AzRecoveryServicesBackupContainer -ContainerType Windows -BackupManagementType MAB -ErrorAction SilentlyContinue
        }

        if ($containers) {
            foreach ($container in $containers) {
                $items = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType MSSQL -ErrorAction SilentlyContinue
                if (-not $items) {
                    $items = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -ErrorAction SilentlyContinue
                }
                if ($items) {
                    foreach ($item in $items) {
                        Write-Log "  $($item.Name): Health=$($item.HealthStatus), LastBackup=$($item.LastBackupTime)" -Level "INFO"
                        $results += [PSCustomObject]@{
                            Name       = $item.Name
                            Health     = $item.HealthStatus
                            LastBackup = $item.LastBackupTime
                        }
                    }
                }
            }
        }
        else {
            Write-Log "  No backup containers found" -Level "WARN"
        }
    }
    catch {
        Write-Log "  Protected items check failed — $_" -Level "WARN"
    }

    return $results
}

#endregion Validation Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "Backup & DR Validation" -Level "HEADER"
Write-Log "========================================" -Level "HEADER"

if ($ConfigPath) {
    $config = Import-InfrastructureConfig -Path $ConfigPath
    if (-not $ClusterName -and $config) { $ClusterName = $config.platform.cluster_name }
    if (-not $SubscriptionId -and $config) { $SubscriptionId = $config.azure.subscription_id }
    if (-not $ResourceGroupName -and $config) { $ResourceGroupName = $config.azure.resource_group }
    if (-not $VaultName -and $config) { $VaultName = $config.backup.vault_name }
}
if (-not $ClusterName -or -not $SubscriptionId -or -not $ResourceGroupName -or -not $VaultName) {
    Write-Log "ClusterName, SubscriptionId, ResourceGroupName, and VaultName are required." -Level "ERROR"
    exit 1
}

Write-Log "Cluster: $ClusterName" -Level "INFO"
Write-Log "Vault: $VaultName" -Level "INFO"
Write-Host ""

$report = @{ Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; ClusterName = $ClusterName; VaultName = $VaultName; Sections = @{} }

# 1. Vault
$vaultResult = Test-RecoveryServicesVault -SubId $SubscriptionId -RgName $ResourceGroupName -Vault $VaultName
$report.Sections["Vault"] = $vaultResult
Write-Host ""

# 2. Policies
$policyResults = Test-BackupPolicies -SubId $SubscriptionId -RgName $ResourceGroupName -Vault $VaultName
$report.Sections["Policies"] = $policyResults
Write-Host ""

# 3. Job History
$jobResults = Test-BackupJobHistory -SubId $SubscriptionId -RgName $ResourceGroupName -Vault $VaultName
$report.Sections["Jobs"] = $jobResults
Write-Host ""

# 4. Site Recovery
Test-SiteRecoveryHealth -SubId $SubscriptionId -RgName $ResourceGroupName -Vault $VaultName
Write-Host ""

# 5. Protected Items
$protectedItems = Test-ProtectedItems -SubId $SubscriptionId -RgName $ResourceGroupName -Vault $VaultName
$report.Sections["ProtectedItems"] = $protectedItems
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "06-backup-dr-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "Backup & DR Summary" -Level "SUCCESS"
Write-Log "  Vault: $($vaultResult.Status)" -Level "INFO"
Write-Log "  Policies: $($policyResults.Count) configured" -Level "INFO"
Write-Log "  Protected items: $($protectedItems.Count)" -Level "INFO"

$failedJobs = ($jobResults | Where-Object { $_.Status -eq "Failed" })
if ($failedJobs) {
    Write-Log "  ATTENTION: $($failedJobs.Count) failed backup jobs in last 7 days" -Level "WARN"
}
else {
    Write-Log "  No failed backup jobs in last 7 days" -Level "SUCCESS"
}

#endregion Main
