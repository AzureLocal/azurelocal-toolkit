<#
.SYNOPSIS
    Tests Azure Local network configuration and connectivity. Read only.

.DESCRIPTION
    Stage 07 (validation and handover), task 03. Over PowerShell remoting the script asks the nodes of the cluster:
    - Physical network adapter status (every node)
    - Virtual switch configuration and its team members (every node)
    - Network ATC intents and their status on every node (Get-NetIntentStatus)
    - RDMA configuration (every node)
    - Cluster network state, and a ping from every node to every other node
    - DNS resolution from a node (the cluster name and hosts of the documented endpoint list)
    - External connectivity from a node (only with -TestExternalConnectivity)

    Run it from the management host. Every question is asked on a node, and every node is asked at its own management address of
    the file, so this host needs neither the failover clustering tools nor membership of the cluster's domain, and the names of
    the cluster and its nodes need not resolve from it. The script asks nothing and changes nothing.

    Exit codes: 0 no problem was found (warnings are listed); 1 a problem was found or the cluster could not be reached; 2 cluster.name
    is missing or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads cluster.name (the cluster to validate), azure.location (the region for the endpoint list of
    Microsoft Learn), nodes[] (the management addresses to connect to) and identity.active_directory (the deployment user and its secret
    reference); the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to send the cluster questions to. Default: the first node of nodes[] that answers on WinRM at its management
    address; cluster.name when the file has no node address.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Default: the deployment (LCM) user of the file, its secret read through the
    toolkit's secret resolver; the account that runs the script when the file has none or the secret cannot be read.

.PARAMETER TestExternalConnectivity
    Switch to test external/internet connectivity.

.PARAMETER CustomEndpoints
    Array of custom endpoints to test (hostname:port format).

.PARAMETER OutputPath
    Folder to save the test results (a JSON file) in. Created when it does not exist.

.EXAMPLE
    .\Test-NetworkConfiguration.ps1 -InfrastructureFile ./infrastructure.yml

.EXAMPLE
    .\Test-NetworkConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -TestExternalConnectivity -CustomEndpoints @("proxy.improbability.cloud:8080")

.NOTES
    Author: Azure Local Cloud AzureLocalCloud Team
    Version: 2.0.0
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
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

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
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force

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
$connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $ComputerName -Credential $Credential -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }

