#Requires -Version 7.0
<#
.SYNOPSIS
    Task 02. Creates the deployment repository or project from the Azure Local template. Orchestrated variant: reads the one infrastructure file.

.DESCRIPTION
    Creates the private repository (GitHub), project (GitLab) or project and repository (Azure DevOps) named in devops.repository and devops.project, from the template when devops.repository.template is set. The platform token comes from GH_TOKEN, GITLAB_TOKEN or AZURE_DEVOPS_EXT_PAT, or devops.api_token (a keyvault:// reference); GitHub and Azure DevOps also use the signed-in gh or az session.

    The orchestrated variant takes the infrastructure file as -ConfigPath and has no CONFIGURATION region. It is what the
    pipelines and the Deploy-Infrastructure.ps1 driver call. Idempotent; -WhatIf lists what it would do.

.PARAMETER ConfigPath
    The infrastructure file (infrastructure.yml, schema 5.5). Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml.

.PARAMETER LogPath
    The log file. Default: logs/task-02-create-project/<timestamp>.log.

.EXAMPLE
    ./Invoke-CicdProject-Orchestrated.ps1 -ConfigPath ./infrastructure.yml -WhatIf
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
$null = Initialize-AzlCicdLog -TaskName 'task-02-create-project' -LogPath $LogPath
$settings = Resolve-AzlCicdInput -InfrastructureFile $ConfigPath
$results = New-AzlCicdProject -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
