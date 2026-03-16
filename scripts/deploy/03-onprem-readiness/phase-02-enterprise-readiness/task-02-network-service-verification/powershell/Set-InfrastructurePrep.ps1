<#
.SYNOPSIS
    Prepares on-premises infrastructure for Azure Local deployment.

.DESCRIPTION
    This script validates and prepares infrastructure including:
    - Server hardware validation (BIOS/UEFI, Secure Boot)
    - Firmware version checks
    - Windows Server installation validation
    - Feature installation (Hyper-V, Failover Clustering)
    - PowerShell module installation
    - Time synchronization configuration

.PARAMETER NodeNames
    Array of cluster node names or IP addresses.

.PARAMETER Credential
    PSCredential for remote access to nodes.

.PARAMETER InstallFeatures
    Switch to install required Windows features.

.PARAMETER ConfigureNTP
    Switch to configure NTP time sync.

.PARAMETER NTPServer
    NTP server address. Default: time.windows.com

.EXAMPLE
    .\Set-InfrastructurePrep.ps1 -NodeNames @("node-01","node-02") -InstallFeatures

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires administrative access to cluster nodes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$InstallFeatures,

    [Parameter(Mandatory = $false)]
    [switch]$ConfigureNTP,

    [Parameter(Mandatory = $false)]
    [string]$NTPServer = "time.windows.com"
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

# Required Windows features
$RequiredFeatures = @(
    "Hyper-V"
    "Hyper-V-PowerShell"
    "Failover-Clustering"
    "RSAT-Clustering-PowerShell"
    "FS-Data-Deduplication"
    "BitLocker"
    "Data-Center-Bridging"
    "RSAT-AD-PowerShell"
    "NetworkATC"
)

# Required PowerShell modules
$RequiredModules = @(
    "Az.Accounts"
    "Az.Resources"
    "Az.ConnectedMachine"
    "Az.StackHCI"
)

$ValidationResults = @{
    Timestamp = Get-Date
    Nodes = @()
}

function Get-RemoteSession {
    param([string]$ComputerName)
    
    $sessionParams = @{
        ComputerName = $ComputerName
        ErrorAction = "Stop"
    }
    
    if ($Credential) {
        $sessionParams.Credential = $Credential
    }
    
    return $sessionParams
}

function Test-HardwareRequirements {
    param([string]$NodeName)
    
    Write-Log -Message "Checking hardware requirements for $NodeName..." -Level "INFO"
    
    try {
        $sessionParams = Get-RemoteSession -ComputerName $NodeName
        
        $hwInfo = Invoke-Command @sessionParams -ScriptBlock {
            $bios = Get-CimInstance -ClassName Win32_BIOS
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem
            $proc = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
            $mem = Get-CimInstance -ClassName Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
            $secureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
            
            @{
                Manufacturer = $cs.Manufacturer
                Model = $cs.Model
                BIOSVersion = $bios.SMBIOSBIOSVersion
                ProcessorName = $proc.Name
                ProcessorCores = $proc.NumberOfCores
                ProcessorLogical = $proc.NumberOfLogicalProcessors
                MemoryGB = [math]::Round($mem.Sum / 1GB, 0)
                SecureBootEnabled = $secureBoot
                TPMPresent = (Get-Tpm -ErrorAction SilentlyContinue).TpmPresent
            }
        }
        
        Write-Log -Message "  Manufacturer: $($hwInfo.Manufacturer) $($hwInfo.Model)" -Level "INFO"
        Write-Log -Message "  BIOS Version: $($hwInfo.BIOSVersion)" -Level "INFO"
        Write-Log -Message "  Processor: $($hwInfo.ProcessorName)" -Level "INFO"
        Write-Log -Message "  Cores/Threads: $($hwInfo.ProcessorCores)/$($hwInfo.ProcessorLogical)" -Level "INFO"
        Write-Log -Message "  Memory: $($hwInfo.MemoryGB) GB" -Level "INFO"
        
        # Validate minimums
        if ($hwInfo.MemoryGB -lt 32) {
            Write-Log -Message "  WARNING: Memory below recommended 32 GB" -Level "WARN"
        }
        else {
            Write-Log -Message "  Memory: OK" -Level "SUCCESS"
        }
        
        if ($hwInfo.SecureBootEnabled) {
            Write-Log -Message "  Secure Boot: Enabled" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  Secure Boot: NOT enabled" -Level "WARN"
        }
        
        if ($hwInfo.TPMPresent) {
            Write-Log -Message "  TPM: Present" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  TPM: NOT present or not enabled" -Level "WARN"
        }
        
        return $hwInfo
    }
    catch {
        Write-Log -Message "Failed to check hardware: $_" -Level "ERROR"
        return $null
    }
}

