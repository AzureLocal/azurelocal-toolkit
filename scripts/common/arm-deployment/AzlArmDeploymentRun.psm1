#Requires -Version 7.0
<#
.SYNOPSIS
    One run of the Azure Local ARM Validate and Deploy: preconditions, parameters, Validate, approval, Deploy, report.

.DESCRIPTION
    The design is docs/design/arm-validate-deploy.md. This module adds to AzlArmDeployment.psm1 (template choice, parameter
    generation, submit): the settings, the read-only preconditions, the key check that names the missing infrastructure.yml key,
    the run's state machine, polling with backoff and a time limit, the failing step of the step tree, the known-issue mapping,
    idempotent re-runs (attach, skip, resume), the approval gate, the event feed, report.json and summary.md, and the exit code.

    Every call that touches Azure or a node goes through the ADAPTER (New-AzlArmAzureAdapter): a table of scriptblocks. Tests
    pass a fake adapter, with a fake clock, so no test needs a subscription. Nothing runs at import.

    Exit codes: 0 the requested part succeeded; 1 a precondition failed, or the validation or deployment failed or timed out;
    2 bad input (a file or a required key is missing, unsupported scenario, no Azure sign-in when one is needed).

    Secrets: parameters hold keyvault:// references. The values are read into memory only when submitting, are remembered to be
    scrubbed from every text this module writes, and are never written.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlArmDeployment.psm1'))

$script:RepoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$script:KnownIssuesPath = [IO.Path]::Combine($script:RepoRoot, 'config', 'known-issues', 'arm-deployment.json')
$script:ParameterSourcesPath = [IO.Path]::Combine($script:RepoRoot, 'config', 'azure', 'arm-templates', 'parameter-sources.json')
$script:SecretValues = [System.Collections.Generic.List[string]]::new()
$script:EventMaxText = 2000
$script:ReportSchemaVersion = 1

$script:Transitions = @{
    Start              = @('Prepared')
    Prepared           = @('Validating', 'ValidationPassed', 'Resumed', 'Deploying')
    Validating         = @('ValidationPassed', 'ValidationFailed', 'ValidationTimedOut')
    ValidationPassed   = @('AwaitingApproval', 'Deploying', 'Resumed')
    AwaitingApproval   = @('Deploying', 'Resumed')
    Resumed            = @('Deploying', 'DeploymentSucceeded')
    Deploying          = @('DeploymentSucceeded', 'DeploymentFailed', 'DeploymentTimedOut')
    ValidationFailed   = @()
    ValidationTimedOut = @()
    DeploymentSucceeded = @()
    DeploymentFailed   = @()
    DeploymentTimedOut = @()
}

$script:RequiredProviders = @('Microsoft.AzureStackHCI', 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.KeyVault', 'Microsoft.Storage')
$script:RecommendedProviders = @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.HybridContainerService', 'Microsoft.Attestation', 'Microsoft.Insights')
$script:RequiredActions = @('Microsoft.Resources/deployments/write', 'Microsoft.AzureStackHCI/clusters/write', 'Microsoft.AzureStackHCI/clusters/deploymentSettings/write', 'Microsoft.KeyVault/vaults/write', 'Microsoft.Storage/storageAccounts/write', 'Microsoft.Authorization/roleAssignments/write')

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlArmArray([AllowNull()][object]$Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) { return @($Value) }
    return @($Value)
}

function Stop-AzlArmInput {
    # Bad input: the run ends with exit code 2.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object or throws; changes no system state.')]
    param([Parameter(Mandatory)][string]$Message)
    $e = [System.ArgumentException]::new($Message)
    $e.Data['AzlExit'] = 2
    throw $e
}

function Test-AzlArmFilled {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Count -gt 0 }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value).Count -gt 0 }
    return $true
}

function Format-AzlArmId([string]$Id) {
    # A GUID shortened for evidence text: the first 8 characters.
    if ($Id -match '^[0-9a-fA-F]{8}-') { return $Id.Substring(0, 8) + '...' }
    return $Id
}

function Register-AzlArmSecret {
    param([AllowNull()][string]$Value)
    if ($Value -and $Value.Length -ge 3 -and -not $script:SecretValues.Contains($Value)) { $script:SecretValues.Add($Value) }
}

function Hide-AzlArmSecret {
    <#
    .SYNOPSIS
        The text with every secret value this run read replaced by ***.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $out = $Text
    foreach ($s in $script:SecretValues) { $out = $out.Replace($s, '***') }
    return $out
}

function Limit-AzlArmText([AllowNull()][string]$Text, [int]$Max = $script:EventMaxText) {
    if ($null -eq $Text) { return '' }
    $one = ((Hide-AzlArmSecret $Text) -replace '\s*[\r\n]+\s*', ' ').Trim()
    if ($one.Length -gt $Max) { return $one.Substring(0, $Max - 3) + '...' }
    return $one
}

function Get-AzlArmParameterHash {
    <#
    .SYNOPSIS
        The first 12 hex characters of the SHA-256 of the canonical parameter JSON, without deploymentMode. Secrets are
        references, so a rotated secret does not change the hash. The same parameters give the same hash on any machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$ParameterSet)
    $canonical = [ordered]@{}
    foreach ($k in ($ParameterSet.Parameters.Keys | Sort-Object)) {
        if ($k -eq 'deploymentMode') { continue }
        $canonical[$k] = $ParameterSet.Parameters[$k]
    }
    $json = ConvertTo-Json -InputObject $canonical -Depth 30 -Compress
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($json))
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 12)
}

function ConvertTo-AzlArmStepStatus {
    <#
    .SYNOPSIS
        An Azure Local step or status word as notstarted, running, success, error, skipped or unknown (the words Sonar uses).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Status)
    if ($null -eq $Status) { return 'notstarted' }
    $key = ([string]$Status -replace '[\s_\-]', '').ToLowerInvariant()
    switch ($key) {
        { $_ -in '', 'notstarted' } { return 'notstarted' }
        { $_ -in 'success', 'succeeded', 'completed', 'deploymentsuccess', 'validationsuccess' } { return 'success' }
        { $_ -in 'inprogress', 'running', 'provisioning', 'creating', 'updating', 'accepted', 'deploymentinprogress', 'validationinprogress' } { return 'running' }
        { $_ -in 'error', 'failed', 'failure', 'canceled', 'cancelled', 'deploymentfailed', 'validationfailed' } { return 'error' }
        'skipped' { return 'skipped' }
    }
    return 'unknown'
}

# ---------------------------------------------------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlArmRunSetting {
    <#
    .SYNOPSIS
        The run's settings: defaults, then the master file's deployment block, then -ConfigPath (JSON), then -Settings.
    .DESCRIPTION
        Keys (camel case): validateTimeoutMinutes 90, deployTimeoutMinutes 360, pollSeconds 15, pollMaxSeconds 120,
        pollFactor 1.5, transientErrorLimit 5, approvalMode stop|prompt|none, resume false, requireOsConfigurationReport false,
        skipPreconditions [], acknowledgeKnownIssues [], deploymentSettingsApiVersion '', revalidate false, allowRevalidate false,
        requireValidatedParameterHash false, osReportMaxAgeHours 48, staleSkewMinutes 5, knownIssuesFile '', solutionVersion '',
        sbeCatalogPath ''. The master file's deployment block uses the same names in snake_case.
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Infrastructure, [string]$ConfigPath, [System.Collections.IDictionary]$Settings)
    $s = [ordered]@{
        validateTimeoutMinutes = 90; deployTimeoutMinutes = 360; pollSeconds = 15; pollMaxSeconds = 120; pollFactor = 1.5; transientErrorLimit = 5
        approvalMode = 'stop'; resume = $false; requireOsConfigurationReport = $false; skipPreconditions = @(); acknowledgeKnownIssues = @()
        deploymentSettingsApiVersion = ''; revalidate = $false; allowRevalidate = $false; requireValidatedParameterHash = $false
        osReportMaxAgeHours = 48; staleSkewMinutes = 5; knownIssuesFile = ''; solutionVersion = ''; sbeCatalogPath = ''
    }
    $apply = {
        param($source)
        foreach ($k in @($source.Keys)) {
            $camel = ([string]$k -replace '_(\w)', { $_.Groups[1].Value.ToUpperInvariant() })
            if ($camel -ieq 'approval') { $camel = 'approvalMode' }
            $match = @($s.Keys | Where-Object { $_ -ieq $camel })
            if ($match.Count -eq 1) { $s[$match[0]] = $source[$k] }
            else { Stop-AzlArmInput "Unknown deployment setting '$k'. Known: $($s.Keys -join ', ')." }
        }
    }
    $block = Get-AzlProp $Infrastructure 'deployment'
    if ($block -is [System.Collections.IDictionary]) { & $apply $block }
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Stop-AzlArmInput "Settings file not found: $ConfigPath" }
        & $apply (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 10)
    }
    if ($Settings) { & $apply $Settings }
    foreach ($k in 'validateTimeoutMinutes', 'deployTimeoutMinutes', 'pollSeconds', 'pollMaxSeconds', 'transientErrorLimit', 'osReportMaxAgeHours', 'staleSkewMinutes') {
        if ([int]$s[$k] -lt 1) { Stop-AzlArmInput "Setting $k must be 1 or more." }
        $s[$k] = [int]$s[$k]
    }
    if ([double]$s.pollFactor -lt 1) { Stop-AzlArmInput 'Setting pollFactor must be 1 or more.' }
    $s.pollFactor = [double]$s.pollFactor
    if ($s.pollMaxSeconds -lt $s.pollSeconds) { Stop-AzlArmInput 'Setting pollMaxSeconds must not be less than pollSeconds.' }
    if ([string]$s.approvalMode -notin 'stop', 'prompt', 'none') { Stop-AzlArmInput "Setting approval must be stop, prompt or none, not '$($s.approvalMode)'." }
    $s.approvalMode = [string]$s.approvalMode
    foreach ($k in 'resume', 'requireOsConfigurationReport', 'revalidate', 'allowRevalidate', 'requireValidatedParameterHash') { $s[$k] = [bool]$s[$k] }
    $s.solutionVersion = ([string]$s.solutionVersion).Trim()
    if ($s.solutionVersion -and $s.solutionVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { Stop-AzlArmInput "Setting solutionVersion must be four numeric parts, for example 12.2610.1004.50, not '$($s.solutionVersion)'." }
    $s.sbeCatalogPath = ([string]$s.sbeCatalogPath).Trim()
    $s.skipPreconditions = @(ConvertTo-AzlArmArray $s.skipPreconditions | ForEach-Object { [string]$_ })
    $s.acknowledgeKnownIssues = @(ConvertTo-AzlArmArray $s.acknowledgeKnownIssues | ForEach-Object { [string]$_ })
    return $s
}

# ---------------------------------------------------------------------------------------------------------------------
# Event feed
# ---------------------------------------------------------------------------------------------------------------------

function Write-AzlArmEvent {
    <#
    .SYNOPSIS
        Appends one line to the event feed (JSON Lines, UTF-8 without BOM). Never throws.
    .DESCRIPTION
        Fields: timestamp (UTC round trip), node ('*' for the run), stage ('ArmDeployment'), step, state, evidence, level,
        nextAction, schemaVersion, then -Data. Secrets are scrubbed from every text.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$State,
        [string]$Node = '*',
        [string]$Step = '',
        [string]$Evidence = '',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$NextAction = '',
        [string]$SchemaVersion = '',
        [System.Collections.IDictionary]$Data,
        [datetime]$Now = [datetime]::UtcNow
    )
    if (-not $Path) { return $false }
    try {
        $entry = [ordered]@{
            timestamp = $Now.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture)
            node = $Node; stage = 'ArmDeployment'; step = $Step; state = $State
            evidence = Limit-AzlArmText $Evidence; level = $Level; nextAction = Limit-AzlArmText $NextAction; schemaVersion = $SchemaVersion
        }
        if ($Data) {
            foreach ($key in $Data.Keys) {
                if ($entry.Contains([string]$key)) { continue }
                $value = $Data[$key]
                $entry[[string]$key] = if ($value -is [string]) { Limit-AzlArmText $value } else { $value }
            }
        }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n")
        $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
        return $true
    }
    catch { Write-Verbose "The event could not be written: $($_.Exception.Message)"; return $false }
}

function Send-AzlArmEvent {
    # The run's events: adds run id, mode and cluster, and uses the run's clock.
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$State, [string]$Node = '*', [string]$Step = '', [string]$Evidence = '', [string]$Level = 'Info', [string]$NextAction = '', [System.Collections.IDictionary]$Data)
    $extra = [ordered]@{ runId = $Run.RunId; mode = $Run.Mode; cluster = $Run.Cluster }
    if ($Data) { foreach ($k in $Data.Keys) { $extra[$k] = $Data[$k] } }
    $null = Write-AzlArmEvent -Path $Run.EventPath -State $State -Node $Node -Step $Step -Evidence $Evidence -Level $Level -NextAction $NextAction -SchemaVersion $Run.SchemaVersion -Data $extra -Now (& $Run.Adapter.Now)
}

# ---------------------------------------------------------------------------------------------------------------------
# Run state machine
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlArmRunTransition {
    <#
    .SYNOPSIS
        $true when a run may go from one state to the next (docs/design/arm-validate-deploy.md section 6).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    if (-not $script:Transitions.ContainsKey($From)) { return $false }
    return $To -in $script:Transitions[$From]
}

function New-AzlArmRunState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object or throws; changes no system state.')]
    [CmdletBinding()]
    param()
    [pscustomobject]@{ Current = 'Start'; History = [System.Collections.Generic.List[object]]::new() }
}

function Set-AzlArmRunState {
    <#
    .SYNOPSIS
        Moves the run to the next state; throws on a transition the design does not allow.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object or throws; changes no system state.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$To, [string]$Reason = '', [datetime]$At = [datetime]::UtcNow)
    if (-not (Test-AzlArmRunTransition -From $State.Current -To $To)) { throw "Run state $($State.Current) cannot go to $To." }
    $State.History.Add([ordered]@{ from = $State.Current; to = $To; at = $At.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture); reason = (Limit-AzlArmText $Reason 400) })
    $State.Current = $To
}

function Move-AzlArmRunState {
    # Set-AzlArmRunState for a Run: records, and writes the RunStateChanged event.
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$To, [string]$Reason = '')
    $from = $Run.State.Current
    Set-AzlArmRunState -State $Run.State -To $To -Reason $Reason -At (& $Run.Adapter.Now)
    Send-AzlArmEvent -Run $Run -State RunStateChanged -Evidence "$from -> $To$(if ($Reason) { ": $Reason" })" -Data @{ from = $from; to = $To }
}

# ---------------------------------------------------------------------------------------------------------------------
# Failing step and known issues
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlArmFailedStep {
    <#
    .SYNOPSIS
        The failing steps of a flattened step list (Get-AzlDeploymentState): steps in an error status that have no failing step
        below them, in the order of the list. The first one is the failing step the portal points at.
    .OUTPUTS
        FullStepIndex, Name, Status, Errors, Depth.
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$Steps)
    $list = @($Steps | Where-Object { $_ })
    $out = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $list.Count; $i++) {
        $s = $list[$i]
        if ((ConvertTo-AzlArmStepStatus $s.Status) -ne 'error') { continue }
        $hasFailedChild = $false
        for ($j = $i + 1; $j -lt $list.Count -and $list[$j].Depth -gt $s.Depth; $j++) {
            if ((ConvertTo-AzlArmStepStatus $list[$j].Status) -eq 'error') { $hasFailedChild = $true; break }
        }
        if (-not $hasFailedChild) { $out.Add([pscustomobject]@{ FullStepIndex = [string](Get-AzlProp $s 'FullStepIndex' ''); Name = [string]$s.Name; Status = [string]$s.Status; Errors = @($s.Errors); Depth = $s.Depth }) }
    }
    return $out.ToArray()
}

