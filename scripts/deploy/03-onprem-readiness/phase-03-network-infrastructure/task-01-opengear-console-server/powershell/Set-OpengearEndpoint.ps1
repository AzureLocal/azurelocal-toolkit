<#
.SYNOPSIS
    Configures Opengear console server endpoint for Azure Local deployment.

.DESCRIPTION
    This script configures the Opengear console server:
    - Sets network configuration
    - Configures serial port mappings to nodes
    - Sets up logging and alerting
    - Configures authentication

.PARAMETER OpengearHost
    Hostname or IP address of the Opengear device.

.PARAMETER Credential
    Credentials for Opengear admin access.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-OpengearEndpoint.ps1 -OpengearHost "opengear.customer.local"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 04-onprem-readiness
    Step: stage-10-network-device-deployment/step-01-opengear-endpoint
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$OpengearHost,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [int]$WebPort = 443,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [switch]$Force
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

function Get-OpengearAuthToken {
    <#
    .SYNOPSIS
        Gets authentication token from Opengear REST API.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$Port,
        [pscredential]$Credential
    )

    $baseUri = "https://${Host}:${Port}/api/v1"
    
    $authBody = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    } | ConvertTo-Json

    $response = Invoke-RestMethod `
        -Uri "$baseUri/sessions" `
        -Method POST `
        -Body $authBody `
        -ContentType 'application/json' `
        -SkipCertificateCheck

    return $response.session
}

function Set-OpengearSerialPort {
    <#
    .SYNOPSIS
        Configures a serial port on the Opengear device.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$Port,
        [string]$Token,
        [int]$PortNumber,
        [string]$Label,
        [string]$Mode = 'localConsole',
        [int]$BaudRate = 115200,
        [int]$DataBits = 8,
        [string]$Parity = 'none',
        [int]$StopBits = 1
    )

    $baseUri = "https://${Host}:${Port}/api/v1"
    $headers = @{ 'Authorization' = "Token $Token" }

    $portConfig = @{
        label    = $Label
        mode     = $Mode
        baudrate = $BaudRate
        databits = $DataBits
        parity   = $Parity
        stopbits = $StopBits
        logging  = @{
            enabled = $true
            level   = 'default'
        }
    } | ConvertTo-Json

    $response = Invoke-RestMethod `
        -Uri "$baseUri/serialPorts/$PortNumber" `
        -Method PUT `
        -Headers $headers `
        -Body $portConfig `
        -ContentType 'application/json' `
        -SkipCertificateCheck

    return $response
}

function Set-OpengearAlerts {
    <#
    .SYNOPSIS
        Configures alerting on the Opengear device.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$Port,
        [string]$Token,
        [hashtable]$AlertConfig
    )

    $baseUri = "https://${Host}:${Port}/api/v1"
    $headers = @{ 'Authorization' = "Token $Token" }

    # Configure SNMP alerts if specified
    if ($AlertConfig.snmp) {
        $snmpConfig = @{
            enabled    = $true
            community  = $AlertConfig.snmp.community
            trapHost   = $AlertConfig.snmp.trapHost
        } | ConvertTo-Json

        try {
            Invoke-RestMethod `
                -Uri "$baseUri/services/snmp" `
                -Method PUT `
                -Headers $headers `
                -Body $snmpConfig `
                -ContentType 'application/json' `
                -SkipCertificateCheck | Out-Null
            
            Write-LogMessage "  SNMP alerts configured" -Level Success
        } catch {
            Write-LogMessage "  Failed to configure SNMP: $_" -Level Warning
        }
    }

    # Configure syslog if specified
    if ($AlertConfig.syslog) {
        $syslogConfig = @{
            enabled = $true
            server  = $AlertConfig.syslog.server
            port    = $AlertConfig.syslog.port ?? 514
        } | ConvertTo-Json

        try {
            Invoke-RestMethod `
                -Uri "$baseUri/services/syslog" `
                -Method PUT `
                -Headers $headers `
                -Body $syslogConfig `
                -ContentType 'application/json' `
                -SkipCertificateCheck | Out-Null
            
            Write-LogMessage "  Syslog configured" -Level Success
        } catch {
            Write-LogMessage "  Failed to configure syslog: $_" -Level Warning
        }
    }
}

function Set-OpengearUsers {
    <#
    .SYNOPSIS
        Configures users on the Opengear device.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$Port,
        [string]$Token,
        [array]$Users
    )

    $baseUri = "https://${Host}:${Port}/api/v1"
    $headers = @{ 'Authorization' = "Token $Token" }

    foreach ($user in $Users) {
        $userConfig = @{
            username = $user.username
            password = $user.password
            groups   = $user.groups ?? @('users')
            enabled  = $true
        } | ConvertTo-Json

        try {
            # Check if user exists
            try {
                Invoke-RestMethod `
                    -Uri "$baseUri/users/$($user.username)" `
                    -Headers $headers `
                    -SkipCertificateCheck | Out-Null
                
                # Update existing user
                Invoke-RestMethod `
                    -Uri "$baseUri/users/$($user.username)" `
                    -Method PUT `
                    -Headers $headers `
                    -Body $userConfig `
                    -ContentType 'application/json' `
                    -SkipCertificateCheck | Out-Null
                
                Write-LogMessage "  User updated: $($user.username)" -Level Success
            } catch {
                # Create new user
                Invoke-RestMethod `
                    -Uri "$baseUri/users" `
                    -Method POST `
                    -Headers $headers `
                    -Body $userConfig `
                    -ContentType 'application/json' `
                    -SkipCertificateCheck | Out-Null
                
                Write-LogMessage "  User created: $($user.username)" -Level Success
            }
        } catch {
            Write-LogMessage "  Failed to configure user $($user.username): $_" -Level Warning
        }
    }
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Opengear Console Server Configuration" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
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
        $Credential = Get-Credential -Message "Enter Opengear admin credentials"
    }

    Write-LogMessage "Opengear Host: $OpengearHost" -Level Info

    # Get authentication token
    Write-LogMessage "Authenticating..." -Level Info
    $token = Get-OpengearAuthToken -Host $OpengearHost -Port $WebPort -Credential $Credential
    Write-LogMessage "  Authentication successful" -Level Success

    # Configure serial ports for cluster nodes
    if ($config.compute.cluster_nodes) {
        Write-LogMessage "Configuring serial ports for cluster nodes..." -Level Info
        $portNumber = 1
        
        foreach ($node in $config.compute.cluster_nodes) {
            $label = "$($node.name)-console"
            
            if ($PSCmdlet.ShouldProcess("Port $portNumber", "Configure as $label")) {
                Set-OpengearSerialPort `
                    -Host $OpengearHost `
                    -Port $WebPort `
                    -Token $token `
                    -PortNumber $portNumber `
                    -Label $label

                Write-LogMessage "  Port $portNumber configured: $label" -Level Success
            }
            
            $portNumber++
        }
    }

    # Configure alerts
    if ($config.networking.onprem.network_devices.opengear.alerts) {
        Write-LogMessage "Configuring alerts..." -Level Info
        Set-OpengearAlerts `
            -Host $OpengearHost `
            -Port $WebPort `
            -Token $token `
            -AlertConfig $config.networking.onprem.network_devices.opengear.alerts
    }

    # Configure users
    if ($config.networking.onprem.network_devices.opengear.users) {
        Write-LogMessage "Configuring users..." -Level Info
        Set-OpengearUsers `
            -Host $OpengearHost `
            -Port $WebPort `
            -Token $token `
            -Users $config.networking.onprem.network_devices.opengear.users
    }

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Opengear Configuration Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "  Host: $OpengearHost" -Level Info
    Write-LogMessage "  Serial ports configured: $($config.compute.cluster_nodes.Count)" -Level Info

    return @{
        Status = 'Complete'
        Host   = $OpengearHost
    }

} catch {
    Write-LogMessage "Opengear configuration failed: $_" -Level Error
    throw
}

#endregion Main
