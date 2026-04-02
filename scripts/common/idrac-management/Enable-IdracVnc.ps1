<#
.SYNOPSIS
    Enables and configures VNC access on Dell iDRAC via Redfish API.

.DESCRIPTION
    Configures Dell iDRAC virtual console access via VNC using the Redfish API.
    Supports two modes of operation:

    Config-driven mode (recommended):
      Reads iDRAC IPs, credentials, and VNC settings from infrastructure.yml.
      Iterates over all nodes (or a filtered subset via -TargetNode).

    Standalone mode:
      Targets a single iDRAC IP with explicit parameters.

    infrastructure.yml paths used:
      security.infrastructure_credentials.idrac.username         - iDRAC admin username
      security.infrastructure_credentials.idrac.password_secret  - iDRAC password (keyvault:// URI)
      security.infrastructure_credentials.idrac.vnc.enabled      - VNC enable flag
      security.infrastructure_credentials.idrac.vnc.port         - VNC port
      security.infrastructure_credentials.idrac.vnc.timeout_seconds - VNC session timeout
      security.infrastructure_credentials.idrac.vnc.password_secret - VNC password (keyvault:// URI)
      compute.cluster_nodes.<key>.idrac_ip                               - Per-node iDRAC IP
      compute.cluster_nodes.<key>.hostname                               - Node hostname (display)

.PARAMETER ConfigPath
    Path to the infrastructure.yml configuration file.
    When provided, enables config-driven mode (reads credentials and VNC settings from YAML).

.PARAMETER Credential
    PSCredential for iDRAC authentication. Overrides Key Vault and config-based credential resolution.

.PARAMETER TargetNode
    One or more node hostnames to target. Empty = all nodes from config. Only used in config-driven mode.

.PARAMETER LogPath
    Override the default log file path. When omitted, logs to:
    ./logs/idrac-management/<date>_<time>_EnableVnc.log

.PARAMETER IdracIP
    The IP address of a single iDRAC interface (standalone mode).
    Not required when using -ConfigPath (IPs are read from compute.nodes.<key>.idrac_ip).

.PARAMETER Username
    The iDRAC username (standalone mode only; default: root).
    In config-driven mode, read from security.infrastructure_credentials.idrac.username.

.PARAMETER VNCPort
    The TCP port for VNC connections (default: 5901).
    In config-driven mode, read from security.infrastructure_credentials.idrac.vnc.port.

.PARAMETER EnableVNC
    Enable or disable VNC access. Valid values: Enabled, Disabled (default: Enabled).
    In config-driven mode, derived from security.infrastructure_credentials.idrac.vnc.enabled.

.PARAMETER VNCTimeout
    VNC session timeout in seconds (default: 1800 = 30 minutes, max: 10800 = 3 hours).
    In config-driven mode, read from security.infrastructure_credentials.idrac.vnc.timeout_seconds.

.PARAMETER VNCPassword
    Password for VNC authentication (required for third-party VNC clients like Devolutions RDM).
    If not specified, VNC password will not be set/changed.
    In config-driven mode, resolved from security.infrastructure_credentials.idrac.vnc.password_secret.

.PARAMETER IgnoreCertificateErrors
    Ignore SSL certificate validation errors (useful for self-signed iDRAC certificates).

.EXAMPLE
    .\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml"
    Config-driven: enables VNC on all nodes using YAML settings and Key Vault credentials.

.EXAMPLE
    .\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml" -TargetNode "node-01"
    Config-driven: targets only a specific node.

.EXAMPLE
    .\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml" -WhatIf
    Config-driven dry run: shows what would be configured without making changes.

.EXAMPLE
    .\Enable-IdracVnc.ps1 -IdracIP "10.0.0.11" -Credential (Get-Credential) -IgnoreCertificateErrors
    Standalone mode: prompts for credentials interactively.

.NOTES
    File Name      : Enable-IdracVnc.ps1
    Author         : AzureLocal Cloud Team Team
    Prerequisite   : Dell iDRAC 9 or later, PowerShell 5.1 or later
    Copyright      : Azure Local Cloud
    Version        : 2.0.0
    Created        : 2026-01-20
    Updated        : 2026-03-28

.LINK
    https://www.dell.com/support/manuals/en-us/idrac9-lifecycle-controller-v3.x-series/idrac_3.30.30.30_redfishapiguide/
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Path to the infrastructure.yml configuration file")]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false, HelpMessage = "PSCredential for iDRAC authentication (overrides Key Vault)")]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false, HelpMessage = "Node hostnames to target (empty = all nodes from config)")]
    [string[]]$TargetNode = @(),

    [Parameter(Mandatory = $false, HelpMessage = "Override log file path")]
    [string]$LogPath = "",

    [Parameter(Mandatory = $false, HelpMessage = "The IP address of a single iDRAC interface (standalone mode)")]
    [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}$')]
    [string]$IdracIP,

    [Parameter(Mandatory = $false, HelpMessage = "The iDRAC username (standalone mode; default: root)")]
    [string]$Username = "root",

    [Parameter(Mandatory = $false, HelpMessage = "The TCP port for VNC connections")]
    [ValidateRange(1, 65535)]
    [int]$VNCPort = 5901,

    [Parameter(Mandatory = $false, HelpMessage = "Enable or disable VNC access")]
    [ValidateSet("Enabled", "Disabled")]
    [string]$EnableVNC = "Enabled",

    [Parameter(Mandatory = $false, HelpMessage = "VNC session timeout in seconds")]
    [ValidateRange(60, 10800)]
    [int]$VNCTimeout = 1800,

    [Parameter(Mandatory = $false, HelpMessage = "Password for VNC authentication (required for third-party VNC clients)")]
    [ValidateLength(4, 8)]
    [string]$VNCPassword,

    [Parameter(Mandatory = $false, HelpMessage = "Ignore SSL certificate validation errors")]
    [switch]$IgnoreCertificateErrors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
# LOGGING (self-contained — per toolkit standard for orchestration scripts)
# ============================================================================
$script:LogPath = ""

function Start-LogFile {
    param([string]$Path)
    $script:LogPath = $Path
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [INFO ] Log started: $Path" | Tee-Object -FilePath $Path -Append | Out-Null
}

function Write-Log {
    param(
        [ValidateSet("Info","Warning","Error","Debug")][string]$Level = "Info",
        [string]$Message
    )
    $ts   = [datetime]::Now.ToString("yyyy-MM-dd HH:mm:ss")
    $tag  = $Level.ToUpper().PadRight(5)
    $line = "[$ts] [$tag] $Message"
    switch ($Level) {
        "Warning" { Write-Warning $Message }
        "Error"   { Write-Error   $Message -ErrorAction Continue }
        "Debug"   { Write-Debug   $Message }
        default   { Write-Host    $line }
    }
    if ($script:LogPath) { $line | Out-File -FilePath $script:LogPath -Append }
}

function Write-LogSection {
    param([string]$Title)
    $bar = "=" * 76
    Write-Log -Level Info -Message $bar
    Write-Log -Level Info -Message "  $Title"
    Write-Log -Level Info -Message $bar
}

function Stop-LogFile {
    Write-Log -Level Info -Message "Log complete: $script:LogPath"
}

# ============================================================================
# LOGGING SETUP
# ============================================================================
$taskFolderName = "idrac-management"
if ($LogPath -eq "") {
    $dateStamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $logDir    = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $LogPath   = Join-Path $logDir "${dateStamp}_EnableVnc.log"
}
Start-LogFile -Path $LogPath

Write-LogSection -Title "Enable-IdracVnc — iDRAC VNC Configuration"

# ============================================================================
# CREDENTIAL RESOLUTION HELPER
# ============================================================================
function Resolve-KeyVaultRef {
    <#
    .SYNOPSIS
        Resolves a keyvault:// URI to a plaintext secret value.
        Tries Az.KeyVault first, then az CLI fallback all per credential resolution order.
    #>
    param([Parameter(Mandatory)][string]$KvUri)

    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]

    Write-Log -Level Info -Message "  Resolving secret '$secretName' from Key Vault '$vaultName'..."

    # Attempt 1: Az.KeyVault module
    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { return $secret }
            Write-Log -Level Warning -Message "  Az.KeyVault returned no value for '$secretName'."
        }
        catch {
            Write-Log -Level Warning -Message "  Az.KeyVault failed: $($_.Exception.Message)"
        }
    }

    # Attempt 2: az CLI fallback
    try {
        $azOut = & az keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $azOut) { return ($azOut | Out-String).Trim() }
        $errDetail = if ($azOut) { ": $azOut" } else { " (exit $LASTEXITCODE)" }
        Write-Log -Level Warning -Message "  az CLI failed$errDetail."
        return $null
    }
    catch {
        Write-Log -Level Warning -Message "  az CLI exception: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================================
# CERTIFICATE HANDLING
# ============================================================================
if ($IgnoreCertificateErrors) {
    Write-Log -Level Warning -Message "Ignoring SSL certificate validation errors"

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
    }
    else {
        # Legacy approach for Windows PowerShell 5.1
        if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {
            Add-Type @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback
{
    public static void Ignore()
    {
        ServicePointManager.ServerCertificateValidationCallback +=
            delegate
            (
                Object obj,
                X509Certificate certificate,
                X509Chain chain,
                SslPolicyErrors errors
            )
            {
                return true;
            };
    }
}
"@
        }
        [ServerCertificateValidationCallback]::Ignore()
    }
}

