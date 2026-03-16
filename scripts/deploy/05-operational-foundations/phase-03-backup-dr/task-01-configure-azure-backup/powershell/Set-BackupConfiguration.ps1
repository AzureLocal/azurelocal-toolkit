<#
.SYNOPSIS
    Configures Azure Backup and Disaster Recovery for Azure Local.

.DESCRIPTION
    This script sets up backup and disaster recovery including:
    - Recovery Services Vault creation
    - Azure Backup Server (MABS) configuration
    - VM backup policies
    - Azure Site Recovery integration
    - Backup schedule configuration

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER ResourceGroup
    Azure resource group name.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER Location
    Azure region for backup resources.

.PARAMETER VaultName
    Recovery Services Vault name.

.PARAMETER BackupPolicyName
    Name for the backup policy.

.PARAMETER RetentionDays
    Daily backup retention in days. Default: 30

.EXAMPLE
    .\Set-BackupConfiguration.ps1 -ClusterName "azl-cluster-01" -ResourceGroup "rg-azl-01" -VaultName "rsv-azl-01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires Az.RecoveryServices module.
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
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$VaultName,

    [Parameter(Mandatory = $false)]
    [string]$BackupPolicyName = "DefaultVMBackupPolicy",

    [Parameter(Mandatory = $false)]
    [int]$RetentionDays = 30,

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
        
        if (-not $SubscriptionId) { $SubscriptionId = $config.azure_platform.subscriptions.lab.id }
        if (-not $ResourceGroup) { $ResourceGroup = $config.azure_platform.resource_group }
        if (-not $Location) { $Location = $config.azure_platform.location }
    }
}

# Default vault name
if (-not $VaultName) {
    $VaultName = "rsv-$ClusterName"
}

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

