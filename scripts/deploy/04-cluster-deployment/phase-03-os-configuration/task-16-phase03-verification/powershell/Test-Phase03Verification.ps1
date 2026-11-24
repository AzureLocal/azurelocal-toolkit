#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 03, task 16: the Test- name of Invoke-Phase03Verification-Orchestrated.ps1. Read only.

.DESCRIPTION
    A thin wrapper: it keeps the file name that this task folder and its guide page name, and runs the script that does the work.
    Runs Invoke-Phase03Verification-Orchestrated.ps1 of this folder with the same arguments (OS configuration plan with -FailOnPendingChanges, then the
    nodes checks of the pre-cluster verification).

    Exit codes: 0 passed or planned (a partial pre-cluster run with no blocking result is reported as 0), 1 a check failed or a node did not converge, 2 bad input (also a missing file).
    -WhatIf prints the command line of each step and runs none.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER Node
    Optional. Limit the run to these nodes (node names).

.PARAMETER ReportDirectory
    Optional. Where the script writes its report (report.json and summary.md).

.PARAMETER SettingsFile
    Optional. The run settings file (JSON) of the script that does the work.

.PARAMETER Credential
    Optional. The login for the nodes. Without it the account of the file is used. The script never asks.

.EXAMPLE
    ./Test-Phase03Verification.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$Node,
    [string]$ReportDirectory,
    [string]$SettingsFile,
    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DeploymentWrapperModulePath {
    $current = Get-Item -LiteralPath $PSScriptRoot
    while ($null -ne $current) {
        $candidate = [System.IO.Path]::Combine($current.FullName, 'scripts', 'deploy', 'common', 'DeploymentWrapper.psm1')
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        $current = $current.Parent
    }

    throw "Unable to locate DeploymentWrapper.psm1 from '$PSScriptRoot'."
}

Import-Module (Get-DeploymentWrapperModulePath) -Force

if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) {
    Write-Error "Cannot read the infrastructure file '$InfrastructureFile'." -ErrorAction Continue
    exit 2
}

$arguments = @{ InfrastructureFile = $InfrastructureFile }
if ($Node) { $arguments['Node'] = $Node }
if ($ReportDirectory) { $arguments['ReportDirectory'] = $ReportDirectory }
if ($SettingsFile) { $arguments['SettingsFile'] = $SettingsFile }
if ($Credential) { $arguments['Credential'] = $Credential }
exit (Invoke-DeploymentWrapperStep -ScriptPath (Join-Path $PSScriptRoot 'Invoke-Phase03Verification-Orchestrated.ps1') -Argument $arguments -Label 'Phase 03 verification' -WhatIf:$WhatIfPreference)
