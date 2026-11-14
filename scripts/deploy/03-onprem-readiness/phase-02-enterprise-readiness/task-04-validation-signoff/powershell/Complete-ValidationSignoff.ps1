<#
.SYNOPSIS
    Writes the validation sign-off document of the on-premises readiness phase, from infrastructure.yml and the pre-cluster verification report.

.DESCRIPTION
    Phase 02 (enterprise readiness), Task 04. The script writes one Markdown page that the engineers and the customer sign before the deployment:
      - the customer, the project (when -ProjectName is given), the cluster name, the Azure region, the subscription and the number of machines,
        all from the infrastructure file;
      - the result of the pre-cluster verification (Invoke-AzureLocalPreClusterVerification.ps1 -Mode Verify), when -VerificationReport names its
        report.json (or the folder that holds it): the verdict, the counts of the results, when the report expires, and whether the report was
        made for this very infrastructure file (the SHA-256 of the file against the fileHash of the report);
      - a checklist of what is confirmed by a person, and the signature tables.

    The page says what the report says. Nothing in the script judges the readiness: a verdict other than Pass is written as it is, with the line that the
    deployment must not start. The script reads files and writes one file. It changes nothing else, signs in to nothing and asks nothing.
    Under -WhatIf it writes no file and prints the path it would write.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        site.customer (required), cluster.name, azure.location, azure.subscription_id, nodes[].name

    Exit codes: 0 the document is written (or planned under -WhatIf); 1 the report cannot be read or the document cannot be written; 2 site.customer
    is missing or the file cannot be read.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER VerificationReport
    Optional. The report.json of a pre-cluster verification run, or the folder that holds it. Without it the page says that no report was given.

.PARAMETER OutputPath
    The folder for the sign-off page. It is created when it does not exist. Default: .\output\signoff

.PARAMETER ProjectName
    Optional. The project name to print on the page. Without it the page prints no project line.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Complete-ValidationSignoff.ps1 -InfrastructureFile ./infrastructure.yml -VerificationReport ./arm-report/verification/live -OutputPath ./signoff

    Writes ./signoff/validation-signoff-<date>.md.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$VerificationReport,
    [string]$OutputPath = '.\output\signoff',
    [string]$ProjectName,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

# The name of the report file the pre-cluster verification writes. Fixed by Invoke-AzureLocalPreClusterVerification.ps1.
$ReportFileName = 'report.json'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Cell([string]$Text) { if ($Text) { $Text.Replace('|', '/') } else { 'not given' } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
$customer = Get-Text 'site.customer'
if (-not $customer) { Exit-InputProblem 'site.customer is missing in the infrastructure file. It is the customer name the page is written for.' }
$clusterName = Get-Text 'cluster.name'
$location = Get-Text 'azure.location'
$subscriptionId = Get-Text 'azure.subscription_id'
$nodeCount = @(Get-AzlInfrastructureNode -Infrastructure $infra).Count

# ---- the report of the pre-cluster verification (read only)
$verification = [ordered]@{ Given = $false; Verdict = ''; Counts = ''; Expires = ''; SameFile = $null; Path = '' }
if ($VerificationReport) {
    $reportPath = $VerificationReport
    if (Test-Path -LiteralPath $reportPath -PathType Container) { $reportPath = Join-Path $reportPath $ReportFileName }
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { Exit-Failed "The verification report was not found: $reportPath" }
    try { $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json }
    catch { Exit-Failed "The verification report cannot be read as JSON: $reportPath" }
    $verification.Given = $true
    $verification.Path = $reportPath
    $verification.Verdict = if ($report.PSObject.Properties['verdict']) { [string]$report.verdict } else { '' }
    if ($report.PSObject.Properties['counts'] -and $report.counts) {
        $verification.Counts = (($report.counts.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { "$($_.Name) $($_.Value)" }) -join ', ')
    }
    if ($report.PSObject.Properties['expiresUtc'] -and $report.expiresUtc) {
        # ConvertFrom-Json turns an ISO date into a [datetime]; write it back in one fixed form.
        $verification.Expires = if ($report.expiresUtc -is [datetime]) { $report.expiresUtc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) + ' UTC' } else { [string]$report.expiresUtc }
    }
    if ($report.PSObject.Properties['fileHash'] -and $report.fileHash) {
        $hash = (Get-FileHash -LiteralPath $InfrastructureFile -Algorithm SHA256).Hash
        $verification.SameFile = ($hash -ieq [string]$report.fileHash)
    }
}
$passed = $verification.Given -and $verification.Verdict -eq 'Pass' -and $verification.SameFile -eq $true

