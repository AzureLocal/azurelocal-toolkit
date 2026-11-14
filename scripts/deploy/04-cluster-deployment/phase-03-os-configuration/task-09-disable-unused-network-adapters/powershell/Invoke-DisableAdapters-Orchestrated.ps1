#Requires -Version 7.0
# PLACEHOLDER: this script does not do the task. It ends with exit code 3 (NOT IMPLEMENTED) and changes nothing.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InfrastructureFile = '',
    [System.Management.Automation.PSCredential]$Credential = $null,
    [string[]]$TargetNode = @(),
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

Invoke-DeploymentOrchestrated `
    -ScriptPath $PSCommandPath `
    -TaskPath '04-cluster-deployment/phase-03-os-configuration/task-09-disable-unused-network-adapters' `
    -ActionName 'Invoke-DisableAdapters-Orchestrated' `
    -InfrastructureFile $InfrastructureFile `
    -Credential $Credential `
    -TargetNode $TargetNode `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
