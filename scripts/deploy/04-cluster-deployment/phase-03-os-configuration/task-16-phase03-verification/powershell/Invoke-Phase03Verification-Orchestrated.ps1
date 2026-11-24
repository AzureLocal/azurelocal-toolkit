#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 03, task 16: verifies the OS configuration of every node against infrastructure.yml. Read only.

.DESCRIPTION
    A thin wrapper: it keeps the file name that this task folder and its guide page name, and runs the script that does the work.
    Two steps, both read only, each run even when the other failed: Invoke-AzureLocalOsConfiguration.ps1 in Plan mode with -FailOnPendingChanges
    (exit 1 while any change is still pending against infrastructure.yml), then Invoke-AzureLocalPreClusterVerification.ps1 in Verify mode with the nodes
    category (checks ND-001 to ND-012). With -ReportDirectory the reports go to its os-configuration and pre-cluster folders.

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
    ./Invoke-Phase03Verification-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
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

$osArguments = @{ InfrastructureFile = $InfrastructureFile; Mode = 'Plan'; FailOnPendingChanges = $true }
$verifyArguments = @{ InfrastructureFile = $InfrastructureFile; Mode = 'Verify'; Category = @('nodes') }
if ($Node) { $osArguments['Node'] = $Node }
if ($Credential) { $osArguments['Credential'] = $Credential }
if ($SettingsFile) { $osArguments['SettingsFile'] = $SettingsFile; $verifyArguments['SettingsFile'] = $SettingsFile }
if ($ReportDirectory) { $osArguments['ReportDirectory'] = Join-Path $ReportDirectory 'os-configuration'; $verifyArguments['ReportDirectory'] = Join-Path $ReportDirectory 'pre-cluster' }
$osConfiguration = Get-DeploymentWrapperTarget -From $PSScriptRoot -Relative '04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
$preCluster = Get-DeploymentWrapperTarget -From $PSScriptRoot -Relative '04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalPreClusterVerification.ps1'
$first = Invoke-DeploymentWrapperStep -ScriptPath $osConfiguration -Argument $osArguments -Label 'OS configuration plan' -WhatIf:$WhatIfPreference
$second = Invoke-DeploymentWrapperStep -ScriptPath $preCluster -Argument $verifyArguments -Label 'Node checks' -PartialIsPass -WhatIf:$WhatIfPreference
exit ([Math]::Max($first, $second))
