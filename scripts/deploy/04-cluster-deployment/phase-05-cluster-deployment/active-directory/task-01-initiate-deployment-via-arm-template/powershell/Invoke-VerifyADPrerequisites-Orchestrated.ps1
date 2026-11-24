#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 05 (Active Directory), task 01: checks Active Directory from the management host before the deployment. Read only.

.DESCRIPTION
    A thin wrapper: it keeps the file name that this task folder and its guide page name, and runs the script that does the work.
    The work is done by Invoke-AzureLocalPreClusterVerification.ps1 (phase-05-cluster-deployment) in Verify mode with the identity category: the OU,
    the LCM user and its delegation, and the domain values of the file.

    Exit codes: 0 passed or planned (a partial pre-cluster run with no blocking result is reported as 0), 1 a check failed or a node did not converge, 2 bad input (also a missing file).
    -WhatIf prints the command line of each step and runs none.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER ReportDirectory
    Optional. Where the script writes its report (report.json and summary.md).

.PARAMETER SettingsFile
    Optional. The run settings file (JSON) of the script that does the work.

.EXAMPLE
    ./Invoke-VerifyADPrerequisites-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ReportDirectory,
    [string]$SettingsFile
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

$arguments = @{ InfrastructureFile = $InfrastructureFile; Mode = 'Verify'; Category = @('identity') }
if ($ReportDirectory) { $arguments['ReportDirectory'] = $ReportDirectory }
if ($SettingsFile) { $arguments['SettingsFile'] = $SettingsFile }
$target = Get-DeploymentWrapperTarget -From $PSScriptRoot -Relative '04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalPreClusterVerification.ps1'
exit (Invoke-DeploymentWrapperStep -ScriptPath $target -Argument $arguments -Label 'Active Directory prerequisites' -PartialIsPass -WhatIf:$WhatIfPreference)
