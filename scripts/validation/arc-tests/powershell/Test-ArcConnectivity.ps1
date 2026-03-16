<#
.SYNOPSIS
    Tests Azure Arc connectivity and configuration for Azure Local nodes.

.DESCRIPTION
    This script validates Azure Arc connection including:
    - Arc agent installation status
    - Arc agent connectivity
    - Extension status
    - Azure resource registration
    - Managed identity configuration

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER SubscriptionId
    Azure subscription ID for validation.

.PARAMETER ResourceGroup
    Resource group name where Arc resources are registered.

.PARAMETER OutputPath
    Path to save test results.

.EXAMPLE
    .\Test-ArcConnectivity.ps1 -ClusterName "azl-cluster-01" -SubscriptionId "xxx" -ResourceGroup "rg-azl-01"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 1.0.0
    Created: 2026-02-01
    
    Requires Az.ConnectedMachine module and appropriate Azure permissions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

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

# Required Azure Arc endpoints
$ArcEndpoints = @(
    @{ Name = "Azure Resource Manager"; Host = "management.azure.com"; Port = 443 }
    @{ Name = "Azure Active Directory"; Host = "login.microsoftonline.com"; Port = 443 }
    @{ Name = "Arc Global Endpoint"; Host = "gbl.his.arc.azure.com"; Port = 443 }
    @{ Name = "Arc Data Plane"; Host = "gbl.dp.kubernetesconfiguration.azure.com"; Port = 443 }
    @{ Name = "Arc Guest Config"; Host = "agentserviceapi.guestconfiguration.azure.com"; Port = 443 }
    @{ Name = "Arc Metadata"; Host = "azgn-eus.his.arc.azure.com"; Port = 443 }
)

# Initialize results
$TestResults = @{
    Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    ClusterName = $ClusterName
    Nodes = @()
    AzureResources = @()
    EndpointTests = @()
}

function Test-ArcAgentInstallation {
    Write-Log -Message "Checking Arc agent installation status..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $agentInfo = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                $agentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
                
                if (Test-Path $agentPath) {
                    # Get agent version
                    $versionOutput = & $agentPath version 2>&1
                    $version = ($versionOutput | Select-String -Pattern "^\d+\.\d+\.\d+" | Select-Object -First 1).ToString()
                    
                    # Get agent status
                    $statusJson = & $agentPath show --json 2>&1
                    $status = $statusJson | ConvertFrom-Json
                    
                    return @{
                        Installed = $true
                        Version = $version
                        Status = $status.status
                        ResourceId = $status.resourceId
                        TenantId = $status.tenantId
                        SubscriptionId = $status.subscriptionId
                        ResourceGroup = $status.resourceGroup
                        MachineName = $status.machineName
                        LastHeartbeat = $status.lastHeartbeat
                        AgentErrorCode = $status.agentErrorCode
                        AgentErrorMessage = $status.agentErrorMessage
                    }
                }
                else {
                    return @{ Installed = $false }
                }
            } -ErrorAction Stop
            
            $nodeResult = @{
                NodeName = $node.Name
                AgentInstalled = $agentInfo.Installed
                AgentVersion = $agentInfo.Version
                Status = $agentInfo.Status
                ResourceId = $agentInfo.ResourceId
                LastHeartbeat = $agentInfo.LastHeartbeat
            }
            
            $TestResults.Nodes += $nodeResult
            
            if ($agentInfo.Installed) {
                if ($agentInfo.Status -eq "Connected") {
                    Write-Log -Message "  [$($node.Name)] Arc Agent v$($agentInfo.Version) - Connected" -Level "SUCCESS"
                    Write-Log -Message "    Resource: $($agentInfo.ResourceId)" -Level "INFO"
                    Write-Log -Message "    Last Heartbeat: $($agentInfo.LastHeartbeat)" -Level "INFO"
                }
                elseif ($agentInfo.Status -eq "Disconnected") {
                    Write-Log -Message "  [$($node.Name)] Arc Agent v$($agentInfo.Version) - Disconnected" -Level "ERROR"
                    if ($agentInfo.AgentErrorMessage) {
                        Write-Log -Message "    Error: $($agentInfo.AgentErrorMessage)" -Level "ERROR"
                    }
                }
                else {
                    Write-Log -Message "  [$($node.Name)] Arc Agent v$($agentInfo.Version) - $($agentInfo.Status)" -Level "WARN"
                }
            }
            else {
                Write-Log -Message "  [$($node.Name)] Arc Agent NOT INSTALLED" -Level "ERROR"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check Arc agent: $_" -Level "ERROR"
    }
}

