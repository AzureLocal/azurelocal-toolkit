<#
.SYNOPSIS
    Creates a new script from a template following Azure Local Cloud scripting standards.

.DESCRIPTION
    Generates a new script file with proper structure, comment-based help,
    parameter validation, and config loading. Supports both config-driven
    and standalone script types.

.PARAMETER ScriptType
    Type of script to generate:
    - PowerShell: PowerShell Core script (Verb-Noun.ps1)
    - AzurePowerShell: Azure PowerShell script (Verb-AzResource.ps1)
    - AzureCliPowerShell: Azure CLI for PowerShell (az-verb-resource.ps1)
    - AzureCliBash: Azure CLI Bash script (az-verb-resource.sh)
    - InvokeScript: Remote/management-box script (Invoke-Action.ps1)

.PARAMETER Name
    Name for the script (will be formatted according to type).

.PARAMETER Description
    Brief description of what the script does.

.PARAMETER OutputPath
    Directory to create the script in. Defaults to current directory.

.PARAMETER Standalone
    Generate a standalone script with inline variables instead of config-driven.

.EXAMPLE
    .\New-ScriptFromTemplate.ps1 -ScriptType AzurePowerShell -Name "New-AzKeyVault" -Description "Creates a Key Vault"

.EXAMPLE
    .\New-ScriptFromTemplate.ps1 -ScriptType AzurePowerShell -Name "New-AzKeyVault" -Standalone

.NOTES
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("PowerShell", "AzurePowerShell", "AzureCliPowerShell", "AzureCliBash", "InvokeScript")]
    [string]$ScriptType,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Description = "TODO: Add description",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$Standalone
)

$ErrorActionPreference = "Stop"

# Determine file name based on type
switch ($ScriptType) {
    "PowerShell" {
        $fileName = "$Name.ps1"
        $extension = "ps1"
    }
    "AzurePowerShell" {
        $fileName = "$Name.ps1"
        if ($Standalone) { $fileName = "$Name-Standalone.ps1" }
        $extension = "ps1"
    }
    "AzureCliPowerShell" {
        $fileName = "az-$($Name.ToLower()).ps1"
        $extension = "ps1"
    }
    "AzureCliBash" {
        $fileName = "az-$($Name.ToLower()).sh"
        $extension = "sh"
    }
    "InvokeScript" {
        $fileName = "Invoke-$Name.ps1"
        $extension = "ps1"
    }
}

$fullPath = Join-Path $OutputPath $fileName

