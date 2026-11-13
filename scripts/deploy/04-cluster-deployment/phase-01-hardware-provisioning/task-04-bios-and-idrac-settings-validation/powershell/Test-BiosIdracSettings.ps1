<#
.SYNOPSIS
    Validates BIOS and iDRAC settings against desired configuration baseline.

.DESCRIPTION
    This script validates Dell server BIOS and iDRAC settings via Redfish API:
    - Reads desired BIOS/iDRAC settings from infrastructure.yml
    - Connects to each node's iDRAC via Redfish
    - Compares current settings against desired baseline
    - Generates compliance report with pass/fail per setting
    - Does NOT make changes — use task-05 for remediation

    The BMC login comes from infrastructure.yml: hardware.bmc.username and password, and a node's own nodes[].bmc.username and
    password when it has them (they win for that node). The password is a secret reference (keyvault://, env://, file:// or
    command://) read by the toolkit's secret resolver; no value is written to the file. Whether the BMC certificate is checked
    comes from hardware.bmc.verify_certificate (default false: the BMC's own certificate is accepted). The script never prompts.

    Keys read: nodes[].name, nodes[].bmc (ip_address, username, password), hardware.bmc (username, password, verify_certificate),
    hardware.bios and nodes[].bios (overrides of the desired BIOS values), secrets and key_vaults (for the references).

.PARAMETER ConfigPath
    Path to infrastructure.yml configuration.

.PARAMETER Credential
    Optional. Use this BMC login for every node instead of the one in infrastructure.yml.

.PARAMETER OutputPath
    Path to save validation report. Default: .\logs\bios-validation-report.json

.EXAMPLE
    .\Test-BiosIdracSettings.ps1 -ConfigPath ".\configs\infrastructure.yml"

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
    Stage: 04-cluster-deployment
    Phase: phase-01-hardware-provisioning
    Task: task-04-bios-and-idrac-settings-validation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\logs\bios-validation-report.json"
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

function Get-RedfishData {
    param(
        [string]$BaseUri,
        [string]$Endpoint,
        [PSCredential]$Credential
    )
    $uri = "$BaseUri$Endpoint"
    # The BMC's own certificate is accepted unless hardware.bmc.verify_certificate is true.
    $tls = @{}
    if (-not $script:VerifyCertificate) { $tls.SkipCertificateCheck = $true }
    $response = Invoke-RestMethod -Uri $uri -Credential $Credential `
        -Method Get -ContentType 'application/json' `
        @tls -ErrorAction Stop
    return $response
}

function Test-BiosSettings {
    param(
        [string]$iDRACIp,
        [PSCredential]$Credential,
        [hashtable]$DesiredSettings
    )

    $baseUri = "https://$iDRACIp"
    $biosAttributes = (Get-RedfishData -BaseUri $baseUri -Endpoint "/redfish/v1/Systems/System.Embedded.1/Bios" -Credential $Credential).Attributes

    $results = @()
    foreach ($key in $DesiredSettings.Keys) {
        $currentValue = $biosAttributes.$key
        $desiredValue = $DesiredSettings[$key]
        $compliant = ($currentValue -eq $desiredValue)

        $results += [PSCustomObject]@{
            Setting  = $key
            Current  = $currentValue
            Desired  = $desiredValue
            Status   = if ($compliant) { "PASS" } else { "FAIL" }
        }
    }
    return $results
}

function Test-IdracSettings {
    param(
        [string]$iDRACIp,
        [PSCredential]$Credential,
        [hashtable]$DesiredSettings
    )

    $baseUri = "https://$iDRACIp"
    $idracAttributes = (Get-RedfishData -BaseUri $baseUri -Endpoint "/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" -Credential $Credential).Attributes

    $results = @()
    foreach ($key in $DesiredSettings.Keys) {
        $currentValue = $idracAttributes.$key
        $desiredValue = $DesiredSettings[$key]
        $compliant = ($currentValue -eq $desiredValue)

        $results += [PSCustomObject]@{
            Setting  = $key
            Current  = $currentValue
            Desired  = $desiredValue
            Status   = if ($compliant) { "PASS" } else { "FAIL" }
        }
    }
    return $results
}

#region Main

Write-Log "=== BIOS and iDRAC Settings Validation ===" -Level "HEADER"

$configFile = Resolve-ConfigPath -ExplicitPath $ConfigPath
$config = Import-InfrastructureConfig -Path $configFile

$nodes = Get-AzlInfrastructureValue -Infrastructure $config -Path 'nodes'
if (-not $nodes -or $nodes.Count -eq 0) {
    Write-Log "No nodes found in configuration." -Level "ERROR"
    exit 1
}

$verifyValue = Get-AzlInfrastructureValue -Infrastructure $config -Path 'hardware.bmc.verify_certificate'
$script:VerifyCertificate = ($null -ne $verifyValue -and ([string]$verifyValue).Trim().ToLowerInvariant() -in 'true', '1', 'yes')

# Define desired BIOS settings baseline for Azure Local
$desiredBios = @{
    "SysProfile"          = "PerfOptimized"
    "LogicalProc"         = "Enabled"
    "VirtualizationTechnology" = "Enabled"
    "SriovGlobalEnable"   = "Enabled"
    "BootMode"            = "Uefi"
    "SecureBoot"          = "Enabled"
    "TpmSecurity"         = "OnPbm"
}

# Override with config if present: hardware.bios for every machine, nodes[].bios for one machine (the key of a node wins)
$biosOverride = Get-AzlInfrastructureValue -Infrastructure $config -Path 'hardware.bios'
if ($biosOverride) {
    foreach ($key in $biosOverride.Keys) {
        $desiredBios[$key] = $biosOverride[$key]
    }
}

$desiredIdrac = @{
    "IPMILan.1#Enable"  = "Enabled"
}
# The iDRAC baseline above is fixed in this script: infrastructure.yml has no key for iDRAC attributes.

$report = @()
$totalPass = 0
$totalFail = 0

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

    Write-Log "  Validating $nodeName ($iDRACIp)..." -Level "INFO"

    try {
        # -Credential, else nodes[].bmc, else hardware.bmc (secret references read by the resolver). Never a prompt.
        $bmcCredential = Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $config -Node $node -NoPrompt
        $biosResults = Test-BiosSettings -iDRACIp $iDRACIp -Credential $bmcCredential -DesiredSettings $nodeBios
        $idracResults = Test-IdracSettings -iDRACIp $iDRACIp -Credential $bmcCredential -DesiredSettings $desiredIdrac

        $allResults = $biosResults + $idracResults
        $pass = ($allResults | Where-Object { $_.Status -eq "PASS" }).Count
        $fail = ($allResults | Where-Object { $_.Status -eq "FAIL" }).Count

        $totalPass += $pass
        $totalFail += $fail

        foreach ($r in $allResults | Where-Object { $_.Status -eq "FAIL" }) {
            Write-Log "    FAIL: $($r.Setting) — Current: $($r.Current), Desired: $($r.Desired)" -Level "WARN"
        }

        Write-Log "    $nodeName : $pass passed, $fail failed" -Level $(if ($fail -gt 0) { "WARN" } else { "SUCCESS" })

        $report += [PSCustomObject]@{
            Node    = $nodeName
            iDRACIp = $iDRACIp
            Results = $allResults
            Pass    = $pass
            Fail    = $fail
        }
    }
    catch {
        Write-Log "    $nodeName : Validation failed — $_" -Level "ERROR"
        $report += [PSCustomObject]@{
            Node    = $nodeName
            iDRACIp = $iDRACIp
            Results = @()
            Pass    = 0
            Fail    = 0
            Error   = $_.ToString()
        }
    }
}

# Save report
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory -Force | Out-Null }
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Log "Report saved: $OutputPath" -Level "INFO"

Write-Host ""
Write-Log "=== Validation Summary ===" -Level "HEADER"
Write-Log "  Nodes validated: $($report.Count)" -Level "INFO"
Write-Log "  Total settings passed: $totalPass" -Level "INFO"
Write-Log "  Total settings failed: $totalFail" -Level "INFO"

if ($totalFail -gt 0) {
    Write-Log "Run task-05 (Set-BiosIdracSettings.ps1) to remediate non-compliant settings." -Level "WARN"
}
else {
    Write-Log "All settings compliant." -Level "SUCCESS"
}

#endregion Main
