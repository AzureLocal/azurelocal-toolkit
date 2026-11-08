#Requires -Version 7.0
<#
.SYNOPSIS
    ARM Validate and Deploy of an Azure Local instance from infrastructure.yml: preconditions, Validate, approval, Deploy, report.

.DESCRIPTION
    The one entry point of the cluster deployment phase for jump servers and CI/CD pipelines (GitHub Actions, GitLab CI, Azure
    DevOps). The same command runs on both. The logic is in scripts/common/arm-deployment/AzlArmDeploymentRun.psm1; the design is
    docs/design/arm-validate-deploy.md.

    Modes
      Plan               Generates the ARM parameters, checks them against the template, runs every read-only precondition.
                         Changes nothing. Works without an Azure sign-in (the checks that read Azure are then skipped).
      Validate           Plan, then submits the Validate deployment and waits for Microsoft's validation. A Validate that already
                         passed with the same parameters is not submitted again; a running one is attached to.
      Deploy             Plan, then submits the Deploy (2.5 to 3 hours) after checking that these parameters validated. A running
                         deployment is attached to. A failed one is resubmitted only with -Resume.
      ValidateAndDeploy  Validate, then the approval gate (-ApprovalMode), then Deploy. Pipelines run Validate and Deploy as
                         two jobs with the platform's approval between them instead.

    Needs an Az context (this script does not sign in): Connect-AzAccount on a jump server, or the pipeline's OIDC or managed
    identity login step. Secrets are keyvault:// references read into memory and never written.

    Output (in -ReportDirectory): arm-deployment-events.jsonl (the event feed Sonar can follow), report.json, summary.md,
    <cluster>.parameters.json (secrets are null in it) and parameter-sources.md (which infrastructure.yml key fed which ARM
    parameter).

    Exit codes: 0 the requested part succeeded (Plan clean; Validate passed; Deploy succeeded; ValidateAndDeploy stopped at the
    approval gate); 1 a precondition failed, or the validation or deployment failed or timed out; 2 bad input.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2): the Arc machine resource IDs and the solution build. Optional.
.PARAMETER OsConfigurationReport
    The OS configuration report: its report.json, a node-level report, or its report directory. Used for the adapter names, the
    SAN disks and the precondition that every node converged. Optional unless deployment.require_os_configuration_report is true.
.PARAMETER Mode
    Plan (default), Validate, Deploy or ValidateAndDeploy.
.PARAMETER ReportDirectory
    Where the events, report and parameter files go. Default: a folder in the temp directory. Keep it out of the repository.
.PARAMETER Settings
    Run settings, winning over the master file's deployment block: validateTimeoutMinutes, deployTimeoutMinutes, pollSeconds,
    pollMaxSeconds, approvalMode, resume, skipPreconditions, acknowledgeKnownIssues, requireOsConfigurationReport, revalidate,
    deploymentSettingsApiVersion and the others in Get-AzlArmRunSetting.
.PARAMETER ConfigPath
    The same settings as a JSON file.
.PARAMETER TemplateFile
    A local copy of the quickstart template, instead of downloading it from GitHub.
.PARAMETER Resume
    Resubmit a failed Deploy (and attach to a running one). Without it a failed Deploy is refused.
.PARAMETER AllowRevalidate
    Allow Validate on an instance in a failed deployment state. Microsoft says not to; for support-guided recovery only.
.PARAMETER AutoApprove
    ValidateAndDeploy: continue to Deploy without asking (same as -ApprovalMode none).
.PARAMETER ApprovalMode
    stop (default: ends after a good Validate), prompt (asks on the console) or none.
.PARAMETER ProbeOsConfiguration
    Without -OsConfigurationReport, run the OS configuration in Plan mode (read only) to learn whether the nodes converged.
.PARAMETER Offline
    Mode Plan only: do not touch Azure at all, even when someone is signed in. Reads the files, generates and checks the
    parameters, and skips every check that needs Azure.
.PARAMETER AcknowledgeKnownIssues
    Known issue ids (config/known-issues/arm-deployment.json) to proceed past, for example arc-device-id-name, which otherwise blocks
    a Deploy on an affected build and a resume of a failure it explains. Comma-separated or a list. Leave empty normally.
.PARAMETER WhatIf
    Do everything except submit; say what would be submitted.
.PARAMETER PassThru
    Also return the result object (exit code, state, report paths, preconditions).
.EXAMPLE
    ./Invoke-AzureLocalArmDeployment.ps1 -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Plan
.EXAMPLE
    ./Invoke-AzureLocalArmDeployment.ps1 -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Validate -ReportDirectory ./arm-validate
.EXAMPLE
    ./Invoke-AzureLocalArmDeployment.ps1 -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Deploy -Resume -ReportDirectory ./arm-deploy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string]$OsConfigurationReport,
    [ValidateSet('Plan', 'Validate', 'Deploy', 'ValidateAndDeploy')][string]$Mode = 'Plan',
    [string]$ReportDirectory,
    [hashtable]$Settings,
    [string]$ConfigPath,
    [string]$TemplateFile,
    [switch]$Resume,
    [switch]$AllowRevalidate,
    [switch]$AutoApprove,
    [ValidateSet('', 'stop', 'prompt', 'none')][string]$ApprovalMode = '',
    [switch]$ProbeOsConfiguration,
    [switch]$Offline,
    [string[]]$AcknowledgeKnownIssues,
    [switch]$WhatIf,
    [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force

# Every parameter of this script is a parameter of the run, except these.
$arguments = @{}
foreach ($key in $PSBoundParameters.Keys) { if ($key -notin 'Settings', 'ApprovalMode', 'PassThru', 'AcknowledgeKnownIssues') { $arguments[$key] = $PSBoundParameters[$key] } }
$merged = @{}
if ($Settings) { foreach ($k in $Settings.Keys) { $merged[$k] = $Settings[$k] } }
if ($ApprovalMode) { $merged['approvalMode'] = $ApprovalMode }
if ($AcknowledgeKnownIssues) { $merged['acknowledgeKnownIssues'] = @($AcknowledgeKnownIssues | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($merged.Count) { $arguments.Settings = $merged }
$result = Invoke-AzlArmDeploymentRun @arguments

Write-Information -InformationAction Continue -MessageData "ARM deployment, mode $($result.Mode): state $($result.State), exit code $($result.ExitCode)."
if ($result.Message) { Write-Information -InformationAction Continue -MessageData $result.Message }
if ($result.NextAction) { Write-Information -InformationAction Continue -MessageData "Next: $($result.NextAction)" }
if ($result.SummaryPath -and (Test-Path -LiteralPath $result.SummaryPath)) { Write-Information -InformationAction Continue -MessageData "Report: $($result.ReportDirectory)" }
if ($PassThru) { $result }
exit $result.ExitCode
