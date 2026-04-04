#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Path,
    [string]$SettingsPath = (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'),
    [switch]$SkipAnalyzer
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $Path) {
    $Path = Join-Path $repoRoot 'scripts'
}

if (-not (Test-Path $Path)) {
    throw "PowerShell path not found: $Path"
}

if (-not (Test-Path $SettingsPath)) {
    throw "PSScriptAnalyzer settings file not found: $SettingsPath"
}

function Get-ParseIssues {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Files
    )

    $issues = New-Object System.Collections.Generic.List[object]

    foreach ($file in $Files) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

        foreach ($error in $errors) {
            $issues.Add([PSCustomObject]@{
                File = $file.FullName
                Line = $error.Extent.StartLineNumber
                Column = $error.Extent.StartColumnNumber
                Message = $error.Message
            })
        }
    }

    return $issues
}

$files = @(Get-ChildItem -Path $Path -Recurse -Filter '*.ps1' -File | Sort-Object FullName)
if ($files.Count -eq 0) {
    throw "No PowerShell files found under: $Path"
}

Write-Host "Scanning $($files.Count) PowerShell files under $Path" -ForegroundColor Cyan

$parseIssues = @(Get-ParseIssues -Files $files)

$analysisResults = @()
if (-not $SkipAnalyzer) {
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        throw 'PSScriptAnalyzer is not installed. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    }

    Import-Module PSScriptAnalyzer -ErrorAction Stop | Out-Null
    $analysisResults = @(Invoke-ScriptAnalyzer -Path $Path -Recurse -Settings $SettingsPath | Where-Object {
        $_.Severity -in @('Error', 'Warning')
    })
}

if ($parseIssues.Count -gt 0) {
    Write-Host ''
    Write-Host 'Parse errors:' -ForegroundColor Red
    foreach ($issue in $parseIssues) {
        Write-Host "- $($issue.File):$($issue.Line):$($issue.Column) $($issue.Message)" -ForegroundColor Red
    }
}

if ($analysisResults.Count -gt 0) {
    Write-Host ''
    Write-Host 'PSScriptAnalyzer findings:' -ForegroundColor Yellow
    foreach ($result in $analysisResults) {
        Write-Host "- $($result.ScriptPath):$($result.Line):$($result.Column) [$($result.RuleName)] $($result.Message)" -ForegroundColor Yellow
    }
}

$summary = [PSCustomObject]@{
    Path = $Path
    FilesScanned = $files.Count
    ParseErrors = $parseIssues.Count
    AnalyzerFindings = $analysisResults.Count
    AnalyzerSkipped = $SkipAnalyzer.IsPresent
}

Write-Output $summary

if ($parseIssues.Count -gt 0 -or $analysisResults.Count -gt 0) {
    throw "PowerShell QA failed. Parse errors: $($parseIssues.Count). Analyzer findings: $($analysisResults.Count)."
}

Write-Host 'PowerShell QA passed.' -ForegroundColor Green