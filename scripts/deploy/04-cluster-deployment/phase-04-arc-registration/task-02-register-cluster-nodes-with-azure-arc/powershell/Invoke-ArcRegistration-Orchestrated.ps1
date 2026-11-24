#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 04, task 02: registers the nodes with Azure Arc (the ArcRegistration step of the OS configuration). Plan by default.

.DESCRIPTION
    A thin wrapper: it keeps the file name that this task folder and its guide page name, and runs the script that does the work.
    The work is done by Invoke-AzureLocalOsConfiguration.ps1 (phase-03-os-configuration), step ArcRegistration. In Plan mode (the default) it reads each
    machine and lists whether its Arc machine exists and is Connected; it changes nothing. With -Mode Apply it registers a machine that was installed from
    an ISO. A machine that ZTP provisioned is already registered.

    Exit codes: 0 passed or planned (a partial pre-cluster run with no blocking result is reported as 0), 1 a check failed or a node did not converge, 2 bad input (also a missing file).
    -WhatIf prints the command line of each step and runs none.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER Node
    Optional. Limit the run to these nodes (node names).

.PARAMETER Mode
    Plan (the default) reads and lists what would change; Apply makes the change.

.PARAMETER ReportDirectory
    Optional. Where the script writes its report (report.json and summary.md).

.PARAMETER SettingsFile
    Optional. The run settings file (JSON) of the script that does the work.

.PARAMETER Credential
    Optional. The login for the nodes. Without it the account of the file is used. The script never asks.

.EXAMPLE
    ./Invoke-ArcRegistration-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string[]]$Node,
    [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
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

$arguments = @{ InfrastructureFile = $InfrastructureFile; Mode = $Mode; Step = @('ArcRegistration') }
if ($Node) { $arguments['Node'] = $Node }
if ($ReportDirectory) { $arguments['ReportDirectory'] = $ReportDirectory }
if ($SettingsFile) { $arguments['SettingsFile'] = $SettingsFile }
if ($Credential) { $arguments['Credential'] = $Credential }
$target = Get-DeploymentWrapperTarget -From $PSScriptRoot -Relative '04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
exit (Invoke-DeploymentWrapperStep -ScriptPath $target -Argument $arguments -Label 'Arc registration' -WhatIf:$WhatIfPreference)
