<#
.SYNOPSIS
    Discovers and inventories on-premises network infrastructure.

.DESCRIPTION
    Collects configuration and status data from on-premises network devices
    including firewalls, switches, console servers, and other infrastructure.
    
    Supports multiple device types via pluggable discovery modules:
    - Ubiquiti UniFi (UDM) - REST API
    - Ubiquiti EdgeRouter - REST/SSH
    - OpenGear console servers - REST API
    - Dell/Sodola switches - REST/SSH
    - Generic SNMP devices
    
    Retrieves credentials from Azure Key Vault for secure authentication.
    Outputs to consolidated onprem-inventory.json file.

.PARAMETER DeviceType
    Filter by device type: udm, edgerouter, opengear, switch, snmp, all
    Default: all

.PARAMETER DeviceIP
    Specific device IP(s) to scan. Overrides infrastructure.yml device list.

.PARAMETER DeviceName
    Specific device name(s) from infrastructure.yml to scan.

.PARAMETER KeyVaultName
    Azure Key Vault name for credential retrieval. 
    Default: reads from infrastructure.yml

.PARAMETER InfrastructureFile
    Path to infrastructure.yml file. Default: repository root.

.PARAMETER OutputPath
    Output directory for inventory file. Default: ./discovery

.PARAMETER SkipKeyVault
    Skip Key Vault credential retrieval (use for devices with no auth or testing).

.PARAMETER Timeout
    API/connection timeout in seconds. Default: 30

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Inventory-OnPrem.ps1
    # Discover all devices listed in infrastructure.yml

.EXAMPLE
    .\Inventory-OnPrem.ps1 -DeviceType udm -WhatIf
    # Preview UDM discovery only

.EXAMPLE
    .\Inventory-OnPrem.ps1 -DeviceName "opengear" -Verbose
    # Discover specific device by name with verbose output

.EXAMPLE
    .\Inventory-OnPrem.ps1 -DeviceIP "192.168.200.250" -SkipKeyVault
    # Discover specific device without Key Vault credentials

.NOTES
    File: Inventory-OnPrem.ps1
    Author: Azure Local Documentation Team
    Version: 1.0.0
    Created: 2025-12-05
    
    ═══════════════════════════════════════════════════════════════════════════
    DESIGN DOCUMENT: discovery/Inventory-OnPrem.md
    ═══════════════════════════════════════════════════════════════════════════
    
    INTEGRATION:
    - Input: infrastructure.yml (network_devices section)
    - Credentials: Azure Key Vault (keyvault:// URI scheme)
    - Output: discovery/onprem-inventory.json
    - Merge: Update-InfrastructureFromDiscovery.ps1 -OnPrem

    VERSION HISTORY:
    - 1.0.0 (2025-12-05): Initial implementation
      - Key Vault integration with keyvault:// URI scheme
      - UDM, EdgeRouter, OpenGear, Switch discovery modules
      - SNMP fallback for generic devices
      - Infrastructure.yml integration
      - JSON output with metadata and error tracking
#>

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [ValidateSet("udm", "edgerouter", "opengear", "switch", "snmp", "all")]
    [string[]]$DeviceType = @("all"),

    [Parameter(Mandatory = $false)]
    [string[]]$DeviceIP,

    [Parameter(Mandatory = $false)]
    [string[]]$DeviceName,

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$InfrastructureFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipKeyVault,

    [Parameter(Mandatory = $false)]
    [int]$Timeout = 30,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#region Script Configuration
$ErrorActionPreference = "Stop"
$ScriptVersion = "1.0.0"
$ScriptRoot = $PSScriptRoot

# Determine repository root (2 levels up from scripts/discovery)
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptRoot)

# Set default paths
if (-not $InfrastructureFile) {
    $InfrastructureFile = Join-Path $RepoRoot "infrastructure.yml"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $RepoRoot "discovery"
}

$OutputFile = Join-Path $OutputPath "onprem-inventory.json"

# Device type mappings (infrastructure.yml type -> script category)
$DeviceTypeMap = @{
    "Ubiquiti UniFi Dream Machine" = "udm"
    "Ubiquiti EdgeRouter X"        = "edgerouter"
    "Opengear OM1208"              = "opengear"
    "Sodola SL902-SWTGW124AS"      = "switch"
    "Dell Switch"                  = "switch"
    "FortiGate"                    = "fortigate"
}
#endregion

#region Helper Functions

