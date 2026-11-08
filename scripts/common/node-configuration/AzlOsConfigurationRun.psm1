#Requires -Version 7.0
<#
.SYNOPSIS
    One OS configuration run for a whole Azure Local instance: every handoff, every node, one plan, one apply, one verification, one report.

.DESCRIPTION
    Invoke-AzureLocalOsConfiguration.ps1 is a thin entry point over Invoke-AzlOsConfiguration. The same function runs standalone and
    inside a pipeline; nothing here knows about a pipeline.

    The run, in order:
      1. Validate the inputs. The infrastructure file; the handoff files merged into one node -> handoff map (a node in two files is an
         error); the method per node (below); the transport; the Azure sign-in; for a machine installed from an ISO the route, the
         credentials and the OS build. Any failure here stops the run with exit code 2 before anything is changed.
      2. Plan for ALL nodes: Set-AzureLocalNodeConfiguration.ps1 once per node, read only. Writes plan-report.json. When
         os_configuration.clear_storage is on it prints exactly which disks on which node would be wiped.
      3. Apply (-Mode Apply), node by node. A node that fails does not stop the others unless -ContinueOnNodeFailure:$false.
      4. Verify: a Plan pass per node that was changed. A node is converged only when this pass finds nothing left to change; the
         status of the commands that did the work doesn't decide it.
      5. report.json (per node: method and evidence, steps, changes, errors, converged, restarted), summary.md, and the exit code.

    Which method? Per node, from the master file and from what is actually there (Resolve-AzlNodeMethod):
      declared   scenario.os_install: iso | simplified
      evidence   (a) a ZTP handoff for the node that says ready, (b) an Arc machine for it that is Connected, (c) the node answers
                 on WinRM at the address in the file.
      Ztp path   Arc Run Command (ARM only). Skips what ZTP guaranteed (OS build, Arc registration, the node's name, BIOS) and verifies
                 it; does the rest.
      Iso path   WinRM with identity.local_admin from a host that reaches the node. Also sets the computer name, checks the OS up
                 front, and registers the machine with Azure Arc.
    Both can be in one cluster. When the declaration and the evidence disagree the evidence wins and a warning names both; when
    there is no evidence the run stops with exit code 2.

    Exit codes: 0 all nodes converged (Plan mode: no node failed and nothing is blocked); 1 a node failed, is blocked or did not
    converge; 2 bad input or nothing reachable.

    Event feed: the run appends what it does, one JSON object per line, to <ReportDirectory>\os-configuration-events.jsonl
    (-EventLogPath overrides). The contract is in AzlOsConfigurationEvents.psm1. Writing it never fails the run.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'infrastructure' 'AzlInfrastructure.psm1'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path $PSScriptRoot 'AzlNodePayload.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeTransport.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeConfiguration.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlOsConfigurationEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlGuardedChange.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlRemoting.psm1')

$script:SetScript = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'deploy', '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1'))
# The order the steps run in (the same as AzlNodeConfiguration): Sbe is last, so a package that can't be delivered never stops the others.
$script:NodeSteps = @('RemoteManagement', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe')
$script:AllSteps = $script:NodeSteps + 'ArcRegistration'
# What ZTP already guaranteed (the computer name, Arc registration) is verified, not redone.
$script:ZtpSteps = @('RemoteManagement', 'Drivers', 'Network', 'Dns', 'Time', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe')
$script:IsoSteps = $script:AllSteps
# Shown by a viewer next to the master file's schema_version; raise it when the run's behaviour or the event feed changes.
$script:WrapperVersion = '1.0.0'
# The result format of the node payloads (the v of their answer); part of every event.
$script:PayloadVersion = '1'
# Azure Local OS 23H2 is build 25398; anything older cannot be an Azure Local node.
$script:MinimumBuild = 25398

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function Write-AzlLine([string]$Text) { Write-Information -MessageData $Text -InformationAction Continue }

function Get-AzlInputError([string]$Message) {
    $exception = [System.ArgumentException]::new($Message)
    $exception.Data['AzlInput'] = $true
    return $exception
}

# ---------------------------------------------------------------------------------------------------------------------
# The event feed (contract: AzlOsConfigurationEvents.psm1): what the run is doing, one line at a time, for a viewer to follow
# ---------------------------------------------------------------------------------------------------------------------

function Send-AzlRunEvent {
    <#
    .SYNOPSIS
        One event of this run: the standard fields from the context and the node record, appended to the feed. Never throws.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Context,
        [Parameter(Mandatory)][string]$State,
        [AllowNull()][System.Collections.IDictionary]$Record,
        [string]$Step = '',
        [string]$Evidence = '',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$NextAction = '',
        [System.Collections.IDictionary]$Data
    )
    try {
        if (-not $Context -or -not $Context.EventLogPath) { return }
        $node = '*'; $method = ''; $transport = ''
        if ($Record) {
            $node = [string]$Record['name']
            if ($Record.Contains('method') -and $Record['method']) { $method = [string]$Record['method'] }
            if ($Record.Contains('transport') -and $Record['transport']) { $transport = [string]$Record['transport'] }
        }
        $null = Write-AzlOsConfigurationEvent -Path $Context.EventLogPath -Node $node -State $State -Step $Step -Evidence $Evidence -Level $Level -NextAction $NextAction -Method $method -Transport $transport -PayloadVersion $script:PayloadVersion -SchemaVersion ([string](Get-AzlProp $Context 'SchemaVersion' '')) -Data $Data
    }
    catch { Write-Verbose "OS configuration event skipped: $($_.Exception.Message)" }
}

function Send-AzlRetryEvent {
    # NodeRetry: the Arc Run Command ended in state Unknown and is being tried again. $Retry is what ConvertFrom-AzlOsRetryWarning reads.
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [AllowNull()][System.Collections.IDictionary]$Record, [string]$Phase = '', [Parameter(Mandatory)][object]$Retry)
    Send-AzlRunEvent -Context $Context -Record $Record -State NodeRetry -Level Warning `
        -Evidence "The Arc Run Command ended in state Unknown (the node's agent may have lost its connection). Try $($Retry.Try) of $($Retry.Tries)$(if ($Phase) { " in the $Phase pass" }); trying again in $($Retry.WaitSeconds) s." `
        -NextAction 'Wait: the script is safe to run again and the next read decides what is done.' -Data @{ try = $Retry.Try; tries = $Retry.Tries; waitSeconds = $Retry.WaitSeconds; phase = $Phase }
}

function Get-AzlNodeVersionData {
    <#
    .SYNOPSIS
        The versions a viewer shows for a node: the master file's schema_version, this wrapper's version, the OS the node reports
        (hostname, osVersion, build, caption), and the SBE (publisher, family, version, package, delivery route). Empty values are left out.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [AllowNull()][System.Collections.IDictionary]$Record)
    $data = [ordered]@{ wrapperVersion = $script:WrapperVersion }
    if ($Context) {
        $schema = [string](Get-AzlProp $Context.Infra '_metadata.schema_version' '')
        if ($schema) { $data.schemaVersion = $schema }
        $sbe = Get-AzlProp $Context.Infra 'hardware.sbe'
        if ($sbe) {
            foreach ($pair in @(@('sbePublisher', 'publisher'), @('sbeFamily', 'family'), @('sbeVersion', 'version'))) {
                $v = [string](Get-AzlProp $sbe $pair[1] '')
                if ($v) { $data[$pair[0]] = $v }
            }
            # The route is the one the master file names (hardware.sbe.delivery); without one the package is not delivered (skip).
            $delivery = [string](Get-AzlProp $sbe 'delivery' '')
            if (-not $delivery -and (Get-AzlProp $sbe 'bundle_path' '')) { $delivery = 'skip' }
            if ($delivery) { $data.sbeDelivery = $delivery }
        }
    }
    if ($Record) {
        if ($Record.hostname) { $data.hostname = [string]$Record.hostname }
        if ($Record.osVersion) {
            $data.osVersion = [string]$Record.osVersion
            $build = [regex]::Match([string]$Record.osVersion, '10\.0\.(\d{4,6})')
            if ($build.Success) { $data.build = [int]$build.Groups[1].Value }
        }
        if ($Record.osCaption) { $data.osCaption = [string]$Record.osCaption }
        if ($Record.osBuild -and -not $data.Contains('build')) { $data.build = [int]$Record.osBuild }
        $package = @(@($Record.plan) | Where-Object { $_.Step -eq 'Sbe' -and "$($_.Item)" -match 'SBE_[^\\/]*\.zip$' } | ForEach-Object { ([string]$_.Item -split '[\\/]')[-1] } | Select-Object -First 1)
        if ($package.Count) { $data.sbePackage = $package[0] }
    }
    return $data
}

function Get-AzlMethodResolvedData {
    <#
    .SYNOPSIS
        The extra fields of MethodResolved: what the master file declares and what the evidence says (so a viewer can show a
        disagreement), the method's source, the steps, the evidence found, and the versions.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [System.Collections.IDictionary]$Record, [object]$Resolution)
    $declaredMethod = switch ([string]$Resolution.Declared) { 'simplified' { 'Ztp' } 'iso' { 'Iso' } default { '' } }
    $e = $Record.evidence
    $data = [ordered]@{
        declared       = [string]$Resolution.Declared
        declaredMethod = $declaredMethod
        source         = [string]$Resolution.Source
        mismatch       = [bool]($declaredMethod -and $Record.method -and $declaredMethod -ne $Record.method)
        steps          = @($Record.steps)
        handoff        = $(if ($e.HandoffPresent) { if ($e.HandoffReady) { 'ready' } else { 'not ready' } } else { 'none' })
        arc            = $(if ($e.ArcFound) { [string]$e.ArcStatus } else { 'none' })
        winrm          = $(if ($e.WinRmAnswers -eq $true) { 'answers' } elseif ($null -eq $e.WinRmAnswers) { 'not tried' } else { 'no answer' })
        warnings       = @($Resolution.Warnings)
    }
    foreach ($pair in (Get-AzlNodeVersionData -Context $Context -Record $Record).GetEnumerator()) { $data[$pair.Key] = $pair.Value }
    return $data
}

function Send-AzlStepPlanEvent {
    # StepPlanned for every step the node runs, StepSkipped for the ones it doesn't, from the plan of a Plan pass.
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [System.Collections.IDictionary]$Record)
    if (-not $Context -or -not $Context.EventLogPath) { return }
    $byStep = @{}
    foreach ($s in @(Get-AzlOsStepPlan -Plan @($Record.plan))) { $byStep[$s.Step] = $s }
    foreach ($step in (Get-AzlOsConfigurationStepOrder)) {
        if ($step -in @($Record.steps)) {
            if ($byStep.ContainsKey($step)) {
                $p = $byStep[$step]
                Send-AzlRunEvent -Context $Context -Record $Record -State StepPlanned -Step $step -Evidence "$($p.Action): $($p.Evidence)" -Level $(if ($p.Action -eq 'Blocked') { 'Warning' } else { 'Info' }) -Data @{ action = $p.Action; item = $p.Item; current = $p.Current; desired = $p.Desired }
            }
            else {
                $reason = switch ($step) {
                    { $_ -in 'Sbe', 'Drivers' } { if (-not (Get-AzlProp $Context.Infra 'hardware.sbe.bundle_path' '')) { 'hardware.sbe.bundle_path is not set in the master file, so the SBE and the OEM drivers are skipped.' } else { 'the script found nothing to check for this step on this node.' } }
                    'ClearStorage' { if (-not $Context.ClearStorage) { 'os_configuration.clear_storage is off, so no storage is wiped.' } else { 'the script found nothing to check for this step on this node.' } }
                    default { 'the script found nothing to check for this step on this node (for example no SAN is configured).' }
                }
                Send-AzlRunEvent -Context $Context -Record $Record -State StepSkipped -Step $step -Evidence "Not applicable: $reason"
            }
        }
        elseif ($Record.method -eq 'Ztp' -and $step -in 'Hostname', 'ArcRegistration') {
            # ZTP did these two; the run checks them and doesn't change them.
            $e = $Record.evidence
            if ($step -eq 'Hostname') {
                $wrong = $Record.hostname -and ($Record.hostname -ine $Record.name)
                $text = if ($wrong) { "Verify only: the node reports '$($Record.hostname)', the master file says '$($Record.name)'. ZTP names the machine, so it is not renamed here." } elseif ($Record.hostname) { "Verify only: the node reports '$($Record.hostname)'; ZTP set the computer name." } else { 'Verify only: ZTP set the computer name; the node did not report one.' }
                $action = if ($wrong) { 'Blocked' } else { 'Ok' }
            }
            else {
                $connected = [string]$e.ArcStatus -eq 'Connected'
                $text = "Verify only: handoff $(if ($e.HandoffPresent) { if ($e.HandoffReady) { 'ready' } else { 'not ready' } } else { 'not passed' }); Arc machine $(if ($e.ArcFound) { $e.ArcStatus } else { 'not found' }). ZTP registered the machine with Azure Arc."
                $action = if ($connected) { 'Ok' } else { 'Blocked' }
            }
            Send-AzlRunEvent -Context $Context -Record $Record -State StepPlanned -Step $step -Evidence "${action}: $text" -Level $(if ($action -eq 'Blocked') { 'Warning' } else { 'Info' }) -Data @{ action = $action; verifyOnly = $true; item = $step; current = ''; desired = '' }
        }
        elseif ($step -ne 'ArcRegistration' -or $Record.method -eq 'Iso') {
            Send-AzlRunEvent -Context $Context -Record $Record -State StepSkipped -Step $step -Evidence 'Not applicable: not selected with -Step.'
        }
    }
}

