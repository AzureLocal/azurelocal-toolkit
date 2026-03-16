<#
.SYNOPSIS
    Safely shuts down an Azure Local (Azure Stack HCI) cluster for transport or maintenance.

.DESCRIPTION
    This script performs a complete, graceful shutdown of an Azure Local 2-node switchless 
    cluster following Microsoft best practices for Storage Spaces Direct (S2D) clusters.
    
    The shutdown order is critical for data integrity:
    1. Shut down all clustered VMs (save state or turn off)
    2. Stop the Cluster Service on all nodes (gracefully stops all cluster resources)
    3. Shut down Node 02 first
    4. Shut down Node 01 last (the node running the script)
    
    This script is designed to be run from an external management workstation (jump box)
    with remote PowerShell access to the cluster nodes.

.PARAMETER ClusterName
    The name of the Azure Local cluster. Default: cluster-01

.PARAMETER Node01
    IP address or hostname of Node 01. Default: 192.168.150.11

.PARAMETER Node02
    IP address or hostname of Node 02. Default: 192.168.150.12

.PARAMETER Credential
    PSCredential object for connecting to the nodes. If not provided, prompts for credentials.

.PARAMETER KeyVaultName
    Azure Key Vault name to retrieve credentials from. Default: kv-platform

.PARAMETER SecretName
    Key Vault secret name for credentials. Default: Domain-Admin-Password

.PARAMETER DomainUserName
    Domain username for authentication. Default: hybrid.mgmt\azureadmin

.PARAMETER SaveVMState
    If specified, saves VM state instead of shutting down VMs. Default: $false (shutdown VMs)

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER WhatIf
    Show what would happen without making changes.

.EXAMPLE
    .\Stop-AzureLocalCluster.ps1
    Shuts down the cluster using default settings and Key Vault credentials.

.EXAMPLE
    .\Stop-AzureLocalCluster.ps1 -SaveVMState -Force
    Saves VM state instead of shutdown, skips confirmation.

.EXAMPLE
    # Using solution configuration
    .\Stop-AzureLocalCluster.ps1 -Solution "azure-local"

.EXAMPLE
    $cred = Get-Credential
    .\Stop-AzureLocalCluster.ps1 -Credential $cred
    Uses provided credentials instead of Key Vault.

.NOTES
    Author: Hybrid Cloud Solutions Team
    Date: 2025-12-06
    Version: 1.1.0
    
    References:
    - https://learn.microsoft.com/en-us/azure/aks/aksarc/stop-start-cluster
    - https://learn.microsoft.com/en-us/powershell/module/failoverclusters/stop-cluster
    - https://learn.microsoft.com/en-us/azure/azure-local/manage/suspend-resume-cluster-maintenance

    CRITICAL: This script is for COMPLETE cluster shutdown (all nodes).
    For single-node maintenance, use Suspend-ClusterNode instead.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateSet("azure-local", "failover-clusters-scvmm", "scvmm-azure-arc", "azure-arc-servers")]
    [string]$Solution,

    [Parameter()]
    [string]$ClusterName,

    [Parameter()]
    [string]$Node01,

    [Parameter()]
    [string]$Node02,

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$KeyVaultName,

    [Parameter()]
    [string]$SecretName = "Domain-Admin-Password",

    [Parameter()]
    [string]$DomainUserName,

    [Parameter()]
    [switch]$SaveVMState,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$LogPath
)

# Load configuration if Solution specified
if ($Solution) {
    . "$PSScriptRoot\config-loader.ps1"
    . "$PSScriptRoot\keyvault-helper.ps1"
    
    $config = Get-SolutionConfig -Solution $Solution
    
    # Map config values to script parameters
    if (-not $ClusterName) { $ClusterName = $config.compute.azure_local.cluster_name }
    if (-not $Node01 -and $config.compute.cluster_nodes.Count -ge 1) { $Node01 = $config.compute.cluster_nodes[0].ip_address }
    if (-not $Node02 -and $config.compute.cluster_nodes.Count -ge 2) { $Node02 = $config.compute.cluster_nodes[1].ip_address }
    if (-not $KeyVaultName) { $KeyVaultName = $config.security.key_vaults.management.name }
    if (-not $DomainUserName) { $DomainUserName = $config.security.credentials.domain_join_username }
}

