#Requires -Version 7.0
<#
.SYNOPSIS
    The engine of Invoke-AzureLocalPostDeployment.ps1: runs the tasks of phase 06 (post-deployment) of the Implementation guide as one sequence, or
    one task, or a range, from the step table PostDeploymentSteps.psd1.

.DESCRIPTION
    Every task script of the phase also runs alone, with only its own parameters. This module calls those scripts and nothing else: the public
    parameters -InfrastructureFile, -WhatIf, -Confirm:$false, -LogPath, -ComputerName and -Credential, each passed only when the script has it. No
    state, no file and no variable passes from one step to the next, so a script behaves the same alone and called from here, and each script checks
    its own preconditions from the file and from Azure and the cluster.

    What the engine decides, from the table and the infrastructure file:
      - which steps are selected (-Only, or -From and -To; default all, in the order of the guide's pages);
      - which selected steps apply: the conditions of the step (sdn.enabled, storage.volumes, ...) and operations.post_cluster.skip_steps. A step that
        does not apply is Skipped with the reason, never run;
      - whether the file carries the acknowledgement keys of an irreversible step (SDN enabled by Azure Arc cannot be undone): without them the run is
        refused before any step starts (exit code 2), in Plan mode too;
      - whether the cluster answers, once, through scripts/common/remoting/AzlClusterConnection.psm1 (the account is the deployment user of the
        file, its secret read through the toolkit's one secret resolver; never a prompt).
    Then it runs the steps one at a time. Plan mode passes -WhatIf to every step whose script has it (a step marked Plan = Run changes nothing and is run
    as it is). The run stops at the first step that fails, and after the first step that ended with warnings unless -ContinueOnWarning is given; the
    steps after it are NotRun. Nothing continues past a failed step.

    Outputs: <LogPath>/run.log, <LogPath>/<NN>-<step>.log (the log of each script), <LogPath>/report.json, <LogPath>/summary.md, and one event per
    state change in post-deployment-events.jsonl of the events folder (deployment.events_directory), in the envelope azurelocal-sonar reads. The events of
    the run are also copied to <LogPath>/post-deployment-events.jsonl, so a pipeline that publishes the log folder publishes the feed.

    Exit codes: 0 every selected step passed, was planned or was skipped; 1 a step failed; 2 bad input (the file, the table, an unknown step, a missing
    script), a refusal (an irreversible step without its acknowledgement keys) or a cluster that does not answer; 3 the run stopped after a step with warnings.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1')))
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'remoting', 'AzlClusterConnection.psm1')))

$script:DefaultRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$script:DefaultTable = [IO.Path]::Combine($script:DefaultRoot, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'PostDeploymentSteps.psd1')
$script:EventFeed = 'post-deployment-events.jsonl'
$script:StageName = 'PostDeployment'

function Get-AzlPostDeploymentStepTable {
    <#
    .SYNOPSIS
        Reads and checks the step table (PostDeploymentSteps.psd1). Returns the steps in order.
    .PARAMETER Path
        The table. Default: the table next to Invoke-AzureLocalPostDeployment.ps1.
    #>
    [CmdletBinding()]
    param([string]$Path = $script:DefaultTable)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The step table '$Path' is not there." }
    $table = Import-PowerShellDataFile -LiteralPath $Path
    if (-not $table.ContainsKey('Steps') -or @($table.Steps).Count -eq 0) { throw "The step table '$Path' lists no steps." }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($step in @($table.Steps)) {
        foreach ($field in 'Id', 'Task', 'Title', 'Script', 'Plan') { if (-not $step.ContainsKey($field) -or -not [string]$step[$field]) { throw "A step of '$Path' has no $field." } }
        if (-not $seen.Add([string]$step.Id)) { throw "The step id '$($step.Id)' is in the table twice." }
        if ([string]$step.Plan -notin 'WhatIf', 'Run') { throw "Step '$($step.Id)': Plan is '$($step.Plan)', not WhatIf or Run." }
    }
    return @($table.Steps)
}

function Get-PostDeploymentValue {
    param([System.Collections.IDictionary]$Infrastructure, [string]$Key)
    # a list stays one object (a function would unroll a list of one entry into the entry itself)
    $value = Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path $Key
    if ($null -eq $value) { return $null }
    return , $value
}