function Write-Banner {
    param([string]$Title, [string]$Color = "Cyan")
    
    $width = 70
    $line = "═" * $width
    Write-Host ""
    Write-Host "╔$line╗" -ForegroundColor $Color
    Write-Host "║ $($Title.PadRight($width - 1))║" -ForegroundColor $Color
    Write-Host "╚$line╝" -ForegroundColor $Color
    Write-Host ""
}

function Write-DeviceHeader {
    param(
        [string]$DeviceName,
        [string]$DeviceType,
        [string]$IP
    )
    Write-Host "┌─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "│ Device: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$DeviceName" -NoNewline -ForegroundColor White
    Write-Host " ($DeviceType)" -ForegroundColor Gray
    Write-Host "│ IP: $IP" -ForegroundColor DarkGray
    Write-Host "└─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
}

function Get-InfrastructureConfig {
    <#
    .SYNOPSIS
        Loads and parses infrastructure.yml file.
    #>
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        throw "Infrastructure file not found: $Path"
    }
    
    Write-Verbose "Loading infrastructure file: $Path"
    
    # Use powershell-yaml module if available, otherwise parse manually
    try {
        if (Get-Module -ListAvailable -Name powershell-yaml) {
            Import-Module powershell-yaml -ErrorAction Stop
            $content = Get-Content $Path -Raw
            $config = ConvertFrom-Yaml $content
            return $config
        }
    }
    catch {
        Write-Verbose "powershell-yaml module not available, using manual parsing"
    }
    
    # Manual YAML parsing for network_devices section
    $content = Get-Content $Path -Raw
    $devices = @{}
    
    # Find network_devices section
    if ($content -match '(?ms)^network_devices:\s*\n((?:  .+\n)+)') {
        $deviceSection = $Matches[1]
        $currentDevice = $null
        $currentDeviceData = @{}
        
        foreach ($line in $deviceSection -split "`n") {
            # Skip empty lines
            if ($line -match '^\s*$') { continue }
            
            # New device (2-space indent, ends with colon)
            if ($line -match '^  ([a-zA-Z0-9_-]+):\s*$') {
                if ($currentDevice) {
                    $devices[$currentDevice] = $currentDeviceData
                }
                $currentDevice = $Matches[1]
                $currentDeviceData = @{}
            }
            # Device property (4-space indent)
            elseif ($line -match '^    ([a-zA-Z0-9_]+):\s*"?([^"]*)"?\s*$') {
                $key = $Matches[1]
                $value = $Matches[2].Trim()
                $currentDeviceData[$key] = $value
            }
            # Nested object start (4-space indent, ends with colon only)
            elseif ($line -match '^    ([a-zA-Z0-9_]+):\s*$') {
                # Skip nested objects for now (ports, serial_ports, etc.)
                continue
            }
            # Break on next top-level section
            elseif ($line -match '^[a-zA-Z]') {
                break
            }
        }
        
        # Don't forget the last device
        if ($currentDevice) {
            $devices[$currentDevice] = $currentDeviceData
        }
    }
    
    return @{
        network_devices = $devices
    }
}

function Get-KeyVaultCredential {
    <#
    .SYNOPSIS
        Retrieves a credential from Azure Key Vault.
    #>
    param(
        [string]$KeyVaultUri,
        [string]$DefaultVaultName
    )
    
    # Parse keyvault:// URI
    # Format: keyvault://vault-name/secret-name
    if ($KeyVaultUri -match '^keyvault://([^/]+)/(.+)$') {
        $vaultName = $Matches[1]
        $secretName = $Matches[2]
    }
    elseif ($KeyVaultUri -match '^keyvault://(.+)$') {
        # Just secret name, use default vault
        $vaultName = $DefaultVaultName
        $secretName = $Matches[1]
    }
    else {
        # Not a keyvault URI, treat as secret name with default vault
        $vaultName = $DefaultVaultName
        $secretName = $KeyVaultUri
    }
    
    if (-not $vaultName) {
        Write-Warning "No Key Vault name specified for secret: $secretName"
        return $null
    }
    
    Write-Verbose "  Retrieving secret '$secretName' from Key Vault '$vaultName'"
    
    try {
        $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -ErrorAction Stop
        if ($secret) {
            $value = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            Write-Verbose "  Successfully retrieved secret '$secretName'"
            return $value
        }
    }
    catch {
        Write-Warning "  Failed to retrieve secret '$secretName' from Key Vault '$vaultName': $($_.Exception.Message)"
        return $null
    }
    
    return $null
}

