#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$VariablesPath,
    [string]$RegistryPath,
    [string]$SchemaPath,
    [switch]$StrictUnknown
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$configRoot = Join-Path $repoRoot 'config\variables'

if (-not $VariablesPath) {
    $VariablesPath = Join-Path $configRoot 'variables.example.yml'
}

if (-not $RegistryPath) {
    $RegistryPath = Join-Path $configRoot 'schema\master-registry.yaml'
}

if (-not $SchemaPath) {
    $SchemaPath = Join-Path $configRoot 'schema\variables.schema.json'
}

$registryValidator = Join-Path $configRoot 'scripts\validate-registry.ps1'
$variablesValidator = Join-Path $configRoot 'scripts\validate-variables.ps1'

foreach ($requiredPath in @($VariablesPath, $RegistryPath, $SchemaPath, $registryValidator, $variablesValidator)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required path not found: $requiredPath"
    }
}

$results = New-Object System.Collections.Generic.List[object]

Write-Host 'Running registry validation...' -ForegroundColor Cyan
& $registryValidator -RegistryPath $RegistryPath
$results.Add([PSCustomObject]@{ Step = 'validate-registry'; Status = 'Passed' })

Write-Host 'Running variable validation...' -ForegroundColor Cyan
$variableArgs = @{
    VariablesPath = $VariablesPath
    RegistryPath = $RegistryPath
    SchemaPath = $SchemaPath
}

if ($StrictUnknown) {
    $variableArgs.StrictUnknown = $true
}

& $variablesValidator @variableArgs
$results.Add([PSCustomObject]@{ Step = 'validate-variables'; Status = 'Passed' })

$summary = [PSCustomObject]@{
    VariablesPath = $VariablesPath
    RegistryPath = $RegistryPath
    SchemaPath = $SchemaPath
    StrictUnknown = $StrictUnknown.IsPresent
    StepsPassed = $results.Count
}

Write-Output $summary
Write-Host 'Variable configuration QA passed.' -ForegroundColor Green