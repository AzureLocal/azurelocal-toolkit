#Requires -Modules Az.Resources
<#
.SYNOPSIS
    Create and configure Network Security Groups for Azure Local cluster networks.
.DESCRIPTION
    Orchestrated script that loads NSG definitions from config/variables.yml,
    creates NSGs using az stack-hci-vm network nsg commands, and applies all
    security rules. Supports -WhatIf and logging.
.PARAMETER ConfigPath
    Path to the YAML variables file. Defaults to ./config/variables.yml.
.PARAMETER LogPath
    Path to write operation log. Defaults to ./logs/configure-nsgs.log.
.PARAMETER WhatIf
    Preview changes without making them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "./config/variables.yml",
    [string]$LogPath    = "./logs/configure-nsgs.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Logging ───────────────────────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# ── Load config ───────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config       = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
$rg           = $config.azure.resource_group
$location     = $config.azure.location
$customLocation = $config.azure.custom_location
$nsgs         = $config.network.nsgs

Write-Log "Starting NSG configuration — Resource Group: $rg"

# ── Process each NSG ──────────────────────────────────────────────────────────
foreach ($nsg in $nsgs) {
    Write-Log "Processing NSG: $($nsg.name)"

    if (-not ($PSCmdlet.ShouldProcess($nsg.name, "Create/update NSG"))) { continue }

    # Create NSG
    $nsgExists = az stack-hci-vm network nsg show `
        --name              $nsg.name `
        --resource-group    $rg `
        --custom-location   $customLocation `
        --query             "name" -o tsv 2>$null

    if ($nsgExists) {
        Write-Log "  [SKIP] NSG '$($nsg.name)' already exists." "WARN"
    } else {
        Write-Log "  Creating NSG: $($nsg.name)"
        az stack-hci-vm network nsg create `
            --name            $nsg.name `
            --resource-group  $rg `
            --custom-location $customLocation `
            --location        $location `
            --output none
        Write-Log "  [CREATED] $($nsg.name)" "INFO"
    }

    # Apply rules
    foreach ($rule in $nsg.rules) {
        Write-Log "  Applying rule: $($rule.name) ($($rule.direction) $($rule.protocol) $($rule.destination_port_range))"
        az stack-hci-vm network nsg rule create `
            --nsg-name              $nsg.name `
            --resource-group        $rg `
            --custom-location       $customLocation `
            --name                  $rule.name `
            --priority              $rule.priority `
            --direction             $rule.direction `
            --access                $rule.access `
            --protocol              $rule.protocol `
            --source-address-prefix $rule.source_address_prefix `
            --destination-address-prefix $rule.destination_address_prefix `
            --destination-port-range     $rule.destination_port_range `
            --output none
        Write-Log "    [DONE] Rule: $($rule.name)"
    }
}

Write-Log "NSG configuration complete."