function Get-AzlArmKnownIssue {
    <#
    .SYNOPSIS
        config/known-issues/arm-deployment.json: the known failures (id, match, cause, remediation, retry, confidence, link).
    #>
    [CmdletBinding()]
    param([string]$Path = $script:KnownIssuesPath)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Known issues file not found: $Path" }
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    return @($json['issues'])
}

function Find-AzlArmKnownIssue {
    <#
    .SYNOPSIS
        The known issue for a failure, or $null. Every match member an entry gives (stepId, stepName, error; regular expressions,
        case-insensitive) must match; the entry with the most members wins, the first in the file on a tie.
    .PARAMETER Phase
        Validate or Deploy: only entries for that phase are considered.
    .PARAMETER Build
        The solution build (the handoff's vsrVersion). An entry with affectedBuilds gets BuildNote when the build is not one of them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Phase,
        [string]$StepId = '', [string]$StepName = '', [string]$ErrorText = '', [string]$Build = '',
        [object[]]$Issues = (Get-AzlArmKnownIssue)
    )
    $best = $null; $bestCount = 0
    foreach ($issue in $Issues) {
        if ($Phase -notin @(ConvertTo-AzlArmArray $issue['phase'])) { continue }
        $m = $issue['match']
        $checks = @(@('stepId', $StepId), @('stepName', $StepName), @('error', $ErrorText))
        $given = 0; $ok = $true
        foreach ($c in $checks) {
            if ($m.Contains($c[0])) {
                $given++
                if (-not $c[1] -or -not [regex]::IsMatch([string]$c[1], [string]$m[$c[0]], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $ok = $false; break }
            }
        }
        if ($ok -and $given -gt $bestCount) { $best = $issue; $bestCount = $given }
    }
    if (-not $best) { return $null }
    $note = ''
    $builds = @(ConvertTo-AzlArmArray $best['affectedBuilds'])
    if ($builds.Count -and $Build -and -not ($builds | Where-Object { $Build.StartsWith([string]$_) })) { $note = "Not yet seen on build $Build (known on $($builds -join ', '))." }
    [pscustomobject]@{
        Id = [string]$best['id']; Title = [string]$best['title']; Cause = [string]$best['cause']; Remediation = @($best['remediation']); Retry = [string]$best['retry']
        Confidence = [string]$best['confidence']; Link = [string]$best['link']; Evidence = [string]$best['evidence']; BuildNote = $note; MatchedMembers = $bestCount
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Parameter sources: the key check
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlArmParameterSource {
    <#
    .SYNOPSIS
        config/azure/arm-templates/parameter-sources.json: ARM parameter name -> its infrastructure.yml keys.
    #>
    [CmdletBinding()]
    param([string]$Path = $script:ParameterSourcesPath)
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20)['parameters']
}

function Test-AzlArmRequiredKey {
    <#
    .SYNOPSIS
        The required ARM parameters whose infrastructure.yml keys are empty, as messages that name the key. Nothing when all is set.
    .PARAMETER TemplateName
        The template Select-AzlArmTemplate chose.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [Parameter(Mandatory)][string]$TemplateName,
        [hashtable]$Catalog = (Get-AzlArmTemplateCatalog),
        [System.Collections.IDictionary]$Source = (Get-AzlArmParameterSource)
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $declared = $Catalog.templates[$TemplateName].parameters
    foreach ($name in $declared.Keys) {
        if (-not $Source.Contains($name)) { continue }
        $entry = $Source[$name]
        $required = [bool]$entry['required']
        $why = 'always required'
        if ($entry.Contains('requiredWhen')) {
            $all = $true
            foreach ($path in $entry['requiredWhen'].Keys) {
                if ([string](Get-AzlProp $Infrastructure $path '') -ne [string]$entry['requiredWhen'][$path]) { $all = $false }
            }
            if ($all) { $required = $true; $why = 'required when ' + ((@($entry['requiredWhen'].Keys) | ForEach-Object { "$_ is $($entry['requiredWhen'][$_])" }) -join ' and ') }
        }
        if (-not $required) { continue }
        $keys = if ($entry.Contains('requiredKeys')) { @($entry['requiredKeys']) } else { @(@($entry['keys']) | Where-Object { $_ -notmatch '\[\]' }) }
        foreach ($key in $keys) {
            if (-not (Test-AzlArmFilled (Get-AzlProp $Infrastructure ([string]$key)))) {
                $problems.Add("ARM parameter $name ($why) needs $key in infrastructure.yml, and it is empty.")
            }
        }
    }
    return $problems.ToArray()
}

function Format-AzlArmParameterSource {
    <#
    .SYNOPSIS
        Markdown table: each ARM parameter in the set, the infrastructure.yml keys it came from, and whether it is a secret. The SBE
        parameters that are not in the set (no SBE configured) are listed with the value 'no SBE configured'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$ParameterSet, [System.Collections.IDictionary]$Source = (Get-AzlArmParameterSource))
    $lines = @("Template: $($ParameterSet.Template.Name)", '', '| ARM parameter | infrastructure.yml keys | Other source | Value |', '| --- | --- | --- | --- |')
    foreach ($name in $ParameterSet.Parameters.Keys) {
        $e = if ($Source.Contains($name)) { $Source[$name] } else { @{} }
        $keys = if ($e.Contains('keys') -and @($e['keys']).Count) { (@($e['keys']) | ForEach-Object { "``$_``" }) -join ', ' } else { '' }
        $other = if ($e.Contains('source')) { [string]$e['source'] } else { '' }
        $v = $ParameterSet.Parameters[$name]
        $kind = if ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) { 'secret (Key Vault reference)' } else { 'value' }
        $lines += "| $name | $keys | $other | $kind |"
    }
    # The Solution Builder Extension is opt-in: its parameters are left out of the set when none is configured. Say so, per parameter.
    foreach ($name in 'sbeVersion', 'sbeFamily', 'sbePublisher', 'sbeManifestSource', 'sbeManifestCreationDate', 'partnerProperties', 'partnerCredentiallist') {
        if ($ParameterSet.Parameters.Contains($name)) { continue }
        $e = if ($Source.Contains($name)) { $Source[$name] } else { @{} }
        $keys = if ($e.Contains('keys') -and @($e['keys']).Count) { (@($e['keys']) | ForEach-Object { "``$_``" }) -join ', ' } else { '' }
        $other = if ($e.Contains('source')) { [string]$e['source'] } else { '' }
        $lines += "| $name | $keys | $other | no SBE configured |"
    }
    return ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------------------------------------------------
# The Azure adapter
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlArmAzureAdapter {
    <#
    .SYNOPSIS
        The table of scriptblocks that touch Azure, a node or the clock. Tests replace members with fakes.
    .DESCRIPTION
        Reads only, except Submit. Members: Now, Sleep, GetContext, GetResourceGroup, GetProviderState, GetPermission,
        TestNameAvailable, TestSecret, GetSecret, GetArcMachine, GetDeploymentState, GetArmDeployment, GetTemplate, Submit,
        ResolveDns, TestActiveDirectory, ProbeOsConfiguration, Prompt. A member that is $null is "not available here"; the
        check that needs it is Skipped with that reason.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object or throws; changes no system state.')]
    [CmdletBinding()]
    param()
    [ordered]@{
        Now = { [datetime]::UtcNow }
        Sleep = { param([double]$Seconds) Start-Sleep -Seconds $Seconds }
        GetContext = {
            if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) { return $null }
            $c = Get-AzContext
            if (-not $c) { return $null }
            [pscustomobject]@{ SubscriptionId = [string]$c.Subscription.Id; TenantId = [string]$c.Tenant.Id; Account = [string]$c.Account.Id }
        }
        GetResourceGroup = { param($Subscription, $ResourceGroup) Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourceGroups/$ResourceGroup" -ApiVersion '2024-03-01' -AllowNotFound }
        GetProviderState = {
            param($Subscription, $Namespace)
            $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/providers/$Namespace" -ApiVersion '2021-04-01' -AllowNotFound
            if ($r) { [string](Get-AzlProp $r 'registrationState' '') } else { 'NotFound' }
        }
        GetPermission = {
            param($Subscription, $ResourceGroup)
            $r = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Authorization/permissions" -ApiVersion '2022-04-01'
            @(Get-AzlProp $r 'value' @() | ForEach-Object { [pscustomobject]@{ Actions = @($_.actions); NotActions = @($_.notActions) } })
        }
        TestNameAvailable = {
            param($Subscription, $ResourceGroup, $Type, $Name)
            if ($Type -eq 'storage') {
                $existing = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$Name" -ApiVersion '2023-05-01' -AllowNotFound
                if ($existing) { return [pscustomobject]@{ Available = $false; ExistsInResourceGroup = $true; Reason = '' } }
                $r = Invoke-AzlArm -Method POST -Path "/subscriptions/$Subscription/providers/Microsoft.Storage/checkNameAvailability" -ApiVersion '2023-05-01' -Body @{ name = $Name; type = 'Microsoft.Storage/storageAccounts' }
                return [pscustomobject]@{ Available = [bool](Get-AzlProp $r 'nameAvailable' $false); ExistsInResourceGroup = $false; Reason = [string](Get-AzlProp $r 'message' '') }
            }
            $existing = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$Name" -ApiVersion '2023-07-01' -AllowNotFound
            if ($existing) { return [pscustomobject]@{ Available = $false; ExistsInResourceGroup = $true; Reason = '' } }
            $r = Invoke-AzlArm -Method POST -Path "/subscriptions/$Subscription/providers/Microsoft.KeyVault/checkNameAvailability" -ApiVersion '2023-07-01' -Body @{ name = $Name; type = 'Microsoft.KeyVault/vaults' }
            [pscustomobject]@{ Available = [bool](Get-AzlProp $r 'nameAvailable' $false); ExistsInResourceGroup = $false; Reason = [string](Get-AzlProp $r 'message' '') }
        }
        TestSecret = {
            param($Vault, $Secret)
            # Metadata only: the value is not read.
            $s = Get-AzKeyVaultSecret -VaultName $Vault -Name $Secret -ErrorAction Stop
            return [bool]$s
        }
        GetSecret = { param($Reference) Get-AzlSecret -Reference $Reference }
        GetHciResourceProviderObjectId = { Get-AzlHciResourceProviderObjectId }
        GetArcMachine = {
            param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup)
            $null = $Node
            $path = if ($ResourceId) { $ResourceId } else { "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcMachineName" }
            $m = Invoke-AzlArm -Method GET -Path $path -ApiVersion '2024-07-10' -AllowNotFound
            if (-not $m) { return $null }
            [pscustomobject]@{
                Name = [string](Get-AzlProp $m 'name' ''); ResourceId = [string](Get-AzlProp $m 'id' $path); Status = [string](Get-AzlProp $m 'properties.status' '')
                OsVersion = [string](Get-AzlProp $m 'properties.osVersion' ''); ComputerName = [string](Get-AzlProp $m 'properties.osProfile.computerName' '')
            }
        }
        GetDeploymentState = { param($Subscription, $ResourceGroup, $Cluster) Get-AzlDeploymentState -SubscriptionId $Subscription -ResourceGroup $ResourceGroup -ClusterName $Cluster }
        GetArmDeployment = {
            param($Subscription, $ResourceGroup, $Name)
            $d = Invoke-AzlArm -Method GET -Path "/subscriptions/$Subscription/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$Name" -ApiVersion '2024-03-01' -AllowNotFound
            if (-not $d) { return $null }
            [pscustomobject]@{ ProvisioningState = [string](Get-AzlProp $d 'properties.provisioningState' ''); Error = [string](Get-AzlProp $d 'properties.error.message' ''); Timestamp = [string](Get-AzlProp $d 'properties.timestamp' '') }
        }
        GetTemplate = { param($Uri) Invoke-RestMethod -Uri $Uri }
        Submit = {
            param($Arguments)
            Invoke-AzlArmDeployment @Arguments -NoWait
        }
        ResolveDns = {
            param($Name, $Server)
            try { [bool](Resolve-DnsName -Name $Name -Server $Server -DnsOnly -ErrorAction Stop) } catch { $false }
        }
        TestActiveDirectory = {
            param($Domain, $OuPath, $LcmUser)
            # Needs the ActiveDirectory module and a domain-joined host; $null when it can't be asked.
            if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { return $null }
            Import-Module ActiveDirectory
            $ou = $null; $user = $null
            try { $ou = Get-ADOrganizationalUnit -Identity $OuPath -Server $Domain -ErrorAction Stop } catch { Write-Verbose "OU not found: $($_.Exception.Message)" }
            try { $user = Get-ADUser -Identity $LcmUser -Server $Domain -ErrorAction Stop } catch { Write-Verbose "LCM user not found: $($_.Exception.Message)" }
            [pscustomobject]@{ OuExists = [bool]$ou; LcmUserExists = [bool]$user }
        }
        ProbeOsConfiguration = {
            param($InfrastructureFile, $HandoffFile)
            # Read-only: the OS configuration run in Plan mode. $null when the script isn't in this checkout.
            $script = [IO.Path]::Combine($script:RepoRoot, 'scripts', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Invoke-AzureLocalOsConfiguration.ps1')
            if (-not (Test-Path -LiteralPath $script)) { return $null }
            $dir = Join-Path ([IO.Path]::GetTempPath()) ('azl-osconfig-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $arguments = @{ InfrastructureFile = $InfrastructureFile; Mode = 'Plan'; ReportDirectory = $dir }
            if ($HandoffFile) { $arguments.HandoffPath = $HandoffFile }
            $null = & $script @arguments
            $report = Join-Path $dir 'plan-report.json'
            if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw | ConvertFrom-Json -Depth 20 }
        }
        Prompt = {
            param($Caption, $Message)
            if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return $null }
            $choices = [System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]]@(
                [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', 'Continue with the deployment'),
                [System.Management.Automation.Host.ChoiceDescription]::new('&No', 'Stop here'))
            $Host.UI.PromptForChoice($Caption, $Message, $choices, 1) -eq 0
        }
    }
}

function Invoke-AzlArmAdapter {
    # Calls an adapter member; a member that is missing or $null is "not available here".
    param([Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)][string]$Name, [object[]]$Argument = @())
    if (-not $Adapter.Contains($Name) -or $null -eq $Adapter[$Name]) { throw [System.NotSupportedException]::new("The adapter has no '$Name' here.") }
    return (& $Adapter[$Name] @Argument)
}

function Test-AzlArmAdapterHas([Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)][string]$Name) {
    return ($Adapter.Contains($Name) -and $null -ne $Adapter[$Name])
}

# ---------------------------------------------------------------------------------------------------------------------
# Reading the OS configuration report
# ---------------------------------------------------------------------------------------------------------------------