function Get-DeviceCredentials {
    <#
    .SYNOPSIS
        Gets username and password for a device from the credentials section via Key Vault.
    #>
    param(
        [string]$CredentialRef,
        [string]$InfrastructureFile,
        [string]$DefaultVaultName
    )
    
    if (-not $CredentialRef) {
        return $null
    }
    
    Write-Verbose "  Looking up credential_ref: $CredentialRef"
    
    # Parse the credentials section from infrastructure.yml
    $content = Get-Content $InfrastructureFile -Raw
    
    # Find the credential entry - look for patterns like:
    # opengear:
    #   username_secret: "opengear-username"
    #   password_secret: "opengear-password"
    #   key_vault: "kv-platform"
    
    $credSection = $null
    $inCredentials = $false
    $inTargetCred = $false
    $credData = @{}
    
    foreach ($line in $content -split "`n") {
        if ($line -match '^credentials:') {
            $inCredentials = $true
            continue
        }
        if ($inCredentials -and $line -match "^  ${CredentialRef}:\s*$") {
            $inTargetCred = $true
            continue
        }
        if ($inTargetCred) {
            if ($line -match '^  [a-zA-Z]' -and $line -notmatch "^  ${CredentialRef}:") {
                # Hit next credential entry
                break
            }
            if ($line -match '^    ([a-zA-Z0-9_]+):\s*"?([^"]+)"?\s*$') {
                $credData[$Matches[1]] = $Matches[2].Trim()
            }
        }
        if ($inCredentials -and $line -match '^[a-zA-Z]' -and $line -notmatch '^credentials:') {
            break
        }
    }
    
    if ($credData.Count -eq 0) {
        Write-Verbose "  No credential data found for '$CredentialRef'"
        return $null
    }
    
    $vaultName = $credData.key_vault ?? $DefaultVaultName
    
    $result = @{
        Username = $null
        Password = $null
    }
    
    # Get username
    if ($credData.username_secret) {
        $result.Username = Get-KeyVaultCredential -KeyVaultUri $credData.username_secret -DefaultVaultName $vaultName
    }
    elseif ($credData.username) {
        $result.Username = $credData.username
    }
    
    # Get password
    if ($credData.password_secret) {
        $result.Password = Get-KeyVaultCredential -KeyVaultUri $credData.password_secret -DefaultVaultName $vaultName
    }
    
    if ($result.Username -and $result.Password) {
        Write-Verbose "  Successfully retrieved credentials for '$CredentialRef'"
        return $result
    }
    
    Write-Verbose "  Incomplete credentials for '$CredentialRef'"
    return $null
}

function Test-DeviceReachable {
    <#
    .SYNOPSIS
        Tests if a device is reachable via ping or port check.
    #>
    param(
        [string]$IP,
        [int]$Port = 443,
        [int]$TimeoutMs = 3000
    )
    
    # Try TCP connection first (more reliable than ICMP)
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($IP, $Port, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        
        if ($wait) {
            try { $tcpClient.EndConnect($connect) } catch { }
            $tcpClient.Close()
            return $true
        }
        else {
            $tcpClient.Close()
            return $false
        }
    }
    catch {
        return $false
    }
}

function Invoke-DeviceApi {
    <#
    .SYNOPSIS
        Makes an API call to a network device with common error handling.
    #>
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers = @{},
        [object]$Body,
        [int]$TimeoutSec = 30,
        [switch]$SkipCertificateCheck
    )
    
    $params = @{
        Uri                  = $Uri
        Method               = $Method
        Headers              = $Headers
        TimeoutSec           = $TimeoutSec
        SkipCertificateCheck = $true  # Most network devices use self-signed certs
        ErrorAction          = "Stop"
    }
    
    if ($Body) {
        $params.Body = $Body | ConvertTo-Json -Depth 10
        $params.ContentType = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        throw "API call failed: $($_.Exception.Message)"
    }
}
#endregion

#region Device Discovery Modules

