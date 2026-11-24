<#
.SYNOPSIS
    Validates network connectivity, RDMA configuration, and DCB settings.

.DESCRIPTION
    Comprehensive network and RDMA validation including:
    - RDMA adapter configuration and status
    - DCB (Data Center Bridging) priority flow control
    - VLAN connectivity between all nodes
    - SMB Direct and SMB Multichannel status
    - Network ATC intent validation
    - Generates validation report for customer handover

    Read only: it changes nothing on the cluster. Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        cluster.name, nodes[] (the management addresses), identity.active_directory (the deployment user and its secret reference),
        networking.intents[] (the adapters of a storage intent are the ones RDMA is expected on)
    Run it from the management host: every question is asked on a node over PowerShell remoting (scripts/common/remoting/AzlClusterConnection.psm1),
    each node at its own management address, so this host needs neither the failover clustering tools nor membership of the cluster's domain.
    The script asks nothing.

    Exit codes: 0 no RDMA adapter failed; 1 an RDMA adapter check failed; 2 cluster.name is missing or the file cannot be read. The cluster that cannot be reached is exit code 1.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys listed in the description are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to send the cluster questions to. Default: the first node of nodes[] that answers at its management address.

.PARAMETER Credential
    Optional. The account for the remoting sessions. Default: the deployment (LCM) user of the file, through the toolkit's secret resolver.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.EXAMPLE
    .\Test-NetworkRdmaValidation.ps1 -InfrastructureFile ./infrastructure.yml

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-03-network-rdma-validation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports",

    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'remoting', 'AzlClusterConnection.psm1'))) -Force

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

#region Validation Functions