function Hide-PostDeploymentSecret([string]$Text) {
    # a task script prints no secret; this is the last guard before a line goes to the log, the report or the event feed
    return [regex]::Replace($Text, '(?i)\b(password|passwd|secret|token|access[_ ]?key|sas|connection ?string)\b(\s*[=:]\s*)\S+', '$1$2***')
}

function Test-PostDeploymentNotEmpty {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Count -gt 0 }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value).Count -gt 0 }
    return $true
}

function Test-AzlPostDeploymentCondition {
    <#
    .SYNOPSIS
        Evaluates one condition of the step table against the infrastructure file. Returns Met and, when it is not met, the Reason.
    .DESCRIPTION
        Key with Is (a boolean or a string, compared without regard to case; an absent key is not equal), IsNot (an absent key passes), NotEmpty,
        AnyItemHas (the key is a list of mappings and one of them has the named field set); or Keys with AnyNotEmpty (one of the keys is set).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Condition)
    $met = $false; $reason = ''
    if ($Condition.ContainsKey('AnyNotEmpty')) {
        $keys = @($Condition['Keys'])
        $met = @($keys | Where-Object { Test-PostDeploymentNotEmpty (Get-PostDeploymentValue $Infrastructure $_) }).Count -gt 0
        if (-not $met) { $reason = "none of $($keys -join ', ') is set" }
    }
    else {
        $key = [string]$Condition['Key']
        $value = Get-PostDeploymentValue $Infrastructure $key
        $shown = if ($null -eq $value) { 'absent' } elseif ($value -is [bool]) { $value.ToString().ToLowerInvariant() } elseif ($value -is [string]) { "'$value'" } else { 'set' }
        if ($Condition.ContainsKey('Is')) {
            $expected = $Condition['Is']
            if ($expected -is [bool]) {
                $actual = if ($value -is [bool]) { $value } elseif ($value -is [string] -and $value -in 'true', 'false') { [bool]::Parse($value) } else { $null }
                $met = ($null -ne $actual -and $actual -eq $expected)
                if (-not $met) { $reason = "$key is not $($expected.ToString().ToLowerInvariant()) (the file has it $shown)" }
            }
            else {
                $met = ($null -ne $value -and [string]$value -ieq [string]$expected)
                if (-not $met) { $reason = "$key is not '$expected' (the file has it $shown)" }
            }
        }
        elseif ($Condition.ContainsKey('IsNot')) {
            $met = -not ($null -ne $value -and [string]$value -ieq [string]$Condition['IsNot'])
            if (-not $met) { $reason = "$key is '$($Condition['IsNot'])'" }
        }
        elseif ($Condition.ContainsKey('NotEmpty')) {
            $met = Test-PostDeploymentNotEmpty $value
            if (-not $met) { $reason = "$key is empty or absent" }
        }
        elseif ($Condition.ContainsKey('AnyItemHas')) {
            $field = [string]$Condition['AnyItemHas']
            $items = if ($null -eq $value) { @() } elseif ($value -is [System.Collections.IDictionary]) { @() } else { @($value) }
            $met = @($items | Where-Object { $_ -is [System.Collections.IDictionary] -and ([System.Collections.IDictionary]$_).Contains($field) -and (Test-PostDeploymentNotEmpty $_[$field]) }).Count -gt 0
            if (-not $met) { $reason = "no entry of $key has $field" }
        }
        else { throw "A condition of the step table on '$key' has no operator (Is, IsNot, NotEmpty, AnyItemHas, AnyNotEmpty)." }
    }
    [pscustomobject]@{ Met = [bool]$met; Reason = $reason }
}

function Test-PostDeploymentAll {
    # All conditions of a list (each may carry a When: it counts only when the When holds). Returns the first reason that is not met, or ''.
    param([System.Collections.IDictionary]$Infrastructure, [object[]]$Conditions)
    foreach ($c in @($Conditions)) {
        if (-not $c) { continue }
        if ($c.ContainsKey('When') -and -not (Test-AzlPostDeploymentCondition -Infrastructure $Infrastructure -Condition $c.When).Met) { continue }
        $r = Test-AzlPostDeploymentCondition -Infrastructure $Infrastructure -Condition $c
        if (-not $r.Met) { return $r.Reason }
    }
    return ''
}