# ============================================================================
# BUILD TARGET LIST
# ============================================================================
$targets = @()   # Array of [PSCustomObject]@{ Hostname; IdracIP }

if ($ConfigPath -ne "") {
    # --- Config-driven mode ---
    Write-Log -Level Info -Message "Config-driven mode: loading $ConfigPath"

    if (-not (Get-Module -Name powershell-yaml -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Log -Level Warning -Message "Installing powershell-yaml module..."
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

    # --- Read iDRAC credential settings from config ---
    $idracCfg  = $cfg.security.infrastructure_credentials.idrac             # security.infrastructure_credentials.idrac
    $cfgUser   = $idracCfg.username                                         # security.infrastructure_credentials.idrac.username
    $cfgPassUri = $idracCfg.password_secret                                 # security.infrastructure_credentials.idrac.password_secret

    # --- Read VNC settings from config (YAML-overridable defaults) ---
    $vncCfg = $idracCfg.vnc                                                # security.infrastructure_credentials.idrac.vnc
    if (-not $PSBoundParameters.ContainsKey('EnableVNC')) {
        $EnableVNC = if ($vncCfg.enabled -eq $true) { "Enabled" } else { "Disabled" }  # .vnc.enabled
    }
    if (-not $PSBoundParameters.ContainsKey('VNCPort')) {
        $VNCPort = [int]$vncCfg.port                                       # .vnc.port
    }
    if (-not $PSBoundParameters.ContainsKey('VNCTimeout')) {
        $VNCTimeout = [int]$vncCfg.timeout_seconds                         # .vnc.timeout_seconds
    }
    if (-not $PSBoundParameters.ContainsKey('VNCPassword') -and $vncCfg.password_secret) {
        $resolvedVncPass = Resolve-KeyVaultRef -KvUri $vncCfg.password_secret  # .vnc.password_secret
        if ($resolvedVncPass) { $VNCPassword = $resolvedVncPass }
    }

    # --- Resolve iDRAC credentials (credential resolution order) ---
    if (-not $Credential) {
        Write-Log -Level Info -Message "Resolving iDRAC credentials..."
        # Step 2: Key Vault lookup — secret stored as "username:password"
        $kvValue = Resolve-KeyVaultRef -KvUri $cfgPassUri
        if ($kvValue) {
            $idx = $kvValue.IndexOf(":")
            if ($idx -gt 0) {
                $cfgUser    = $kvValue.Substring(0, $idx)
                $kvPassword = $kvValue.Substring($idx + 1)
            } else {
                $kvPassword = $kvValue
            }
            $secPass    = ConvertTo-SecureString $kvPassword -AsPlainText -Force
            $Credential = New-Object PSCredential($cfgUser, $secPass)
            Write-Log -Level Info -Message "Credentials resolved from Key Vault for '$cfgUser'."
        }
        else {
            # Step 3: Interactive prompt
            Write-Log -Level Warning -Message "Key Vault unavailable — prompting for iDRAC credentials."
            $Credential = Get-Credential -Message "Enter iDRAC credentials" -UserName $cfgUser
        }
    }

    # --- Build node target list from compute.cluster_nodes ---
    $nodeEntries = $cfg.compute.cluster_nodes                               # compute.cluster_nodes
    if (-not $nodeEntries) {
        throw "No nodes found under compute.cluster_nodes in $ConfigPath."
    }

    foreach ($entry in $nodeEntries.GetEnumerator()) {
        $hostname = $entry.Key                                              # compute.cluster_nodes.<key>
        $nodeIp   = $entry.Value.idrac_ip                                   # compute.cluster_nodes.<key>.idrac_ip

        if ($TargetNode.Count -gt 0 -and $hostname -notin $TargetNode) {
            Write-Log -Level Debug -Message "Skipping $hostname (not in TargetNode filter)"
            continue
        }
        if (-not $nodeIp) {
            Write-Log -Level Warning -Message "[$hostname] idrac_ip missing — skipping"
            continue
        }

        $targets += [PSCustomObject]@{ Hostname = $hostname; IdracIP = $nodeIp }
    }

    if ($targets.Count -eq 0) {
        throw "No matching nodes found. Check -TargetNode filter or compute.nodes entries."
    }

    Write-Log -Level Info -Message "Targets: $($targets.Count) node(s)"
}
elseif ($IdracIP) {
    # --- Standalone mode ---
    Write-Log -Level Info -Message "Standalone mode: targeting $IdracIP"

    if (-not $Credential) {
        # Step 3: Interactive prompt (no config available for Key Vault)
        Write-Log -Level Warning -Message "No -Credential provided — prompting."
        $Credential = Get-Credential -Message "Enter iDRAC credentials" -UserName $Username
    }

    $targets += [PSCustomObject]@{ Hostname = $IdracIP; IdracIP = $IdracIP }
}
else {
    throw "Specify either -ConfigPath for config-driven mode or -IdracIP for standalone mode."
}

# ============================================================================
# COMMON API SETTINGS
# ============================================================================
$Headers = @{ "Accept" = "application/json" }

# ============================================================================
# CONFIGURE VNC ON EACH TARGET
# ============================================================================
$results = @()

foreach ($target in $targets) {
    $ip       = $target.IdracIP
    $hostname = $target.Hostname
    $BaseUri  = "https://$ip/redfish/v1"
    $AttrUri  = "$BaseUri/Managers/iDRAC.Embedded.1/Attributes"

    Write-Log -Level Info -Message "[$hostname] Processing iDRAC at $ip..."

    try {
        # --- Query current attributes ---
        if ($PSCmdlet.ShouldProcess($ip, "Query current iDRAC VNC attributes")) {
            Write-Log -Level Info -Message "[$hostname] Querying current VNC attributes..."

            $CurrentAttrs = Invoke-RestMethod `
                -Method GET `
                -Uri $AttrUri `
                -Credential $Credential `
                -Headers $Headers `
                -SkipCertificateCheck `
                -ErrorAction Stop

            Write-Log -Level Debug -Message "[$hostname] Current VNC Enable : $($CurrentAttrs.Attributes.'VNCServer.1.Enable')"
            Write-Log -Level Debug -Message "[$hostname] Current VNC Port   : $($CurrentAttrs.Attributes.'VNCServer.1.Port')"
            Write-Log -Level Debug -Message "[$hostname] Current VNC Timeout: $($CurrentAttrs.Attributes.'VNCServer.1.Timeout')s"
        }

        # --- Build configuration payload ---
        $PayloadAttrs = @{
            "VNCServer.1.Enable"               = $EnableVNC
            "VNCServer.1.Port"                 = $VNCPort
            "VNCServer.1.Timeout"              = $VNCTimeout
            "VirtualConsole.1.AccessPrivilege" = "Administrator"
        }

        if ($VNCPassword) {
            $PayloadAttrs["VNCServer.1.Password"] = $VNCPassword
            Write-Log -Level Debug -Message "[$hostname] VNC password will be set"
        }

        $Payload = @{ "Attributes" = $PayloadAttrs } | ConvertTo-Json -Depth 5

        # --- Apply VNC configuration ---
        if ($PSCmdlet.ShouldProcess($ip, "Apply VNC configuration (Enable: $EnableVNC, Port: $VNCPort, Timeout: $VNCTimeout)")) {
            Write-Log -Level Info -Message "[$hostname] Applying VNC configuration..."

            $Response = Invoke-RestMethod `
                -Method PATCH `
                -Uri $AttrUri `
                -Credential $Credential `
                -Headers $Headers `
                -ContentType "application/json" `
                -Body $Payload `
                -SkipCertificateCheck `
                -ErrorAction Stop

            Write-Log -Level Info -Message "[$hostname] VNC configuration applied successfully."

            if ($Response.PSObject.Properties['@Message.ExtendedInfo'] -and $Response.'@Message.ExtendedInfo') {
                foreach ($message in $Response.'@Message.ExtendedInfo') {
                    Write-Log -Level Warning -Message "[$hostname] $($message.Message)"
                }
                Write-Log -Level Warning -Message "[$hostname] An iDRAC reset may be required for changes to take effect."
            }

            # Summary for this node
            Write-Log -Level Info -Message "[$hostname] Summary — Status: $EnableVNC | Port: $VNCPort | Timeout: ${VNCTimeout}s ($([math]::Round($VNCTimeout/60,1))m) | VNC Password: $(if ($VNCPassword) {'Set'} else {'Unchanged'})"

            $results += [PSCustomObject]@{
                Node    = $hostname
                IP      = $ip
                Status  = "PASS"
                Detail  = "$EnableVNC port:$VNCPort timeout:${VNCTimeout}s"
            }
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDesc = if ($_.Exception.Response.PSObject.Properties['StatusDescription']) { $_.Exception.Response.StatusDescription } else { $_.Exception.Response.StatusCode }
        Write-Log -Level Error -Message "[$hostname] Failed to configure VNC: $_"
        if ($statusCode) {
            Write-Log -Level Error -Message "[$hostname] HTTP $statusCode $statusDesc"
        }

        $results += [PSCustomObject]@{
            Node    = $hostname
            IP      = $ip
            Status  = "FAIL"
            Detail  = "$_"
        }
    }
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-LogSection -Title "VNC Configuration Results"
$results | Format-Table Node, IP, Status, Detail -AutoSize | Out-String | ForEach-Object { Write-Log -Level Info -Message $_ }

$failCount = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
if ($failCount -eq 0) {
    Write-Log -Level Info -Message "All $($results.Count) node(s) configured successfully."
}
else {
    Write-Log -Level Error -Message "$failCount of $($results.Count) node(s) failed. Review log output above."
}

Stop-LogFile

if ($failCount -gt 0) {
    throw "$failCount node(s) failed VNC configuration. See log: $LogPath"
}
