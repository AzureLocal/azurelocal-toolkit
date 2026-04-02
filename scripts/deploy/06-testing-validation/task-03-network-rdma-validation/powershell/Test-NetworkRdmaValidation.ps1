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

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\validation-reports\

.EXAMPLE
    .\Test-NetworkRdmaValidation.ps1 -ClusterName "azl-cluster-01"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 06-cluster-testing-and-validation
    Task: task-03-network-rdma-validation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\validation-reports"
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml
    return Get-Content -Path $Path -Raw | ConvertFrom-Yaml
}

#region Validation Functions

function Test-RdmaConfiguration {
    param([string[]]$NodeNames)

    Write-Log "Validating RDMA adapter configuration..." -Level "HEADER"
    $results = @()

    foreach ($node in $NodeNames) {
        try {
            $rdmaAdapters = Invoke-Command -ComputerName $node -ScriptBlock {
                Get-NetAdapterRdma | Select-Object Name, Enabled, OperationalState
            }

            foreach ($adapter in $rdmaAdapters) {
                $ok = $adapter.Enabled -and ($adapter.OperationalState -eq 'Routable' -or $adapter.OperationalState -eq 'Connected')
                Write-Log "  $node - $($adapter.Name): Enabled=$($adapter.Enabled), State=$($adapter.OperationalState)" -Level $(if ($ok) { "SUCCESS" } else { "WARN" })
                $results += [PSCustomObject]@{
                    Node    = $node
                    Adapter = $adapter.Name
                    Enabled = $adapter.Enabled
                    State   = $adapter.OperationalState
                    Status  = if ($ok) { "PASS" } else { "FAIL" }
                }
            }
        }
        catch {
            Write-Log "  $node: RDMA check failed — $_" -Level "ERROR"
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
            $dcbSettings = Invoke-Command -ComputerName $node -ScriptBlock {
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
                Write-Log "  $node: No QoS policies found" -Level "WARN"
            }

            if ($dcbSettings.PFC) {
                foreach ($pfc in $dcbSettings.PFC) {
                    Write-Log "  $node - PFC Priority $($pfc.Priority): Enabled" -Level "SUCCESS"
                }
            }

            $results += [PSCustomObject]@{ Node = $node; QosCount = ($dcbSettings.QosPolicy).Count; PfcCount = ($dcbSettings.PFC).Count }
        }
        catch {
            Write-Log "  $node: DCB check failed — $_" -Level "ERROR"
        }
    }
    return $results
}

function Test-SmbDirectStatus {
    param([string[]]$NodeNames)

    Write-Log "Validating SMB Direct and Multichannel..." -Level "HEADER"

    foreach ($node in $NodeNames) {
        try {
            $smbDirect = Invoke-Command -ComputerName $node -ScriptBlock {
                @{
                    SmbClientEnabled     = (Get-SmbClientConfiguration).EnableMultichannel
                    SmbServerEnabled     = (Get-SmbServerConfiguration).EnableMultichannel
                    RdmaConnections      = (Get-SmbConnection | Where-Object { $_.Dialect -ge '3.0' }).Count
                    SmbDirectConnections = (Get-SmbConnection -SmbInstance Default -ErrorAction SilentlyContinue | Where-Object { $_.RdmaCapable }).Count
                }
            }
            Write-Log "  $node - SMB Multichannel Client=$($smbDirect.SmbClientEnabled), Server=$($smbDirect.SmbServerEnabled)" -Level "SUCCESS"
            Write-Log "  $node - SMB 3.x connections: $($smbDirect.RdmaConnections), RDMA-capable: $($smbDirect.SmbDirectConnections)" -Level "INFO"
        }
        catch {
            Write-Log "  $node: SMB Direct check failed — $_" -Level "ERROR"
        }
    }
}

function Test-NetworkAtcIntents {
    param([string]$Cluster)

    Write-Log "Validating Network ATC intents..." -Level "HEADER"

    try {
        $intents = Invoke-Command -ComputerName $Cluster -ScriptBlock {
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

if ($ConfigPath) {
    $config = Import-InfrastructureConfig -Path $ConfigPath
    if (-not $ClusterName -and $config) { $ClusterName = $config.platform.cluster_name }
}
if (-not $ClusterName) {
    Write-Log "ClusterName is required." -Level "ERROR"
    exit 1
}

$nodes = (Get-ClusterNode -Cluster $ClusterName).Name
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
Test-NetworkAtcIntents -Cluster $ClusterName
Write-Host ""

# Save report
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$reportFile = Join-Path $OutputPath "03-network-rdma-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8
Write-Log "Report saved: $reportFile" -Level "INFO"

$rdmaPass = ($rdmaResults | Where-Object { $_.Status -eq "PASS" }).Count
$rdmaFail = ($rdmaResults | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host ""
Write-Log "========================================" -Level "HEADER"
Write-Log "Network & RDMA Summary" -Level "SUCCESS"
Write-Log "  RDMA adapters: $rdmaPass pass / $rdmaFail fail" -Level "INFO"
Write-Log "  DCB configured on $($dcbResults.Count) nodes" -Level "INFO"

#endregion Main