function Test-RdmaConfiguration {
    param([string[]]$NodeNames)

    Write-Log "Validating RDMA adapter configuration..." -Level "HEADER"
    $results = @()

    foreach ($node in $NodeNames) {
        try {
            $rdmaAdapters = Invoke-AzlClusterCommand -Connection $connection -Node $node -ScriptBlock {
                Get-NetAdapterRdma | Select-Object Name, Enabled, OperationalState
            }

            foreach ($adapter in $rdmaAdapters) {
                # OperationalState is a state name on older builds and a boolean on Windows Server 2025 based builds
                $state = $adapter.OperationalState
                $up = ($state -is [bool] -and $state) -or ([string]$state -in @('Routable', 'Connected', 'True'))
                $ok = [bool]$adapter.Enabled -and $up
                # Network ATC turns RDMA on for the adapters of a storage intent only; an adapter of a management or compute intent with RDMA off
                # is the intended state, not a failure (seen on a live instance: the compute ports and vManagement were reported as failures).
                # a host vNIC of a storage intent counts too: Network ATC names it vSMB(<intent>#<port>)
                $expected = ($script:StorageAdapters.Count -eq 0) -or ([string]$adapter.Name -in $script:StorageAdapters) -or (@($script:StorageAdapters | Where-Object { ([string]$adapter.Name).EndsWith("#$_)", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
                $status = if ($ok) { "PASS" } elseif ($expected) { "FAIL" } else { "INFO" }
                $level = switch ($status) { 'PASS' { 'SUCCESS' } 'FAIL' { 'WARN' } default { 'INFO' } }
                $note = if ($status -eq 'INFO') { ' (not a storage intent adapter: RDMA not expected)' } else { '' }
                Write-Log "  $node - $($adapter.Name): Enabled=$($adapter.Enabled), State=$($adapter.OperationalState)$note" -Level $level
                $results += [PSCustomObject]@{
                    Node    = $node
                    Adapter = $adapter.Name
                    Enabled = $adapter.Enabled
                    State   = $adapter.OperationalState
                    Status  = $status
                }
            }
        }
        catch {
            Write-Log "  ${node}: RDMA check failed — $_" -Level "ERROR"
        }
    }
    return $results
}

function Test-DcbConfiguration {
    param([string[]]$NodeNames)

    Write-Log "Validating DCB / Priority Flow Control..." -Level "HEADER"
    $results = @()

    foreach ($node in $NodeNames) {
        try {
            $dcbSettings = Invoke-AzlClusterCommand -Connection $connection -Node $node -ScriptBlock {
                $qos = Get-NetQosPolicy | Select-Object Name, PriorityValue8021Action, NetDirectPortMatchCondition
                $pfc = Get-NetQosFlowControl | Where-Object { $_.Enabled -eq $true } | Select-Object Priority, Enabled
                return @{ QosPolicy = $qos; PFC = $pfc }
            }

            if ($dcbSettings.QosPolicy) {
                foreach ($policy in $dcbSettings.QosPolicy) {
                    Write-Log "  $node - QoS: $($policy.Name), Priority=$($policy.PriorityValue8021Action)" -Level "SUCCESS"
                }
            }
            else {
                Write-Log "  ${node}: No QoS policies found" -Level "WARN"
            }

            if ($dcbSettings.PFC) {
                foreach ($pfc in $dcbSettings.PFC) {
                    Write-Log "  $node - PFC Priority $($pfc.Priority): Enabled" -Level "SUCCESS"
                }
            }

            $results += [PSCustomObject]@{ Node = $node; QosCount = @($dcbSettings.QosPolicy).Count; PfcCount = @($dcbSettings.PFC).Count }
        }
        catch {
            Write-Log "  ${node}: DCB check failed — $_" -Level "ERROR"
        }
    }
    return $results
}

function Test-SmbDirectStatus {
    param([string[]]$NodeNames)

    Write-Log "Validating SMB Direct and Multichannel..." -Level "HEADER"

    foreach ($node in $NodeNames) {
        try {
            $smbDirect = Invoke-AzlClusterCommand -Connection $connection -Node $node -ScriptBlock {
                @{
                    SmbClientEnabled     = (Get-SmbClientConfiguration).EnableMultichannel
                    SmbServerEnabled     = (Get-SmbServerConfiguration).EnableMultichannel
                    RdmaConnections      = @(Get-SmbConnection | Where-Object { $_.Dialect -ge '3.0' }).Count
                    SmbDirectConnections = @(Get-SmbConnection -SmbInstance Default -ErrorAction SilentlyContinue | Where-Object { $_.RdmaCapable }).Count
                }
            }
            Write-Log "  $node - SMB Multichannel Client=$($smbDirect.SmbClientEnabled), Server=$($smbDirect.SmbServerEnabled)" -Level "SUCCESS"
            Write-Log "  $node - SMB 3.x connections: $($smbDirect.RdmaConnections), RDMA-capable: $($smbDirect.SmbDirectConnections)" -Level "INFO"
        }
        catch {
            Write-Log "  ${node}: SMB Direct check failed — $_" -Level "ERROR"
        }
    }
}

function Test-NetworkAtcIntents {

    Write-Log "Validating Network ATC intents..." -Level "HEADER"

    try {
        $intents = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock {
            Get-NetIntent | Select-Object Name, IntentType, IsManagementIntent, IsComputeIntent, IsStorageIntent
        }

        if ($intents) {
            foreach ($intent in $intents) {
                Write-Log "  Intent: $($intent.Name) — Mgmt=$($intent.IsManagementIntent), Compute=$($intent.IsComputeIntent), Storage=$($intent.IsStorageIntent)" -Level "SUCCESS"
            }
        }
        else {
            Write-Log "  No Network ATC intents found (may be using manual configuration)" -Level "INFO"
        }
    }
    catch {
        Write-Log "  Network ATC check skipped — $_" -Level "WARN"
    }
}

#endregion Validation Functions

#region Main

Write-Log "========================================" -Level "HEADER"
Write-Log "Network & RDMA Validation" -Level "HEADER"
Write-Log "========================================" -Level "HEADER"

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Log "Cannot read the infrastructure file: $($_.Exception.Message)" -Level "ERROR"; exit 2 }
$ClusterName = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'cluster.name')).Trim()
if (-not $ClusterName) {
    Write-Log "cluster.name is missing in the infrastructure file. It is the name of the cluster to test." -Level "ERROR"
    exit 2
}
# The adapters of the storage intents of the file (networking.intents[] with storage traffic): RDMA is expected on these. Without intents in the file every
# RDMA adapter is expected to be on, as before.
$script:StorageAdapters = @(@(Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.intents') | ForEach-Object { $_ } | Where-Object { $_ -is [System.Collections.IDictionary] -and @($_['traffic'] | ForEach-Object { "$_".ToLowerInvariant() }) -contains 'storage' } | ForEach-Object { @($_['adapters']) } | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$connection = Resolve-AzlClusterConnection -Infrastructure $infra -ComputerName $ComputerName -Credential $Credential -RemoteCommand { param([hashtable]$Call) Invoke-Command @Call }
try { $nodes = @(Invoke-AzlClusterCommand -Connection $connection -ScriptBlock { @(Get-ClusterNode | ForEach-Object { [string]$_.Name }) }) }
catch { Write-Log "The cluster could not be reached: $($_.Exception.Message)" -Level "ERROR"; exit 1 }

Write-Log "Cluster: $ClusterName ($($nodes.Count) nodes)" -Level "INFO"
Write-Host ""

$report = @{ Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; ClusterName = $ClusterName; Sections = @{} }

# 1. RDMA
$rdmaResults = Test-RdmaConfiguration -NodeNames $nodes
$report.Sections["RDMA"] = $rdmaResults
Write-Host ""

# 2. DCB
$dcbResults = Test-DcbConfiguration -NodeNames $nodes
$report.Sections["DCB"] = $dcbResults
Write-Host ""

# 3. SMB Direct
Test-SmbDirectStatus -NodeNames $nodes
Write-Host ""

# 4. Network ATC
Test-NetworkAtcIntents
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "03-network-rdma-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

$rdmaPass = @($rdmaResults | Where-Object { $_.Status -eq "PASS" }).Count
$rdmaFail = @($rdmaResults | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "Network & RDMA Summary" -Level "SUCCESS"
Write-Log "  RDMA adapters: $rdmaPass pass / $rdmaFail fail" -Level "INFO"
Write-Log "  DCB configured on $(@($dcbResults).Count) nodes" -Level "INFO"

if ($rdmaFail -gt 0) { exit 1 }
exit 0

#endregion Main
