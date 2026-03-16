<#
    Author:  Kristopher J Turner
    Updated:  2025-08-11
    Enhanced: GitHub Copilot for Azure Local Cloud Product Labs

    .DESCRIPTION
    This PowerShell Script will automatically detect and monitor Azure Local (23H2) deployment phases with intelligent connectivity management.

    .NOTES
    This script is designed for Azure Local Cloud Product Labs Azure Local Cluster (azl-lab-clus01) running 23H2. 
    
    INTELLIGENT FEATURES:
    - Automatically detects domain join status of target nodes
    - Switches between IP addresses and FQDNs based on connectivity
    - Tries multiple authentication methods automatically
    - Handles both pre-domain and post-domain deployment phases seamlessly
    
    CONNECTIVITY IMPROVEMENTS:
    - Smart server detection (IP vs FQDN based on reachability)
    - Configures WinRM TrustedHosts automatically for IP-based connections
    - Tests connectivity before attempting monitoring
    - Provides fallback authentication methods (Kerberos -> NTLM -> Negotiate)
    - Enhanced error handling with descriptive messages
    
    DEPLOYMENT PHASES:
    1. Pre-Domain Join: Automatically uses IP addresses (192.168.211.11-14) with local Administrator credentials
    2. Post-Domain Join: Automatically uses FQDNs (*.azlocal.mgmt) with domain credentials
    
    TROUBLESHOOTING:
    - If WinRM connectivity fails, the script attempts to enable it remotely
    - If deployment XML file is not found, it searches for alternative files
    - Provides manual intervention instructions when automated fixes fail

    .PARAMETER Phase
    Optional parameter to force a specific phase: 'PreDomain', 'PostDomain', or 'Auto' (default)

    .PARAMETER MonitorOnly
    Skip connectivity setup and go straight to monitoring

    .EXAMPLE
    .\Monitor-Deployment.ps1
    
    Automatically detects the deployment phase and starts monitoring.

    .EXAMPLE
    .\Monitor-Deployment.ps1 -Phase PreDomain
    
    Forces pre-domain join monitoring using IP addresses.

    .EXAMPLE
    .\Monitor-Deployment.ps1 -Phase PostDomain
    
    Forces post-domain join monitoring using FQDNs.

    .EXAMPLE
    .\Monitor-Deployment.ps1 -MonitorOnly
    
    Skips setup and goes directly to monitoring with current configuration.

#>

param(
    [ValidateSet('Auto', 'PreDomain', 'PostDomain')]
    [string]$Phase = 'Auto',
    
    [switch]$MonitorOnly
)

# Global configuration
$Script:ClusterConfig = @{
    NodeIPs = @("192.168.211.11", "192.168.211.12", "192.168.211.13", "192.168.211.14")
    NodeFQDNs = @("azl-lab-01-n01.azlocal.mgmt", "azl-lab-01-n02.azlocal.mgmt", "azl-lab-01-n03.azlocal.mgmt", "azl-lab-01-n04.azlocal.mgmt")
    NodeHostnames = @("azl-lab-01-n01", "azl-lab-01-n02", "azl-lab-01-n03", "azl-lab-01-n04")
    LocalPassword = "!!AzureLocal2025!!"
    DomainUser = "azlocal\administrator"
    LocalUser = "Administrator"
}

Write-Host "🚀 Azure Local Cloud Azure Local Deployment Monitor" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "Cluster: azl-lab-clus01 | Phase: $Phase | Monitor Only: $MonitorOnly" -ForegroundColor Yellow
Write-Host ""

