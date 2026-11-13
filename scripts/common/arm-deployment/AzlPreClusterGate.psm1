#Requires -Version 7.0
<#
.SYNOPSIS
    The contract between the pre-cluster verification gate and the ARM Validate and Deploy: where the gate's result lives and when it counts.

.DESCRIPTION
    The gate (AzlPreClusterVerification.psm1, Invoke-AzureLocalPreClusterVerification.ps1) writes three files into its report directory:
    report.json, summary.md and precluster-verification-events.jsonl. The ARM run (AzlArmDeploymentRun.psm1) must not Validate or
    Deploy unless the latest result there says Pass, was made for the same infrastructure file (same SHA-256), has not expired and was
    not a partial run. This module holds only that contract, so the ARM run can read the result without loading the whole gate (the
    gate loads the ARM run for its Azure adapter, so the two cannot import each other).

    Get-AzlPclFileHash             SHA-256 (lower case hex) of the infrastructure file.
    Resolve-AzlPclReportDirectory  The report directory: the setting, else arm-report\verification\live in the folder of the infrastructure
                                   file (the environment data folder).
    Get-AzlPclCommand              The exact command that produces a result (named in every failure of the ARM precondition).
    Read-AzlPclGateResult          report.json as an object, or $null.
    Test-AzlPclGateResult          Does the latest result allow an ARM Validate or Deploy, and if not, why and what to run.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SchemaVersion = 1
$script:Categories = @('azure', 'identity', 'nodes', 'network', 'storage', 'readiness')
$script:ReportFile = 'report.json'
$script:SummaryFile = 'summary.md'
$script:EventFile = 'precluster-verification-events.jsonl'
$script:GateScript = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'deploy', '04-cluster-deployment', 'phase-05-cluster-deployment', 'Invoke-AzureLocalPreClusterVerification.ps1'))

function Get-AzlPclContract {
    <#
    .SYNOPSIS
        The constants of the contract: SchemaVersion, Categories, and the three file names.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{ SchemaVersion = $script:SchemaVersion; Categories = @($script:Categories); ReportFile = $script:ReportFile; SummaryFile = $script:SummaryFile; EventFile = $script:EventFile; GateScript = $script:GateScript }
}

function Get-AzlPclFileHash {
    <#
    .SYNOPSIS
        SHA-256 of a file as lower case hex. Throws when the file is not there.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $stream = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try { return ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose() }
}

function Resolve-AzlPclReportDirectory {
    <#
    .SYNOPSIS
        The report directory of the gate: -Configured when given (deployment.pre_cluster_verification_report_directory), else
        arm-report\verification\live in the environment data folder, else a folder in the temp directory.
        The environment data folder is the folder that holds the evidence folder of the file (provisioning.simplified.evidence_path, for
        example D:\Data\azl-ztp\iic\evidence gives D:\Data\azl-ztp\iic), else the one that holds media_path, else the folder of
        the infrastructure file. With -Infrastructure (the parsed file) the first two are used.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$InfrastructureFile, [string]$Configured, [System.Collections.IDictionary]$Infrastructure)
    if ($Configured) { return $Configured }
    if ($Infrastructure) {
        foreach ($key in 'evidence_path', 'media_path') {
            $node = $Infrastructure
            foreach ($part in 'provisioning', 'simplified', $key) { if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] } else { $node = $null; break } }
            $path = [Environment]::ExpandEnvironmentVariables([string]$node).Trim()
            if ($path) {
                $parent = Split-Path -Parent ($path.TrimEnd('\', '/'))
                if ($parent) { return [IO.Path]::Combine($parent, 'arm-report', 'verification', 'live') }
            }
        }
    }
    if ($InfrastructureFile) {
        $folder = Split-Path -Parent ([IO.Path]::GetFullPath($InfrastructureFile))
        return [IO.Path]::Combine($folder, 'arm-report', 'verification', 'live')
    }
    return [IO.Path]::Combine([IO.Path]::GetTempPath(), 'azl-precluster-verification')
}

function Get-AzlPclCommand {
    <#
    .SYNOPSIS
        The exact command that makes a result for this file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$InfrastructureFile, [string]$ReportDirectory, [string]$HandoffFile, [string]$OsConfigurationReport)
    $file = if ($InfrastructureFile) { [IO.Path]::GetFullPath($InfrastructureFile) } else { '<infrastructure.yml>' }
    $text = "& '$script:GateScript' -InfrastructureFile '$file' -Mode Verify"
    if ($HandoffFile) { $text += " -HandoffFile '$HandoffFile'" }
    if ($OsConfigurationReport) { $text += " -OsConfigurationReport '$OsConfigurationReport'" }
    if ($ReportDirectory) { $text += " -ReportDirectory '$ReportDirectory'" }
    return $text
}

function Read-AzlPclGateResult {
    <#
    .SYNOPSIS
        report.json of the gate in -Directory as an object, or $null when there is none or it is not readable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)
    $path = Join-Path $Directory $script:ReportFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 30) } catch { return $null }
}