function Get-UDMInventory {
    <#
    .SYNOPSIS
        Discovers Ubiquiti UniFi Dream Machine via REST API.
    #>
    param(
        [string]$IP,
        [string]$ApiKey,
        [string]$DeviceName,
        [hashtable]$DeviceConfig
    )
    
    $result = @{
        Type           = "UniFi Dream Machine"
        IP             = $IP
        Hostname       = $DeviceConfig.hostname
        Role           = $DeviceConfig.role
        LastDiscovered = (Get-Date -Format "o")
        Status         = "Unknown"
        Details        = @{}
    }
    
    if (-not $ApiKey) {
        $result.Status = "NoCredentials"
        $result.Error = "No API key available"
        Write-Warning "  No API key for UDM at $IP"
        return $result
    }
    
    Write-Verbose "  Connecting to UDM API at $IP"
    
    try {
        # UDM uses local API - attempt to get system info
        $headers = @{
            "Authorization" = "Bearer $ApiKey"
            "Accept"        = "application/json"
        }
        
        # Try the standard UniFi controller API endpoint
        $baseUri = "https://${IP}"
        
        # Get site info
        try {
            $siteInfo = Invoke-DeviceApi -Uri "$baseUri/proxy/network/api/s/default/stat/sysinfo" -Headers $headers -TimeoutSec $Timeout
            $result.Details.SysInfo = $siteInfo.data
            $result.Status = "Online"
        }
        catch {
            Write-Verbose "    Could not get site info: $_"
        }
        
        # Get device info
        try {
            $deviceInfo = Invoke-DeviceApi -Uri "$baseUri/proxy/network/api/s/default/stat/device" -Headers $headers -TimeoutSec $Timeout
            $result.Details.Devices = $deviceInfo.data
            
            # Extract UDM details if found
            $udm = $deviceInfo.data | Where-Object { $_.type -eq "udm" -or $_.model -like "*UDM*" } | Select-Object -First 1
            if ($udm) {
                $result.Model = $udm.model
                $result.SerialNumber = $udm.serial
                $result.Firmware = $udm.version
                $result.MAC = $udm.mac
                $result.Uptime = $udm.uptime
                $result.Status = "Online"
            }
        }
        catch {
            Write-Verbose "    Could not get device info: $_"
        }
        
        # Get network configuration
        try {
            $networks = Invoke-DeviceApi -Uri "$baseUri/proxy/network/api/s/default/rest/networkconf" -Headers $headers -TimeoutSec $Timeout
            $result.Details.Networks = $networks.data
        }
        catch {
            Write-Verbose "    Could not get network config: $_"
        }
        
        # Get clients
        try {
            $clients = Invoke-DeviceApi -Uri "$baseUri/proxy/network/api/s/default/stat/sta" -Headers $headers -TimeoutSec $Timeout
            $result.Details.ClientCount = ($clients.data | Measure-Object).Count
        }
        catch {
            Write-Verbose "    Could not get clients: $_"
        }
        
        if ($result.Status -eq "Unknown") {
            $result.Status = "PartialData"
        }
    }
    catch {
        $result.Status = "Error"
        $result.Error = $_.Exception.Message
        Write-Warning "  Error discovering UDM at ${IP}: $_"
    }
    
    return $result
}

function Get-EdgeRouterInventory {
    <#
    .SYNOPSIS
        Discovers Ubiquiti EdgeRouter via REST API or SSH.
    #>
    param(
        [string]$IP,
        [string]$Credential,
        [string]$DeviceName,
        [hashtable]$DeviceConfig
    )
    
    $result = @{
        Type           = "EdgeRouter"
        IP             = $IP
        Hostname       = $DeviceConfig.hostname
        Role           = $DeviceConfig.role
        BGP_ASN        = $DeviceConfig.bgp_asn
        LastDiscovered = (Get-Date -Format "o")
        Status         = "Unknown"
        Details        = @{}
    }
    
    # EdgeRouter typically uses session-based auth
    # Check reachability first
    if (Test-DeviceReachable -IP $IP -Port 443) {
        $result.Status = "Reachable"
        $result.Details.Note = "Device reachable on port 443. Full discovery requires session authentication."
        
        if ($Credential) {
            Write-Verbose "  EdgeRouter API auth not yet implemented - marking as reachable"
            # TODO: Implement EdgeRouter session-based auth
            # EdgeRouter uses form-based login, then session cookie
        }
    }
    elseif (Test-DeviceReachable -IP $IP -Port 22) {
        $result.Status = "Reachable"
        $result.Details.Note = "Device reachable on SSH (22). Full discovery requires Posh-SSH module."
        
        # TODO: Implement SSH-based discovery using Posh-SSH
        # if (Get-Module -ListAvailable -Name Posh-SSH) { ... }
    }
    else {
        $result.Status = "Unreachable"
        $result.Error = "Device not reachable on ports 443 or 22"
    }
    
    return $result
}

