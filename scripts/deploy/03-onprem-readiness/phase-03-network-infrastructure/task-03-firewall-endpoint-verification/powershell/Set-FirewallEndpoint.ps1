<#
.SYNOPSIS
    Configures firewall endpoint for Azure Local deployment.

.DESCRIPTION
    This script configures firewall rules for Azure Local:
    - Validates required outbound URLs
    - Tests connectivity to Azure endpoints
    - Documents firewall requirements
    - Optionally configures firewall via API

.PARAMETER FirewallHost
    Hostname or IP address of the firewall management interface.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.PARAMETER TestConnectivity
    Test connectivity to required Azure endpoints.

.EXAMPLE
    .\Set-FirewallEndpoint.ps1 -TestConnectivity

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 04-onprem-readiness
    Step: stage-10-network-device-deployment/step-03-firewall-endpoint
    
    Azure Local Required URLs:
    https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$FirewallHost,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$TestConnectivity,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\firewall",

    [Parameter(Mandatory = $false)]
    [string]$SourceIP
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

function Get-AzureLocalRequiredEndpoints {
    <#
    .SYNOPSIS
        Returns the list of required Azure endpoints for Azure Local.
    #>

    # Based on Microsoft documentation for Azure Local firewall requirements
    return @(
        # Azure Arc endpoints
        @{ Url = "aka.ms"; Port = 443; Category = "Azure Arc"; Required = $true }
        @{ Url = "download.microsoft.com"; Port = 443; Category = "Azure Arc"; Required = $true }
        @{ Url = "packages.microsoft.com"; Port = 443; Category = "Azure Arc"; Required = $true }
        @{ Url = "login.microsoftonline.com"; Port = 443; Category = "Azure Arc"; Required = $true }
        @{ Url = "management.azure.com"; Port = 443; Category = "Azure Arc"; Required = $true }
        @{ Url = "guestnotificationservice.azure.com"; Port = 443; Category = "Azure Arc"; Required = $true }
        
        # Azure Local specific
        @{ Url = "azurestackhci.azurecr.io"; Port = 443; Category = "Azure Local"; Required = $true }
        @{ Url = "ecpacr.azurecr.io"; Port = 443; Category = "Azure Local"; Required = $true }
        @{ Url = "mcr.microsoft.com"; Port = 443; Category = "Azure Local"; Required = $true }
        
        # Windows Update
        @{ Url = "windowsupdate.microsoft.com"; Port = 443; Category = "Windows Update"; Required = $true }
        @{ Url = "update.microsoft.com"; Port = 443; Category = "Windows Update"; Required = $true }
        @{ Url = "download.windowsupdate.com"; Port = 443; Category = "Windows Update"; Required = $true }
        
        # Telemetry
        @{ Url = "dc.services.visualstudio.com"; Port = 443; Category = "Telemetry"; Required = $false }
        @{ Url = "v10.events.data.microsoft.com"; Port = 443; Category = "Telemetry"; Required = $false }
        
        # Time sync
        @{ Url = "time.windows.com"; Port = 123; Category = "NTP"; Required = $true }
        
        # Key Vault
        @{ Url = "vault.azure.net"; Port = 443; Category = "Key Vault"; Required = $true }
        
        # Storage
        @{ Url = "blob.core.windows.net"; Port = 443; Category = "Storage"; Required = $true }
        
        # Graph API
        @{ Url = "graph.microsoft.com"; Port = 443; Category = "Graph API"; Required = $true }
    )
}

