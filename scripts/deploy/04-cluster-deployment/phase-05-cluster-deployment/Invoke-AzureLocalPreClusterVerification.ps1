#Requires -Version 7.0
<#
.SYNOPSIS
    The pre-cluster verification gate: checks, read only, everything Microsoft Learn (view azloc-2610) and the azurelocal.cloud documentation
    list as a prerequisite, so that the ARM Validate never fails for something the toolkit could have caught.

.DESCRIPTION
    A stage of its own between the OS configuration (Invoke-AzureLocalOsConfiguration.ps1) and the cluster ARM Validate
    (Invoke-AzureLocalArmDeployment.ps1). The logic is in scripts/common/arm-deployment/AzlPreClusterVerification.psm1; the catalog of
    checks, with the Learn page of each, is docs/pre-cluster-verification.md.

    Modes
      Plan     (default) Offline. Lists the checks that apply to the file and what each one reads. Writes plan.json and plan.md. Never a
               result the ARM run accepts.
      Verify   Runs every check read only: Azure (ARM REST, the signed-in Az context), Active Directory over LDAP (the LCM credential
               from Key Vault) and the nodes over WinRM (the local administrator from Key Vault). Writes report.json, summary.md and
               precluster-verification-events.jsonl. Default: nothing is changed anywhere.

    A check ends as Passed, Failed, Warning, Skipped, NotApplicable or Fixed. A Skipped check is NOT a pass: it blocks the verdict unless
    you accept its id with -AcceptSkipped. -Fix (opt in, Verify only) applies the safe fixes, which are Azure side only: it registers the
    mandatory resource providers that are not registered.

    The ARM run (Invoke-AzureLocalArmDeployment.ps1, Mode Validate or Deploy) refuses to go on without a result here with the verdict
    Pass, for this infrastructure file (same SHA-256), not older than deployment.pre_cluster_verification_max_age_hours (default 4) and
    covering all six categories.

    Needs an Az context (this script does not sign in): Connect-AzAccount on a jump server. Secrets are keyvault:// references read into
    memory and never written.

    Output (in -ReportDirectory; default arm-report\verification\live in the folder of the infrastructure file): report.json, summary.md,
    precluster-verification-events.jsonl (one JSON object per line: RunStarted, Check ..., RunCompleted).

    Exit codes: 0 Plan done, or Verify with the verdict Pass; 1 Verify with the verdict Fail; 2 bad input.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).
.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2): the Arc machine resource IDs and the solution build. Optional.
.PARAMETER OsConfigurationReport
    The OS configuration report (report.json, a node-level report, or its report directory): the OS names of the adapters (found by MAC),
    which the ARM intents use. Optional.
.PARAMETER Mode
    Plan (default) or Verify.
.PARAMETER ReportDirectory
    Where the result goes. Default: deployment.pre_cluster_verification_report_directory, else arm-report\verification\live next to the file.
.PARAMETER AcceptSkipped
    Ids of checks that may stay Skipped (for example IDN-002,IDN-003 when this host cannot reach a domain controller). Comma-separated or a
    list. The report records that the operator accepted them.
.PARAMETER Fix
    Opt in (Mode Verify): register the mandatory Azure Local resource providers that are not registered, and wait until they are
    Registered. Azure side only; nothing on a node or in Active Directory is ever changed. Needs Owner or Contributor on the subscription.
.PARAMETER Category
    Run only these categories: azure, identity, nodes, network, storage, readiness. A partial run never passes the ARM precondition.
.PARAMETER Settings
    Run settings (see Get-AzlArmRunSetting): preClusterVerificationMaxAgeHours, preClusterVerificationReportDirectory,
    acknowledgeKnownIssues, solutionVersion, sbeCatalogPath; and remoting = @{ transport; useSsl; authentication } for the node connections.
.PARAMETER ConfigPath
    The same settings as a JSON file.
.PARAMETER AcknowledgeKnownIssues
    Known issue ids (config/known-issues/arm-deployment.json) to proceed past, for example arc-device-id-name.
.PARAMETER PassThru
    Also return the result object (verdict, counts, paths, checks).
.EXAMPLE
    ./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile D:\Data\site\infrastructure.yml
    # Plan: what would be checked. Offline.
.EXAMPLE
    ./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile D:\Data\site\infrastructure.yml -OsConfigurationReport D:\Data\site\osconfig-report -Mode Verify
    # Verify: read only against Azure, Active Directory and the nodes.
.EXAMPLE
    ./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile D:\Data\site\infrastructure.yml -Mode Verify -Fix -AcceptSkipped RDY-006
    # Also register missing resource providers; accept that the Arc integration validator could not run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string]$OsConfigurationReport,
    [ValidateSet('Plan', 'Verify')][string]$Mode = 'Plan',
    [string]$ReportDirectory,
    [string[]]$AcceptSkipped,
    [switch]$Fix,
    [ValidateSet('azure', 'identity', 'nodes', 'network', 'storage', 'readiness')][string[]]$Category,
    [hashtable]$Settings,
    [string]$ConfigPath,
    [string[]]$AcknowledgeKnownIssues,
    [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'arm-deployment', 'AzlPreClusterVerification.psm1')) -Force

# Every parameter of this script is a parameter of the run, except these.
$arguments = @{}
foreach ($key in $PSBoundParameters.Keys) { if ($key -notin 'PassThru') { $arguments[$key] = $PSBoundParameters[$key] } }
$result = Invoke-AzlPreClusterVerification @arguments

if ($Mode -eq 'Plan') {
    Write-Information -InformationAction Continue -MessageData $result.Message
    $result.Plan | Format-Table Id, Category, Applies, Blocking, Fixable, Title -AutoSize | Out-String -Width 220 | Write-Information -InformationAction Continue
    Write-Information -InformationAction Continue -MessageData "Plan: $(Join-Path $result.ReportDirectory 'plan.md')"
}
else {
    Write-Information -InformationAction Continue -MessageData "Pre-cluster verification, mode Verify: verdict $($result.Verdict), exit code $($result.ExitCode)."
    foreach ($c in @($result.Checks | Where-Object { $_.Blocking })) {
        Write-Information -InformationAction Continue -MessageData "  BLOCKING $($c.Id) [$($c.Status)]$(if ($c.Node -ne '*') { ' on ' + $c.Node }): $($c.Message)"
        if ($c.Remedy) { Write-Information -InformationAction Continue -MessageData "    Fix: $($c.Remedy)" }
    }
    if ($result.ReportPath -and (Test-Path -LiteralPath $result.ReportPath)) { Write-Information -InformationAction Continue -MessageData "Report: $($result.ReportDirectory)" }
}
if ($result.Message -and $Mode -eq 'Verify') { Write-Information -InformationAction Continue -MessageData $result.Message }
if ($result.NextAction) { Write-Information -InformationAction Continue -MessageData "Next: $($result.NextAction)" }
if ($PassThru) { $result }
exit $result.ExitCode