function Get-OpenGearInventory {
    <#
    .SYNOPSIS
        Discovers OpenGear console server via REST API.
    #>
    param(
        [string]$IP,
        [string]$Credential,
        [string]$DeviceName,
        [hashtable]$DeviceConfig
    )
    
    $result = @{
        Type           = "OpenGear Console Server"
        IP             = $IP
        Model          = $DeviceConfig.type
        Role           = $DeviceConfig.role
        VLAN           = $DeviceConfig.vlan
        LastDiscovered = (Get-Date -Format "o")
        Status         = "Unknown"
        Details        = @{}
        SerialPorts    = @{}
        SwitchPorts    = @{}
    }
    
    # Check reachability
    $reachable = Test-DeviceReachable -IP $IP -Port 443
    if (-not $reachable) {
        $reachable = Test-DeviceReachable -IP $IP -Port 80
    }
    
    if ($reachable) {
        $result.Status = "Reachable"
        
        if ($Credential) {
            Write-Verbose "  Attempting OpenGear API discovery"
            
            try {
                # OpenGear uses REST API with token auth
                # First, authenticate to get a token
                $authUri = "https://${IP}/api/v2/sessions"
                $authBody = @{
                    username = "admin"  # Default, should come from credential
                    password = $Credential
                }
                
                try {
                    $session = Invoke-DeviceApi -Uri $authUri -Method "POST" -Body $authBody -TimeoutSec $Timeout
                    $token = $session.session
                    
                    $headers = @{
                        "Authorization" = "Token $token"
                    }
                    
                    # Get system info
                    $sysInfo = Invoke-DeviceApi -Uri "https://${IP}/api/v2/system" -Headers $headers -TimeoutSec $Timeout
                    $result.Details.System = $sysInfo
                    $result.Hostname = $sysInfo.hostname
                    $result.Firmware = $sysInfo.firmware_version
                    $result.SerialNumber = $sysInfo.serial_number
                    $result.Status = "Online"
                    
                    # Get ports info
                    $ports = Invoke-DeviceApi -Uri "https://${IP}/api/v2/ports" -Headers $headers -TimeoutSec $Timeout
                    $result.Details.Ports = $ports
                    
                    # Get connected devices on serial ports
                    $serialPorts = Invoke-DeviceApi -Uri "https://${IP}/api/v2/ports/serial" -Headers $headers -TimeoutSec $Timeout
                    foreach ($port in $serialPorts.ports) {
                        $result.SerialPorts[$port.id] = @{
                            Label    = $port.label
                            Mode     = $port.mode
                            Status   = $port.status
                            BaudRate = $port.baudrate
                        }
                    }
                }
                catch {
                    Write-Verbose "    OpenGear API auth failed: $_"
                    $result.Details.Note = "API authentication failed. Verify credentials."
                }
            }
            catch {
                $result.Error = $_.Exception.Message
            }
        }
        else {
            $result.Details.Note = "No credentials available for full discovery"
        }
    }
    else {
        $result.Status = "Unreachable"
        $result.Error = "Device not reachable on ports 443 or 80"
    }
    
    return $result
}

function Get-SwitchInventory {
    <#
    .SYNOPSIS
        Discovers network switches (Dell, Sodola, etc.) via REST API or SNMP.
    #>
    param(
        [string]$IP,
        [string]$Credential,
        [string]$DeviceName,
        [hashtable]$DeviceConfig
    )
    
    $result = @{
        Type           = $DeviceConfig.type
        IP             = $IP
        Role           = $DeviceConfig.role
        VLAN           = $DeviceConfig.vlan
        LastDiscovered = (Get-Date -Format "o")
        Status         = "Unknown"
        Details        = @{}
        Ports          = @{}
    }
    
    # Check if device is marked as manual discovery only (no API/SSH/SNMP)
    if ($DeviceConfig.discovery -eq "manual") {
        $result.Details.Management = $DeviceConfig.management ?? "Web UI only"
        $result.Details.Note = "Device marked as manual discovery - no API, SSH, or SNMP support. Checking reachability only."
    }
    
    # Check reachability on common switch management ports
    $webReachable = Test-DeviceReachable -IP $IP -Port 443
    if (-not $webReachable) {
        $webReachable = Test-DeviceReachable -IP $IP -Port 80
    }
    $sshReachable = Test-DeviceReachable -IP $IP -Port 22
    
    if ($webReachable -or $sshReachable) {
        $result.Status = "Reachable"
        $result.Details.WebUI = $webReachable
        $result.Details.SSH = $sshReachable
        
        # Copy port configuration from infrastructure.yml if available
        if ($DeviceConfig.ports) {
            $result.Details.ConfiguredPorts = $DeviceConfig.ports
            if ($DeviceConfig.discovery -ne "manual") {
                $result.Details.Note = "Port configuration from infrastructure.yml. Live discovery requires vendor-specific API."
            }
        }
        
        # Note management method
        if ($DeviceConfig.management -and -not $result.Details.Management) {
            $result.Details.Management = $DeviceConfig.management
        }
    }
    else {
        $result.Status = "Unreachable"
        $result.Error = "Device not reachable on ports 443, 80, or 22"
    }
    
    return $result
}

