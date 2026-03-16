<#
.SYNOPSIS
    Configures Dell PowerSwitch for Azure Local deployment.

.DESCRIPTION
    This script configures the Dell PowerSwitch (SONiC) for Azure Local:
    - Verifies switch connectivity
    - Applies base configuration
    - Configures VLANs and port channels
    - Sets up LLDP and QoS

.PARAMETER SwitchHost
    Hostname or IP address of the PowerSwitch.

.PARAMETER Credential
    Credentials for switch admin access.

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration file.

.EXAMPLE
    .\Set-PowerSwitchEndpoint.ps1 -SwitchHost "switch01.customer.local"

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 1.0.0
    Stage: 04-onprem-readiness
    Step: stage-10-network-device-deployment/step-02-powerswitch-endpoint
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$SwitchHost,

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [int]$SshPort = 22,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\configs\infrastructure.yml",

    [Parameter(Mandatory = $false)]
    [string]$ConfigTemplatePath,

    [Parameter(Mandatory = $false)]
    [switch]$ApplyConfig,

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

function Test-SwitchConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to the PowerSwitch.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$SshPort
    )

    $results = @{
        Ping = $false
        SSH  = $false
    }

    # Test ping
    $results.Ping = Test-Connection -ComputerName $Host -Count 2 -Quiet

    # Test SSH port
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($Host, $SshPort, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
        if ($wait -and $tcpClient.Connected) {
            $results.SSH = $true
            $tcpClient.Close()
        }
    } catch { }

    return $results
}

function Get-SwitchVersion {
    <#
    .SYNOPSIS
        Gets SONiC version information from the switch.
    #>
    [CmdletBinding()]
    param(
        [string]$Host,
        [int]$Port,
        [pscredential]$Credential
    )

    # Note: This uses SSH. In production, consider using Posh-SSH module
    Write-LogMessage "  Querying switch version (requires manual SSH or Posh-SSH)..." -Level Info
    
    # Placeholder - in production would use Posh-SSH
    # Example with Posh-SSH:
    # $session = New-SSHSession -ComputerName $Host -Port $Port -Credential $Credential -AcceptKey
    # $result = Invoke-SSHCommand -SessionId $session.SessionId -Command "show version"
    # Remove-SSHSession -SessionId $session.SessionId
    # return $result.Output

    return @{
        Note = "SSH connection required - use Posh-SSH module in production"
    }
}

function New-SwitchConfigFromTemplate {
    <#
    .SYNOPSIS
        Generates switch configuration from template.
    #>
    [CmdletBinding()]
    param(
        [string]$TemplatePath,
        [hashtable]$Config
    )

    if (-not (Test-Path $TemplatePath)) {
        Write-LogMessage "  Config template not found: $TemplatePath" -Level Warning
        return $null
    }

    $template = Get-Content -Path $TemplatePath -Raw

    # Replace placeholders with actual values
    $switchConfig = $template

    # Management VLAN
    if ($config.networking.onprem.vlans.management) {
        $switchConfig = $switchConfig -replace '\{\{MGMT_VLAN\}\}', $config.networking.onprem.vlans.management.id
    }

    # Storage VLAN
    if ($config.networking.onprem.vlans.storage) {
        $switchConfig = $switchConfig -replace '\{\{STORAGE_VLAN\}\}', $config.networking.onprem.vlans.storage.id
    }

    # VM VLAN range
    if ($config.networking.onprem.vlans.workload) {
        $switchConfig = $switchConfig -replace '\{\{COMPUTE_VLAN_START\}\}', $config.networking.onprem.vlans.workload.start
        $switchConfig = $switchConfig -replace '\{\{COMPUTE_VLAN_END\}\}', $config.networking.onprem.vlans.workload.end
    }

    return $switchConfig
}