function New-RecoveryServicesVault {
    Write-Log -Message "Creating Recovery Services Vault..." -Level "INFO"
    
    try {
        # Check for existing vault
        $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroup -Name $VaultName -ErrorAction SilentlyContinue
        
        if ($vault) {
            Write-Log -Message "  Vault already exists: $VaultName" -Level "INFO"
            return $vault
        }
        
        # Determine location
        if (-not $Location) {
            $rg = Get-AzResourceGroup -Name $ResourceGroup
            $Location = $rg.Location
        }
        
        # Create vault
        $vault = New-AzRecoveryServicesVault -ResourceGroupName $ResourceGroup `
                                             -Name $VaultName `
                                             -Location $Location `
                                             -ErrorAction Stop
        
        Write-Log -Message "  Vault created: $VaultName in $Location" -Level "SUCCESS"
        
        # Set vault context
        Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction Stop
        
        # Configure storage replication
        Set-AzRecoveryServicesBackupProperty -Vault $vault `
                                              -BackupStorageRedundancy GeoRedundant `
                                              -ErrorAction Stop
        
        Write-Log -Message "  Storage replication: Geo-Redundant" -Level "SUCCESS"
        
        return $vault
    }
    catch {
        Write-Log -Message "Failed to create vault: $_" -Level "ERROR"
        return $null
    }
}

function New-BackupPolicy {
    param([object]$Vault)
    
    Write-Log -Message "Creating backup policy..." -Level "INFO"
    
    try {
        Set-AzRecoveryServicesVaultContext -Vault $Vault
        
        # Check for existing policy
        $existingPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $BackupPolicyName -ErrorAction SilentlyContinue
        
        if ($existingPolicy) {
            Write-Log -Message "  Policy already exists: $BackupPolicyName" -Level "INFO"
            return $existingPolicy
        }
        
        # Get default policy template
        $schedulePolicy = Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType "AzureVM"
        $retentionPolicy = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType "AzureVM"
        
        # Configure schedule - daily at 2 AM
        $schedulePolicy.ScheduleRunTimes.Clear()
        $schedulePolicy.ScheduleRunTimes.Add((Get-Date "02:00:00"))
        
        # Configure retention
        $retentionPolicy.IsDailyScheduleEnabled = $true
        $retentionPolicy.DailySchedule.DurationCountInDays = $RetentionDays
        
        # Configure weekly retention (keep for 12 weeks)
        $retentionPolicy.IsWeeklyScheduleEnabled = $true
        $retentionPolicy.WeeklySchedule.DurationCountInWeeks = 12
        $retentionPolicy.WeeklySchedule.DaysOfTheWeek = @("Sunday")
        
        # Configure monthly retention (keep for 12 months)
        $retentionPolicy.IsMonthlyScheduleEnabled = $true
        $retentionPolicy.MonthlySchedule.DurationCountInMonths = 12
        
        # Create policy
        $policy = New-AzRecoveryServicesBackupProtectionPolicy -Name $BackupPolicyName `
                                                                -WorkloadType "AzureVM" `
                                                                -RetentionPolicy $retentionPolicy `
                                                                -SchedulePolicy $schedulePolicy `
                                                                -ErrorAction Stop
        
        Write-Log -Message "  Policy created: $BackupPolicyName" -Level "SUCCESS"
        Write-Log -Message "    Daily retention: $RetentionDays days" -Level "INFO"
        Write-Log -Message "    Weekly retention: 12 weeks" -Level "INFO"
        Write-Log -Message "    Monthly retention: 12 months" -Level "INFO"
        
        return $policy
    }
    catch {
        Write-Log -Message "Failed to create backup policy: $_" -Level "ERROR"
        return $null
    }
}

function Enable-VMBackup {
    param(
        [object]$Vault,
        [object]$Policy
    )
    
    Write-Log -Message "Enabling backup for VMs..." -Level "INFO"
    
    try {
        Set-AzRecoveryServicesVaultContext -Vault $Vault
        
        # Get VMs from cluster
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $vms = Get-VM -ComputerName $node.Name -ErrorAction SilentlyContinue
            
            foreach ($vm in $vms) {
                # For Azure Arc VMs, we need to use different approach
                # This is a simplified example for Azure VMs
                Write-Log -Message "  VM: $($vm.Name) on $($node.Name)" -Level "INFO"
                
                # Note: Azure Local VMs use MABS or Azure Backup integration
                # This requires Azure Backup Server configuration
            }
        }
        
        Write-Log -Message "  NOTE: Azure Local VMs require MABS or Azure Backup integration" -Level "WARN"
        Write-Log -Message "  See: https://learn.microsoft.com/azure-local/manage/azure-backup" -Level "INFO"
    }
    catch {
        Write-Log -Message "Failed to enable VM backup: $_" -Level "ERROR"
    }
}

function Set-MABSConfiguration {
    Write-Log -Message "Configuring MABS integration..." -Level "INFO"
    
    try {
        # Check if MABS server is available in config
        $mabsServer = $null
        
        if ($Config -and $Config.backup -and $Config.backup.mabs_server) {
            $mabsServer = $Config.backup.mabs_server
        }
        
        if (-not $mabsServer) {
            Write-Log -Message "  MABS server not configured" -Level "INFO"
            Write-Log -Message "  For Azure Local backup, install Microsoft Azure Backup Server (MABS)" -Level "INFO"
            return
        }
        
        # Verify MABS server connectivity
        if (Test-Connection -ComputerName $mabsServer -Count 1 -Quiet) {
            Write-Log -Message "  MABS server reachable: $mabsServer" -Level "SUCCESS"
            
            # MABS configuration would be done via MABS PowerShell module
            # Example: Add protection groups, configure schedules
            Write-Log -Message "  Configure protection groups via MABS console" -Level "INFO"
        }
        else {
            Write-Log -Message "  MABS server not reachable: $mabsServer" -Level "ERROR"
        }
    }
    catch {
        Write-Log -Message "MABS configuration failed: $_" -Level "ERROR"
    }
}

function Set-SiteRecovery {
    param([object]$Vault)
    
    Write-Log -Message "Configuring Azure Site Recovery..." -Level "INFO"
    
    try {
        # Set vault context for ASR
        Set-AzRecoveryServicesAsrVaultSettings -Vault $Vault -ErrorAction Stop
        
        Write-Log -Message "  ASR vault configured" -Level "SUCCESS"
        Write-Log -Message "  NOTE: Azure Local ASR requires additional setup" -Level "INFO"
        Write-Log -Message "  See: https://learn.microsoft.com/azure-local/manage/azure-site-recovery" -Level "INFO"
        
        # Display next steps
        Write-Host ""
        Write-Host "  Azure Site Recovery Next Steps:" -ForegroundColor Cyan
        Write-Host "    1. Create replication policy" -ForegroundColor White
        Write-Host "    2. Configure recovery plans" -ForegroundColor White
        Write-Host "    3. Enable replication for VMs" -ForegroundColor White
        Write-Host "    4. Test failover procedures" -ForegroundColor White
    }
    catch {
        Write-Log -Message "ASR configuration failed: $_" -Level "WARN"
    }
}

function Export-BackupConfiguration {
    param(
        [object]$Vault,
        [object]$Policy
    )
    
    Write-Log -Message "Exporting backup configuration summary..." -Level "INFO"
    
    $config = @{
        Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        Cluster = $ClusterName
        RecoveryServicesVault = @{
            Name = $Vault.Name
            ResourceGroup = $Vault.ResourceGroupName
            Location = $Vault.Location
            ResourceId = $Vault.ID
        }
        BackupPolicy = @{
            Name = $Policy.Name
            DailyRetentionDays = $RetentionDays
        }
        Documentation = @{
            AzureBackupDocs = "https://learn.microsoft.com/azure-local/manage/azure-backup"
            ASRDocs = "https://learn.microsoft.com/azure-local/manage/azure-site-recovery"
        }
    }
    
    $configPath = Join-Path $env:TEMP "backup-config-$ClusterName.json"
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath
    
    Write-Log -Message "  Configuration saved: $configPath" -Level "SUCCESS"
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Backup and Disaster Recovery Configuration" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "Resource Group: $ResourceGroup" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    # Import required modules
    Import-Module Az.RecoveryServices -ErrorAction Stop
    
    # Connect to Azure
    if (-not (Connect-AzureEnvironment)) {
        throw "Azure connection failed"
    }
    Write-Host ""
    
    # Create Recovery Services Vault
    $vault = New-RecoveryServicesVault
    if (-not $vault) {
        throw "Failed to create Recovery Services Vault"
    }
    Write-Host ""
    
    # Create backup policy
    $policy = New-BackupPolicy -Vault $vault
    Write-Host ""
    
    # Configure VM backup
    Enable-VMBackup -Vault $vault -Policy $policy
    Write-Host ""
    
    # Configure MABS if available
    Set-MABSConfiguration
    Write-Host ""
    
    # Configure Site Recovery
    Set-SiteRecovery -Vault $vault
    Write-Host ""
    
    # Export configuration
    Export-BackupConfiguration -Vault $vault -Policy $policy
    Write-Host ""
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Backup configuration complete" -Level "SUCCESS"
    Write-Log -Message "Recovery Services Vault: $VaultName" -Level "INFO"
}
catch {
    Write-Log -Message "Backup configuration failed: $_" -Level "ERROR"
    exit 1
}