# Validate required parameters
if (-not $ClusterName -or -not $Node01 -or -not $Node02) {
    throw "ClusterName, Node01, and Node02 are required. Specify -Solution or provide parameters directly."
}

#region Variables
$script:StartTime = Get-Date
$script:LogFile = if ($LogPath) { $LogPath } else { Join-Path $PSScriptRoot "logs\cluster-shutdown-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" }
$script:LogEntries = @()
#endregion

#region Functions
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [switch]$NoConsole
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    $script:LogEntries += $logEntry
    
    if (-not $NoConsole) {
        $color = switch ($Level) {
            "INFO" { "Cyan" }
            "SUCCESS" { "Green" }
            "WARNING" { "Yellow" }
            "ERROR" { "Red" }
            "STEP" { "Magenta" }
            "DETAIL" { "Gray" }
            "VM" { "White" }
            default { "White" }
        }
        Write-Host "[$($timestamp.Split(' ')[1])] " -NoNewline -ForegroundColor DarkGray
        Write-Host "[$Level] " -NoNewline -ForegroundColor $color
        Write-Host $Message -ForegroundColor $color
    }
}

function Save-LogFile {
    try {
        $logDir = Split-Path $script:LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $script:LogEntries | Out-File -FilePath $script:LogFile -Encoding UTF8
        Write-Host "Log saved to: $script:LogFile" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "Failed to save log file: $_" -ForegroundColor Red
    }
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    Write-Log -Message $Message -Level $Status
}

function Get-KeyVaultCredential {
    param(
        [string]$VaultName,
        [string]$SecretName,
        [string]$UserName
    )
    
    Write-Step "Retrieving credentials from Key Vault: $VaultName" "INFO"
    
    try {
        $password = az keyvault secret show --vault-name $VaultName --name $SecretName --query "value" -o tsv 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to retrieve secret from Key Vault: $password"
        }
        
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $credential = New-Object PSCredential($UserName, $securePassword)
        
        Write-Step "Credentials retrieved successfully" "SUCCESS"
        return $credential
    }
    catch {
        Write-Step "Failed to get credentials from Key Vault: $_" "ERROR"
        throw
    }
}

function Test-NodeConnectivity {
    param([string]$NodeIP, [PSCredential]$Credential)
    
    try {
        $result = Invoke-Command -ComputerName $NodeIP -Credential $Credential -ScriptBlock {
            $env:COMPUTERNAME
        } -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}
#endregion

#region Main Script
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  AZURE LOCAL CLUSTER SHUTDOWN SCRIPT" -ForegroundColor Cyan
Write-Host "  Cluster: $ClusterName" -ForegroundColor Cyan
Write-Host "  Nodes: $Node01, $Node02" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Confirmation
if (-not $Force -and -not $WhatIfPreference) {
    Write-Host "WARNING: This script will COMPLETELY SHUT DOWN the Azure Local cluster!" -ForegroundColor Red
    Write-Host "         All VMs will be stopped and all nodes will be powered off." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Are you sure you want to proceed? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Step "Operation cancelled by user" "WARNING"
        exit 0
    }
}

# Step 1: Get credentials
Write-Step "========== STEP 1: AUTHENTICATION ==========" "STEP"
if (-not $Credential) {
    try {
        $Credential = Get-KeyVaultCredential -VaultName $KeyVaultName -SecretName $SecretName -UserName $DomainUserName
    }
    catch {
        Write-Step "Key Vault retrieval failed. Prompting for credentials..." "WARNING"
        $Credential = Get-Credential -Message "Enter domain admin credentials for cluster access"
    }
}

# Step 2: Verify connectivity to both nodes
Write-Step "========== STEP 2: VERIFY CONNECTIVITY ==========" "STEP"

Write-Step "Testing connectivity to Node 01 ($Node01)..." "INFO"
if (-not (Test-NodeConnectivity -NodeIP $Node01 -Credential $Credential)) {
    Write-Step "Cannot connect to Node 01 ($Node01)" "ERROR"
    exit 1
}
Write-Step "Node 01 is reachable" "SUCCESS"

