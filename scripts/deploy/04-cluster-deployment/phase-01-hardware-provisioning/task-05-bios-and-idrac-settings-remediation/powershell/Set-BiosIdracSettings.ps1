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
    hardware.bios and nodes[].bios (overrides of the desired BIOS values), secrets and key_vaults (for the references).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. Only the keys named above are read; the file is not validated here.

.PARAMETER Credential
    Optional. Use this BMC login for every node instead of the one in infrastructure.yml.

.PARAMETER RebootAfterBios
    Automatically reboot nodes after BIOS changes. Default: false (manual reboot required).

.EXAMPLE
    .\Set-BiosIdracSettings.ps1 -InfrastructureFile ".\infrastructure.yml" -RebootAfterBios

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 04-cluster-deployment
    Phase: phase-01-hardware-provisioning
    Task: task-05-bios-and-idrac-settings-remediation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$InfrastructureFile,

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

# Redfish resource paths of a Dell iDRAC. Fixed by Dell's iDRAC Redfish API: the manager is always iDRAC.Embedded.1 and the system is always System.Embedded.1.
# This script is for Dell iDRAC only.
$script:IdracManagerPath = '/redfish/v1/Managers/iDRAC.Embedded.1'
$script:IdracSystemPath = '/redfish/v1/Systems/System.Embedded.1'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; "SUCCESS" { "Green" }; "HEADER" { "Cyan" }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
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
    $uri = "$BaseUri$($script:IdracManagerPath)/Jobs"
    $body = @{
        TargetSettingsURI = "$($script:IdracSystemPath)/Bios/Settings"
    } | ConvertTo-Json
    $tls = Get-RedfishTlsArgument
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Post -Body $body -ContentType 'application/json' @tls
}

function Invoke-GracefulReboot {
    param([string]$BaseUri, [PSCredential]$Credential)
    $uri = "$BaseUri$($script:IdracSystemPath)/Actions/ComputerSystem.Reset"
    $body = @{ ResetType = "GracefulRestart" } | ConvertTo-Json
    $tls = Get-RedfishTlsArgument
    return Invoke-RestMethod -Uri $uri -Credential $Credential -Method Post -Body $body -ContentType 'application/json' @tls
}

#region Main

Write-Log "=== BIOS and iDRAC Settings Remediation ===" -Level "HEADER"

try { $config = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Write-Log "Cannot read the infrastructure file: $($_.Exception.Message)" -Level "ERROR"; exit 2 }

$nodes = Get-AzlInfrastructureValue -Infrastructure $config -Path 'nodes'
if (-not $nodes -or $nodes.Count -eq 0) {
    Write-Log "No nodes found in the infrastructure file." -Level "ERROR"
    exit 2
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
$biosOverride = Get-AzlInfrastructureValue -Infrastructure $config -Path 'hardware.bios'
if ($biosOverride) {
    foreach ($key in $biosOverride.Keys) {
        $desiredBios[$key] = $biosOverride[$key]
    }
}

# The iDRAC baseline is one attribute and it is not a choice of a deployment: IPMI over LAN must be on (Dell iDRAC attribute
# registry, attribute IPMILan.1#Enable). config/variables/docs/MIGRATION.md, To 5.6.21, Not keys, records why there is no key.
$IdracIpmiLanAttribute = 'IPMILan.1#Enable'
$IdracIpmiLanValue = 'Enabled'
$desiredIdrac = @{ $IdracIpmiLanAttribute = $IdracIpmiLanValue }

$nodesRemediated = 0
$nodesRequireReboot = @()
$nodesFailed = @()

foreach ($node in $nodes) {
    $nodeName = [string]$node['name']
    # The BIOS attributes of this machine: the baseline, then hardware.bios, then nodes[].bios (the key of the node wins).
    $nodeBios = $desiredBios.Clone()
    if ($node.Contains('bios') -and $node['bios'] -is [System.Collections.IDictionary]) {
        foreach ($key in $node['bios'].Keys) { $nodeBios[$key] = $node['bios'][$key] }
    }
    $bmcBlock = if ($node.Contains('bmc')) { $node['bmc'] } else { $null }
    $iDRACIp = if ($bmcBlock -is [System.Collections.IDictionary] -and $bmcBlock.Contains('ip_address')) { [string]$bmcBlock['ip_address'] } else { $null }

    if (-not $iDRACIp) {
        Write-Log "  $nodeName : No BMC IP — skipping" -Level "WARN"
        continue
    }

    $baseUri = "https://$iDRACIp"
    Write-Log "  Processing $nodeName ($iDRACIp)..." -Level "INFO"

    try {
        # -Credential, else nodes[].bmc, else hardware.bmc (secret references read by the resolver). Never a prompt; with neither the node fails with the message that says what to pass.
        $bmcCredential = Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $config -Node $node

        # Check current BIOS settings
        $currentBios = (Get-RedfishData -BaseUri $baseUri -Endpoint "$($script:IdracSystemPath)/Bios" -Credential $bmcCredential).Attributes
        $biosChanges = @{}

        foreach ($key in $nodeBios.Keys) {
            if ($currentBios.$key -ne $nodeBios[$key]) {
                $biosChanges[$key] = $nodeBios[$key]
                Write-Log "    BIOS: $key — $($currentBios.$key) -> $($nodeBios[$key])" -Level "WARN"
            }
        }

        # Check current iDRAC settings
        $currentIdrac = (Get-RedfishData -BaseUri $baseUri -Endpoint "$($script:IdracManagerPath)/Attributes" -Credential $bmcCredential).Attributes
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
                Set-RedfishAttribute -BaseUri $baseUri -Endpoint "$($script:IdracManagerPath)/Attributes" `
                    -Credential $bmcCredential -Attributes $idracChanges
                Write-Log "    Applied $($idracChanges.Count) iDRAC changes" -Level "SUCCESS"
            }
        }

        # Apply BIOS changes (requires config job + reboot)
        if ($biosChanges.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess("$nodeName BIOS", "Apply $($biosChanges.Count) setting changes")) {
                Set-RedfishAttribute -BaseUri $baseUri -Endpoint "$($script:IdracSystemPath)/Bios/Settings" `
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
        $nodesFailed += $nodeName
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

# Exit codes: 0 every node is done (or planned under -WhatIf); 1 a node failed; 2 the file is not usable.
if ($nodesFailed.Count -gt 0) { Write-Log "  Nodes that failed: $($nodesFailed -join ', ')" -Level "ERROR"; exit 1 }
exit 0

#endregion Main