function Get-SNMPInventory {
    <#
    .SYNOPSIS
        Discovers generic devices via SNMP.
    #>
    param(
        [string]$IP,
        [string]$Community = "public",
        [string]$DeviceName,
        [hashtable]$DeviceConfig
    )
    
    $result = @{
        Type           = $DeviceConfig.type ?? "Unknown"
        IP             = $IP
        Role           = $DeviceConfig.role
        LastDiscovered = (Get-Date -Format "o")
        Status         = "Unknown"
        Details        = @{}
    }
    
    # Check if device is reachable
    $reachable = Test-DeviceReachable -IP $IP -Port 161 -TimeoutMs 2000
    
    if (-not $reachable) {
        # SNMP uses UDP, so TCP check won't work - try a basic ping
        $pingResult = Test-Connection -ComputerName $IP -Count 1 -Quiet -TimeoutSeconds 2
        $reachable = $pingResult
    }
    
    if ($reachable) {
        $result.Status = "Reachable"
        $result.Details.Note = "SNMP discovery requires additional modules. Device responded to connectivity check."
        
        # TODO: Implement SNMP queries using SNMPv3 module or snmpget utility
        # Common SNMP OIDs:
        # - sysDescr: 1.3.6.1.2.1.1.1.0
        # - sysName: 1.3.6.1.2.1.1.5.0
        # - sysUpTime: 1.3.6.1.2.1.1.3.0
    }
    else {
        $result.Status = "Unreachable"
        $result.Error = "Device did not respond to connectivity check"
    }
    
    return $result
}

#endregion

#region Main Discovery Logic