function Test-ArcEndpointConnectivity {
    Write-Log -Message "Testing Arc endpoint connectivity..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1
        
        foreach ($endpoint in $ArcEndpoints) {
            $result = Invoke-Command -ComputerName $nodes.Name -ScriptBlock {
                param($host, $port)
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcp.BeginConnect($host, $port, $null, $null)
                    $wait = $connect.AsyncWaitHandle.WaitOne(5000, $false)
                    if ($wait) {
                        $tcp.EndConnect($connect)
                        $tcp.Close()
                        return @{ Success = $true; LatencyMs = 0 }
                    }
                    $tcp.Close()
                    return @{ Success = $false; Error = "Connection timeout" }
                }
                catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList $endpoint.Host, $endpoint.Port -ErrorAction SilentlyContinue
            
            $TestResults.EndpointTests += @{
                Name = $endpoint.Name
                Host = $endpoint.Host
                Port = $endpoint.Port
                Success = $result.Success
                Error = $result.Error
            }
            
            if ($result.Success) {
                Write-Log -Message "  $($endpoint.Name): OK" -Level "SUCCESS"
            }
            else {
                Write-Log -Message "  $($endpoint.Name): FAILED - $($result.Error)" -Level "ERROR"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to test Arc endpoints: $_" -Level "ERROR"
    }
}

function Test-ArcAzureResources {
    if (-not $SubscriptionId -or -not $ResourceGroup) {
        Write-Log -Message "Skipping Azure resource validation (SubscriptionId and ResourceGroup required)" -Level "INFO"
        return
    }
    
    Write-Log -Message "Validating Arc resources in Azure..." -Level "INFO"
    
    try {
        # Set subscription context
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        
        # Get Arc machines
        $arcMachines = Get-AzConnectedMachine -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
        
        if ($arcMachines) {
            foreach ($machine in $arcMachines) {
                $result = @{
                    Name = $machine.Name
                    Status = $machine.Status
                    AgentVersion = $machine.AgentVersion
                    OSName = $machine.OSName
                    OSVersion = $machine.OSVersion
                    LastStatusChange = $machine.LastStatusChange
                    ProvisioningState = $machine.ProvisioningState
                }
                
                $TestResults.AzureResources += $result
                
                if ($machine.Status -eq "Connected") {
                    Write-Log -Message "  $($machine.Name): Connected (v$($machine.AgentVersion))" -Level "SUCCESS"
                }
                else {
                    Write-Log -Message "  $($machine.Name): $($machine.Status)" -Level "WARN"
                }
            }
        }
        else {
            Write-Log -Message "  No Arc machines found in resource group: $ResourceGroup" -Level "WARN"
        }
        
        # Check for HCI cluster resource
        $hciCluster = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.AzureStackHCI/clusters" -ErrorAction SilentlyContinue
        
        if ($hciCluster) {
            Write-Log -Message "  HCI Cluster Resource: $($hciCluster.Name) - Found" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  HCI Cluster Resource: Not found (may not be registered yet)" -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "Failed to validate Azure resources: $_" -Level "ERROR"
    }
}

function Test-ArcExtensions {
    Write-Log -Message "Checking Arc extensions..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" }
        
        foreach ($node in $nodes) {
            $extensions = Invoke-Command -ComputerName $node.Name -ScriptBlock {
                $agentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
                
                if (Test-Path $agentPath) {
                    $extJson = & $agentPath extension list --json 2>&1
                    if ($extJson -match "^\[") {
                        return $extJson | ConvertFrom-Json
                    }
                }
                return @()
            } -ErrorAction SilentlyContinue
            
            if ($extensions -and $extensions.Count -gt 0) {
                Write-Log -Message "  [$($node.Name)] Extensions:" -Level "INFO"
                foreach ($ext in $extensions) {
                    $status = if ($ext.provisioningState -eq "Succeeded") { "SUCCESS" } else { "WARN" }
                    Write-Log -Message "    - $($ext.name): $($ext.provisioningState)" -Level $status
                }
            }
            else {
                Write-Log -Message "  [$($node.Name)] No extensions installed" -Level "INFO"
            }
        }
    }
    catch {
        Write-Log -Message "Failed to check Arc extensions: $_" -Level "ERROR"
    }
}