function Resolve-AzlPostDeploymentSelection {
    <#
    .SYNOPSIS
        The steps a run selects, in table order. -Only names steps (by id, or by task: task-05 selects every step of that task); -From and -To are
        inclusive and take a step id or a task. Throws on an unknown name, or on -Only together with -From or -To.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Steps, [string[]]$Only, [string]$From, [string]$To)
    $match = {
        param([string]$Name)
        $found = @(0..($Steps.Count - 1) | Where-Object {
                $s = $Steps[$_]
                [string]$s.Id -ieq $Name -or [string]$s.Task -ieq $Name -or ($Name -match '^task-\d\d$' -and ([string]$s.Task).StartsWith("$Name-", [StringComparison]::OrdinalIgnoreCase))
            })
        if ($found.Count -eq 0) { throw "'$Name' is not a step or a task of the post-deployment phase. Steps: $(@($Steps | ForEach-Object { $_.Id }) -join ', '). Tasks: $(@($Steps | ForEach-Object { $_.Task } | Select-Object -Unique) -join ', ')." }
        $found
    }
    $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Only -and ($From -or $To)) { throw '-Only cannot be combined with -From or -To.' }
    $indexes = if ($Only) { @($Only | ForEach-Object { & $match $_ }) }
    else {
        $first = if ($From) { [int](@(& $match $From) | Measure-Object -Minimum).Minimum } else { 0 }
        $last = if ($To) { [int](@(& $match $To) | Measure-Object -Maximum).Maximum } else { $Steps.Count - 1 }
        if ($first -gt $last) { throw "-From '$From' comes after -To '$To' in the guide's order." }
        @($first..$last)
    }
    $set = [System.Collections.Generic.HashSet[int]]::new([int[]]$indexes)
    return @(0..($Steps.Count - 1) | Where-Object { $set.Contains($_) } | ForEach-Object { $Steps[$_] })
}