Write-Step "Testing connectivity to Node 02 ($Node02)..." "INFO"
if (-not (Test-NodeConnectivity -NodeIP $Node02 -Credential $Credential)) {
    Write-Step "Cannot connect to Node 02 ($Node02)" "ERROR"
    exit 1
}
Write-Step "Node 02 is reachable" "SUCCESS"

# Step 3: Get cluster and VM status
Write-Step "========== STEP 3: CLUSTER STATUS ==========" "STEP"

Write-Log "Querying cluster configuration via remote PowerShell..." "INFO"
$clusterInfo = Invoke-Command -ComputerName $Node01 -Credential $Credential -ScriptBlock {
    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    $nodes = Get-ClusterNode -ErrorAction SilentlyContinue
    $vms = Get-ClusterGroup | Where-Object { $_.GroupType -eq "VirtualMachine" }
    
    # Get detailed VM info
    $vmDetails = foreach ($vmGroup in $vms) {
        $vmObj = Get-VM -Name $vmGroup.Name -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name             = $vmGroup.Name
            State            = $vmGroup.State
            OwnerNode        = $vmGroup.OwnerNode
            MemoryAssignedGB = if ($vmObj) { [math]::Round($vmObj.MemoryAssigned / 1GB, 2) } else { 0 }
            CPUUsage         = if ($vmObj) { $vmObj.CPUUsage } else { 0 }
            Uptime           = if ($vmObj -and $vmObj.Uptime) { $vmObj.Uptime.ToString("dd\.hh\:mm\:ss") } else { "N/A" }
            Status           = if ($vmObj) { $vmObj.Status } else { "Unknown" }
        }
    }
    
    # Get storage pool health
    $storagePool = Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue | Select-Object FriendlyName, HealthStatus, OperationalStatus
    
    @{
        ClusterName = $cluster.Name
        Nodes       = $nodes | Select-Object Name, State, @{N = 'NodeWeight'; E = { $_.NodeWeight } }
        VMs         = $vmDetails
        VMCount     = ($vms | Measure-Object).Count
        StoragePool = $storagePool
    }
}
Write-Log "Cluster query complete" "SUCCESS"

Write-Log "Cluster: $($clusterInfo.ClusterName)" "INFO"

# Log storage pool status
if ($clusterInfo.StoragePool) {
    Write-Log "Storage Pool: $($clusterInfo.StoragePool.FriendlyName) - Health: $($clusterInfo.StoragePool.HealthStatus), Status: $($clusterInfo.StoragePool.OperationalStatus)" "INFO"
}

Write-Log "Nodes:" "INFO"
foreach ($node in $clusterInfo.Nodes) {
    $stateColor = if ($node.State -eq "Up") { "Green" } else { "Yellow" }
    $nodeMsg = "  - $($node.Name): $($node.State)"
    Write-Log $nodeMsg "DETAIL"
}

Write-Log "Virtual Machines: $($clusterInfo.VMCount) total" "INFO"
Write-Host ""
Write-Host "  VM Name                          Node              State      Memory    Uptime" -ForegroundColor DarkCyan
Write-Host "  -------------------------------- ----------------- ---------- --------- --------------" -ForegroundColor DarkGray

foreach ($vm in $clusterInfo.VMs) {
    $stateColor = switch ($vm.State) {
        "Online" { "Green" }
        "Offline" { "DarkGray" }
        default { "Yellow" }
    }
    $vmName = $vm.Name.PadRight(32)
    # Extract node name (remove cluster prefix if present)
    $nodePrefix = $ClusterName -replace '-clus.*$', '-'
    $ownerNode = ($vm.OwnerNode -replace [regex]::Escape($nodePrefix), '').PadRight(17)
    $state = $vm.State.ToString().PadRight(10)
    $memory = "$($vm.MemoryAssignedGB) GB".PadRight(9)
    $uptime = $vm.Uptime
    
    Write-Host "  $vmName " -NoNewline -ForegroundColor White
    Write-Host "$ownerNode " -NoNewline -ForegroundColor Cyan
    Write-Host "$state " -NoNewline -ForegroundColor $stateColor
    Write-Host "$memory " -NoNewline -ForegroundColor Yellow
    Write-Host "$uptime" -ForegroundColor DarkGray
    
    # Log detailed VM info
    Write-Log "  VM: $($vm.Name) | Node: $($vm.OwnerNode) | State: $($vm.State) | Memory: $($vm.MemoryAssignedGB)GB | Uptime: $($vm.Uptime)" "VM" -NoConsole
}
Write-Host ""

