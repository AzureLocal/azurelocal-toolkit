#Requires -Version 7.0
<#
.SYNOPSIS
    Task 05. Sets ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_CLIENT_ID and the backend variables per environment.

.DESCRIPTION
    Writes the Azure sign-in values to each environment: GitHub secrets, GitLab masked variables, an Azure DevOps variable group and, for Azure DevOps with OIDC, the workload identity federation service connection AzureLocal-ServiceConnection. With OIDC there is no client secret. With devops.authentication.method client_secret the secret is read from Key Vault and set as a masked value.

    It also sets the runner label and the approval environments the pipelines select (devops.pipelines.runner_label and devops.pipelines.environments.*): GitHub repository variables and GitLab project CI/CD variables named AZL_RUNNER_LABEL and AZL_ENVIRONMENT_..., the same for all environments. Azure DevOps reads the agent pool and the environment of a job before any variable exists, so there they are run parameters with no default: the task changes nothing and lists the value to enter for each (devops.runners[].pool of the general runner, and the environments). A label that the general runner does not have, or an environment that devops.environments[] does not list with approval_required true, stops the task.

    Reads the devops (including devops.pipelines and devops.runners[].pool/labels), azure, key_vaults and landing_zone sections of infrastructure.yml (schema 5).
    Idempotent: it creates what is missing and leaves the rest. -WhatIf reads what exists and
    lists what it would do.

    Exit codes: 0 done (created, already there, or planned under -WhatIf); 1 a call to the platform, Azure or Terraform failed; 2 the infrastructure file cannot be read or does not validate.

.PARAMETER InfrastructureFile
    The infrastructure file (infrastructure.yml, schema 5). Required: there is no default path.

.PARAMETER Platform
    Overrides devops.platform: github, gitlab or azure_devops.

.PARAMETER LogPath
    The log file. Default: logs/task-05-configure-variables/<timestamp>.log.
.PARAMETER ClientId
    The app registration's client ID (an identifier, not a secret). Default: azure.automation_identity.client_id, else looked up by name.

.EXAMPLE
    ./Set-CicdVariables.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Set-CicdVariables.ps1 -InfrastructureFile ./infrastructure.yml
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [ValidateSet('', 'github', 'gitlab', 'azure_devops')]
    [string]$Platform = '',
    [string]$ClientId = '',
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
$null = Initialize-AzlCicdLog -TaskName 'task-05-configure-variables' -LogPath $LogPath
try { $settings = Resolve-AzlCicdInput -InfrastructureFile $InfrastructureFile -Platform $Platform }
catch { Write-Error "The infrastructure file cannot be used: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
try { $results = Set-AzlCicdVariable -Settings $settings -ClientId $ClientId -WhatIf:$WhatIfPreference -Confirm:$false }
catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
exit 0
