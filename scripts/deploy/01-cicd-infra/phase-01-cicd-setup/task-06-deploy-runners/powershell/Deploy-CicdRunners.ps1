#Requires -Version 7.0
<#
.SYNOPSIS
    Task 06. Deploys the self-hosted runners (Linux and the Windows ztp runner) with Terraform.

.DESCRIPTION
    Runs terraform init, validate and plan for src/terraform/environments/cicd-infra, with the variables built from devops.runners, devops.runner_network and devops.runner_access. Apply happens only with -Apply, from the plan file that was just made. The runners read their registration credential from Key Vault at first boot.

    Reads the devops, azure, key_vaults and landing_zone sections of infrastructure.yml (schema 5.5). With no file it uses
    the CONFIGURATION region below. Idempotent: it creates what is missing and leaves the rest. -WhatIf reads what exists and
    lists what it would do.

.PARAMETER InfrastructureFile
    The infrastructure file. Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml.

.PARAMETER Platform
    Overrides devops.platform: github, gitlab or azure_devops.

.PARAMETER LogPath
    The log file. Default: logs/task-06-deploy-runners/<timestamp>.log.
.PARAMETER Apply
    Run terraform apply on the saved plan. Without it the script stops after the plan: nothing in Azure changes.
.PARAMETER VarFile
    A prepared terraform.tfvars (kept outside the repository) used instead of building the variables from infrastructure.yml.
.PARAMETER BackendConfigFile
    A backend.hcl for terraform init. Without it the backend comes from devops.state.
.PARAMETER BackendFalse
    terraform init -backend=false: validate and plan against local state, for a check with no state storage.
.PARAMETER WorkingDirectory
    Where the generated variables and the plan file go. Default: a temporary folder.
.PARAMETER AdminSshPublicKeyPath
    The public key for the Linux runners (a public key, not a secret). Or set AZL_RUNNER_SSH_PUBLIC_KEY.
.PARAMETER NoLock
    terraform plan -lock=false, for a read-only plan while another run holds the state lock.
.PARAMETER PlanFile
    Apply a plan that was made and reviewed earlier (the approval job of a pipeline), without planning again. Needs -Apply.

.EXAMPLE
    ./Deploy-CicdRunners.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Deploy-CicdRunners.ps1 -InfrastructureFile ./infrastructure.yml
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InfrastructureFile = '',
    [ValidateSet('', 'github', 'gitlab', 'azure_devops')]
    [string]$Platform = '',
    [string]$VarFile = '',
    [string]$BackendConfigFile = '',
    [switch]$BackendFalse,
    [string]$WorkingDirectory = '',
    [string]$AdminSshPublicKeyPath = '',
    [switch]$NoLock,
    [string]$PlanFile = '',
    [switch]$Apply,
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
$null = Initialize-AzlCicdLog -TaskName 'task-06-deploy-runners' -LogPath $LogPath
$settings = if ($VarFile -and -not $InfrastructureFile) { $null } else { Resolve-AzlCicdInput -InfrastructureFile $InfrastructureFile -Platform $Platform -Configuration $configuration }
$results = Invoke-AzlCicdRunnerDeployment -Settings $settings -VarFile $VarFile -BackendConfigFile $BackendConfigFile -BackendFalse:$BackendFalse -WorkingDirectory $WorkingDirectory -AdminSshPublicKeyPath $AdminSshPublicKeyPath -NoLock:$NoLock -PlanFile $PlanFile -Apply:$Apply -WhatIf:$WhatIfPreference -Confirm:$false
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
