#Requires -Version 7.0
<#
.SYNOPSIS
    Task 04. Creates the deployment environments with their approval gates.

.DESCRIPTION
    Creates each environment in devops.environments, with required approvers and the branch it may deploy from. Include ztp-reinstall to put an approval in front of the azurelocal-ztp Boot stage.

    Reads the devops, azure, key_vaults and landing_zone sections of infrastructure.yml (schema 5.5). With no file it uses
    the CONFIGURATION region below. Idempotent: it creates what is missing and leaves the rest. -WhatIf reads what exists and
    lists what it would do.

.PARAMETER InfrastructureFile
    The infrastructure file. Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml.

.PARAMETER Platform
    Overrides devops.platform: github, gitlab or azure_devops.

.PARAMETER LogPath
    The log file. Default: logs/task-04-create-environments/<timestamp>.log.

.EXAMPLE
    ./New-CicdEnvironments.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./New-CicdEnvironments.ps1 -InfrastructureFile ./infrastructure.yml
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InfrastructureFile = '',
    [ValidateSet('', 'github', 'gitlab', 'azure_devops')]
    [string]$Platform = '',
    [string]$LogPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region CONFIGURATION
# Used only when no infrastructure file is given or found. The same keys as infrastructure.yml; fill in what the task needs.
$configuration = [ordered]@{
    azure  = [ordered]@{
        tenant_id           = ''
        subscription_id     = ''
        location            = ''
        resource_group      = ''
        automation_identity = [ordered]@{ name = 'azurelocal-cicd'; client_id = '' }
    }
    devops = [ordered]@{ platform = ''; url = ''; organization = ''; project = '' }
}
#endregion

function Get-CicdModulePath {
    $current = Get-Item -LiteralPath $PSScriptRoot
    while ($null -ne $current) {
        $candidate = Join-Path $current.FullName (Join-Path 'scripts' (Join-Path 'common' (Join-Path 'cicd-infra' 'AzlCicdInfra.psm1')))
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        $current = $current.Parent
    }
    throw "Unable to locate AzlCicdInfra.psm1 from '$PSScriptRoot'."
}

Import-Module (Get-CicdModulePath) -Force
$null = Initialize-AzlCicdLog -TaskName 'task-04-create-environments' -LogPath $LogPath
$settings = Resolve-AzlCicdInput -InfrastructureFile $InfrastructureFile -Platform $Platform -Configuration $configuration
$results = New-AzlCicdEnvironment -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