function Send-AzlStepApplyingEvent {
    # StepApplying for each step that has a change in the plan: the apply call is about to run them.
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [System.Collections.IDictionary]$Record, [switch]$ArcRegistration)
    if (-not $Context -or -not $Context.EventLogPath) { return }
    $want = $ArcRegistration.IsPresent
    foreach ($p in @(Get-AzlOsStepPlan -Plan @($Record.plan) | Where-Object { $_.Action -eq 'Change' -and (($_.Step -eq 'ArcRegistration') -eq $want) })) {
        Send-AzlRunEvent -Context $Context -Record $Record -State StepApplying -Step $p.Step -Evidence "Changing: $($p.Evidence)" -Data @{ item = $p.Item; current = $p.Current; desired = $p.Desired }
    }
}

function Send-AzlStepAppliedEvent {
    <#
    .SYNOPSIS
        StepApplied or StepFailed for the steps an apply call reports on. A change id is 'Step/detail'; a step with a failed change
        failed, a step whose changes all succeeded is applied. A step the call says nothing about is decided by the verification.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [System.Collections.IDictionary]$Record, [AllowEmptyCollection()][object[]]$Change = @())
    if (-not $Context -or -not $Context.EventLogPath) { return }
    $known = Get-AzlOsConfigurationStepOrder
    $grouped = @{}
    foreach ($c in @($Change)) {
        $step = (([string]$c.id) -split '[/:]')[0]
        if ($step -notin $known) { continue }
        if (-not $grouped.ContainsKey($step)) { $grouped[$step] = [System.Collections.Generic.List[object]]::new() }
        $grouped[$step].Add($c)
    }
    foreach ($step in $known) {
        if (-not $grouped.ContainsKey($step)) { continue }
        $list = @($grouped[$step])
        $failed = @($list | Where-Object { $_.status -eq 'failed' })
        if ($failed.Count) {
            Send-AzlRunEvent -Context $Context -Record $Record -State StepFailed -Step $step -Evidence "Failed: $(($failed | ForEach-Object { $_.detail }) -join '; ')" -Level Error -NextAction 'Fix the cause on the node and run the OS configuration again; the step is repeated.'
        }
        else {
            Send-AzlRunEvent -Context $Context -Record $Record -State StepApplied -Step $step -Evidence "Applied: $(($list | ForEach-Object { $_.detail }) -join '; ')"
        }
    }
}

function Send-AzlStepVerifiedEvent {
    # After the verification pass: StepVerified for every step that now matches, StepFailed for one that still differs.
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [System.Collections.IDictionary]$Record)
    if (-not $Context -or -not $Context.EventLogPath) { return }
    $byStep = @{}
    foreach ($s in @(Get-AzlOsStepPlan -Plan @($Record.plan))) { $byStep[$s.Step] = $s }
    foreach ($step in (Get-AzlOsConfigurationStepOrder)) {
        if (-not $byStep.ContainsKey($step)) { continue }
        $p = $byStep[$step]
        if ($p.Action -in 'Change', 'Blocked') {
            Send-AzlRunEvent -Context $Context -Record $Record -State StepFailed -Step $step -Evidence "Still differs after the apply: $($p.Evidence)" -Level Error -NextAction 'Fix what the evidence names and run the OS configuration again.' -Data @{ action = $p.Action; item = $p.Item; current = $p.Current; desired = $p.Desired }
        }
        else { Send-AzlRunEvent -Context $Context -Record $Record -State StepVerified -Step $step -Evidence "Verified: $($p.Evidence)" -Data @{ action = $p.Action } }
    }
}

function Send-AzlNodeOutcomeEvent {
    <#
    .SYNOPSIS
        The last word on a node, once: NodeConverged, NodeBlocked or NodeFailed, from its record. A node is not reported twice.
        In Plan mode a node that still has changes pending has no outcome yet.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Context, [System.Collections.IDictionary]$Record, [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan')
    if ($Record.outcomeSent) { return }
    $errors = @($Record.errors)
    $state = ''; $level = 'Info'; $text = ''; $next = ''
    if ($Record.converged) {
        $state = 'NodeConverged'
        $made = @($Record.changes | Where-Object { $_.status -eq 'changed' }).Count
        $text = if ($made) { "The verification pass found nothing left to change after $made change(s)$(if ($Record.restarted) { ' and a restart' })." } elseif ($Mode -eq 'Plan') { 'The node already matches the master file: nothing to change.' } else { 'Nothing to change.' }
    }
    elseif ($Record.status -eq 'skipped') {
        $state = 'NodeBlocked'; $level = 'Warning'; $text = $errors -join ' '; $next = 'Fix the node that failed and run the OS configuration again.'
    }
    elseif ($Record.status -eq 'failed') {
        $state = 'NodeFailed'; $level = 'Error'; $text = $errors -join ' '; $next = 'Read the error, fix the cause, and run the OS configuration again.'
    }
    elseif ($Mode -eq 'Plan') {
        if ($Record.blocked -gt 0 -or $errors.Count) {
            $state = 'NodeBlocked'; $level = 'Warning'; $next = 'Resolve what is blocked (see the StepPlanned lines), then run the OS configuration again.'
            $text = "$($Record.blocked) item(s) blocked$(if ($errors.Count) { '. ' + ($errors -join ' ') })"
        }
        else { return }
    }
    elseif ($Record.blocked -gt 0) {
        $state = 'NodeBlocked'; $level = 'Error'; $next = 'Resolve what is blocked, then run the OS configuration again.'
        $text = "$($Record.blocked) item(s) still blocked after the apply$(if ($errors.Count) { '. ' + ($errors -join ' ') })"
    }
    else {
        $state = 'NodeFailed'; $level = 'Error'; $next = 'Run the OS configuration again; the verification pass shows what is left.'
        $text = if ($errors.Count) { $errors -join ' ' } else { "Not converged: $($Record.pendingChanges) change(s) left after the apply." }
    }
    $Record.outcomeSent = $true
    Send-AzlRunEvent -Context $Context -Record $Record -State $state -Evidence $text -Level $level -NextAction $next
}

function Test-AzlAzureSignedIn {
    # Seam for tests: is there an Azure sign-in to call ARM with?
    if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) { return $false }
    try { return [bool](Get-AzContext) } catch { return $false }
}

function Test-AzlWinRmPort {
    # Seam for tests: does the address accept a TCP connection on the WinRM port?
    param([Parameter(Mandatory)][string]$Address, [int]$Port = 5985, [int]$TimeoutMilliseconds = 4000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync($Address, $Port)
        return ($connect.Wait($TimeoutMilliseconds) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-AzlArmToken {
    # Seam for tests: the ARM access token and account of the current Azure sign-in, for registering a machine with Arc.
    $context = Get-AzContext
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token
    if ($token -is [securestring]) { $token = $token | ConvertFrom-SecureString -AsPlainText }
    [pscustomobject]@{ Token = [string]$token; AccountId = [string](Get-AzlProp $context 'Account.Id' '') }
}

# ---------------------------------------------------------------------------------------------------------------------
# Handoffs
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlHandoffFile {
    <#
    .SYNOPSIS
        The handoff files named by -HandoffPath: a file, several files, or a directory (every *.ztp-handoff.json in it).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Path)
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Path | Where-Object { $_ })) {
        if (Test-Path -LiteralPath $entry -PathType Container) {
            $found = @(Get-ChildItem -LiteralPath $entry -Filter '*.ztp-handoff.json' -File | Sort-Object Name)
            if ($found.Count -eq 0) { throw (Get-AzlInputError "No *.ztp-handoff.json file in $entry.") }
            foreach ($f in $found) { $files.Add($f.FullName) }
        }
        elseif (Test-Path -LiteralPath $entry -PathType Leaf) { $files.Add((Resolve-Path -LiteralPath $entry).ProviderPath) }
        else { throw (Get-AzlInputError "Handoff path not found: $entry") }
    }
    return @($files | Select-Object -Unique)
}

function Merge-AzlHandoff {
    <#
    .SYNOPSIS
        Reads every handoff file and merges them into one node -> handoff map. A node name in two files is an error.
    .OUTPUTS
        Files, ByFile (file, handoff as Read-AzlHandoff returns it) and Map (lower-case node name -> File, Entry).
    #>
    [CmdletBinding()]
    param([string[]]$Path)
    $files = @(Get-AzlHandoffFile -Path $Path)
    $byFile = [System.Collections.Generic.List[object]]::new()
    $map = @{}
    foreach ($file in $files) {
        try { $handoff = Read-AzlHandoff -Path $file }
        catch { throw (Get-AzlInputError $_.Exception.Message) }
        $byFile.Add([pscustomobject]@{ File = $file; Handoff = $handoff })
        foreach ($key in @($handoff.Nodes.Keys)) {
            if ($map.ContainsKey($key)) {
                throw (Get-AzlInputError "Node '$key' is in two handoff files: $($map[$key].File) and $file. One node, one handoff: remove the older file or pass the right one.")
            }
            $map[$key] = [pscustomobject]@{ File = $file; Entry = $handoff.Nodes[$key] }
        }
    }
    [pscustomobject]@{ Files = $files; ByFile = $byFile.ToArray(); Map = $map }
}