# Azure and Arc endpoints to test: the one documented list of the toolkit (Learn: Firewall requirements for Azure Local), for the region of azure.location.
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'arm-deployment', 'verification', 'AzlVerification.Endpoints.psm1'))) -Force
$location = [string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.location')
$AzureEndpoints = @(Get-AzlEndpointSet -Location $location -Group Arc, Auth, Management, DataPlane -Port 443 | ForEach-Object { @{ Name = $_.Note; Host = $_.Host; Port = $_.Port } })

# Initialize results
$TestResults = @{
    Timestamp         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    ClusterName       = $ClusterName
    NetworkAdapters   = @()
    VirtualSwitches   = @()
    NetworkIntents    = @()
    ClusterNetworks   = @()
    RdmaStatus        = @()
    NodeConnectivity  = @()
    DnsResolution     = @()
    ConnectivityTests = @()
}
$script:UpNodes = @()

# ---- The blocks that run on a node (Windows PowerShell): read only, plain values back.
$ReadCluster = {
    @{
        Nodes    = @(Get-ClusterNode -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.Name; State = [string]$_.State } })
        Networks = @(Get-ClusterNetwork -ErrorAction Stop | ForEach-Object { @{ Name = [string]$_.Name; State = [string]$_.State; Role = [string]$_.Role; Address = [string]$_.Address; Metric = [int]$_.Metric } })
    }
}
$ReadNodeNetwork = {
    $physical = @(Get-NetAdapter -Physical -ErrorAction Stop)
    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object {
            $members = @()
            if ($_.EmbeddedTeamingEnabled) { $members = @((Get-VMSwitchTeam -VMSwitch $_ -ErrorAction SilentlyContinue).NetAdapterInterfaceDescription) }
            @{ Name = [string]$_.Name; SwitchType = [string]$_.SwitchType; EmbeddedTeaming = [bool]$_.EmbeddedTeamingEnabled; TeamMembers = @($members | ForEach-Object { [string]$_ }) }
        })
    @{
        Adapters = @($physical | ForEach-Object { @{ Name = [string]$_.Name; InterfaceDescription = [string]$_.InterfaceDescription; Status = [string]$_.Status; LinkSpeed = [string]$_.LinkSpeed; MediaType = [string]$_.MediaType } })
        Switches = $switches
        Rdma     = @(Get-NetAdapterRdma -ErrorAction SilentlyContinue | Where-Object { $_.Enabled } | ForEach-Object { @{ Name = [string]$_.Name; Enabled = [bool]$_.Enabled } })
    }
}
$ReadIntents = {
    if (-not (Get-Command Get-NetIntentStatus -ErrorAction SilentlyContinue)) { return @{ Available = $false; Rows = @() } }
    @{
        Available = $true
        Rows      = @(Get-NetIntentStatus -ErrorAction Stop | ForEach-Object { @{ Intent = [string]$_.IntentName; Node = [string]$_.Host; Configuration = [string]$_.ConfigurationStatus; Provisioning = [string]$_.ProvisioningStatus; Error = [string]$_.Error } })
    }
}
$PingNodes = { param($Targets) foreach ($target in $Targets) { @{ Target = [string]$target; Ok = [bool](Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue) } } }
$ResolveNames = {
    param($Names)
    foreach ($name in $Names) {
        try { $resolved = @(Resolve-DnsName -Name $name -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress }); @{ Name = [string]$name; Success = ($resolved.Count -gt 0); IP = [string]$(if ($resolved.Count -gt 0) { $resolved[0].IPAddress }); Error = $(if ($resolved.Count -eq 0) { 'no address record' } else { '' }) } }
        catch { @{ Name = [string]$name; Success = $false; IP = ''; Error = $_.Exception.Message } }
    }
}
$ProbeEndpoints = {
    param($Targets)
    foreach ($target in $Targets) {
        $ok = $false
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $tcp.BeginConnect([string]$target.Host, [int]$target.Port, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne(5000, $false)) { $tcp.EndConnect($connect); $ok = $true }
        }
        catch { $ok = $false }
        finally { $tcp.Close() }
        @{ Host = [string]$target.Host; Port = [int]$target.Port; Ok = $ok }
    }
}

function Test-ClusterNetworkState {
    Write-Line -Message "Checking cluster networks..." -Level "INFO"

    $cluster = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadCluster
    $script:UpNodes = @(@($cluster.Nodes) | Where-Object { $_.State -eq 'Up' } | ForEach-Object { [string]$_.Name })
    foreach ($node in @(@($cluster.Nodes) | Where-Object { $_.State -ne 'Up' })) { Write-Line -Message "  Node $($node.Name) is $($node.State): it is not asked" -Level "WARN" }
    if ($script:UpNodes.Count -eq 0) { Write-Line -Message "  No node of the cluster is Up" -Level "ERROR" }

    foreach ($network in @($cluster.Networks)) {
        $status = if ($network.State -eq "Up") { "SUCCESS" } else { "ERROR" }
        Write-Line -Message "  $($network.Name): $($network.State) (Role: $($network.Role))" -Level $status
        $TestResults.ClusterNetworks += $network
    }
}