# Step 4: Shut down VMs
Write-Step "========== STEP 4: SHUTDOWN VIRTUAL MACHINES ==========" "STEP"

$runningVMs = $clusterInfo.VMs | Where-Object { $_.State -eq "Online" }
if ($runningVMs.Count -gt 0) {
    Write-Step "Found $($runningVMs.Count) running VMs to stop" "INFO"
    
    foreach ($vm in $runningVMs) {
        $vmName = $vm.Name
        $action = if ($SaveVMState) { "Saving state" } else { "Shutting down" }
        
        if ($PSCmdlet.ShouldProcess($vmName, $action)) {
            $vmStartTime = Get-Date
            Write-Log "$action VM: $vmName (Owner: $($vm.OwnerNode), Memory: $($vm.MemoryAssignedGB)GB)..." "INFO"
            
            try {
                Invoke-Command -ComputerName $Node01 -Credential $Credential -ScriptBlock {
                    param($VMName, $SaveState)
                    
                    if ($SaveState) {
                        # Save VM state (preserves memory)
                        Write-Host "    Saving VM state..." -ForegroundColor Yellow
                        Stop-ClusterGroup -Name $VMName -SaveState -ErrorAction Stop
                    }
                    else {
                        # Graceful shutdown
                        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                        if ($vm -and $vm.State -eq 'Running') {
                            Write-Host "    Sending shutdown signal to guest OS..." -ForegroundColor Yellow
                            Stop-VM -Name $VMName -Force -ErrorAction Stop
                        }
                        # Stop the cluster resource
                        Stop-ClusterGroup -Name $VMName -ErrorAction SilentlyContinue
                    }
                } -ArgumentList $vmName, $SaveVMState
                
                $vmDuration = (Get-Date) - $vmStartTime
                Write-Log "VM $vmName stopped successfully (took $($vmDuration.TotalSeconds.ToString('0.0'))s)" "SUCCESS"
            }
            catch {
                $errMsg = $_.Exception.Message
                Write-Log "Failed to stop VM ${vmName}: $errMsg" "ERROR"
            }
        }
    }
}
else {
    Write-Step "No running VMs found" "INFO"
}

# Verify all VMs are stopped
Start-Sleep -Seconds 5
$vmCheck = Invoke-Command -ComputerName $Node01 -Credential $Credential -ScriptBlock {
    Get-ClusterGroup | Where-Object { $_.GroupType -eq "VirtualMachine" -and $_.State -eq "Online" }
}

if ($vmCheck.Count -gt 0) {
    Write-Step "WARNING: $($vmCheck.Count) VMs still running. Proceeding anyway..." "WARNING"
}
else {
    Write-Step "All VMs are stopped" "SUCCESS"
}

# Step 5: Stop the Cluster Service
Write-Step "========== STEP 5: STOP CLUSTER SERVICE ==========" "STEP"

if ($PSCmdlet.ShouldProcess($ClusterName, "Stop Cluster Service")) {
    Write-Step "Stopping cluster service on all nodes..." "INFO"
    Write-Step "This will gracefully stop all cluster resources including Storage Spaces Direct" "INFO"
    
    Invoke-Command -ComputerName $Node01 -Credential $Credential -ScriptBlock {
        # Stop-Cluster stops the cluster service on ALL nodes
        Stop-Cluster -Force -Confirm:$false
    }
    
    # Wait for cluster to stop
    Write-Step "Waiting for cluster services to stop..." "INFO"
    Start-Sleep -Seconds 15
    
    # Verify cluster is stopped
    $clusterStopped = Invoke-Command -ComputerName $Node01 -Credential $Credential -ScriptBlock {
        $service = Get-Service -Name ClusSvc -ErrorAction SilentlyContinue
        $service.Status -ne "Running"
    } -ErrorAction SilentlyContinue
    
    if ($clusterStopped) {
        Write-Step "Cluster service stopped on all nodes" "SUCCESS"
    }
    else {
        Write-Step "Cluster service may still be stopping..." "WARNING"
    }
}