function Find-AzlMergedHandoff {
    # A node's handoff (File, Handoff, Entry) from a merged set, matched by node name or Arc machine name. $null when none.
    param([object]$Merged, [Parameter(Mandatory)][string]$Name, [string]$ArcMachineName)
    if (-not $Merged) { return $null }
    foreach ($item in $Merged.ByFile) {
        $entry = Get-AzlHandoffNode -Handoff $item.Handoff -Name $Name -ArcMachineName $ArcMachineName
        if ($entry) { return [pscustomobject]@{ File = $item.File; Handoff = $item.Handoff; Entry = $entry } }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------------
# Which method?
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlNodeMethod {
    <#
    .SYNOPSIS
        Decides, for one node, whether it came from ZTP (simplified provisioning) or from an ISO install, and how to reach it.
    .DESCRIPTION
        Pure: it reads only the evidence object it is given (HandoffPresent, HandoffReady, HandoffNote, HandoffContradiction, ArcFound,
        ArcStatus, ArcError, WinRmAnswers, WinRmNote), so a test needs no node and no Azure.

        Auto rules:
          a ready handoff, or (declared simplified and an Arc machine that is Connected)     -> Ztp
              declared iso but a ready handoff exists: Ztp, with a warning naming both
          declared simplified, no ready handoff and no Connected Arc machine                 -> Iso if the node answers on WinRM,
              with a warning naming both; else an error (nothing reachable)
          declared iso (or not set)                                                          -> Iso; an error when the machine isn't
              a Connected Arc machine and doesn't answer on WinRM
          a handoff that names another subscription or resource group than the master file   -> an error (contradictory evidence)
        -Force Ztp needs a handoff or an Arc machine; -Force Iso is taken as given.
        Transport: WinRM for both paths. Arc Run Command only when the caller asks for it (-Transport ArcRunCommand); never a fallback.
    .OUTPUTS
        Node, Declared, Method (Ztp|Iso|$null), Source (declared|evidence|forced), Transport, Warnings, Errors, Evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Node,
        [string]$Declared,
        [Parameter(Mandatory)][object]$Evidence,
        [ValidateSet('Auto', 'Ztp', 'Iso')][string]$Force = 'Auto'
    )
    $e = $Evidence
    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $declaredText = if ($Declared) { $Declared } else { 'not set' }
    $arcConnected = [bool]$e.ArcFound -and [string]$e.ArcStatus -eq 'Connected'
    $handoffReady = [bool]$e.HandoffPresent -and [bool]$e.HandoffReady
    $winRm = $e.WinRmAnswers -eq $true
    $method = $null
    $source = 'declared'

    $notes = {
        $parts = @()
        $parts += if ($e.HandoffPresent) { "handoff present but $(if ($e.HandoffNote) { $e.HandoffNote } else { 'not ready' })" } else { 'no handoff' }
        $parts += if ($e.ArcFound) { "Arc machine is $($e.ArcStatus)" } elseif ($e.ArcError) { "Arc lookup failed ($($e.ArcError))" } else { 'no Arc machine' }
        $parts += if ($e.WinRmAnswers -eq $true) { 'answers on WinRM' } elseif ($e.WinRmNote) { $e.WinRmNote } else { 'no answer on WinRM' }
        $parts -join '; '
    }

    if ($e.HandoffContradiction) { $errors.Add("Contradictory evidence for ${Node}: $($e.HandoffContradiction)") }

    if (-not $errors.Count) {
        switch ($Force) {
            'Ztp' {
                if ($e.HandoffPresent -or $e.ArcFound) { $method = 'Ztp'; $source = 'forced' }
                else { $errors.Add("-Method Ztp was forced for $Node, but there is no handoff for it and no Arc machine. The ZTP path needs one of them.") }
            }
            'Iso' { $method = 'Iso'; $source = 'forced' }
            default {
                if ($handoffReady -or ($arcConnected -and $Declared -eq 'simplified')) {
                    $method = 'Ztp'
                    if ($Declared -eq 'iso') {
                        $source = 'evidence'
                        $warnings.Add("$Node is declared os_install 'iso' but a ready ZTP handoff exists for it, so the ZTP path is used. Fix scenario.os_install in the master file if it was provisioned by ZTP.")
                    }
                }
                elseif ($Declared -eq 'simplified') {
                    if ($winRm) {
                        $method = 'Iso'; $source = 'evidence'
                        $warnings.Add("$Node is declared os_install 'simplified' but there is no ready handoff and no Connected Arc machine ($(& $notes)). It answers on WinRM, so the ISO path is used. Check scenario.os_install.")
                    }
                    else { $errors.Add("$Node is declared os_install 'simplified', but there is no evidence of ZTP and nothing reachable: $(& $notes). Pass its handoff file (-HandoffPath), sign in to Azure so its Arc machine is found, or make the node reachable on WinRM.") }
                }
                else {
                    $method = 'Iso'
                    if (-not $arcConnected -and -not $winRm) {
                        $errors.Add("$Node is declared os_install '$declaredText' and nothing reaches it: $(& $notes). The ISO path opens a WinRM session to the address in the file (nodes[].management.ip_address or maintenance_address; -NodeAddress overrides): run from a host that reaches that subnet, or register the machine with Arc first.")
                    }
                }
            }
        }
    }

    # PowerShell remoting (WinRM) for both paths. Arc Run Command is never chosen here: only the caller's explicit -Transport ArcRunCommand (applied by the run) selects it.
    $transport = $null
    if ($method) { $transport = 'WinRM' }

    [pscustomobject]@{
        Node      = $Node
        Declared  = $declaredText
        Method    = $method
        Source    = $source
        Transport = $transport
        Warnings  = $warnings.ToArray()
        Errors    = $errors.ToArray()
        Evidence  = $e
    }
}

function Get-AzlNodeAddressCandidate {
    # The addresses a node may answer on, in the order they are tried: its management address in the file, its maintenance address.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][System.Collections.IDictionary]$Node, [hashtable]$Override)
    $name = [string]$Node['name']
    $list = [System.Collections.Generic.List[string]]::new()
    if ($Override -and $Override.ContainsKey($name) -and $Override[$name]) { $list.Add([string]$Override[$name]) }
    $adapter = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
    if ($adapter -and $adapter.IpAddress) { $list.Add([string]$adapter.IpAddress) }
    foreach ($candidate in @((Get-AzlProp $Node 'management.ip_address'), (Get-AzlProp $Node 'maintenance_address'))) {
        if ($candidate) { $list.Add([string]$candidate) }
    }
    return @($list | Select-Object -Unique)
}

function Get-AzlLocalAdminCredential {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password was just read from the Key Vault and only ever lives in memory; WinRM needs a PSCredential.')]
    <#
    .SYNOPSIS
        The nodes' local administrator as a credential: the one given, else identity.local_admin with its password read from the
        Key Vault. Never prints the password. Returns Credential (or $null), Source and Error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [pscredential]$Credential)
    if ($Credential) { return [pscustomobject]@{ Credential = $Credential; Source = 'parameter'; Error = '' } }
    $admin = Get-AzlProp $Infrastructure 'identity.local_admin'
    $user = [string](Get-AzlProp $admin 'username' '')
    $reference = [string](Get-AzlProp $admin 'password' '')
    if (-not $user -or -not $reference) { return [pscustomobject]@{ Credential = $null; Source = ''; Error = 'identity.local_admin has no username or password reference in the master file.' } }
    try {
        $secret = Get-AzlSecret -Reference $reference
        $secure = ConvertTo-SecureString -String $secret -AsPlainText -Force
        return [pscustomobject]@{ Credential = [pscredential]::new($user, $secure); Source = "vault ($reference)"; Error = '' }
    }
    catch { return [pscustomobject]@{ Credential = $null; Source = ''; Error = "Can't read the local administrator's password ($reference): $($_.Exception.Message)" } }
}

function Get-AzlNodeEvidence {
    <#
    .SYNOPSIS
        Looks for the evidence Resolve-AzlNodeMethod needs for one node: its handoff, its Arc machine, whether it answers on WinRM.
        Reads only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $infra = $Context.Infra
    $name = [string]$Node['name']
    $arcName = Get-AzlArcMachineName -Node $Node
    $found = Find-AzlMergedHandoff -Merged $Context.Handoff -Name $name -ArcMachineName $arcName
    $entry = if ($found) { $found.Entry } else { $null }
    $subscription = [string](Get-AzlProp $infra 'azure.subscription_id' '')
    $resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')

    $ready = $false; $handoffNote = ''; $contradiction = ''
    if ($entry) {
        $ready = [bool](Get-AzlProp $entry 'ready' $false)
        if (-not $ready) { $handoffNote = 'ready is false' }
        $hSub = [string](Get-AzlProp $found.Handoff 'SubscriptionId' '')
        $hRg = [string](Get-AzlProp $found.Handoff 'ResourceGroup' '')
        if ($hSub -and $subscription -and $hSub -ne $subscription) { $contradiction = "the handoff ($(Split-Path -Leaf $found.File)) is for another subscription than azure.subscription_id in the master file." }
        elseif ($hRg -and $resourceGroup -and $hRg -ine $resourceGroup) { $contradiction = "the handoff ($(Split-Path -Leaf $found.File)) is for resource group '$hRg', the master file says azure.resource_group '$resourceGroup'." }
    }

    $arc = $null; $arcError = ''
    if ($Context.AzureSignedIn) {
        try {
            $resourceId = if ($entry) { [string](Get-AzlProp $entry 'arcMachineResourceId' '') } else { '' }
            $arc = Find-AzlArcMachine -ArcMachineName $arcName -SubscriptionId $subscription -ResourceGroup $resourceGroup -ResourceId $resourceId -HostName $name
        }
        catch { $arcError = $_.Exception.Message }
    }
    else { $arcError = 'not signed in to Azure' }

    # Does it answer on WinRM? Only worth asking when the other evidence is missing.
    $addresses = @(Get-AzlNodeAddressCandidate -Infrastructure $infra -Node $Node -Override $Context.NodeAddress)
    if ($arc) { $addresses = @($addresses + @(Get-AzlNodeRemotingAddress -Node $Node -ManagementMac ([string](Get-AzlProp (Get-AzlManagementAdapter -Infrastructure $infra -Node $Node) 'MacAddress' '')) -ArcMachine $arc) | Select-Object -Unique) }
    $winRm = $null; $winRmAddress = ''; $winRmNote = ''
    if ((Get-AzlProp $Context 'TransportRequested' 'Auto') -ne 'ArcRunCommand') {
        if ($addresses.Count -eq 0) { $winRm = $false; $winRmNote = 'no management address in the file to try' }
        else {
            $winRm = $false
            foreach ($address in $addresses) {
                if (Test-AzlWinRmPort -Address $address) { $winRm = $true; $winRmAddress = $address; break }
            }
            if (-not $winRm) { $winRmNote = "no answer on TCP 5985 at $($addresses -join ', ')" }
        }
    }
    [pscustomobject]@{
        HandoffPresent       = [bool]$entry
        HandoffReady         = $ready
        HandoffNote          = $handoffNote
        HandoffFile          = $(if ($found) { $found.File } else { '' })
        HandoffContradiction = $contradiction
        ArcFound             = [bool]$arc
        ArcStatus            = $(if ($arc) { [string]$arc.Status } else { '' })
        ArcResourceId        = $(if ($arc) { [string]$arc.ResourceId } else { '' })
        ArcError             = $arcError
        WinRmAnswers         = $winRm
        WinRmAddress         = $winRmAddress
        WinRmNote            = $winRmNote
        Addresses            = $addresses
    }
}

function Get-AzlNodeStepList {
    <#
    .SYNOPSIS
        The steps that run on a node: those of its method, limited by -Step. Hostname and Arc registration are ISO-path steps.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Ztp', 'Iso')][string]$Method, [string[]]$Step)
    $list = if ($Method -eq 'Ztp') { $script:ZtpSteps } else { $script:IsoSteps }
    if ($Step) { $list = @($list | Where-Object { $_ -in $Step }) }
    return @($list)
}

# ---------------------------------------------------------------------------------------------------------------------
# Run settings
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlRunSetting {
    <#
    .SYNOPSIS
        Optional run settings: from a JSON file (-ConfigPath), over which a hashtable (-Settings) wins. Keys: retryTries,
        retryDelaySeconds, maxPasses, noRestart, failOnPendingChanges, nodeAddress, networkRollbackMinutes (the confirmation window, 10),
        networkStableSeconds (60), reconnectWaitMinutes (15), staleRunCommandMinutes (15), addressProbe (true), remoting (a hashtable: transport,
        bootstrapTransport, allowedSourceCidrs, useSsl, authentication).
    #>
    [CmdletBinding()]
    param([string]$ConfigPath, [hashtable]$Settings)
    $result = @{}
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw (Get-AzlInputError "Settings file not found: $ConfigPath") }
        try { $file = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable } catch { throw (Get-AzlInputError "Settings file $ConfigPath isn't valid JSON: $($_.Exception.Message)") }
        foreach ($k in $file.Keys) { $result[$k] = $file[$k] }
    }
    if ($Settings) { foreach ($k in $Settings.Keys) { $result[$k] = $Settings[$k] } }
    $known = @('retryTries', 'retryDelaySeconds', 'maxPasses', 'noRestart', 'failOnPendingChanges', 'nodeAddress', 'networkRollbackMinutes', 'networkStableSeconds', 'reconnectWaitMinutes', 'staleRunCommandMinutes', 'addressProbe', 'remoting')
    foreach ($k in $result.Keys) { if ($k -notin $known) { throw (Get-AzlInputError "Unknown run setting '$k'. Known: $($known -join ', ').") } }
    try { $null = Get-AzlGuardSetting -Setting $result; $null = Get-AzlRemotingSetting -Setting $result } catch { throw (Get-AzlInputError $_.Exception.Message) }
    return $result
}