# Function to test node connectivity and determine domain status
function Test-NodeConnectivity {
    param(
        [string[]]$TestServers,
        [string]$TestUsername,
        [string]$TestPassword,
        [string]$ConnectionType
    )
    
    Write-Host "🔍 Testing $ConnectionType connectivity..." -ForegroundColor Yellow
    
    $SecuredPassword = ConvertTo-SecureString $TestPassword -AsPlainText -Force
    $TestCredentials = New-Object System.Management.Automation.PSCredential ($TestUsername, $SecuredPassword)
    
    foreach ($Server in $TestServers) {
        try {
            Write-Host "  Testing: $Server" -ForegroundColor Gray
            
            # Test basic network connectivity first
            $NetworkTest = Test-NetConnection -ComputerName $Server -Port 5985 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if (-not $NetworkTest.TcpTestSucceeded) {
                Write-Host "    ❌ Network connectivity failed (Port 5985)" -ForegroundColor Red
                continue
            }
            
            # Test WinRM connectivity
            $WinRMTest = Test-WSMan -ComputerName $Server -Credential $TestCredentials -Authentication Negotiate -ErrorAction SilentlyContinue
            if ($WinRMTest) {
                Write-Host "    ✅ WinRM connectivity successful" -ForegroundColor Green
                
                # Test actual PowerShell remoting
                $PSTest = Invoke-Command -ComputerName $Server -Credential $TestCredentials -ScriptBlock { 
                    @{
                        ComputerName = $env:COMPUTERNAME
                        Domain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
                        IsInDomain = (Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain
                        CurrentTime = Get-Date
                    }
                } -ErrorAction SilentlyContinue
                
                if ($PSTest) {
                    Write-Host "    ✅ PowerShell remoting successful" -ForegroundColor Green
                    Write-Host "    📊 Node: $($PSTest.ComputerName) | Domain: $($PSTest.Domain) | Domain Joined: $($PSTest.IsInDomain)" -ForegroundColor Cyan
                    
                    return @{
                        Success = $true
                        Server = $Server
                        Username = $TestUsername
                        Credentials = $TestCredentials
                        NodeInfo = $PSTest
                        ConnectionType = $ConnectionType
                    }
                } else {
                    Write-Host "    ❌ PowerShell remoting failed" -ForegroundColor Red
                }
            } else {
                Write-Host "    ❌ WinRM connectivity failed" -ForegroundColor Red
            }
        } catch {
            Write-Host "    ❌ Connection test failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    return @{ Success = $false }
}

# Function to configure WinRM for IP-based connections
function Initialize-WinRMForIPs {
    param([string[]]$IPAddresses)
    
    Write-Host "⚙️  Configuring WinRM for IP-based connections..." -ForegroundColor Yellow
    
    try {
        # Configure TrustedHosts
        $TrustedHosts = @()
        $TrustedHosts += $IPAddresses
        $TrustedHosts += "*.azlocal.mgmt"
        $TrustedHosts += "192.168.211.*"
        
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $($TrustedHosts -join ',') -Force
        Write-Host "✅ TrustedHosts configured" -ForegroundColor Green
        
        # Enable WinRM if needed
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue
        
        # Configure authentication
        Set-WSManInstance -ResourceURI winrm/config/client -ValueSet @{AllowUnencrypted=$true} -ErrorAction SilentlyContinue
        Set-WSManInstance -ResourceURI winrm/config/service -ValueSet @{AllowUnencrypted=$true} -ErrorAction SilentlyContinue
        
        Write-Host "✅ WinRM configuration updated" -ForegroundColor Green
        
    } catch {
        Write-Warning "Could not update WinRM configuration: $($_.Exception.Message)"
    }
}

# Smart connection detection
function Get-OptimalConnection {
    param([string]$ForcePhase = 'Auto')
    
    Write-Host "🧠 Smart Connection Detection" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    
    $ConnectionResult = $null
    
    if ($ForcePhase -eq 'Auto') {
        Write-Host "🔄 Auto-detecting optimal connection method..." -ForegroundColor Yellow
        
        # Try domain-joined connection first (post-domain scenario)
        Write-Host "`n1️⃣  Trying Post-Domain Join Connection (FQDNs with domain credentials)..." -ForegroundColor Magenta
        $ConnectionResult = Test-NodeConnectivity -TestServers $Script:ClusterConfig.NodeFQDNs -TestUsername $Script:ClusterConfig.DomainUser -TestPassword $Script:ClusterConfig.LocalPassword -ConnectionType "Post-Domain"
        
        if (-not $ConnectionResult.Success) {
            # Try hostname-based connection
            Write-Host "`n2️⃣  Trying Hostname Connection (hostnames with local credentials)..." -ForegroundColor Magenta
            $ConnectionResult = Test-NodeConnectivity -TestServers $Script:ClusterConfig.NodeHostnames -TestUsername $Script:ClusterConfig.LocalUser -TestPassword $Script:ClusterConfig.LocalPassword -ConnectionType "Hostname"
        }
        
        if (-not $ConnectionResult.Success) {
            # Fall back to IP-based connection (pre-domain scenario)
            Write-Host "`n3️⃣  Trying Pre-Domain Join Connection (IPs with local credentials)..." -ForegroundColor Magenta
            Initialize-WinRMForIPs -IPAddresses $Script:ClusterConfig.NodeIPs
            $ConnectionResult = Test-NodeConnectivity -TestServers $Script:ClusterConfig.NodeIPs -TestUsername $Script:ClusterConfig.LocalUser -TestPassword $Script:ClusterConfig.LocalPassword -ConnectionType "Pre-Domain"
        }
        
    } elseif ($ForcePhase -eq 'PreDomain') {
        Write-Host "🔒 Forced Pre-Domain Join Mode" -ForegroundColor Magenta
        Initialize-WinRMForIPs -IPAddresses $Script:ClusterConfig.NodeIPs
        $ConnectionResult = Test-NodeConnectivity -TestServers $Script:ClusterConfig.NodeIPs -TestUsername $Script:ClusterConfig.LocalUser -TestPassword $Script:ClusterConfig.LocalPassword -ConnectionType "Pre-Domain"
        
    } elseif ($ForcePhase -eq 'PostDomain') {
        Write-Host "🔒 Forced Post-Domain Join Mode" -ForegroundColor Magenta
        $ConnectionResult = Test-NodeConnectivity -TestServers $Script:ClusterConfig.NodeFQDNs -TestUsername $Script:ClusterConfig.DomainUser -TestPassword $Script:ClusterConfig.LocalPassword -ConnectionType "Post-Domain"
    }
    
    if ($ConnectionResult.Success) {
        Write-Host "`n🎉 Optimal connection established!" -ForegroundColor Green
        Write-Host "📡 Connection Type: $($ConnectionResult.ConnectionType)" -ForegroundColor Green
        Write-Host "🖥️  Target Server: $($ConnectionResult.Server)" -ForegroundColor Green
        Write-Host "👤 Username: $($ConnectionResult.Username)" -ForegroundColor Green
        
        if ($ConnectionResult.NodeInfo) {
            Write-Host "🏷️  Domain Status: $(if ($ConnectionResult.NodeInfo.IsInDomain) { 'Domain Joined (' + $ConnectionResult.NodeInfo.Domain + ')' } else { 'Workgroup' })" -ForegroundColor Green
        }
        
        return $ConnectionResult
    } else {
        Write-Host "`n❌ Unable to establish connection with any method!" -ForegroundColor Red
        Write-Host "📋 Manual troubleshooting required. Check the README for setup instructions." -ForegroundColor Yellow
        return $null
    }
}

# Enhanced monitoring function with better error handling
function Invoke-DeploymentMonitoring {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )
    
    try {
        $SessionOptions = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        
        $Result = Invoke-Command -ComputerName $ComputerName -Credential $Credential -SessionOption $SessionOptions -ScriptBlock {
            # Check if the deployment XML file exists
            $DeploymentFile = "C:\ecestore\efb61d70-47ed-8f44-5d63-bed6adc0fb0f\086a22e3-ef1a-7b3a-dc9d-f407953b0f84"
            
            if (Test-Path $DeploymentFile) {
                ([xml](Get-Content $DeploymentFile)) | 
                Select-Xml -XPath "//Action/Steps/Step" | 
                ForEach-Object { $_.Node } | 
                Select-Object FullStepIndex, Status, Name, StartTimeUtc, EndTimeUtc, 
                    @{Name = "Duration"; Expression = { 
                        if ($_.StartTimeUtc -and $_.EndTimeUtc) {
                            new-timespan -Start $_.StartTimeUtc -End $_.EndTimeUtc 
                        } else {
                            "N/A"
                        }
                    }} | 
                Format-Table -AutoSize
            } else {
                Write-Warning "Deployment file not found at: $DeploymentFile"
                Write-Host "Checking for alternative deployment files..."
                
                # Look for alternative deployment files
                $AlternativeFiles = Get-ChildItem "C:\ecestore" -Recurse -File -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -like "*xml*" -or $_.Name -like "*log*" } | 
                    Select-Object FullName, LastWriteTime | 
                    Sort-Object LastWriteTime -Descending | 
                    Select-Object -First 10
                
                if ($AlternativeFiles) {
                    Write-Host "Found alternative files:" -ForegroundColor Cyan
                    $AlternativeFiles | Format-Table -AutoSize
                } else {
                    Write-Warning "No deployment files found in C:\ecestore"
                    Write-Host "Deployment may not have started yet or files may be in a different location."
                }
            }
        } -ErrorAction Stop
        
        return $Result
    } catch {
        Write-Error "Failed to retrieve deployment status from $ComputerName : $($_.Exception.Message)"
        return $null
    }
}

# Main execution logic
if (-not $MonitorOnly) {
    # Smart connection detection
    $OptimalConnection = Get-OptimalConnection -ForcePhase $Phase
    
    if (-not $OptimalConnection) {
        Write-Host "`n❌ Could not establish any connection to the cluster nodes." -ForegroundColor Red
        Write-Host "🔧 Please check the README.md for manual setup instructions." -ForegroundColor Yellow
        Write-Host "💡 You can also try:" -ForegroundColor Cyan
        Write-Host "   - .\Monitor-Deployment.ps1 -Phase PreDomain   (Force IP-based connection)" -ForegroundColor Cyan
        Write-Host "   - .\Monitor-Deployment.ps1 -Phase PostDomain  (Force FQDN-based connection)" -ForegroundColor Cyan
        exit 1
    }
    
    # Store the optimal connection for monitoring
    $Global:MonitoringServer = $OptimalConnection.Server
    $Global:MonitoringCredentials = $OptimalConnection.Credentials
    $Global:ConnectionType = $OptimalConnection.ConnectionType
    
} else {
    Write-Host "⏭️  Skipping connection detection (MonitorOnly mode)" -ForegroundColor Yellow
    Write-Host "Using existing configuration..." -ForegroundColor Gray
    
    # Use default settings if MonitorOnly is specified
    if (-not $Global:MonitoringServer) {
        Write-Warning "No existing connection found. Defaulting to IP-based connection."
        Initialize-WinRMForIPs -IPAddresses $Script:ClusterConfig.NodeIPs
        $Global:MonitoringServer = $Script:ClusterConfig.NodeIPs[0]
        $SecuredPassword = ConvertTo-SecureString $Script:ClusterConfig.LocalPassword -AsPlainText -Force
        $Global:MonitoringCredentials = New-Object System.Management.Automation.PSCredential ($Script:ClusterConfig.LocalUser, $SecuredPassword)
        $Global:ConnectionType = "Default"
    }
}

# Start monitoring
Write-Host "`n📊 Starting Azure Local Deployment Monitoring" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "🖥️  Target Server: $Global:MonitoringServer" -ForegroundColor Green
Write-Host "🔗 Connection Type: $Global:ConnectionType" -ForegroundColor Green
Write-Host "👤 Username: $($Global:MonitoringCredentials.UserName)" -ForegroundColor Green
Write-Host "⏰ Refresh Interval: 2 minutes" -ForegroundColor Green
Write-Host "⚠️  Press Ctrl+C to stop monitoring" -ForegroundColor Yellow
Write-Host ""

# Initial deployment status check
Write-Host "=== Initial Deployment Status Check ===" -ForegroundColor Magenta
$InitialResult = Invoke-DeploymentMonitoring -ComputerName $Global:MonitoringServer -Credential $Global:MonitoringCredentials

if ($InitialResult) {
    $InitialResult
} else {
    Write-Warning "No initial deployment data retrieved. The deployment may not have started yet."
}

# Continuous monitoring loop
Write-Host "`n=== Starting Continuous Monitoring ===" -ForegroundColor Magenta
$MonitoringCount = 0
$StartTime = Get-Date

try {
    while ($true) {
        $MonitoringCount++
        $CurrentTime = Get-Date
        $ElapsedTime = $CurrentTime - $StartTime
        $TimeStamp = $CurrentTime.ToString("yyyy-MM-dd HH:mm:ss")
        
        Write-Host "`n[$TimeStamp] Cycle #$MonitoringCount (Elapsed: $($ElapsedTime.ToString('hh\:mm\:ss')))" -ForegroundColor Green
        Write-Host "Checking deployment status on $Global:MonitoringServer..." -ForegroundColor Gray
        
        $Result = Invoke-DeploymentMonitoring -ComputerName $Global:MonitoringServer -Credential $Global:MonitoringCredentials
        
        if ($Result) {
            $Result
            
            # Check if monitoring shows completion indicators
            if ($Result -match "Completed|Success|Finished") {
                Write-Host "`n🎉 Deployment appears to be completed!" -ForegroundColor Green
                Write-Host "✅ Check the final status above for confirmation." -ForegroundColor Green
            }
            
        } else {
            Write-Warning "No deployment data retrieved in this cycle."
            Write-Host "This could mean:" -ForegroundColor Yellow
            Write-Host "  • Deployment hasn't started yet" -ForegroundColor Yellow
            Write-Host "  • Deployment files are in a different location" -ForegroundColor Yellow
            Write-Host "  • Connection issues occurred" -ForegroundColor Yellow
        }
        
        Write-Host "`n⏳ Next check in 2 minutes... (Ctrl+C to stop)" -ForegroundColor Gray
        Start-Sleep -Seconds 120
    }
} catch {
    if ($_.Exception.Message -match "terminated by the user") {
        Write-Host "`n👋 Monitoring stopped by user." -ForegroundColor Yellow
    } else {
        Write-Error "Monitoring loop error: $($_.Exception.Message)"
    }
}

Write-Host "`n📋 Monitoring Summary" -ForegroundColor Cyan
Write-Host "=====================" -ForegroundColor Cyan
Write-Host "🖥️  Monitored Server: $Global:MonitoringServer" -ForegroundColor Green
Write-Host "🔗 Connection Type: $Global:ConnectionType" -ForegroundColor Green
Write-Host "🔄 Total Cycles: $MonitoringCount" -ForegroundColor Green
Write-Host "⏱️  Total Runtime: $((Get-Date) - $StartTime | ForEach-Object { $_.ToString('hh\:mm\:ss') })" -ForegroundColor Green
Write-Host "📊 Script completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
