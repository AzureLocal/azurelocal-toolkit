#Requires -Version 7.0
<#
.SYNOPSIS
    Task 05. Sets every value the toolkit's pipelines read, each from its key of infrastructure.yml: the sign-in, the state, the runner, the approval environments, the paths, the tool versions, the job timeouts and the schedule.

.DESCRIPTION
    Writes the Azure sign-in and state values for the repository and for each environment: ARM_TENANT_ID, ARM_SUBSCRIPTION_ID and ARM_CLIENT_ID
    (identifiers, plain variables), ARM_USE_OIDC (devops.authentication.method oidc) or ARM_CLIENT_SECRET (client_secret: read from Key Vault and
    set as a masked value or secret), and TF_BACKEND_RG, TF_BACKEND_SA, TF_BACKEND_CONTAINER and TF_BACKEND_KEY (devops.state.resource_group,
    storage_account, container and azure_local_key). GitHub: repository and environment variables and secrets; GitLab: project CI/CD variables
    (scope * and per environment); Azure DevOps: the repository variable group devops.pipelines.variable_group and one per environment
    (<name>-<environment>), and, for Azure DevOps with OIDC, the workload identity federation service connection devops.pipelines.service_connection.

    It also sets every value the pipelines under pipelines/ select or read (the table $script:AzlPipelineVariable of AzlCicdInfra.psm1), as
    GitHub repository variables and GitLab project CI/CD variables for all environments: AZL_RUNNER_LABEL (devops.pipelines.runner_label),
    AZL_RUNNER_OS (devops.runners[].os_type of the general runner, GitHub), AZL_ENVIRONMENT_* (devops.pipelines.environments.*),
    the path of the infrastructure file and AZL_HANDOFF_PATH (devops.pipelines.infrastructure_file, handoff_path), AZL_AUTH_METHOD (devops.authentication.method),
    AZL_TERRAFORM_VERSION, AZL_PYTHON_VERSION, AZL_ANSIBLE_CORE_VERSION, AZL_ANSIBLE_LINT_VERSION, AZL_AZ_POWERSHELL_VERSION,
    AZL_POWERSHELL_YAML_VERSION and AZL_AZ_KEYVAULT_VERSION (devops.pipelines.tool_versions.*), AZL_VALIDATE_JOB_TIMEOUT_MINUTES and
    AZL_DEPLOY_JOB_TIMEOUT_MINUTES (deployment.validate_timeout_minutes and deploy_timeout_minutes plus 60 minutes, GitHub) and
    AZL_RUNNER_SSH_PUBLIC_KEY (devops.runners[].admin_ssh_public_key of the Linux runner; a reference is read through the secret resolver).
    A key that is not set takes its registry default. On Azure DevOps it writes AZL_AUTH_METHOD, AZL_DEFAULT_BRANCH (devops.repository.default_branch),
    the tool versions and the runner public key to the variable groups.

    The files of the repository (owner directive D126: one CI/CD design on GitHub, GitLab and Azure DevOps, every value from infrastructure.yml, no
    run parameter carrying a deployment value). Azure DevOps reads the agent pool, the service connection, the variable group, the file paths and the
    approval environments when a pipeline is compiled, before any variable exists, and GitHub and Azure DevOps read a schedule only from the pipeline
    file. So the script also writes those values into the files under RepositoryRoot: on Azure DevOps pipelines/azure-devops/variables/pipeline-settings.yml
    (AZL_AGENT_POOL, AZL_SERVICE_CONNECTION, AZL_VARIABLE_GROUP and its `- group:` entry, the path of the infrastructure file, AZL_HANDOFF_PATH),
    variables/approval-environments.yml (AZL_ENVIRONMENT_*) and the cron line and branch of pipelines/azure-devops/day2-check-updates.yml; on GitHub the
    cron line of day2-check-updates.yml (devops.pipelines.schedules.check_for_updates). On GitLab, which keeps a schedule in the project, it creates or
    updates the project pipeline schedule of the check for updates instead. Commit the changed files in a pull request.

    A label that the general runner does not have, or an environment that devops.environments[] does not list with approval_required true, stops the
    task before it changes anything.

    Reads the devops (including devops.pipelines, devops.state and devops.runners[]), azure, deployment, key_vaults and landing_zone sections of infrastructure.yml (schema 5).
    Idempotent: it creates what is missing and leaves the rest. -WhatIf reads what exists and
    lists what it would do.

    Exit codes: 0 done (created, already there, or planned under -WhatIf); 1 a call to the platform, Azure or Terraform failed, or a pipeline file is
    missing; 2 the infrastructure file cannot be read or does not validate.

.PARAMETER InfrastructureFile
    The infrastructure file (infrastructure.yml, schema 5). Required: there is no default path.

.PARAMETER Platform
    Overrides devops.platform: github, gitlab or azure_devops.

.PARAMETER ClientId
    The app registration's client ID (an identifier, not a secret). Default: azure.automation_identity.client_id, else looked up by name.

.PARAMETER RepositoryRoot
    The root of the repository whose pipeline files are written (D126). Default: the repository this script is in.

.PARAMETER GitHubWorkflowDirectory
    GitHub only: the folder of day2-check-updates.yml, relative to RepositoryRoot. Default: .github/workflows when the workflow is there, else
    pipelines/github-actions.

.PARAMETER LogPath
    The log file. Default: logs/task-05-configure-variables/<timestamp>.log.

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
    [string]$RepositoryRoot = '',
    [string]$GitHubWorkflowDirectory = '',
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

$modulePath = Get-CicdModulePath
Import-Module $modulePath
if (-not $RepositoryRoot) { $RepositoryRoot = [IO.Path]::GetFullPath([IO.Path]::Combine((Split-Path -Path $modulePath -Parent), '..', '..', '..')) }
$null = Initialize-AzlCicdLog -TaskName 'task-05-configure-variables' -LogPath $LogPath
try { $settings = Resolve-AzlCicdInput -InfrastructureFile $InfrastructureFile -Platform $Platform }
catch { Write-Error "The infrastructure file cannot be used: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }
try {
    $results = @(Set-AzlCicdVariable -Settings $settings -ClientId $ClientId -WhatIf:$WhatIfPreference -Confirm:$false)
    # D126: the values a platform reads only from a file of the repository (the Azure DevOps settings files, the cron line of the schedule).
    $results += @(Export-AzlCicdPipelineSetting -Settings $settings -RepositoryRoot $RepositoryRoot -GitHubWorkflowDirectory $GitHubWorkflowDirectory -WhatIf:$WhatIfPreference -Confirm:$false)
}
catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
exit 0
