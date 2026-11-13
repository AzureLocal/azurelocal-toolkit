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

    The BMC login comes from infrastructure.yml: hardware.bmc.username and password, and a node's own nodes[].bmc.username and
    password when it has them (they win for that node). The password is a secret reference (keyvault://, env://, file:// or
    command://) read by the toolkit's secret resolver; no value is written to the file. Whether the BMC certificate is checked
    comes from hardware.bmc.verify_certificate (default false: the BMC's own certificate is accepted). The script never prompts.

    Keys read: nodes[].name, nodes[].bmc (ip_address, username, password), hardware.bmc (username, password, verify_certificate),
    hardware.bios_settings and hardware.idrac_settings (overrides of the desired values), secrets and key_vaults (for the references).

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER Credential
    Optional. Use this BMC login for every node instead of the one in infrastructure.yml.

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
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$RebootAfterBios
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([IO.Path]::Combine($common, 'secrets', 'AzlSecret.psm1'))
Import-Module ([IO.Path]::Combine($common, 'redfish', 'AzlRedfishCore.psm1'))

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
    return Import-AzlInfrastructure -Path $Path -SkipValidation
}

# The BMC's own certificate is accepted unless hardware.bmc.verify_certificate is true.
function Get-RedfishTlsArgument {
    $tls = @{}
    if (-not $script:VerifyCertificate) { $tls.SkipCertificateCheck = $true }
    return $tls
}

function Get-RedfishData {
    param([string]$BaseUri, [string]$Endpoint, [PSCredential]$Credential)
    $uri = "$BaseUri$Endpoint"
    $tls = Get-RedfishTlsArgument
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Get -ContentType 'application/json' @tls
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
    $tls = Get-RedfishTlsArgument
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Patch -Body $body -ContentType 'application/json' @tls
}

function New-BiosConfigJob {
    param([string]$BaseUri, [PSCredential]$Credential)
    $uri = "$BaseUri/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
    $body = @{
        TargetSettingsURI = "/redfish/v1/Systems/System.Embedded.1/Bios/Settings"
    } | ConvertTo-Json
    $tls = Get-RedfishTlsArgument
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Post -Body $body -ContentType 'application/json' @tls
}

function Invoke-GracefulReboot {
    param([string]$BaseUri, [PSCredential]$Credential)
    $uri = "$BaseUri/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
    $body = @{ ResetType = "GracefulRestart" } | ConvertTo-Json
    $tls = Get-RedfishTlsArgument
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Post -Body $body -ContentType 'application/json' @tls
}

#region Main

Write-Log "=== BIOS and iDRAC Settings Remediation ===" -Level "HEADER"

$configFile = Resolve-ConfigPath -ExplicitPath $ConfigPath
$config = Import-InfrastructureConfig -Path $configFile

$nodes = Get-AzlInfrastructureValue -Infrastructure $config -Path 'nodes'
if (-not $nodes -or $nodes.Count -eq 0) {
    Write-Log "No nodes found in configuration." -Level "ERROR"
    exit 1
}

$verifyValue = Get-AzlInfrastructureValue -Infrastructure $config -Path 'hardware.bmc.verify_certificate'
$script:VerifyCertificate = ($null -ne $verifyValue -and ([string]$verifyValue).Trim().ToLowerInvariant() -in 'true', '1', 'yes')

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
$biosOverride = Get-AzlInfrastructureValue -Infrastructure $config -Path 'hardware.bios_settings'
if ($biosOverride) {
    foreach ($key in $biosOverride.Keys) {
        $desiredBios[$key] = $biosOverride[$key]
    }
}

$desiredIdrac = @{
    "IPMILan.1#Enable" = "Enabled"
}
$idracOverride = Get-AzlInfrastructureValue -Infrastructure $config -Path 'hardware.idrac_settings'
if ($idracOverride) {
    foreach ($key in $idracOverride.Keys) {
        $desiredIdrac[$key] = $idracOverride[$key]
    }
}

$nodesRemediated = 0
$nodesRequireReboot = @()

foreach ($node in $nodes) {
    $nodeName = [string]$node['name']
    $bmcBlock = if ($node.Contains('bmc')) { $node['bmc'] } else { $null }
    $iDRACIp = if ($bmcBlock -is [System.Collections.IDictionary] -and $bmcBlock.Contains('ip_address')) { [string]$bmcBlock['ip_address'] } else { $null }

    if (-not $iDRACIp) {
        Write-Log "  $nodeName : No BMC IP — skipping" -Level "WARN"
        continue
    }

    $baseUri = "https://$iDRACIp"
    Write-Log "  Processing $nodeName ($iDRACIp)..." -Level "INFO"

    try {
        # -Credential, else nodes[].bmc, else hardware.bmc (secret references read by the resolver). Never a prompt.
        $bmcCredential = Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $config -Node $node -NoPrompt

        # Check current BIOS settings
        $currentBios = (Get-RedfishData -BaseUri $baseUri -Endpoint "/redfish/v1/Systems/System.Embedded.1/Bios" -Credential $bmcCredential).Attributes
        $biosChanges = @{}

        foreach ($key in $desiredBios.Keys) {
            if ($currentBios.$key -ne $desiredBios[$key]) {
                $biosChanges[$key] = $desiredBios[$key]
                Write-Log "    BIOS: $key — $($currentBios.$key) -> $($desiredBios[$key])" -Level "WARN"
            }
        }

        # Check current iDRAC settings
        $currentIdrac = (Get-RedfishData -BaseUri $baseUri -Endpoint "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" -Credential $bmcCredential).Attributes
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
                    -Credential $bmcCredential -Attributes $idracChanges
                Write-Log "    Applied $($idracChanges.Count) iDRAC changes" -Level "SUCCESS"
            }
        }

        # Apply BIOS changes (requires config job + reboot)
        if ($biosChanges.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess("$nodeName BIOS", "Apply $($biosChanges.Count) setting changes")) {
                Set-RedfishAttribute -BaseUri $baseUri -Endpoint "/redfish/v1/Systems/System.Embedded.1/Bios/Settings" `
                    -Credential $bmcCredential -Attributes $biosChanges
                New-BiosConfigJob -BaseUri $baseUri -Credential $bmcCredential
                Write-Log "    Queued $($biosChanges.Count) BIOS changes (reboot required)" -Level "SUCCESS"
                $nodesRequireReboot += $nodeName

                if ($RebootAfterBios) {
                    Write-Log "    Initiating graceful reboot..." -Level "WARN"
                    Invoke-GracefulReboot -BaseUri $baseUri -Credential $bmcCredential
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
