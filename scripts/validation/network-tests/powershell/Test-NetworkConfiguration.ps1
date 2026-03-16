<#
.SYNOPSIS
    Tests Azure Local network configuration and connectivity.

.DESCRIPTION
    This script validates network configuration including:
    - Physical network adapter status
    - Virtual switch configuration
    - Network ATC intents
    - RDMA configuration
    - Cluster network connectivity
    - DNS resolution
    - External connectivity

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER TestExternalConnectivity
    Switch to test external/internet connectivity.

.PARAMETER CustomEndpoints
    Array of custom endpoints to test (hostname:port format).

.PARAMETER OutputPath
    Path to save test results.

.EXAMPLE
    .\Test-NetworkConfiguration.ps1 -ClusterName "azl-cluster-01"

.EXAMPLE
    .\Test-NetworkConfiguration.ps1 -ClusterName "azl-cluster-01" -TestExternalConnectivity -CustomEndpoints @("192.168.1.1:443")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [switch]$TestExternalConnectivity,

    [Parameter(Mandatory = $false)]
    [string[]]$CustomEndpoints,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# Import logging helper
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

# Azure/Arc endpoints to test
$AzureEndpoints = @(
    @{ Name = "Azure Resource Manager"; Host = "management.azure.com"; Port = 443 }
    @{ Name = "Azure Active Directory"; Host = "login.microsoftonline.com"; Port = 443 }
    @{ Name = "Azure Arc"; Host = "gbl.his.arc.azure.com"; Port = 443 }
    @{ Name = "Azure Arc Data"; Host = "gbl.dp.kubernetesconfiguration.azure.com"; Port = 443 }
    @{ Name = "Azure Monitor"; Host = "dc.services.visualstudio.com"; Port = 443 }
)

# Initialize results
$TestResults = @{
    Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    ClusterName = $ClusterName
    NetworkAdapters = @()
    VirtualSwitches = @()
    ClusterNetworks = @()
    RdmaStatus = @()
    ConnectivityTests = @()
}

function Test-PhysicalNetworkAdapters {
    Write-Log -Message "Checking physical network adapters..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $adapters = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike "*Hyper-V*" -and $_.Status -eq "Up" }
            } -ErrorAction Stop
            
            foreach ($adapter in $adapters) {
                $result = @{
                    Node = $node.Name
                    Name = $adapter.Name
                    InterfaceDescription = $adapter.InterfaceDescription
                    Status = $adapter.Status.ToString()
                    LinkSpeed = $adapter.LinkSpeed
                    MediaType = $adapter.MediaType
                }
                
                $TestResults.NetworkAdapters += $result
                Write-Log -Message "  [$($node.Name)] $($adapter.Name): $($adapter.LinkSpeed) - Up" -Level "SUCCESS"
            }
            
            # Check for down adapters
            $downAdapters = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike "*Hyper-V*" -and $_.Status -ne "Up" }
            } -ErrorAction SilentlyContinue
            
            foreach ($adapter in $downAdapters) {
                Write-Log -Message "  [$($node.Name)] $($adapter.Name): $($adapter.Status)" -Level "WARN"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check network adapters: $_" -Level "ERROR"
    }
}

function Test-VirtualSwitchConfiguration {
    Write-Log -Message "Checking virtual switch configuration..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $switches = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                Get-VMSwitch
            } -ErrorAction Stop
            
            foreach ($switch in $switches) {
                $teamMembers = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                    param($switchName)
                    $sw = Get-VMSwitch -Name $switchName
                    if ($sw.EmbeddedTeamingEnabled) {
                        (Get-VMSwitchTeam -VMSwitch $sw).NetAdapterInterfaceDescription
                    }
                } -ArgumentList $switch.Name -ErrorAction SilentlyContinue
                
                $result = @{
                    Node = $node.Name
                    Name = $switch.Name
                    SwitchType = $switch.SwitchType.ToString()
                    EmbeddedTeaming = $switch.EmbeddedTeamingEnabled
                    TeamMembers = $teamMembers
                }
                
                $TestResults.VirtualSwitches += $result
                
                if ($switch.EmbeddedTeamingEnabled) {
                    Write-Log -Message "  [$($node.Name)] $($switch.Name): SET Enabled (Members: $($teamMembers.Count))" -Level "SUCCESS"
                }
                else {
                    Write-Log -Message "  [$($node.Name)] $($switch.Name): External switch" -Level "INFO"
                }
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check virtual switches: $_" -Level "ERROR"
    }
}

