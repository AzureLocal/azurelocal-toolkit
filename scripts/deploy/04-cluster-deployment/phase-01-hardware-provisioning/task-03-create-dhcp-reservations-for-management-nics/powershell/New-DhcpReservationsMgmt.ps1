<#
.SYNOPSIS
    Creates DHCP reservations for cluster node management NIC interfaces.

.DESCRIPTION
    This script creates DHCP reservations for management NICs:
    - Reads node management NIC MAC addresses and desired IPs from infrastructure.yml
    - Creates DHCP reservations on the target DHCP server
    - Validates reservation creation
    - Used for initial OS deployment before static IPs are configured

.PARAMETER DhcpServer
    DHCP server hostname or IP address.

.PARAMETER ScopeName
    DHCP scope name for management NIC reservations.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.EXAMPLE
    .\New-DhcpReservationsMgmt.ps1 -DhcpServer "dhcp01.contoso.com" -ScopeName "MGMT-Network"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 04-cluster-deployment
    Phase: phase-01-hardware-provisioning
    Task: task-03-create-dhcp-reservations-for-management-nics
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DhcpServer,

    [Parameter(Mandatory = $false)]
    [string]$ScopeName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
)

#Requires -Version 7.0
#Requires -Modules DhcpServer

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

function Resolve-ConfigPath {
    param([string]$ExplicitPath)
    if ($ExplicitPath -and (Test-Path $ExplicitPath)) { return $ExplicitPath }
    $candidates = Get-ChildItem -Path ".\configs\" -Filter "infrastructure*.yml" -ErrorAction SilentlyContinue | Sort-Object Name
    if ($candidates.Count -ge 1) { return $candidates[0].FullName }
    throw "No infrastructure*.yml found. Specify -ConfigPath."
}

function Import-InfrastructureConfig {
    param([string]$Path)
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml
    return Get-Content -Path $Path -Raw | ConvertFrom-Yaml
}

#region Main

Write-Log "=== Create DHCP Reservations for Management NICs ===" -Level "HEADER"

$configFile = Resolve-ConfigPath -ExplicitPath $ConfigPath
$config = Import-InfrastructureConfig -Path $configFile

$nodes = $config.compute.nodes
if (-not $nodes -or $nodes.Count -eq 0) {
    Write-Log "No nodes found in configuration." -Level "ERROR"
    exit 1
}

if (-not $DhcpServer) {
    $DhcpServer = $config.networking.dhcp.server
}
if (-not $DhcpServer) {
    Write-Log "DHCP server not specified and not found in config." -Level "ERROR"
    exit 1
}

$scopes = Get-DhcpServerv4Scope -ComputerName $DhcpServer
if ($ScopeName) {
    $targetScope = $scopes | Where-Object { $_.Name -eq $ScopeName }
}
else {
    $targetScope = $scopes | Where-Object { $_.Name -match 'mgmt|management' } | Select-Object -First 1
    if (-not $targetScope) { $targetScope = $scopes | Select-Object -First 1 }
}

if (-not $targetScope) {
    Write-Log "No matching DHCP scope found." -Level "ERROR"
    exit 1
}

Write-Log "DHCP Server: $DhcpServer" -Level "INFO"
Write-Log "Scope: $($targetScope.Name) ($($targetScope.ScopeId))" -Level "INFO"
Write-Host ""

$created = 0
$existing = 0

foreach ($node in $nodes) {
    $nodeName = $node.name
    $mgmtMac = $node.networking.management.mac_address
    $mgmtIp = $node.networking.management.ip_address

    if (-not $mgmtMac -or -not $mgmtIp) {
        Write-Log "  $nodeName : Missing management NIC MAC or IP in config — skipping" -Level "WARN"
        continue
    }

    $normalizedMac = $mgmtMac -replace '[:\.]', '-'

    $existingReservation = Get-DhcpServerv4Reservation -ComputerName $DhcpServer -ScopeId $targetScope.ScopeId -ErrorAction SilentlyContinue |
        Where-Object { $_.ClientId -eq $normalizedMac }

    if ($existingReservation) {
        Write-Log "  $nodeName : Reservation exists ($mgmtIp)" -Level "INFO"
        $existing++
    }
    else {
        if ($PSCmdlet.ShouldProcess("$nodeName MGMT NIC ($mgmtIp)", "Create DHCP reservation")) {
            Add-DhcpServerv4Reservation -ComputerName $DhcpServer `
                -ScopeId $targetScope.ScopeId `
                -IPAddress $mgmtIp `
                -ClientId $normalizedMac `
                -Name "$nodeName-MGMT" `
                -Description "Management NIC for $nodeName"
            Write-Log "  $nodeName : Created reservation ($mgmtIp -> $normalizedMac)" -Level "SUCCESS"
            $created++
        }
    }
}

Write-Host ""
Write-Log "=== Management NIC DHCP Reservation Summary ===" -Level "HEADER"
Write-Log "  Total nodes: $($nodes.Count)" -Level "INFO"
Write-Log "  Created: $created" -Level "INFO"
Write-Log "  Already existed: $existing" -Level "INFO"

#endregion Main
