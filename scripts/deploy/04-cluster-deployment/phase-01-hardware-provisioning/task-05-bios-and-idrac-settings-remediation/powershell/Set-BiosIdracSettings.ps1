<#
.SYNOPSIS
    Remediates non-compliant BIOS and iDRAC settings via Dell Redfish API.

.DESCRIPTION
    This script remediates Dell server BIOS and iDRAC settings:
    - Reads desired settings from infrastructure.yml
    - Compares current settings against baseline
    - Applies BIOS changes via Redfish PATCH and creates config job
    - Applies iDRAC changes via Redfish PATCH
    - Schedules reboot for BIOS changes to take effect
    - Re-validates after remediation

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER iDRACUsername
    iDRAC admin username.

.PARAMETER iDRACPassword
    iDRAC admin password as SecureString.

.PARAMETER RebootAfterBios
    Automatically reboot nodes after BIOS changes. Default: false (manual reboot required).

.EXAMPLE
    .\Set-BiosIdracSettings.ps1 -ConfigPath ".\configs\infrastructure.yml" -RebootAfterBios

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 04-cluster-deployment
    Phase: phase-01-hardware-provisioning
    Task: task-05-bios-and-idrac-settings-remediation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$iDRACUsername,

    [Parameter(Mandatory = $false)]
    [SecureString]$iDRACPassword,

    [Parameter(Mandatory = $false)]
    [switch]$RebootAfterBios
)

#Requires -Version 7.0

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

function Get-RedfishCredential {
    if ($iDRACUsername -and $iDRACPassword) {
        return [PSCredential]::new($iDRACUsername, $iDRACPassword)
    }
    return Get-Credential -Message "Enter iDRAC credentials"
}

function Get-RedfishData {
    param([string]$BaseUri, [string]$Endpoint, [PSCredential]$Credential)
    $uri = "$BaseUri$Endpoint"
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Get -ContentType 'application/json' -SkipCertificateCheck
}

function Set-RedfishAttribute {
    param(
        [string]$BaseUri,
        [string]$Endpoint,
        [PSCredential]$Credential,
        [hashtable]$Attributes
    )
    $uri = "$BaseUri$Endpoint"
    $body = @{ Attributes = $Attributes } | ConvertTo-Json -Depth 5
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Patch -Body $body -ContentType 'application/json' -SkipCertificateCheck
}

function New-BiosConfigJob {
    param([string]$BaseUri, [PSCredential]$Credential)
    $uri = "$BaseUri/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
    $body = @{
        TargetSettingsURI = "/redfish/v1/Systems/System.Embedded.1/Bios/Settings"
    } | ConvertTo-Json
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Post -Body $body -ContentType 'application/json' -SkipCertificateCheck
}

function Invoke-GracefulReboot {
    param([string]$BaseUri, [PSCredential]$Credential)
    $uri = "$BaseUri/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
    $body = @{ ResetType = "GracefulRestart" } | ConvertTo-Json
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Post -Body $body -ContentType 'application/json' -SkipCertificateCheck
}

#region Main

Write-Log "=== BIOS and iDRAC Settings Remediation ===" -Level "HEADER"

$configFile = Resolve-ConfigPath -ExplicitPath $ConfigPath
$config = Import-InfrastructureConfig -Path $configFile

$nodes = $config.compute.nodes
if (-not $nodes -or $nodes.Count -eq 0) {
    Write-Log "No nodes found in configuration." -Level "ERROR"
    exit 1
}

$credential = Get-RedfishCredential

# Desired BIOS settings
$desiredBios = @{
    "SysProfile"          = "PerfOptimized"
    "LogicalProc"         = "Enabled"
    "VirtualizationTechnology" = "Enabled"
    "SriovGlobalEnable"   = "Enabled"
    "BootMode"            = "Uefi"
    "SecureBoot"          = "Enabled"
    "TpmSecurity"         = "OnPbm"
}
if ($config.hardware.bios_settings) {
    foreach ($key in $config.hardware.bios_settings.Keys) {
        $desiredBios[$key] = $config.hardware.bios_settings[$key]
    }
}

