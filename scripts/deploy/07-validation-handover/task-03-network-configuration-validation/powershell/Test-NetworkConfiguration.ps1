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

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name (the cluster to validate) and azure.location (the region for the endpoint list of Microsoft Learn); the whole file is not validated here.

.PARAMETER TestExternalConnectivity
    Switch to test external/internet connectivity.

.PARAMETER CustomEndpoints
    Array of custom endpoints to test (hostname:port format).

.PARAMETER OutputPath
    Path to save test results.

.EXAMPLE
    .\Test-NetworkConfiguration.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    .\Test-NetworkConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -TestExternalConnectivity -CustomEndpoints @("192.168.1.1:443")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
#>
#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read by the functions of the script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names of the check functions inside the script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The values are passed to the remote script blocks with -ArgumentList.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [switch]$TestExternalConnectivity,

    [Parameter(Mandatory = $false)]
    [string[]]$CustomEndpoints,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

$script:ErrorCount = 0
function Write-Line {
    param([string]$Message, [string]$Level = 'INFO')
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } default { 'White' } }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Error "Cannot read the infrastructure file: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
$ClusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $ClusterName) { Write-Error 'cluster.name is missing in the infrastructure file. It is the name of the cluster to validate.' -ErrorAction Continue; exit 2 }

# Azure and Arc endpoints to test: the one documented list of the toolkit (Learn: Firewall requirements for Azure Local), for the region of azure.location.
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'arm-deployment', 'verification', 'AzlVerification.Endpoints.psm1'))) -Force
$AzureEndpoints = @(Get-AzlEndpointSet -Location ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')) -Group Arc, Auth, Management, DataPlane -Port 443 | ForEach-Object { @{ Name = $_.Note; Host = $_.Host; Port = $_.Port } })

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
    Write-Line -Message "Checking physical network adapters..." -Level "INFO"
    
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
                Write-Line -Message "  [$($node.Name)] $($adapter.Name): $($adapter.LinkSpeed) - Up" -Level "SUCCESS"
            }
            
            # Check for down adapters
            $downAdapters = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike "*Hyper-V*" -and $_.Status -ne "Up" }
            } -ErrorAction SilentlyContinue
            
            foreach ($adapter in $downAdapters) {
                Write-Line -Message "  [$($node.Name)] $($adapter.Name): $($adapter.Status)" -Level "WARN"
            }
        }
    }
    catch {
        Write-Line -Message "Failed to check network adapters: $_" -Level "ERROR"
    }
}

function Test-VirtualSwitchConfiguration {
    Write-Line -Message "Checking virtual switch configuration..." -Level "INFO"
    
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
                    Write-Line -Message "  [$($node.Name)] $($switch.Name): SET Enabled (Members: $(@($teamMembers).Count))" -Level "SUCCESS"
                }
                else {
                    Write-Line -Message "  [$($node.Name)] $($switch.Name): External switch" -Level "INFO"
                }
            }
        }
    }
    catch {
        Write-Line -Message "Failed to check virtual switches: $_" -Level "ERROR"
    }
}

function Test-NetworkAtcIntents {
    Write-Line -Message "Checking Network ATC intents..." -Level "INFO"
    
    try {
        $intents = Get-NetIntent -ClusterName $ClusterName -ErrorAction SilentlyContinue
        
        if ($intents) {
            foreach ($intent in $intents) {
                $status = Get-NetIntentStatus -ClusterName $ClusterName -Name $intent.IntentName -ErrorAction SilentlyContinue
                
                if ($status.ConfigurationStatus -eq "Success" -or $status.ConfigurationStatus -eq "Completed") {
                    Write-Line -Message "  Intent: $($intent.IntentName) - $($intent.NetAdapterName) - Configured" -Level "SUCCESS"
                }
                else {
                    Write-Line -Message "  Intent: $($intent.IntentName) - Status: $($status.ConfigurationStatus)" -Level "WARN"
                }
            }
        }
        else {
            Write-Line -Message "  No Network ATC intents found (may be using manual configuration)" -Level "INFO"
        }
    }
    catch {
        Write-Line -Message "  Network ATC check failed (may not be available): $_" -Level "INFO"
    }
}

function Test-RdmaConfiguration {
    Write-Line -Message "Checking RDMA configuration..." -Level "INFO"
    
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
                    Write-Line -Message "  [$($node.Name)] $($adapter.Name): RDMA Enabled" -Level "SUCCESS"
                }
            }
            else {
                Write-Line -Message "  [$($node.Name)] No RDMA-enabled adapters found" -Level "WARN"
            }
        }
    }
    catch {
        Write-Line -Message "Failed to check RDMA: $_" -Level "ERROR"
    }
}

