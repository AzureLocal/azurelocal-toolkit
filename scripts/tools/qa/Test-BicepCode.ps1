#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $Path) {
    $Path = Join-Path $repoRoot 'src\bicep'
}

if (-not (Test-Path $Path)) {
    throw "Bicep path not found: $Path"
}

$bicepFiles = @(Get-ChildItem -Path $Path -Recurse -Filter '*.bicep' -File)
if ($bicepFiles.Count -eq 0) {
    Write-Host "No Bicep files found under $Path. Skipping." -ForegroundColor Yellow
    return [PSCustomObject]@{
        Path = $Path
        FilesChecked = 0
        Status = 'Skipped'
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is not installed or not on PATH.'
}

$failures = New-Object System.Collections.Generic.List[object]

foreach ($file in $bicepFiles) {
    Write-Host "Checking Bicep file: $($file.FullName)" -ForegroundColor Cyan

    $buildOutput = & az bicep build --file $file.FullName 2>&1
    $buildExitCode = $LASTEXITCODE
    if ($buildOutput.Count -gt 0) {
        $buildOutput | Write-Host
    }

    if ($buildExitCode -ne 0) {
        $failures.Add([PSCustomObject]@{ File = $file.FullName; Stage = 'build'; Output = ($buildOutput -join [Environment]::NewLine) })
        continue
    }

    $lintOutput = & az bicep lint --file $file.FullName 2>&1
    $lintExitCode = $LASTEXITCODE
    if ($lintOutput.Count -gt 0) {
        $lintOutput | Write-Host
    }

    if ($lintExitCode -ne 0) {
        $failures.Add([PSCustomObject]@{ File = $file.FullName; Stage = 'lint'; Output = ($lintOutput -join [Environment]::NewLine) })
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Bicep QA failures:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- [$($failure.Stage)] $($failure.File)" -ForegroundColor Red
        if ($failure.Output) {
            Write-Host $failure.Output -ForegroundColor DarkRed
        }
    }
}

$summary = [PSCustomObject]@{
    Path = $Path
    FilesChecked = $bicepFiles.Count
    Failures = $failures.Count
}

Write-Output $summary

if ($failures.Count -gt 0) {
    throw "Bicep QA failed with $($failures.Count) failure(s)."
}

Write-Host 'Bicep QA passed.' -ForegroundColor Green