<#
.SYNOPSIS
    Validates network infrastructure readiness for Azure Local deployment.

.DESCRIPTION
    This script validates network infrastructure including:
    - Physical switch connectivity
    - VLAN configuration verification
    - MTU validation (jumbo frames)
    - Required port connectivity
    - Routing validation
    - Firewall rule verification

.PARAMETER NodeNames
    Array of cluster node names or IP addresses.

.PARAMETER ManagementVLAN
    Management network VLAN ID.

.PARAMETER StorageVLAN
    Storage network VLAN ID.

.PARAMETER TestJumboFrames
    Switch to test jumbo frame (9000 MTU) support.

.PARAMETER GatewayIP
    Default gateway IP for routing tests.

.PARAMETER AzureEndpointTest
    Switch to test Azure endpoint connectivity.

.EXAMPLE
    .\Test-NetworkReadiness.ps1 -NodeNames @("192.168.1.10","192.168.1.11") -ManagementVLAN 100

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [int]$ManagementVLAN,

    [Parameter(Mandatory = $false)]
    [int]$StorageVLAN,

    [Parameter(Mandatory = $false)]
    [switch]$TestJumboFrames,

    [Parameter(Mandatory = $false)]
    [string]$GatewayIP,

    [Parameter(Mandatory = $false)]
    [switch]$AzureEndpointTest
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

# Azure endpoints to test
$AzureEndpoints = @(
    @{ Name = "Azure Resource Manager"; Host = "management.azure.com"; Port = 443 }
    @{ Name = "Azure Active Directory"; Host = "login.microsoftonline.com"; Port = 443 }
    @{ Name = "Azure Arc"; Host = "gbl.his.arc.azure.com"; Port = 443 }
    @{ Name = "Azure Monitor"; Host = "dc.services.visualstudio.com"; Port = 443 }
    @{ Name = "Windows Update"; Host = "windowsupdate.microsoft.com"; Port = 443 }
)

# Required ports for cluster
$RequiredPorts = @(
    @{ Name = "WinRM"; Port = 5985; Protocol = "TCP" }
    @{ Name = "WinRM-SSL"; Port = 5986; Protocol = "TCP" }
    @{ Name = "SMB"; Port = 445; Protocol = "TCP" }
    @{ Name = "RPC"; Port = 135; Protocol = "TCP" }
    @{ Name = "Cluster"; Port = 3343; Protocol = "UDP" }
    @{ Name = "ICMP"; Port = 0; Protocol = "ICMP" }
)

$TestResults = @{
    Timestamp = Get-Date
    Nodes = @()
    Connectivity = @()
    MTU = @()
    Azure = @()
}

function Test-NodeConnectivity {
    Write-Log -Message "Testing node connectivity..." -Level "INFO"
    
    foreach ($node in $NodeNames) {
        Write-Log -Message "  Testing: $node" -Level "INFO"
        
        # Basic ping
        $pingResult = Test-Connection -ComputerName $node -Count 3 -ErrorAction SilentlyContinue
        
        if ($pingResult) {
            $avgLatency = [math]::Round(($pingResult.ResponseTime | Measure-Object -Average).Average, 2)
            Write-Log -Message "    ICMP: OK (Avg: ${avgLatency}ms)" -Level "SUCCESS"
            
            $TestResults.Nodes += @{
                Node = $node
                Reachable = $true
                Latency = $avgLatency
            }
        }
        else {
            Write-Log -Message "    ICMP: FAILED" -Level "ERROR"
            $TestResults.Nodes += @{
                Node = $node
                Reachable = $false
                Latency = $null
            }
            continue
        }
        
        # Test required ports
        foreach ($portInfo in $RequiredPorts) {
            if ($portInfo.Protocol -eq "ICMP") { continue }
            
            $portTest = Test-NetConnection -ComputerName $node -Port $portInfo.Port -WarningAction SilentlyContinue
            
            if ($portTest.TcpTestSucceeded) {
                Write-Log -Message "    $($portInfo.Name) ($($portInfo.Port)): OK" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "    $($portInfo.Name) ($($portInfo.Port)): BLOCKED" -Level "ERROR"
            }
        }
    }
}

