[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = '',
    [string]$LogPath = ''
)

function Get-DeploymentCommonModulePath {
    $current = Get-Item -LiteralPath $PSScriptRoot
    while ($null -ne $current) {
        $candidate = Join-Path $current.FullName 'scripts\deploy\common\DeploymentScaffold.psm1'
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
    -TaskPath '04-cluster-deployment/phase-04-arc-registration/task-01-pre-registration-validation' `
    -ActionName 'az-test-arc-prerequisites' `
    -ConfigPath $ConfigPath `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