function Test-WindowsVersion {
    param([string]$NodeName)
    
    Write-Log -Message "Checking Windows version for $NodeName..." -Level "INFO"
    
    try {
        $sessionParams = Get-RemoteSession -ComputerName $NodeName
        
        $osInfo = Invoke-Command @sessionParams -ScriptBlock {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            @{
                Caption = $os.Caption
                Version = $os.Version
                BuildNumber = $os.BuildNumber
                InstallDate = $os.InstallDate
            }
        }
        
        Write-Log -Message "  OS: $($osInfo.Caption)" -Level "INFO"
        Write-Log -Message "  Version: $($osInfo.Version) (Build $($osInfo.BuildNumber))" -Level "INFO"
        
        # Check for supported versions (Azure Stack HCI or Windows Server 2022+)
        if ($osInfo.Caption -match "Azure Stack HCI" -or 
            ($osInfo.Caption -match "Windows Server" -and [int]$osInfo.BuildNumber -ge 20348)) {
            Write-Log -Message "  OS Version: Supported" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  OS Version: May not be supported" -Level "WARN"
        }
        
        return $osInfo
    }
    catch {
        Write-Log -Message "Failed to check Windows version: $_" -Level "ERROR"
        return $null
    }
}

function Test-WindowsFeatures {
    param([string]$NodeName)
    
    Write-Log -Message "Checking required Windows features for $NodeName..." -Level "INFO"
    
    try {
        $sessionParams = Get-RemoteSession -ComputerName $NodeName
        
        $featureStatus = Invoke-Command @sessionParams -ScriptBlock {
            param($features)
            
            $results = @()
            foreach ($feature in $features) {
                $f = Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue
                if ($f) {
                    $results += @{
                        Name = $feature
                        Installed = $f.Installed
                        InstallState = $f.InstallState.ToString()
                    }
                }
                else {
                    $results += @{
                        Name = $feature
                        Installed = $false
                        InstallState = "NotAvailable"
                    }
                }
            }
            return $results
        } -ArgumentList (, $RequiredFeatures)
        
        $missing = @()
        foreach ($feature in $featureStatus) {
            if ($feature.Installed) {
                Write-Log -Message "  $($feature.Name): Installed" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $($feature.Name): NOT installed" -Level "WARN"
                $missing += $feature.Name
            }
        }
        
        return $missing
    }
    catch {
        Write-Log -Message "Failed to check features: $_" -Level "ERROR"
        return $RequiredFeatures
    }
}

function Install-RequiredFeatures {
    param(
        [string]$NodeName,
        [string[]]$Features
    )
    
    if (-not $InstallFeatures) {
        Write-Log -Message "  Use -InstallFeatures to install missing features" -Level "INFO"
        return
    }
    
    if ($Features.Count -eq 0) {
        Write-Log -Message "  All features already installed" -Level "SUCCESS"
        return
    }
    
    Write-Log -Message "Installing features on $NodeName..." -Level "INFO"
    
    try {
        $sessionParams = Get-RemoteSession -ComputerName $NodeName
        
        $result = Invoke-Command @sessionParams -ScriptBlock {
            param($features)
            
            $installResult = Install-WindowsFeature -Name $features -IncludeAllSubFeature -IncludeManagementTools
            return @{
                Success = $installResult.Success
                RestartNeeded = $installResult.RestartNeeded
                FeatureResult = $installResult.FeatureResult | ForEach-Object { $_.Name }
            }
        } -ArgumentList (, $Features)
        
        if ($result.Success) {
            Write-Log -Message "  Features installed successfully" -Level "SUCCESS"
            
            if ($result.RestartNeeded -eq "Yes") {
                Write-Log -Message "  REBOOT REQUIRED" -Level "WARN"
            }
        }
        else {
            Write-Log -Message "  Feature installation failed" -Level "ERROR"
        }
    }
    catch {
        Write-Log -Message "Failed to install features: $_" -Level "ERROR"
    }
}

function Test-PowerShellModules {
    param([string]$NodeName)
    
    Write-Log -Message "Checking PowerShell modules for $NodeName..." -Level "INFO"
    
    try {
        $sessionParams = Get-RemoteSession -ComputerName $NodeName
        
        $moduleStatus = Invoke-Command @sessionParams -ScriptBlock {
            param($modules)
            
            $results = @()
            foreach ($module in $modules) {
                $m = Get-Module -ListAvailable -Name $module -ErrorAction SilentlyContinue | Select-Object -First 1
                $results += @{
                    Name = $module
                    Installed = ($null -ne $m)
                    Version = if ($m) { $m.Version.ToString() } else { $null }
                }
            }
            return $results
        } -ArgumentList (, $RequiredModules)
        
        $missing = @()
        foreach ($module in $moduleStatus) {
            if ($module.Installed) {
                Write-Log -Message "  $($module.Name): v$($module.Version)" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $($module.Name): NOT installed" -Level "WARN"
                $missing += $module.Name
            }
        }
        
        return $missing
    }
    catch {
        Write-Log -Message "Failed to check modules: $_" -Level "ERROR"
        return $RequiredModules
    }
}

