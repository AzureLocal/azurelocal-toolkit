#Requires -Version 7.0

<#
.SYNOPSIS
    Generate a solution-specific YAML config from solutions.yaml + master-registry + infrastructure-<env>.yml.

.DESCRIPTION
    Reads the solutions definition (config/solutions.yaml), the master variable registry
    (config/schema/master-registry.yaml), and an environment-specific infrastructure
    file (config/infrastructure-<env>.yml) to produce a per-solution config file containing
    only the variables that solution needs — with actual environment values populated.

    Output path follows the convention: solutions/<name>/solution-<name>.yml

.PARAMETER Solution
    Solution name as defined in solutions.yaml (e.g., avd-azure-local, sofs-azure-local).

.PARAMETER Environment
    Environment name matching infrastructure-<env>.yml (e.g., azl-lab, azl-demo).

.PARAMETER ConfigRoot
    Root path of the azl-toolkit repo. Defaults to repo root relative to this script.

.PARAMETER OutputPath
    Override the output file path. Defaults to the path defined in solutions.yaml.

.PARAMETER WhatIf
    Preview what would be generated without writing files.

.EXAMPLE
    .\Generate-SolutionConfig.ps1 -Solution avd-azure-local -Environment azl-lab
    .\Generate-SolutionConfig.ps1 -Solution sofs-azure-local -Environment azl-lab -WhatIf
    .\Generate-SolutionConfig.ps1 -Solution avd-azure-local -Environment azl-lab -OutputPath ./out/avd.yml
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Solution,

    [Parameter(Mandatory)]
    [string] $Environment,

    [string] $ConfigRoot = "",
    [string] $OutputPath = "",
    [switch] $WhatIf
)

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
if ($ConfigRoot -eq "") {
    # Script lives in tools/ — config root is one level up
    $ConfigRoot = Split-Path $PSScriptRoot -Parent
}

$solutionsFile  = Join-Path $ConfigRoot "configs\solutions.yaml"
$registryFile   = Join-Path $ConfigRoot "configs\variables\assets\master-registry.yaml"
$infraFile      = Join-Path $ConfigRoot "configs\infrastructure-$Environment.yml"

