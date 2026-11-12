<#
.SYNOPSIS
    Configures Azure Backup for Azure Local cluster using Azure CLI.

.DESCRIPTION
    This script sets up comprehensive backup and disaster recovery including:
    - Recovery Services Vault creation and configuration
    - Backup policies with retention settings
    - Azure Site Recovery configuration guidance
    Uses Azure CLI (az) commands for all Azure operations.

.PARAMETER ClusterName
    The name of the Azure Local cluster to configure backup for.

.PARAMETER ResourceGroupName
    The Azure resource group for backup resources.

.PARAMETER VaultName
    The Recovery Services Vault name.

.PARAMETER Location
    Azure region for the vault.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ConfigFile
    Optional path to configuration file.

.EXAMPLE
    .\Set-BackupConfiguration.azcli.ps1 -ClusterName "AZL-CLUSTER01" -ResourceGroupName "rg-azl-backup" -VaultName "rsv-azl-prod"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Requires: Azure CLI (az)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VaultName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [int]$DailyRetentionDays = 30,

    [Parameter(Mandatory = $false)]
    [int]$WeeklyRetentionWeeks = 12,

    [Parameter(Mandatory = $false)]
    [int]$MonthlyRetentionMonths = 12,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile
)

$ErrorActionPreference = "Stop"

# Import helper functions
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\..\common\utilities\helpers"

if (Test-Path (Join-Path $HelpersPath "logging.ps1")) {
    . (Join-Path $HelpersPath "logging.ps1")
} else {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $color = switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }
}

if (Test-Path (Join-Path $HelpersPath "config-loader.ps1")) {
    . (Join-Path $HelpersPath "config-loader.ps1")
}

#region Helper Functions

function Test-AzCliInstalled {
    try {
        $null = az version 2>$null
        return $true
    } catch {
        return $false
    }
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [switch]$ReturnJson,
        [switch]$IgnoreError
    )

    Write-Log -Message "Executing: az $Command" -Level "INFO"
    
    if ($ReturnJson) {
        $result = Invoke-Expression "az $Command --output json 2>&1"
    } else {
        $result = Invoke-Expression "az $Command 2>&1"
    }

    if ($LASTEXITCODE -ne 0 -and -not $IgnoreError) {
        throw "Azure CLI command failed: $result"
    }

    if ($ReturnJson -and $result) {
        try {
            return $result | ConvertFrom-Json
        } catch {
            return $null
        }
    }

    return $result
}

#endregion

#region Main Functions

function New-RecoveryServicesVault {
    param(
        [string]$VaultName,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$SubscriptionId
    )

    Write-Log -Message "Creating Recovery Services Vault: $VaultName" -Level "INFO"

    # Check if vault exists
    $vault = $null
    try {
        $vault = Invoke-AzCli -Command "backup vault show --name $VaultName --resource-group $ResourceGroupName --subscription $SubscriptionId" -ReturnJson -IgnoreError
    } catch {
        # Vault doesn't exist
    }

    if ($vault) {
        Write-Log -Message "Recovery Services Vault already exists" -Level "INFO"
        return $vault
    }

    # Create vault
    $createCmd = "backup vault create " +
        "--name $VaultName " +
        "--resource-group $ResourceGroupName " +
        "--location $Location " +
        "--subscription $SubscriptionId"

    $vault = Invoke-AzCli -Command $createCmd -ReturnJson
    Write-Log -Message "Recovery Services Vault created successfully" -Level "SUCCESS"

    return $vault
}

function Set-VaultProperties {
    param(
        [string]$VaultName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId
    )

    Write-Log -Message "Configuring vault properties..." -Level "INFO"

    # Set storage redundancy to GeoRedundant
    $storageCmd = "backup vault backup-properties set " +
        "--name $VaultName " +
        "--resource-group $ResourceGroupName " +
        "--subscription $SubscriptionId " +
        "--backup-storage-redundancy GeoRedundant"

    try {
        Invoke-AzCli -Command $storageCmd
        Write-Log -Message "Vault storage redundancy set to GeoRedundant" -Level "SUCCESS"
    } catch {
        Write-Log -Message "Failed to set storage redundancy: $_" -Level "WARN"
    }

    # Enable soft delete
    $softDeleteCmd = "backup vault backup-properties set " +
        "--name $VaultName " +
        "--resource-group $ResourceGroupName " +
        "--subscription $SubscriptionId " +
        "--soft-delete-feature-state Enable"

    try {
        Invoke-AzCli -Command $softDeleteCmd
        Write-Log -Message "Soft delete enabled" -Level "SUCCESS"
    } catch {
        Write-Log -Message "Failed to enable soft delete: $_" -Level "WARN"
    }
}