# Generate PowerShell template
if ($extension -eq "ps1") {
    if ($Standalone) {
        $template = @"
<#
.SYNOPSIS
    $Description

.DESCRIPTION
    $Description
    
    This is a STANDALONE script with all configuration inline.
    No external dependencies required - can be run anywhere.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    .\$fileName
    
    Runs the script with the configured values.

.EXAMPLE
    .\$fileName -WhatIf
    
    Shows what would be done without making changes.

.NOTES
    Type: Standalone (Option 5)
    Author: AzureLocal Cloud Team Team
    Date: $(Get-Date -Format 'yyyy-MM-dd')
    Version: 1.0.0
#>

[CmdletBinding(SupportsShouldProcess)]
param()

#Requires -Modules Az.Accounts

`$ErrorActionPreference = "Stop"

#region CONFIGURATION
# ============================================================================
# STANDALONE SCRIPT CONFIGURATION
# All variables below map to infrastructure.yml paths
# Update these values for your environment
# ============================================================================

# Azure tenant and subscription
# infrastructure.yml path: azure.tenant.id
`$azure_tenant_id = "00000000-0000-0000-0000-000000000000"

# infrastructure.yml path: azure.subscriptions.demo.id
`$azure_subscriptions_demo_id = "00000000-0000-0000-0000-000000000000"

# Platform Key Vault
# infrastructure.yml path: platform.kv_platform_name
`$platform_kv_platform_name = "kv-yourplatform"

# infrastructure.yml path: platform.kv_platform_resource_group
`$platform_kv_platform_resource_group = "rg-yourplatform"

# Cluster configuration
# infrastructure.yml path: cluster.arm_deployment.cluster_name
`$cluster_arm_deployment_cluster_name = "your-cluster"

# Add additional variables as needed...

#endregion CONFIGURATION

# ============================================================================
# MAIN LOGIC
# ============================================================================

Write-Host "Starting $Name..." -ForegroundColor Cyan

# TODO: Add your script logic here
# Use the variables defined above, e.g.:
# `$tenantId = `$azure_tenant_id
# `$subscriptionId = `$azure_subscriptions_demo_id

if (`$PSCmdlet.ShouldProcess("Target", "Action")) {
    # Perform action
    Write-Host "Action completed successfully." -ForegroundColor Green
}

# ============================================================================
# OUTPUT
# ============================================================================

Write-Host "`nScript completed." -ForegroundColor Green
"@
    } else {
        $template = @"
<#
.SYNOPSIS
    $Description

.DESCRIPTION
    $Description
    
    Reads configuration from infrastructure.yml.

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to relative path from script location.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    .\$fileName -ConfigPath .\configs\infrastructure.yml
    
    Runs the script with the specified config file.

.NOTES
    Type: Config-Driven (Option 2)
    Author: AzureLocal Cloud Team Team
    Date: $(Get-Date -Format 'yyyy-MM-dd')
    Version: 1.0.0
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = `$false)]
    [string]`$ConfigPath
)

#Requires -Modules Az.Accounts, powershell-yaml

`$ErrorActionPreference = "Stop"
`$scriptRoot = `$PSScriptRoot

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

Write-Host "[1/N] Loading infrastructure configuration..." -ForegroundColor Cyan

if (`$ConfigPath) {
    `$infraConfigPath = `$ConfigPath
} else {
    `$infraConfigPath = Join-Path `$scriptRoot "..\..\..\..\configs\infrastructure.yml"
}

if (!(Test-Path `$infraConfigPath)) {
    throw "infrastructure.yml not found at `$infraConfigPath"
}

Import-Module powershell-yaml -ErrorAction Stop
`$content = Get-Content -Path `$infraConfigPath -Raw
`$config = ConvertFrom-Yaml `$content -Ordered

# Extract required values from config
`$tenantId = `$config["azure"]["tenant"]["id"]
`$subscriptionId = `$config["azure"]["subscriptions"]["demo"]["id"]
`$kvName = `$config["platform"]["kv_platform_name"]

Write-Host "  Tenant ID: `$tenantId" -ForegroundColor Gray
Write-Host "  Subscription ID: `$subscriptionId" -ForegroundColor Gray

# ============================================================================
# MAIN LOGIC
# ============================================================================

Write-Host "`n[2/N] Performing action..." -ForegroundColor Cyan

# TODO: Add your script logic here

if (`$PSCmdlet.ShouldProcess("Target", "Action")) {
    # Perform action
    Write-Host "  Action completed successfully." -ForegroundColor Green
}

# ============================================================================
# OUTPUT
# ============================================================================

Write-Host "`nScript completed." -ForegroundColor Green
"@
    }
} else {
    # Bash template
    $template = @"
#!/bin/bash
#===============================================================================
# Script Name: $fileName
# Description: $Description
# Author: Azure Local Cloud AzureLocalCloud Team
# Created: $(Get-Date -Format 'yyyy-MM-dd')
# Version: 1.0.0
#
# Dependencies:
#   - Azure CLI (az) version 2.50.0+
#   - jq for JSON processing
#   - yq for YAML processing
#
# Usage:
#   ./$fileName -c <config-path>
#
# Parameters:
#   -c, --config    Path to infrastructure.yml (required)
#   -v, --verbose   Enable verbose output
#   -h, --help      Show this help message
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Invalid arguments
#   3 - Azure CLI error
#   4 - Configuration error
#===============================================================================

set -euo pipefail
IFS=`$'\n\t'

# Script directory
SCRIPT_DIR="`$(cd "`$(dirname "`${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="`$(basename "`${BASH_SOURCE[0]}")"

# Default values
VERBOSE=false
CONFIG_FILE=""

#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================
log_info() {
    echo "[INFO] `$(date '+%Y-%m-%d %H:%M:%S') - `$*"
}

log_warn() {
    echo "[WARN] `$(date '+%Y-%m-%d %H:%M:%S') - `$*" >&2
}

log_error() {
    echo "[ERROR] `$(date '+%Y-%m-%d %H:%M:%S') - `$*" >&2
}

log_success() {
    echo "[SUCCESS] `$(date '+%Y-%m-%d %H:%M:%S') - `$*"
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================
show_help() {
    head -30 "`$0" | tail -20
    exit 0
}

while [[ `$# -gt 0 ]]; do
    case `$1 in
        -c|--config)
            CONFIG_FILE="`$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown option: `$1"
            exit 2
            ;;
    esac
done

#===============================================================================
# VALIDATION
#===============================================================================
if [[ -z "`$CONFIG_FILE" ]]; then
    log_error "Configuration file is required. Use -c or --config."
    exit 2
fi

if [[ ! -f "`$CONFIG_FILE" ]]; then
    log_error "Configuration file not found: `$CONFIG_FILE"
    exit 4
fi

#===============================================================================
# CONFIGURATION LOADING
#===============================================================================
log_info "Loading configuration from: `$CONFIG_FILE"

# Extract values using yq
TENANT_ID=`$(yq -r '.azure.tenant.id' "`$CONFIG_FILE")
SUBSCRIPTION_ID=`$(yq -r '.azure.subscriptions.demo.id' "`$CONFIG_FILE")
KV_NAME=`$(yq -r '.platform.kv_platform_name' "`$CONFIG_FILE")

log_info "Tenant ID: `$TENANT_ID"
log_info "Subscription ID: `$SUBSCRIPTION_ID"

#===============================================================================
# MAIN LOGIC
#===============================================================================
log_info "Starting $Name..."

# TODO: Add your script logic here

log_success "Script completed."
"@
}

# Write the template
$template | Out-File -FilePath $fullPath -Encoding utf8

Write-Host "Script created: $fullPath" -ForegroundColor Green
Write-Host "Type: $ScriptType$(if ($Standalone) { ' (Standalone)' })" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open the script and update the TODO sections"
Write-Host "  2. Add your script logic"
Write-Host "  3. Test with -WhatIf if applicable"
Write-Host "  4. Run PSScriptAnalyzer or ShellCheck for linting"

return [PSCustomObject]@{
    ScriptPath = $fullPath
    ScriptType = $ScriptType
    Standalone = $Standalone.IsPresent
}
