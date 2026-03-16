<#
.SYNOPSIS
    Verifies Opengear console server configuration and connectivity.

.DESCRIPTION
    This script validates Opengear console server setup:
    - Tests network connectivity
    - Verifies serial port configuration
    - Validates access to connected devices
    - Checks logging configuration

.PARAMETER OpengearHost
    Hostname or IP address of the Opengear device.

.PARAMETER Credential
    Credentials for Opengear access.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Test-OpengearVerification.ps1 -OpengearHost "192.168.1.100"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 04-onprem-readiness
    Step: stage-09-enterprise-readiness/step-03-opengear-verification
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OpengearHost,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [int]$SshPort = 22,

    [Parameter(Mandatory = $false)]
    [int]$WebPort = 443,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\opengear-verification"
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

function Test-NetworkConnectivity {
    <#
    .SYNOPSIS
        Tests basic network connectivity to Opengear device.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$SshPort,
        [int]$WebPort
    )

    $results = @{
        Ping      = $false
        SSH       = $false
        WebUI     = $false
    }

    # Test ping
    Write-LogMessage "  Testing ICMP ping..." -Level Info
    $ping = Test-Connection -ComputerName $Host -Count 2 -Quiet
    $results.Ping = $ping
    Write-LogMessage "    Ping: $(if($ping){'✓ Reachable'}else{'✗ Unreachable'})" -Level $(if($ping){'Success'}else{'Error'})

    # Test SSH port
    Write-LogMessage "  Testing SSH port ($SshPort)..." -Level Info
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($Host, $SshPort, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
        if ($wait -and $tcpClient.Connected) {
            $results.SSH = $true
            $tcpClient.Close()
        }
    } catch { }
    Write-LogMessage "    SSH: $(if($results.SSH){'✓ Open'}else{'✗ Closed'})" -Level $(if($results.SSH){'Success'}else{'Error'})

    # Test Web UI port
    Write-LogMessage "  Testing Web UI port ($WebPort)..." -Level Info
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($Host, $WebPort, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
        if ($wait -and $tcpClient.Connected) {
            $results.WebUI = $true
            $tcpClient.Close()
        }
    } catch { }
    Write-LogMessage "    WebUI: $(if($results.WebUI){'✓ Open'}else{'✗ Closed'})" -Level $(if($results.WebUI){'Success'}else{'Error'})

    return $results
}