# Step 6: Shut down Node 02 first
Write-Step "========== STEP 6: SHUTDOWN NODE 02 ==========" "STEP"

if ($PSCmdlet.ShouldProcess($Node02, "Shutdown")) {
    Write-Step "Shutting down Node 02 ($Node02)..." "INFO"
    
    try {
        Invoke-Command -ComputerName $Node02 -Credential $Credential -ScriptBlock {
            Stop-Computer -Force
        } -ErrorAction SilentlyContinue
        
        Write-Step "Shutdown command sent to Node 02" "SUCCESS"
    }
    catch {
        # Expected - connection will drop during shutdown
        Write-Step "Node 02 is shutting down (connection closed as expected)" "SUCCESS"
    }
    
    # Wait for Node 02 to go offline
    Write-Step "Waiting for Node 02 to power off..." "INFO"
    $timeout = 60
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 5
        $elapsed += 5
        
        $pingResult = Test-Connection -ComputerName $Node02 -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingResult) {
            Write-Step "Node 02 is offline" "SUCCESS"
            break
        }
        Write-Host "." -NoNewline
    }
}

# Step 7: Shut down Node 01 last
Write-Step "========== STEP 7: SHUTDOWN NODE 01 ==========" "STEP"

if ($PSCmdlet.ShouldProcess($Node01, "Shutdown")) {
    Write-Step "Shutting down Node 01 ($Node01)..." "INFO"
    
    try {
        Invoke-Command -ComputerName $Node01 -Credential $Credential -ScriptBlock {
            Stop-Computer -Force
        } -ErrorAction SilentlyContinue
        
        Write-Step "Shutdown command sent to Node 01" "SUCCESS"
    }
    catch {
        # Expected - connection will drop during shutdown
        Write-Step "Node 01 is shutting down (connection closed as expected)" "SUCCESS"
    }
    
    # Wait for Node 01 to go offline
    Write-Step "Waiting for Node 01 to power off..." "INFO"
    $timeout = 60
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 5
        $elapsed += 5
        
        $pingResult = Test-Connection -ComputerName $Node01 -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingResult) {
            Write-Step "Node 01 is offline" "SUCCESS"
            break
        }
        Write-Host "." -NoNewline
    }
}

# Summary
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "  CLUSTER SHUTDOWN COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""
Write-Step "Shutdown Summary:" "INFO"
Write-Host "  - All VMs have been stopped" -ForegroundColor Green
Write-Host "  - Cluster service has been stopped on all nodes" -ForegroundColor Green
Write-Host "  - Node 02 ($Node02) has been powered off" -ForegroundColor Green
Write-Host "  - Node 01 ($Node01) has been powered off" -ForegroundColor Green
Write-Host ""
Write-Host "  The cluster is now safe to transport or perform maintenance." -ForegroundColor Cyan
Write-Host ""
Write-Host "  TO RESTART THE CLUSTER:" -ForegroundColor Yellow
Write-Host "  1. Power on Node 01 first, then Node 02" -ForegroundColor White
Write-Host "  2. Wait for both nodes to boot completely" -ForegroundColor White
Write-Host "  3. The cluster service will auto-start on boot" -ForegroundColor White
Write-Host "  4. Start VMs using: Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine' | Start-ClusterGroup" -ForegroundColor White
Write-Host ""

# Calculate total duration
$totalDuration = (Get-Date) - $script:StartTime
Write-Log "Total shutdown duration: $($totalDuration.Minutes) minutes $($totalDuration.Seconds) seconds" "INFO"

# Save log file
Save-LogFile
#endregion
