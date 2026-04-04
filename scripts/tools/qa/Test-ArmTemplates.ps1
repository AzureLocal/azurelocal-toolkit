#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $Path) {
    $Path = Join-Path $repoRoot 'src\arm-templates'
}

if (-not (Test-Path $Path)) {
    throw "ARM template path not found: $Path"
}

$templates = @(Get-ChildItem -Path $Path -Recurse -Filter '*.json' -File | Where-Object {
    $_.Name -notmatch '\.parameters\.json$'
})

if ($templates.Count -eq 0) {
    Write-Host "No ARM template files found under $Path. Skipping." -ForegroundColor Yellow
    return [PSCustomObject]@{
        Path = $Path
        TemplatesChecked = 0
        Status = 'Skipped'
    }
}

if (-not (Get-Module -ListAvailable -Name 'arm-ttk')) {
    throw 'arm-ttk is not installed. Install it with: Install-Module arm-ttk -Scope CurrentUser'
}

Import-Module arm-ttk -ErrorAction Stop | Out-Null
if (-not (Get-Command Test-AzTemplate -ErrorAction SilentlyContinue)) {
    throw 'Test-AzTemplate was not found after importing arm-ttk.'
}

$failures = New-Object System.Collections.Generic.List[object]

foreach ($template in $templates) {
    Write-Host "Testing ARM template: $($template.FullName)" -ForegroundColor Cyan

    $results = @(Test-AzTemplate -TemplatePath $template.FullName -ErrorAction Stop)
    $failedResults = @($results | Where-Object {
        ($_.PSObject.Properties.Name -contains 'Passed' -and -not $_.Passed) -or
        ($_.PSObject.Properties.Name -contains 'Errors' -and $_.Errors)
    })

    if ($failedResults.Count -gt 0) {
        $failures.Add([PSCustomObject]@{
            File = $template.FullName
            Stage = 'arm-ttk'
            Output = ($failedResults | Out-String)
        })
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'ARM QA failures:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- [$($failure.Stage)] $($failure.File)" -ForegroundColor Red
        if ($failure.Output) {
            Write-Host $failure.Output -ForegroundColor DarkRed
        }
    }
}

$summary = [PSCustomObject]@{
    Path = $Path
    TemplatesChecked = $templates.Count
    Failures = $failures.Count
}

Write-Output $summary

if ($failures.Count -gt 0) {
    throw "ARM QA failed with $($failures.Count) failure(s)."
}

Write-Host 'ARM QA passed.' -ForegroundColor Green