# ---------------------------------------------------------------------------------------------------------------------
# One call of the OS configuration script, for one node
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlSetNodeConfiguration {
    <#
    .SYNOPSIS
        Runs Set-AzureLocalNodeConfiguration.ps1 with these parameters and reads back the report it wrote. The one place the script is
        called, so a test replaces it.
    .OUTPUTS
        ExitCode, Error, Unknown ($true when the error was a run that ended in state Unknown), Report (the parsed JSON, or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Parameters,
        # Where a retry of an Unknown run command goes in the event feed (NodeRetry), as the warning is written.
        [AllowNull()][object]$EventContext,
        [AllowNull()][System.Collections.IDictionary]$EventRecord,
        [string]$EventPhase = ''
    )
    $global:LASTEXITCODE = 0
    $errorText = ''; $unknown = $false; $exit = 0
    try {
        # The warnings pass through (and are written again as warnings); a retry of an Unknown run command also goes to the event feed.
        $null = & $script:SetScript @Parameters 3>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.WarningRecord]) {
                Write-Warning $_.Message
                if ($EventContext) {
                    $retry = ConvertFrom-AzlOsRetryWarning -Message $_.Message
                    if ($retry) { Send-AzlRetryEvent -Context $EventContext -Record $EventRecord -Phase $EventPhase -Retry $retry }
                }
            }
        }
        $exit = [int]$global:LASTEXITCODE
    }
    catch {
        $errorText = $_.Exception.Message
        $unknown = ($_.Exception.Data['AzlState'] -eq 'Unknown')
        $exit = 1
    }
    $report = $null
    if ($Parameters.ContainsKey('ReportPath') -and (Test-Path -LiteralPath $Parameters.ReportPath -PathType Leaf)) {
        try { $report = Get-Content -LiteralPath $Parameters.ReportPath -Raw | ConvertFrom-Json -Depth 20 } catch { $report = $null }
    }
    [pscustomobject]@{ ExitCode = $exit; Error = $errorText; Unknown = $unknown; Report = $report }
}

function Invoke-AzlNodeRun {
    <#
    .SYNOPSIS
        One Plan or Apply call of the OS configuration script for one node, with that node's method, transport, steps and address.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Verify')][string]$Phase
    )
    $steps = @($Record.setSteps)
    if ($steps.Count -eq 0) { return [pscustomobject]@{ ExitCode = 0; Error = ''; Unknown = $false; Entry = $null; Skipped = $true } }
    $reportFile = Join-Path $Context.NodeReportDirectory ("{0}-{1}.json" -f $Record.name, $Phase.ToLowerInvariant())
    $parameters = @{
        InfrastructureFile = $Context.InfrastructureFile
        Node               = @($Record.name)
        Transport          = $Record.transport
        Step               = $steps
        ReportPath         = $reportFile
        RetryTries         = $Context.RetryTries
        RetryDelaySeconds  = $Context.RetryDelaySeconds
        MaxPasses          = $Context.MaxPasses
    }
    if ($Record.handoffFile) { $parameters.HandoffFile = $Record.handoffFile }
    if ($Context.PSObject.Properties['GuardSettings'] -and $Context.GuardSettings.Count) { $parameters.Settings = $Context.GuardSettings }
    if ($Context.PSObject.Properties['EventLogPath'] -and $Context.EventLogPath) { $parameters.EventLogPath = $Context.EventLogPath }
    if ($Context.ClearStorage) { $parameters.ClearStorage = $true }
    if ($Context.NoRestart) { $parameters.NoRestart = $true }
    if ($Context.SkipValidation) { $parameters.SkipValidation = $true }
    if ($Phase -eq 'Apply') { $parameters.Execute = $true }
    if ($Record.transport -eq 'WinRM') {
        $parameters.Credential = $Context.CredentialInfo.Credential
        if ($Record.address) { $parameters.NodeAddress = @{ $Record.name = $Record.address } }
        if ($Context.PSObject.Properties['Remoting'] -and $Context.Remoting) {
            if ($Context.Remoting.UseSsl) { $parameters.UseSsl = $true }
            $parameters.Authentication = $Context.Remoting.Authentication
        }
    }
    elseif ($Context.CredentialInfo.Credential -and 'Sbe' -in $steps -and [string](Get-AzlProp $Context.Infra 'hardware.sbe.delivery' 'skip') -eq 'winrm_copy') {
        # The node is reached over Arc Run Command, which can't carry a file. hardware.sbe.delivery winrm_copy copies the SBE package
        # over WinRM, so the node script gets the local administrator for that one step (the other steps stay on Arc).
        $parameters.Credential = $Context.CredentialInfo.Credential
        if ($Record.address) { $parameters.NodeAddress = @{ $Record.name = $Record.address } }
    }
    $run = Invoke-AzlSetNodeConfiguration -Parameters $parameters -EventContext $Context -EventRecord $Record -EventPhase $Phase
    $entry = $null
    if ($run.Report) { $entry = @($run.Report.nodes | Where-Object { $_.name -ieq $Record.name } | Select-Object -First 1)[0] }
    [pscustomobject]@{ ExitCode = $run.ExitCode; Error = $run.Error; Unknown = $run.Unknown; Entry = $entry; Skipped = $false }
}

# ---------------------------------------------------------------------------------------------------------------------
# Arc registration (ISO path)
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlArcRegistrationItem {
    <#
    .SYNOPSIS
        The Arc registration step as a plan item. Read only: the Arc machine is looked up in Azure; the node isn't touched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record, [Parameter(Mandatory)][System.Collections.IDictionary]$Node)
    $infra = $Context.Infra
    $resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')
    $current = 'unknown'; $action = 'Info'; $note = ''
    $arc = $null
    try {
        $arc = Find-AzlArcMachine -ArcMachineName (Get-AzlArcMachineName -Node $Node) -SubscriptionId ([string](Get-AzlProp $infra 'azure.subscription_id' '')) -ResourceGroup $resourceGroup -ResourceId ([string]$Record.evidence.ArcResourceId) -HostName $Record.name
    }
    catch { $note = "Arc lookup failed: $($_.Exception.Message)" }
    if ($arc) {
        $current = "$($arc.Name) is $($arc.Status)"
        if ($arc.Status -eq 'Connected') { $action = 'Ok' } else { $action = 'Change'; $note = 'The Arc machine exists but is not Connected; registration runs again.' }
    }
    elseif (-not $note) { $current = 'not registered'; $action = 'Change'; $note = "Registers the machine into $resourceGroup with Invoke-AzStackHciArcInitialization over WinRM (an ARM token from this run's Azure sign-in)." }
    [pscustomobject]@{ Node = $Record.name; Step = 'ArcRegistration'; Item = 'Azure Arc registration'; Current = $current; Desired = "Connected in $resourceGroup"; Action = $action; Note = $note }
}

function Invoke-AzlArcRegistration {
    <#
    .SYNOPSIS
        Registers an ISO-installed machine with Azure Arc: Invoke-AzStackHciArcInitialization on the node, over WinRM, with the ARM
        token of this run's Azure sign-in (passed as a secret, never written down). Then waits for the Arc machine to be Connected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record, [Parameter(Mandatory)][System.Collections.IDictionary]$Node, [int]$WaitMinutes = 20)
    $infra = $Context.Infra
    $subscription = [string](Get-AzlProp $infra 'azure.subscription_id' '')
    $resourceGroup = [string](Get-AzlProp $infra 'azure.resource_group' '')
    $token = Get-AzlArmToken
    $gateway = ''
    if ((Get-AzlProp $infra 'scenario.outbound_path' '') -in 'arc_gateway', 'proxy_arc_gateway') {
        $gw = Get-AzlProp $infra 'networking.outbound.arc_gateway'
        $gwGroup = [string](Get-AzlProp $gw 'resource_group' $resourceGroup)
        if (Get-AzlProp $gw 'name') { $gateway = "/subscriptions/$subscription/resourceGroups/$gwGroup/providers/Microsoft.HybridCompute/gateways/$(Get-AzlProp $gw 'name')" }
    }
    $parameters = @{
        subscriptionId = $subscription; resourceGroup = $resourceGroup; tenantId = [string](Get-AzlProp $infra 'azure.tenant_id' '')
        region = [string](Get-AzlProp $infra 'azure.location' ''); accountId = $token.AccountId
        cloud = $(if ((Get-AzlProp $infra 'scenario.cloud' 'public') -eq 'government') { 'AzureUSGovernment' } else { 'AzureCloud' })
        arcGatewayId = $gateway
    }
    $transport = New-AzlWinRmTransport -Address @{ $Record.name = $Record.address } -Credential $Context.CredentialInfo.Credential
    $null = Invoke-AzlNodeScript -Transport $transport -Node $Record.name -Script (Get-AzlNodePayload -Name ArcRegistration) -Parameters $parameters -Secrets @{ armToken = $token.Token } -TimeoutSeconds 7200 -Tries 1
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    do {
        $arc = $null
        try { $arc = Find-AzlArcMachine -ArcMachineName (Get-AzlArcMachineName -Node $Node) -SubscriptionId $subscription -ResourceGroup $resourceGroup -HostName $Record.name } catch { Write-Verbose "Arc lookup: $($_.Exception.Message)" }
        if ($arc -and $arc.Status -eq 'Connected') { return $arc }
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    throw "$($Record.name) ran the Arc initialization but its Arc machine is not Connected in $resourceGroup after $WaitMinutes minutes."
}

# ---------------------------------------------------------------------------------------------------------------------
# Preconditions of the ISO path
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlIsoPrecondition {
    <#
    .SYNOPSIS
        Before anything is changed on a machine reached over WinRM: the route, the credentials, and the OS (Azure Stack HCI OS or
        Windows Server at build 25398 or later). Returns a list of precise problems (empty when fine) and what it saw.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $problems = [System.Collections.Generic.List[string]]::new()
    $seen = $null
    $name = $Record.name
    if (-not $Record.address) { $problems.Add("${name}: no address to open a WinRM session to. Put nodes[].management.ip_address or maintenance_address in the file, or pass -NodeAddress."); return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null } }
    if (-not $Context.CredentialInfo.Credential) {
        $problems.Add("${name}: no local administrator credential. $($Context.CredentialInfo.Error) Pass -Credential, or make identity.local_admin.password readable (Key Vault get on the secret).")
        return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null }
    }
    if (-not (Test-AzlWinRmPort -Address $Record.address)) {
        $problems.Add("${name}: no route to $($Record.address):5985. The ISO path opens a WinRM session from this host, so this host (or the self-hosted runner) must reach the nodes' management subnet and WinRM must be enabled on the node.")
        return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null }
    }
    try {
        $transport = New-AzlWinRmTransport -Address @{ $name = $Record.address } -Credential $Context.CredentialInfo.Credential
        $seen = Invoke-AzlNodeScript -Transport $transport -Node $name -Script (Get-AzlNodePayload -Name Preflight) -Tries 1 -TimeoutSeconds 300
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'denied|logon failure|authentication|credentials|unauthorized') { $problems.Add("${name}: the local administrator '$($Context.CredentialInfo.Credential.UserName)' was refused on $($Record.address) ($message). Check identity.local_admin (username and the vault secret), or pass -Credential.") }
        else { $problems.Add("${name}: can't run a command on $($Record.address) over WinRM: $message") }
        return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $null }
    }
    $caption = [string](Get-AzlProp $seen 'caption' '')
    $build = [int](Get-AzlProp $seen 'build' 0)
    if ($caption -notmatch 'Azure Stack HCI|Azure Local|Windows Server') { $problems.Add("${name}: the OS is '$caption'. Azure Local needs the Azure Stack HCI OS (or Windows Server for the early steps).") }
    elseif ($build -lt $script:MinimumBuild) { $problems.Add("${name}: the OS build is $build ($caption). Azure Local needs build $script:MinimumBuild or later (Azure Stack HCI OS 23H2).") }
    return [pscustomobject]@{ Problems = $problems.ToArray(); Seen = $seen }
}

# ---------------------------------------------------------------------------------------------------------------------
# Plan, apply, verify
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlPlanItem {
    param([object]$Item, [string]$Node)
    [pscustomobject]@{
        Node = $Node; Step = [string](Get-AzlProp $Item 'step' (Get-AzlProp $Item 'Step' '')); Item = [string](Get-AzlProp $Item 'item' (Get-AzlProp $Item 'Item' ''))
        Current = [string](Get-AzlProp $Item 'current' (Get-AzlProp $Item 'Current' '')); Desired = [string](Get-AzlProp $Item 'desired' (Get-AzlProp $Item 'Desired' ''))
        Action = [string](Get-AzlProp $Item 'action' (Get-AzlProp $Item 'Action' '')); Note = [string](Get-AzlProp $Item 'note' (Get-AzlProp $Item 'Note' ''))
    }
}

