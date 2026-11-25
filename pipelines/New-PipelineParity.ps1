#Requires -Version 7.0
<#
.SYNOPSIS
    Writes pipelines/PARITY.md: the generated parity table of the toolkit's pipelines, one row per pipeline and one column per platform (D126).

.DESCRIPTION
    The pipelines are one CI/CD design on GitHub Actions, GitLab CI and Azure DevOps (owner directive D126): each pipeline is a thin wrapper that
    calls the same PowerShell entry scripts with the values of infrastructure.yml, refuses a change while its approval environment is not set, starts
    by hand (or on the same schedule), and holds no logic of one platform only. This script reads the pipeline files and writes, for every pipeline:

      - the file of each platform;
      - the entry scripts each file runs (every scripts/... or config/variables/scripts/... .ps1 path on a code line, comments left out);
      - the approval environments each file binds (AZL_ENVIRONMENT_*), and whether the file has the refusal job or stage of an unset environment;
      - how a run starts (by hand, or the schedule of devops.pipelines.schedules.check_for_updates);
      - the verdict: Equal when the three columns agree, else the difference.

    The pipeline list is $Catalog below; a pipeline file that no entry names is reported, so a new file cannot be left out of the table.
    tests/pipelines/PipelineParity.Tests.ps1 runs this script with -Check (the committed table must be current) and fails on any row that is not Equal.
    Nothing is run on a platform and nothing is sent anywhere.

    Exit codes: 0 written (or current with -Check); 1 the table on disk is out of date (-Check) or a pipeline file is missing.

.PARAMETER Check
    Do not write: exit 1 when pipelines/PARITY.md differs from what this script would write.

.PARAMETER RepositoryRoot
    The repository root. Default: the parent folder of this script's folder.

.EXAMPLE
    ./pipelines/New-PipelineParity.ps1

