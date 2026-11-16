<#
.SYNOPSIS
    Verifies in Azure that the deployment of an Azure Local instance with Active Directory completed, with the Azure CLI. Read only.

.DESCRIPTION
    Phase 05 (cluster deployment), active-directory, task 02 (verify deployment completion), the Azure side. The work is done by
    phase-05-cluster-deployment/Test-AzureLocalClusterDeployment.azcli.ps1: the instance is Succeeded, the deployment status of the instance is Success
    and every Arc machine is Connected. This script adds one check: the file's scenario.identity must be active_directory, or it stops with exit code 2 before
    anything goes to Azure. The checks of the nodes and of the domain run on premises: use Invoke-VerifyPostDeployment.ps1 (phase 06, task 09).

    Exit codes: 0 every check passed (or planned under -WhatIf); 1 a check failed or a precondition failed; 2 a value in the file is missing or unusable,
    or scenario.identity is not active_directory.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ClusterDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$verification = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'Test-AzureLocalClusterDeployment.azcli.ps1'))
& $verification @PSBoundParameters -ExpectedIdentity 'active_directory'
exit $LASTEXITCODE