function Test-NodeNetwork {
    Write-Line -Message "Checking physical network adapters, virtual switches and RDMA on every node..." -Level "INFO"

    foreach ($node in $script:UpNodes) {
        try { $state = Invoke-AzlClusterCommand -Connection $connection -Node $node -ScriptBlock $ReadNodeNetwork }
        catch { Write-Line -Message "  [$node] The network state could not be read: $($_.Exception.Message)" -Level "ERROR"; continue }

        foreach ($adapter in @($state.Adapters)) {
            $TestResults.NetworkAdapters += @{ Node = $node; Name = $adapter.Name; InterfaceDescription = $adapter.InterfaceDescription; Status = $adapter.Status; LinkSpeed = $adapter.LinkSpeed; MediaType = $adapter.MediaType }
            if ($adapter.Status -eq 'Up') { Write-Line -Message "  [$node] $($adapter.Name): $($adapter.LinkSpeed) - Up" -Level "SUCCESS" }
            else { Write-Line -Message "  [$node] $($adapter.Name): $($adapter.Status)" -Level "WARN" }
        }

        if (@($state.Switches).Count -eq 0) { Write-Line -Message "  [$node] No virtual switch found" -Level "WARN" }
        foreach ($switch in @($state.Switches)) {
            $TestResults.VirtualSwitches += @{ Node = $node; Name = $switch.Name; SwitchType = $switch.SwitchType; EmbeddedTeaming = $switch.EmbeddedTeaming; TeamMembers = @($switch.TeamMembers) }
            if ($switch.EmbeddedTeaming) { Write-Line -Message "  [$node] $($switch.Name): SET Enabled (Members: $(@($switch.TeamMembers).Count))" -Level "SUCCESS" }
            else { Write-Line -Message "  [$node] $($switch.Name): $($switch.SwitchType) switch" -Level "INFO" }
        }

        if (@($state.Rdma).Count -eq 0) { Write-Line -Message "  [$node] No RDMA-enabled adapters found" -Level "WARN" }
        foreach ($adapter in @($state.Rdma)) {
            $TestResults.RdmaStatus += @{ Node = $node; Name = $adapter.Name; Enabled = $adapter.Enabled }
            Write-Line -Message "  [$node] $($adapter.Name): RDMA Enabled" -Level "SUCCESS"
        }
    }
}

