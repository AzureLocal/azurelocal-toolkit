[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$EnvironmentName = '',
    [string]$ProjectName = '',
    [string]$SubscriptionId = '',
    [string]$ResourceGroupName = '',
    [string]$LogPath = ''
)

#region CONFIGURATION
$environment_name = 'ProjectIIC'
$project_name = 'Azure Local Toolkit'
$subscription_id = ''
$resource_group_name = ''
#endregion

if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { $EnvironmentName = $environment_name }
if ([string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName = $project_name }
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { $SubscriptionId = $subscription_id }
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { $ResourceGroupName = $resource_group_name }

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

Invoke-DeploymentStandalone `
    -ScriptPath $PSCommandPath `
    -TaskPath '01-cicd-infra/phase-01-cicd-setup/task-06-deploy-runners' `
    -ActionName 'Deploy-CicdRunners' `
    -LogPath $LogPath `
    -Parameters $PSBoundParameters `
    -Configuration [ordered]@{
        environment_name = $EnvironmentName
        project_name = $ProjectName
        subscription_id = $SubscriptionId
        resource_group_name = $ResourceGroupName
    }
