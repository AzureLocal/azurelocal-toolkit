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
    -TaskPath '05-operational-foundations/phase-02-monitoring-observability/task-05-deploy-wac' `
    -ActionName 'az-deploy-wac' `
    -ConfigPath $ConfigPath `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