function Test-ClusterNetworkConnectivity {
    Write-Line -Message "Checking cluster network connectivity..." -Level "INFO"
    
    try {
        $networks = Get-ClusterNetwork -Cluster $ClusterName
        
        foreach ($network in $networks) {
            $status = if ($network.State -eq "Up") { "SUCCESS" } else { "ERROR" }
            
            Write-Line -Message "  $($network.Name): $($network.State) (Role: $($network.Role))" -Level $status
            
            $TestResults.ClusterNetworks += @{
                Name = $network.Name
                State = $network.State.ToString()
                Role = $network.Role.ToString()
                Address = $network.Address
                Metric = $network.Metric
            }
        }
        
        # Test node-to-node connectivity
        Write-Line -Message "Testing node-to-node connectivity..." -Level "INFO"
        
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
                        Write-Line -Message "  $sourceNode -> $targetNode : OK" -Level "SUCCESS"
                    }
                    else {
                        Write-Line -Message "  $sourceNode -> $targetNode : FAILED" -Level "ERROR"
                    }
                }
            }
        }
    }
    catch {
        Write-Line -Message "Failed to check cluster networks: $_" -Level "ERROR"
    }
}

function Test-DnsResolution {
    Write-Line -Message "Checking DNS resolution..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1
        
        # The names to resolve: the cluster, and the management and sign-in hosts of the one documented endpoint list of the toolkit.
        $testNames = @($ClusterName) + @(Get-AzlEndpointSet -Location ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')) -Group Auth, Management -Port 443 | ForEach-Object { $_.Host } | Select-Object -Unique -First 2)
        
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
                Write-Line -Message "  $name -> $($result.IP)" -Level "SUCCESS"
            }
            else {
                Write-Line -Message "  $name -> Failed: $($result.Error)" -Level "ERROR"
            }
        }
    }
    catch {
        Write-Line -Message "Failed to check DNS: $_" -Level "ERROR"
    }
}

function Test-ExternalEndpoints {
    if (-not $TestExternalConnectivity) {
        Write-Line -Message "Skipping external connectivity tests (use -TestExternalConnectivity to enable)" -Level "INFO"
        return
    }
    
    Write-Line -Message "Testing external endpoint connectivity..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1
        
        foreach ($endpoint in $AzureEndpoints) {
            $result = Invoke-Command -ComputerName $nodes.Name -ScriptBlock {
                param($targetHost, $port)
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcp.BeginConnect($targetHost, $port, $null, $null)
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
                Write-Line -Message "  $($endpoint.Name): $($endpoint.Host):$($endpoint.Port) - OK" -Level "SUCCESS"
            }
            else {
                Write-Line -Message "  $($endpoint.Name): $($endpoint.Host):$($endpoint.Port) - FAILED" -Level "ERROR"
            }
        }
        
        # Test custom endpoints
        if ($CustomEndpoints) {
            foreach ($ep in $CustomEndpoints) {
                $parts = $ep -split ":"
                $endpointHost = $parts[0]
                $port = if ($parts.Count -gt 1) { [int]$parts[1] } else { 443 }
                
                $result = Invoke-Command -ComputerName $nodes.Name -ScriptBlock {
                    param($h, $p)
                    Test-NetConnection -ComputerName $h -Port $p -WarningAction SilentlyContinue | 
                        Select-Object -ExpandProperty TcpTestSucceeded
                } -ArgumentList $endpointHost, $port -ErrorAction SilentlyContinue
                
                if ($result) {
                    Write-Line -Message "  Custom: ${endpointHost}:${port} - OK" -Level "SUCCESS"
                }
                else {
                    Write-Line -Message "  Custom: ${endpointHost}:${port} - FAILED" -Level "ERROR"
                }
            }
        }
    }
    catch {
        Write-Line -Message "Failed to test external endpoints: $_" -Level "ERROR"
    }
}

function Export-NetworkTestResults {
    if ($OutputPath) {
        $reportPath = Join-Path $OutputPath "network-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $TestResults | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath
        Write-Line -Message "Results saved to: $reportPath" -Level "INFO"
    }
}

# Main execution
try {
    Write-Line -Message "========================================" -Level "INFO"
    Write-Line -Message "Network Configuration and Connectivity Validation" -Level "INFO"
    Write-Line -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Line -Message "========================================" -Level "INFO"
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
    
    Write-Line -Message "========================================" -Level "INFO"
    Write-Line -Message "Network validation complete" -Level "SUCCESS"
    if ($script:ErrorCount -gt 0) { Write-Line -Message "$($script:ErrorCount) problem(s) were found." -Level "WARN"; exit 1 }
    exit 0
}
catch {
    Write-Line -Message "Network validation failed: $_" -Level "ERROR"
    exit 1
}
