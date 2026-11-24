#Requires -Version 7.0
<#
.SYNOPSIS
    The whole post-deployment phase (phase 06 of the Implementation guide) in ONE run, in page order: plan, then apply. Every task also runs alone.

.DESCRIPTION
    The one entry point of the post-deployment phase. The same command runs on an operator's workstation and, unchanged, in a CI/CD pipeline. It runs the
    task scripts of the eleven pages of docs/implementation/04-cluster-deployment/phase-06-post-deployment in the order of the pages:

      task 01 SDN (Enable-ArcSdn.ps1), 02 quorum, 03 security groups, 04 SSH, 05 storage (volumes, then storage paths), 06 VM images, 07 network
      security groups, 08 logical networks, 09 verification, 10 external storage (hybrid S2D plus SAN), 11 SBE import plan.

    The steps, their order and what makes each one apply live in ONE table, PostDeploymentSteps.psd1 next to this script; a test compares it with the
    pages. A step whose keys the file does not set (sdn.enabled, storage.volumes, storage.paths, storage.vm_images, networking.logical_networks, the SAN
    keys ...) is Skipped with the reason, and operations.post_cluster.skip_steps leaves a step out on purpose.

    Together and alone. Each task script keeps running by itself with its own parameters; this script only calls those public parameters (-InfrastructureFile,
    -WhatIf, -LogPath, -ComputerName, -Credential) and passes no state from one step to the next. -Only runs one task, -From and -To a range, so a
    failed run is repeated from the step that failed: -From <step>.

    -Mode Plan (default) passes -WhatIf to every step: each reads Azure and the cluster and changes nothing. -Mode Apply makes the changes. The run stops at the
    first failed step (the steps after it are NotRun), and after the first step with warnings unless -ContinueOnWarning is given. SDN enabled by Azure Arc cannot
    be undone, so the run is refused (exit code 2, in Plan mode too) unless the file carries sdn.acknowledge_maintenance_window (and sdn.acknowledge_dns_record
    with static DNS). Nothing is asked: the run never prompts, and secrets are read only through the toolkit's secret resolver.

    Written to -LogPath: run.log, the log of each step, report.json (what each step found) and summary.md. One event per state change goes to
    post-deployment-events.jsonl in the events folder (deployment.events_directory) for azurelocal-sonar.

    Exit codes: 0 every selected step passed, was planned or was skipped; 1 a step failed; 2 bad input, a refusal, a missing script or a cluster that does not
    answer; 3 the run stopped after a step with warnings.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER LogPath
    The folder for the logs, report.json and summary.md. It is created. Keep it out of the repository.
.PARAMETER Mode
    Plan (default; -WhatIf for every step) or Apply.
.PARAMETER From
    The first step or task to run (a step id such as storage-paths, or a task such as task-05). Default: the first.
.PARAMETER To
    The last step or task to run. Default: the last.
.PARAMETER Only
    Run only these steps or tasks. task-05 is both storage steps.
.PARAMETER ContinueOnWarning
    Keep going after a step that ended with warnings.
.PARAMETER Route
    PowerShell (default) or AzureCli, the other tab of the pages, for the steps that have an Azure CLI script.
.PARAMETER ComputerName
    The machine the cluster commands go to, passed to the steps that take it. Default: each script chooses, as it does when it runs alone.
.PARAMETER Credential
    The account for the nodes, passed to the steps that take it. Default: the deployment user of the file.
.PARAMETER EventLogPath
    The event feed. Default: post-deployment-events.jsonl in the events folder.
.PARAMETER SkipClusterProbe
    Do not check that the cluster answers before the first step that connects to it.
.PARAMETER SkipValidation
    Read the file without checking it against the schema.
.EXAMPLE
    ./Invoke-AzureLocalPostDeployment.ps1 -InfrastructureFile ./infrastructure.yml -LogPath ./out -Mode Plan
.EXAMPLE
    ./Invoke-AzureLocalPostDeployment.ps1 -InfrastructureFile ./infrastructure.yml -LogPath ./out -Mode Apply -From storage-paths -To logical-networks
.EXAMPLE
    ./Invoke-AzureLocalPostDeployment.ps1 -InfrastructureFile ./infrastructure.yml -LogPath ./out -Mode Plan -Only task-08
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [Parameter(Mandatory)][string]$LogPath,
    [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
    [string]$From,
    [string]$To,
    [string[]]$Only,
    [switch]$ContinueOnWarning,
    [ValidateSet('PowerShell', 'AzureCli')][string]$Route = 'PowerShell',
    [string]$ComputerName,
    [pscredential]$Credential,
    [string]$EventLogPath,
    [switch]$SkipClusterProbe,
    [switch]$SkipValidation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common'))
Import-Module (Join-Path (Join-Path $common 'post-deployment') 'AzlPostDeploymentRun.psm1') -Force

$result = Invoke-AzlPostDeployment @PSBoundParameters -StepTablePath ([IO.Path]::Combine($PSScriptRoot, 'PostDeploymentSteps.psd1'))
exit $result.ExitCode
