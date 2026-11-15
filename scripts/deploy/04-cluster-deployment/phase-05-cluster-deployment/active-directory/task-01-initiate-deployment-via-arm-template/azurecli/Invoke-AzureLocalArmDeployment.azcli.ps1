<#
.SYNOPSIS
    Starts the ARM template deployment of an Azure Local instance with Active Directory identity, with the Azure CLI: az deployment group validate, then az deployment group create.

.DESCRIPTION
    Phase 05 (cluster deployment), active-directory, task 01 (initiate deployment via ARM template). Azure CLI variant of the ARM deployment. The work is done by
    phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.azcli.ps1, which reuses the toolkit's ARM deployment code (the parameter set built from
    infrastructure.yml, the quickstart template of the design, the validate-then-deploy order) and calls az for Azure. This script adds one check: the file's
    scenario.identity must be active_directory, or it stops with exit code 2 before anything goes to Azure. Read that script's help for the steps, the secrets
    (Key Vault references only) and the exit codes.

    Exit codes: 0 the requested step succeeded (or planned under -WhatIf, or submitted with -NoWait); 1 a precondition, the pre-flight, the validation or the
    deployment failed, or the wait timed out; 2 a value in the file is missing or unusable, or scenario.identity is not active_directory.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2): the Arc machine resource IDs and the solution build. Optional.

.PARAMETER OsConfigurationReport
    The OS configuration report: its report.json, a node-level report, or its report directory. Optional.

.PARAMETER Mode
    Validate (default) or Deploy. Deploy needs a successful Validate of the same parameters.

.PARAMETER ReportDirectory
    Where the parameter file goes. Default: a folder in the temp directory. Keep it out of the repository.

.PARAMETER TemplateFile
    A local copy of the quickstart template, instead of the address in the template catalog.

.PARAMETER TimeoutMinutes
    The longest time to wait for the outcome. Default: the run setting of the mode.

.PARAMETER NoWait
    Submit and return. Run the script again to attach to the running deployment.

.PARAMETER Resume
    Resubmit a failed Deploy.

.PARAMETER AllowRevalidate
    Allow Validate on an instance in a failed deployment state (support-guided recovery only).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-AzureLocalArmDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Validate -WhatIf
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string]$OsConfigurationReport,
    [ValidateSet('Validate', 'Deploy')][string]$Mode = 'Validate',
    [string]$ReportDirectory,
    [string]$TemplateFile,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes,
    [switch]$NoWait,
    [switch]$Resume,
    [switch]$AllowRevalidate,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$deployment = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'Invoke-AzureLocalArmDeployment.azcli.ps1'))
& $deployment @PSBoundParameters -ExpectedIdentity 'active_directory'
exit $LASTEXITCODE
