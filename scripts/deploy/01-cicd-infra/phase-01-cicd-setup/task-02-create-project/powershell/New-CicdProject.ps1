#Requires -Version 7.0
<#
.SYNOPSIS
    Task 02. Creates the deployment repository or project from the Azure Local template.

.DESCRIPTION
    Creates the private repository (GitHub), project (GitLab) or project and repository (Azure DevOps) named in devops.repository and devops.project, from the template when devops.repository.template is set. The platform token comes from GH_TOKEN, GITLAB_TOKEN or AZURE_DEVOPS_EXT_PAT, or devops.api_token (a keyvault:// reference); GitHub and Azure DevOps also use the signed-in gh or az session.

    Reads the devops, azure, key_vaults and landing_zone sections of infrastructure.yml (schema 5).
    Idempotent: it creates what is missing and leaves the rest. -WhatIf reads what exists and
    lists what it would do.

    Exit codes: 0 done (created, already there, or planned under -WhatIf); 1 a call to the platform, Azure or Terraform failed; 2 the infrastructure file cannot be read or does not validate.

.PARAMETER InfrastructureFile
    The infrastructure file (infrastructure.yml, schema 5). Required: there is no default path.

.PARAMETER Platform
    Overrides devops.platform: github, gitlab or azure_devops.

.PARAMETER LogPath
    The log file. Default: logs/task-02-create-project/<timestamp>.log.

.EXAMPLE
    ./New-CicdProject.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./New-CicdProject.ps1 -InfrastructureFile ./infrastructure.yml
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [ValidateSet('', 'github', 'gitlab', 'azure_devops')]
    [string]$Platform = '',
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

Import-Module (Get-CicdModulePath)
$null = Initialize-AzlCicdLog -TaskName 'task-02-create-project' -LogPath $LogPath
try { $settings = Resolve-AzlCicdInput -InfrastructureFile $InfrastructureFile -Platform $Platform }
catch { Write-Error "The infrastructure file cannot be used: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
try { $results = New-AzlCicdProject -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false }
catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
exit 0
