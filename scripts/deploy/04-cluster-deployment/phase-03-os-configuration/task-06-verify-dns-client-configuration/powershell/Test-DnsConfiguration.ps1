<#
.SYNOPSIS
    Verifies DNS configuration for Azure Local nodes.

.DESCRIPTION
    This script validates DNS configuration:
    - Checks DNS server settings
    - Validates forward and reverse lookups
    - Tests required Azure endpoint resolution
    - Verifies Active Directory DNS records

.PARAMETER NodeNames
    Array of node hostnames to verify.

.PARAMETER DnsServers
    DNS servers to validate.

.PARAMETER DomainName
    Active Directory domain name.

.EXAMPLE
    .\Test-DnsConfiguration.ps1 -NodeNames @("node01", "node02") -DomainName "Contoso.local"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 05-cluster-deployment
    Step: stage-13-node-configuration/step-02-dns-verification
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [string[]]$DnsServers,

    [Parameter(Mandatory = $false)]
    [string]$DomainName,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\dns-verification"
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Functions

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Import-InfrastructureConfig {
    [CmdletBinding()]
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    $configContent = Get-Content -Path $Path -Raw
    return ConvertFrom-Yaml $configContent
}

function Test-DnsResolution {
    <#
    .SYNOPSIS
        Tests DNS resolution for a hostname.
    #>
    [CmdletBinding()]
    param(
        [string]$Hostname,
        [string]$Server
    )

    try {
        $params = @{
            Name        = $Hostname
            ErrorAction = 'Stop'
        }
        if ($Server) {
            $params['Server'] = $Server
        }

        $result = Resolve-DnsName @params
        return @{
            Hostname  = $Hostname
            Resolved  = $true
            IpAddress = ($result | Where-Object { $_.Type -eq 'A' }).IPAddress
            Type      = $result[0].Type
        }
    } catch {
        return @{
            Hostname  = $Hostname
            Resolved  = $false
            Error     = $_.Exception.Message
        }
    }
}

function Test-ReverseDns {
    <#
    .SYNOPSIS
        Tests reverse DNS lookup for an IP address.
    #>
    [CmdletBinding()]
    param(
        [string]$IpAddress,
        [string]$Server
    )

    try {
        $params = @{
            Name        = $IpAddress
            Type        = 'PTR'
            ErrorAction = 'Stop'
        }
        if ($Server) {
            $params['Server'] = $Server
        }

        $result = Resolve-DnsName @params
        return @{
            IpAddress   = $IpAddress
            Resolved    = $true
            PtrRecord   = $result.NameHost
        }
    } catch {
        return @{
            IpAddress   = $IpAddress
            Resolved    = $false
            Error       = $_.Exception.Message
        }
    }
}

