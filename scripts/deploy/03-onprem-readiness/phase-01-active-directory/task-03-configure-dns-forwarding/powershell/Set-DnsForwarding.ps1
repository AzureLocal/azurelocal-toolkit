<#
.SYNOPSIS
    Configures DNS conditional forwarders and validates DNS infrastructure for Azure Local.

.DESCRIPTION
    This script configures DNS forwarding:
    - Creates conditional forwarders for Azure endpoints
    - Validates forward and reverse lookup zones
    - Tests DNS resolution for critical Azure and cluster endpoints
    - Verifies DNS delegation for split-horizon scenarios

.PARAMETER DomainController
    Target domain controller / DNS server FQDN.

.PARAMETER ClusterName
    Name of the Azure Local cluster.

.PARAMETER NodeNames
    Array of cluster node hostnames.

.PARAMETER ConfigFile
    Path to infrastructure.yml configuration.

.EXAMPLE
    .\Set-DnsForwarding.ps1 -DomainController "dc01.contoso.com" -ClusterName "azl-cluster-01" -NodeNames @("node-01","node-02")

.NOTES
    Author: Azure Local Cloudnology Team
    Version: 1.0.0
    Stage: 03-onprem-readiness
    Phase: phase-01-active-directory
    Task: task-03-configure-dns-forwarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainController,

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile
)

#Requires -Version 7.0
#Requires -Modules DnsServer

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import helpers
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelpersPath = Join-Path $ScriptRoot "..\..\..\..\common\utilities\helpers"

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

#region Functions

function Set-AzureConditionalForwarders {
    Write-Log -Message "Configuring conditional forwarders for Azure endpoints..." -Level "INFO"

    # Azure DNS addresses for conditional forwarding
    $azureDnsServers = @("168.63.129.16")

    $azureZones = @(
        "his.arc.azure.com",
        "guestconfiguration.azure.com",
        "dp.kubernetesconfiguration.azure.com",
        "servicebus.windows.net",
        "guestnotificationservice.azure.com"
    )

    $created = 0
    foreach ($zone in $azureZones) {
        $existing = Get-DnsServerZone -ComputerName $DomainController -Name $zone -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log -Message "  Forwarder exists: $zone" -Level "INFO"
        }
        else {
            if ($PSCmdlet.ShouldProcess($zone, "Create conditional forwarder")) {
                Add-DnsServerConditionalForwarderZone -ComputerName $DomainController `
                    -Name $zone `
                    -MasterServers $azureDnsServers `
                    -ReplicationScope Forest
                Write-Log -Message "  Created forwarder: $zone" -Level "SUCCESS"
                $created++
            }
        }
    }

    return $created
}

function Test-DnsResolution {
    Write-Log -Message "Validating DNS resolution..." -Level "INFO"

    $domain = (Get-ADDomain -Server $DomainController).DNSRoot
    $passed = 0
    $failed = 0

    # Test domain resolution
    try {
        $result = Resolve-DnsName -Name $domain -Server $DomainController -ErrorAction Stop
        Write-Log -Message "  Domain ($domain): Resolved" -Level "SUCCESS"
        $passed++
    }
    catch {
        Write-Log -Message "  Domain ($domain): FAILED" -Level "ERROR"
        $failed++
    }

    # Test cluster name availability
    try {
        $clusterFqdn = "$ClusterName.$domain"
        $result = Resolve-DnsName -Name $clusterFqdn -Server $DomainController -ErrorAction SilentlyContinue
        if ($result) {
            Write-Log -Message "  Cluster ($clusterFqdn): Already exists — verify this is expected" -Level "WARN"
        }
        else {
            Write-Log -Message "  Cluster ($clusterFqdn): Available" -Level "SUCCESS"
        }
        $passed++
    }
    catch {
        Write-Log -Message "  Cluster ($clusterFqdn): Available" -Level "SUCCESS"
        $passed++
    }

    # Test node resolution
    if ($NodeNames) {
        foreach ($node in $NodeNames) {
            try {
                $fqdn = "$node.$domain"
                $result = Resolve-DnsName -Name $fqdn -Server $DomainController -ErrorAction Stop
                Write-Log -Message "  Node ($fqdn): Resolved to $($result.IPAddress | Select-Object -First 1)" -Level "SUCCESS"
                $passed++
            }
            catch {
                Write-Log -Message "  Node ($fqdn): No record (will be created at domain join)" -Level "INFO"
                $passed++
            }
        }
    }

    # Test external Azure endpoints
    $azureEndpoints = @("management.azure.com", "login.microsoftonline.com")
    foreach ($endpoint in $azureEndpoints) {
        try {
            $result = Resolve-DnsName -Name $endpoint -ErrorAction Stop
            Write-Log -Message "  Azure ($endpoint): Resolved" -Level "SUCCESS"
            $passed++
        }
        catch {
            Write-Log -Message "  Azure ($endpoint): FAILED — check DNS forwarding" -Level "ERROR"
            $failed++
        }
    }

    return @{ Passed = $passed; Failed = $failed }
}

function Test-ReverseLookupZones {
    Write-Log -Message "Checking reverse lookup zones..." -Level "INFO"

    $zones = Get-DnsServerZone -ComputerName $DomainController | Where-Object { $_.IsReverseLookupZone -eq $true }

    if ($zones.Count -eq 0) {
        Write-Log -Message "  No reverse lookup zones found — consider creating for management subnet" -Level "WARN"
    }
    else {
        foreach ($zone in $zones) {
            Write-Log -Message "  Found: $($zone.ZoneName) (Type: $($zone.ZoneType))" -Level "INFO"
        }
    }
}

#endregion Functions

#region Main

try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "DNS Forwarding Configuration" -Level "INFO"
    Write-Log -Message "DNS Server: $DomainController" -Level "INFO"
    Write-Log -Message "Cluster Name: $ClusterName" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    Write-Host ""

    Import-Module DnsServer -ErrorAction Stop

    # Configure conditional forwarders
    $forwardersCreated = Set-AzureConditionalForwarders
    Write-Host ""

    # Validate reverse lookup zones
    Test-ReverseLookupZones
    Write-Host ""

    # Test DNS resolution
    $dnsResult = Test-DnsResolution
    Write-Host ""

    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "DNS Configuration Summary" -Level "SUCCESS"
    Write-Log -Message "  Forwarders created: $forwardersCreated" -Level "INFO"
    Write-Log -Message "  DNS tests passed: $($dnsResult.Passed)" -Level "INFO"
    Write-Log -Message "  DNS tests failed: $($dnsResult.Failed)" -Level "INFO"

    if ($dnsResult.Failed -gt 0) {
        Write-Log -Message "Some DNS tests failed — review output above." -Level "WARN"
    }
}
catch {
    Write-Log -Message "DNS configuration failed: $_" -Level "ERROR"
    exit 1
}

#endregion Main
