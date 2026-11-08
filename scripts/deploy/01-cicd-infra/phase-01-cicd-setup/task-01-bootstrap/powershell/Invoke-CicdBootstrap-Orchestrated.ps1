#Requires -Version 7.0
<#
.SYNOPSIS
    Task 01. Creates the CI/CD service principal and its Azure access. Orchestrated variant: reads the one infrastructure file.

.DESCRIPTION
    Creates the app registration and service principal (azure.automation_identity.name), its federated credentials for the platform (or, with devops.authentication.method client_secret, a client secret stored only in Key Vault), the role assignments on each subscription, and the Microsoft.Compute and EncryptionAtHost registrations. Needs az login as someone who can create app registrations and assign roles.

    The orchestrated variant takes the infrastructure file as -ConfigPath and has no CONFIGURATION region. It is what the
    pipelines and the Deploy-Infrastructure.ps1 driver call. Idempotent; -WhatIf lists what it would do.

.PARAMETER ConfigPath
    The infrastructure file (infrastructure.yml, schema 5.5). Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml.

.PARAMETER LogPath
    The log file. Default: logs/task-01-bootstrap/<timestamp>.log.

.EXAMPLE
    ./Invoke-CicdBootstrap-Orchestrated.ps1 -ConfigPath ./infrastructure.yml -WhatIf
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
$null = Initialize-AzlCicdLog -TaskName 'task-01-bootstrap' -LogPath $LogPath
$settings = Resolve-AzlCicdInput -InfrastructureFile $ConfigPath
$results = Invoke-AzlCicdBootstrap -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false
$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