function Test-NetworkAtcIntents {
    Write-Log -Message "Checking Network ATC intents..." -Level "INFO"
    
    try {
        $intents = Get-NetIntent -ClusterName $ClusterName -ErrorAction SilentlyContinue
        
        if ($intents) {
            foreach ($intent in $intents) {
                $status = Get-NetIntentStatus -ClusterName $ClusterName -Name $intent.IntentName -ErrorAction SilentlyContinue
                
                if ($status.ConfigurationStatus -eq "Success" -or $status.ConfigurationStatus -eq "Completed") {
                    Write-Log -Message "  Intent: $($intent.IntentName) - $($intent.NetAdapterName) - Configured" -Level "SUCCESS"
                }
                else {
                    Write-Log -Message "  Intent: $($intent.IntentName) - Status: $($status.ConfigurationStatus)" -Level "WARN"
                }
            }
        }
        else {
            Write-Log -Message "  No Network ATC intents found (may be using manual configuration)" -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "  Network ATC check failed (may not be available): $_" -Level "INFO"
    }
}

function Test-RdmaConfiguration {
    Write-Log -Message "Checking RDMA configuration..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $rdmaAdapters = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                Get-NetAdapterRdma | Where-Object { $_.Enabled -eq $true }
            } -ErrorAction SilentlyContinue
            
            if ($rdmaAdapters) {
                foreach ($adapter in $rdmaAdapters) {
                    $result = @{
                        Node = $node.Name
                        Name = $adapter.Name
                        Enabled = $adapter.Enabled
                        OperationalStatus = "Active"
                    }
                    
                    $TestResults.RdmaStatus += $result
                    Write-Log -Message "  [$($node.Name)] $($adapter.Name): RDMA Enabled" -Level "SUCCESS"
                }
            }
            else {
                Write-Log -Message "  [$($node.Name)] No RDMA-enabled adapters found" -Level "WARN"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check RDMA: $_" -Level "ERROR"
    }
}

