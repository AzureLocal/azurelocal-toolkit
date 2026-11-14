#Requires -Version 7.0
# PLACEHOLDER: this script does not do the task. It ends with exit code 3 (NOT IMPLEMENTED) and changes nothing.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DeploymentCommonModulePath {
    $current = Get-Item -LiteralPath $PSScriptRoot
    while ($null -ne $current) {
        $candidate = [System.IO.Path]::Combine($current.FullName, 'scripts', 'deploy', 'common', 'DeploymentScaffold.psm1')
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }

        $current = $current.Parent
    }

    throw "Unable to locate DeploymentScaffold.psm1 from '$PSScriptRoot'."
}

Import-Module (Get-DeploymentCommonModulePath) -Force

Invoke-DeploymentAzCliPowerShell `
    -ScriptPath $PSCommandPath `
    -TaskPath '04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-01-initiate-deployment-via-arm-template' `
    -ActionName 'az-deploy-cluster' `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