# ---- the page
$date = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$fileDate = Get-Date -Format 'yyyyMMdd'
$signoffFile = Join-Path $OutputPath "validation-signoff-$fileDate.md"
$projectLine = if ($ProjectName) { "**Project:** $ProjectName  `n" } else { '' }
if ($verification.Given) {
    $sameFileText = switch ($verification.SameFile) { $true { 'yes' } $false { 'NO: the infrastructure file changed after the report was made' } default { 'the report holds no file hash' } }
    $verificationRow = "| Pre-cluster verification | $(Get-Cell $verification.Verdict) | Counts: $(Get-Cell $verification.Counts). Report for this file: $sameFileText. Expires: $(Get-Cell $verification.Expires). Report: $(Get-Cell $verification.Path) |"
}
else {
    $verificationRow = '| Pre-cluster verification | No report given | Run Invoke-AzureLocalPreClusterVerification.ps1 -Mode Verify and give its report with -VerificationReport |'
}
$readiness = if ($passed) { 'The verification verdict is Pass for this infrastructure file.' } else { 'The verification verdict is not a Pass for this infrastructure file. The deployment must not start until it is.' }

$document = @"
# Azure Local Deployment - Validation Sign-off

**Customer:** $customer
$projectLine**Date:** $date

---

## Summary

$readiness

## Validation status

| Check | Status | Notes |
|-------|--------|-------|
$verificationRow

## Pre-deployment checklist (confirmed by a person)

### Azure resources
- [ ] Subscription access verified
- [ ] Resource providers registered
- [ ] RBAC permissions assigned
- [ ] Virtual network deployed
- [ ] Key Vault configured
- [ ] Log Analytics workspace created

### On-premises infrastructure
- [ ] Active Directory configured
- [ ] OUs and groups created
- [ ] DNS records configured
- [ ] Service accounts created
- [ ] Network connectivity verified
- [ ] Firewall rules configured

### Hardware
- [ ] All nodes physically inspected
- [ ] Firmware versions validated
- [ ] BIOS settings configured
- [ ] BMC access confirmed
- [ ] Network cabling verified
- [ ] Power connections verified

### Network devices
- [ ] Console server configured
- [ ] Switch port configuration complete
- [ ] VLAN configuration verified

---

## Configuration summary

**Cluster name:** $(Get-Cell $clusterName)
**Machines in the file:** $nodeCount
**Azure region:** $(Get-Cell $location)
**Subscription:** $(Get-Cell $subscriptionId)

---

## Sign-off

### Engineering

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Lead engineer | _________________ | _________________ | __________ |
| Network engineer | _________________ | _________________ | __________ |
| Project manager | _________________ | _________________ | __________ |

### Customer

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Technical contact | _________________ | _________________ | __________ |
| Project sponsor | _________________ | _________________ | __________ |

---

## Approval

By signing above, all parties acknowledge that:

1. The pre-deployment validation checks are complete and their result is the one written on this page
2. The infrastructure meets the requirements for the Azure Local deployment
3. Any exception or deviation is documented and accepted
4. The project may go on to the deployment phase

---

*Generated: $date*
"@

if ($PSCmdlet.ShouldProcess($signoffFile, 'Write the validation sign-off document')) {
    try {
        if (-not (Test-Path -LiteralPath $OutputPath)) { $null = New-Item -Path $OutputPath -ItemType Directory -Force }
        Set-Content -LiteralPath $signoffFile -Value $document -Encoding utf8
    }
    catch { Exit-Failed "The sign-off document cannot be written: $($_.Exception.Message)" }
    Write-Line "[done]    The sign-off document is written: $signoffFile"
    $action = 'Written'
}
else {
    Write-Line "[plan]    The sign-off document would be written: $signoffFile"
    $action = 'WouldWrite'
}

[pscustomobject]@{ Action = $action; SignoffPath = $signoffFile; Verdict = $verification.Verdict; ReadyForDeployment = $passed }
exit 0
