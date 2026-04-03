<#
.SYNOPSIS
    Runs quality and unit tests for all scripts in the Azure Local Toolkit.

.DESCRIPTION
    Entry-point test runner that invokes Pester 5 tests for the azurelocal-toolkit
    repository. Supports running unit tests, quality/linting tests, or both.
    Outputs results to the console and optionally to a NUnit XML file for CI ingestion.

.PARAMETER TestType
    Which suite to run:
    - All     : Unit tests + Quality tests (default)
    - Unit    : Unit tests only (tests/Unit/**)
    - Quality : PSScriptAnalyzer + structure tests (tests/Quality/**)

.PARAMETER OutputFormat
    Result output format:
    - Detailed  : Console-only detailed output (default)
    - NUnitXml  : NUnit XML file (for CI / test dashboards)

.PARAMETER OutputPath
    Path for the NUnit XML output file.
    Defaults to logs/test-quality/<timestamp>.xml.

.PARAMETER PassThru
    Return the Pester result object to the caller.

.EXAMPLE
    .\scripts\tools\Test-ScriptQuality.ps1

.EXAMPLE
    .\scripts\tools\Test-ScriptQuality.ps1 -TestType Quality

.EXAMPLE
    .\scripts\tools\Test-ScriptQuality.ps1 -OutputFormat NUnitXml -OutputPath .\test-results.xml

.NOTES
    Author: Azure Local Cloud
    Version: 1.0.0
    Prerequisites: Pester 5+, PSScriptAnalyzer 1.21+
    See tests/README.md for full documentation.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('All', 'Unit', 'Quality')]
    [string]$TestType = 'All',

    [Parameter()]
    [ValidateSet('Detailed', 'NUnitXml')]
    [string]$OutputFormat = 'Detailed',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$repoRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testsRoot = Join-Path $repoRoot 'tests'
$logsRoot  = Join-Path $repoRoot 'logs' 'test-quality'

# ---------------------------------------------------------------------------
# Verify prerequisites
# ---------------------------------------------------------------------------
$requiredModules = @('Pester', 'PSScriptAnalyzer')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -Name $module -ListAvailable)) {
        throw "Required module '$module' is not installed. Run: Install-Module $module -Scope CurrentUser"
    }
}

Import-Module Pester -MinimumVersion '5.0.0' -ErrorAction Stop
Import-Module PSScriptAnalyzer -ErrorAction Stop

# ---------------------------------------------------------------------------
# Set up output path
# ---------------------------------------------------------------------------
if (-not $OutputPath) {
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $OutputPath = Join-Path $logsRoot "test-results-$timestamp.xml"
}

if ($OutputFormat -eq 'NUnitXml') {
    $logDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Determine test paths
# ---------------------------------------------------------------------------
$testPaths = switch ($TestType) {
    'Unit'    { Join-Path $testsRoot 'Unit' }
    'Quality' { Join-Path $testsRoot 'Quality' }
    default   { $testsRoot }
}

Write-Host ""
Write-Host "Azure Local Toolkit — Script Quality Tests" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Test type   : $TestType"
Write-Host "  Test path   : $testPaths"
Write-Host "  Output      : $OutputFormat"
if ($OutputFormat -eq 'NUnitXml') {
    Write-Host "  Report file : $OutputPath"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Configure Pester
# ---------------------------------------------------------------------------
$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path = $testPaths
$pesterConfig.Output.Verbosity = 'Detailed'

if ($PassThru) {
    $pesterConfig.Run.PassThru = $true
}

if ($OutputFormat -eq 'NUnitXml') {
    $pesterConfig.TestResult.Enabled    = $true
    $pesterConfig.TestResult.OutputPath = $OutputPath
    $pesterConfig.TestResult.OutputFormat = 'NUnitXml'
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
$result = Invoke-Pester -Configuration $pesterConfig

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
if ($result.FailedCount -gt 0) {
    Write-Host "FAILED — $($result.FailedCount) test(s) failed out of $($result.TotalCount)" -ForegroundColor Red
    if ($OutputFormat -eq 'NUnitXml') {
        Write-Host "Results written to: $OutputPath" -ForegroundColor Yellow
    }
    exit 1
}
else {
    Write-Host "PASSED — $($result.PassedCount)/$($result.TotalCount) tests passed" -ForegroundColor Green
    if ($OutputFormat -eq 'NUnitXml') {
        Write-Host "Results written to: $OutputPath" -ForegroundColor Green
    }
}

if ($PassThru) {
    return $result
}