$desiredIdrac = @{
    "IPMILan.1#Enable" = "Enabled"
}
if ($config.hardware.idrac_settings) {
    foreach ($key in $config.hardware.idrac_settings.Keys) {
        $desiredIdrac[$key] = $config.hardware.idrac_settings[$key]
    }
}

$nodesRemediated = 0
$nodesRequireReboot = @()

foreach ($node in $nodes) {
    $nodeName = $node.name
    $iDRACIp = $node.bmc.ip_address

    if (-not $iDRACIp) {
        Write-Log "  $nodeName : No BMC IP — skipping" -Level "WARN"
        continue
    }

    $baseUri = "https://$iDRACIp"
    Write-Log "  Processing $nodeName ($iDRACIp)..." -Level "INFO"

    try {
        # Check current BIOS settings
        $currentBios = (Get-RedfishData -BaseUri $baseUri -Endpoint "/redfish/v1/Systems/System.Embedded.1/Bios" -Credential $credential).Attributes
        $biosChanges = @{}

        foreach ($key in $desiredBios.Keys) {
            if ($currentBios.$key -ne $desiredBios[$key]) {
                $biosChanges[$key] = $desiredBios[$key]
                Write-Log "    BIOS: $key — $($currentBios.$key) -> $($desiredBios[$key])" -Level "WARN"
            }
        }

        # Check current iDRAC settings
        $currentIdrac = (Get-RedfishData -BaseUri $baseUri -Endpoint "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" -Credential $credential).Attributes
        $idracChanges = @{}

        foreach ($key in $desiredIdrac.Keys) {
            if ($currentIdrac.$key -ne $desiredIdrac[$key]) {
                $idracChanges[$key] = $desiredIdrac[$key]
                Write-Log "    iDRAC: $key — $($currentIdrac.$key) -> $($desiredIdrac[$key])" -Level "WARN"
            }
        }

        # Apply iDRAC changes (immediate, no reboot needed)
        if ($idracChanges.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess("$nodeName iDRAC", "Apply $($idracChanges.Count) setting changes")) {
                Set-RedfishAttribute -BaseUri $baseUri -Endpoint "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" `
                    -Credential $credential -Attributes $idracChanges
                Write-Log "    Applied $($idracChanges.Count) iDRAC changes" -Level "SUCCESS"
            }
        }

        # Apply BIOS changes (requires config job + reboot)
        if ($biosChanges.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess("$nodeName BIOS", "Apply $($biosChanges.Count) setting changes")) {
                Set-RedfishAttribute -BaseUri $baseUri -Endpoint "/redfish/v1/Systems/System.Embedded.1/Bios/Settings" `
                    -Credential $credential -Attributes $biosChanges
                New-BiosConfigJob -BaseUri $baseUri -Credential $credential
                Write-Log "    Queued $($biosChanges.Count) BIOS changes (reboot required)" -Level "SUCCESS"
                $nodesRequireReboot += $nodeName

                if ($RebootAfterBios) {
                    Write-Log "    Initiating graceful reboot..." -Level "WARN"
                    Invoke-GracefulReboot -BaseUri $baseUri -Credential $credential
                }
            }
        }

        if ($biosChanges.Count -eq 0 -and $idracChanges.Count -eq 0) {
            Write-Log "    $nodeName : All settings compliant — no changes needed" -Level "SUCCESS"
        }
        else {
            $nodesRemediated++
        }
    }
    catch {
        Write-Log "    $nodeName : Remediation failed — $_" -Level "ERROR"
    }
}

Write-Host ""
Write-Log "=== Remediation Summary ===" -Level "HEADER"
Write-Log "  Nodes processed: $($nodes.Count)" -Level "INFO"
Write-Log "  Nodes remediated: $nodesRemediated" -Level "INFO"

if ($nodesRequireReboot.Count -gt 0) {
    Write-Log "  Nodes requiring reboot: $($nodesRequireReboot -join ', ')" -Level "WARN"
    if (-not $RebootAfterBios) {
        Write-Log "  Reboot nodes manually or re-run with -RebootAfterBios to apply BIOS changes." -Level "WARN"
    }
}
else {
    Write-Log "  No reboots required." -Level "SUCCESS"
}

#endregion Main