.EXAMPLE
    ./pipelines/New-PipelineParity.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$RepositoryRoot = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) { $RepositoryRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..')) }

# The pipelines, in the order a deployment runs them, and the file (or files) of each platform. GitLab runs the Terraform and Ansible chain from
# .gitlab-ci.yml with the stage files it includes, so that row lists them all.
$Catalog = [ordered]@{
    'cicd-infra'               = @{ GitHub = @('pipelines/github-actions/cicd-infra.yml'); GitLab = @('pipelines/gitlab/.gitlab-ci.yml', 'pipelines/gitlab/stages/deploy-cicd-infra.yml'); AzureDevOps = @('pipelines/azure-devops/cicd-infra.yml') }
    'discovery'                = @{ GitHub = @('pipelines/github-actions/discovery.yml'); GitLab = @('pipelines/gitlab/stages/discovery.yml'); AzureDevOps = @('pipelines/azure-devops/discovery.yml') }
    'os-configuration'         = @{ GitHub = @('pipelines/github-actions/os-configuration.yml'); GitLab = @('pipelines/gitlab/os-configuration.gitlab-ci.yml'); AzureDevOps = @('pipelines/azure-devops/os-configuration.yml') }
    'pre-cluster-verification' = @{ GitHub = @('pipelines/github-actions/pre-cluster-verification.yml'); GitLab = @('pipelines/gitlab/stages/pre-cluster-verification.yml'); AzureDevOps = @('pipelines/azure-devops/pre-cluster-verification.yml') }
    'arm-deployment'           = @{ GitHub = @('pipelines/github-actions/arm-deployment.yml'); GitLab = @('pipelines/gitlab/stages/arm-deployment.yml'); AzureDevOps = @('pipelines/azure-devops/arm-deployment.yml') }
    'post-deployment'          = @{ GitHub = @('pipelines/github-actions/post-deployment.yml'); GitLab = @('pipelines/gitlab/stages/post-deployment.yml'); AzureDevOps = @('pipelines/azure-devops/post-deployment.yml') }
    'azure-local-deploy'       = @{
        GitHub      = @('pipelines/github-actions/azure-local-deploy.yml')
        GitLab      = @('pipelines/gitlab/.gitlab-ci.yml', 'pipelines/gitlab/stages/validate.yml', 'pipelines/gitlab/stages/deploy-foundation.yml', 'pipelines/gitlab/stages/configure-onprem.yml', 'pipelines/gitlab/stages/configure-operations.yml')
        AzureDevOps = @('pipelines/azure-devops/azure-local-deploy.yml')
    }
    'validation'               = @{ GitHub = @('pipelines/github-actions/validation.yml'); GitLab = @('pipelines/gitlab/stages/validation.yml'); AzureDevOps = @('pipelines/azure-devops/validation.yml') }
    'day2-check-updates'       = @{ GitHub = @('pipelines/github-actions/day2-check-updates.yml'); GitLab = @('pipelines/gitlab/stages/day2-check-updates.yml'); AzureDevOps = @('pipelines/azure-devops/day2-check-updates.yml') }
    'day2-update'              = @{ GitHub = @('pipelines/github-actions/day2-update.yml'); GitLab = @('pipelines/gitlab/stages/day2-update.yml'); AzureDevOps = @('pipelines/azure-devops/day2-update.yml') }
    'day2-node-maintenance'    = @{ GitHub = @('pipelines/github-actions/day2-node-maintenance.yml'); GitLab = @('pipelines/gitlab/stages/day2-node-maintenance.yml'); AzureDevOps = @('pipelines/azure-devops/day2-node-maintenance.yml') }
    'day2-cluster-operations'  = @{ GitHub = @('pipelines/github-actions/day2-cluster-operations.yml'); GitLab = @('pipelines/gitlab/stages/day2-cluster-operations.yml'); AzureDevOps = @('pipelines/azure-devops/day2-cluster-operations.yml') }
}
# Files that are not a pipeline of their own: the Azure DevOps compile-time settings and the GitLab tool installer.
$Support = @('pipelines/azure-devops/variables/approval-environments.yml', 'pipelines/azure-devops/variables/pipeline-settings.yml')
$Platforms = [ordered]@{ GitHub = 'GitHub Actions'; GitLab = 'GitLab CI'; AzureDevOps = 'Azure DevOps' }

function Get-CodeText([string]$Relative) {
    $path = [IO.Path]::Combine($RepositoryRoot, $Relative)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The pipeline file '$Relative' is not there." }
    $lines = foreach ($line in ([IO.File]::ReadAllText($path) -split "\r?\n")) {
        if ($line.TrimStart().StartsWith('#')) { continue }
        $line -replace '\s+#\s.*$', ''
    }
    return ($lines -join "`n")
}

function Get-PipelineFact([string]$Platform, [string[]]$Files) {
    $code = (@($Files | ForEach-Object { Get-CodeText $_ }) -join "`n")
    $scripts = @([regex]::Matches($code, '(?<![\w/.-])(?:\./)?((?:config/variables/)?scripts/[\w./-]+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $environments = @([regex]::Matches($code, '\bAZL_ENVIRONMENT_[A-Z_]+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $refusal = switch ($Platform) {
        'GitHub' { $code -match '(?m)^  approval-environment-not-set:' }
        'GitLab' { $code -match '(?m)^[\w-]*approval-environment-not-set:' }
        default { $code -match 'stage: ApprovalEnvironmentNotSet' }
    }
    $schedule = switch ($Platform) {
        'GitHub' { $m = [regex]::Match($code, "(?m)^\s+- cron: '([^']+)'"); if ($m.Success) { "cron $($m.Groups[1].Value)" } else { '' } }
        'AzureDevOps' { $m = [regex]::Match($code, "(?m)^\s+- cron: '([^']+)'"); if ($m.Success) { "cron $($m.Groups[1].Value)" } else { '' } }
        default { if ($code -match '\$CI_PIPELINE_SOURCE =~ /\^\(schedule\|') { 'cron (project schedule, task 05)' } else { '' } }
    }
    # How a run starts: GitHub workflow_dispatch, Azure DevOps trigger none, GitLab the web form or the API. A push or a merge request starts nothing.
    $manual = switch ($Platform) {
        'GitHub' { ($code -match '(?m)^\s+workflow_dispatch:') -and ($code -notmatch '(?m)^\s+(push|pull_request):') }
        'AzureDevOps' { ($code -match '(?m)^trigger: none') -and ($code -match '(?m)^pr: none') }
        # GitLab: the workflow rule of the pipeline file creates a pipeline only from the web form, the API (or the project schedule).
        default { $code -match "(?m)^workflow:\n  rules:\n    - if: '\`$CI_PIPELINE_SOURCE =~ /\^\((schedule\|)?web\|api\)\`$/'" }
    }
    [pscustomobject]@{
        Files        = $Files
        Scripts      = $scripts
        Environments = $environments
        Refusal      = [bool]$refusal
        Schedule     = [string]$schedule
        Manual       = [bool]$manual
    }
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($name in $Catalog.Keys) {
    $facts = [ordered]@{}
    foreach ($p in $Platforms.Keys) { $facts[$p] = Get-PipelineFact $p $Catalog[$name][$p] }
    $differences = [System.Collections.Generic.List[string]]::new()
    $first = $facts['GitHub']
    foreach ($p in @('GitLab', 'AzureDevOps')) {
        $f = $facts[$p]
        if (($f.Scripts -join ',') -ne ($first.Scripts -join ',')) { $differences.Add("entry scripts of $($Platforms[$p]) differ from GitHub Actions") }
        if (($f.Environments -join ',') -ne ($first.Environments -join ',')) { $differences.Add("approval environments of $($Platforms[$p]) differ from GitHub Actions") }
        if ($f.Refusal -ne $first.Refusal) { $differences.Add("refusal of an unset environment differs on $($Platforms[$p])") }
        if ([bool]$f.Schedule -ne [bool]$first.Schedule) { $differences.Add("schedule differs on $($Platforms[$p])") }
        if ($f.Manual -ne $first.Manual) { $differences.Add("start (by hand) differs on $($Platforms[$p])") }
    }
    foreach ($p in $Platforms.Keys) { if ($facts[$p].Environments.Count -gt 0 -and -not $facts[$p].Refusal) { $differences.Add("$($Platforms[$p]) binds an environment without the refusal of an unset one") } }
    $schedules = @($facts.Values | Where-Object { $_.Schedule -like 'cron *' -and $_.Schedule -notlike 'cron (*' } | ForEach-Object Schedule | Sort-Object -Unique)
    if ($schedules.Count -gt 1) { $differences.Add('the cron lines differ') }
    $rows.Add([pscustomobject]@{ Name = $name; Facts = $facts; Differences = @($differences | Sort-Object -Unique) })
}

# Every pipeline file is in the catalog or is a support file.
$listed = [System.Collections.Generic.HashSet[string]]::new([string[]](@($Catalog.Values | ForEach-Object { $_.Values } | ForEach-Object { $_ }) + $Support))
$unlisted = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($RepositoryRoot, 'pipelines')) -Recurse -File -Force -Filter '*.yml' |
        ForEach-Object { 'pipelines/' + $_.FullName.Substring(([IO.Path]::Combine($RepositoryRoot, 'pipelines')).Length + 1).Replace('\', '/') } |
        Where-Object { -not $listed.Contains($_) } | Sort-Object)

function Format-List([string[]]$Items) { if (-not $Items -or $Items.Count -eq 0) { return 'none' } return (($Items | ForEach-Object { "``$_``" }) -join '<br>') }

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('# Pipeline parity (generated)')
$null = $sb.AppendLine()
$null = $sb.AppendLine('GENERATED by `pipelines/New-PipelineParity.ps1` from the pipeline files; do not edit by hand. `tests/pipelines/PipelineParity.Tests.ps1`')
$null = $sb.AppendLine('fails when this file is out of date or when a row is not Equal (owner directive D126: one CI/CD design on GitHub Actions, GitLab CI and Azure DevOps).')
$null = $sb.AppendLine()
$null = $sb.AppendLine('Each pipeline calls the same entry scripts on every platform, binds the same approval environments (and refuses to change anything while one is')
$null = $sb.AppendLine('not set), starts by hand, and runs on the same schedule. The values come from `infrastructure.yml`: on GitHub and GitLab as the variables task 05')
$null = $sb.AppendLine('sets, on Azure DevOps as the compile-time variables of `azure-devops/variables/pipeline-settings.yml` and `approval-environments.yml`, which task 05 writes.')
$null = $sb.AppendLine()
$null = $sb.AppendLine('## Files')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| Pipeline | GitHub Actions | GitLab CI | Azure DevOps |')
$null = $sb.AppendLine('| --- | --- | --- | --- |')
foreach ($r in $rows) {
    $cells = foreach ($p in $Platforms.Keys) { Format-List ($r.Facts[$p].Files | ForEach-Object { $_ -replace '^pipelines/', '' }) }
    $null = $sb.AppendLine("| $($r.Name) | $($cells -join ' | ') |")
}
$null = $sb.AppendLine()
$null = $sb.AppendLine('## What each pipeline does on each platform')
$null = $sb.AppendLine()
$null = $sb.AppendLine('| Pipeline | Entry scripts (all platforms) | Approval environments | Refuses while unset | Starts | Schedule | GitHub / GitLab / Azure DevOps |')
$null = $sb.AppendLine('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($r in $rows) {
    $g = $r.Facts['GitHub']
    $refuse = (@($Platforms.Keys | ForEach-Object { if ($r.Facts[$_].Environments.Count -eq 0) { 'n/a' } elseif ($r.Facts[$_].Refusal) { 'yes' } else { 'NO' } }) | Sort-Object -Unique) -join ' / '
    $starts = (@($Platforms.Keys | ForEach-Object { if ($r.Facts[$_].Manual) { 'by hand' } else { 'NOT by hand' } }) | Sort-Object -Unique) -join ' / '
    $schedule = (@($Platforms.Keys | ForEach-Object { if ($r.Facts[$_].Schedule) { $r.Facts[$_].Schedule } else { 'none' } })) -join ' / '
    $verdict = if ($r.Differences.Count -eq 0) { 'Equal' } else { 'DIFFERENT: ' + ($r.Differences -join '; ') }
    $null = $sb.AppendLine("| $($r.Name) | $(Format-List $g.Scripts) | $(Format-List $g.Environments) | $refuse | $starts | $schedule | $verdict |")
}
$null = $sb.AppendLine()
$null = $sb.AppendLine('## Pipeline files that are not in the table')
$null = $sb.AppendLine()
if ($unlisted.Count -eq 0) { $null = $sb.AppendLine('None. The support files are `azure-devops/variables/pipeline-settings.yml` and `azure-devops/variables/approval-environments.yml`.') }
else { foreach ($u in $unlisted) { $null = $sb.AppendLine("- ``$u`` (NOT LISTED: add it to the catalog of New-PipelineParity.ps1)") } }
$text = $sb.ToString().Replace("`r`n", "`n")

$out = [IO.Path]::Combine($RepositoryRoot, 'pipelines', 'PARITY.md')
if ($Check) {
    $current = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out).Replace("`r`n", "`n") } else { '' }
    if ($current -ne $text) { Write-Error 'pipelines/PARITY.md is out of date. Run ./pipelines/New-PipelineParity.ps1' -ErrorAction Continue; exit 1 }
    exit 0
}
[IO.File]::WriteAllText($out, $text, [Text.UTF8Encoding]::new($false))
$rows | ForEach-Object { [pscustomobject]@{ Pipeline = $_.Name; Verdict = $(if ($_.Differences.Count) { $_.Differences -join '; ' } else { 'Equal' }) } }
exit 0
