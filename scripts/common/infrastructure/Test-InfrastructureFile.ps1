#Requires -Version 7.0
<#
.SYNOPSIS
    Checks an infrastructure.yml file against schema 5 and the Azure Local rules, and lists every finding.

.DESCRIPTION
    Exits 0 when the file has no errors (warnings are listed but don't fail), 1 when it has errors. Use it by hand, in a
    pipeline, or as the tools\Validate-Infrastructure.ps1 that azurelocal-ztp runs before a provisioning run.

.PARAMETER Path
    The infrastructure file.

.PARAMETER AsJson
    Write the findings as JSON instead of a table, for other tools to read.

.EXAMPLE
    ./scripts/common/infrastructure/Test-InfrastructureFile.ps1 -Path ./infrastructure.yml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$AsJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AzlInfrastructure.psm1') -Force
$findings = @(Test-AzlInfrastructure -Path $Path)
$errors = @($findings | Where-Object Severity -eq 'error')

if ($AsJson) {
    ConvertTo-Json -InputObject @($findings) -Depth 4
} elseif ($findings.Count -eq 0) {
    Write-Host "$Path is valid."
} else {
    $findings | Sort-Object { @{ error = 0; warning = 1; info = 2 }[$_.Severity] }, Path |
        Format-Table Severity, Id, Path, Message -Wrap | Out-String -Width 200 | Write-Host
    Write-Host ("{0} error(s), {1} warning(s)." -f $errors.Count, ($findings.Count - $errors.Count))
}
exit ([int]($errors.Count -gt 0))