function Merge-AzlRunResult {
    # Folds one Plan or Verify call into the node's record. Returns $true when the node could be read.
    param([System.Collections.IDictionary]$Record, [object]$Run, [string]$Phase)
    $Record.phases[$Phase] = [ordered]@{ exitCode = $Run.ExitCode; error = $Run.Error; skipped = $Run.Skipped }
    if ($Run.Skipped) { $Record.plan = @(); return $true }
    if (-not $Run.Entry) {
        $Record.errors += "$Phase of $($Record.name) failed: $(if ($Run.Error) { $Run.Error } else { "the script wrote no report (exit code $($Run.ExitCode))." })"
        return $false
    }
    $Record.plan = @(@($Run.Entry.plan) | ForEach-Object { ConvertTo-AzlPlanItem -Item $_ -Node $Record.name })
    $Record.ports = @($Run.Entry.ports)
    $Record.sanDisks = @($Run.Entry.sanDisks)
    $Record.hostname = [string](Get-AzlProp $Run.Entry 'hostname' '')
    $Record.osVersion = [string](Get-AzlProp $Run.Entry 'osVersion' '')
    # hardware.sbe.delivery skip: the node is not failed, but the package is not on it and the OEM drivers wait, so say it once.
    if ($Phase -eq 'Plan' -and @($Record.plan | Where-Object { $_.Step -eq 'Sbe' -and $_.Action -eq 'Info' -and $_.Note -match 'NOT DELIVERED' }).Count) {
        $Record.warnings += "$($Record.name): the SBE package is NOT DELIVERED (hardware.sbe.delivery is skip or not set), so the OEM network drivers are skipped. Set hardware.sbe.delivery to node_pull or winrm_copy, or put the package in C:\SBE yourself."
    }
    $guard = @(Get-AzlProp $Run.Entry 'guard' @())
    if ($guard.Count) { $Record.guard = @($Record.guard) + $guard }
    $events = @(Get-AzlProp $Run.Entry 'events' @())
    if ($events.Count) { $Record.events = @($Record.events) + $events }
    $finalAddress = [string](Get-AzlProp $Run.Entry 'address' '')
    if ($finalAddress -and $Record.transport -eq 'WinRM') { $Record.address = $finalAddress }
    return $true
}

function Merge-AzlRecordCount {
    param([System.Collections.IDictionary]$Record)
    $Record.pendingChanges = @($Record.plan | Where-Object { $_.Action -eq 'Change' }).Count
    $Record.blocked = @($Record.plan | Where-Object { $_.Action -eq 'Blocked' }).Count
    $Record.wipe = @($Record.plan | Where-Object { $_.Step -eq 'ClearStorage' -and $_.Action -eq 'Change' } | ForEach-Object {
            [ordered]@{ node = $Record.name; disks = $_.Current; note = $_.Note }
        })
}

function Test-AzlZtpVerification {
    # What ZTP guaranteed, checked rather than redone: the node's name, its Arc machine, the handoff.
    param([System.Collections.IDictionary]$Record)
    $checks = @()
    $e = $Record.evidence
    $checks += [ordered]@{ check = 'handoff ready'; ok = [bool]($e.HandoffPresent -and $e.HandoffReady); detail = $(if ($e.HandoffPresent) { "ready=$($e.HandoffReady)" } else { 'no handoff passed; verified through the Arc machine' }) }
    $checks[-1].ok = $checks[-1].ok -or $e.ArcStatus -eq 'Connected'
    $checks += [ordered]@{ check = 'Arc machine connected'; ok = ($e.ArcStatus -eq 'Connected'); detail = $(if ($e.ArcFound) { $e.ArcStatus } else { 'not found' }) }
    if ($Record.hostname) {
        $checks += [ordered]@{ check = 'computer name'; ok = ($Record.hostname -ieq $Record.name); detail = "node reports '$($Record.hostname)', file says '$($Record.name)'; ZTP names the machine, so it is not renamed here" }
    }
    return $checks
}

function Invoke-AzlPlanPhase {
    param([object]$Context, [System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Node, [string]$Phase = 'Plan')
    if ($Record.bootstrap.Contains('pending') -and $Record.bootstrap.pending) {
        $Record.plan = @([pscustomobject]@{ Node = $Record.name; Step = 'RemoteManagement'; Item = 'remote management bootstrap'; Current = 'WinRM is closed to this host (the node firewall limits it to its own subnet)'; Desired = "WinRM open for $(@($Record.bootstrap.cidrs) -join ', ')"; Action = 'Change'; Note = 'Arc Run Command, once, only for this step. The rest of the plan can be read after it.' })
        Merge-AzlRecordCount -Record $Record
        $Record.status = 'planned'
        return
    }
    $run = Invoke-AzlNodeRun -Context $Context -Record $Record -Phase $Phase
    $readable = Merge-AzlRunResult -Record $Record -Run $run -Phase $Phase
    if (-not $readable) { $Record.status = 'failed'; return }
    if ($Record.method -eq 'Iso' -and 'ArcRegistration' -in $Record.steps) {
        $item = Get-AzlArcRegistrationItem -Context $Context -Record $Record -Node $Node
        $Record.plan = @($Record.plan) + $item
        if ($item.Action -eq 'Ok') { $Record.evidence.ArcStatus = 'Connected'; $Record.evidence.ArcFound = $true }
    }
    if ($Record.method -eq 'Ztp') {
        $Record.verification = @(Test-AzlZtpVerification -Record $Record)
        foreach ($v in $Record.verification | Where-Object { -not $_.ok }) { $Record.errors += "Verification failed for $($Record.name): $($v.check) ($($v.detail))." }
    }
    Merge-AzlRecordCount -Record $Record
    if ($Phase -eq 'Plan') { $Record.status = 'planned' }
}

function Resolve-AzlWinRmAddress {
    # A node's address can change while it is configured (the installer's address becomes the static one): find where it answers now.
    param([object]$Context, [System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Node)
    if ($Record.transport -ne 'WinRM') { return }
    foreach ($address in @(Get-AzlNodeAddressCandidate -Infrastructure $Context.Infra -Node $Node -Override $Context.NodeAddress)) {
        if (Test-AzlWinRmPort -Address $address) { $Record.address = $address; return }
    }
}

function Invoke-AzlApplyPhase {
    param([object]$Context, [System.Collections.IDictionary]$Record, [System.Collections.IDictionary]$Node)
    if ($Record.bootstrap.Contains('pending') -and $Record.bootstrap.pending) {
        try {
            Invoke-AzlRunBootstrap -Context $Context -Record $Record
            $Record.changes += [ordered]@{ pass = 0; id = 'RemoteManagement/bootstrap'; status = 'changed'; detail = "opened $(@($Record.bootstrap.opened) -join ', ') for $(@($Record.bootstrap.cidrs) -join ', ') through Arc Run Command (once)" }
            Invoke-AzlPlanPhase -Context $Context -Record $Record -Node $Node -Phase 'Plan'
        }
        catch { $Record.errors += "Bootstrap of $($Record.name) failed: $($_.Exception.Message)"; $Record.status = 'failed'; return }
    }
    Resolve-AzlWinRmAddress -Context $Context -Record $Record -Node $Node
    $arcPending = @($Record.plan | Where-Object { $_.Step -eq 'ArcRegistration' -and $_.Action -eq 'Change' }).Count -gt 0
    $setPending = @($Record.plan | Where-Object { $_.Step -ne 'ArcRegistration' -and $_.Action -eq 'Change' }).Count -gt 0
    if ($setPending -or $Record.blocked -gt 0) {
        Send-AzlStepApplyingEvent -Context $Context -Record $Record
        $run = Invoke-AzlNodeRun -Context $Context -Record $Record -Phase Apply
        $Record.phases['Apply'] = [ordered]@{ exitCode = $run.ExitCode; error = $run.Error; unknown = $run.Unknown }
        $made = @()
        if ($run.Entry) {
            $made = @(@($run.Entry.changes) | ForEach-Object { [ordered]@{ pass = $_.Pass; id = $_.Id; status = $_.Status; detail = $_.Detail } })
            $Record.changes += $made
            if ($run.Entry.restarted) {
                $Record.restarted = $true
                # The restart happens inside the apply call; these two are written when the call reports it, before the steps of that call.
                Send-AzlRunEvent -Context $Context -Record $Record -State NodeRestarting -Evidence 'The apply asked the node to restart (a computer name, MPIO or driver change needs one).' -Level Warning
                Send-AzlRunEvent -Context $Context -Record $Record -State NodeReconnecting -Evidence 'The node restarted during the apply (a computer name, MPIO or driver change needs one); the run waited for it.' -Level Warning
                Send-AzlRunEvent -Context $Context -Record $Record -State NodeReconnected -Evidence 'The node came back with a new boot time and answered again.'
            }
        }
        Send-AzlStepAppliedEvent -Context $Context -Record $Record -Change $made
        foreach ($g in @(Get-AzlProp $run.Entry 'guard' @() | Where-Object { $_ -and $_.state -ne 'Committed' })) {
            if ($g.state -eq 'Unknown') { $Record.warnings += "PendingReconciliation: change $($g.changeId) ($($g.group)) on $($Record.name): $($g.reason) $($g.nextAction)" }
            else { $Record.errors += "Guarded change $($g.changeId) ($($g.group)) on $($Record.name) ended $($g.state): $($g.reason) $($g.nextAction)" }
        }
        if ($run.Entry) { $Record.guard = @($Record.guard) + @(Get-AzlProp $run.Entry 'guard' @()); $Record.events = @($Record.events) + @(Get-AzlProp $run.Entry 'events' @()); $finalAddress = [string](Get-AzlProp $run.Entry 'address' ''); if ($finalAddress -and $Record.transport -eq 'WinRM') { $Record.address = $finalAddress; $Context.NodeAddress[$Record.name] = $finalAddress } }
        if ($run.Error) {
            if ($run.Unknown) { $Record.warnings += "The Apply of $($Record.name) ended in state Unknown after $($Context.RetryTries) tries; convergence is decided by the verification pass, not by the command." }
            else { $Record.errors += "Apply of $($Record.name) failed: $($run.Error)" }
        }
    }
    if ($arcPending) {
        Send-AzlStepApplyingEvent -Context $Context -Record $Record -ArcRegistration
        try {
            Resolve-AzlWinRmAddress -Context $Context -Record $Record -Node $Node
            $arc = Invoke-AzlArcRegistration -Context $Context -Record $Record -Node $Node
            $Record.changes += [ordered]@{ pass = 1; id = 'ArcRegistration'; status = 'changed'; detail = "registered as $($arc.Name) ($($arc.Status))" }
            $Record.evidence.ArcFound = $true; $Record.evidence.ArcStatus = 'Connected'; $Record.evidence.ArcResourceId = $arc.ResourceId
        }
        catch {
            $Record.changes += [ordered]@{ pass = 1; id = 'ArcRegistration'; status = 'failed'; detail = $_.Exception.Message }
            $Record.errors += "Arc registration of $($Record.name) failed: $($_.Exception.Message)"
        }
        Send-AzlStepAppliedEvent -Context $Context -Record $Record -Change @($Record.changes | Where-Object { $_.id -eq 'ArcRegistration' } | Select-Object -Last 1)
    }
    $Record.status = 'applied'
}

function Invoke-AzlRemotingPreCheck {
    <#
    .SYNOPSIS
        The remoting pre-check seam (a test replaces it): every WinRM node probed at the same time, rows with Reachable, Address, Result and Diagnosis.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Candidate, [Parameter(Mandatory)][object]$Remoting, [Parameter(Mandatory)][object]$Context, [string[]]$ArcAvailable = @())
    $has = [bool]$Context.CredentialInfo.Credential
    Get-AzlRemotingFinding -Node $Candidate -Port $Remoting.Port -HasCredential $has -Origin ([string]$Context.CredentialInfo.Source) -ArcAvailable $ArcAvailable
}

function Invoke-AzlRunBootstrap {
    <#
    .SYNOPSIS
        The one use of Arc Run Command in the WinRM mode: open WinRM (and RDP, ICMP when the plan has them) for the source CIDRs on one node, once.
        Then the node is probed again; a node that still doesn't answer fails with the diagnosis.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $cidrs = @($Record.bootstrap.cidrs)
    $arc = New-AzlArcRunCommandTransport -ArcResourceId @{ $Record.name = [string]$Record.evidence.ArcResourceId }
    $withExtras = 'RemoteManagement' -in $Record.steps
    $done = Invoke-AzlRemotingBootstrap -ArcTransport $arc -Node $Record.name -Cidr $cidrs -Rdp:$withExtras -Icmp:$withExtras -Https:([bool]$Context.Remoting.UseSsl)
    $Record.bootstrap = [ordered]@{ used = $true; pending = $false; transport = 'ArcRunCommand'; opened = @($done.Opened); scope = @($done.Scope); cidrs = $cidrs }
    Send-AzlGuardEvent -Context $Context.EventContext -Node $Record.name -State 'TransportResolved' -Step 'RemoteManagement' -Transport 'ArcRunCommand' -Level Warning -Evidence "Bootstrap through Arc Run Command, once: opened $(@($done.Opened) -join ', ') for $($cidrs -join ', '). Everything after this goes over WinRM." -Data @{ bootstrap = $true; cidrs = $cidrs }
    Start-Sleep -Seconds 3
    $reached = $false
    foreach ($address in @($Record.evidence.Addresses)) { if (Test-AzlWinRmPort -Address $address -Port $Context.Remoting.Port) { $Record.address = $address; $reached = $true; break } }
    if (-not $reached) { throw "$($Record.name) still doesn't answer on $($Context.Remoting.Port) after the bootstrap opened remote management for $($cidrs -join ', '). The runner's address may not be in those CIDRs, or a network firewall between this host and the node blocks TCP $($Context.Remoting.Port). Tried: $(@($Record.evidence.Addresses) -join ', ')." }
}
function Get-AzlWipeList {
    <#
    .SYNOPSIS
        The disks that will be wiped: one entry per node with a ClearStorage change in its plan, from the plan and nothing else.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Record)
    @($Record | Where-Object { @($_.wipe).Count } | ForEach-Object { foreach ($w in $_.wipe) { [pscustomobject]@{ Node = $w.node; Disks = $w.disks; Note = $w.note } } })
}

