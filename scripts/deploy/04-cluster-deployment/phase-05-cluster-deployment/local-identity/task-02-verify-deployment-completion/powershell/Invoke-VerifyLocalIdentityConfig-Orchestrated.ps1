#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 05 (local identity), task 02: verifies the deployed cluster. Read only.

.DESCRIPTION
    A thin wrapper: it keeps the file name that this task folder and its guide page name, and runs the script that does the work.
    The work is done by Invoke-PostDeploymentVerification-Orchestrated.ps1 (phase-06-post-deployment, task 09): the node checks, the Azure checks, the solution
    health summary and, with an external SAN, the SAN disks. The local identity checks of the nodes are part of its node checks.

    Exit codes: 0 passed or planned (a partial pre-cluster run with no blocking result is reported as 0), 1 a check failed or a node did not converge, 2 bad input (also a missing file).
    -WhatIf prints the command line of each step and runs none.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER Credential
    Optional. The login for the nodes. Without it the account of the file is used. The script never asks.

.PARAMETER TargetNode
    Optional. Limit the node checks to these nodes (node names or management addresses).

.PARAMETER SkipAzure
    Optional. Leave out the Azure checks (for a host without the Azure CLI).

.PARAMETER LogPath
    Optional. A log file for the progress lines. Keep it out of the repository.

.EXAMPLE
    ./Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [string[]]$TargetNode,
    [switch]$SkipAzure,
    [string]$LogPath
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
if ($Credential) { $arguments['Credential'] = $Credential }
if ($TargetNode) { $arguments['TargetNode'] = $TargetNode }
if ($SkipAzure) { $arguments['SkipAzure'] = $true }
if ($LogPath) { $arguments['LogPath'] = $LogPath }
$target = Get-DeploymentWrapperTarget -From $PSScriptRoot -Relative '04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-PostDeploymentVerification-Orchestrated.ps1'
exit (Invoke-DeploymentWrapperStep -ScriptPath $target -Argument $arguments -Label 'Local identity verification' -WhatIf:$WhatIfPreference)