function Test-ManagedIdentity {
    Write-Log -Message "Checking managed identity configuration..." -Level "INFO"
    
    try {
        $nodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -eq "Up" } | Select-Object -First 1
        
        $identityStatus = Invoke-Command -ComputerName $nodes.Name -ScriptBlock {
            $agentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            
            if (Test-Path $agentPath) {
                # Check if we can acquire a token using managed identity
                try {
                    $tokenResult = & $agentPath token get --resource "https://management.azure.com/" 2>&1
                    if ($tokenResult -match "accessToken") {
                        return @{ Available = $true; Error = $null }
                    }
                    return @{ Available = $false; Error = $tokenResult }
                }
                catch {
                    return @{ Available = $false; Error = $_.Exception.Message }
                }
            }
            return @{ Available = $false; Error = "Agent not installed" }
        } -ErrorAction SilentlyContinue
        
        if ($identityStatus.Available) {
            Write-Log -Message "  Managed identity is available and working" -Level "SUCCESS"
        }
        else {
            Write-Log -Message "  Managed identity not available: $($identityStatus.Error)" -Level "WARN"
        }
    }
    catch {
        Write-Log -Message "Failed to check managed identity: $_" -Level "ERROR"
    }
}

function Export-ArcTestResults {
    if ($OutputPath) {
        $reportPath = Join-Path $OutputPath "arc-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $TestResults | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath
        Write-Log -Message "Results saved to: $reportPath" -Level "INFO"
    }
}

# Main execution
try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Azure Arc Connectivity Validation" -Level "INFO"
    Write-Log -Message "Cluster: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""
    
    # Check for required modules
    if (-not (Get-Module -ListAvailable -Name Az.ConnectedMachine)) {
        Write-Log -Message "Az.ConnectedMachine module not installed. Some tests may be limited." -Level "WARN"
    }
    
    Test-ArcAgentInstallation
    Write-Host ""
    
    Test-ArcEndpointConnectivity
    Write-Host ""
    
    Test-ArcExtensions
    Write-Host ""
    
    Test-ManagedIdentity
    Write-Host ""
    
    Test-ArcAzureResources
    Write-Host ""
    
    # Export results
    Export-ArcTestResults
    
    # Summary
    $connectedNodes = ($TestResults.Nodes | Where-Object { $_.Status -eq "Connected" }).Count
    $totalNodes = $TestResults.Nodes.Count
    $failedEndpoints = ($TestResults.EndpointTests | Where-Object { -not $_.Success }).Count
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Summary:" -Level "INFO"
    Write-Host "  Arc Nodes Connected: $connectedNodes / $totalNodes"
    Write-Host "  Endpoint Failures: $failedEndpoints"
    
    if ($connectedNodes -eq $totalNodes -and $failedEndpoints -eq 0) {
        Write-Log -Message "Arc validation: PASSED" -Level "SUCCESS"
        exit 0
    }
    elseif ($connectedNodes -gt 0) {
        Write-Log -Message "Arc validation: PARTIAL" -Level "WARN"
        exit 0
    }
    else {
        Write-Log -Message "Arc validation: FAILED" -Level "ERROR"
        exit 1
    }
}
catch {
    Write-Log -Message "Arc validation failed: $_" -Level "ERROR"
    exit 1
}