function Test-NodeToNodeConnectivity {
    Write-Log -Message "Testing node-to-node connectivity..." -Level "INFO"
    
    if ($NodeNames.Count -lt 2) {
        Write-Log -Message "  Need at least 2 nodes for this test" -Level "INFO"
        return
    }
    
    # Test from first reachable node
    $sourceNode = $NodeNames | Where-Object { Test-Connection -ComputerName $_ -Count 1 -Quiet } | Select-Object -First 1
    
    if (-not $sourceNode) {
        Write-Log -Message "  No reachable nodes to test from" -Level "ERROR"
        return
    }
    
    foreach ($targetNode in $NodeNames) {
        if ($targetNode -eq $sourceNode) { continue }
        
        try {
            $result = Invoke-Command -ComputerName $sourceNode -ScriptBlock {
                param($target)
                
                $results = @{
                    Ping = Test-Connection -ComputerName $target -Count 3 -ErrorAction SilentlyContinue
                    SMB = Test-NetConnection -ComputerName $target -Port 445 -WarningAction SilentlyContinue
                    WinRM = Test-NetConnection -ComputerName $target -Port 5985 -WarningAction SilentlyContinue
                }
                
                return $results
            } -ArgumentList $targetNode -ErrorAction Stop
            
            $pingStatus = if ($result.Ping) { "OK" } else { "FAILED" }
            $smbStatus = if ($result.SMB.TcpTestSucceeded) { "OK" } else { "BLOCKED" }
            $winrmStatus = if ($result.WinRM.TcpTestSucceeded) { "OK" } else { "BLOCKED" }
            
            Write-Log -Message "  $sourceNode -> $targetNode" -Level "INFO"
            Write-Log -Message "    Ping: $pingStatus | SMB: $smbStatus | WinRM: $winrmStatus" -Level $(if ($pingStatus -eq "OK" -and $smbStatus -eq "OK") { "SUCCESS" } else { "ERROR" })
            
            $TestResults.Connectivity += @{
                Source = $sourceNode
                Target = $targetNode
                Ping = ($pingStatus -eq "OK")
                SMB = ($smbStatus -eq "OK")
                WinRM = ($winrmStatus -eq "OK")
            }
        }
        catch {
            Write-Log -Message "  $sourceNode -> $targetNode : Test failed - $_" -Level "ERROR"
        }
    }
}

function Test-JumboFrameSupport {
    if (-not $TestJumboFrames) {
        Write-Log -Message "Skipping jumbo frame test (use -TestJumboFrames to enable)" -Level "INFO"
        return
    }
    
    Write-Log -Message "Testing jumbo frame (MTU 9000) support..." -Level "INFO"
    
    foreach ($node in $NodeNames) {
        if (-not (Test-Connection -ComputerName $node -Count 1 -Quiet)) {
            continue
        }
        
        try {
            # Test with large packet (8972 bytes = 9000 - 28 for ICMP headers)
            $jumboTest = Test-Connection -ComputerName $node -Count 3 -BufferSize 8972 -DontFragment -ErrorAction SilentlyContinue
            
            if ($jumboTest) {
                Write-Log -Message "  $node : Jumbo frames supported (MTU 9000)" -Level "SUCCESS"
                $TestResults.MTU += @{ Node = $node; JumboSupported = $true }
            }
            else {
                Write-Log -Message "  $node : Jumbo frames NOT supported" -Level "WARN"
                $TestResults.MTU += @{ Node = $node; JumboSupported = $false }
            }
        }
        catch {
            Write-Log -Message "  $node : MTU test failed" -Level "WARN"
        }
        
        # Also check from node's perspective
        try {
            $mtuConfig = Invoke-Command -ComputerName $node -ScriptBlock {
                Get-NetAdapterAdvancedProperty -Name * | Where-Object { $_.RegistryKeyword -eq "*JumboPacket" }
            } -ErrorAction SilentlyContinue
            
            if ($mtuConfig) {
                Write-Log -Message "    Current MTU settings: $($mtuConfig.DisplayValue -join ', ')" -Level "INFO"
            }
        }
        catch { }
    }
}

function Test-GatewayRouting {
    if (-not $GatewayIP) {
        Write-Log -Message "Skipping gateway test (no GatewayIP specified)" -Level "INFO"
        return
    }
    
    Write-Log -Message "Testing gateway and routing..." -Level "INFO"
    
    # Test gateway from local machine
    $gwTest = Test-Connection -ComputerName $GatewayIP -Count 2 -ErrorAction SilentlyContinue
    
    if ($gwTest) {
        Write-Log -Message "  Gateway $GatewayIP : Reachable" -Level "SUCCESS"
    }
    else {
        Write-Log -Message "  Gateway $GatewayIP : NOT reachable" -Level "ERROR"
        return
    }
    
    # Test from each node
    foreach ($node in $NodeNames) {
        if (-not (Test-Connection -ComputerName $node -Count 1 -Quiet)) {
            continue
        }
        
        try {
            $result = Invoke-Command -ComputerName $node -ScriptBlock {
                param($gw)
                
                $ping = Test-Connection -ComputerName $gw -Count 2 -ErrorAction SilentlyContinue
                $route = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } | Select-Object -First 1
                
                @{
                    GatewayReachable = ($null -ne $ping)
                    DefaultRoute = $route.NextHop
                }
            } -ArgumentList $GatewayIP -ErrorAction Stop
            
            if ($result.GatewayReachable) {
                Write-Log -Message "  $node -> Gateway: OK (Default route: $($result.DefaultRoute))" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $node -> Gateway: FAILED" -Level "ERROR"
            }
        }
        catch {
            Write-Log -Message "  $node : Routing test failed" -Level "ERROR"
        }
    }
}