function New-BackupPolicy {
    param(
        [string]$PolicyName,
        [string]$VaultName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId,
        [int]$DailyRetentionDays,
        [int]$WeeklyRetentionWeeks,
        [int]$MonthlyRetentionMonths
    )

    Write-Log -Message "Creating backup policy: $PolicyName" -Level "INFO"

    # Check if policy exists
    $policy = $null
    try {
        $policy = Invoke-AzCli -Command "backup policy show --name $PolicyName --vault-name $VaultName --resource-group $ResourceGroupName --subscription $SubscriptionId" -ReturnJson -IgnoreError
    } catch {
        # Policy doesn't exist
    }

    if ($policy) {
        Write-Log -Message "Backup policy already exists" -Level "INFO"
        return $policy
    }

    # Create policy configuration
    $policyConfig = @{
        eTag = $null
        properties = @{
            backupManagementType = "AzureIaasVM"
            instantRpRetentionRangeInDays = 2
            schedulePolicy = @{
                schedulePolicyType = "SimpleSchedulePolicy"
                scheduleRunFrequency = "Daily"
                scheduleRunTimes = @("2024-01-01T02:00:00Z")
            }
            retentionPolicy = @{
                retentionPolicyType = "LongTermRetentionPolicy"
                dailySchedule = @{
                    retentionTimes = @("2024-01-01T02:00:00Z")
                    retentionDuration = @{
                        count = $DailyRetentionDays
                        durationType = "Days"
                    }
                }
                weeklySchedule = @{
                    daysOfTheWeek = @("Sunday")
                    retentionTimes = @("2024-01-01T02:00:00Z")
                    retentionDuration = @{
                        count = $WeeklyRetentionWeeks
                        durationType = "Weeks"
                    }
                }
                monthlySchedule = @{
                    retentionScheduleFormatType = "Weekly"
                    retentionScheduleWeekly = @{
                        daysOfTheWeek = @("Sunday")
                        weeksOfTheMonth = @("First")
                    }
                    retentionTimes = @("2024-01-01T02:00:00Z")
                    retentionDuration = @{
                        count = $MonthlyRetentionMonths
                        durationType = "Months"
                    }
                }
            }
            timeZone = "UTC"
        }
    }

    # Save config to temp file
    $configPath = [System.IO.Path]::GetTempFileName()
    $policyConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

    try {
        # Note: az backup policy create requires specific parameters
        # Using set instead for flexibility
        $createCmd = "backup policy set " +
            "--policy $configPath " +
            "--vault-name $VaultName " +
            "--resource-group $ResourceGroupName " +
            "--subscription $SubscriptionId " +
            "--name $PolicyName"

        $policy = Invoke-AzCli -Command $createCmd -ReturnJson
        Write-Log -Message "Backup policy created successfully" -Level "SUCCESS"
    } catch {
        Write-Log -Message "Policy creation via CLI may require ARM template. Creating default policy." -Level "WARN"
        
        # Try creating with simpler command
        $simpleCmd = "backup policy create " +
            "--vault-name $VaultName " +
            "--resource-group $ResourceGroupName " +
            "--subscription $SubscriptionId " +
            "--name $PolicyName " +
            "--backup-management-type AzureIaasVM " +
            "--workload-type VM"
        
        try {
            $policy = Invoke-AzCli -Command $simpleCmd -ReturnJson
            Write-Log -Message "Default backup policy created" -Level "SUCCESS"
        } catch {
            Write-Log -Message "Failed to create policy: $_" -Level "ERROR"
        }
    } finally {
        Remove-Item -Path $configPath -Force -ErrorAction SilentlyContinue
    }

    return $policy
}

function Show-SiteRecoveryGuidance {
    param(
        [string]$VaultName,
        [string]$ResourceGroupName
    )

    Write-Log -Message "Azure Site Recovery Configuration Guidance" -Level "INFO"
    Write-Log -Message "==========================================" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "To enable Azure Site Recovery for Azure Local VMs:" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "1. Install Site Recovery Provider on each cluster node:" -Level "INFO"
    Write-Log -Message "   - Download from Azure Portal > Recovery Services Vault > Site Recovery" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "2. Register the Hyper-V site with Azure:" -Level "INFO"
    Write-Log -Message "   az backup protection enable-for-vm \\" -Level "INFO"
    Write-Log -Message "     --vault-name $VaultName \\" -Level "INFO"
    Write-Log -Message "     --resource-group $ResourceGroupName \\" -Level "INFO"
    Write-Log -Message "     --vm <vm-name> \\" -Level "INFO"
    Write-Log -Message "     --policy-name <policy-name>" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "3. Configure replication policies in Azure Portal" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "For detailed documentation, see:" -Level "INFO"
    Write-Log -Message "https://learn.microsoft.com/azure/site-recovery/hyper-v-azure-architecture" -Level "INFO"
}