function Test-NetworkAtcIntents {
    Write-Line -Message "Checking Network ATC intents..." -Level "INFO"

    try {
        $intents = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ReadIntents
        if (-not $intents.Available) { Write-Line -Message "  Network ATC is not available on the node (Get-NetIntentStatus)" -Level "WARN"; return }
        if (@($intents.Rows).Count -eq 0) { Write-Line -Message "  No Network ATC intent found" -Level "WARN"; return }

        foreach ($row in @($intents.Rows)) {
            $TestResults.NetworkIntents += $row
            if ($row.Configuration -eq 'Success' -and $row.Provisioning -eq 'Completed') {
                Write-Line -Message "  Intent: $($row.Intent) on $($row.Node) - Success, Completed" -Level "SUCCESS"
            }
            elseif ($row.Configuration -in 'Failed', 'Failure' -or $row.Provisioning -eq 'Failed') {
                Write-Line -Message "  Intent: $($row.Intent) on $($row.Node) - $($row.Configuration), $($row.Provisioning)$(if ($row.Error) { ": $($row.Error)" })" -Level "ERROR"
            }
            else {
                Write-Line -Message "  Intent: $($row.Intent) on $($row.Node) - $($row.Configuration), $($row.Provisioning)" -Level "WARN"
            }
        }
    }
    catch {
        Write-Line -Message "  The Network ATC intents could not be read: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Test-NodeToNodeConnectivity {
    Write-Line -Message "Testing node-to-node connectivity..." -Level "INFO"

    foreach ($sourceNode in $script:UpNodes) {
        $others = @($script:UpNodes | Where-Object { $_ -ne $sourceNode })
        if ($others.Count -eq 0) { continue }
        try { $pings = @(Invoke-AzlClusterCommand -Connection $connection -Node $sourceNode -ScriptBlock $PingNodes -ArgumentList @(, $others)) }
        catch { Write-Line -Message "  $sourceNode : the ping could not be run: $($_.Exception.Message)" -Level "ERROR"; continue }
        foreach ($targetNode in $others) {
            $ok = [bool](@($pings | Where-Object { $_.Target -eq $targetNode -and $_.Ok }).Count)
            $TestResults.NodeConnectivity += @{ Source = $sourceNode; Target = $targetNode; Ok = $ok }
            if ($ok) { Write-Line -Message "  $sourceNode -> $targetNode : OK" -Level "SUCCESS" }
            else { Write-Line -Message "  $sourceNode -> $targetNode : FAILED" -Level "ERROR" }
        }
    }
}

function Test-DnsResolution {
    Write-Line -Message "Checking DNS resolution..." -Level "INFO"

    try {
        # The names to resolve: the cluster, and the management and sign-in hosts of the one documented endpoint list of the toolkit.
        $testNames = @($ClusterName) + @(Get-AzlEndpointSet -Location $location -Group Auth, Management -Port 443 | ForEach-Object { $_.Host } | Select-Object -Unique -First 2)
        foreach ($result in @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ResolveNames -ArgumentList @(, $testNames))) {
            $TestResults.DnsResolution += $result
            if ($result.Success) { Write-Line -Message "  $($result.Name) -> $($result.IP)" -Level "SUCCESS" }
            else { Write-Line -Message "  $($result.Name) -> Failed: $($result.Error)" -Level "ERROR" }
        }
    }
    catch {
        Write-Line -Message "Failed to check DNS: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Test-ExternalEndpoints {
    if (-not $TestExternalConnectivity) {
        Write-Line -Message "Skipping external connectivity tests (use -TestExternalConnectivity to enable)" -Level "INFO"
        return
    }

    Write-Line -Message "Testing external endpoint connectivity from a node..." -Level "INFO"

    try {
        $targets = @($AzureEndpoints | ForEach-Object { @{ Name = $_.Name; Host = $_.Host; Port = $_.Port } })
        foreach ($ep in @($CustomEndpoints | Where-Object { $_ })) {
            $parts = $ep -split ':'
            $port = 443
            if ($parts.Count -gt 1 -and -not [int]::TryParse($parts[1], [ref]$port)) { Write-Line -Message "  Custom: '$ep' is not hostname:port" -Level "ERROR"; continue }
            $targets += @{ Name = 'Custom'; Host = $parts[0]; Port = $port }
        }
        $probe = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock $ProbeEndpoints -ArgumentList @(, @($targets | ForEach-Object { @{ Host = $_.Host; Port = $_.Port } })))
        foreach ($target in $targets) {
            $ok = [bool](@($probe | Where-Object { $_.Host -eq $target.Host -and $_.Port -eq $target.Port -and $_.Ok }).Count)
            $TestResults.ConnectivityTests += @{ Name = $target.Name; Host = $target.Host; Port = $target.Port; Success = $ok }
            if ($ok) { Write-Line -Message "  $($target.Name): $($target.Host):$($target.Port) - OK" -Level "SUCCESS" }
            else { Write-Line -Message "  $($target.Name): $($target.Host):$($target.Port) - FAILED" -Level "ERROR" }
        }
    }
    catch {
        Write-Line -Message "Failed to test external endpoints: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Export-NetworkTestResults {
    if ($OutputPath) {
        if (-not (Test-Path -LiteralPath $OutputPath)) { $null = New-Item -ItemType Directory -Path $OutputPath -Force }
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
    Write-Line -Message (Format-AzlClusterConnection -Connection $connection) -Level "INFO"
    foreach ($note in $connection.Notes) { Write-Line -Message $note -Level "WARN" }
    Write-Line -Message "========================================" -Level "INFO"
    Write-Host ""

    Test-ClusterNetworkState
    Write-Host ""

    Test-NodeNetwork
    Write-Host ""

    Test-NetworkAtcIntents
    Write-Host ""

    Test-NodeToNodeConnectivity
    Write-Host ""

    Test-DnsResolution
    Write-Host ""

    Test-ExternalEndpoints
    Write-Host ""

    # Export results
    Export-NetworkTestResults

    Write-Line -Message "========================================" -Level "INFO"
    if ($script:ErrorCount -gt 0) { Write-Line -Message "Network validation finished: $($script:ErrorCount) problem(s) were found." -Level "WARN"; exit 1 }
    Write-Line -Message "Network validation complete" -Level "SUCCESS"
    exit 0
}
catch {
    Write-Line -Message "Network validation failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}
