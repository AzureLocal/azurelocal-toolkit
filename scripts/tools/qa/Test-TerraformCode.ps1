#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$SkipInit
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $Path) {
    $Path = Join-Path $repoRoot 'src\terraform'
}

if (-not (Test-Path $Path)) {
    throw "Terraform path not found: $Path"
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw 'terraform is not installed or not on PATH.'
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

$tfFiles = @(Get-ChildItem -Path $Path -Recurse -Filter '*.tf' -File)
if ($tfFiles.Count -eq 0) {
    Write-Host "No Terraform files found under $Path. Skipping." -ForegroundColor Yellow
    return [PSCustomObject]@{
        Path = $Path
        DirectoriesValidated = 0
        FmtPassed = $true
        Status = 'Skipped'
    }
}

$directories = @($tfFiles.DirectoryName | Sort-Object -Unique)

Write-Host "Running terraform fmt -check across $Path" -ForegroundColor Cyan
$fmtResult = Invoke-ExternalCommand -Command 'terraform' -Arguments @('fmt', '-check', '-recursive') -WorkingDirectory $Path
if ($fmtResult.Output.Count -gt 0) {
    $fmtResult.Output | Write-Host
}

$failures = New-Object System.Collections.Generic.List[object]

foreach ($directory in $directories) {
    Write-Host "Validating Terraform directory: $directory" -ForegroundColor Cyan

    $terraformStatePath = Join-Path $directory '.terraform'
    $lockFilePath = Join-Path $directory '.terraform.lock.hcl'
    $hadTerraformState = Test-Path $terraformStatePath
    $hadLockFile = Test-Path $lockFilePath

    try {
        if (-not $SkipInit) {
            $initResult = Invoke-ExternalCommand -Command 'terraform' -Arguments @('init', '-backend=false', '-input=false', '-no-color') -WorkingDirectory $directory
            if ($initResult.ExitCode -ne 0) {
                $failures.Add([PSCustomObject]@{ Directory = $directory; Stage = 'init'; Output = ($initResult.Output -join [Environment]::NewLine) })
                continue
            }
        }

        $validateResult = Invoke-ExternalCommand -Command 'terraform' -Arguments @('validate', '-no-color') -WorkingDirectory $directory
        if ($validateResult.ExitCode -ne 0) {
            $failures.Add([PSCustomObject]@{ Directory = $directory; Stage = 'validate'; Output = ($validateResult.Output -join [Environment]::NewLine) })
            continue
        }
    }
    finally {
        if (-not $hadTerraformState -and (Test-Path $terraformStatePath)) {
            Remove-Item -Path $terraformStatePath -Recurse -Force
        }

        if (-not $hadLockFile -and (Test-Path $lockFilePath)) {
            Remove-Item -Path $lockFilePath -Force
        }
    }
}

if ($fmtResult.ExitCode -ne 0) {
    $failures.Add([PSCustomObject]@{ Directory = $Path; Stage = 'fmt'; Output = ($fmtResult.Output -join [Environment]::NewLine) })
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Terraform QA failures:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- [$($failure.Stage)] $($failure.Directory)" -ForegroundColor Red
        if ($failure.Output) {
            Write-Host $failure.Output -ForegroundColor DarkRed
        }
    }
}

$summary = [PSCustomObject]@{
    Path = $Path
    DirectoriesValidated = $directories.Count
    FmtPassed = ($fmtResult.ExitCode -eq 0)
    Failures = $failures.Count
    InitSkipped = $SkipInit.IsPresent
}

Write-Output $summary

if ($failures.Count -gt 0) {
    throw "Terraform QA failed with $($failures.Count) failure(s)."
}

Write-Host 'Terraform QA passed.' -ForegroundColor Green