foreach ($f in @($solutionsFile, $registryFile, $infraFile)) {
    if (-not (Test-Path $f)) {
        Write-Error "Required file not found: $f"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Load YAML (requires powershell-yaml module)
# ---------------------------------------------------------------------------
if (-not (Get-Module -Name powershell-yaml -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] Installing powershell-yaml module..." -ForegroundColor Cyan
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
}
Import-Module powershell-yaml -ErrorAction Stop

$solutions = Get-Content $solutionsFile  -Raw | ConvertFrom-Yaml
$registry  = Get-Content $registryFile   -Raw | ConvertFrom-Yaml
$infra     = Get-Content $infraFile      -Raw | ConvertFrom-Yaml

# ---------------------------------------------------------------------------
# Validate solution exists
# ---------------------------------------------------------------------------
$solDef = $solutions.solutions[$Solution]
if (-not $solDef) {
    Write-Error "Solution '$Solution' not found in solutions.yaml. Available: $($solutions.solutions.Keys -join ', ')"
    exit 1
}

Write-Host ""
Write-Host "=== Generate Solution Config ===" -ForegroundColor Cyan
Write-Host "  Solution:    $Solution ($($solDef.display_name))"
Write-Host "  Environment: $Environment"
Write-Host "  Status:      $($solDef.status)"
Write-Host ""

# ---------------------------------------------------------------------------
# Helper: Navigate a dotted YAML path (e.g., compute.avd.azure_local)
# ---------------------------------------------------------------------------
function Get-YamlSection {
    param(
        [object] $Root,
        [string] $DottedPath
    )
    $current = $Root
    foreach ($segment in $DottedPath.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            $current = $current[$segment]
        } else {
            return $null
        }
    }
    return $current
}

# ---------------------------------------------------------------------------
# Collect variables for this solution
# ---------------------------------------------------------------------------
$outputData = [ordered]@{
    "_generated" = [ordered]@{
        solution    = $Solution
        display_name = $solDef.display_name
        environment = $Environment
        generated_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        generator   = "Generate-SolutionConfig.ps1 v1.0.0"
        source_files = @(
            "config/solutions.yaml"
            "config/schema/master-registry.yaml"
            "config/infrastructure-$Environment.yml"
        )
    }
}

$varCount = 0
$missingRequired = @()

# Process required variable groups
$allGroups = @()
if ($solDef.variable_groups.required) { $allGroups += $solDef.variable_groups.required }
if ($solDef.variable_groups.optional) { $allGroups += $solDef.variable_groups.optional }

foreach ($groupPath in $allGroups) {
    $isRequired = $solDef.variable_groups.required -contains $groupPath
    $sectionLabel = $groupPath.Replace('.', '_')

    # Get values from infrastructure YAML
    $infraSection = Get-YamlSection -Root $infra -DottedPath $groupPath
    # Get metadata from registry
    $registrySection = Get-YamlSection -Root $registry -DottedPath $groupPath

    if ($null -eq $infraSection -and $isRequired) {
        Write-Host "  [WARN] Required section '$groupPath' not found in infrastructure-$Environment.yml" -ForegroundColor Yellow
    }

    if ($null -ne $infraSection -and $infraSection -is [System.Collections.IDictionary]) {
        $sectionData = [ordered]@{}
        foreach ($key in $infraSection.Keys) {
            if ($key -eq '_meta' -or $key -eq 'infrastructure_type') { continue }
            $sectionData[$key] = $infraSection[$key]
            $varCount++
        }
        if ($sectionData.Count -gt 0) {
            $outputData[$sectionLabel] = $sectionData
        }
    }
}

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
if ($solDef.required_variables) {
    Write-Host "  Validating required variables..." -ForegroundColor Cyan
    foreach ($reqVar in $solDef.required_variables) {
        $found = $false
        foreach ($sectionKey in $outputData.Keys) {
            if ($sectionKey -eq '_generated') { continue }
            $section = $outputData[$sectionKey]
            if ($section -is [System.Collections.IDictionary] -and $section.Contains($reqVar)) {
                $val = $section[$reqVar]
                if ($null -ne $val -and "$val" -ne "" -and "$val" -ne "false") {
                    $found = $true
                    break
                }
            }
        }
        if (-not $found) {
            $missingRequired += $reqVar
        }
    }
    if ($missingRequired.Count -gt 0) {
        Write-Host "  [WARN] Missing required variables:" -ForegroundColor Yellow
        foreach ($m in $missingRequired) {
            Write-Host "    - $m" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [PASS] All required variables present" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Run custom validations
# ---------------------------------------------------------------------------
if ($solDef.validations) {
    Write-Host "  Running validations..." -ForegroundColor Cyan
    foreach ($v in $solDef.validations) {
        # Simple validation — logged but not blocking
        Write-Host "    [CHECK] $($v.rule) — $($v.message)" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Determine output path
# ---------------------------------------------------------------------------
if ($OutputPath -eq "") {
    if ($solDef.output) {
        $OutputPath = Join-Path $ConfigRoot $solDef.output
    } else {
        $OutputPath = Join-Path $ConfigRoot "solutions\$Solution\solution-$Solution.yml"
    }
}

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  Variables collected: $varCount" -ForegroundColor Cyan
Write-Host "  Output: $OutputPath" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host ""
    Write-Host "[DRY RUN] Would write solution config to: $OutputPath" -ForegroundColor Yellow
    Write-Host ""
    $yamlOut = $outputData | ConvertTo-Yaml
    Write-Host $yamlOut
} else {
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $yamlOut = $outputData | ConvertTo-Yaml
    # Add header comment
    $header = @"
# =============================================================================
# Solution Config: $($solDef.display_name)
# =============================================================================
# Generated by: Generate-SolutionConfig.ps1
# Solution:     $Solution
# Environment:  $Environment
# Generated:    $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
#
# DO NOT EDIT MANUALLY — regenerate with:
#   .\tools\Generate-SolutionConfig.ps1 -Solution $Solution -Environment $Environment
# =============================================================================

"@
    ($header + $yamlOut) | Out-File -FilePath $OutputPath -Encoding utf8 -Force
    Write-Host "[PASS] Solution config written: $OutputPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