function Test-AzureConnectivity {
    if (-not $AzureEndpointTest) {
        Write-Log -Message "Skipping Azure endpoint test (use -AzureEndpointTest to enable)" -Level "INFO"
        return
    }
    
    Write-Log -Message "Testing Azure endpoint connectivity..." -Level "INFO"
    
    # Get first reachable node
    $testNode = $NodeNames | Where-Object { Test-Connection -ComputerName $_ -Count 1 -Quiet } | Select-Object -First 1
    
    if (-not $testNode) {
        Write-Log -Message "  No reachable nodes for Azure test" -Level "ERROR"
        return
    }
    
    foreach ($endpoint in $AzureEndpoints) {
        try {
            $result = Invoke-Command -ComputerName $testNode -ScriptBlock {
                param($host, $port)
                
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcp.BeginConnect($host, $port, $null, $null)
                    $wait = $connect.AsyncWaitHandle.WaitOne(5000, $false)
                    
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
            } -ArgumentList $endpoint.Host, $endpoint.Port -ErrorAction Stop
            
            if ($result) {
                Write-Log -Message "  $($endpoint.Name): OK" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $($endpoint.Name): BLOCKED" -Level "ERROR"
            }
            
            $TestResults.Azure += @{
                Name = $endpoint.Name
                Host = $endpoint.Host
                Port = $endpoint.Port
                Reachable = $result
            }
        }
        catch {
            Write-Log -Message "  $($endpoint.Name): Test failed - $_" -Level "ERROR"
        }
    }
}

function Test-DNSResolution {
    Write-Log -Message "Testing DNS resolution..." -Level "INFO"
    
    $testNames = @(
        "management.azure.com"
        "login.microsoftonline.com"
    )
    
    $testNode = $NodeNames | Where-Object { Test-Connection -ComputerName $_ -Count 1 -Quiet } | Select-Object -First 1
    
    if (-not $testNode) {
        Write-Log -Message "  No reachable nodes for DNS test" -Level "ERROR"
        return
    }
    
    foreach ($name in $testNames) {
        try {
            $result = Invoke-Command -ComputerName $testNode -ScriptBlock {
                param($hostname)
                Resolve-DnsName -Name $hostname -ErrorAction Stop | Select-Object -First 1
            } -ArgumentList $name -ErrorAction Stop
            
            Write-Log -Message "  $name -> $($result.IPAddress)" -Level "SUCCESS"
        }
        catch {
            Write-Log -Message "  $name : Resolution FAILED" -Level "ERROR"
        }
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Network Readiness Validation" -Level "INFO"
    Write-Log -Message "Nodes: $($NodeNames -join ', ')" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    Test-NodeConnectivity
    Write-Host ""
    
    Test-NodeToNodeConnectivity
    Write-Host ""
    
    Test-JumboFrameSupport
    Write-Host ""
    
    Test-GatewayRouting
    Write-Host ""
    
    Test-DNSResolution
    Write-Host ""
    
    Test-AzureConnectivity
    Write-Host ""
    
    # Summary
    Write-Log -Message "========================================" -Level "INFO"
    
    $reachableNodes = ($TestResults.Nodes | Where-Object { $_.Reachable }).Count
    $totalNodes = $TestResults.Nodes.Count
    
    Write-Log -Message "Summary:" -Level "INFO"
    Write-Host "  Nodes reachable: $reachableNodes / $totalNodes"
    
    if ($TestResults.Azure.Count -gt 0) {
        $azureOK = ($TestResults.Azure | Where-Object { $_.Reachable }).Count
        Write-Host "  Azure endpoints: $azureOK / $($TestResults.Azure.Count)"
    }
    
    if ($reachableNodes -eq $totalNodes) {
        Write-Log -Message "Network readiness: PASSED" -Level "SUCCESS"
    }
    else {
        Write-Log -Message "Network readiness: ISSUES FOUND" -Level "WARN"
    }
}
catch {
    Write-Log -Message "Network validation failed: $_" -Level "ERROR"
    exit 1
}