function Invoke-AzlPostDeployment {
    <#
    .SYNOPSIS
        Runs the post-deployment tasks (phase 06) in the order of the guide, or one task, or a range. See the module description.
    .PARAMETER InfrastructureFile
        The master infrastructure.yml (schema 5).
    .PARAMETER LogPath
        The folder for the run log, the log of each step, report.json and summary.md. It is created. Keep it out of the repository.
    .PARAMETER Mode
        Plan (default): every step runs with -WhatIf and changes nothing. Apply: the steps make their changes.
    .PARAMETER From
        First step or task to run (inclusive). Default: the first.
    .PARAMETER To
        Last step or task to run (inclusive). Default: the last.
    .PARAMETER Only
        Run only these steps or tasks (task-05 is both storage steps).
    .PARAMETER ContinueOnWarning
        Keep going after a step that ended with warnings. Without it the run stops after the first such step (exit code 3).
    .PARAMETER Route
        PowerShell (default) or AzureCli: the Azure CLI twin of a step that has one (the other tab of its page); a step without one runs its PowerShell script.
    .PARAMETER ComputerName
        Passed to each step that takes it, and used for the connection check: the machine the cluster commands go to. Default: each script chooses as it does alone.
    .PARAMETER Credential
        Passed to each step that takes it, and used for the connection check. Default: the deployment user of the file, as each script does alone.
    .PARAMETER EventLogPath
        The event feed. Default: post-deployment-events.jsonl in the events folder (deployment.events_directory, else the default folder Sonar reads).
    .PARAMETER SkipClusterProbe
        Do not check that the cluster answers before the first step that connects to it.
    .PARAMETER SkipValidation
        Read the file without checking it against the schema.
    .PARAMETER RepositoryRoot
        The toolkit root the step scripts are relative to. Default: this toolkit.
    .PARAMETER StepTablePath
        The step table. Default: the one next to Invoke-AzureLocalPostDeployment.ps1.
    .PARAMETER RemoteCommand
        A script block { param([hashtable]$Call) Invoke-Command @Call } that replaces Invoke-Command in the connection check (a test hook).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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
        [switch]$SkipValidation,
        [string]$RepositoryRoot = $script:DefaultRoot,
        [string]$StepTablePath,
        [scriptblock]$RemoteCommand
    )
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $started = [datetime]::UtcNow
    $runLog = $null
    $feed = ''
    $cluster = ''
    $rows = [System.Collections.Generic.List[object]]::new()

    function Write-RunLine([string]$Text) {
        Write-Information -MessageData $Text -InformationAction Continue
        if ($runLog) { Add-Content -LiteralPath $runLog -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) }
    }
    function Send-Event([string]$State, [string]$Step = '', [string]$Evidence = '', [string]$Level = 'Info', [string]$NextAction = '', [hashtable]$Data) {
        $null = Write-AzlToolkitEvent -Path $feed -Stage $script:StageName -Step $Step -State $State -Evidence $Evidence -Level $Level -NextAction $NextAction -RunId $runId -Mode $Mode -Cluster $cluster -Data $Data
    }
    function Complete-Run([int]$Code, [string]$Why) {
        $report = [ordered]@{
            schemaVersion = 1; runId = $runId; mode = $Mode; route = $Route; cluster = $cluster
            infrastructureFile = (Split-Path -Leaf $InfrastructureFile)
            startedUtc = $started.ToString('o', [cultureinfo]::InvariantCulture); finishedUtc = [datetime]::UtcNow.ToString('o', [cultureinfo]::InvariantCulture)
            exitCode = $Code; result = $Why; steps = @($rows)
        }
        if ($runLog) {
            [IO.File]::WriteAllText([IO.Path]::Combine($LogPath, 'report.json'), (ConvertTo-Json -InputObject $report -Depth 6), [Text.UTF8Encoding]::new($false))
            $md = [System.Text.StringBuilder]::new()
            $null = $md.AppendLine("# Post-deployment ($Mode)").AppendLine().AppendLine("Run ``$runId``, cluster ``$cluster``. Exit code **$Code**: $Why").AppendLine()
            $null = $md.AppendLine('| # | Step | Task | Result | Exit | What it found |').AppendLine('| --- | --- | --- | --- | --- | --- |')
            foreach ($r in $rows) {
                $found = (($r.reason ? $r.reason : (@($r.warnings) + @($r.found) | Where-Object { $_ } | Select-Object -First 1)) -replace '\|', '/')
                $null = $md.AppendLine("| $($r.order) | $($r.id) | $($r.task) | $($r.result) | $(if ($null -eq $r.exitCode) { '' } else { $r.exitCode }) | $found |")
            }
            [IO.File]::WriteAllText([IO.Path]::Combine($LogPath, 'summary.md'), $md.ToString(), [Text.UTF8Encoding]::new($false))
        }
        Write-RunLine "Result: $Why (exit code $Code)."
        if ($rows.Count -gt 0) { Write-RunLine ((@($rows | ForEach-Object { [pscustomobject]@{ Step = $_.id; Result = $_.result; Exit = $_.exitCode; Reason = $_.reason } }) | Format-Table -AutoSize | Out-String).TrimEnd()) }
        Send-Event -State RunCompleted -Evidence $Why -Level $(if ($Code -eq 0) { 'Info' } else { 'Error' }) -Data @{ exitCode = $Code; result = $Why }
        # The events of THIS run are copied next to the report, so a pipeline (or a person) that keeps the log folder keeps the feed too. The feed itself stays in the
        # events folder, where azurelocal-sonar reads it.
        if ($runLog -and $feed -and (Test-Path -LiteralPath $feed -PathType Leaf)) {
            $copy = [IO.Path]::Combine($LogPath, $script:EventFeed)
            if ([IO.Path]::GetFullPath($copy) -ne [IO.Path]::GetFullPath($feed)) {
                try { Set-Content -LiteralPath $copy -Value @(Get-Content -LiteralPath $feed | Where-Object { $_ -like "*$runId*" }) -Encoding utf8 }
                catch { Write-RunLine "The events of this run could not be copied to '$copy': $($_.Exception.Message)" }
            }
        }
        [pscustomobject]@{ ExitCode = $Code; Result = $Why; RunId = $runId; Steps = @($rows); ReportPath = [IO.Path]::Combine($LogPath, 'report.json') }
    }

    # ---- inputs
    try {
        $null = New-Item -ItemType Directory -Force -Path $LogPath
        $runLog = [IO.Path]::Combine($LogPath, 'run.log')
    }
    catch { Write-Error "The log folder '$LogPath' cannot be created: $($_.Exception.Message)" -ErrorAction Continue; return [pscustomobject]@{ ExitCode = 2; Result = 'bad input'; RunId = $runId; Steps = @(); ReportPath = '' } }
    if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { Write-RunLine "The infrastructure file '$InfrastructureFile' was not found."; return Complete-Run 2 'the infrastructure file was not found' }
    try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation:$SkipValidation }
    catch { Write-RunLine "Cannot read the infrastructure file: $($_.Exception.Message)"; return Complete-Run 2 'the infrastructure file cannot be read or has errors' }
    $clusterValue = Get-PostDeploymentValue $infra 'cluster.name'
    $cluster = if ($clusterValue -is [string]) { $clusterValue } else { '' }
    $feed = if ($EventLogPath) { $EventLogPath } else { [IO.Path]::Combine((Resolve-AzlEventsDirectory -Infrastructure $infra -InfrastructureFile $InfrastructureFile), $script:EventFeed) }

    try {
        $steps = @(Get-AzlPostDeploymentStepTable -Path $(if ($StepTablePath) { $StepTablePath } else { [IO.Path]::Combine($RepositoryRoot, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'PostDeploymentSteps.psd1') }))
        $selected = @(Resolve-AzlPostDeploymentSelection -Steps $steps -Only $Only -From $From -To $To)
    }
    catch { Write-RunLine $_.Exception.Message; return Complete-Run 2 'bad input: the step table or the selection' }

    Send-Event -State RunStarted -Evidence "Post-deployment of cluster '$cluster' ($Mode, $(@($selected).Count) of $($steps.Count) steps selected)." -Data @{ route = $Route; selected = @($selected | ForEach-Object { $_.Id }) }
    $enabled = Get-PostDeploymentValue $infra 'operations.post_cluster.enabled'
    if ($enabled -is [bool] -and -not $enabled) { Write-RunLine 'operations.post_cluster.enabled is false: nothing to do.'; return Complete-Run 0 'operations.post_cluster.enabled is false: nothing was run' }
    $skipValue = Get-PostDeploymentValue $infra 'operations.post_cluster.skip_steps'
    $skipList = @($skipValue | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $unknown = @($skipList | Where-Object { $_ -notin @($steps | ForEach-Object { $_.Id }) })
    if ($unknown.Count -gt 0) { Write-RunLine "operations.post_cluster.skip_steps names unknown steps: $($unknown -join ', ')."; return Complete-Run 2 'operations.post_cluster.skip_steps names an unknown step' }

    # ---- decide every step
    $selectedIds = @($selected | ForEach-Object { $_.Id })
    $order = 0
    foreach ($step in $steps) {
        $order++
        $row = [ordered]@{ order = $order; id = [string]$step.Id; task = [string]$step.Task; title = [string]$step.Title; script = ''; result = 'Pending'; exitCode = $null; reason = ''; warnings = @(); found = @(); durationSeconds = 0 }
        if ($step.Id -notin $selectedIds) { $row.result = 'NotSelected'; $row.reason = 'not in the selection of this run' }
        elseif ($step.Id -in $skipList) { $row.result = 'Skipped'; $row.reason = 'operations.post_cluster.skip_steps lists it' }
        else {
            $why = Test-PostDeploymentAll -Infrastructure $infra -Conditions @($step['Applies'])
            if ($why) { $row.result = 'Skipped'; $row.reason = $why }
        }
        if ($row.result -eq 'Pending') {
            $relative = if ($Route -eq 'AzureCli' -and $step.ContainsKey('AzureCliScript')) { [string]$step.AzureCliScript } else { [string]$step.Script }
            $row.script = $relative
        }
        $rows.Add([pscustomobject]$row)
    }
    foreach ($r in @($rows | Where-Object { $_.result -eq 'Skipped' })) { Send-Event -State StepSkipped -Step $r.id -Evidence $r.reason }
    $pending = @($rows | Where-Object result -EQ 'Pending')

    # ---- every script is there (nothing starts when one is missing)
    $missing = @($pending | Where-Object { -not (Test-Path -LiteralPath ([IO.Path]::Combine($RepositoryRoot, $_.script)) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        foreach ($m in $missing) { Write-RunLine "Step '$($m.id)': the script '$($m.script)' is not there." }
        return Complete-Run 2 'a step script is missing'
    }

    # ---- the irreversible steps need their acknowledgements, in Plan mode too: nobody should be asked to approve a run that would be refused
    $refused = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $pending) {
        $step = @($steps | Where-Object { $_.Id -eq $r.id })[0]
        if (-not $step.ContainsKey('Irreversible') -or -not $step.Irreversible) { continue }
        $need = Test-PostDeploymentAll -Infrastructure $infra -Conditions @($step['Requires'])
        if ($need) { $refused.Add("Step '$($r.id)' cannot be undone and the file does not acknowledge it: $need. Set it only after the maintenance window is agreed.") }
    }
    if ($refused.Count -gt 0) {
        foreach ($line in $refused) { Write-RunLine $line }
        foreach ($r in @($pending | Where-Object { $refused -match "^Step '$($_.id)'" })) { $r.result = 'Refused'; $r.reason = 'its acknowledgement keys are missing'; Send-Event -State StepRefused -Step $r.id -Evidence $r.reason -Level Error -NextAction 'Set the acknowledgement keys of the step in infrastructure.yml.' }
        return Complete-Run 2 'refused: an irreversible step is not acknowledged in the file'
    }

    # ---- the cluster answers (once), through the shared connection module
    $needsCluster = @($pending | Where-Object { $id = $_.id; [bool](@($steps | Where-Object { $_.Id -eq $id })[0]['NeedsCluster']) })
    if ($needsCluster.Count -gt 0 -and -not $SkipClusterProbe) {
        try {
            $connectionArgs = @{ Infrastructure = $infra }
            if ($ComputerName) { $connectionArgs.ComputerName = $ComputerName }
            if ($Credential) { $connectionArgs.Credential = $Credential }
            if ($RemoteCommand) { $connectionArgs.RemoteCommand = $RemoteCommand }
            $connection = Resolve-AzlClusterConnection @connectionArgs
            $answer = Invoke-AzlClusterCommand -Connection $connection -ScriptBlock { [string]$env:COMPUTERNAME }
            Write-RunLine "The cluster answers: $($connection.Target) ($(@($answer)[0]))."
            Send-Event -State ClusterReachable -Evidence "The cluster answers on $($connection.Target)."
        }
        catch {
            Write-RunLine "The cluster does not answer: $($_.Exception.Message)"
            Send-Event -State ClusterUnreachable -Evidence $_.Exception.Message -Level Error -NextAction 'Check WinRM to the nodes and the deployment user of the file, then run again.'
            foreach ($r in $pending) { $r.result = 'NotRun'; $r.reason = 'the cluster does not answer' }
            return Complete-Run 2 'the cluster does not answer'
        }
    }

    # ---- run
    $final = 0; $finalWhy = if ($pending.Count -eq 0) { 'no step applies: nothing was run' } else { 'every selected step passed or was planned' }
    $stopped = $false
    $number = 0
    foreach ($r in $rows) {
        if ($r.result -ne 'Pending') { continue }
        $number++
        if ($stopped) { $r.result = 'NotRun'; $r.reason = 'an earlier step stopped the run'; Send-Event -State StepNotRun -Step $r.id -Evidence $r.reason; continue }
        $step = @($steps | Where-Object { $_.Id -eq $r.id })[0]
        $path = [IO.Path]::Combine($RepositoryRoot, $r.script)
        $command = Get-Command -Name $path -CommandType ExternalScript
        $arguments = @{ InfrastructureFile = $InfrastructureFile }
        if ($command.Parameters.ContainsKey('LogPath')) { $arguments.LogPath = [IO.Path]::Combine($LogPath, ('{0:00}-{1}.log' -f $r.order, $r.id)) }
        if ($ComputerName -and $command.Parameters.ContainsKey('ComputerName')) { $arguments.ComputerName = $ComputerName }
        if ($Credential -and $command.Parameters.ContainsKey('Credential')) { $arguments.Credential = $Credential }
        if ($command.Parameters.ContainsKey('Confirm')) { $arguments.Confirm = $false }
        $planned = ($Mode -eq 'Plan' -and [string]$step.Plan -eq 'WhatIf')
        if ($planned) { $arguments.WhatIf = $true }
        foreach ($extra in @($step['Arguments'])) {
            if (-not $extra) { continue }
            if ($extra.ContainsKey('When') -and -not (Test-AzlPostDeploymentCondition -Infrastructure $infra -Condition $extra.When).Met) { continue }
            if (-not $command.Parameters.ContainsKey([string]$extra.Name)) { continue }
            $arguments[[string]$extra.Name] = $true
        }
        Write-RunLine "---- Step $($r.order): $($r.id) ($($r.task)): $($step.Title)$(if ($planned) { ' [plan, -WhatIf]' })"
        Send-Event -State StepStarted -Step $r.id -Evidence "$($step.Title): $([IO.Path]::GetFileName($r.script))$(if ($planned) { ' with -WhatIf' })." -Data @{ task = $r.task }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $warnings = [System.Collections.Generic.List[string]]::new()
        $found = [System.Collections.Generic.List[string]]::new()
        $code = 0; $failure = ''
        $global:LASTEXITCODE = 0
        try {
            & $path @arguments *>&1 | ForEach-Object {
                $item = $_
                if ($item -is [System.Management.Automation.WarningRecord]) { $text = Hide-PostDeploymentSecret ([string]$item.Message); $warnings.Add($text); Write-Warning $text }
                elseif ($item -is [System.Management.Automation.ErrorRecord]) {
                    $text = Hide-PostDeploymentSecret "ERROR: $($item.Exception.Message)"; $found.Add($text); Write-RunLine $text
                    # an error the script reported and went on from is a warning of the step, so the run does not pass over it unseen
                    $warnings.Add($text)
                }
                elseif ($item -is [System.Management.Automation.InformationRecord]) { $text = Hide-PostDeploymentSecret ([string]$item.MessageData); $found.Add($text); Write-RunLine $text }
                elseif ($item -is [System.Management.Automation.VerboseRecord] -or $item -is [System.Management.Automation.DebugRecord]) { }
                elseif ($null -ne $item) { $found.Add((Hide-PostDeploymentSecret ([string]($item | Out-String)).Trim())) }
            }
            $code = [int]$global:LASTEXITCODE
        }
        catch { $failure = $_.Exception.Message; $code = 1; Write-RunLine "The script stopped with an error: $failure" }
        $watch.Stop()
        $r.exitCode = $code
        $r.durationSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        $r.warnings = @($warnings | Select-Object -First 20)
        $r.found = @($found | Where-Object { $_ } | Select-Object -First 60 | ForEach-Object { if ($_.Length -gt 600) { $_.Substring(0, 600) } else { $_ } })
        if ($code -eq 0) {
            if ($warnings.Count -gt 0) {
                $r.result = 'Warning'; $r.reason = "ended with $($warnings.Count) warning(s)"
                Send-Event -State StepWarning -Step $r.id -Evidence "$($r.reason): $($warnings[0])" -Level Warning -Data @{ exitCode = 0 }
                if (-not $ContinueOnWarning) { $stopped = $true; $final = 3; $finalWhy = "stopped after step '$($r.id)', which ended with warnings (-ContinueOnWarning goes on)" }
            }
            else {
                $r.result = if ($planned) { 'Planned' } else { 'Passed' }
                Send-Event -State $(if ($planned) { 'StepPlanned' } else { 'StepPassed' }) -Step $r.id -Evidence $(if ($found.Count) { [string]($found | Where-Object { $_ } | Select-Object -Last 1) } else { $step.Title }) -Data @{ exitCode = 0 }
            }
        }
        else {
            $r.result = if ($code -eq 2) { 'InputProblem' } else { 'Failed' }
            $firstError = ($found | Where-Object { $_ -like 'ERROR:*' } | Select-Object -First 1)
            $r.reason = if ($failure) { $failure } elseif ($code -eq 2) { 'exit code 2 (a value in the file is missing or not usable, or a precondition is not met; this step changed nothing)' + $(if ($firstError) { ': ' + $firstError } else { '' }) } else { "exit code $code" + $(if ($firstError) { ': ' + $firstError } else { '' }) }
            Send-Event -State StepFailed -Step $r.id -Evidence $r.reason -Level Error -NextAction "Read the log '$([IO.Path]::GetFileName([string]$arguments['LogPath']))', fix the cause, and run again with -From $($r.id)." -Data @{ exitCode = $code }
            $stopped = $true
            $final = if ($code -eq 2) { 2 } else { 1 }
            $finalWhy = "step '$($r.id)' failed (exit code $code); the steps after it were not run"
        }
    }
    return Complete-Run $final $finalWhy
}

Export-ModuleMember -Function Get-AzlPostDeploymentStepTable, Test-AzlPostDeploymentCondition, Resolve-AzlPostDeploymentSelection, Invoke-AzlPostDeployment