function Start-OnPremDiscovery {
    <#
    .SYNOPSIS
        Main discovery orchestration function.
    #>
    
    Write-Banner "On-Premises Infrastructure Discovery v$ScriptVersion"
    
    # Initialize result structure
    $inventory = @{
        Metadata = @{
            CollectedAt        = (Get-Date -Format "o")
            CollectedBy        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            Hostname           = $env:COMPUTERNAME
            ScriptVersion      = $ScriptVersion
            DevicesScanned     = 0
            DevicesSuccessful  = 0
            DevicesFailed      = 0
            DevicesUnreachable = 0
        }
        Devices  = @{}
        Errors   = @()
    }
    
    # Load infrastructure configuration
    Write-Host "Loading infrastructure configuration..." -ForegroundColor Cyan
    Write-Host "  File: $InfrastructureFile" -ForegroundColor Gray
    
    try {
        $config = Get-InfrastructureConfig -Path $InfrastructureFile
        $networkDevices = $config.networking.onprem.network_devices
        
        if (-not $networkDevices -or $networkDevices.Count -eq 0) {
            throw "No network_devices found in infrastructure.yml"
        }
        
        Write-Host "  Found $($networkDevices.Count) network device(s)" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to load infrastructure configuration: $_"
        return
    }
    
    # Connect to Azure for Key Vault access
    $kvConnected = $false
    if (-not $SkipKeyVault) {
        Write-Host ""
        Write-Host "Connecting to Azure for Key Vault access..." -ForegroundColor Cyan
        
        try {
            $context = Get-AzContext
            if (-not $context) {
                Write-Host "  No Azure context found. Attempting to connect..." -ForegroundColor Yellow
                Connect-AzAccount -ErrorAction Stop | Out-Null
            }
            Write-Host "  Connected as: $($context.Account.Id)" -ForegroundColor Green
            $kvConnected = $true
        }
        catch {
            Write-Warning "Could not connect to Azure: $_"
            Write-Host "  Continuing without Key Vault access" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ""
        Write-Host "Skipping Key Vault authentication (-SkipKeyVault specified)" -ForegroundColor Yellow
    }
    
    # Filter devices based on parameters
    $devicesToScan = @{}
    
    foreach ($deviceName in $networkDevices.Keys) {
        $deviceConfig = $networkDevices[$deviceName]
        $include = $true
        
        # Filter by device name
        if ($DeviceName -and $deviceName -notin $DeviceName) {
            $include = $false
        }
        
        # Filter by device IP
        if ($DeviceIP -and $deviceConfig.ip -notin $DeviceIP) {
            $include = $false
        }
        
        # Filter by device type
        if ($DeviceType -notcontains "all") {
            $mappedType = $DeviceTypeMap[$deviceConfig.type] ?? "unknown"
            if ($mappedType -notin $DeviceType) {
                $include = $false
            }
        }
        
        if ($include) {
            $devicesToScan[$deviceName] = $deviceConfig
        }
    }
    
    if ($devicesToScan.Count -eq 0) {
        Write-Warning "No devices match the specified filters"
        return
    }
    
    Write-Host ""
    Write-Host "Devices to scan: $($devicesToScan.Count)" -ForegroundColor Cyan
    foreach ($name in $devicesToScan.Keys) {
        Write-Host "  - $name ($($devicesToScan[$name].type))" -ForegroundColor Gray
    }
    
    # WhatIf mode - show what would be done
    if ($WhatIfPreference) {
        Write-Host ""
        Write-Host "WhatIf: Would discover the following devices:" -ForegroundColor Yellow
        foreach ($deviceName in $devicesToScan.Keys) {
            $deviceConfig = $devicesToScan[$deviceName]
            Write-Host "  - $deviceName" -ForegroundColor White
            Write-Host "      Type: $($deviceConfig.type)" -ForegroundColor Gray
            Write-Host "      IP: $($deviceConfig.ip)" -ForegroundColor Gray
            Write-Host "      Role: $($deviceConfig.role)" -ForegroundColor Gray
            if ($deviceConfig.api_key) {
                Write-Host "      Credentials: $($deviceConfig.api_key)" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-Host "Output would be written to: $OutputFile" -ForegroundColor Yellow
        return
    }
    
    # Discover each device
    Write-Host ""
    Write-Host "Starting device discovery..." -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($deviceName in $devicesToScan.Keys) {
        $deviceConfig = $devicesToScan[$deviceName]
        $ip = $deviceConfig.ip
        $deviceType = $DeviceTypeMap[$deviceConfig.type] ?? "snmp"
        
        Write-DeviceHeader -DeviceName $deviceName -DeviceType $deviceConfig.type -IP $ip
        
        $inventory.Metadata.DevicesScanned++
        
        # Check for missing IP address
        if ([string]::IsNullOrWhiteSpace($ip)) {
            $inventory.Metadata.DevicesFailed++
            $inventory.Devices[$deviceName] = @{
                Type           = $deviceConfig.type
                IP             = $null
                Role           = $deviceConfig.role
                LastDiscovered = (Get-Date -Format "o")
                Status         = "NoIPConfigured"
                Error          = "No IP address configured for this device in infrastructure.yml"
            }
            Write-Host "  ⚠ Status: " -NoNewline -ForegroundColor Yellow
            Write-Host "No IP configured - skipping" -ForegroundColor Yellow
            Write-Host ""
            continue
        }
        
        # Get credentials - support both api_key (single value) and credential_ref (username/password pair)
        $credential = $null
        $credentialPair = $null
        
        if ($kvConnected) {
            # First check for credential_ref (points to credentials section with username/password)
            if ($deviceConfig.credential_ref) {
                Write-Verbose "  Looking up credential_ref: $($deviceConfig.credential_ref)"
                $credentialPair = Get-DeviceCredentials -CredentialRef $deviceConfig.credential_ref -InfrastructureFile $InfrastructureFile -DefaultVaultName $KeyVaultName
            }
            # Then check for direct api_key
            elseif ($deviceConfig.api_key) {
                Write-Verbose "  Retrieving API key from Key Vault"
                $credential = Get-KeyVaultCredential -KeyVaultUri $deviceConfig.api_key -DefaultVaultName $KeyVaultName
            }
        }
        
        try {
            $deviceResult = switch ($deviceType) {
                "udm" {
                    Write-Host "  Discovering UniFi Dream Machine..." -ForegroundColor Gray
                    Get-UDMInventory -IP $ip -ApiKey $credential -DeviceName $deviceName -DeviceConfig $deviceConfig
                }
                "edgerouter" {
                    Write-Host "  Discovering EdgeRouter..." -ForegroundColor Gray
                    $cred = if ($credentialPair) { $credentialPair } else { $credential }
                    Get-EdgeRouterInventory -IP $ip -Credential $cred -DeviceName $deviceName -DeviceConfig $deviceConfig
                }
                "opengear" {
                    Write-Host "  Discovering OpenGear console server..." -ForegroundColor Gray
                    Get-OpenGearInventory -IP $ip -Credential $credentialPair -DeviceName $deviceName -DeviceConfig $deviceConfig
                }
                "switch" {
                    Write-Host "  Discovering switch..." -ForegroundColor Gray
                    Get-SwitchInventory -IP $ip -Credential $credential -DeviceName $deviceName -DeviceConfig $deviceConfig
                }
                default {
                    Write-Host "  Attempting generic discovery..." -ForegroundColor Gray
                    Get-SNMPInventory -IP $ip -Community $credential -DeviceName $deviceName -DeviceConfig $deviceConfig
                }
            }
            
            $inventory.Devices[$deviceName] = $deviceResult
            
            # Update counters
            switch ($deviceResult.Status) {
                "Online" {
                    $inventory.Metadata.DevicesSuccessful++
                    Write-Host "  ✓ Status: " -NoNewline -ForegroundColor Green
                    Write-Host "Online" -ForegroundColor Green
                }
                "Reachable" {
                    $inventory.Metadata.DevicesSuccessful++
                    Write-Host "  ✓ Status: " -NoNewline -ForegroundColor Yellow
                    Write-Host "Reachable (limited data)" -ForegroundColor Yellow
                }
                "PartialData" {
                    $inventory.Metadata.DevicesSuccessful++
                    Write-Host "  ~ Status: " -NoNewline -ForegroundColor Yellow
                    Write-Host "Partial Data" -ForegroundColor Yellow
                }
                "Unreachable" {
                    $inventory.Metadata.DevicesUnreachable++
                    Write-Host "  ✗ Status: " -NoNewline -ForegroundColor Red
                    Write-Host "Unreachable" -ForegroundColor Red
                }
                default {
                    $inventory.Metadata.DevicesFailed++
                    Write-Host "  ? Status: " -NoNewline -ForegroundColor Yellow
                    Write-Host $deviceResult.Status -ForegroundColor Yellow
                }
            }
            
            if ($deviceResult.Model) {
                Write-Host "  Model: $($deviceResult.Model)" -ForegroundColor Gray
            }
            if ($deviceResult.Firmware) {
                Write-Host "  Firmware: $($deviceResult.Firmware)" -ForegroundColor Gray
            }
        }
        catch {
            $inventory.Metadata.DevicesFailed++
            $inventory.Errors += @{
                Device    = $deviceName
                IP        = $ip
                Error     = $_.Exception.Message
                Timestamp = (Get-Date -Format "o")
            }
            Write-Host "  ✗ Error: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        Write-Host ""
    }
    
    # Write output file
    Write-Host "Writing inventory to: $OutputFile" -ForegroundColor Cyan
    
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    
    $inventory | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding UTF8
    
    # Summary
    Write-Host ""
    Write-Banner "Discovery Complete" "Green"
    Write-Host "Summary:" -ForegroundColor White
    Write-Host "  Devices Scanned:     $($inventory.Metadata.DevicesScanned)" -ForegroundColor Gray
    Write-Host "  Successful:          $($inventory.Metadata.DevicesSuccessful)" -ForegroundColor Green
    Write-Host "  Failed:              $($inventory.Metadata.DevicesFailed)" -ForegroundColor $(if ($inventory.Metadata.DevicesFailed -gt 0) { "Red" } else { "Gray" })
    Write-Host "  Unreachable:         $($inventory.Metadata.DevicesUnreachable)" -ForegroundColor $(if ($inventory.Metadata.DevicesUnreachable -gt 0) { "Yellow" } else { "Gray" })
    Write-Host ""
    Write-Host "Output: $OutputFile" -ForegroundColor Cyan
    Write-Host ""
    
    return $inventory
}

#endregion

# Execute discovery
Start-OnPremDiscovery