function Format-AzlWipeList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$WipeList, [Parameter(Mandatory)][bool]$ClearStorage, [Parameter(Mandatory)][string]$Mode, [string]$Source = '')
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $ClearStorage) { $lines.Add('Storage wipe: off (os_configuration.clear_storage is false). Leftover storage is reported, nothing is wiped.'); return ($lines -join [Environment]::NewLine) }
    $verb = if ($Mode -eq 'Apply') { 'WILL BE WIPED NOW' } else { 'WOULD BE WIPED if you apply' }
    $lines.Add("STORAGE WIPE ($Source). Local disks that $verb. Boot, system, SAN (FC, iSCSI) and USB disks are never touched.")
    if (@($WipeList).Count -eq 0) { $lines.Add('  Nothing to wipe: no leftover local storage was found on any node.') }
    foreach ($w in $WipeList) { $lines.Add("  $($w.Node): $($w.Disks)") }
    return ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlOsConfigurationExitCode {
    <#
    .SYNOPSIS
        0 all converged (Plan: nothing failed or blocked), 1 a node failed, is blocked or didn't converge, 2 bad input.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record, [string[]]$ClusterProblem = @(), [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan', [switch]$FailOnPendingChanges, [switch]$InputError)
    if ($InputError) { return 2 }
    if (@($ClusterProblem).Count) { return 1 }
    foreach ($r in $Record) {
        if ($r.status -in 'failed', 'skipped') { return 1 }
        if (@($r.errors).Count -and -not $r.converged) { return 1 }
        if ($r.blocked -gt 0) { return 1 }
        if ($Mode -eq 'Apply' -and -not $r.converged) { return 1 }
        if ($Mode -eq 'Plan' -and $FailOnPendingChanges -and $r.pendingChanges -gt 0) { return 1 }
    }
    return 0
}

function Format-AzlOsConfigurationSummary {
    <#
    .SYNOPSIS
        The human summary: a table with one row per node. -Markdown for a job summary.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record, [string]$Mode = 'Plan', [switch]$Markdown, [int]$ExitCode = 0)
    $rows = foreach ($r in $Record) {
        [pscustomobject][ordered]@{
            Node      = $r.name
            Method    = "$($r.method) ($($r.methodSource))"
            Transport = $r.transport
            Changes   = $(if ($Mode -eq 'Apply') { @($r.changes | Where-Object { $_.status -eq 'changed' }).Count } else { "$($r.pendingChanges) planned" })
            Converged = $(if ($Mode -eq 'Apply') { $r.converged } else { if ($r.pendingChanges -eq 0 -and $r.blocked -eq 0 -and $r.status -ne 'failed') { 'yes (nothing to change)' } else { 'no' } })
            Restarted = $r.restarted
            Errors    = @($r.errors).Count
        }
    }
    if ($Markdown) {
        $lines = @("| Node | Method | Transport | Changes | Converged | Restarted | Errors |", '| --- | --- | --- | --- | --- | --- | --- |')
        foreach ($row in $rows) { $lines += "| $($row.Node) | $($row.Method) | $($row.Transport) | $($row.Changes) | $($row.Converged) | $($row.Restarted) | $($row.Errors) |" }
        $lines += ''; $lines += "Exit code: $ExitCode"
        return ($lines -join [Environment]::NewLine)
    }
    return (($rows | Format-Table -AutoSize -Wrap | Out-String -Width 200).TrimEnd() + [Environment]::NewLine + "Exit code: $ExitCode")
}

function ConvertTo-AzlNodeReport {
    param([System.Collections.IDictionary]$Record)
    [ordered]@{
        name           = $Record.name
        method         = [ordered]@{ declared = $Record.declared; resolved = $Record.method; source = $Record.methodSource; transport = $Record.transport; warnings = @($Record.methodWarnings) }
        evidence       = [ordered]@{
            handoff = [ordered]@{ present = $Record.evidence.HandoffPresent; ready = $Record.evidence.HandoffReady; file = $Record.evidence.HandoffFile }
            arc     = [ordered]@{ found = $Record.evidence.ArcFound; status = $Record.evidence.ArcStatus; error = $Record.evidence.ArcError }
            winrm   = [ordered]@{ answers = $Record.evidence.WinRmAnswers; address = $Record.evidence.WinRmAddress; note = $Record.evidence.WinRmNote }
        }
        address        = $Record.address
        stepTransports = [ordered]@{ all = $Record.transport; bootstrap = $(if ($Record.bootstrap.used) { 'ArcRunCommand' } else { '' }) }
        bootstrap      = $Record.bootstrap
        guard          = @($Record.guard)
        events         = @($Record.events)
        steps          = @($Record.steps)
        status         = $Record.status
        planned        = [ordered]@{ changes = $Record.pendingChanges; blocked = $Record.blocked }
        plan           = @($Record.plan | ForEach-Object { [ordered]@{ step = $_.Step; item = $_.Item; current = $_.Current; desired = $_.Desired; action = $_.Action; note = $_.Note } })
        changes        = @($Record.changes)
        verification   = @($Record.verification)
        wipe           = @($Record.wipe)
        errors         = @($Record.errors)
        warnings       = @($Record.warnings)
        converged      = [bool]$Record.converged
        restarted      = [bool]$Record.restarted
        phases         = $Record.phases
    }
}

function Write-AzlOsConfigurationReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record, [Parameter(Mandatory)][string]$FileName, [string[]]$ClusterProblem = @(), [int]$ExitCode = 0, [string]$Message = '')
    $report = [ordered]@{
        schemaVersion  = 1
        generatedUtc   = [datetime]::UtcNow.ToString('o')
        mode           = $Context.Mode
        cluster        = $Context.ClusterName
        infrastructure = $Context.InfrastructureFile
        clearStorage   = [ordered]@{ enabled = [bool]$Context.ClearStorage; source = $Context.ClearStorageSource }
        handoffFiles   = @($Context.HandoffFiles)
        exitCode       = $ExitCode
        message        = $Message
        clusterProblems = @($ClusterProblem)
        wipeList       = @(Get-AzlWipeList -Record $Record | ForEach-Object { [ordered]@{ node = $_.Node; disks = $_.Disks } })
        nodes          = @($Record | ForEach-Object { ConvertTo-AzlNodeReport -Record $_ })
    }
    $path = Join-Path $Context.ReportDirectory $FileName
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

# ---------------------------------------------------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlNodeRecord {
    param([System.Collections.IDictionary]$Node, [object]$Resolution, [string[]]$Step)
    $method = $Resolution.Method
    $steps = if ($method) { @(Get-AzlNodeStepList -Method $method -Step $Step) } else { @() }
    $evidence = $Resolution.Evidence
    [ordered]@{
        name = [string]$Node['name']; declared = $Resolution.Declared; method = $method; methodSource = $Resolution.Source; methodWarnings = @($Resolution.Warnings)
        transport = $Resolution.Transport; address = $(if ($Resolution.Transport -eq 'WinRM') { $evidence.WinRmAddress } else { '' })
        handoffFile = $evidence.HandoffFile; evidence = $evidence
        steps = $steps; setSteps = @($steps | Where-Object { $_ -in $script:NodeSteps })
        status = 'pending'; plan = @(); changes = @(); errors = @(); warnings = @(); verification = @(); wipe = @()
        ports = @(); sanDisks = @(); hostname = ''; osVersion = ''; guard = @(); events = @(); bootstrap = [ordered]@{ used = $false }
        pendingChanges = 0; blocked = 0; converged = $false; restarted = $false; phases = [ordered]@{}; outcomeSent = $false
        osCaption = ''; osBuild = 0
    }
}

function Test-AzlSanConsistency {
    # Every node must see the same SAN disks (the same UniqueIds).
    param([object[]]$Record)
    $sets = @{}
    foreach ($r in $Record) {
        if ($r.status -in 'failed', 'skipped' -or @($r.sanDisks).Count -eq 0) { continue }
        $sets[$r.name] = @($r.sanDisks | ForEach-Object { $_.uid } | Sort-Object) -join ','
    }
    if (@($sets.Values | Select-Object -Unique).Count -gt 1) { return @("The nodes don't see the same SAN disks (UniqueIds differ): $(($sets.GetEnumerator() | ForEach-Object { "$($_.Key)=[$($_.Value)]" }) -join '; ')") }
    return @()
}

