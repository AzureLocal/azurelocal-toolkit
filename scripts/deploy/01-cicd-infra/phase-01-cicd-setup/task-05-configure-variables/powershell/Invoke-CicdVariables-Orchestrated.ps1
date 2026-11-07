#Requires -Version 7.0
<#
.SYNOPSIS
    Task 05. Sets ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_CLIENT_ID and the backend variables per environment. Orchestrated variant: reads the one infrastructure file.

.DESCRIPTION
    Writes the Azure sign-in values to each environment: GitHub secrets, GitLab masked variables, an Azure DevOps variable group and, for Azure DevOps with OIDC, the workload identity federation service connection AzureLocal-ServiceConnection. With OIDC there is no client secret. With devops.authentication.method client_secret the secret is read from Key Vault and set as a masked value.

    The orchestrated variant takes the infrastructure file as -ConfigPath and has no CONFIGURATION region. It is what the
    pipelines and the Deploy-Infrastructure.ps1 driver call. Idempotent; -WhatIf lists what it would do.

.PARAMETER ConfigPath
    The infrastructure file (infrastructure.yml, schema 5.5). Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml.

.PARAMETER LogPath
    The log file. Default: logs/task-05-configure-variables/<timestamp>.log.
.PARAMETER ClientId
    The app registration's client ID (an identifier, not a secret). Default: azure.automation_identity.client_id, else looked up by name.

.EXAMPLE
    ./Invoke-CicdVariables-Orchestrated.ps1 -ConfigPath ./infrastructure.yml -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = '',
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

Import-Module (Get-CicdModulePath) -Force
$null = Initialize-AzlCicdLog -TaskName 'task-05-configure-variables' -LogPath $LogPath
$settings = Resolve-AzlCicdInput -InfrastructureFile $ConfigPath
$results = Set-AzlCicdVariable -Settings $settings -ClientId $ClientId -WhatIf:$WhatIfPreference -Confirm:$false
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