function Show-MABSGuidance {
    Write-Log -Message "Microsoft Azure Backup Server (MABS) Guidance" -Level "INFO"
    Write-Log -Message "=============================================" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "For additional workload protection (SQL, SharePoint, etc.):" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "1. Deploy MABS server in your environment" -Level "INFO"
    Write-Log -Message "2. Register MABS with the Recovery Services Vault" -Level "INFO"
    Write-Log -Message "3. Install protection agents on workload servers" -Level "INFO"
    Write-Log -Message "4. Configure protection groups in MABS console" -Level "INFO"
    Write-Log -Message "" -Level "INFO"
    Write-Log -Message "For detailed documentation, see:" -Level "INFO"
    Write-Log -Message "https://learn.microsoft.com/azure/backup/backup-mabs-install-azure-stack" -Level "INFO"
}

#endregion

#region Main Execution

try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Backup Configuration (Azure CLI)" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"

    # Verify Azure CLI is installed
    if (-not (Test-AzCliInstalled)) {
        throw "Azure CLI is not installed. Please install Azure CLI and try again."
    }

    # Set subscription if provided
    if ($SubscriptionId) {
        Invoke-AzCli -Command "account set --subscription $SubscriptionId"
        Write-Log -Message "Using subscription: $SubscriptionId" -Level "INFO"
    } else {
        $currentAccount = Invoke-AzCli -Command "account show" -ReturnJson
        $SubscriptionId = $currentAccount.id
        Write-Log -Message "Using current subscription: $SubscriptionId" -Level "INFO"
    }

    # Set vault name if not provided
    if (-not $VaultName) {
        $VaultName = "rsv-$ClusterName"
    }

    # Get or set location
    if (-not $Location) {
        $rgInfo = Invoke-AzCli -Command "group show --name $ResourceGroupName" -ReturnJson
        $Location = $rgInfo.location
    }

    # Step 1: Create Recovery Services Vault
    Write-Log -Message "Step 1: Recovery Services Vault" -Level "INFO"
    $vault = New-RecoveryServicesVault -VaultName $VaultName -ResourceGroupName $ResourceGroupName -Location $Location -SubscriptionId $SubscriptionId

    # Step 2: Configure vault properties
    Write-Log -Message "Step 2: Vault Properties" -Level "INFO"
    Set-VaultProperties -VaultName $VaultName -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId

    # Step 3: Create backup policy
    Write-Log -Message "Step 3: Backup Policy" -Level "INFO"
    $policyName = "policy-$ClusterName-daily"
    $policy = New-BackupPolicy `
        -PolicyName $policyName `
        -VaultName $VaultName `
        -ResourceGroupName $ResourceGroupName `
        -SubscriptionId $SubscriptionId `
        -DailyRetentionDays $DailyRetentionDays `
        -WeeklyRetentionWeeks $WeeklyRetentionWeeks `
        -MonthlyRetentionMonths $MonthlyRetentionMonths

    # Step 4: Site Recovery guidance
    Write-Log -Message "Step 4: Site Recovery Guidance" -Level "INFO"
    Show-SiteRecoveryGuidance -VaultName $VaultName -ResourceGroupName $ResourceGroupName

    # Step 5: MABS guidance
    Write-Log -Message "Step 5: MABS Integration Guidance" -Level "INFO"
    Show-MABSGuidance

    Write-Log -Message "========================================" -Level "SUCCESS"
    Write-Log -Message "Backup configuration complete!" -Level "SUCCESS"
    Write-Log -Message "Vault: $VaultName" -Level "INFO"
    Write-Log -Message "Policy: $policyName" -Level "INFO"
    Write-Log -Message "Retention:" -Level "INFO"
    Write-Log -Message "  Daily: $DailyRetentionDays days" -Level "INFO"
    Write-Log -Message "  Weekly: $WeeklyRetentionWeeks weeks" -Level "INFO"
    Write-Log -Message "  Monthly: $MonthlyRetentionMonths months" -Level "INFO"
    Write-Log -Message "========================================" -Level "SUCCESS"

} catch {
    Write-Log -Message "Backup configuration failed: $_" -Level "ERROR"
    Write-Log -Message $_.ScriptStackTrace -Level "ERROR"
    exit 1
}

#endregion
