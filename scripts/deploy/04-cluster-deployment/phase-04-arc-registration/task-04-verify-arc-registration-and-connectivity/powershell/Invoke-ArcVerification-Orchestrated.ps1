#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 04, task 04: verifies that every machine is registered with Azure Arc and connected. Read only.

.DESCRIPTION
    A thin wrapper: it keeps the file name that this task folder and its guide page name, and runs the script that does the work.
    Two steps, both read only: Invoke-AzureLocalOsConfiguration.ps1 in Plan mode with the ArcRegistration step (per machine: does its Arc machine exist and
    is it Connected), then Invoke-AzureLocalArmDeployment.ps1 in Plan mode, which runs the checks before Validate (ArcMachinesConnected, ArcMachineNaming)
    from the report of the first step. Without -ReportDirectory the reports go to a new folder under the temp path of the account; the folder is named in
    the progress lines. The Azure CLI twin of this task is azurecli/Test-ArcRegistration.azcli.ps1.

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
    ./Invoke-ArcVerification-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
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

$base = if ($ReportDirectory) { $ReportDirectory } else { Join-Path ([System.IO.Path]::GetTempPath()) ('arc-verification-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$osReport = Join-Path $base 'osconfig-report'
$osArguments = @{ InfrastructureFile = $InfrastructureFile; Mode = 'Plan'; Step = @('ArcRegistration'); ReportDirectory = $osReport }
$armArguments = @{ InfrastructureFile = $InfrastructureFile; Mode = 'Plan'; OsConfigurationReport = $osReport; ReportDirectory = (Join-Path $base 'arm-plan') }
if ($Node) { $osArguments['Node'] = $Node }
if ($Credential) { $osArguments['Credential'] = $Credential }
if ($SettingsFile) { $osArguments['SettingsFile'] = $SettingsFile }
$osConfiguration = Get-DeploymentWrapperTarget -From $PSScriptRoot -Relative '04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1'
$armDeployment = Get-DeploymentWrapperTarget -From $PSScriptRoot -Relative '04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1'
$first = Invoke-DeploymentWrapperStep -ScriptPath $osConfiguration -Argument $osArguments -Label 'Arc registration plan' -WhatIf:$WhatIfPreference
# The ARM plan reads the report of the first step: it runs only when the first step ended with 0 (under -WhatIf both are only listed).
if ($first -eq 0) {
    $second = Invoke-DeploymentWrapperStep -ScriptPath $armDeployment -Argument $armArguments -Label 'ARM plan checks' -WhatIf:$WhatIfPreference
}
else {
    Write-Error 'The Arc registration plan did not end with 0, so the ARM plan checks were not run (they read its report).' -ErrorAction Continue
    $second = 1
}
exit ([Math]::Max($first, $second))