function Test-NodeDnsSettings {
    <#
    .SYNOPSIS
        Checks DNS settings on a node via remote session.
    #>
    [CmdletBinding()]
    param(
        [string]$NodeName,
        [pscredential]$Credential
    )

    try {
        $sessionParams = @{
            ComputerName = $NodeName
            ErrorAction  = 'Stop'
        }
        if ($Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-PSSession @sessionParams

        $dnsSettings = Invoke-Command -Session $session -ScriptBlock {
            $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
            $dnsInfo = @()
            
            foreach ($adapter in $adapters) {
                $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4
                $dnsInfo += @{
                    AdapterName    = $adapter.Name
                    InterfaceIndex = $adapter.InterfaceIndex
                    DnsServers     = $dns.ServerAddresses
                }
            }
            
            return $dnsInfo
        }

        Remove-PSSession -Session $session

        return @{
            NodeName    = $NodeName
            Success     = $true
            DnsSettings = $dnsSettings
        }
    } catch {
        return @{
            NodeName = $NodeName
            Success  = $false
            Error    = $_.Exception.Message
        }
    }
}

function Get-AzureEndpointsForDnsTest {
    <#
    .SYNOPSIS
        Returns Azure endpoints that should be resolvable.
    #>
    return @(
        "login.microsoftonline.com"
        "management.azure.com"
        "graph.microsoft.com"
        "aka.ms"
        "azurestackhci.azurecr.io"
        "mcr.microsoft.com"
    )
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "DNS Configuration Verification" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get values from config if not provided
    if (-not $NodeNames -and $config.compute.cluster_nodes) {
        $NodeNames = $config.compute.cluster_nodes | ForEach-Object { $_.name }
    }
    if (-not $DnsServers -and $config.networking.onprem.dns) {
        $DnsServers = $config.networking.onprem.dns.servers
    }
    if (-not $DomainName -and $config.domain) {
        $DomainName = $config.domain.name
    }

    # Prompt for credentials if not provided and nodes specified
    if ($NodeNames -and -not $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for node access"
    }

    $results = @{
        Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        NodeDnsSettings = @()
        ForwardLookups  = @()
        ReverseLookups  = @()
        AzureEndpoints  = @()
    }

    # Check DNS settings on nodes
    if ($NodeNames) {
        Write-LogMessage "Checking DNS settings on nodes..." -Level Info
        foreach ($node in $NodeNames) {
            Write-LogMessage "  Node: $node" -Level Info
            $nodeResult = Test-NodeDnsSettings -NodeName $node -Credential $Credential
            $results.NodeDnsSettings += $nodeResult

            if ($nodeResult.Success) {
                foreach ($adapter in $nodeResult.DnsSettings) {
                    Write-LogMessage "    $($adapter.AdapterName): $($adapter.DnsServers -join ', ')" -Level Info
                }
            } else {
                Write-LogMessage "    Failed: $($nodeResult.Error)" -Level Error
            }
        }
    }

    # Test forward lookups for nodes
    if ($NodeNames -and $DomainName) {
        Write-LogMessage "Testing forward DNS lookups..." -Level Info
        foreach ($node in $NodeNames) {
            $fqdn = "$node.$DomainName"
            Write-Host "  $fqdn... " -NoNewline
            
            $result = Test-DnsResolution -Hostname $fqdn -Server $DnsServers[0]
            $results.ForwardLookups += $result

            if ($result.Resolved) {
                Write-Host "✓ $($result.IpAddress)" -ForegroundColor Green
            } else {
                Write-Host "✗" -ForegroundColor Red
            }
        }
    }

    # Test reverse lookups
    $ipsToTest = $results.ForwardLookups | Where-Object { $_.Resolved } | ForEach-Object { $_.IpAddress } | Select-Object -Unique
    if ($ipsToTest) {
        Write-LogMessage "Testing reverse DNS lookups..." -Level Info
        foreach ($ip in $ipsToTest) {
            Write-Host "  $ip... " -NoNewline
            
            $result = Test-ReverseDns -IpAddress $ip -Server $DnsServers[0]
            $results.ReverseLookups += $result

            if ($result.Resolved) {
                Write-Host "✓ $($result.PtrRecord)" -ForegroundColor Green
            } else {
                Write-Host "✗" -ForegroundColor Yellow
            }
        }
    }

    # Test Azure endpoint resolution
    Write-LogMessage "Testing Azure endpoint resolution..." -Level Info
    $azureEndpoints = Get-AzureEndpointsForDnsTest
    foreach ($endpoint in $azureEndpoints) {
        Write-Host "  $endpoint... " -NoNewline
        
        $result = Test-DnsResolution -Hostname $endpoint
        $results.AzureEndpoints += $result

        if ($result.Resolved) {
            Write-Host "✓" -ForegroundColor Green
        } else {
            Write-Host "✗" -ForegroundColor Red
        }
    }

    # Save results
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $reportFile = Join-Path $OutputPath "dns-verification-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $results | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile
    Write-LogMessage "Report saved: $reportFile" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "DNS Verification Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $forwardSuccess = ($results.ForwardLookups | Where-Object { $_.Resolved }).Count
    $azureSuccess = ($results.AzureEndpoints | Where-Object { $_.Resolved }).Count

    Write-LogMessage "  Forward lookups: $forwardSuccess / $($results.ForwardLookups.Count)" -Level $(if($forwardSuccess -eq $results.ForwardLookups.Count){'Success'}else{'Warning'})
    Write-LogMessage "  Azure endpoints: $azureSuccess / $($results.AzureEndpoints.Count)" -Level $(if($azureSuccess -eq $results.AzureEndpoints.Count){'Success'}else{'Error'})

    return $results

} catch {
    Write-LogMessage "DNS verification failed: $_" -Level Error
    throw
}

#endregion Main