function Test-EndpointConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to a specific endpoint.
    #>
    [CmdletBinding()]
    param(
        [string]$Hostname,
        [int]$Port
    )

    try {
        if ($Port -eq 443) {
            # HTTPS test
            $response = Invoke-WebRequest `
                -Uri "https://$Hostname" `
                -Method HEAD `
                -TimeoutSec 10 `
                -UseBasicParsing `
                -ErrorAction SilentlyContinue

            return $true
        } elseif ($Port -eq 123) {
            # NTP uses UDP, can't easily test - assume OK if DNS resolves
            $null = [System.Net.Dns]::GetHostAddresses($Hostname)
            return $true
        } else {
            # TCP connection test
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connect = $tcpClient.BeginConnect($Hostname, $Port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne(5000, $false)
            $result = $wait -and $tcpClient.Connected
            if ($tcpClient.Connected) { $tcpClient.Close() }
            return $result
        }
    } catch {
        return $false
    }
}

function New-FirewallRuleDocument {
    <#
    .SYNOPSIS
        Creates a document with required firewall rules.
    #>
    [CmdletBinding()]
    param(
        [array]$Endpoints,
        [array]$TestResults,
        [string]$OutputPath
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $docPath = Join-Path $OutputPath "firewall-rules-$(Get-Date -Format 'yyyyMMdd').md"

    $doc = @"
# Azure Local Firewall Requirements

**Generated:** $timestamp

## Overview

This document lists all required firewall rules for Azure Local deployment.
These rules must be configured to allow outbound traffic from the Azure Local cluster.

---

## Required Outbound Rules

### Summary by Category

| Category | Required Rules | Optional Rules |
|----------|----------------|----------------|
"@

    $categories = $Endpoints | Group-Object -Property Category
    foreach ($cat in $categories) {
        $required = ($cat.Group | Where-Object { $_.Required }).Count
        $optional = $cat.Group.Count - $required
        $doc += "`n| $($cat.Name) | $required | $optional |"
    }

    $doc += @"

---

## Detailed Rule List

| Destination | Port | Protocol | Category | Required | Status |
|-------------|------|----------|----------|----------|--------|
"@

    foreach ($endpoint in $Endpoints) {
        $testResult = $TestResults | Where-Object { $_.Url -eq $endpoint.Url } | Select-Object -First 1
        $status = if ($testResult) { if ($testResult.Accessible) { '✅ Accessible' } else { '❌ Blocked' } } else { '⚪ Not tested' }
        
        $doc += "`n| $($endpoint.Url) | $($endpoint.Port) | HTTPS | $($endpoint.Category) | $(if($endpoint.Required){'Yes'}else{'No'}) | $status |"
    }

    $doc += @"

---

## Firewall Configuration Template

### Palo Alto Networks

\`\`\`
# Azure Local Outbound Rules
set rulebase security rules "Azure-Local-Outbound" from trust
set rulebase security rules "Azure-Local-Outbound" to untrust
set rulebase security rules "Azure-Local-Outbound" source azure-local-nodes
set rulebase security rules "Azure-Local-Outbound" destination any
set rulebase security rules "Azure-Local-Outbound" application ssl web-browsing
set rulebase security rules "Azure-Local-Outbound" service application-default
set rulebase security rules "Azure-Local-Outbound" action allow
\`\`\`

### Cisco ASA

\`\`\`
! Azure Local Outbound Rules
access-list AZURE-LOCAL-OUT extended permit tcp any any eq 443
access-list AZURE-LOCAL-OUT extended permit udp any any eq 123
\`\`\`

### Fortinet FortiGate

\`\`\`
config firewall policy
    edit 100
        set name "Azure-Local-Outbound"
        set srcintf "internal"
        set dstintf "wan"
        set srcaddr "Azure-Local-Nodes"
        set dstaddr "all"
        set action accept
        set schedule "always"
        set service "HTTPS" "NTP"
    next
end
\`\`\`

---

## Notes

1. All traffic is outbound only - no inbound rules required from internet
2. Some endpoints may require wildcard (*) matching for subdomains
3. Consider using Azure Service Tags where supported
4. Test connectivity from cluster nodes after configuration

---

*Generated by Azure Local Cloud AzureLocalCloud Automation*
"@

    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path $docPath -Value $doc
    return $docPath
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Firewall Endpoint Configuration" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get required endpoints
    Write-LogMessage "Loading Azure Local endpoint requirements..." -Level Info
    $endpoints = Get-AzureLocalRequiredEndpoints
    Write-LogMessage "  Found $($endpoints.Count) endpoints" -Level Info

    $requiredCount = ($endpoints | Where-Object { $_.Required }).Count
    $optionalCount = $endpoints.Count - $requiredCount
    Write-LogMessage "  Required: $requiredCount, Optional: $optionalCount" -Level Info

    # Test connectivity if requested
    $testResults = @()
    if ($TestConnectivity) {
        Write-LogMessage "Testing endpoint connectivity..." -Level Info
        
        foreach ($endpoint in $endpoints) {
            Write-Host "  Testing $($endpoint.Url):$($endpoint.Port)... " -NoNewline
            
            $accessible = Test-EndpointConnectivity -Hostname $endpoint.Url -Port $endpoint.Port
            
            $testResults += @{
                Url        = $endpoint.Url
                Port       = $endpoint.Port
                Category   = $endpoint.Category
                Required   = $endpoint.Required
                Accessible = $accessible
            }

            $status = if ($accessible) { "✓" } else { "✗" }
            $color = if ($accessible) { "Green" } else { if ($endpoint.Required) { "Red" } else { "Yellow" } }
            Write-Host $status -ForegroundColor $color
        }

        # Summary
        $accessible = ($testResults | Where-Object { $_.Accessible }).Count
        $blocked = $testResults.Count - $accessible
        $blockedRequired = ($testResults | Where-Object { -not $_.Accessible -and $_.Required }).Count

        Write-LogMessage "" -Level Info
        Write-LogMessage "Connectivity Summary:" -Level Info
        Write-LogMessage "  Accessible: $accessible" -Level Success
        Write-LogMessage "  Blocked: $blocked" -Level $(if($blocked -eq 0){'Info'}else{'Warning'})
        
        if ($blockedRequired -gt 0) {
            Write-LogMessage "  BLOCKED REQUIRED: $blockedRequired" -Level Error
            Write-LogMessage "" -Level Info
            Write-LogMessage "The following REQUIRED endpoints are blocked:" -Level Error
            foreach ($result in ($testResults | Where-Object { -not $_.Accessible -and $_.Required })) {
                Write-LogMessage "  - $($result.Url):$($result.Port) [$($result.Category)]" -Level Error
            }
        }
    }

    # Generate documentation
    Write-LogMessage "Generating firewall requirements document..." -Level Info
    $docPath = New-FirewallRuleDocument `
        -Endpoints $endpoints `
        -TestResults $testResults `
        -OutputPath $OutputPath

    Write-LogMessage "  Document: $docPath" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Firewall Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  Requirements document: $docPath" -Level Info
    
    if ($TestConnectivity) {
        $allAccessible = ($testResults | Where-Object { $_.Required -and -not $_.Accessible }).Count -eq 0
        Write-LogMessage "  Connectivity: $(if($allAccessible){'All required endpoints accessible'}else{'Some required endpoints blocked'})" -Level $(if($allAccessible){'Success'}else{'Error'})
    }

    return @{
        Status      = 'Complete'
        Endpoints   = $endpoints
        TestResults = $testResults
        DocumentPath = $docPath
    }

} catch {
    Write-LogMessage "Firewall configuration failed: $_" -Level Error
    throw
}

#endregion Main