function Test-ClusterNetworkConnectivity {
    Write-Log -Message "Checking cluster network connectivity..." -Level "INFO"
    
    try {
        $networks = Get-ClusterNetwork -Cluster $ClusterName
        
        foreach ($network in $networks) {
            $status = if ($network.State -eq "Up") { "SUCCESS" } else { "ERROR" }
            
            Write-Log -Message "  $($network.Name): $($network.State) (Role: $($network.Role))" -Level $status
            
            $TestResults.ClusterNetworks += @{
                Name = $network.Name
                State = $network.State.ToString()
                Role = $network.Role.ToString()
                Address = $network.Address
                Metric = $network.Metric
            }
        }
        
        # Test node-to-node connectivity
        Write-Log -Message "Testing node-to-node connectivity..." -Level "INFO"
        
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        $nodeNames = $nodes.Name
        
        foreach ($sourceNode in $nodeNames) {
            foreach ($targetNode in $nodeNames) {
                if ($sourceNode -ne $targetNode) {
                    $pingResult = Invoke-Command -ComputerName $sourceNode -ScriptBlock {
                        param($target)
                        Test-Connection -ComputerName $target -Count 1 -Quiet
                    } -ArgumentList $targetNode -ErrorAction SilentlyContinue
                    
                    if ($pingResult) {
                        Write-Log -Message "  $sourceNode -> $targetNode : OK" -Level "SUCCESS"
                    }
                    else {
                        Write-Log -Message "  $sourceNode -> $targetNode : FAILED" -Level "ERROR"
                    }
                }
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check cluster networks: $_" -Level "ERROR"
    }
}

function Test-DnsResolution {
    Write-Log -Message "Checking DNS resolution..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1
        
        $testNames = @(
            "management.azure.com"
            "login.microsoftonline.com"
            $ClusterName
        )
        
        foreach ($name in $testNames) {
            $result = Invoke-Command -ComputerName $nodes.Name -ScriptBlock {
                param($hostname)
                try {
                    $resolved = Resolve-DnsName -Name $hostname -ErrorAction Stop
                    return @{ Success = $true; IP = $resolved.IPAddress[0] }
                }
                catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList $name -ErrorAction SilentlyContinue
            
            if ($result.Success) {
                Write-Log -Message "  $name -> $($result.IP)" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $name -> Failed: $($result.Error)" -Level "ERROR"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check DNS: $_" -Level "ERROR"
    }
}

function Test-ExternalEndpoints {
    if (-not $TestExternalConnectivity) {
        Write-Log -Message "Skipping external connectivity tests (use -TestExternalConnectivity to enable)" -Level "INFO"
        return
    }
    
    Write-Log -Message "Testing external endpoint connectivity..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1
        
        foreach ($endpoint in $AzureEndpoints) {
            $result = Invoke-Command -ComputerName $nodes.Name -ScriptBlock {
                param($host, $port)
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcp.BeginConnect($host, $port, $null, $null)
                    $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
                    if ($wait) {
                        $tcp.EndConnect($connect)
                        $tcp.Close()
                        return $true
                    }
                    $tcp.Close()
                    return $false
                }
                catch {
                    return $false
                }
            } -ArgumentList $endpoint.Host, $endpoint.Port -ErrorAction SilentlyContinue
            
            $TestResults.ConnectivityTests += @{
                Name = $endpoint.Name
                Host = $endpoint.Host
                Port = $endpoint.Port
                Success = $result
            }
            
            if ($result) {
                Write-Log -Message "  $($endpoint.Name): $($endpoint.Host):$($endpoint.Port) - OK" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $($endpoint.Name): $($endpoint.Host):$($endpoint.Port) - FAILED" -Level "ERROR"
            }
        }
        
        # Test custom endpoints
        if ($CustomEndpoints) {
            foreach ($ep in $CustomEndpoints) {
                $parts = $ep -split ":"
                $host = $parts[0]
                $port = if ($parts.Count -gt 1) { [int]$parts[1] } else { 443 }
                
                $result = Invoke-Command -ComputerName $nodes.Name -ScriptBlock {
                    param($h, $p)
                    Test-NetConnection -ComputerName $h -Port $p -WarningAction SilentlyContinue | 
                        Select-Object -ExpandProperty TcpTestSucceeded
                } -ArgumentList $host, $port -ErrorAction SilentlyContinue
                
                if ($result) {
                    Write-Log -Message "  Custom: ${host}:${port} - OK" -Level "SUCCESS"
                }
                else {
                    Write-Log -Message "  Custom: ${host}:${port} - FAILED" -Level "ERROR"
                }
            }
        }
    }
    catch {
        Write-Log -Message "Failed to test external endpoints: $_" -Level "ERROR"
    }
}

function Export-NetworkTestResults {
    if ($OutputPath) {
        $reportPath = Join-Path $OutputPath "network-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $TestResults | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath
        Write-Log -Message "Results saved to: $reportPath" -Level "INFO"
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Network Configuration and Connectivity Validation" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    Test-PhysicalNetworkAdapters
    Write-Host ""
    
    Test-VirtualSwitchConfiguration
    Write-Host ""
    
    Test-NetworkAtcIntents
    Write-Host ""
    
    Test-RdmaConfiguration
    Write-Host ""
    
    Test-ClusterNetworkConnectivity
    Write-Host ""
    
    Test-DnsResolution
    Write-Host ""
    
    Test-ExternalEndpoints
    Write-Host ""
    
    # Export results
    Export-NetworkTestResults
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Network validation complete" -Level "SUCCESS"
}
catch {
    Write-Log -Message "Network validation failed: $_" -Level "ERROR"
    exit 1
}