function Read-AzlArmOsReport {
    <#
    .SYNOPSIS
        The OS configuration report as an object with nodes[]. -Path is a report.json (the one-run cluster report), a
        node-level report (Set-AzureLocalNodeConfiguration -ReportPath), or a directory that holds report.json. Nodes that lack
        ports or SAN disks get them from the node reports next to the cluster report (node-reports/*.json).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $file = $Path
    if (Test-Path -LiteralPath $Path -PathType Container) { $file = Join-Path $Path 'report.json' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-AzlArmInput "OS configuration report not found: $file" }
    $report = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -Depth 20
    if (-not (Get-AzlProp $report 'nodes')) { Stop-AzlArmInput "$file has no nodes[]; it is not an OS configuration report." }
    $dir = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $file).ProviderPath) 'node-reports'
    if (Test-Path -LiteralPath $dir -PathType Container) {
        $byName = @{}
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
            $nr = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -Depth 20
            foreach ($n in @(Get-AzlProp $nr 'nodes' @())) { $byName[([string]$n.name).ToLowerInvariant()] = $n }
            if ((Get-AzlProp $nr 'name') -and (Get-AzlProp $nr 'ports')) { $byName[([string]$nr.name).ToLowerInvariant()] = $nr }
        }
        foreach ($n in @($report.nodes)) {
            $extra = $byName[([string]$n.name).ToLowerInvariant()]
            if (-not $extra) { continue }
            foreach ($p in 'ports', 'sanDisks', 'osVersion', 'hostname') {
                if (-not (Get-AzlProp $n $p) -and (Get-AzlProp $extra $p)) { $n | Add-Member -NotePropertyName $p -NotePropertyValue (Get-AzlProp $extra $p) -Force }
            }
        }
    }
    return $report
}

# ---------------------------------------------------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlArmCheckResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object or throws; changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Passed', 'Failed', 'Warning', 'Skipped')][string]$Result,
        [string]$Evidence = '', [string]$NextAction = '', [string]$Node = '*'
    )
    [pscustomobject]@{ Name = $Name; Node = $Node; Result = $Result; Evidence = $Evidence; NextAction = $NextAction }
}

function Get-AzlArmArcMachineCached {
    # One Arc machine lookup per node per run.
    param($Ctx, $Node)
    $name = [string]$Node['name']
    if ($Ctx.ArcMachines.ContainsKey($name)) { return $Ctx.ArcMachines[$name] }
    $handoffNode = Get-AzlHandoffNode -Handoff $Ctx.Handoff -Name $name -ArcMachineName (Get-AzlArcMachineName -Node $Node)
    $id = if ($handoffNode -and (Get-AzlProp $handoffNode 'arcMachineResourceId')) { [string](Get-AzlProp $handoffNode 'arcMachineResourceId') } else { '' }
    $machine = Invoke-AzlArmAdapter $Ctx.Run.Adapter GetArcMachine @($name, $id, (Get-AzlArcMachineName -Node $Node), $Ctx.Subscription, $Ctx.ResourceGroup)
    $Ctx.ArcMachines[$name] = $machine
    return $machine
}

# ---------------------------------------------------------------------------------------------------------------------
# SBE and solution version: is the SBE validated with the solution the nodes run?
# ---------------------------------------------------------------------------------------------------------------------

# OS build -> the solution line it ships with (first three parts of the solution version; the last part is the build of the
# solution package and is not known from the OS build). Add a row only when both were seen together on a real deployment.
$script:SolutionOsBuilds = @(
    [pscustomobject]@{ OsBuild = '10.0.26100.33650'; Solution = '12.2610.1004'; Evidence = 'tplabs lab 2026-11-08: nodes on 10.0.26100.33650, Azure reported Solution version 12.2610.1004.50' }
)

function Read-AzlArmSbeCatalog {
    <#
    .SYNOPSIS
        An OEM's SBE discovery catalog (SBE_Discovery_Dell.xml): one entry per ApplicableUpdate, with the Solution version
        patterns of its ValidatedConfigurations/RequiredPackages. Reads the file only; DTDs are refused.
    .OUTPUTS
        Name (UpdateName), Version, Family, SolutionPatterns (Pattern, MinVersionRequired).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "SBE discovery catalog not found: $Path" }
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $xml = [xml]::new()
    $reader = [System.Xml.XmlReader]::Create((Resolve-Path -LiteralPath $Path).ProviderPath, $settings)
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    $root = $xml.SelectSingleNode('/SBEUpdatesManifest')
    if (-not $root) { throw "$Path is not an SBE discovery catalog (no SBEUpdatesManifest root)." }
    foreach ($node in $root.SelectNodes('ApplicableUpdate')) {
        $patterns = foreach ($package in $node.SelectNodes('ValidatedConfigurations/RequiredPackages/Package[@Type="Solution"]')) {
            [pscustomobject]@{ Pattern = [string]$package.GetAttribute('Version'); MinVersionRequired = [string]$package.GetAttribute('MinVersionRequired') }
        }
        [pscustomobject]@{
            Name             = [string]$node.SelectSingleNode('UpdateInfo/UpdateName')?.InnerText
            Version          = [string]$node.GetAttribute('Version')
            Family           = [string]$node.GetAttribute('Family')
            SolutionPatterns = @($patterns)
        }
    }
}

function Test-AzlArmSolutionVersionMatch {
    <#
    .SYNOPSIS
        $true when a solution version matches a catalog pattern (12.*.1004.*; * stands for any text). A three-part version (the
        solution line derived from the OS build) is compared on the first three parts, and a MinVersionRequired it cannot prove
        is not held against it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Version, [string]$MinVersionRequired = '')
    $parts = $Version.Split('.')
    $effective = $Pattern
    if ($parts.Count -eq 3) { $effective = (($Pattern.Split('.') | Select-Object -First 3) -join '.') }
    $regex = '^' + ((($effective -split '\*') | ForEach-Object { [regex]::Escape($_) }) -join '.*') + '$'
    if (-not [regex]::IsMatch($Version, $regex)) { return $false }
    if ($MinVersionRequired -and $parts.Count -eq 4) {
        $have = $null; $min = $null
        if ([version]::TryParse($Version, [ref]$have) -and [version]::TryParse($MinVersionRequired, [ref]$min) -and $have -lt $min) { return $false }
    }
    return $true
}

function ConvertFrom-AzlArmOsBuild {
    <#
    .SYNOPSIS
        The solution line (three parts, for example 12.2610.1004) a node's OS build ships with, or $null. Conservative: only a
        build in the table that was seen on a real deployment maps; any other build is unknown. The result is always derived.
    .OUTPUTS
        Version (three parts), OsBuild, Derived ($true), Note.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$OsBuild)
    if (-not $OsBuild) { return $null }
    $row = $script:SolutionOsBuilds | Where-Object { $_.OsBuild -eq $OsBuild.Trim() } | Select-Object -First 1
    if (-not $row) { return $null }
    [pscustomobject]@{ Version = $row.Solution; OsBuild = $row.OsBuild; Derived = $true; Note = "derived from OS build $($row.OsBuild) ($($row.Evidence))" }
}

function Test-AzlArmSbeSolution {
    <#
    .SYNOPSIS
        Looks up an SBE (family and version) in a catalog from Read-AzlArmSbeCatalog and says whether it is validated with a solution
        version.
    .OUTPUTS
        Status (Validated, NotValidated, NotListed), Entry, Patterns (the SBE's Solution patterns), MatchedPattern,
        ValidatedVersions (SBE versions of the same family that are validated with the solution, newest first), ValidatedElsewhere
        (names of validated SBEs of other families; only when the family has none).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog, [Parameter(Mandatory)][string]$Family, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Solution)
    $wanted = $Solution
    $validated = {
        param($entry)
        foreach ($p in @($entry.SolutionPatterns)) { if (Test-AzlArmSolutionVersionMatch -Pattern $p.Pattern -Version $wanted -MinVersionRequired $p.MinVersionRequired) { return $p.Pattern } }
        return $null
    }
    $entry = @($Catalog | Where-Object { $_.Family -ieq $Family -and $_.Version -eq $Version }) | Select-Object -First 1
    if (-not $entry) { return [pscustomobject]@{ Status = 'NotListed'; Entry = $null; Patterns = @(); MatchedPattern = $null; ValidatedVersions = @(); ValidatedElsewhere = @() } }
    $matched = & $validated $entry
    $sameFamily = @($Catalog | Where-Object { $_.Family -ieq $Family -and (& $validated $_) } | Sort-Object { $v = $null; if ([version]::TryParse($_.Version, [ref]$v)) { $v } else { [version]'0.0' } } -Descending | ForEach-Object { $_.Version })
    $elsewhere = @()
    if (-not $matched -and $sameFamily.Count -eq 0) { $elsewhere = @($Catalog | Where-Object { $_.Family -ine $Family -and (& $validated $_) } | ForEach-Object { $_.Name }) }
    [pscustomobject]@{
        Status = $(if ($matched) { 'Validated' } else { 'NotValidated' }); Entry = $entry; Patterns = @($entry.SolutionPatterns | ForEach-Object { $_.Pattern })
        MatchedPattern = $matched; ValidatedVersions = $sameFamily; ValidatedElsewhere = $elsewhere
    }
}

function Join-AzlArmList([string[]]$Item) {
    if ($Item.Count -le 1) { return ($Item -join '') }
    return (($Item | Select-Object -SkipLast 1) -join ', ') + ' and ' + $Item[-1]
}

function Resolve-AzlArmSbeCatalogFile {
    # The catalog file the run reads, and where the path came from: the run setting sbeCatalogPath, else the SBE_Discovery_*.xml in
    # hardware.sbe.bundle_path. A folder is searched for SBE_Discovery_*.xml. Nothing is downloaded.
    param($Ctx)
    $path = [string]$Ctx.Settings.sbeCatalogPath
    $from = 'run setting sbeCatalogPath'
    if (-not $path) { $path = [string](Get-AzlProp $Ctx.Infra 'hardware.sbe.bundle_path' ''); $from = 'hardware.sbe.bundle_path' }
    if (-not $path) { return [pscustomobject]@{ File = ''; Reason = 'No SBE discovery catalog is available: set hardware.sbe.bundle_path (the folder with the SBE files, including SBE_Discovery_*.xml) or the run setting sbeCatalogPath (deployment.sbe_catalog_path). Nothing is downloaded.' } }
    if (Test-Path -LiteralPath $path -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $path -File -Filter 'SBE_Discovery_*.xml' | Sort-Object Name)
        if ($found.Count -eq 0) { return [pscustomobject]@{ File = ''; Reason = "No SBE_Discovery_*.xml in $path ($from), so the SBE was not compared with the solution version. Nothing is downloaded." } }
        return [pscustomobject]@{ File = $found[0].FullName; Reason = '' }
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return [pscustomobject]@{ File = (Resolve-Path -LiteralPath $path).ProviderPath; Reason = '' } }
    [pscustomobject]@{ File = ''; Reason = "The SBE discovery catalog $path ($from) is not on this host, so the SBE was not compared with the solution version. Nothing is downloaded." }
}

function Resolve-AzlArmSolutionVersion {
    # The solution version the nodes run: the run setting, else the ZTP handoff's, else derived from the nodes' OS build (only a
    # build that maps unambiguously). Returns Version, Derived, Source; or Version $null with Source holding the reason.
    param($Ctx)
    if ($Ctx.Settings.solutionVersion) { return [pscustomobject]@{ Version = $Ctx.Settings.solutionVersion; Derived = $false; Source = 'run setting solutionVersion' } }
    if ([string]$Ctx.Build -match '^\d+\.\d+\.\d+\.\d+$') { return [pscustomobject]@{ Version = [string]$Ctx.Build; Derived = $false; Source = "the ZTP handoff's solution version" } }
    $builds = [ordered]@{}
    $problem = ''
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $v = ''
        if (-not $Ctx.Offline) {
            try { $m = Get-AzlArmArcMachineCached $Ctx $n; if ($m -and $m.OsVersion) { $v = [string]$m.OsVersion } }
            catch { $problem = " The Arc machine could not be read ($($_.Exception.Message))." }
        }
        if (-not $v -and $Ctx.OsReport) {
            $r = @(ConvertTo-AzlArmArray (Get-AzlProp $Ctx.OsReport 'nodes' @()) | Where-Object { ([string]$_.name) -ieq $name }) | Select-Object -First 1
            if ($r) { $v = [string](Get-AzlProp $r 'osVersion' '') }
        }
        $builds[$name] = $v
    }
    $known = @($builds.Values | Where-Object { $_ } | Select-Object -Unique)
    if ($known.Count -eq 0) { return [pscustomobject]@{ Version = $null; Derived = $false; Source = "No node reports its OS build and neither the run setting solutionVersion nor a ZTP handoff gives the solution version.$problem" } }
    $mapped = @(foreach ($b in $known) { $one = ConvertFrom-AzlArmOsBuild -OsBuild $b; if ($one) { $one } })
    if ($mapped.Count -eq $known.Count -and @($mapped | ForEach-Object { $_.Version } | Select-Object -Unique).Count -eq 1) {
        return [pscustomobject]@{ Version = $mapped[0].Version; Derived = $true; Source = $mapped[0].Note }
    }
    [pscustomobject]@{ Version = $null; Derived = $false; Source = "OS build $($known -join ', ') does not map unambiguously to a solution version (nothing is guessed).$problem" }
}

$script:Checks = [ordered]@{}

$script:Checks['AzureContext'] = {
    param($Ctx)
    $c = $Ctx.AzureContext
    if (-not $c) { return New-AzlArmCheckResult AzureContext Failed 'Nobody is signed in to Azure.' 'Sign in first: Connect-AzAccount (jump server), or the pipeline''s OIDC or managed identity login step.' }
    $problems = @()
    if ($c.SubscriptionId -ne $Ctx.Subscription) { $problems += "the context is subscription $(Format-AzlArmId $c.SubscriptionId), the file says $(Format-AzlArmId $Ctx.Subscription)" }
    $tenant = [string](Get-AzlProp $Ctx.Infra 'azure.tenant_id' '')
    if ($tenant -and $c.TenantId -and $c.TenantId -ne $tenant) { $problems += "the context is tenant $(Format-AzlArmId $c.TenantId), the file says $(Format-AzlArmId $tenant)" }
    if ($problems) { return New-AzlArmCheckResult AzureContext Failed ("Wrong Azure context: " + ($problems -join '; ') + '.') 'Select the right subscription (Set-AzContext) or fix azure.subscription_id and azure.tenant_id.' }
    New-AzlArmCheckResult AzureContext Passed "Signed in as $($c.Account) to subscription $(Format-AzlArmId $c.SubscriptionId)."
}

$script:Checks['ResourceGroup'] = {
    param($Ctx)
    $rg = Invoke-AzlArmAdapter $Ctx.Run.Adapter GetResourceGroup @($Ctx.Subscription, $Ctx.ResourceGroup)
    if (-not $rg) { return New-AzlArmCheckResult ResourceGroup Failed "Resource group $($Ctx.ResourceGroup) does not exist." 'Create it, or fix azure.resource_group.' }
    New-AzlArmCheckResult ResourceGroup Passed "Resource group $($Ctx.ResourceGroup) exists."
}

$script:Checks['ResourceProviders'] = {
    param($Ctx)
    $missing = @(); $weak = @()
    foreach ($ns in $script:RequiredProviders) { if ((Invoke-AzlArmAdapter $Ctx.Run.Adapter GetProviderState @($Ctx.Subscription, $ns)) -ne 'Registered') { $missing += $ns } }
    foreach ($ns in $script:RecommendedProviders) { if ((Invoke-AzlArmAdapter $Ctx.Run.Adapter GetProviderState @($Ctx.Subscription, $ns)) -ne 'Registered') { $weak += $ns } }
    if ($missing) { return New-AzlArmCheckResult ResourceProviders Failed "Not registered: $($missing -join ', ')." (($missing | ForEach-Object { "az provider register --namespace $_" }) -join '; ') }
    if ($weak) { return New-AzlArmCheckResult ResourceProviders Warning "Required providers are registered. Not registered (used by Arc VMs and AKS): $($weak -join ', ')." 'Register them before you create Arc VMs or AKS clusters.' }
    New-AzlArmCheckResult ResourceProviders Passed 'All resource providers are registered.'
}

$script:Checks['Permissions'] = {
    param($Ctx)
    $perm = @(Invoke-AzlArmAdapter $Ctx.Run.Adapter GetPermission @($Ctx.Subscription, $Ctx.ResourceGroup))
    if ($perm.Count -eq 0) { return New-AzlArmCheckResult Permissions Warning 'The effective permissions could not be read.' 'Make sure the identity is Owner, or Contributor plus User Access Administrator, on the resource group.' }
    $missing = foreach ($action in $script:RequiredActions) {
        $allowed = $false
        foreach ($p in $perm) {
            $yes = @($p.Actions | Where-Object { $action -like $_ }).Count -gt 0
            $no = @($p.NotActions | Where-Object { $action -like $_ }).Count -gt 0
            if ($yes -and -not $no) { $allowed = $true }
        }
        if (-not $allowed) { $action }
    }
    if ($missing) { return New-AzlArmCheckResult Permissions Failed "The signed-in identity may not: $(@($missing) -join ', ')." 'Give it Owner, or Contributor plus User Access Administrator, on the resource group.' }
    New-AzlArmCheckResult Permissions Passed 'The identity may create the deployment, the cluster, the Key Vault, storage accounts and role assignments.'
}

$script:Checks['NamesAvailable'] = {
    param($Ctx)
    $p = $Ctx.Set.Parameters
    $names = @()
    if ($p.Contains('diagnosticStorageAccountName') -and $p['diagnosticStorageAccountName']) { $names += , @('storage', [string]$p['diagnosticStorageAccountName']) }
    if ($p.Contains('witnessType') -and $p['witnessType'] -eq 'Cloud' -and $p.Contains('clusterWitnessStorageAccountName') -and $p['clusterWitnessStorageAccountName']) { $names += , @('storage', [string]$p['clusterWitnessStorageAccountName']) }
    if ($p.Contains('createNewKeyVault') -and $p['createNewKeyVault'] -and $p['keyVaultName']) { $names += , @('keyvault', [string]$p['keyVaultName']) }
    $bad = @()
    foreach ($n in $names) {
        $r = Invoke-AzlArmAdapter $Ctx.Run.Adapter TestNameAvailable @($Ctx.Subscription, $Ctx.ResourceGroup, $n[0], $n[1])
        if (-not $r.Available -and -not $r.ExistsInResourceGroup) { $bad += "$($n[1]) ($($n[0]))$(if ($r.Reason) { ': ' + $r.Reason })" }
    }
    if ($bad) { return New-AzlArmCheckResult NamesAvailable Failed "Name taken or unusable: $($bad -join '; ')." 'Choose another name in the file. A soft-deleted Key Vault keeps its name until it is purged.' }
    New-AzlArmCheckResult NamesAvailable Passed "$($names.Count) resource name(s) are free or already in the resource group."
}

$script:Checks['KeyVaultSecrets'] = {
    param($Ctx)
    $refs = @()
    foreach ($k in $Ctx.Set.Parameters.Keys) {
        $v = $Ctx.Set.Parameters[$k]
        if ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) { $refs += [pscustomobject]@{ Parameter = $k; Reference = [string]$v.KeyVault } }
    }
    $listed = @(ConvertTo-AzlArmArray $Ctx.Infra['key_vaults'] | ForEach-Object { [string]$_['name'] })
    $bad = @()
    foreach ($r in $refs) {
        $parts = ConvertFrom-AzlKeyVaultRef -Reference $r.Reference
        if (-not $parts) { $bad += "$($r.Parameter): '$($r.Reference)' is not a keyvault:// reference"; continue }
        if ($parts.Vault -notin $listed) { $bad += "$($r.Parameter): vault $($parts.Vault) is not listed under key_vaults"; continue }
        $exists = $false
        try { $exists = [bool](Invoke-AzlArmAdapter $Ctx.Run.Adapter TestSecret @($parts.Vault, $parts.Secret)) } catch { $bad += "$($r.Parameter): secret $($parts.Secret) in $($parts.Vault) could not be read ($($_.Exception.Message))"; continue }
        if (-not $exists) { $bad += "$($r.Parameter): secret $($parts.Secret) is not in vault $($parts.Vault)" }
    }
    if ($bad) { return New-AzlArmCheckResult KeyVaultSecrets Failed ($bad -join '; ') 'Create the secret (Add-KeyVaultCredentials.ps1), grant this identity Get on secrets, or fix the keyvault:// reference.' }
    New-AzlArmCheckResult KeyVaultSecrets Passed "$($refs.Count) secret reference(s) resolve to existing secrets (values not read)."
}

$script:Checks['ArcMachinesConnected'] = {
    param($Ctx)
    foreach ($n in $Ctx.Nodes) {
        $m = Get-AzlArmArcMachineCached $Ctx $n
        $name = [string]$n['name']
        if (-not $m) { New-AzlArmCheckResult ArcMachinesConnected Failed "No Arc machine found for $name in $($Ctx.ResourceGroup)." 'Finish ZTP or Arc registration for the node, or fix nodes[].arc_machine_name.' -Node $name; continue }
        $problems = @()
        if ($m.Status -ne 'Connected') { $problems += "status is '$($m.Status)', not Connected" }
        if ($m.ResourceId -match '^/subscriptions/(?<s>[^/]+)/resourceGroups/(?<g>[^/]+)/') {
            if ($Matches.s -ne $Ctx.Subscription -or $Matches.g -ne $Ctx.ResourceGroup) { $problems += "the machine is in resource group $($Matches.g), not $($Ctx.ResourceGroup)" }
        }
        if ($problems) { New-AzlArmCheckResult ArcMachinesConnected Failed "Arc machine $($m.Name): $($problems -join '; ')." 'Wait for the agent to connect, restart the Azure Connected Machine agent, or register the node in the instance''s resource group.' -Node $name }
        else { New-AzlArmCheckResult ArcMachinesConnected Passed "Arc machine $($m.Name) is Connected." -Node $name }
    }
}

$script:Checks['ArcMachineNaming'] = {
    param($Ctx)
    $guid = '^[0-9a-f]{8}(-?[0-9a-f]{4}){3}-?[0-9a-f]{12}(-\d+)?$|^[0-9a-f]{16,}(-\d+)?$'
    foreach ($n in $Ctx.Nodes) {
        $m = Get-AzlArmArcMachineCached $Ctx $n
        $name = [string]$n['name']
        if (-not $m) { continue }
        $hostName = if ($m.ComputerName) { $m.ComputerName } else { $name }
        if ($m.Name -ieq $hostName -or $m.Name -ieq $name) { New-AzlArmCheckResult ArcMachineNaming Passed "Arc machine $($m.Name) is named after the host." -Node $name; continue }
        if ($m.Name -notmatch $guid) { New-AzlArmCheckResult ArcMachineNaming Warning "Arc machine $($m.Name) is not named after the host ($hostName). Check that nodes[].arc_machine_name is intended." -Node $name; continue }
        $issueId = 'arc-device-id-name'
        $knownBad = (-not $Ctx.Build) -or (@(ConvertTo-AzlArmArray $Ctx.DeviceIdIssue.affectedBuilds) | Where-Object { $Ctx.Build.StartsWith([string]$_) })
        $acknowledged = ($issueId -in $Ctx.Settings.acknowledgeKnownIssues) -or ('*' -in $Ctx.Settings.acknowledgeKnownIssues)
        $text = "Arc machine $($m.Name) is named by device ID, not after the host ($hostName). On build 2690 the Deploy step 0.41 (Arc infrastructure) looks the machine up by host name and fails with ParentResourceNotFound (known issue $issueId)."
        if ($Ctx.Phase -eq 'Deploy' -and $knownBad -and -not $acknowledged) {
            New-AzlArmCheckResult ArcMachineNaming Failed $text 'Do not Deploy yet. Wait for a fixed build, or install from the Microsoft image and register under the host name. To deploy anyway, set deployment.acknowledge_known_issues to arc-device-id-name.' -Node $name
        }
        else {
            New-AzlArmCheckResult ArcMachineNaming Warning ($text + $(if (-not $knownBad) { " Build $($Ctx.Build) is not one it was seen on." } elseif ($acknowledged) { ' Acknowledged.' } else { ' Validate does not reach that step.' })) 'Deploy will fail at that step on an affected build; see config/known-issues/arm-deployment.json.' -Node $name
        }
    }
}

$script:Checks['OsConfigurationConverged'] = {
    param($Ctx)
    $report = $Ctx.OsReport
    if (-not $report) {
        $level = if ($Ctx.Settings.requireOsConfigurationReport) { 'Failed' } else { 'Skipped' }
        return New-AzlArmCheckResult OsConfigurationConverged $level 'No OS configuration report was given (-OsConfigurationReport), so convergence of the nodes is not proven.' 'Run the OS configuration (Invoke-AzureLocalOsConfiguration.ps1 -Mode Apply) and pass its report directory.'
    }
    $reportCluster = [string](Get-AzlProp $report 'cluster' '')
    if ($reportCluster -and $reportCluster -ine $Ctx.Cluster) { return New-AzlArmCheckResult OsConfigurationConverged Failed "The OS configuration report is for cluster '$reportCluster', not '$($Ctx.Cluster)'." 'Pass the report of this cluster.' }
    $extra = ''
    $generated = [string](Get-AzlProp $report 'generatedUtc' '')
    if ($generated) {
        $at = [datetime]::MinValue
        if ([datetime]::TryParse($generated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$at) -and ((& $Ctx.Run.Adapter.Now) - $at).TotalHours -gt $Ctx.Settings.osReportMaxAgeHours) { $extra = " The report is older than $($Ctx.Settings.osReportMaxAgeHours) hours." }
    }
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $r = @(ConvertTo-AzlArmArray (Get-AzlProp $report 'nodes' @()) | Where-Object { ([string]$_.name) -ieq $name }) | Select-Object -First 1
        if (-not $r) { New-AzlArmCheckResult OsConfigurationConverged Failed "$name is not in the OS configuration report." 'Run the OS configuration for this node.' -Node $name; continue }
        $converged = Get-AzlProp $r 'converged' $null
        $changes = [int](Get-AzlProp $r 'planned.changes' -1)
        $blocked = [int](Get-AzlProp $r 'planned.blocked' 0)
        $errors = @(ConvertTo-AzlArmArray (Get-AzlProp $r 'errors' @()))
        $status = [string](Get-AzlProp $r 'status' '')
        if ($converged -eq $true -or ($changes -eq 0 -and $blocked -eq 0 -and $errors.Count -eq 0 -and $status -ne 'failed')) {
            New-AzlArmCheckResult OsConfigurationConverged $(if ($extra) { 'Warning' } else { 'Passed' }) "$name converged.$extra" -Node $name
        }
        else {
            $why = if ($errors.Count) { "error: $($errors[0])" } elseif ($changes -gt 0 -or $blocked -gt 0) { "$changes change(s) pending, $blocked blocked" } else { 'not converged' }
            New-AzlArmCheckResult OsConfigurationConverged Failed "$name has not converged ($why)." 'Run the OS configuration with -Mode Apply and read its report.' -Node $name
        }
    }
}

$script:Checks['OsBuildConsistent'] = {
    param($Ctx)
    $builds = [ordered]@{}
    foreach ($n in $Ctx.Nodes) {
        $name = [string]$n['name']
        $v = ''
        $m = Get-AzlArmArcMachineCached $Ctx $n
        if ($m -and $m.OsVersion) { $v = [string]$m.OsVersion }
        elseif ($Ctx.OsReport) {
            $r = @(ConvertTo-AzlArmArray (Get-AzlProp $Ctx.OsReport 'nodes' @()) | Where-Object { ([string]$_.name) -ieq $name }) | Select-Object -First 1
            if ($r) { $v = [string](Get-AzlProp $r 'osVersion' '') }
        }
        $builds[$name] = $v
    }
    $known = @($builds.Values | Where-Object { $_ })
    if ($known.Count -eq 0) { return New-AzlArmCheckResult OsBuildConsistent Skipped 'No node reports its OS build (the Arc machines have no osVersion yet and there is no OS report).' }
    if (@($known | Select-Object -Unique).Count -gt 1) { return New-AzlArmCheckResult OsBuildConsistent Failed ("The nodes run different OS builds: " + (($builds.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') + '.') 'Install the same build on every node (Microsoft requires the same exact version). The portal says "Unsupported OS version" for some mismatches.' }
    if ($known.Count -lt $builds.Count) { return New-AzlArmCheckResult OsBuildConsistent Warning "All nodes that report a build run $($known[0]); $($builds.Count - $known.Count) node(s) report none." }
    New-AzlArmCheckResult OsBuildConsistent Passed "Every node runs OS build $($known[0])$(if ($Ctx.Build) { "; the handoff's solution build is $($Ctx.Build)" })."
}

# The Solution Builder Extension is opt-in. These two checks run only against an SBE somebody configured; with none, the parameter
# set carries no SBE parameter (New-AzlArmParameterSet) and both are Passed with this note.
$script:NoSbeNote = 'No SBE configured (hardware.sbe has no version): deploying without a Solution Builder Extension. No SBE parameter is passed to the template.'

$script:Checks['SbeConsistent'] = {
    param($Ctx)
    if (-not $Ctx.Set.Parameters.Contains('sbeVersion') -or -not $Ctx.Set.Parameters['sbeVersion']) {
        return New-AzlArmCheckResult SbeConsistent Passed $script:NoSbeNote
    }
    if (-not $Ctx.Set.Parameters['sbeFamily']) {
        return New-AzlArmCheckResult SbeConsistent Warning "SBE version $($Ctx.Set.Parameters['sbeVersion']) is set without a family." 'Set hardware.sbe.family (the family of the SBE package, for example 16G-45n0c-Intel), or remove hardware.sbe.version to deploy without an SBE.'
    }
    New-AzlArmCheckResult SbeConsistent Passed "SBE $($Ctx.Set.Parameters['sbeFamily']) $($Ctx.Set.Parameters['sbeVersion']) is set."
}
$script:Checks['SbeValidatedWithSolution'] = {
    param($Ctx)
    $check = 'SbeValidatedWithSolution'
    $parameters = $Ctx.Set.Parameters
    $version = if ($parameters.Contains('sbeVersion')) { [string]$parameters['sbeVersion'] } else { '' }
    $family = if ($parameters.Contains('sbeFamily')) { [string]$parameters['sbeFamily'] } else { '' }
    if (-not $version) { return New-AzlArmCheckResult $check Passed $script:NoSbeNote }
    $source = Resolve-AzlArmSbeCatalogFile $Ctx
    if (-not $source.File) { return New-AzlArmCheckResult $check Skipped $source.Reason }
    try { $catalog = @(Read-AzlArmSbeCatalog -Path $source.File) }
    catch { return New-AzlArmCheckResult $check Warning "The SBE discovery catalog $($source.File) could not be read ($($_.Exception.Message)), so SBE $version was not compared with the solution version." 'Copy SBE_Discovery_*.xml again from the Dell download (hardware.sbe.bundle_path) or point the run setting sbeCatalogPath at a good copy.' }
    $solution = Resolve-AzlArmSolutionVersion $Ctx
    if (-not $solution.Version) {
        return New-AzlArmCheckResult $check Warning "The solution version could not be determined, so SBE $version was not compared with the catalog. $($solution.Source)" 'Set the run setting solutionVersion (deployment.solution_version), for example 12.2610.1004.50, to the solution version this deployment installs. Azure refuses an SBE that is not validated with it (ErrorUnvalidatedSolutionAndSbeCombination) only after 10 to 15 minutes of Validate.'
    }
    $shown = if ($solution.Derived) { "$($solution.Version).x" } else { $solution.Version }
    $how = if ($solution.Derived) { $solution.Source } else { "from $($solution.Source)" }
    $r = Test-AzlArmSbeSolution -Catalog $catalog -Family $family -Version $version -Solution $solution.Version
    $file = Split-Path -Leaf $source.File
    if ($r.Status -eq 'NotListed') {
        return New-AzlArmCheckResult $check Warning "SBE $version (family $family) is not listed in the catalog $file, so it was not compared with Solution $shown." "Use the SBE_Discovery_*.xml that came with the package (it lists the package), and check hardware.sbe.family ($family) and hardware.sbe.version ($version)."
    }
    if ($r.Status -eq 'Validated') {
        return New-AzlArmCheckResult $check Passed "SBE $version ($family) is validated with Solution $($r.MatchedPattern) in $file; this deployment uses $shown ($how)."
    }
    $patterns = Join-AzlArmList @($r.Entry.SolutionPatterns | ForEach-Object { $_.Pattern })
    $minimums = @($r.Entry.SolutionPatterns | Where-Object { $_.MinVersionRequired } | ForEach-Object { "$($_.Pattern) from $($_.MinVersionRequired)" })
    $evidence = "SBE $version is validated for Solution $patterns, this deployment uses $shown ($how)."
    if ($minimums.Count) { $evidence += " Minimum versions: $($minimums -join '; ')." }
    $evidence += " Catalog: $file. Azure would stop the Validate at step 0.60 (InvokeEnvironmentChecker) with ErrorUnvalidatedSolutionAndSbeCombination."
    if (@($r.ValidatedVersions).Count) {
        $best = @($r.ValidatedVersions)[0]
        $fix = "Use SBE $best (validated: $(@($r.ValidatedVersions) -join ', ') for family $family and Solution $shown): download it from Dell support, set hardware.sbe.version and hardware.sbe.bundle_path, run OS configuration to deliver it to C:\SBE."
    }
    else {
        $others = if (@($r.ValidatedElsewhere).Count) { " The catalog validates these SBEs with it: $(@($r.ValidatedElsewhere) -join ', ')." } else { '' }
        $fix = "No SBE of family $family in $file is validated with Solution $shown.$others Use an SBE of your hardware's family from a newer catalog, or install a solution version SBE $version is validated for ($patterns); then set hardware.sbe.family, hardware.sbe.version and bundle_path and run OS configuration."
    }
    New-AzlArmCheckResult $check Failed $evidence $fix
}

$script:Checks['DnsAndTime'] = {
    param($Ctx)
    $infra = $Ctx.Infra
    $problems = @(); $warnings = @(); $skipped = ''
    $dns = @(ConvertTo-AzlArmArray (Get-AzlProp $infra 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
    $useDhcp = [bool](Get-AzlProp $infra 'networking.management.use_dhcp' $false)
    if (-not $useDhcp) {
        if ($dns.Count -eq 0) { $problems += 'networking.management.dns_servers is empty' }
        foreach ($d in $dns) { $ip = $null; if (-not [System.Net.IPAddress]::TryParse($d, [ref]$ip)) { $problems += "DNS server '$d' is not an IP address" } }
    }
    $ntp = @(ConvertTo-AzlArmArray (Get-AzlProp $infra 'networking.ntp_servers' @()))
    if ($ntp.Count -eq 0) { $warnings += 'networking.ntp_servers is empty (the nodes use the domain or Azure time)' }
    if ($Ctx.OsReport) {
        foreach ($n in $Ctx.Nodes) {
            $name = [string]$n['name']
            $r = @(ConvertTo-AzlArmArray (Get-AzlProp $Ctx.OsReport 'nodes' @()) | Where-Object { ([string]$_.name) -ieq $name }) | Select-Object -First 1
            if (-not $r) { continue }
            foreach ($p in @(ConvertTo-AzlArmArray (Get-AzlProp $r 'plan' @()))) {
                if ([string](Get-AzlProp $p 'step' '') -in 'Dns', 'Time' -and [string](Get-AzlProp $p 'action' '') -in 'Change', 'Blocked') { $problems += "$name still has a pending $($p.step) change" }
            }
        }
    }
    $domain = [string](Get-AzlProp $infra 'identity.active_directory.domain_fqdn' '')
    if ($domain -and $dns.Count -and -not $Ctx.Offline -and (Test-AzlArmAdapterHas $Ctx.Run.Adapter ResolveDns)) {
        $answers = @($dns | ForEach-Object { Invoke-AzlArmAdapter $Ctx.Run.Adapter ResolveDns @($domain, $_) })
        $ok = @($answers | Where-Object { $_ -eq $true }).Count; $unknown = @($answers | Where-Object { $null -eq $_ }).Count
        if ($unknown -eq $answers.Count) { $skipped = ' The domain was not resolved (this host has no DNS probe).' }
        elseif ($ok -eq 0) { $warnings += "none of the DNS servers ($($dns -join ', ')) resolves $domain from this host (a runner outside the management network may not reach them; the nodes' own DNS is checked by the OS configuration)" }
    }
    elseif ($domain) { $skipped = ' The domain was not resolved (no DNS probe here).' }
    if ($problems) { return New-AzlArmCheckResult DnsAndTime Failed ($problems -join '; ') 'Fix networking.management.dns_servers, run the OS configuration (Dns and Time steps), and check the DNS records of the domain.' }
    if ($warnings) { return New-AzlArmCheckResult DnsAndTime Warning (($warnings -join '; ') + '.' + $skipped) }
    New-AzlArmCheckResult DnsAndTime Passed "DNS servers $($dns -join ', ') and NTP are set.$skipped"
}

$script:Checks['ActiveDirectoryPrepared'] = {
    param($Ctx)
    $ad = Get-AzlProp $Ctx.Infra 'identity.active_directory'
    $ou = [string](Get-AzlProp $ad 'ou_path' ''); $domain = [string](Get-AzlProp $ad 'domain_fqdn' ''); $lcm = [string](Get-AzlProp $ad 'lcm_user.username' '')
    $problems = @()
    if ($ou -and $ou -notmatch '(^|,)\s*OU=') { $problems += "ou_path '$ou' is the top of the domain; the OU can't be at the top level" }
    if ($lcm.Length -gt 20) { $problems += "the LCM user name is $($lcm.Length) characters; the limit is 20" }
    if ($problems) { return New-AzlArmCheckResult ActiveDirectoryPrepared Failed ($problems -join '; ') 'Fix identity.active_directory in infrastructure.yml.' }
    if (-not (Test-AzlArmAdapterHas $Ctx.Run.Adapter TestActiveDirectory)) { return New-AzlArmCheckResult ActiveDirectoryPrepared Skipped 'The file is consistent; the OU and the LCM user were not looked up (no Active Directory access here).' 'Run Invoke-AzStackHciExternalActiveDirectoryValidation from a domain-joined machine.' }
    $r = Invoke-AzlArmAdapter $Ctx.Run.Adapter TestActiveDirectory @($domain, $ou, $lcm)
    if ($null -eq $r) { return New-AzlArmCheckResult ActiveDirectoryPrepared Skipped 'The file is consistent; the OU and the LCM user were not looked up (this host has no ActiveDirectory module or is not domain-joined).' 'Run from a domain-joined host, or run Invoke-AzStackHciExternalActiveDirectoryValidation there.' }
    $missing = @()
    if (-not $r.OuExists) { $missing += "OU $ou" }
    if (-not $r.LcmUserExists) { $missing += "LCM user $lcm" }
    if ($missing) { return New-AzlArmCheckResult ActiveDirectoryPrepared Failed "Not found in $($domain): $($missing -join ', ')." 'Run Microsoft''s Active Directory preparation tool with these names, then check again.' }
    New-AzlArmCheckResult ActiveDirectoryPrepared Passed "OU $ou and LCM user $lcm exist in $domain."
}

$script:Checks['LocalIdentityPrerequisites'] = {
    param($Ctx)
    $zone = [string](Get-AzlProp $Ctx.Infra 'identity.local_identity.dns_zone' '')
    if (-not $zone) { return New-AzlArmCheckResult LocalIdentityPrerequisites Failed 'identity.local_identity.dns_zone is empty.' 'Set the DNS zone for the local identity deployment.' }
    New-AzlArmCheckResult LocalIdentityPrerequisites Passed "Local identity DNS zone $zone is set."
}

$script:Checks['NoLeftoverFailedDeployment'] = {
    param($Ctx)
    $s = $Ctx.State
    if (-not $s) { return New-AzlArmCheckResult NoLeftoverFailedDeployment Passed 'No cluster resource yet.' }
    $dep = ConvertTo-AzlArmStepStatus $s.DeploymentStatus
    $failed = ($s.ProvisioningState -eq 'Failed') -or $dep -eq 'error'
    if ($Ctx.Phase -eq 'Validate') {
        if ($dep -eq 'success') { return New-AzlArmCheckResult NoLeftoverFailedDeployment Failed 'The instance is already deployed.' 'Nothing to validate.' }
        if ($dep -eq 'running') { return New-AzlArmCheckResult NoLeftoverFailedDeployment Failed 'A deployment is running.' 'Wait for it, or run Mode Deploy to attach to it.' }
        if ($failed -and -not ($Ctx.Settings.allowRevalidate)) { return New-AzlArmCheckResult NoLeftoverFailedDeployment Failed "The instance is in a failed deployment state (provisioning $($s.ProvisioningState), deployment $($s.DeploymentStatus)). Microsoft: another Validate resets the system properties and can break license sync." 'Fix the cause and resume with Mode Deploy -Resume. -AllowRevalidate is for support-guided recovery only.' }
        return New-AzlArmCheckResult NoLeftoverFailedDeployment Passed 'The instance is not in a failed or running deployment.'
    }
    if ($dep -eq 'success') { return New-AzlArmCheckResult NoLeftoverFailedDeployment Passed 'The instance is already deployed; nothing to do.' }
    if ($dep -eq 'running') { return New-AzlArmCheckResult NoLeftoverFailedDeployment Warning 'A deployment is running; this run attaches to it.' }
    if ($failed) {
        if ($Ctx.Settings.resume) { return New-AzlArmCheckResult NoLeftoverFailedDeployment Warning 'The last deployment failed; this run resubmits it (resume).' }
        return New-AzlArmCheckResult NoLeftoverFailedDeployment Failed 'The last deployment failed.' 'Read the failing step and the known issue in the last report, fix the cause, then run Mode Deploy -Resume.'
    }
    New-AzlArmCheckResult NoLeftoverFailedDeployment Passed 'No failed deployment.'
}

$script:Checks['ValidatedBeforeDeploy'] = {
    param($Ctx)
    $s = $Ctx.State
    $val = if ($s) { ConvertTo-AzlArmStepStatus $s.ValidationStatus } else { 'notstarted' }
    $dep = if ($s) { ConvertTo-AzlArmStepStatus $s.DeploymentStatus } else { 'notstarted' }
    $resuming = $dep -in 'error', 'running', 'success'
    if ($val -ne 'success' -and -not $resuming) { return New-AzlArmCheckResult ValidatedBeforeDeploy Failed "No successful validation (validation status '$(if ($s) { $s.ValidationStatus } else { 'no cluster resource' })')." 'Run Mode Validate first and let it succeed.' }
    $arm = Invoke-AzlArmAdapter $Ctx.Run.Adapter GetArmDeployment @($Ctx.Subscription, $Ctx.ResourceGroup, $Ctx.ValidateName)
    if ($arm -and (ConvertTo-AzlArmStepStatus $arm.ProvisioningState) -eq 'success') { return New-AzlArmCheckResult ValidatedBeforeDeploy Passed "Validated with these parameters (deployment $($Ctx.ValidateName))." }
    if ($resuming) { return New-AzlArmCheckResult ValidatedBeforeDeploy Passed 'A deployment already started for this instance; validation is not required again.' }
    $level = if ($Ctx.Settings.requireValidatedParameterHash) { 'Failed' } else { 'Warning' }
    New-AzlArmCheckResult ValidatedBeforeDeploy $level "The instance validated, but not by this tool with these parameters (no ARM deployment $($Ctx.ValidateName)). The file may have changed since, or the validation ran in the portal." 'Run Mode Validate for these parameters, or accept that the validation was for the same settings.'
}

# name -> phases where it applies; nodeScope marks checks that report per node
$script:CheckOrder = @(
    @{ Name = 'AzureContext'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'ResourceGroup'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'ResourceProviders'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'Permissions'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'NamesAvailable'; Phases = , 'Validate'; Azure = $true }
    @{ Name = 'KeyVaultSecrets'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'ArcMachinesConnected'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'ArcMachineNaming'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'OsConfigurationConverged'; Phases = 'Validate', 'Deploy'; Azure = $false }
    @{ Name = 'OsBuildConsistent'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'SbeConsistent'; Phases = 'Validate', 'Deploy'; Azure = $false }
    @{ Name = 'SbeValidatedWithSolution'; Phases = 'Validate', 'Deploy'; Azure = $false }
    @{ Name = 'DnsAndTime'; Phases = 'Validate', 'Deploy'; Azure = $false }
    @{ Name = 'ActiveDirectoryPrepared'; Phases = 'Validate', 'Deploy'; Azure = $false; Identity = 'active_directory' }
    @{ Name = 'LocalIdentityPrerequisites'; Phases = 'Validate', 'Deploy'; Azure = $false; Identity = 'local_identity' }
    @{ Name = 'NoLeftoverFailedDeployment'; Phases = 'Validate', 'Deploy'; Azure = $true }
    @{ Name = 'ValidatedBeforeDeploy'; Phases = , 'Deploy'; Azure = $true }
)

function Get-AzlArmPreconditionName {
    <#
    .SYNOPSIS
        The names of the preconditions, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@($script:CheckOrder | ForEach-Object { $_.Name })
}

function Invoke-AzlArmPrecondition {
    <#
    .SYNOPSIS
        Runs the read-only preconditions for a phase (Validate or Deploy) and returns every result. Writes a PreconditionChecked
        event per result. A check that throws is Failed with the message; a check that needs a missing adapter member is Skipped.
    .PARAMETER Offline
        No Azure sign-in (Plan): the checks that read Azure are Skipped.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Phase, [switch]$Offline)
    $Context.Phase = $Phase
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($def in $script:CheckOrder) {
        if ($Phase -notin $def.Phases) { continue }
        if ($def.ContainsKey('Identity') -and [string](Get-AzlProp $Context.Infra 'scenario.identity' '') -ne $def.Identity) { continue }
        $partial = @()
        if ($def.Name -in $Run.Settings.skipPreconditions) { $partial = @(New-AzlArmCheckResult $def.Name Skipped 'Skipped on purpose (deployment.skip_preconditions).') }
        elseif ($Offline -and $def.Azure) { $partial = @(New-AzlArmCheckResult $def.Name Skipped 'Plan without an Azure sign-in reads files only.') }
        else {
            try { $partial = @(& $script:Checks[$def.Name] $Context) }
            catch [System.NotSupportedException] { $partial = @(New-AzlArmCheckResult $def.Name Skipped ($_.Exception.Message + ' This check was not run.')) }
            catch { $partial = @(New-AzlArmCheckResult $def.Name Failed "The check could not run: $($_.Exception.Message)") }
        }
        foreach ($r in $partial) {
            $results.Add($r)
            $level = switch ($r.Result) { 'Failed' { 'Error' } 'Warning' { 'Warning' } default { 'Info' } }
            Send-AzlArmEvent -Run $Run -State PreconditionChecked -Node $r.Node -Step $r.Name -Evidence $r.Evidence -Level $level -NextAction $r.NextAction -Data @{ name = $r.Name; result = $r.Result }
        }
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# Snapshots, polling, outcomes
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlArmSnapshotFresh {
    <#
    .SYNOPSIS
        $true when a step list belongs to the submission made at -Submitted. An earlier attempt's steps are still on the cluster
        resource when a new run starts. The latest step time must not be older than the submission (minus the clock skew
        allowed). With no step times, only a finished ARM deployment makes the snapshot count.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object[]]$Steps, [Parameter(Mandatory)][datetime]$Submitted, [Parameter(Mandatory)][bool]$ArmTerminal, [int]$SkewMinutes = 5)
    $latest = [datetime]::MinValue; $any = $false
    foreach ($s in @($Steps | Where-Object { $_ })) {
        foreach ($p in 'StartTime', 'EndTime') {
            $text = [string](Get-AzlProp $s $p '')
            $t = [datetime]::MinValue
            if ($text -and [datetime]::TryParse($text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$t)) { $any = $true; if ($t -gt $latest) { $latest = $t } }
        }
    }
    if (-not $any) { return $ArmTerminal }
    return $latest -ge $Submitted.ToUniversalTime().AddMinutes(-$SkewMinutes)
}

function Get-AzlArmPhaseOutcome {
    <#
    .SYNOPSIS
        What a snapshot (ARM deployment + cluster deploymentSettings) says about a phase: Running, Succeeded or Failed.
    .DESCRIPTION
        Validate succeeds when the named ARM deployment finished and the validation status is Succeeded for this submission.
        Deploy succeeds when the deployment status is Succeeded for this submission. A failed ARM deployment fails the phase;
        a failed status counts only when the snapshot belongs to this submission (see Test-AzlArmSnapshotFresh).
    .OUTPUTS
        Outcome, Reason, Steps, Status, ArmState, ArmError, Fresh.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Phase, [AllowNull()]$Arm, [AllowNull()]$State, [Parameter(Mandatory)][datetime]$Submitted, [int]$SkewMinutes = 5)
    $armState = if ($Arm) { ConvertTo-AzlArmStepStatus $Arm.ProvisioningState } else { 'notstarted' }
    $armTerminal = $armState -in 'success', 'error'
    $armError = if ($Arm) { [string]$Arm.Error } else { '' }
    $steps = @(); $raw = ''
    if ($State) {
        $steps = @(if ($Phase -eq 'Validate') { $State.ValidationSteps } else { $State.DeploymentSteps })
        $raw = [string]$(if ($Phase -eq 'Validate') { $State.ValidationStatus } else { $State.DeploymentStatus })
    }
    $status = ConvertTo-AzlArmStepStatus $raw
    $fresh = Test-AzlArmSnapshotFresh -Steps $steps -Submitted $Submitted -ArmTerminal $armTerminal -SkewMinutes $SkewMinutes
    $make = { param($o, $r) [pscustomobject]@{ Outcome = $o; Reason = $r; Steps = $steps; Status = $raw; ArmState = $armState; ArmError = $armError; Fresh = $fresh } }
    if ($armState -eq 'error') { return (& $make 'Failed' 'The ARM deployment failed.') }
    if ($fresh -and $status -eq 'error') { return (& $make 'Failed' "The $($Phase.ToLowerInvariant()) status is $raw.") }
    if ($fresh -and $status -eq 'success') {
        if ($Phase -eq 'Validate' -and -not $armTerminal -and $Arm) { return (& $make 'Running' 'Validation succeeded; the ARM deployment is still finishing.') }
        return (& $make 'Succeeded' "The $($Phase.ToLowerInvariant()) status is $raw.")
    }
    if ($Phase -eq 'Validate' -and $armState -eq 'success' -and $fresh -and $status -eq 'notstarted' -and -not $State) { return (& $make 'Running' 'The ARM deployment finished; the validation has not started on the cluster resource.') }
    return (& $make 'Running' 'Waiting.')
}

function Publish-AzlArmStepEvent {
    # One event per step whose status changed since the last poll (-Seen keeps the last status by step index).
    param($Run, [string]$Phase, [object[]]$Steps, [hashtable]$Seen)
    foreach ($s in @($Steps | Where-Object { $_ })) {
        $key = [string](Get-AzlProp $s 'FullStepIndex' $s.Name)
        $norm = ConvertTo-AzlArmStepStatus $s.Status
        if ($norm -eq 'notstarted') { continue }
        if ($Seen.ContainsKey($key) -and $Seen[$key] -eq $norm) { continue }
        $Seen[$key] = $norm
        $err = if (@($s.Errors).Count) { ' - ' + (@($s.Errors)[0]) } else { '' }
        Send-AzlArmEvent -Run $Run -State "${Phase}Step" -Step $key -Evidence "$($s.Name): $($s.Status)$err" -Level $(if ($norm -eq 'error') { 'Error' } else { 'Info' }) -Data @{ status = $norm; rawStatus = [string]$s.Status; stepName = [string]$s.Name; depth = [int]$s.Depth }
    }
}

function Wait-AzlArmPhase {
    <#
    .SYNOPSIS
        Polls the phase until it succeeds, fails or the time limit passes. Delay 15 s, times 1.5 each read, up to 120 s (the
        settings); a read that fails is retried, five in a row end the wait. The clock and the sleep come from the adapter.
    .OUTPUTS
        The Get-AzlArmPhaseOutcome object, with Outcome TimedOut when the limit passed, and Polls.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Phase, [Parameter(Mandatory)][string]$DeploymentName, [Parameter(Mandatory)][datetime]$Submitted, [Parameter(Mandatory)][int]$TimeoutMinutes)
    $a = $Run.Adapter; $set = $Run.Settings
    $start = & $a.Now
    $deadline = $start.AddMinutes($TimeoutMinutes)
    $delay = [double]$set.pollSeconds
    $seen = @{}; $consecutive = 0; $polls = 0
    $eventPhase = if ($Phase -eq 'Validate') { 'Validation' } else { 'Deployment' }
    while ($true) {
        $outcome = $null
        try {
            $arm = Invoke-AzlArmAdapter $a GetArmDeployment @($Run.Subscription, $Run.ResourceGroup, $DeploymentName)
            $state = Invoke-AzlArmAdapter $a GetDeploymentState @($Run.Subscription, $Run.ResourceGroup, $Run.Cluster)
            $polls++; $consecutive = 0
            $outcome = Get-AzlArmPhaseOutcome -Phase $Phase -Arm $arm -State $state -Submitted $Submitted -SkewMinutes $set.staleSkewMinutes
            Publish-AzlArmStepEvent -Run $Run -Phase $eventPhase -Steps $outcome.Steps -Seen $seen
        }
        catch {
            $consecutive++
            Send-AzlArmEvent -Run $Run -State PollError -Evidence "Reading the $($Phase.ToLowerInvariant()) status failed ($consecutive in a row): $($_.Exception.Message)" -Level Warning -Data @{ consecutive = $consecutive }
            if ($consecutive -ge $set.transientErrorLimit) {
                return [pscustomobject]@{ Outcome = 'Failed'; Reason = "Reading the status failed $consecutive times in a row: $($_.Exception.Message)"; Steps = @(); Status = ''; ArmState = ''; ArmError = ''; Fresh = $false; Polls = $polls }
            }
        }
        if ($outcome -and $outcome.Outcome -ne 'Running') { $outcome | Add-Member -NotePropertyName Polls -NotePropertyValue $polls -Force; return $outcome }
        $now = & $a.Now
        if ($now -ge $deadline) {
            $last = if ($outcome) { $outcome } else { [pscustomobject]@{ Steps = @(); Status = ''; ArmState = ''; ArmError = ''; Fresh = $false } }
            return [pscustomobject]@{ Outcome = 'TimedOut'; Reason = "Still running after $TimeoutMinutes minutes."; Steps = $last.Steps; Status = $last.Status; ArmState = $last.ArmState; ArmError = $last.ArmError; Fresh = $last.Fresh; Polls = $polls }
        }
        $remaining = ($deadline - $now).TotalSeconds
        & $a.Sleep ([math]::Min($delay, $remaining))
        $delay = [math]::Min([double]$set.pollMaxSeconds, $delay * $set.pollFactor)
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Idempotent decisions
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlArmValidateAction {
    <#
    .SYNOPSIS
        What a Validate run does about what Azure already holds: Submit, Skip (already validated with these parameters), Attach
        (our validation is running), or Refuse (with the reason). The table is section 7 of the design.
    #>
    [CmdletBinding()]
    param([AllowNull()]$State, [AllowNull()]$ArmValidate, [switch]$Revalidate)
    if (-not $State) { return [pscustomobject]@{ Kind = 'Submit'; Reason = 'No cluster resource yet.' } }
    $val = ConvertTo-AzlArmStepStatus $State.ValidationStatus
    $armOk = $ArmValidate -and (ConvertTo-AzlArmStepStatus $ArmValidate.ProvisioningState) -eq 'success'
    $armRunning = $ArmValidate -and (ConvertTo-AzlArmStepStatus $ArmValidate.ProvisioningState) -eq 'running'
    if ($armRunning -or ($val -eq 'running' -and $ArmValidate)) { return [pscustomobject]@{ Kind = 'Attach'; Reason = 'This validation is already running.' } }
    if ($val -eq 'running') { return [pscustomobject]@{ Kind = 'Refuse'; Reason = 'A validation is running that this run did not start (the portal, or other parameters).' } }
    if ($val -eq 'success' -and $armOk -and -not $Revalidate) { return [pscustomobject]@{ Kind = 'Skip'; Reason = 'Already validated with these parameters.' } }
    return [pscustomobject]@{ Kind = 'Submit'; Reason = $(if ($val -eq 'success') { 'Validated before with other parameters, or revalidate was asked for.' } else { 'Not validated yet.' }) }
}

function Resolve-AzlArmDeployAction {
    <#
    .SYNOPSIS
        What a Deploy run does: Submit, Attach (a deployment is running), Resubmit (a failed one, with resume), Done (already
        succeeded), or Refuse (with the reason, for example a failed deployment without resume).
    #>
    [CmdletBinding()]
    param([AllowNull()]$State, [switch]$Resume)
    if (-not $State) { return [pscustomobject]@{ Kind = 'Refuse'; Reason = 'No cluster resource: nothing was validated.' } }
    $val = ConvertTo-AzlArmStepStatus $State.ValidationStatus
    $dep = ConvertTo-AzlArmStepStatus $State.DeploymentStatus
    $failed = $dep -eq 'error' -or $State.ProvisioningState -eq 'Failed'
    if ($dep -eq 'success') { return [pscustomobject]@{ Kind = 'Done'; Reason = 'The instance is already deployed.' } }
    if ($dep -eq 'running') { return [pscustomobject]@{ Kind = 'Attach'; Reason = 'A deployment is running.' } }
    if ($failed) {
        if ($Resume) { return [pscustomobject]@{ Kind = 'Resubmit'; Reason = 'The last deployment failed; resubmitting it.' } }
        return [pscustomobject]@{ Kind = 'Refuse'; Reason = 'The last deployment failed. Fix the cause and run again with -Resume.' }
    }
    if ($val -ne 'success') { return [pscustomobject]@{ Kind = 'Refuse'; Reason = "No successful validation (status '$($State.ValidationStatus)')." } }
    return [pscustomobject]@{ Kind = 'Submit'; Reason = 'Validated; no deployment yet.' }
}

# ---------------------------------------------------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlArmNextAction {
    param($Issue, [string]$Default)
    if ($Issue -and @($Issue.Remediation).Count) { return "Known issue $($Issue.Id): " + (@($Issue.Remediation)[0]) }
    return $Default
}

function Invoke-AzlArmPhase {
    # One of Validate or Deploy against Azure (or its description, with -WhatIf). Returns $true when the phase succeeded.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Phase)
    $a = $Run.Adapter; $set = $Run.Settings
    $mode = $Phase
    $name = if ($Phase -eq 'Validate') { $Run.ValidateName } else { $Run.DeployName }
    $label = if ($Phase -eq 'Validate') { 'Validation' } else { 'Deployment' }
    $state = Invoke-AzlArmAdapter $a GetDeploymentState @($Run.Subscription, $Run.ResourceGroup, $Run.Cluster)
    $section = $Run.Report[$Phase.ToLowerInvariant()]
    $section.deploymentName = $name

    $action = if ($Phase -eq 'Validate') {
        Resolve-AzlArmValidateAction -State $state -ArmValidate (Invoke-AzlArmAdapter $a GetArmDeployment @($Run.Subscription, $Run.ResourceGroup, $name)) -Revalidate:$set.revalidate
    } else {
        Resolve-AzlArmDeployAction -State $state -Resume:$set.resume
    }
    $section.action = $action.Kind; $section.actionReason = $action.Reason

    # A failed Deploy with a known issue that says "do not retry" needs the operator to acknowledge it first.
    if ($Phase -eq 'Deploy' -and $action.Kind -eq 'Resubmit') {
        $failedBefore = Get-AzlArmFailedStep -Steps $state.DeploymentSteps | Select-Object -First 1
        if ($failedBefore) {
            $issue = Find-AzlArmKnownIssue -Phase Deploy -StepId $failedBefore.FullStepIndex -StepName $failedBefore.Name -ErrorText ($failedBefore.Errors -join ' ') -Build $Run.Build -Issues $Run.KnownIssues
            if ($issue -and $issue.Retry -eq 'none' -and $issue.Id -notin $set.acknowledgeKnownIssues -and '*' -notin $set.acknowledgeKnownIssues) {
                $Run.Report.knownIssue = $issue
                $section.status = 'Refused'
                $Run.Message = "The last failure (step $($failedBefore.FullStepIndex) $($failedBefore.Name)) is known issue $($issue.Id), which is not fixed by resubmitting. $($issue.Cause)"
                $Run.NextAction = (Get-AzlArmNextAction $issue 'Fix the cause first.') + " To resubmit anyway, set deployment.acknowledge_known_issues to $($issue.Id)."
                Send-AzlArmEvent -Run $Run -State PhaseRefused -Step $failedBefore.FullStepIndex -Evidence $Run.Message -Level Error -NextAction $Run.NextAction -Data @{ knownIssue = $issue.Id; phase = $Phase }
                return $false
            }
        }
    }

    switch ($action.Kind) {
        'Refuse' {
            $section.status = 'Refused'
            $Run.Message = "$label not started: $($action.Reason)"; $Run.NextAction = 'Resolve what is said above and run again.'
            Send-AzlArmEvent -Run $Run -State PhaseRefused -Evidence $Run.Message -Level Error -NextAction $Run.NextAction -Data @{ phase = $Phase }
            return $false
        }
        'Done' {
            Move-AzlArmRunState -Run $Run -To Resumed -Reason $action.Reason
            Send-AzlArmEvent -Run $Run -State DeploymentResumed -Evidence $action.Reason -Data @{ deploymentName = $name; previous = 'Succeeded' }
            Move-AzlArmRunState -Run $Run -To DeploymentSucceeded -Reason 'Nothing to do.'
            Send-AzlArmEvent -Run $Run -State DeploymentSucceeded -Evidence $action.Reason
            $section.status = 'Succeeded'
            return $true
        }
        'Skip' {
            Send-AzlArmEvent -Run $Run -State ValidationSkipped -Evidence $action.Reason -Data @{ deploymentName = $name }
            Move-AzlArmRunState -Run $Run -To ValidationPassed -Reason $action.Reason
            Send-AzlArmEvent -Run $Run -State ValidationPassed -Evidence $action.Reason -Data @{ skipped = $true }
            $section.status = 'Succeeded'
            return $true
        }
    }

    $submitted = & $a.Now
    if ($action.Kind -in 'Submit', 'Resubmit') {
        if ($Run.WhatIf) {
            $section.status = 'WhatIf'; $section.wouldSubmit = "Mode $mode as deployment $name"
            $Run.Message = "WhatIf: would submit $mode as deployment $name."
            return $true
        }
        if ($Phase -eq 'Validate') { Move-AzlArmRunState -Run $Run -To Validating -Reason $action.Reason }
        elseif ($action.Kind -eq 'Resubmit') {
            Move-AzlArmRunState -Run $Run -To Resumed -Reason $action.Reason
            Send-AzlArmEvent -Run $Run -State DeploymentResumed -Evidence "$($action.Reason) Resubmitted under the same name; the first step events show where Azure restarted." -Level Warning -Data @{ deploymentName = $name; previous = 'Failed' }
            Move-AzlArmRunState -Run $Run -To Deploying -Reason 'Resubmitted.'
        }
        else { Move-AzlArmRunState -Run $Run -To Deploying -Reason $action.Reason }
        $args2 = @{
            ParameterSet = $Run.ParameterSet; Template = $Run.Template; SubscriptionId = $Run.Subscription; ResourceGroup = $Run.ResourceGroup
            Mode = $mode; DeploymentName = $name
            # The resolver is called by the submit code, which is outside this module; a scriptblock keeps this module's scope, so it
            # reaches the run's adapter through the script variable (a closure would lose the module's private functions).
            SecretResolver = { param($Ref) $v = Invoke-AzlArmAdapter $script:RunAdapter GetSecret @($Ref); Register-AzlArmSecret $v; $v }
        }
        if ($set.deploymentSettingsApiVersion) { $args2.DeploymentSettingsApiVersion = $set.deploymentSettingsApiVersion }
        if ($Phase -eq 'Deploy' -and $action.Kind -eq 'Resubmit') { $args2.SkipValidationCheck = $true }
        if ($Phase -eq 'Validate' -and $set.allowRevalidate) { $args2.AllowRevalidate = $true }
        $null = Invoke-AzlArmAdapter $a Submit @($args2)
        Send-AzlArmEvent -Run $Run -State "${label}Submitted" -Evidence "Submitted $mode as deployment $name." -Data @{ deploymentName = $name }
    }
    else {
        # Attach: nothing is submitted.
        if ($Phase -eq 'Validate') { Move-AzlArmRunState -Run $Run -To Validating -Reason $action.Reason }
        else {
            Move-AzlArmRunState -Run $Run -To Resumed -Reason $action.Reason
            Send-AzlArmEvent -Run $Run -State DeploymentResumed -Evidence "$($action.Reason) Attached; nothing was submitted." -Data @{ deploymentName = $name; previous = 'InProgress' }
            Move-AzlArmRunState -Run $Run -To Deploying -Reason 'Attached.'
        }
        $arm = Invoke-AzlArmAdapter $a GetArmDeployment @($Run.Subscription, $Run.ResourceGroup, $name)
        $stamp = [datetime]::MinValue
        if ($arm -and $arm.Timestamp -and [datetime]::TryParse([string]$arm.Timestamp, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$stamp)) { $submitted = $stamp } else { $submitted = [datetime]::MinValue }
    }

    $limit = if ($Phase -eq 'Validate') { $set.validateTimeoutMinutes } else { $set.deployTimeoutMinutes }
    $outcome = Wait-AzlArmPhase -Run $Run -Phase $Phase -DeploymentName $name -Submitted $submitted -TimeoutMinutes $limit
    $section.status = $outcome.Outcome; $section.reportedStatus = $outcome.Status; $section.armState = $outcome.ArmState
    $section.polls = $outcome.Polls; $section.steps = @($outcome.Steps | ForEach-Object { [ordered]@{ step = $_.FullStepIndex; name = $_.Name; status = $_.Status; depth = $_.Depth } })
    if ($outcome.Outcome -eq 'Succeeded') {
        $section.failedSteps = @()
        if ($Phase -eq 'Validate') { Move-AzlArmRunState -Run $Run -To ValidationPassed -Reason $outcome.Reason; Send-AzlArmEvent -Run $Run -State ValidationPassed -Evidence 'Validation succeeded.' -Data @{ status = $outcome.Status } }
        else { Move-AzlArmRunState -Run $Run -To DeploymentSucceeded -Reason $outcome.Reason; Send-AzlArmEvent -Run $Run -State DeploymentSucceeded -Evidence 'Deployment succeeded.' -Data @{ status = $outcome.Status } }
        return $true
    }

    # Failed or timed out: the failing step, the text, the known issue.
    $failed = @(Get-AzlArmFailedStep -Steps $outcome.Steps)
    $primary = $failed | Select-Object -First 1
    $errorText = Hide-AzlArmSecret ((@($failed | ForEach-Object { $_.Errors }) + $outcome.ArmError + $outcome.Reason) -join ' ')
    $issue = $null
    if ($outcome.Outcome -ne 'TimedOut' -or $primary) {
        $issue = Find-AzlArmKnownIssue -Phase $Phase -StepId $(if ($primary) { $primary.FullStepIndex } else { '' }) -StepName $(if ($primary) { $primary.Name } else { '' }) -ErrorText $errorText -Build $Run.Build -Issues $Run.KnownIssues
    }
    $section.failedSteps = @($failed | ForEach-Object { [ordered]@{ step = $_.FullStepIndex; name = $_.Name; status = $_.Status; errors = @($_.Errors | ForEach-Object { Limit-AzlArmText $_ 800 }) } })
    $section.error = Limit-AzlArmText $errorText 1500
    $Run.Report.knownIssue = $issue
    $stepText = if ($primary) { "step $($primary.FullStepIndex) '$($primary.Name)'" } else { 'no step' }
    if ($outcome.Outcome -eq 'TimedOut') {
        $toState = if ($Phase -eq 'Validate') { 'ValidationTimedOut' } else { 'DeploymentTimedOut' }
        Move-AzlArmRunState -Run $Run -To $toState -Reason $outcome.Reason
        $Run.Message = "$label timed out after $limit minutes (Azure is still working; nothing was cancelled). Last failing step: $stepText."
        $Run.NextAction = "Run the same command again to attach to the running $($Phase.ToLowerInvariant())."
        Send-AzlArmEvent -Run $Run -State "${label}TimedOut" -Step $(if ($primary) { $primary.FullStepIndex } else { '' }) -Evidence $Run.Message -Level Error -NextAction $Run.NextAction
    }
    else {
        $toState = if ($Phase -eq 'Validate') { 'ValidationFailed' } else { 'DeploymentFailed' }
        Move-AzlArmRunState -Run $Run -To $toState -Reason $outcome.Reason
        $Run.Message = "$label failed at $stepText$(if ($errorText.Trim()) { ': ' + (Limit-AzlArmText $errorText 600) })"
        $Run.NextAction = Get-AzlArmNextAction $issue $(if ($Phase -eq 'Validate') { 'Fix the failing step and run again. The instance is not in a failed deployment state, so Validate can run again.' } else { 'Read the failing step. Do not run Validate again; fix the cause and run Mode Deploy -Resume.' })
        Send-AzlArmEvent -Run $Run -State "${label}Failed" -Step $(if ($primary) { $primary.FullStepIndex } else { '' }) -Evidence $Run.Message -Level Error -NextAction $Run.NextAction -Data @{ knownIssue = $(if ($issue) { $issue.Id } else { '' }); stepName = $(if ($primary) { $primary.Name } else { '' }); status = $outcome.Status }
    }
    return $false
}

function Request-AzlArmApproval {
    # The gate between Validate and Deploy. Returns Granted or Stopped.
    param([Parameter(Mandatory)]$Run)
    $mode = $Run.Settings.approvalMode
    Send-AzlArmEvent -Run $Run -State ApprovalRequested -Evidence "Validation passed for $($Run.Cluster). Approval mode: $mode." -Data @{ approvalMode = $mode }
    $result = 'Stopped'
    if ($mode -eq 'none') { $result = 'Granted' }
    elseif ($mode -eq 'prompt' -and (Test-AzlArmAdapterHas $Run.Adapter Prompt)) {
        $answer = Invoke-AzlArmAdapter $Run.Adapter Prompt @("Deploy $($Run.Cluster)?", "The validation passed. The deployment takes 2.5 to 3 hours. Deploy now?")
        if ($answer -eq $true) { $result = 'Granted' }
    }
    $Run.Report.approval = [ordered]@{ mode = $mode; result = $result }
    if ($result -eq 'Granted') { Send-AzlArmEvent -Run $Run -State ApprovalGranted -Evidence 'Approved.' -Data @{ approvalMode = $mode } }
    return $result
}

function Get-AzlArmExitCode {
    param([Parameter(Mandatory)][string]$StateName, [bool]$PreconditionsFailed, [bool]$Refused)
    if ($PreconditionsFailed -or $Refused) { return 1 }
    if ($StateName -in 'ValidationFailed', 'ValidationTimedOut', 'DeploymentFailed', 'DeploymentTimedOut') { return 1 }
    return 0
}

function Format-AzlArmSummary {
    # summary.md: for a person and for a pipeline's job summary.
    param([Parameter(Mandatory)]$Report)
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add("## Azure Local ARM deployment: $($Report.mode) of $($Report.cluster)"); $l.Add('')
    $l.Add("- **Result:** state $($Report.state), exit code $($Report.exitCode)")
    $l.Add("- **Template:** $($Report.template.name); parameter hash $($Report.parameterHash)")
    if ($Report.message) { $l.Add("- **Message:** $($Report.message)") }
    if ($Report.nextAction) { $l.Add("- **Next:** $($Report.nextAction)") }
    $l.Add('')
    if (@($Report.preconditions).Count) {
        $l.Add('### Preconditions'); $l.Add(''); $l.Add('| Check | Node | Result | Evidence |'); $l.Add('| --- | --- | --- | --- |')
        foreach ($p in $Report.preconditions) { $l.Add("| $($p.name) | $($p.node) | $($p.result) | $(($p.evidence -replace '\|', '/')) |") }
        $l.Add('')
    }
    foreach ($phase in 'validate', 'deploy') {
        $s = $Report[$phase]
        if (-not $s -or -not $s.status) { continue }
        $l.Add("### $($phase.Substring(0,1).ToUpperInvariant() + $phase.Substring(1))"); $l.Add('')
        $l.Add("- Deployment: ``$($s.deploymentName)``, action $($s.action), status $($s.status)")
        foreach ($f in @($s.failedSteps)) { $l.Add("- **Failed step $($f.step)** $($f.name): $(($f.errors -join ' | '))") }
        $l.Add('')
    }
    if ($Report.knownIssue) {
        $k = $Report.knownIssue
        $l.Add("### Known issue: $($k.Id)"); $l.Add(''); $l.Add($k.Title); $l.Add(''); $l.Add("Cause: $($k.Cause)"); $l.Add('')
        foreach ($r in @($k.Remediation)) { $l.Add("1. $r") }
        if ($k.BuildNote) { $l.Add(''); $l.Add($k.BuildNote) }
        $l.Add(''); $l.Add("Confidence: $($k.Confidence). $($k.Link)"); $l.Add('')
    }
    if (@($Report.warnings).Count) { $l.Add('### Warnings'); $l.Add(''); foreach ($w in $Report.warnings) { $l.Add("- $w") }; $l.Add('') }
    $l.Add('### State history'); $l.Add('')
    foreach ($h in $Report.stateHistory) { $l.Add("- $($h.at): $($h.from) -> $($h.to)$(if ($h.reason) { ' (' + $h.reason + ')' })") }
    return ($l -join [Environment]::NewLine)
}

function Invoke-AzlArmDeploymentRun {
    <#
    .SYNOPSIS
        The whole run: Plan, Validate, Deploy or ValidateAndDeploy. See docs/design/arm-validate-deploy.md.
    .PARAMETER Infrastructure
        The parsed master file (Import-AzlInfrastructure), instead of -InfrastructureFile.
    .PARAMETER OsConfigurationReport
        A path (report.json, a node-level report, or the report directory) or an already parsed report.
    .PARAMETER Settings
        Run settings (see Get-AzlArmRunSetting); they win over the master file's deployment block and -ConfigPath.
    .PARAMETER Adapter
        New-AzlArmAzureAdapter, or a table with the members a test replaces.
    .OUTPUTS
        ExitCode, State, Mode, Message, NextAction, ReportDirectory, ReportPath, EventPath, SummaryPath, Preconditions, KnownIssue.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'A plain -WhatIf switch: ShouldProcess would also stop the report and the event feed from being written.')]
    param(
        [string]$InfrastructureFile,
        [System.Collections.IDictionary]$Infrastructure,
        [string]$HandoffFile,
        [object]$OsConfigurationReport,
        [ValidateSet('Plan', 'Validate', 'Deploy', 'ValidateAndDeploy')][string]$Mode = 'Plan',
        [string]$ReportDirectory,
        [System.Collections.IDictionary]$Settings,
        [string]$ConfigPath,
        [string]$TemplateFile,
        [switch]$Resume,
        [switch]$AllowRevalidate,
        [switch]$AutoApprove,
        [switch]$ProbeOsConfiguration,
        # Plan only: do not read Azure at all (no Get-AzContext, no REST call), whoever is signed in. Files only.
        [switch]$Offline,
        # Reads and checks everything, says what it would submit, submits nothing. (A plain switch, not ShouldProcess: the
        # report and the event feed are still written.)
        [switch]$WhatIf,
        [System.Collections.IDictionary]$Adapter = (New-AzlArmAzureAdapter)
    )
    $script:SecretValues.Clear()
    $defaults = New-AzlArmAzureAdapter
    foreach ($k in $defaults.Keys) { if (-not $Adapter.Contains($k)) { $Adapter[$k] = $defaults[$k] } }
    $report = [ordered]@{
        schemaVersion = $script:ReportSchemaVersion; runId = [guid]::NewGuid().ToString('N').Substring(0, 12); generatedUtc = ''; mode = $Mode; cluster = ''
        infrastructure = $InfrastructureFile; template = [ordered]@{ name = ''; uri = '' }; deploymentSettingsApiVersion = ''; parameterHash = ''
        state = 'Start'; stateHistory = @(); exitCode = 0; message = ''; nextAction = ''; preconditions = @(); approval = $null
        validate = [ordered]@{ status = ''; deploymentName = ''; action = ''; actionReason = ''; failedSteps = @(); steps = @() }
        deploy = [ordered]@{ status = ''; deploymentName = ''; action = ''; actionReason = ''; failedSteps = @(); steps = @() }
        knownIssue = $null; warnings = @(); settings = $null
    }
    $run = [ordered]@{
        RunId = $report.runId; Mode = $Mode; Cluster = ''; SchemaVersion = ''; EventPath = ''; Adapter = $Adapter; Settings = $null; State = (New-AzlArmRunState)
        Report = $report; Message = ''; NextAction = ''; Subscription = ''; ResourceGroup = ''; Build = ''; KnownIssues = @(); ParameterSet = $null; Template = $null
        ValidateName = ''; DeployName = ''; WhatIf = [bool]$WhatIf
    }
    $exit = 0; $refused = $false; $preFailed = $false; $reportDir = ''
    try {
        # ---- 1 Prepare
        $infra = if ($Infrastructure) { $Infrastructure } elseif ($InfrastructureFile) {
            if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { Stop-AzlArmInput "Infrastructure file not found: $InfrastructureFile" }
            try { Import-AzlInfrastructure -Path $InfrastructureFile } catch { Stop-AzlArmInput "The master file is not valid: $($_.Exception.Message)" }
        } else { Stop-AzlArmInput 'Give -InfrastructureFile (or -Infrastructure).' }
        $cluster = [string](Get-AzlProp $infra 'cluster.name' '')
        if (-not $cluster) { Stop-AzlArmInput 'cluster.name is empty in infrastructure.yml.' }
        $run.Cluster = $cluster; $report.cluster = $cluster
        $run.SchemaVersion = [string](Get-AzlProp $infra '_metadata.schema_version' '')
        $run.Subscription = [string](Get-AzlProp $infra 'azure.subscription_id' ''); $run.ResourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')
        if (-not $run.Subscription -or -not $run.ResourceGroup) { Stop-AzlArmInput 'azure.subscription_id and azure.resource_group must be set in infrastructure.yml.' }
        $settingsOverride = [ordered]@{}
        if ($Settings) { foreach ($k in $Settings.Keys) { $settingsOverride[$k] = $Settings[$k] } }
        if ($Resume) { $settingsOverride['resume'] = $true }
        if ($AllowRevalidate) { $settingsOverride['allowRevalidate'] = $true }
        if ($AutoApprove) { $settingsOverride['approvalMode'] = 'none' }
        $run.Settings = Get-AzlArmRunSetting -Infrastructure $infra -ConfigPath $ConfigPath -Settings $settingsOverride
        $report.settings = $run.Settings
        $run.KnownIssues = if ($run.Settings.knownIssuesFile) { Get-AzlArmKnownIssue -Path $run.Settings.knownIssuesFile } else { Get-AzlArmKnownIssue }
        $deviceIdIssue = $run.KnownIssues | Where-Object { $_['id'] -eq 'arc-device-id-name' } | Select-Object -First 1
        $reportDir = if ($ReportDirectory) { $ReportDirectory } else { Join-Path ([IO.Path]::GetTempPath()) "azl-arm-$cluster" }
        $null = New-Item -ItemType Directory -Force -Path $reportDir
        $run.EventPath = Join-Path $reportDir 'arm-deployment-events.jsonl'
        $nodes = @(ConvertTo-AzlArmArray $infra['nodes'])
        Send-AzlArmEvent -Run $run -State RunStarted -Evidence "ARM deployment run: mode $Mode, $($nodes.Count) node(s)." -Data @{ nodes = @($nodes | ForEach-Object { [string]$_['name'] }); runMode = $Mode }
        Move-AzlArmRunState -Run $run -To Prepared -Reason 'Inputs read.'

        $handoff = if ($HandoffFile) { if (-not (Test-Path -LiteralPath $HandoffFile)) { Stop-AzlArmInput "Handoff file not found: $HandoffFile" }; Read-AzlHandoff -Path $HandoffFile } else { $null }
        $run.Build = if ($handoff) { [string]$handoff.VsrVersion } else { '' }
        $osReport = $null
        if ($OsConfigurationReport -is [string] -and $OsConfigurationReport) { $osReport = Read-AzlArmOsReport -Path $OsConfigurationReport }
        elseif ($OsConfigurationReport -and $OsConfigurationReport -isnot [string]) { $osReport = $OsConfigurationReport }
        elseif ($ProbeOsConfiguration -and (Test-AzlArmAdapterHas $Adapter ProbeOsConfiguration)) { $osReport = Invoke-AzlArmAdapter $Adapter ProbeOsConfiguration @($InfrastructureFile, $HandoffFile) }

        $script:RunAdapter = $Adapter
        try { $template = Select-AzlArmTemplate -Infrastructure $infra }
        catch { Stop-AzlArmInput "No template for this design: $($_.Exception.Message)" }
        $report.template = [ordered]@{ name = $template.Name; uri = $template.Uri }
        $keyProblems = @(Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName $template.Name)
        if ($keyProblems) { Stop-AzlArmInput ("$($keyProblems.Count) required value(s) are missing:`n" + ($keyProblems -join "`n")) }
        # Who is signed in decides whether the Azure checks can run; Plan without a sign-in reads files only.
        if ($Offline -and $Mode -ne 'Plan') { Stop-AzlArmInput '-Offline reads files only; it works with Mode Plan.' }
        $azureContext = if ($Offline -or -not (Test-AzlArmAdapterHas $Adapter GetContext)) { $null } else { & $Adapter.GetContext }
        $offline = (-not $azureContext)
        if ($offline -and $Mode -ne 'Plan') { Stop-AzlArmInput 'Nobody is signed in to Azure. Sign in first (Connect-AzAccount, or the pipeline''s OIDC or managed identity step); this run does not sign in itself.' }
        $arguments = @{ Infrastructure = $infra; Handoff = $handoff; Mode = 'Validate'; AllowUnresolvedSanLun = ($Mode -eq 'Plan') }
        if ($osReport) { $arguments.AdapterMap = Get-AzlAdapterMapFromReport -Report $osReport; $arguments.NodeReport = @($osReport.nodes) }
        if (-not $offline -and -not (Get-AzlProp $infra 'azure.hci_resource_provider_object_id') -and (Test-AzlArmAdapterHas $Adapter GetHciResourceProviderObjectId)) {
            $arguments.HciResourceProviderObjectId = [string](Invoke-AzlArmAdapter $Adapter GetHciResourceProviderObjectId)
        }
        try { $set = New-AzlArmParameterSet @arguments }
        catch { Stop-AzlArmInput "The parameters can't be generated: $($_.Exception.Message)" }
        $catalog = Get-AzlArmTemplateCatalog
        $problems = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $catalog.templates[$set.Template.Name].parameters)
        if ($offline) { $problems = @($problems | Where-Object { $_ -notmatch '^(infraVolLunId|infraPerfLunId|hciResourceProviderObjectID) ' }) }
        if ($problems) { Stop-AzlArmInput ("$($problems.Count) problem(s) in the parameter set:`n" + ($problems -join "`n")) }
        $run.ParameterSet = $set
        $hash = Get-AzlArmParameterHash -ParameterSet $set
        $run.ValidateName = "azl-validate-$hash"; $run.DeployName = "azl-deploy-$hash"
        $report.parameterHash = $hash; $report.deploymentSettingsApiVersion = $set.DeploymentSettingsApiVersion
        $report.warnings = @($set.Warnings)
        $parameterFile = Join-Path $reportDir "$cluster.parameters.json"
        ConvertTo-AzlArmParameterFile -ParameterSet $set -Infrastructure $infra | Set-Content -LiteralPath $parameterFile -Encoding utf8NoBOM
        Format-AzlArmParameterSource -ParameterSet $set | Set-Content -LiteralPath (Join-Path $reportDir 'parameter-sources.md') -Encoding utf8NoBOM
        Send-AzlArmEvent -Run $run -State ParametersGenerated -Evidence "$($set.Parameters.Count) parameters for template $($set.Template.Name); hash $hash." -Data @{ template = $set.Template.Name; parameterCount = $set.Parameters.Count; parameterHash = $hash; deploymentSettingsApiVersion = $set.DeploymentSettingsApiVersion }

        # ---- 2 Preconditions
        $context = [pscustomobject]@{
            Run = $run; Infra = $infra; Handoff = $handoff; OsReport = $osReport; Set = $set; Settings = $run.Settings; Subscription = $run.Subscription; ResourceGroup = $run.ResourceGroup
            Cluster = $cluster; Nodes = $nodes; Build = $run.Build; Phase = 'Validate'; ArcMachines = @{}; State = $null; AzureContext = $null; Offline = $offline; ValidateName = $run.ValidateName
            DeviceIdIssue = $(if ($deviceIdIssue) { [pscustomobject]$deviceIdIssue } else { [pscustomobject]@{ affectedBuilds = @() } })
        }
        $context.AzureContext = $azureContext
        if (-not $offline) { $context.State = Invoke-AzlArmAdapter $Adapter GetDeploymentState @($run.Subscription, $run.ResourceGroup, $cluster) }
        $pre = [System.Collections.Generic.List[object]]::new()
        $firstPhase = if ($Mode -eq 'Deploy') { 'Deploy' } else { 'Validate' }
        foreach ($r in (Invoke-AzlArmPrecondition -Run $run -Context $context -Phase $firstPhase -Offline:$offline)) { $pre.Add($r) }
        $report.preconditions = @($pre | ForEach-Object { [ordered]@{ name = $_.Name; node = $_.Node; result = $_.Result; evidence = (Limit-AzlArmText $_.Evidence 600); nextAction = (Limit-AzlArmText $_.NextAction 400) } })
        $failedChecks = @($pre | Where-Object { $_.Result -eq 'Failed' })
        $preFailed = $failedChecks.Count -gt 0
        if ($preFailed) {
            $run.Message = "$($failedChecks.Count) precondition(s) failed: " + ((@($failedChecks | Select-Object -ExpandProperty Name -Unique)) -join ', ') + '.'
            $run.NextAction = ($failedChecks | Select-Object -First 1).NextAction
        }

        if ($Mode -eq 'Plan' -or $preFailed) {
            Send-AzlArmEvent -Run $run -State PlanCompleted -Evidence $(if ($preFailed) { $run.Message } else { 'Plan complete: parameters generated, no precondition failed.' }) -Level $(if ($preFailed) { 'Error' } else { 'Info' }) -Data @{ failedPreconditions = $failedChecks.Count; offline = $offline }
            if (-not $preFailed) { $run.Message = "Plan complete. $($pre.Count) checks, none failed$(if ($offline) { ' (Azure was not read: nobody is signed in)' })."; $run.NextAction = 'Run Mode Validate.' }
        }
        else {
            # ---- template for the real submit
            if ($TemplateFile) {
                if (-not (Test-Path -LiteralPath $TemplateFile)) { Stop-AzlArmInput "Template file not found: $TemplateFile" }
                $run.Template = Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json -Depth 100
            }
            else { $run.Template = Invoke-AzlArmAdapter $Adapter GetTemplate @($set.Template.Uri) }

            # ---- 3 Validate
            $ok = $true
            if ($Mode -in 'Validate', 'ValidateAndDeploy') {
                $ok = Invoke-AzlArmPhase -Run $run -Phase Validate
                if ($ok -and $Mode -eq 'Validate' -and $report.validate.status -ne 'WhatIf') {
                    $run.Message = 'Validation succeeded.'; $run.NextAction = 'Review the report, then run Mode Deploy (in a pipeline: approve the Deploy job).'
                }
                elseif (-not $ok -and $report.validate.status -eq 'Refused') { $refused = $true }
            }
            # ---- 4 Approval, 5 Deploy
            if ($ok -and $Mode -eq 'ValidateAndDeploy' -and $report.validate.status -ne 'WhatIf') {
                $gate = Request-AzlArmApproval -Run $run
                if ($gate -eq 'Stopped') {
                    Move-AzlArmRunState -Run $run -To AwaitingApproval -Reason 'Approval mode does not continue by itself.'
                    $run.Message = 'Validation succeeded. Waiting for approval.'; $run.NextAction = 'Run Mode Deploy with the same files to deploy (the validation is not repeated).'
                    $ok = $false
                }
                else { Move-AzlArmRunState -Run $run -To AwaitingApproval -Reason 'Approved.' }
            }
            if ($ok -and $Mode -in 'Deploy', 'ValidateAndDeploy' -and $report.validate.status -ne 'WhatIf') {
                if ($Mode -eq 'ValidateAndDeploy') {
                    $context.State = Invoke-AzlArmAdapter $Adapter GetDeploymentState @($run.Subscription, $run.ResourceGroup, $cluster)
                    $second = @(Invoke-AzlArmPrecondition -Run $run -Context $context -Phase Deploy)
                    foreach ($r in $second) { $pre.Add($r) }
                    $report.preconditions = @($pre | ForEach-Object { [ordered]@{ name = $_.Name; node = $_.Node; result = $_.Result; evidence = (Limit-AzlArmText $_.Evidence 600); nextAction = (Limit-AzlArmText $_.NextAction 400) } })
                    $failed2 = @($second | Where-Object { $_.Result -eq 'Failed' })
                    if ($failed2.Count) { $preFailed = $true; $ok = $false; $run.Message = "$($failed2.Count) precondition(s) failed before the Deploy: " + ((@($failed2.Name | Select-Object -Unique)) -join ', ') + '.'; $run.NextAction = $failed2[0].NextAction }
                }
                if ($ok) {
                    $ok = Invoke-AzlArmPhase -Run $run -Phase Deploy
                    if ($ok -and $report.deploy.status -eq 'Succeeded') { $run.Message = 'Deployment succeeded.'; $run.NextAction = 'Run the post-deployment checks (Phase 06).' }
                    elseif (-not $ok -and $report.deploy.status -eq 'Refused') { $refused = $true }
                }
            }
            if ($WhatIf -and -not $run.Message) { $run.Message = 'WhatIf: nothing was submitted.' }
        }
        $exit = Get-AzlArmExitCode -StateName $run.State.Current -PreconditionsFailed $preFailed -Refused $refused
    }
    catch {
        $exit = if ($_.Exception.Data -and $_.Exception.Data.Contains('AzlExit')) { [int]$_.Exception.Data['AzlExit'] } else { 1 }
        $run.Message = Limit-AzlArmText $_.Exception.Message 4000
        $run.NextAction = if ($exit -eq 2) { 'Fix the input and run again.' } else { 'Read the message above; the event feed has the details.' }
        if ($run.EventPath) { Send-AzlArmEvent -Run $run -State RunFailed -Evidence $run.Message -Level Error -NextAction $run.NextAction }
    }

    # ---- 6 Report
    $report.generatedUtc = (& $Adapter.Now).ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture)
    $report.state = $run.State.Current; $report.stateHistory = @($run.State.History); $report.exitCode = $exit
    $report.message = Limit-AzlArmText $run.Message 4000; $report.nextAction = Limit-AzlArmText $run.NextAction 1000
    $reportPath = ''; $summaryPath = ''
    if ($reportDir) {
        $reportPath = Join-Path $reportDir 'report.json'
        $summaryPath = Join-Path $reportDir 'summary.md'
        (Hide-AzlArmSecret ($report | ConvertTo-Json -Depth 12)) | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
        if ($report.cluster) { (Hide-AzlArmSecret (Format-AzlArmSummary -Report $report)) | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM }
        Send-AzlArmEvent -Run $run -State RunCompleted -Evidence "Run finished in state $($run.State.Current), exit code $exit." -Level $(if ($exit -eq 0) { 'Info' } else { 'Error' }) -NextAction $report.nextAction -Data @{ exitCode = $exit; state = $run.State.Current }
    }
    [pscustomobject]@{
        ExitCode = $exit; State = $run.State.Current; Mode = $Mode; Message = $report.message; NextAction = $report.nextAction; ReportDirectory = $reportDir
        ReportPath = $reportPath; EventPath = $run.EventPath; SummaryPath = $summaryPath; Preconditions = @($report.preconditions); KnownIssue = $report.knownIssue; Report = $report
    }
}

            if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { return $null } # not on Linux: unknown, not false
Export-ModuleMember -Function Get-AzlArmRunSetting, Read-AzlArmSbeCatalog, Test-AzlArmSolutionVersionMatch, ConvertFrom-AzlArmOsBuild, Test-AzlArmSbeSolution, Write-AzlArmEvent, Test-AzlArmRunTransition, New-AzlArmRunState, Set-AzlArmRunState, Get-AzlArmFailedStep, Get-AzlArmKnownIssue, Find-AzlArmKnownIssue, Get-AzlArmParameterSource, Test-AzlArmRequiredKey, Format-AzlArmParameterSource, New-AzlArmAzureAdapter, Read-AzlArmOsReport, Get-AzlArmPreconditionName, Invoke-AzlArmPrecondition, Test-AzlArmSnapshotFresh, Get-AzlArmPhaseOutcome, Wait-AzlArmPhase, Resolve-AzlArmValidateAction, Resolve-AzlArmDeployAction, Get-AzlArmParameterHash, ConvertTo-AzlArmStepStatus, Hide-AzlArmSecret, Invoke-AzlArmDeploymentRun