function Set-NTPConfiguration {
    param([string]$NodeName)
    
    if (-not $ConfigureNTP) {
        return
    }
    
    Write-Log -Message "Configuring NTP for $NodeName..." -Level "INFO"
    
    try {
        $sessionParams = Get-RemoteSession -ComputerName $NodeName
        
        Invoke-Command @sessionParams -ScriptBlock {
            param($ntpServer)
            
            # Configure Windows Time service
            w32tm /config /manualpeerlist:$ntpServer /syncfromflags:manual /reliable:yes /update
            Restart-Service w32time
            w32tm /resync /force
        } -ArgumentList $NTPServer
        
        Write-Log -Message "  NTP configured: $NTPServer" -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to configure NTP: $_" -Level "ERROR"
    }
}

function Test-DiskConfiguration {
    param([string]$NodeName)
    
    Write-Log -Message "Checking disk configuration for $NodeName..." -Level "INFO"
    
    try {
        $sessionParams = Get-RemoteSession -ComputerName $NodeName
        
        $diskInfo = Invoke-Command @sessionParams -ScriptBlock {
            $disks = Get-PhysicalDisk | Where-Object { $_.BusType -ne "USB" }
            
            @{
                TotalDisks = $disks.Count
                SSD = ($disks | Where-Object { $_.MediaType -eq "SSD" }).Count
                HDD = ($disks | Where-Object { $_.MediaType -eq "HDD" }).Count
                NVMe = ($disks | Where-Object { $_.BusType -eq "NVMe" }).Count
                UnpartitionedDisks = ($disks | Where-Object { $_.CanPool -eq $true }).Count
            }
        }
        
        Write-Log -Message "  Total disks: $($diskInfo.TotalDisks)" -Level "INFO"
        Write-Log -Message "  SSD: $($diskInfo.SSD), HDD: $($diskInfo.HDD), NVMe: $($diskInfo.NVMe)" -Level "INFO"
        Write-Log -Message "  Available for pooling: $($diskInfo.UnpartitionedDisks)" -Level "INFO"
        
        if ($diskInfo.UnpartitionedDisks -gt 0) {
            Write-Log -Message "  Disk configuration: OK" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  No disks available for Storage Spaces Direct" -Level "WARN"
        }
        
        return $diskInfo
    }
    catch {
        Write-Log -Message "Failed to check disks: $_" -Level "ERROR"
        return $null
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Infrastructure Preparation" -Level "INFO"
    Write-Log -Message "Nodes: $($NodeNames -join ', ')" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    foreach ($node in $NodeNames) {
        Write-Log -Message "============ $node ============" -Level "INFO"
        Write-Host ""
        
        # Test connectivity first
        if (-not (Test-Connection -ComputerName $node -Count 1 -Quiet)) {
            Write-Log -Message "$node is not reachable, skipping..." -Level "ERROR"
            continue
        }
        
        # Hardware check
        $hw = Test-HardwareRequirements -NodeName $node
        Write-Host ""
        
        # Windows version
        $os = Test-WindowsVersion -NodeName $node
        Write-Host ""
        
        # Disk configuration
        $disks = Test-DiskConfiguration -NodeName $node
        Write-Host ""
        
        # Features
        $missingFeatures = Test-WindowsFeatures -NodeName $node
        
        if ($missingFeatures.Count -gt 0) {
            Install-RequiredFeatures -NodeName $node -Features $missingFeatures
        }
        Write-Host ""
        
        # PowerShell modules
        $missingModules = Test-PowerShellModules -NodeName $node
        Write-Host ""
        
        # NTP configuration
        Set-NTPConfiguration -NodeName $node
        
        # Store results
        $ValidationResults.Nodes += @{
            Name = $node
            Hardware = $hw
            OS = $os
            Disks = $disks
            MissingFeatures = $missingFeatures
            MissingModules = $missingModules
        }
        
        Write-Host ""
    }
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Infrastructure preparation complete" -Level "SUCCESS"
    
    # Summary
    $nodesWithIssues = $ValidationResults.Nodes | Where-Object { 
        $_.MissingFeatures.Count -gt 0 -or $_.MissingModules.Count -gt 0 
    }
    
    if ($nodesWithIssues.Count -gt 0) {
        Write-Log -Message "Nodes requiring attention: $($nodesWithIssues.Name -join ', ')" -Level "WARN"
    }
    else {
        Write-Log -Message "All nodes ready for deployment" -Level "SUCCESS"
    }
}
catch {
    Write-Log -Message "Infrastructure preparation failed: $_" -Level "ERROR"
    exit 1
}
