#Requires -Version 7.0
<#
.SYNOPSIS
    Task 06. Deploys the self-hosted runners (Linux and the Windows ztp runner) with Terraform. Orchestrated variant: reads the one infrastructure file.

.DESCRIPTION
    Runs terraform init, validate and plan for src/terraform/environments/cicd-infra, with the variables built from devops.runners, devops.runner_network and devops.runner_access. Apply happens only with -Apply, from the plan file that was just made. The runners read their registration credential from Key Vault at first boot.

    The orchestrated variant takes the infrastructure file as -ConfigPath and has no CONFIGURATION region. It is what the
    pipelines and the Deploy-Infrastructure.ps1 driver call. Idempotent; -WhatIf lists what it would do.

.PARAMETER ConfigPath
    The infrastructure file (infrastructure.yml, schema 5.5). Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml.

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
    ./Invoke-CicdRunners-Orchestrated.ps1 -ConfigPath ./infrastructure.yml -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = '',
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
$settings = if ($VarFile -and -not $ConfigPath) { $null } else { Resolve-AzlCicdInput -InfrastructureFile $ConfigPath }
$results = Invoke-AzlCicdRunnerDeployment -Settings $settings -VarFile $VarFile -BackendConfigFile $BackendConfigFile -BackendFalse:$BackendFalse -WorkingDirectory $WorkingDirectory -AdminSshPublicKeyPath $AdminSshPublicKeyPath -NoLock:$NoLock -PlanFile $PlanFile -Apply:$Apply -WhatIf:$WhatIfPreference -Confirm:$false
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