function Get-PowerSwitchValidation {
    <#
    .SYNOPSIS
        Validates switch configuration requirements for Azure Local.
    #>
    [CmdletBinding()]
    param([hashtable]$Config)

    $checks = @()

    # Check VLAN configuration
    $checks += @{
        Name    = "Management VLAN"
        Status  = if ($config.networking.onprem.vlans.management) { 'Configured' } else { 'Missing' }
        Details = $config.networking.onprem.vlans.management.id ?? 'Not defined'
    }

    $checks += @{
        Name    = "Storage VLAN"
        Status  = if ($config.networking.onprem.vlans.storage) { 'Configured' } else { 'Missing' }
        Details = $config.networking.onprem.vlans.storage.id ?? 'Not defined'
    }

    # Check MTU settings
    $checks += @{
        Name    = "Jumbo Frames"
        Status  = if ($config.networking.onprem.mtu -ge 9000) { 'Configured' } else { 'Warning' }
        Details = "MTU: $($config.networking.onprem.mtu ?? 'Default')"
    }

    return $checks
}

#endregion Functions

#region Main

try {
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "Dell PowerSwitch Configuration" -Level Info
    Write-LogMessage "=" * 60 -Level Info

    # Load configuration
    $config = $null
    if (Test-Path $ConfigPath) {
        $config = Import-InfrastructureConfig -Path $ConfigPath
        Write-LogMessage "Configuration loaded" -Level Info
    }

    # Get switch host from config if not provided
    if (-not $SwitchHost) {
        $SwitchHost = $config.networking.onprem.network_devices.powerswitch.host
        if (-not $SwitchHost) {
            throw "SwitchHost is required"
        }
    }

    Write-LogMessage "PowerSwitch Host: $SwitchHost" -Level Info

    # Test connectivity
    Write-LogMessage "Testing connectivity..." -Level Info
    $connectivity = Test-SwitchConnectivity -Host $SwitchHost -SshPort $SshPort
    Write-LogMessage "  Ping: $(if($connectivity.Ping){'✓'}else{'✗'})" -Level $(if($connectivity.Ping){'Success'}else{'Error'})
    Write-LogMessage "  SSH: $(if($connectivity.SSH){'✓'}else{'✗'})" -Level $(if($connectivity.SSH){'Success'}else{'Error'})

    if (-not $connectivity.SSH) {
        throw "Cannot connect to switch via SSH"
    }

    # Validate configuration requirements
    Write-LogMessage "Validating configuration requirements..." -Level Info
    $validation = Get-PowerSwitchValidation -Config $config

    foreach ($check in $validation) {
        $level = switch ($check.Status) {
            'Configured' { 'Success' }
            'Warning'    { 'Warning' }
            'Missing'    { 'Error' }
            default      { 'Info' }
        }
        Write-LogMessage "  $($check.Name): $($check.Status) ($($check.Details))" -Level $level
    }

    # Generate configuration if template provided
    if ($ConfigTemplatePath) {
        Write-LogMessage "Generating switch configuration from template..." -Level Info
        $switchConfig = New-SwitchConfigFromTemplate -TemplatePath $ConfigTemplatePath -Config $config
        
        if ($switchConfig) {
            $configFile = ".\output\switch-config-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
            if (-not (Test-Path (Split-Path $configFile -Parent))) {
                New-Item -Path (Split-Path $configFile -Parent) -ItemType Directory -Force | Out-Null
            }
            Set-Content -Path $configFile -Value $switchConfig
            Write-LogMessage "  Configuration saved: $configFile" -Level Success
        }
    }

    # Display manual steps
    Write-LogMessage "" -Level Info
    Write-LogMessage "MANUAL CONFIGURATION STEPS:" -Level Warning
    Write-LogMessage "  1. SSH to switch: ssh admin@$SwitchHost" -Level Info
    Write-LogMessage "  2. Enter configuration mode: configure terminal" -Level Info
    Write-LogMessage "  3. Apply VLAN configuration for Azure Local" -Level Info
    Write-LogMessage "  4. Configure port channels for node uplinks" -Level Info
    Write-LogMessage "  5. Enable LLDP on all ports" -Level Info
    Write-LogMessage "  6. Configure QoS for storage traffic" -Level Info
    Write-LogMessage "  7. Save configuration: write memory" -Level Info

    # Summary
    Write-LogMessage "=" * 60 -Level Info
    Write-LogMessage "PowerSwitch Configuration Check Complete" -Level Success
    Write-LogMessage "=" * 60 -Level Info

    return @{
        Status       = 'ValidationComplete'
        Host         = $SwitchHost
        Connectivity = $connectivity
        Validation   = $validation
    }

} catch {
    Write-LogMessage "PowerSwitch configuration failed: $_" -Level Error
    throw
}

#endregion Main
