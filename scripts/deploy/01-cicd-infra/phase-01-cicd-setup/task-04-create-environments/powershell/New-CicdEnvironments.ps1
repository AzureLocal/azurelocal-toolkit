#Requires -Version 7.0
<#
.SYNOPSIS
    Task 04. Creates the deployment environments with their approval gates.

.DESCRIPTION
    Creates each environment in devops.environments, with required approvers and the branch it may deploy from. Include ztp-reinstall to put an approval in front of the azurelocal-ztp Boot stage.

    Reads the devops, azure, key_vaults and landing_zone sections of infrastructure.yml (schema 5).
    Idempotent: it creates what is missing and leaves the rest. -WhatIf reads what exists and
    lists what it would do.

    Exit codes: 0 done (created, already there, or planned under -WhatIf); 1 a call to the platform, Azure or Terraform failed; 2 the infrastructure file cannot be read or does not validate.

.PARAMETER InfrastructureFile
    The infrastructure file (infrastructure.yml, schema 5). Required: there is no default path.

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
$null = Initialize-AzlCicdLog -TaskName 'task-04-create-environments' -LogPath $LogPath
try { $settings = Resolve-AzlCicdInput -InfrastructureFile $InfrastructureFile -Platform $Platform }
catch { Write-Error "The infrastructure file cannot be used: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
try { $results = New-AzlCicdEnvironment -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false }
catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
exit 0
