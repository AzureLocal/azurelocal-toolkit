#Requires -Version 7.0
<#
.SYNOPSIS
    Invoke-EnableRdp-Orchestrated.ps1
    Enables RDP on all Azure Local nodes from the management server.

.DESCRIPTION
    Runs from the management server. Reads node IPs from infrastructure.yml and
    pushes RDP enablement to each node via PSRemoting (WinRM must already be
    enabled — Task 01).

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-detected from .\configs\ if not specified.

.PARAMETER NodeNames
    Specific node names to target. Default: all nodes in infrastructure.yml.

.PARAMETER Credential
    PSCredential for PSRemoting. Prompted if not provided.

.EXAMPLE
    .\Invoke-EnableRdp-Orchestrated.ps1 -ConfigPath ".\configs\infrastructure.yml"

.EXAMPLE
    .\Invoke-EnableRdp-Orchestrated.ps1 -ConfigPath ".\configs\infrastructure.yml" -NodeNames "node01","node02"

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-02-enable-rdp
    Prerequisites: PowerShell 7+, powershell-yaml module, WinRM enabled on nodes (Task 01)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER"  { "Cyan" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Resolve-ConfigPath {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "Config not found: $ExplicitPath" }
        Write-Log "Using specified config: $ExplicitPath"
        return $ExplicitPath
    }

    $candidates = @(Get-ChildItem -Path ".\configs\" -Filter "infrastructure*.yml" -ErrorAction SilentlyContinue)
    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No infrastructure*.yml found in .\configs\. Use -ConfigPath."
    }
    if ($candidates.Count -eq 1) {
        Write-Log "Auto-detected config: $($candidates[0].FullName)"
        return $candidates[0].FullName
    }

    Write-Host "`nMultiple config files found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $default = if ($candidates[$i].Name -eq "infrastructure.yml") { " [DEFAULT]" } else { "" }
        Write-Host "  [$($i+1)] $($candidates[$i].Name)$default"
    }
    $defaultIdx = [array]::IndexOf(($candidates | ForEach-Object { $_.Name }), "infrastructure.yml")
    if ($defaultIdx -lt 0) { $defaultIdx = 0 }
    $sel = Read-Host "`nSelect config (Enter for default [$($candidates[$defaultIdx].Name)])"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $candidates[$defaultIdx].FullName }
    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $candidates.Count) { throw "Invalid selection: $sel" }
    return $candidates[$idx].FullName
}

function Resolve-KeyVaultRef {
    # Reads a secret reference through the toolkit's one secret resolver (AzlSecret.psm1): any provider, no Azure CLI.
    # Returns the text, or $null when it cannot be read; the caller then falls back as before. No value is logged.
    param([string]$KvUri)
    if (-not (Get-AzlSecretProvider -Reference $KvUri)) { Write-Log "  The value is not a secret reference." "WARN"; return $null }
    try {
        $value = Get-AzlSecretPlainText -Reference $KvUri -Infrastructure $script:SecretInfrastructure
        Write-Log "  Secret retrieved." "SUCCESS"
        return $value
    }
    catch { Write-Log "  The secret could not be read: $($_.Exception.Message)" "WARN"; return $null }
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Enable RDP on Azure Local Nodes ===" "HEADER"

    Import-Module powershell-yaml -ErrorAction Stop

    $resolvedConfig = Resolve-ConfigPath -ExplicitPath $ConfigPath
    $config = Get-Content $resolvedConfig -Raw | ConvertFrom-Yaml
    $script:SecretInfrastructure = $config

    # Build node list
    $allNodes = Get-AzlInfrastructureNode -Infrastructure $config | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            IP   = $_.ManagementIp
        }
    }

    if ($NodeNames) {
        $allNodes = $allNodes | Where-Object { $NodeNames -contains $_.Name }
    }

    if (-not $allNodes) { throw "No nodes found to target." }

    Write-Log "Targeting $($allNodes.Count) node(s): $($allNodes.Name -join ', ')"

    if (-not $Credential) {
        $adminUser    = $config.identity.local_admin.username
        $adminPassUri = $config.identity.local_admin.password
        Write-Log "Resolving credentials from Key Vault..."
        $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
        if ($adminPass) {
            $Credential = New-Object PSCredential(
                $adminUser,
                (ConvertTo-SecureString $adminPass -AsPlainText -Force)
            )
            Write-Log "Credentials resolved for '$adminUser'." "SUCCESS"
        } else {
            Write-Log "Key Vault unavailable — prompting for credentials." "WARN"
            $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $adminUser
        }
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($node in $allNodes) {
        Write-Log "Enabling RDP on $($node.Name) ($($node.IP))..." "HEADER"

        try {
            $result = Invoke-Command -ComputerName $node.IP -Credential $Credential -ErrorAction Stop -ScriptBlock {
                Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                    -Name "fDenyTSConnections" -Value 0

                Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

                $rdp = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                    -Name "fDenyTSConnections").fDenyTSConnections

                [PSCustomObject]@{
                    Hostname   = $env:COMPUTERNAME
                    RDPEnabled = ($rdp -eq 0)
                }
            }

            if ($result.RDPEnabled) {
                Write-Log "  $($node.Name) ($($result.Hostname)): RDP enabled" "SUCCESS"
                $results.Add([PSCustomObject]@{ Node = $node.Name; IP = $node.IP; Status = "OK" })
            } else {
                Write-Log "  $($node.Name): RDP not enabled" "ERROR"
                $results.Add([PSCustomObject]@{ Node = $node.Name; IP = $node.IP; Status = "FAILED" })
            }
        } catch {
            Write-Log "  $($node.Name): $_" "ERROR"
            $results.Add([PSCustomObject]@{ Node = $node.Name; IP = $node.IP; Status = "ERROR: $_" })
        }
    }

    Write-Log ""
    Write-Log "=== SUMMARY ===" "HEADER"
    $results | ForEach-Object {
        $level = if ($_.Status -eq "OK") { "SUCCESS" } else { "ERROR" }
        Write-Log "  $($_.Node) ($($_.IP)): $($_.Status)" $level
    }

    $failed = @($results | Where-Object { $_.Status -ne "OK" })
    if ($failed.Count -gt 0) {
        Write-Log "$($failed.Count) node(s) failed — review errors above" "WARN"
        exit 1
    }

    Write-Log "RDP enabled on all $($results.Count) node(s)" "SUCCESS"

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
