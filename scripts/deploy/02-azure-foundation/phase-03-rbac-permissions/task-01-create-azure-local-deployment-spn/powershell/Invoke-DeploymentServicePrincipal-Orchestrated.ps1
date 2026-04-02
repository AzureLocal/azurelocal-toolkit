[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = '',
    [System.Management.Automation.PSCredential]$Credential = $null,
    [string[]]$TargetNode = @(),
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

Invoke-DeploymentOrchestrated `
    -ScriptPath $PSCommandPath `
    -TaskPath '02-azure-foundation/phase-03-rbac-permissions/task-01-create-azure-local-deployment-spn' `
    -ActionName 'Invoke-DeploymentServicePrincipal-Orchestrated' `
    -ConfigPath $ConfigPath `
    -Credential $Credential `
    -TargetNode $TargetNode `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters
