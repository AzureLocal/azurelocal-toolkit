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
        example D:\Data\azl-ztp\tplabs\evidence gives D:\Data\azl-ztp\tplabs), else the one that holds media_path, else the folder of
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

function Test-AzlPclGateResult {
    <#
    .SYNOPSIS
        Whether the latest gate result allows an ARM Validate or Deploy of -InfrastructureFile.
    .DESCRIPTION
        It does only when report.json exists and is readable, is a Verify result of all six categories (not partial), has the verdict
        Pass, has the SHA-256 of the file as it is now, and has not expired. Every other case is Passed false with the reason and the
        exact command to run.
    .OUTPUTS
        Passed, Reason, Command, Directory, Verdict, FileHash, ExpiresUtc, RunId, Report.
    #>
    [CmdletBinding()]
    param(
        [string]$InfrastructureFile,
        [Parameter(Mandatory)][string]$Directory,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$HandoffFile,
        [string]$OsConfigurationReport
    )
    $command = Get-AzlPclCommand -InfrastructureFile $InfrastructureFile -ReportDirectory $Directory -HandoffFile $HandoffFile -OsConfigurationReport $OsConfigurationReport
    $make = {
        param([bool]$Passed, [string]$Reason, $Report)
        [pscustomobject]@{
            Passed = $Passed; Reason = $Reason; Command = $command; Directory = $Directory
            Verdict = $(if ($Report) { [string]$Report.verdict } else { '' }); FileHash = $(if ($Report) { [string]$Report.fileHash } else { '' })
            ExpiresUtc = $(if ($Report) { [string]$Report.expiresUtc } else { '' }); RunId = $(if ($Report) { [string]$Report.runId } else { '' }); Report = $Report
        }
    }
    if (-not $InfrastructureFile -or -not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) {
        return (& $make $false 'The ARM run was not given an infrastructure file (-InfrastructureFile), so the hash of the file the gate verified cannot be compared.' $null)
    }
    $report = Read-AzlPclGateResult -Directory $Directory
    if (-not $report) { return (& $make $false "There is no result of the pre-cluster verification in $Directory (no readable $script:ReportFile)." $null) }
    $props = $report.PSObject.Properties.Name
    foreach ($needed in 'schema', 'mode', 'verdict', 'fileHash', 'expiresUtc', 'partial') {
        if ($needed -notin $props) { return (& $make $false "The result in $Directory has no '$needed' field; it is not a result of this gate." $report) }
    }
    if ([int]$report.schema -ne $script:SchemaVersion) { return (& $make $false "The result in $Directory has schema $($report.schema); this toolkit reads schema $script:SchemaVersion." $report) }
    if ([string]$report.mode -ne 'Verify') { return (& $make $false "The latest result in $Directory is from mode '$($report.mode)'; only a Verify run counts." $report) }
    if ([bool]$report.partial) { return (& $make $false "The latest result in $Directory covers only some categories (-Category was used). A partial run never counts." $report) }
    if ([string]$report.verdict -ne 'Pass') { return (& $make $false "The latest pre-cluster verification (run $($report.runId)) has the verdict $($report.verdict), not Pass; $(@($report.checks | Where-Object { $_.blocking }).Count) check(s) block." $report) }
    $hash = Get-AzlPclFileHash -Path $InfrastructureFile
    if ([string]$report.fileHash -ne $hash) {
        return (& $make $false "The infrastructure file changed since the verification (run $($report.runId) saw SHA-256 $(([string]$report.fileHash).Substring(0, [Math]::Min(12, ([string]$report.fileHash).Length)))..., the file now has $($hash.Substring(0, 12))...)." $report)
    }
    $expires = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$report.expiresUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expires)) {
        return (& $make $false "The result in $Directory has an expiresUtc that is not a date ($($report.expiresUtc))." $report)
    }
    if ($Now.ToUniversalTime() -ge $expires) { return (& $make $false "The latest pre-cluster verification (run $($report.runId)) expired at $($expires.ToString('o')); results count for a limited time (deployment.pre_cluster_verification_max_age_hours)." $report) }
    return (& $make $true "The pre-cluster verification (run $($report.runId)) passed for this file and is valid until $($expires.ToString('o'))." $report)
}

Export-ModuleMember -Function Get-AzlPclContract, Get-AzlPclFileHash, Resolve-AzlPclReportDirectory, Get-AzlPclCommand, Read-AzlPclGateResult, Test-AzlPclGateResult