function ConvertTo-AzlPclUtc {
    <#
    .SYNOPSIS
        A date of the report as a UTC DateTime, whatever ConvertFrom-Json made of it. PowerShell 7.0 to 7.4 turn an ISO string with Z into a local
        DateTime, 7.5 and later into a UTC one; a string is read as UTC when it has no offset. $null when it is not a date.
    #>
    [CmdletBinding()]
    param($Value)
    if ($Value -is [datetime]) { return $(if ($Value.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }) }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.UtcDateTime }
    return $null
}

function Test-AzlPclGateResult {
    <#
    .SYNOPSIS
        Whether the latest gate result allows an ARM Validate or Deploy of -InfrastructureFile.
    .DESCRIPTION
        It does only when report.json exists and is readable, is a Verify result of all six categories (not partial), has the verdict
        Pass, has the SHA-256 of the file as it is now, has not expired, and its own checks agree with the verdict: some checks, all six
        categories, no Failed check, nothing blocking, no Skipped check that was not accepted. summary.md must be there too. The ARM run
        enforces its own maximum age (-MaxAgeHours) on top of the expiry the report carries, and a report dated in the future or with an expiry
        more than 168 hours after it was made is refused. Every other case is Passed false with the reason and the exact command to run.
    .PARAMETER ExpectedFileHash
        The SHA-256 of the bytes the caller parsed (computed before it read the file). The report and the file now must both have it.
    .PARAMETER MaxAgeHours
        The caller's own maximum age of a result (deployment.pre_cluster_verification_max_age_hours); 0 uses only the report's expiry.
    .OUTPUTS
        Passed, Reason, Command, Directory, Verdict, FileHash, ExpiresUtc, RunId, AcceptedSkipped, Report.
    #>
    [CmdletBinding()]
    param(
        [string]$InfrastructureFile,
        [Parameter(Mandatory)][string]$Directory,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$HandoffFile,
        [string]$OsConfigurationReport,
        [string]$ExpectedFileHash,
        [int]$MaxAgeHours = 0
    )
    $command = Get-AzlPclCommand -InfrastructureFile $InfrastructureFile -ReportDirectory $Directory -HandoffFile $HandoffFile -OsConfigurationReport $OsConfigurationReport
    $get = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties[$Name].Value } else { $null } }
    $make = {
        param([bool]$Passed, [string]$Reason, $Report)
        $accepted = if ($Report) { @(@(& $get $Report 'acceptedSkipped') | Where-Object { $_ } | ForEach-Object { [string]$_ }) } else { @() }
        [pscustomobject]@{
            Passed = $Passed; Reason = $Reason; Command = $command; Directory = $Directory
            Verdict = $(if ($Report) { [string](& $get $Report 'verdict') } else { '' }); FileHash = $(if ($Report) { [string](& $get $Report 'fileHash') } else { '' })
            ExpiresUtc = $(if ($Report) { [string](& $get $Report 'expiresUtc') } else { '' }); RunId = $(if ($Report) { [string](& $get $Report 'runId') } else { '' })
            AcceptedSkipped = $accepted; Report = $Report
        }
    }
    if (-not $InfrastructureFile -or -not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) {
        return (& $make $false 'The ARM run was not given an infrastructure file (-InfrastructureFile), so the hash of the file the gate verified cannot be compared.' $null)
    }
    $report = Read-AzlPclGateResult -Directory $Directory
    if (-not $report) { return (& $make $false "There is no result of the pre-cluster verification in $Directory (no readable $script:ReportFile)." $null) }
    $props = $report.PSObject.Properties.Name
    foreach ($needed in 'schema', 'mode', 'verdict', 'fileHash', 'expiresUtc', 'partial', 'completedUtc', 'runId', 'checks', 'categories') {
        if ($needed -notin $props) { return (& $make $false "The result in $Directory has no '$needed' field; it is not a result of this gate." $report) }
    }
    $schema = 0
    if (-not [int]::TryParse([string]$report.schema, [ref]$schema) -or $schema -ne $script:SchemaVersion) { return (& $make $false "The result in $Directory has schema $($report.schema); this toolkit reads schema $script:SchemaVersion." $report) }
    if ([string]$report.mode -ne 'Verify') { return (& $make $false "The latest result in $Directory is from mode '$($report.mode)'; only a Verify run counts." $report) }
    if ($null -eq $report.partial -or $report.partial -isnot [bool]) { return (& $make $false "The result in $Directory has no true or false 'partial' field." $report) }
    if ($report.partial) { return (& $make $false "The latest result in $Directory covers only some categories (-Category was used). A partial run never counts." $report) }
    $checks = @($report.checks | Where-Object { $null -ne $_ })
    # A check of a hand-made or damaged report may lack any field: read them all safely.
    $blocking = @($checks | Where-Object { (& $get $_ 'blocking') -eq $true -or [string](& $get $_ 'status') -eq 'Failed' })
    $ids = { param($List) ((@($List | ForEach-Object { $n = [string](& $get $_ 'node'); "$(& $get $_ 'checkId')$(if ($n -and $n -ne '*') { '@' + $n })" } | Select-Object -Unique | Select-Object -First 12)) -join ', ') + $(if (@($List).Count -gt 12) { ', ...' } else { '' }) }
    if ([string]$report.verdict -ne 'Pass') { return (& $make $false "The latest pre-cluster verification (run $($report.runId)) has the verdict $($report.verdict), not Pass; $($blocking.Count) check(s) block: $(& $ids $blocking)." $report) }
    # The verdict is not taken on trust: the checks inside the report must agree with it.
    if (-not $checks.Count) { return (& $make $false "The result in $Directory says Pass but lists no check." $report) }
    if ($blocking.Count) { return (& $make $false "The result in $Directory says Pass but lists Failed or blocking check(s): $(& $ids $blocking)." $report) }
    $loose = @($checks | Where-Object { [string](& $get $_ 'status') -eq 'Skipped' -and (& $get $_ 'accepted') -ne $true })
    if ($loose.Count) { return (& $make $false "The result in $Directory says Pass but lists Skipped check(s) that were not accepted with -AcceptSkipped: $(& $ids $loose)." $report) }
    $unknown = @($checks | Where-Object { [string](& $get $_ 'status') -notin 'Passed', 'Warning', 'NotApplicable', 'Fixed', 'Skipped' })
    if ($unknown.Count) { return (& $make $false "The result in $Directory lists check(s) with an unknown status: $(& $ids $unknown)." $report) }
    $present = if ($report.categories) { @($report.categories.PSObject.Properties.Name) } else { @() }
    $missing = @($script:Categories | Where-Object { $_ -notin $present })
    if ($missing.Count) { return (& $make $false "The result in $Directory has no result for the categories $($missing -join ', '); a full run covers all six." $report) }
    if (-not (Test-Path -LiteralPath (Join-Path $Directory $script:SummaryFile) -PathType Leaf)) { return (& $make $false "The result in $Directory has no $script:SummaryFile next to it; a run that did not write all its outputs does not count." $report) }
    $hash = Get-AzlPclFileHash -Path $InfrastructureFile
    $short = { param($h) ([string]$h).Substring(0, [Math]::Min(12, ([string]$h).Length)) }
    if ([string]$report.fileHash -ne $hash) {
        return (& $make $false "The infrastructure file changed since the verification (run $($report.runId) saw SHA-256 $(& $short $report.fileHash)..., the file now has $(& $short $hash)...)." $report)
    }
    if ($ExpectedFileHash -and $ExpectedFileHash -ne $hash) {
        return (& $make $false "The infrastructure file changed while it was being read (it had SHA-256 $(& $short $ExpectedFileHash)... when it was parsed, it has $(& $short $hash)... now)." $report)
    }
    $nowUtc = ConvertTo-AzlPclUtc $Now
    $expires = ConvertTo-AzlPclUtc $report.expiresUtc
    $completed = ConvertTo-AzlPclUtc $report.completedUtc
    if ($null -eq $expires) { return (& $make $false "The result in $Directory has an expiresUtc that is not a date ($($report.expiresUtc))." $report) }
    if ($null -eq $completed) { return (& $make $false "The result in $Directory has a completedUtc that is not a date ($($report.completedUtc))." $report) }
    if ($completed -gt $nowUtc.AddMinutes(5)) { return (& $make $false "The result in $Directory was completed at $($completed.ToString('o')), which is in the future." $report) }
    if (($expires - $completed) -gt [TimeSpan]::FromHours(168).Add([TimeSpan]::FromMinutes(1))) { return (& $make $false "The result in $Directory expires more than 168 hours after it was made." $report) }
    $effective = $expires
    if ($MaxAgeHours -gt 0 -and $completed.AddHours($MaxAgeHours) -lt $effective) { $effective = $completed.AddHours($MaxAgeHours) }
    if ($nowUtc -ge $effective) {
        $why = if ($effective -lt $expires) { "the ARM run allows a result to be $MaxAgeHours hour(s) old (deployment.pre_cluster_verification_max_age_hours)" } else { 'results count for a limited time (deployment.pre_cluster_verification_max_age_hours)' }
        return (& $make $false "The latest pre-cluster verification (run $($report.runId)) expired at $($effective.ToString('o')); $why." $report)
    }
    $accepted = @(@(& $get $report 'acceptedSkipped') | Where-Object { $_ })
    $note = if ($accepted.Count) { " $($accepted.Count) check(s) stayed Skipped and were accepted by the operator with -AcceptSkipped: $($accepted -join ', ')." } else { '' }
    return (& $make $true "The pre-cluster verification (run $($report.runId)) passed for this file and is valid until $($effective.ToString('o')).$note" $report)
}

Export-ModuleMember -Function ConvertTo-AzlPclUtc, Get-AzlPclContract, Get-AzlPclFileHash, Resolve-AzlPclReportDirectory, Get-AzlPclCommand, Read-AzlPclGateResult, Test-AzlPclGateResult