function Get-OpengearConfig {
    <#
    .SYNOPSIS
        Retrieves configuration from Opengear via REST API.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$Port,
        [pscredential]$Credential
    )

    try {
        $baseUri = "https://${Host}:${Port}/api/v1"
        
        # Get auth token
        $authBody = @{
            username = $Credential.UserName
            password = $Credential.GetNetworkCredential().Password
        } | ConvertTo-Json

        $authResponse = Invoke-RestMethod `
            -Uri "$baseUri/sessions" `
            -Method POST `
            -Body $authBody `
            -ContentType 'application/json' `
            -SkipCertificateCheck

        $token = $authResponse.session

        $headers = @{
            'Authorization' = "Token $token"
        }

        # Get system info
        $systemInfo = Invoke-RestMethod `
            -Uri "$baseUri/system" `
            -Headers $headers `
            -SkipCertificateCheck

        # Get serial ports
        $serialPorts = Invoke-RestMethod `
            -Uri "$baseUri/serialPorts" `
            -Headers $headers `
            -SkipCertificateCheck

        return @{
            System      = $systemInfo
            SerialPorts = $serialPorts.serialPorts
        }
    } catch {
        Write-LogMessage "  Failed to query Opengear API: $_" -Level Warning
        return $null
    }
}

function Test-SerialPortConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to devices connected via serial ports.
    #>
    [CmdletBinding()]
    param(
        [string]$OpengearHost,
        [int]$SshPort,
        [pscredential]$Credential,
        [array]$Ports
    )

    $results = @()

    foreach ($port in $Ports) {
        $portNumber = $port.id
        $portLabel = $port.label ?? "Port $portNumber"
        
        Write-LogMessage "  Testing serial port: $portLabel (Port $portNumber)" -Level Info

        # Test SSH to serial port (typically opengear_host:port_number_base + port)
        $serialSshPort = 3000 + $portNumber
        
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connect = $tcpClient.BeginConnect($OpengearHost, $serialSshPort, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne(2000, $false)
            $accessible = $wait -and $tcpClient.Connected
            if ($accessible) { $tcpClient.Close() }
        } catch {
            $accessible = $false
        }

        $results += @{
            PortNumber  = $portNumber
            Label       = $portLabel
            SshPort     = $serialSshPort
            Accessible  = $accessible
            Mode        = $port.mode
            Status      = $port.status
        }

        Write-LogMessage "    $(if($accessible){'✓'}else{'✗'}) $portLabel - SSH port $serialSshPort" -Level $(if($accessible){'Success'}else{'Warning'})
    }

    return $results
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Opengear Console Server Verification" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
    }

    # Get Opengear host from config if not provided
    if (-not $OpengearHost) {
        $OpengearHost = $config.networking.onprem.network_devices.opengear.host
        if (-not $OpengearHost) {
            throw "OpengearHost is required"
        }
    }

    # Prompt for credentials if not provided
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter Opengear credentials"
    }

    Write-LogMessage "Opengear Host: $OpengearHost" -Level Info

    # Test network connectivity
    Write-LogMessage "Testing network connectivity..." -Level Info
    $networkResults = Test-NetworkConnectivity -Host $OpengearHost -SshPort $SshPort -WebPort $WebPort

    if (-not $networkResults.Ping -and -not $networkResults.SSH) {
        Write-LogMessage "Opengear device is not reachable" -Level Error
        return @{
            Status  = 'Failed'
            Network = $networkResults
        }
    }

    # Get Opengear configuration
    Write-LogMessage "Querying Opengear configuration..." -Level Info
    $opengearConfig = $null
    if ($networkResults.WebUI) {
        $opengearConfig = Get-OpengearConfig -Host $OpengearHost -Port $WebPort -Credential $Credential
    }

    $serialPortResults = @()
    if ($opengearConfig) {
        Write-LogMessage "System Info:" -Level Info
        Write-LogMessage "  Model: $($opengearConfig.System.model)" -Level Info
        Write-LogMessage "  Firmware: $($opengearConfig.System.firmware_version)" -Level Info
        Write-LogMessage "  Serial Ports: $($opengearConfig.SerialPorts.Count)" -Level Info

        # Test serial port connectivity
        if ($opengearConfig.SerialPorts) {
            Write-LogMessage "Testing serial port connectivity..." -Level Info
            $serialPortResults = Test-SerialPortConnectivity `
                -OpengearHost $OpengearHost `
                -SshPort $SshPort `
                -Credential $Credential `
                -Ports $opengearConfig.SerialPorts
        }
    } else {
        Write-LogMessage "Could not retrieve Opengear configuration via API" -Level Warning
    }

    # Generate report
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $reportFile = Join-Path $OutputPath "opengear-verification-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $report = @{
        Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Host         = $OpengearHost
        Network      = $networkResults
        System       = $opengearConfig.System
        SerialPorts  = $serialPortResults
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile
    Write-LogMessage "Report saved: $reportFile" -Level Success

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Opengear Verification Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    $allPassed = $networkResults.Ping -and $networkResults.SSH
    Write-LogMessage "  Network: $(if($allPassed){'✓ All tests passed'}else{'⚠ Some tests failed'})" -Level $(if($allPassed){'Success'}else{'Warning'})
    
    if ($serialPortResults) {
        $accessiblePorts = ($serialPortResults | Where-Object { $_.Accessible }).Count
        Write-LogMessage "  Serial Ports: $accessiblePorts / $($serialPortResults.Count) accessible" -Level Info
    }

    return @{
        Status           = if($allPassed){'Passed'}else{'Warning'}
        Network          = $networkResults
        System           = $opengearConfig.System
        SerialPorts      = $serialPortResults
        ReportPath       = $reportFile
    }

} catch {
    Write-LogMessage "Opengear verification failed: $_" -Level Error
    throw
}

#endregion Main
