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
    -TaskPath '04-cluster-deployment/phase-02-os-installation/task-02-mount-and-verify-dell-gold-image-iso' `
    -ActionName 'az-mount-gold-image-iso' `
    -ConfigPath $ConfigPath `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
