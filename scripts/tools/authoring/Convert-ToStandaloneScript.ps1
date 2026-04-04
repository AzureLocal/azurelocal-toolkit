<#
.SYNOPSIS
    Converts a config-driven script to a standalone script with inline variables.

.DESCRIPTION
    Takes an existing script that uses infrastructure.yml and generates a standalone
    version by baking in the current config values as inline variables. The output
    script has no external dependencies and can be shared/run anywhere.

.PARAMETER SourceScript
    Path to the source script that uses infrastructure.yml.

.PARAMETER ConfigPath
    Path to the infrastructure.yml file to extract values from.

.PARAMETER OutputPath
    Path for the generated standalone script. Defaults to <SourceName>-Standalone.ps1.

.EXAMPLE
    .\Convert-ToStandaloneScript.ps1 -SourceScript .\New-AzureLocalSP.ps1 -ConfigPath .\infrastructure.yml

.EXAMPLE
    .\Convert-ToStandaloneScript.ps1 -SourceScript .\New-AzureLocalSP.ps1 -ConfigPath .\infrastructure.yml -OutputPath .\New-AzureLocalSP-Standalone.ps1

.NOTES
    Requires: powershell-yaml module
    Author: AzureLocal Cloud Team Team
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceScript,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

# Validate inputs
if (-not (Test-Path $SourceScript)) {
    throw "Source script not found: $SourceScript"
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

# Load YAML module
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "powershell-yaml module not found. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop

# Load config
$configContent = Get-Content -Path $ConfigPath -Raw
$config = ConvertFrom-Yaml $configContent -Ordered

# Read source script
$sourceContent = Get-Content -Path $SourceScript -Raw

# Find all $config references in the script
$configRefs = [regex]::Matches($sourceContent, '\$config\[?"?([^\]"]+)"?\](?:\[?"?([^\]"]+)"?\])?(?:\[?"?([^\]"]+)"?\])?(?:\[?"?([^\]"]+)"?\])?(?:\[?"?([^\]"]+)"?\])?')

# Build a hashtable of unique config paths and their values
$variables = @{}
foreach ($match in $configRefs) {
    $fullMatch = $match.Value
    
    # Parse the path segments
    $segments = @()
    for ($i = 1; $i -le 5; $i++) {
        if ($match.Groups[$i].Success -and $match.Groups[$i].Value) {
            $segments += $match.Groups[$i].Value
        }
    }
    
    if ($segments.Count -eq 0) { continue }
    
    # Build variable name from path
    $varName = ($segments -join '_') -replace '[-.]', '_'
    
    # Get value from config
    $value = $config
    foreach ($seg in $segments) {
        if ($null -eq $value) { break }
        if ($value -is [System.Collections.IDictionary] -and $value.Contains($seg)) {
            $value = $value[$seg]
        } elseif ($value.PSObject.Properties.Name -contains $seg) {
            $value = $value.$seg
        } else {
            $value = $null
            break
        }
    }
    
    if ($null -ne $value -and -not $variables.ContainsKey($varName)) {
        $variables[$varName] = @{
            OriginalPath = $fullMatch
            Value = $value
            Segments = $segments
        }
    }
}

# Build the configuration block
$configBlock = @"
#region CONFIGURATION
# ============================================================================
# STANDALONE SCRIPT CONFIGURATION
# All variables below map to infrastructure.yml paths
# Update these values for your environment
# Generated from: $ConfigPath
# Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# ============================================================================

"@

foreach ($var in $variables.GetEnumerator() | Sort-Object Name) {
    $varName = $var.Key
    $info = $var.Value
    $value = $info.Value
    $pathComment = $info.Segments -join '.'
    
    # Format value based on type
    if ($value -is [string]) {
        $valueStr = "`"$value`""
    } elseif ($value -is [bool]) {
        $valueStr = if ($value) { '$true' } else { '$false' }
    } elseif ($value -is [int] -or $value -is [long] -or $value -is [double]) {
        $valueStr = $value.ToString()
    } elseif ($value -is [array]) {
        $valueStr = "@(" + (($value | ForEach-Object { "`"$_`"" }) -join ', ') + ")"
    } else {
        $valueStr = "`"$value`""
    }
    
    $configBlock += "# infrastructure.yml path: $pathComment`n"
    $configBlock += "`$$varName = $valueStr`n`n"
}

$configBlock += "#endregion CONFIGURATION`n"

# Replace config references with variable references in the script
$newContent = $sourceContent

foreach ($var in $variables.GetEnumerator()) {
    $varName = $var.Key
    $originalPath = $var.Value.OriginalPath
    # Escape regex special characters
    $escapedPath = [regex]::Escape($originalPath)
    $newContent = $newContent -replace $escapedPath, "`$$varName"
}

# Remove config-loader and helper imports
$newContent = $newContent -replace '(?m)^\s*\.\s*"\$.*config-loader\.ps1".*$', '# Config loader removed - standalone script'
$newContent = $newContent -replace '(?m)^\s*\.\s*"\$.*keyvault-helper\.ps1".*$', '# Key Vault helper removed - standalone script'
$newContent = $newContent -replace '(?m)^\s*\.\s*"\$.*logging\.ps1".*$', '# Logging helper removed - standalone script'
$newContent = $newContent -replace '(?m)^\s*\$config\s*=\s*Get-EnvironmentConfig.*$', '# Config loading removed - using inline variables'
$newContent = $newContent -replace '(?m)^\s*\$config\s*=\s*ConvertFrom-Yaml.*$', '# Config loading removed - using inline variables'
$newContent = $newContent -replace '(?m)^\s*Import-Module\s+powershell-yaml.*$', '# YAML module not needed - standalone script'

# Remove ConfigPath parameter if present
$newContent = $newContent -replace '(?ms)\[Parameter\(Mandatory\s*=\s*\$false\)\]\s*\[string\]\$ConfigPath,?', ''

# Insert config block after the comment-based help (after #>)
if ($newContent -match '(?s)(^.*?#>)(.*)$') {
    $helpBlock = $matches[1]
    $restOfScript = $matches[2]
    
    # Add standalone notice to help
    $standaloneNotice = @"

# ============================================================================
# STANDALONE VERSION
# This script has been converted to standalone mode with inline variables.
# No external configuration files or helpers are required.
# Original source: $SourceScript
# ============================================================================

"@
    
    $newContent = $helpBlock + "`n" + $standaloneNotice + "`n" + $configBlock + $restOfScript
} else {
    # No help block found, prepend config block
    $newContent = $configBlock + "`n" + $newContent
}

# Determine output path
if (-not $OutputPath) {
    $sourceName = [System.IO.Path]::GetFileNameWithoutExtension($SourceScript)
    $sourceDir = [System.IO.Path]::GetDirectoryName($SourceScript)
    $OutputPath = Join-Path $sourceDir "$sourceName-Standalone.ps1"
}

# Write output
$newContent | Out-File -FilePath $OutputPath -Encoding utf8

Write-Host "Standalone script generated: $OutputPath" -ForegroundColor Green
Write-Host "Variables extracted: $($variables.Count)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Review and update the CONFIGURATION section with your environment values"
Write-Host "  2. Test the script with -WhatIf if supported"
Write-Host "  3. Share the standalone script as needed"

return [PSCustomObject]@{
    SourceScript = $SourceScript
    OutputPath = $OutputPath
    VariablesExtracted = $variables.Count
    ConfigPath = $ConfigPath
}
