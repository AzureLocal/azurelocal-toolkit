#Requires -Version 7.0
<#
.SYNOPSIS
    Task 04. Creates the deployment environments with their approval gates. Orchestrated variant: reads the one infrastructure file.

.DESCRIPTION
    Creates each environment in devops.environments, with required approvers and the branch it may deploy from. Include ztp-reinstall to put an approval in front of the azurelocal-ztp Boot stage.

    The orchestrated variant takes the infrastructure file as -ConfigPath and has no CONFIGURATION region. It is what the
    pipelines and the Deploy-Infrastructure.ps1 driver call. Idempotent; -WhatIf lists what it would do.

.PARAMETER ConfigPath
    The infrastructure file (infrastructure.yml, schema 5.5). Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml.

.PARAMETER LogPath
    The log file. Default: logs/task-04-create-environments/<timestamp>.log.

.EXAMPLE
    ./Invoke-CicdEnvironments-Orchestrated.ps1 -ConfigPath ./infrastructure.yml -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = '',
    [string]$LogPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$settings = Resolve-AzlCicdInput -InfrastructureFile $ConfigPath
$results = New-AzlCicdEnvironment -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