function Invoke-AzlOsConfiguration {
    <#
    .SYNOPSIS
        The whole OS configuration run. See the module description. Returns Context, Records, ExitCode, Report paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InfrastructureFile,
        [string[]]$HandoffPath,
        [string[]]$Node,
        [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
        [ValidateSet('RemoteManagement', 'Sbe', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'ArcRegistration')][string[]]$Step,
        [string]$ReportDirectory,
        [string]$ConfigPath,
        [hashtable]$Settings,
        [bool]$ContinueOnNodeFailure = $true,
        [ValidateSet('Auto', 'ArcRunCommand', 'WinRM')][string]$Transport = 'Auto',
        [ValidateSet('Auto', 'Ztp', 'Iso')][string]$Method = 'Auto',
        [pscredential]$Credential,
        [hashtable]$NodeAddress,
        [switch]$ClearStorage,
        [switch]$FailOnPendingChanges,
        [switch]$SkipValidation,
        [string]$EventLogPath
    )
    $records = @()
    $context = $null
    try {
        # ---- 1. validate the inputs
        if (-not (Test-Path -LiteralPath $InfrastructureFile -PathType Leaf)) { throw (Get-AzlInputError "Infrastructure file not found: $InfrastructureFile") }
        $run = Get-AzlRunSetting -ConfigPath $ConfigPath -Settings $Settings
        try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation:$SkipValidation }
        catch { throw (Get-AzlInputError $_.Exception.Message) }
        $infraNodes = @($infra.nodes)
        if ($Node) { foreach ($n in $Node) { if ($n -notin @($infraNodes | ForEach-Object { $_['name'] })) { throw (Get-AzlInputError "Node $n isn't in $InfrastructureFile. Nodes there: $(@($infraNodes | ForEach-Object { $_['name'] }) -join ', ').") } } }
        $nodes = @($infraNodes | Where-Object { -not $Node -or $_['name'] -in $Node })
        if ($nodes.Count -eq 0) { throw (Get-AzlInputError "No nodes in $InfrastructureFile.") }
        $merged = if ($HandoffPath) { Merge-AzlHandoff -Path $HandoffPath } else { $null }

        $reportDir = if ($ReportDirectory) { $ReportDirectory } else { Join-Path ([IO.Path]::GetTempPath()) 'azl-osconfig' }
        $null = New-Item -ItemType Directory -Force -Path $reportDir
        $nodeReportDir = Join-Path $reportDir 'node-reports'
        $null = New-Item -ItemType Directory -Force -Path $nodeReportDir

        $clearFromFile = (Get-AzlProp $infra 'os_configuration.clear_storage' $false) -eq $true
        $clear = $ClearStorage.IsPresent -or $clearFromFile
        $clearSource = if ($ClearStorage.IsPresent) { '-ClearStorage switch' } elseif ($clearFromFile) { 'os_configuration.clear_storage in the master file' } else { 'off' }
        $tries = if ($run.ContainsKey('retryTries')) { [int]$run.retryTries } else { 3 }
        $delays = if ($run.ContainsKey('retryDelaySeconds')) { @($run.retryDelaySeconds | ForEach-Object { [int]$_ }) } else { @(15, 45, 120) }
        $addressOverride = @{}
        if ($run.ContainsKey('nodeAddress')) { foreach ($k in $run.nodeAddress.Keys) { $addressOverride[$k] = $run.nodeAddress[$k] } }
        if ($NodeAddress) { foreach ($k in $NodeAddress.Keys) { $addressOverride[$k] = $NodeAddress[$k] } }
        $failOnPending = $FailOnPendingChanges.IsPresent -or ($run.ContainsKey('failOnPendingChanges') -and $run.failOnPendingChanges -eq $true)

        $context = [pscustomobject]@{
            Infra = $infra; InfrastructureFile = $InfrastructureFile; Mode = $Mode; Handoff = $merged; HandoffFiles = $(if ($merged) { $merged.Files } else { @() })
            ClearStorage = $clear; ClearStorageSource = $clearSource; ReportDirectory = $reportDir; NodeReportDirectory = $nodeReportDir
            ClusterName = [string](Get-AzlProp $infra 'cluster.name' 'cluster'); AzureSignedIn = (Test-AzlAzureSignedIn)
            NodeAddress = $addressOverride; Method = $Method; CredentialInfo = $null
            RetryTries = $tries; RetryDelaySeconds = $delays; MaxPasses = $(if ($run.ContainsKey('maxPasses')) { [int]$run.maxPasses } else { 6 })
            NoRestart = ($run.ContainsKey('noRestart') -and $run.noRestart -eq $true); SkipValidation = $SkipValidation.IsPresent
            SchemaVersion = [string](Get-AzlProp $infra '_metadata.schema_version' '')
            EventLogPath = $(if ($EventLogPath) { [IO.Path]::GetFullPath($EventLogPath, (Get-Location).ProviderPath) } else { Join-Path $reportDir 'os-configuration-events.jsonl' })
            TransportRequested = $Transport; Remoting = $null; GuardSettings = @{}; EventContext = $null
        }
        $context.Remoting = Get-AzlRemotingSetting -Infrastructure $infra -Setting $run -Transport $Transport
        foreach ($k in 'networkRollbackMinutes', 'networkStableSeconds', 'reconnectWaitMinutes', 'staleRunCommandMinutes', 'addressProbe', 'remoting') { if ($run.ContainsKey($k)) { $context.GuardSettings[$k] = $run[$k] } }
        if (-not $context.GuardSettings.ContainsKey('networkRollbackMinutes') -and (Get-AzlProp $infra 'os_configuration.network.confirm_minutes')) { $context.GuardSettings.networkRollbackMinutes = [int](Get-AzlProp $infra 'os_configuration.network.confirm_minutes') }
        if (-not $context.GuardSettings.ContainsKey('networkStableSeconds') -and (Get-AzlProp $infra 'os_configuration.network.stable_seconds')) { $context.GuardSettings.networkStableSeconds = [int](Get-AzlProp $infra 'os_configuration.network.stable_seconds') }
        $context.EventContext = New-AzlGuardEventContext -Path $context.EventLogPath -SchemaVersion $context.SchemaVersion
        $context.CredentialInfo = Get-AzlLocalAdminCredential -Infrastructure $infra -Credential $Credential
        $declared = [string](Get-AzlProp $infra 'scenario.os_install' '')
        $nodeNames = @($nodes | ForEach-Object { [string]$_['name'] })
        $startData = Get-AzlNodeVersionData -Context $context -Record $null
        $startData.nodes = $nodeNames; $startData.mode = $Mode; $startData.cluster = $context.ClusterName
        Send-AzlRunEvent -Context $context -State RunStarted -Record $null -Evidence "OS configuration run started: mode $Mode, cluster $($context.ClusterName), $($nodeNames.Count) node(s): $($nodeNames -join ', ')." -Data $startData

        Write-AzlLine "OS configuration: $($context.ClusterName), mode $Mode, $($nodes.Count) node(s), report directory $reportDir"
        if ($merged) { Write-AzlLine "Handoffs: $($merged.Files.Count) file(s) merged, $($merged.Map.Count) node(s)." }
        if ($merged) {
            foreach ($key in $merged.Map.Keys) {
                if (-not (@($infraNodes | Where-Object { ([string]$_['name']) -ieq $key -or (Get-AzlArcMachineName -Node $_) -ieq $key }).Count)) { Write-Warning "Handoff $($merged.Map[$key].File) names node '$key', which isn't in the infrastructure file." }
            }
        }

        $records = [System.Collections.Generic.List[object]]::new()
        $inputProblems = [System.Collections.Generic.List[string]]::new()
        $nodeByName = @{}
        foreach ($n in $nodes) {
            $nodeByName[[string]$n['name']] = $n
            Send-AzlRunEvent -Context $context -State NodeStarted -Record ([ordered]@{ name = [string]$n['name'] }) -Evidence "Looking at $($n['name']): its handoff, its Arc machine, and whether it answers on WinRM, to decide how it is configured."
            $evidence = Get-AzlNodeEvidence -Context $context -Node $n
            $resolution = Resolve-AzlNodeMethod -Node ([string]$n['name']) -Declared $declared -Evidence $evidence -Force $Method
            foreach ($e in $resolution.Errors) { $inputProblems.Add($e) }
            foreach ($w in $resolution.Warnings) { Write-Warning $w }
            if ($resolution.Method) { $resolution.Transport = $context.Remoting.Kind }
            $record = Get-AzlNodeRecord -Node $n -Resolution $resolution -Step $Step
            $records.Add($record)
            if ($resolution.Method) {
                $seen = @(
                    $(if ($evidence.HandoffPresent) { "handoff $(if ($evidence.HandoffReady) { 'ready' } else { 'not ready' })" } else { 'no handoff' })
                    $(if ($evidence.ArcFound) { "Arc machine $($evidence.ArcStatus)" } else { 'no Arc machine' })
                    $(if ($evidence.WinRmAnswers -eq $true) { 'answers on WinRM' } elseif ($null -eq $evidence.WinRmAnswers) { 'WinRM not tried' } else { 'no answer on WinRM' })
                ) -join ', '
                Send-AzlRunEvent -Context $context -State MethodResolved -Record $record -Level $(if (@($resolution.Warnings).Count) { 'Warning' } else { 'Info' }) `
                    -Evidence "Declared os_install '$($resolution.Declared)'; evidence: $seen; so the $($resolution.Method) path ($($resolution.Source)) over $($resolution.Transport).$(if (@($resolution.Warnings).Count) { ' Warning: ' + (@($resolution.Warnings) -join ' ') })" `
                    -Data (Get-AzlMethodResolvedData -Context $context -Record $record -Resolution $resolution)
                Send-AzlRunEvent -Context $context -State TransportResolved -Record $record -Evidence "$($record.name) is reached over $($record.transport)$(if ($record.address) { ' at ' + $record.address }) for every step ($(if ($Transport -ne 'Auto') { '-Transport forces it' } else { 'chosen from the method and the evidence' }))." -Data @{ forced = ($Transport -ne 'Auto'); address = [string]$record.address }
            }
            else {
                Send-AzlRunEvent -Context $context -State NodeFailed -Record $record -Level Error -Evidence "No method could be resolved: $(@($resolution.Errors) -join ' ')" -NextAction 'Pass the node''s handoff (-HandoffPath), sign in to Azure, or make the node reachable; then run again.'
            }
            if ($resolution.Method) { Write-AzlLine "  $($record.name): method $($record.method) ($($record.methodSource); declared $declared), transport $($record.transport)$(if ($record.address) { ", address $($record.address)" })." }
        }
        if ($inputProblems.Count) { throw (Get-AzlInputError (($inputProblems | ForEach-Object { "- $_" }) -join [Environment]::NewLine)) }

        # transport needs
        $arcNodes = @($records | Where-Object { $_.transport -eq 'ArcRunCommand' })
        if ($arcNodes.Count -and -not $context.AzureSignedIn) { throw (Get-AzlInputError "Azure Arc Run Command needs an Azure sign-in (Connect-AzAccount, or azure/login in a pipeline) for: $(($arcNodes | ForEach-Object { $_.name }) -join ', ').") }
        $needsArcStep = @($records | Where-Object { $_.method -eq 'Iso' -and 'ArcRegistration' -in $_.steps })
        if ($needsArcStep.Count -and -not $context.AzureSignedIn) { throw (Get-AzlInputError "Arc registration needs an Azure sign-in to look up the Arc machine and get an ARM token: $(($needsArcStep | ForEach-Object { $_.name }) -join ', ').") }

        # remoting pre-check: every node reached over WinRM, probed at the same time; one table, before anything changes
        $winRmRecords = @($records | Where-Object { $_.transport -eq 'WinRM' })
        if ($winRmRecords.Count) {
            $candidates = @($winRmRecords | ForEach-Object { [pscustomobject]@{ Name = $_.name; Addresses = @($_.evidence.Addresses) } })
            $arcAvailable = @($winRmRecords | Where-Object { $_.evidence.ArcStatus -eq 'Connected' } | ForEach-Object { $_.name })
            $findings = @(Invoke-AzlRemotingPreCheck -Candidate $candidates -Remoting $context.Remoting -Context $context -ArcAvailable $arcAvailable)
            $unreachable = [System.Collections.Generic.List[object]]::new()
            foreach ($f in $findings) {
                $r = $records | Where-Object { $_.name -eq $f.Node } | Select-Object -First 1
                if ($f.Reachable) { $r.address = $f.Address; continue }
                if ($context.Remoting.BootstrapTransport -eq 'arc' -and $f.Node -in $arcAvailable -and $f.Result -notin 'NoCredential', 'NoAddress') {
                    $cidrs = @(Get-AzlRemotingAllowedCidr -Infrastructure $infra -RunnerCidr $context.Remoting.AllowedSourceCidrs)
                    if ($cidrs.Count) { $r.bootstrap = [ordered]@{ used = $false; pending = $true; cidrs = $cidrs }; continue }
                }
                $unreachable.Add($f)
            }
            if ($unreachable.Count) { throw (Get-AzlInputError ("PowerShell remoting can't reach $($unreachable.Count) node(s); nothing was changed.$([Environment]::NewLine)$(Format-AzlRemotingFinding -Finding @($unreachable))")) }
        }

        # ISO path: route, credentials, OS
        $pre = [System.Collections.Generic.List[string]]::new()
        foreach ($r in @($records | Where-Object { $_.transport -eq 'WinRM' -and -not $_.bootstrap.Contains('pending') })) {
            $check = Test-AzlIsoPrecondition -Context $context -Record $r
            foreach ($p in $check.Problems) { $pre.Add($p) }
            if ($check.Seen) {
                $r.warnings += "OS: $(Get-AzlProp $check.Seen 'caption' '') build $(Get-AzlProp $check.Seen 'build' '')"
                $r.osCaption = [string](Get-AzlProp $check.Seen 'caption' ''); $r.osBuild = [int](Get-AzlProp $check.Seen 'build' 0)
            }
            if ($check.Problems.Count) { Send-AzlRunEvent -Context $context -State NodeFailed -Record $r -Level Error -Evidence ($check.Problems -join ' ') -NextAction 'Fix what is named, then run the OS configuration again.' }
        }
        if ($pre.Count) { throw (Get-AzlInputError (($pre | ForEach-Object { "- $_" }) -join [Environment]::NewLine)) }

        # ---- 2. plan for ALL nodes
        Write-AzlLine ''
        Write-AzlLine '== Plan: all nodes (read only)'
        $stop = $false
        foreach ($r in $records) {
            if ($stop) { $r.status = 'skipped'; $r.errors += 'Skipped: an earlier node failed and -ContinueOnNodeFailure is off.'; continue }
            Write-AzlLine "-- $($r.name)"
            try { Invoke-AzlPlanPhase -Context $context -Record $r -Node $nodeByName[$r.name] }
            catch { $r.status = 'failed'; $r.errors += "Plan of $($r.name) failed: $($_.Exception.Message)" }
            if ($r.status -ne 'failed') {
                # The node was read: add what it reported (hostname, OS) to the method line, then say what each step found.
                if ($r.hostname -or $r.osVersion) {
                    Send-AzlRunEvent -Context $context -Record $r -State MethodResolved -Level $(if (@($r.methodWarnings).Count) { 'Warning' } else { 'Info' }) -Evidence "Read from the node: computer name '$($r.hostname)', OS $($r.osVersion)$(if ($r.osCaption) { " ($($r.osCaption))" })." -Data (Get-AzlMethodResolvedData -Context $context -Record $r -Resolution ([pscustomobject]@{ Declared = $r.declared; Source = $r.methodSource; Warnings = @($r.methodWarnings) }))
                }
                Send-AzlStepPlanEvent -Context $context -Record $r
            }
            if ($r.status -eq 'failed' -and -not $ContinueOnNodeFailure) { $stop = $true }
        }
        $clusterProblems = @(Test-AzlSanConsistency -Record $records)
        foreach ($r in $records) { $r.converged = ($r.status -eq 'planned' -and $r.pendingChanges -eq 0 -and $r.blocked -eq 0 -and @($r.errors).Count -eq 0) }
        # Plan mode ends here for every node. In Apply mode only a node that is already settled (failed, skipped, nothing to change) is reported now.
        foreach ($r in $records) { if ($Mode -eq 'Plan' -or $r.converged -or $r.status -in 'failed', 'skipped') { Send-AzlNodeOutcomeEvent -Context $context -Record $r -Mode Plan } }
        $wipe = @(Get-AzlWipeList -Record $records)
        $null = Write-AzlOsConfigurationReport -Context $context -Record $records -FileName 'plan-report.json' -ClusterProblem $clusterProblems
        $wipeText = Format-AzlWipeList -WipeList $wipe -ClearStorage $clear -Mode $Mode -Source $clearSource
        Set-Content -LiteralPath (Join-Path $reportDir 'wipe-list.txt') -Value $wipeText -Encoding utf8NoBOM
        $planChanges = [int](@($records | Where-Object { $_.status -ne 'failed' -and $_.status -ne 'skipped' } | ForEach-Object { $_.pendingChanges } | Measure-Object -Sum).Sum)
        $planBlocked = [int](@($records | Where-Object { $_.status -ne 'failed' -and $_.status -ne 'skipped' } | ForEach-Object { $_.blocked } | Measure-Object -Sum).Sum)
        Send-AzlRunEvent -Context $context -State PlanCompleted -Record $null -Level $(if ($planBlocked -or $clusterProblems.Count) { 'Warning' } else { 'Info' }) `
            -Evidence "Plan complete for $($records.Count) node(s): $planChanges change(s) pending, $planBlocked blocked. Nothing was changed.$(if ($clusterProblems.Count) { ' ' + ($clusterProblems -join ' ') })" `
            -NextAction $(if ($Mode -eq 'Plan') { 'Review the plan and the wipe list; apply with -Mode Apply.' } else { 'Applying node by node.' }) -Data @{ changes = $planChanges; blocked = $planBlocked; mode = $Mode }
        Send-AzlRunEvent -Context $context -State WipeListPublished -Record $null -Level $(if ($wipe.Count) { 'Warning' } else { 'Info' }) `
            -Evidence $(if (-not $clear) { 'Storage wipe is off (os_configuration.clear_storage is false): nothing will be wiped.' } elseif ($wipe.Count -eq 0) { 'Storage wipe is on and no leftover local storage was found: nothing to wipe.' } else { "$($wipe.Count) node(s) have local disks that $(if ($Mode -eq 'Apply') { 'WILL BE WIPED NOW' } else { 'WOULD BE WIPED if you apply' }): $((@($wipe | ForEach-Object { "$($_.Node): $($_.Disks)" })) -join ' | ')" }) `
            -NextAction $(if ($wipe.Count -and $Mode -eq 'Plan') { 'Check the disks listed in wipe-list.txt before you apply.' } else { '' }) `
            -Data @{ wipeCount = $wipe.Count; clearStorage = [bool]$clear; wipe = @($wipe | ForEach-Object { [ordered]@{ node = $_.Node; disks = $_.Disks } }) }
        Write-AzlLine ''
        foreach ($r in $records) {
            $show = @($r.plan | Where-Object { $_.Action -ne 'Ok' })
            if ($show.Count) { Write-AzlLine (Format-AzlPlan -Plan $show) }
            foreach ($e in $r.errors) { Write-Warning $e }
        }
        Write-AzlLine $wipeText

        # ---- 3. apply
        if ($Mode -eq 'Apply') {
            Write-AzlLine ''
            Write-AzlLine '== Apply: node by node'
            $stop = $false
            foreach ($r in $records) {
                if ($r.status -eq 'skipped') { continue }
                if ($stop) { $r.status = 'skipped'; $r.errors += 'Skipped: an earlier node failed and -ContinueOnNodeFailure is off.'; continue }
                if ($r.status -eq 'failed') { if (-not $ContinueOnNodeFailure) { $stop = $true }; continue }
                if ($r.pendingChanges -eq 0 -and $r.blocked -eq 0) { Write-AzlLine "-- $($r.name): nothing to change"; $r.converged = (@($r.errors).Count -eq 0); continue }
                Write-AzlLine "-- $($r.name): applying $($r.pendingChanges) change(s)"
                try { Invoke-AzlApplyPhase -Context $context -Record $r -Node $nodeByName[$r.name] }
                catch { $r.errors += "Apply of $($r.name) failed: $($_.Exception.Message)" }
                if (@($r.errors).Count -and -not $ContinueOnNodeFailure) { $stop = $true }
            }

            # ---- 4. verify: a Plan pass proves convergence
            Write-AzlLine ''
            Write-AzlLine '== Verify: a Plan pass per changed node'
            foreach ($r in $records) {
                if ($r.status -ne 'applied') { continue }
                Write-AzlLine "-- $($r.name)"
                $before = @($r.errors).Count
                Resolve-AzlWinRmAddress -Context $context -Record $r -Node $nodeByName[$r.name]
                $r.verification = @()
                try { Invoke-AzlPlanPhase -Context $context -Record $r -Node $nodeByName[$r.name] -Phase Verify }
                catch { $r.status = 'failed'; $r.errors += "Verification of $($r.name) failed: $($_.Exception.Message)" }
                if ($r.status -ne 'failed') { Send-AzlStepVerifiedEvent -Context $context -Record $r }
                $verifyErrors = @(@($r.errors) | Select-Object -Skip $before)
                $r.converged = ($r.status -ne 'failed' -and $r.pendingChanges -eq 0 -and $r.blocked -eq 0 -and $verifyErrors.Count -eq 0)
                if ($r.converged -and $before -gt 0) { $r.warnings += "Recovered: the verification pass found nothing left to change although a step reported an error (errors kept in the report)." }
                if (-not $r.converged -and $r.status -ne 'failed') { $r.status = 'applied' }
                Write-AzlLine "   $($r.name): $(if ($r.converged) { 'converged' } else { "NOT converged ($($r.pendingChanges) change(s) left, $($r.blocked) blocked)" })"
            }
            $clusterProblems = @(Test-AzlSanConsistency -Record $records)
            foreach ($r in $records) { Send-AzlNodeOutcomeEvent -Context $context -Record $r -Mode Apply }
        }
        foreach ($p in $clusterProblems) { Write-Warning $p }

        # ---- 5. report
        $exit = Get-AzlOsConfigurationExitCode -Record $records -ClusterProblem $clusterProblems -Mode $Mode -FailOnPendingChanges:$failOnPending
        $reportPath = Write-AzlOsConfigurationReport -Context $context -Record $records -FileName 'report.json' -ClusterProblem $clusterProblems -ExitCode $exit
        $summary = Format-AzlOsConfigurationSummary -Record $records -Mode $Mode -ExitCode $exit
        $convergedCount = @($records | Where-Object { $_.converged }).Count
        Send-AzlRunEvent -Context $context -State RunCompleted -Record $null -Level $(if ($exit -eq 0) { 'Info' } else { 'Error' }) `
            -Evidence "OS configuration run finished with exit code ${exit}: $convergedCount of $($records.Count) node(s) converged$(if ($Mode -eq 'Plan') { ' (plan only, nothing was changed)' })." `
            -NextAction $(if ($exit -eq 0) { '' } else { 'Read the NodeFailed and NodeBlocked events, fix the cause, and run again; finished steps are not repeated.' }) `
            -Data @{ exitCode = $exit; converged = $convergedCount; total = $records.Count; mode = $Mode }
        $markdown = (Format-AzlOsConfigurationSummary -Record $records -Mode $Mode -ExitCode $exit -Markdown) + [Environment]::NewLine + [Environment]::NewLine + '```' + [Environment]::NewLine + $wipeText + [Environment]::NewLine + '```'
        Set-Content -LiteralPath (Join-Path $reportDir 'summary.md') -Value $markdown -Encoding utf8NoBOM
        Write-AzlLine ''
        Write-AzlLine $summary
        Write-AzlLine "Report: $reportPath"
        return [pscustomobject]@{ ExitCode = $exit; Records = $records.ToArray(); ReportPath = $reportPath; ReportDirectory = $reportDir; Summary = $summary; WipeList = $wipe; Message = '' }
    }
    catch {
        $isInput = [bool]$_.Exception.Data['AzlInput']
        $message = $_.Exception.Message
        Write-AzlLine ''
        Write-AzlLine "$(if ($isInput) { 'BAD INPUT' } else { 'FAILED' }): $message"
        if ($context) {
            try {
                $null = Write-AzlOsConfigurationReport -Context $context -Record @($records) -FileName 'report.json' -ExitCode $(if ($isInput) { 2 } else { 1 }) -Message $message
            }
            catch { Write-Verbose "Couldn't write the report: $($_.Exception.Message)" }
            Send-AzlRunEvent -Context $context -State RunCompleted -Record $null -Level Error -Evidence "OS configuration run stopped with exit code $(if ($isInput) { 2 } else { 1 }) ($(if ($isInput) { 'bad input' } else { 'failed' })): $message" `
                -NextAction $(if ($isInput) { 'Fix the input named in the message; nothing was changed.' } else { 'Read the error and run again.' }) `
                -Data @{ exitCode = $(if ($isInput) { 2 } else { 1 }); converged = @($records | Where-Object { $_.converged }).Count; total = @($records).Count }
        }
        return [pscustomobject]@{ ExitCode = $(if ($isInput) { 2 } else { 1 }); Records = @($records); ReportPath = ''; ReportDirectory = ''; Summary = ''; WipeList = @(); Message = $message }
    }
}

Export-ModuleMember -Function Get-AzlHandoffFile, Merge-AzlHandoff, Find-AzlMergedHandoff, Resolve-AzlNodeMethod, Get-AzlNodeStepList, Get-AzlNodeEvidence, Get-AzlRunSetting, Get-AzlWipeList, Format-AzlWipeList, Get-AzlOsConfigurationExitCode, Format-AzlOsConfigurationSummary, Test-AzlIsoPrecondition, Invoke-AzlOsConfiguration
