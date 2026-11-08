#Requires -Version 7.0
<#
.SYNOPSIS
    How OS configuration reaches a node: one transport interface, two implementations.

.DESCRIPTION
    A transport is an object with:
      Kind        'ArcRunCommand' or 'WinRM'
      Invoke      { param($Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds) }
                  runs a node script and returns Output (the text it wrote), Failed, Error.
      Stage       { param($Node, [string]$LocalPath, [string]$RemotePath, [string]$Sha256) }
                  puts a file on the node.
    Everything above this layer (the plan, the actions, the restart wait) uses only Invoke-AzlNodeScript and
    Send-AzlNodeFile, so a test passes a fake transport and no node is touched.

    ArcRunCommand  Microsoft.HybridCompute/machines/{name}/runCommands. The operator host has no network path to the
                   nodes' management subnet, but the Connected Machine agent on each node calls out to Azure, so the
                   script goes through ARM. Needs the Arc machine's resource ID (handoff, or found by name). Secrets go
                   in protectedParameters. It can't carry a file: Stage throws. The SBE package reaches a node by
                   hardware.sbe.delivery (node_pull: the node downloads it; winrm_copy: a WinRM transport copies it).
    WinRM          New-PSSession to the node. For a host that can reach the management subnet. A file is copied with
                   Copy-Item -ToSession to a .part file, its SHA-256 is checked on the node, and it is renamed.

    The run command resource is created, polled until the script finishes, read, and deleted. The runCommands api-version
    (2026-09-01) is the newest generally available one on Microsoft Learn.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunCommandApiVersion = '2026-09-01'
$script:ResultPrefix = 'AZLRESULT:'
$script:RetryPolicy = @{ Tries = 3; DelaySeconds = @(15, 45, 120) }

Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))

function ConvertTo-AzlNodeResult {
    <#
    .SYNOPSIS
        Decodes the AZLRESULT line a node script wrote (base64 of gzip of JSON) into an object. $null when there is none.
    .EXAMPLE
        ConvertTo-AzlNodeResult -Text $run.Output
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $line = @($Text -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith($script:ResultPrefix) }) | Select-Object -Last 1
    if (-not $line) { return $null }
    $b64 = $line.Trim().Substring($script:ResultPrefix.Length)
    $in = [System.IO.MemoryStream]::new([Convert]::FromBase64String($b64))
    $gz = [System.IO.Compression.GZipStream]::new($in, [System.IO.Compression.CompressionMode]::Decompress)
    $reader = [System.IO.StreamReader]::new($gz, [System.Text.Encoding]::UTF8)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json -Depth 20) }
    finally { $reader.Dispose(); $gz.Dispose(); $in.Dispose() }
}

function ConvertTo-AzlB64Json {
    # A hashtable as the base64 JSON a node script takes in ParamsB64 or SecretsB64.
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $json = $Value | ConvertTo-Json -Depth 20 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Set-AzlTransportHeartbeat {
    <#
    .SYNOPSIS
        Gives a transport a heartbeat (New-AzlWaitHeartbeat of AzlGuardedChange.psm1): every wait inside a call to a node ticks it, so the event feed shows a
        sign of life every 60 seconds. A transport without a State (a fake in a test) is left alone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Transport, [AllowNull()][object]$Heartbeat)
    if (-not $Transport.PSObject.Properties['State'] -or $Transport.State -isnot [hashtable]) { return }
    if ($PSCmdlet.ShouldProcess($Transport.Kind, 'Set the heartbeat')) { $Transport.State['Heartbeat'] = $Heartbeat }
}

function Send-AzlTransportHeartbeat {
    # Begin, Tick or End of the transport's heartbeat, when it has one. Never throws: a heartbeat must not break a call.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][ValidateSet('Begin', 'Tick', 'End')][string]$Action, [string]$Text = '', [string]$Phase = '')
    if (-not $Transport.PSObject.Properties['State'] -or $Transport.State -isnot [hashtable] -or -not $Transport.State.ContainsKey('Heartbeat')) { return }
    $hb = $Transport.State['Heartbeat']
    if (-not $hb) { return }
    try {
        switch ($Action) {
            'Begin' { & $hb.Begin $hb $Text }
            'Tick' { & $hb.Tick $hb $Text $Phase }
            'End' { & $hb.End $hb }
        }
    }
    catch { Write-Verbose "Heartbeat skipped: $($_.Exception.Message)" }
}

function Wait-AzlNodeJob {
    <#
    .SYNOPSIS
        Waits for the job of one WinRM call in slices of a few seconds, ticking the heartbeat between slices, and gives up after the cap. $true: the job
        finished. $false: the cap passed (the caller abandons the job and drops the session).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object]$Job, [Parameter(Mandatory)][int]$CapSeconds, [Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][string]$Node, [int]$SliceSeconds = 5)
    $waited = 0
    Send-AzlTransportHeartbeat -Transport $Transport -Action Begin -Text "a call to $Node"
    try {
        while ($true) {
            if (Wait-Job -Job $Job -Timeout $SliceSeconds) { return $true }
            $waited += $SliceSeconds
            if ($waited -ge $CapSeconds) { return $false }
            Send-AzlTransportHeartbeat -Transport $Transport -Action Tick -Text "a call to $Node"
        }
    }
    finally { Send-AzlTransportHeartbeat -Transport $Transport -Action End }
}

function New-AzlArcRunCommandTransport {
    <#
    .SYNOPSIS
        A transport that runs node scripts through Azure Arc Run Command.
    .PARAMETER ArcResourceId
        Hashtable: node name -> the Arc machine's resource ID.
    .PARAMETER PollSeconds
        How often the run command is read while its script runs.
    .EXAMPLE
        New-AzlArcRunCommandTransport -ArcResourceId @{ 'node-01' = $arcId }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory transport object; changes no system state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Every transport script block takes the same (Self, Node, ...) signature; a block that has no use for one of them still declares it.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ArcResourceId,
        [int]$PollSeconds = 15,
        [string]$ApiVersion = $script:RunCommandApiVersion
    )
    # The scriptblocks are not closures: they stay bound to this module (so its commands resolve, and a test can mock them)
    # and take the transport as $Self, which carries the settings in State.
    [pscustomobject]@{
        Kind   = 'ArcRunCommand'
        Machine = {
            param($Self, $Node)
            $s = $Self.State
            $m = Invoke-AzlArm -Method GET -Path $s.Ids[$Node] -ApiVersion '2024-07-10' -AllowNotFound
            if (-not $m) { return [pscustomobject]@{ Found = $false; Status = ''; LastStatusChange = $null } }
            $changed = Get-AzlProp $m 'properties.lastStatusChange' $null
            if ($changed -and $changed -isnot [datetime]) { $changed = [datetime]::Parse([string]$changed, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) }
            [pscustomobject]@{ Found = $true; Status = [string](Get-AzlProp $m 'properties.status' ''); LastStatusChange = $(if ($changed) { $changed.ToUniversalTime() } else { $null }) }
        }
        ListRunCommands = {
            param($Self, $Node)
            $s = $Self.State
            $list = Invoke-AzlArm -Method GET -Path "$($s.Ids[$Node])/runCommands" -ApiVersion $s.Api -AllowNotFound
            foreach ($rc in @(Get-AzlProp $list 'value' @())) {
                $created = Get-AzlProp $rc 'systemData.createdAt' (Get-AzlProp $rc 'properties.instanceView.startTime' $null)
                if ($created -and $created -isnot [datetime]) { $created = [datetime]::Parse([string]$created, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) }
                [pscustomobject]@{
                    Name              = [string](Get-AzlProp $rc 'name' '')
                    ProvisioningState = [string](Get-AzlProp $rc 'properties.provisioningState' '')
                    ExecutionState    = [string](Get-AzlProp $rc 'properties.instanceView.executionState' '')
                    CreatedUtc        = $(if ($created) { $created.ToUniversalTime() } else { $null })
                }
            }
        }
        DeleteRunCommand = {
            param($Self, $Node, [string]$Name)
            $s = $Self.State
            $null = Invoke-AzlArm -Method DELETE -Path "$($s.Ids[$Node])/runCommands/$Name" -ApiVersion $s.Api -AllowNotFound
        }
        State  = @{ Ids = $ArcResourceId; Poll = $PollSeconds; Api = $ApiVersion }
        Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            $s = $Self.State
            if (-not $s.Ids.ContainsKey($Node)) { throw "No Arc machine resource ID for node $Node. Give one in the handoff file, or let it be found by name." }
            $machine = $s.Ids[$Node]
            $name = 'azl-osconfig-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 16)
            $path = "$machine/runCommands/$name"
            $location = [string](Get-AzlProp (Invoke-AzlArm -Method GET -Path $machine -ApiVersion '2024-07-10') 'location' '')
            $properties = @{
                source           = @{ script = $Script }
                timeoutInSeconds = $TimeoutSeconds
                asyncExecution   = $false
                parameters       = @(@{ name = 'ParamsB64'; value = (ConvertTo-AzlB64Json $Parameters) })
            }
            if ($Secrets -and $Secrets.Count -gt 0) { $properties.protectedParameters = @(@{ name = 'SecretsB64'; value = (ConvertTo-AzlB64Json $Secrets) }) }
            $null = Invoke-AzlArm -Method PUT -Path $path -ApiVersion $s.Api -Body @{ location = $location; properties = $properties }
            try {
                $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 300)
                $terminal = @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
                $unknownPolls = 0
                Send-AzlTransportHeartbeat -Transport $Self -Action Begin -Text "the run command on $Node"
                do {
                    Start-Sleep -Seconds $s.Poll
                    Send-AzlTransportHeartbeat -Transport $Self -Action Tick -Text "the run command on $Node"
                    $run = Invoke-AzlArm -Method GET -Path $path -ApiVersion $s.Api
                    $state = [string](Get-AzlProp $run 'properties.instanceView.executionState' '')
                    $provisioning = [string](Get-AzlProp $run 'properties.provisioningState' '')
                    # Azure lost the run: it finished provisioning but the node never reported a state (twice in a row, so a run that is just starting isn't mistaken for it).
                    $unknownPolls = if ($state -eq 'Unknown' -and $provisioning -eq 'Succeeded') { $unknownPolls + 1 } else { 0 }
                } while ($state -notin $terminal -and $provisioning -ne 'Failed' -and $unknownPolls -lt 2 -and (Get-Date) -lt $deadline)
                $exit = Get-AzlProp $run 'properties.instanceView.exitCode' $null
                [pscustomobject]@{
                    Output = [string](Get-AzlProp $run 'properties.instanceView.output' '')
                    Error  = [string](Get-AzlProp $run 'properties.instanceView.error' '')
                    Failed = ($state -ne 'Succeeded' -or ($null -ne $exit -and [int]$exit -ne 0))
                    State  = $state
                }
            }
            finally {
                Send-AzlTransportHeartbeat -Transport $Self -Action End
                try { $null = Invoke-AzlArm -Method DELETE -Path $path -ApiVersion $s.Api -AllowNotFound }
                catch { Write-Warning "Couldn't delete run command ${name} on ${Node}: $($_.Exception.Message)" }
            }
        }
        Stage  = {
            param($Self, $Node, [string]$LocalPath, [string]$RemotePath, [string]$Sha256)
            throw "File $([IO.Path]::GetFileName($LocalPath)) has to reach $Node, and Azure Arc Run Command can't carry a file. Set hardware.sbe.delivery to node_pull (the node downloads it) or winrm_copy (copied over WinRM from a host that reaches the node)."
        }
    }
}

function Get-AzlWinRmSession {
    param([hashtable]$State, [string]$Node)
    if (-not $State.Addresses.ContainsKey($Node)) { throw "No address for node $Node." }
    if ($State.Sessions.ContainsKey($Node) -and $State.Sessions[$Node].State -eq 'Opened') { return $State.Sessions[$Node] }
    $arguments = @{ ComputerName = $State.Addresses[$Node]; Credential = $State.Credential; Authentication = $State.Authentication; UseSSL = $State.Ssl; Port = $State.Port }
    if ($State.SkipCertificateCheck) { $arguments.SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck }
    $State.Sessions[$Node] = New-PSSession @arguments
    return $State.Sessions[$Node]
}

function New-AzlWinRmTransport {
    <#
    .SYNOPSIS
        A transport that runs node scripts over WinRM, for a host that can reach the nodes' management subnet.
    .PARAMETER Address
        Hashtable: node name -> the address or DNS name to connect to.
    .PARAMETER Credential
        The node's local administrator (<node>\<user> or a domain account).
    .EXAMPLE
        New-AzlWinRmTransport -Address @{ 'node-01' = '192.0.2.11' } -Credential (Get-Credential)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The inner script block declares its own param() and receives values through -ArgumentList.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory transport object; changes no system state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Every transport script block takes the same (Self, Node, ...) signature; a block that has no use for one of them still declares it.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$UseSsl,
        [ValidateSet('Default', 'Negotiate', 'Kerberos', 'Basic', 'CredSSP')][string]$Authentication = 'Negotiate',
        [int]$Port = 0,
        [switch]$SkipCertificateCheck
    )
    [pscustomobject]@{
        Kind   = 'WinRM'
        GetAddress = { param($Self, $Node) $Self.State.Addresses[$Node] }
        GetPort = { param($Self, $Node) $Self.State.Port }
        SetAddress = {
            param($Self, $Node, [string]$Address)
            $Self.State.Addresses[$Node] = $Address
            if ($Self.State.Sessions.ContainsKey($Node)) { Remove-PSSession -Session $Self.State.Sessions[$Node] -ErrorAction SilentlyContinue; $Self.State.Sessions.Remove($Node) }
        }
        CloseSession = {
            param($Self, $Node)
            if ($Self.State.Sessions.ContainsKey($Node)) { Remove-PSSession -Session $Self.State.Sessions[$Node] -ErrorAction SilentlyContinue; $Self.State.Sessions.Remove($Node) }
        }
        State  = @{ Addresses = $Address; Credential = $Credential; Ssl = [bool]$UseSsl; Authentication = $Authentication; Port = $(if ($Port -gt 0) { $Port } elseif ($UseSsl) { 5986 } else { 5985 }); SkipCertificateCheck = [bool]$SkipCertificateCheck; Sessions = @{} }
        Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            $session = Get-AzlWinRmSession -State $Self.State -Node $Node
            $p = ConvertTo-AzlB64Json $Parameters
            $q = ConvertTo-AzlB64Json $Secrets
            try {
                # The payload runs as a FILE on the node, never as a scriptblock: a script file has a script scope of its own, and a scriptblock created from text does
                # not, so a payload written for a file would come back empty. The file is created inside the session (UTF-8 with a byte-order mark, readable by SYSTEM and
                # Administrators only), run with the call operator in the same session (no child process, so no secret is on a command line) and removed in finally.
                # A hard cap: the call runs as a job and is abandoned after $TimeoutSeconds (plus a short grace), so one stalled WinRM call (a network change under
                # an open session does it) can never hang the whole run. The session is dropped so the next call opens a new one.
                $cap = [Math]::Max(30, $(if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { 900 })) + 30
                $job = Invoke-Command -Session $session -AsJob -ScriptBlock {
                    param($Text, $ParamsB64, $SecretsB64)
                    $folder = 'C:\ProgramData\AzureLocal\osconfig'
                    $null = New-Item -ItemType Directory -Force -Path $folder
                    try { & icacls.exe $folder /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null } catch { $null = $_ }
                    $file = Join-Path $folder ('run-' + [guid]::NewGuid().ToString('N') + '.ps1')
                    [IO.File]::WriteAllText($file, $Text, (New-Object Text.UTF8Encoding($true)))
                    try {
                        Set-ExecutionPolicy Bypass -Scope Process -Force
                        & $file -ParamsB64 $ParamsB64 -SecretsB64 $SecretsB64
                    }
                    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
                } -ArgumentList $Script, $p, $q
                if (-not (Wait-AzlNodeJob -Job $job -CapSeconds $cap -Transport $Self -Node $Node)) {
                    Stop-Job -Job $job -ErrorAction SilentlyContinue
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                    if ($Self.State.Sessions.ContainsKey($Node)) { Remove-PSSession -Session $Self.State.Sessions[$Node] -ErrorAction SilentlyContinue; $Self.State.Sessions.Remove($Node) }
                    throw "The call to $Node did not finish within $cap seconds and was abandoned."
                }
                try { $output = Receive-Job -Job $job -ErrorAction Stop } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
                [pscustomobject]@{ Output = ($output -join [Environment]::NewLine); Error = ''; Failed = $false; State = 'Succeeded' }
            }
            catch { [pscustomobject]@{ Output = ''; Error = $_.Exception.Message; Failed = $true; State = 'Failed' } }
        }
        Stage  = {
            param($Self, $Node, [string]$LocalPath, [string]$RemotePath, [string]$Sha256)
            $session = Get-AzlWinRmSession -State $Self.State -Node $Node
            $part = "$RemotePath.part"
            Invoke-Command -Session $session -ScriptBlock { param($Folder, $Part) New-Item -ItemType Directory -Force -Path $Folder | Out-Null; if (Test-Path -LiteralPath $Part) { Remove-Item -LiteralPath $Part -Force } } -ArgumentList $RemotePath.Substring(0, [Math]::Max(0, $RemotePath.LastIndexOf([char]92))), $part
            Copy-Item -LiteralPath $LocalPath -Destination $part -ToSession $session -Force
            # The copy lands in a .part file; it takes its name only after its SHA-256 is what the toolkit expects.
            $verdict = Invoke-Command -Session $session -ScriptBlock {
                param($Part, $Final, $Want)
                $hash = (Get-FileHash -LiteralPath $Part -Algorithm SHA256).Hash
                if ($Want -and $hash -ine $Want) { Remove-Item -LiteralPath $Part -Force; return "SHA-256 is $hash, expected $Want" }
                if (Test-Path -LiteralPath $Final) { Remove-Item -LiteralPath $Final -Force }
                Move-Item -LiteralPath $Part -Destination $Final
                return 'ok'
            } -ArgumentList $part, $RemotePath, $Sha256
            if ($verdict -ne 'ok') { throw "$([IO.Path]::GetFileName($LocalPath)) copied to $Node but $verdict; the copy was removed." }
            [pscustomobject]@{ Name = [IO.Path]::GetFileName($LocalPath); Url = $null }
        }
    }
}

function Set-AzlNodeRetryPolicy {
    <#
    .SYNOPSIS
        How many times a node script is tried when its Arc run command ends in state 'Unknown', and how long to wait between tries.
    .DESCRIPTION
        State Unknown means Azure lost track of the run: the node's agent briefly lost its connection (a network change on the
        node does it). The script may or may not have run, so Invoke-AzlNodeScript runs it again after a pause that grows
        (-DelaySeconds, the last value repeats). The scripts are safe to run again: every action checks the item before it
        changes it. After the last try the error carries Data['AzlState'] = 'Unknown'; Invoke-AzlNodeConfiguration then reads the
        node and decides from what it sees, not from the failed command's status.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([ValidateRange(1, 10)][int]$Tries = 3, [int[]]$DelaySeconds = @(15, 45, 120))
    if ($PSCmdlet.ShouldProcess('node script retry policy', 'Set')) { $script:RetryPolicy = @{ Tries = $Tries; DelaySeconds = @($DelaySeconds) } }
}

function Invoke-AzlNodeScript {
    <#
    .SYNOPSIS
        Runs a node script on a node through a transport and returns the decoded result object.
    .DESCRIPTION
        Throws when the script failed or wrote no result. -Secrets never appear in the returned object or the messages.
        A run that ends in state 'Unknown' without a result is tried again (Set-AzlNodeRetryPolicy; default 3 tries with a growing
        pause). -Tries overrides the policy for one call (a restart script uses 1: the node is meant to go away).
    .EXAMPLE
        Invoke-AzlNodeScript -Transport $t -Node node-01 -Script (Get-AzlNodePayload Read) -Parameters @{ san = $false }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transport,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$Parameters = @{},
        [hashtable]$Secrets = @{},
        [int]$TimeoutSeconds = 900,
        [ValidateRange(1, 10)][int]$Tries
    )
    $maxTries = if ($PSBoundParameters.ContainsKey('Tries')) { $Tries } else { [int]$script:RetryPolicy.Tries }
    $attempt = 0
    while ($true) {
        $attempt++
        $run = & $Transport.Invoke $Transport $Node $Script $Parameters $Secrets $TimeoutSeconds
        $result = ConvertTo-AzlNodeResult -Text $run.Output
        if ($result) {
            # A Read answers with the sections nics, remote and time. All empty is not a node with nothing: the read gave nothing back.
            $names = @($result.PSObject.Properties.Name)
            if ('nics' -in $names -and 'remote' -in $names -and 'time' -in $names -and @($result.nics).Count -eq 0 -and $null -eq $result.remote -and $null -eq $result.time) {
                $why = if ($result.PSObject.Properties['err'] -and $result.err) { ($result.err.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join '; ' } else { 'no reason was recorded' }
                throw "The node read returned no data on ${Node} through $($Transport.Kind) (no adapters, no remote management state, no time state; $why). Not planning against nothing. Check that the payload ran as a script file and that the session is elevated."
            }
            return $result
        }
        $unknown = $run.Failed -and ([string]$run.State -eq 'Unknown')
        if ($unknown -and $attempt -lt $maxTries) {
            $delays = @($script:RetryPolicy.DelaySeconds)
            $wait = if ($delays.Count) { [int]$delays[[Math]::Min($attempt - 1, $delays.Count - 1)] } else { 0 }
            Write-Warning "${Node}: the run command ended in state Unknown (try $attempt of $maxTries; the node's agent may have lost its connection). Trying again in $wait s."
            if ($wait -gt 0) { Start-Sleep -Seconds $wait }
            continue
        }
        if ($unknown) {
            $exception = [System.InvalidOperationException]::new("The script on $Node through $($Transport.Kind) ended in state Unknown after $attempt tries: Azure lost the run (the node's agent lost its connection?). Read the node again to see what happened.")
            $exception.Data['AzlState'] = 'Unknown'
            throw $exception
        }
        if ($run.Failed) {
            $detail = if ($run.Error) { $run.Error } else { "state $($run.State)" }
            throw "The script failed on ${Node} through $($Transport.Kind): $detail"
        }
        throw "The script on $Node through $($Transport.Kind) wrote no result. Output: $($run.Output)"
    }
}
function Send-AzlNodeFile {
    <#
    .SYNOPSIS
        Puts a file on a node through its transport (the WinRM transport only; the Arc transport throws, it can't carry a
        file). The file's SHA-256 is checked on the node. Returns the staging record (Name).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][string]$LocalPath, [Parameter(Mandatory)][string]$RemotePath, [string]$Sha256)
    & $Transport.Stage $Transport $Node $LocalPath $RemotePath $Sha256
}

function Test-AzlTransportMember {
    # Optional abilities of a transport (a fake in a test may have none): $true when the transport has this member.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][string]$Name)
    return [bool]($Transport.PSObject.Properties[$Name] -and $Transport.$Name)
}

function ConvertTo-AzlPortResult {
    # Classifies a finished (or unfinished) TCP connect: Open, Closed (the host refused), NoRoute, TimedOut or Error.
    param([System.Threading.Tasks.Task]$Task, [bool]$Connected)
    if ($Connected) { return [pscustomobject]@{ Open = $true; Reason = 'Open'; Detail = 'the port accepted a connection' } }
    if (-not $Task.IsCompleted) { return [pscustomobject]@{ Open = $false; Reason = 'TimedOut'; Detail = 'no answer before the timeout (a firewall dropping the packets, no route, or the host is down)' } }
    $inner = $Task.Exception
    while ($inner -is [System.AggregateException] -and $inner.InnerException) { $inner = $inner.InnerException }
    if ($inner -is [System.Net.Sockets.SocketException]) {
        switch ($inner.SocketErrorCode) {
            'ConnectionRefused' { return [pscustomobject]@{ Open = $false; Reason = 'Closed'; Detail = 'the host answered and refused: nothing listens on the port, or a firewall rejects it' } }
            { $_ -in 'NetworkUnreachable', 'HostUnreachable' } { return [pscustomobject]@{ Open = $false; Reason = 'NoRoute'; Detail = "no route to the host ($($inner.SocketErrorCode))" } }
            'TimedOut' { return [pscustomobject]@{ Open = $false; Reason = 'TimedOut'; Detail = 'the connection attempt timed out' } }
        }
    }
    $message = if ($inner) { $inner.Message } else { 'the connection failed' }
    return [pscustomobject]@{ Open = $false; Reason = 'Error'; Detail = $message }
}

function Test-AzlTcpPort {
    <#
    .SYNOPSIS
        Does the address accept a TCP connection on the port? Open, or the reason it didn't (Closed, NoRoute, TimedOut, Error).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMilliseconds = 4000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Address, $Port)
        $done = $false
        try { $done = $task.Wait($TimeoutMilliseconds) } catch { $done = $true }
        return (ConvertTo-AzlPortResult -Task $task -Connected ($done -and $client.Connected))
    }
    catch { return [pscustomobject]@{ Open = $false; Reason = 'Error'; Detail = $_.Exception.Message } }
    finally { $client.Dispose() }
}

function Get-AzlRemotingDiagnosis {
    <#
    .SYNOPSIS
        The sentence that says why a node can't be reached with PowerShell remoting and what to do next. Pure.
    #>
    [CmdletBinding()]
    param([string]$Reason, [string]$Address, [int]$Port, [bool]$HasCredential = $true, [string]$Detail = '', [bool]$ArcAvailable = $false)
    $where = "${Address}:$Port"
    $firewall = "The node's Windows Firewall remote-management rules (WinRM-In, RDP, echo) are limited to the local subnet by default, so a runner or jump server on another subnet is blocked until the RemoteManagement step opens them. Run once with -Settings @{ remoting = @{ bootstrapTransport = 'arc' } } (the node needs a Connected Arc machine), or open WinRM-In for the runner's CIDR by another means (console, GPO, an earlier script)."
    $text = switch ($Reason) {
        'Open' { if (-not $HasCredential) { "$where answers, but no credential is available. Pass -Credential, or make identity.local_admin.password readable from the Key Vault (Key Vault Secrets User on the secret)." } else { '' } }
        'Closed' { "$where refuses the connection ($Detail). The host is up and reachable; WinRM is not listening on that port or a rule rejects it. $firewall For HTTPS (5986) a listener with a certificate must exist; for HTTP check Enable-PSRemoting ran." }
        'TimedOut' { "$where gave no answer ($Detail). There is no route from this host, a firewall drops the traffic, or the node is off. Check the route to $Address, the network firewalls and ACLs for TCP $Port. $firewall" }
        'NoRoute' { "No route from this host to $Address ($Detail). The runner or jump server must have a route to the nodes' management network; check routing, VPN or the runner's network." }
        default { "$where could not be tested: $Detail. Check the address in the file (nodes[].management.ip_address) and the DNS name." }
    }
    if ($Reason -ne 'Open' -and -not $HasCredential) { $text += ' No credential is available either: pass -Credential or make identity.local_admin.password readable from the vault.' }
    if ($Reason -ne 'Open') { $text += ' Over WinRM from a Linux runner the Negotiate or Kerberos authentication needs PSWSMan; for a workgroup node set TrustedHosts or use WinRM over HTTPS (5986, -UseSsl).' }
    if ($ArcAvailable -and $Reason -ne 'Open') { $text += ' This node has a Connected Arc machine, so the bootstrap option can open the firewall.' }
    return $text.Trim()
}

function Test-AzlNodeConnectivity {
    <#
    .SYNOPSIS
        The pre-check: can every node be reached with PowerShell remoting? All nodes and all candidate addresses are probed at the same
        time; one row per node says which address answers (BestAddress) or why none does.
    .PARAMETER Node
        Objects with Name, Addresses (candidates in the order to try) and Port.
    .PARAMETER Probe
        Replaces the real probe (a test): a scriptblock taking (Address, Port) and returning an object with Open, Reason and Detail.
    .OUTPUTS
        Node, Reachable, BestAddress, Port, Result (Open|Closed|NoRoute|TimedOut|Error|NoAddress), Detail, Tried.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Node, [scriptblock]$Probe, [int]$TimeoutMilliseconds = 4000)
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $Node) { foreach ($a in @($n.Addresses | Where-Object { $_ })) { $pairs.Add([pscustomobject]@{ Node = $n.Name; Address = [string]$a; Port = [int]$n.Port; Result = $null; Client = $null; Task = $null }) } }
    if ($Probe) { foreach ($pair in $pairs) { $pair.Result = & $Probe $pair.Address $pair.Port } }
    else {
        foreach ($pair in $pairs) {
            $pair.Client = [System.Net.Sockets.TcpClient]::new()
            $pair.Task = $pair.Client.ConnectAsync($pair.Address, $pair.Port)
        }
        $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        foreach ($pair in $pairs) {
            $left = [int][math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
            $done = $false
            try { $done = $pair.Task.Wait($left) } catch { $done = $true }
            $pair.Result = ConvertTo-AzlPortResult -Task $pair.Task -Connected ($done -and $pair.Client.Connected)
            $pair.Client.Dispose()
        }
    }
    foreach ($n in $Node) {
        $mine = @($pairs | Where-Object { $_.Node -eq $n.Name })
        $open = @($mine | Where-Object { $_.Result.Open } | Select-Object -First 1)
        if ($open.Count) { [pscustomobject]@{ Node = $n.Name; Reachable = $true; BestAddress = $open[0].Address; Port = [int]$n.Port; Result = 'Open'; Detail = $open[0].Result.Detail; Tried = @($mine | ForEach-Object { $_.Address }) }; continue }
        $first = $mine | Select-Object -First 1
        # A refusal means the host is up: report it in preference to a timeout on another candidate.
        $pick = @($mine | Where-Object { $_.Result.Reason -eq 'Closed' } | Select-Object -First 1)
        if (-not $pick.Count -and $first) { $pick = @($first) }
        if ($pick.Count) { [pscustomobject]@{ Node = $n.Name; Reachable = $false; BestAddress = $pick[0].Address; Port = [int]$n.Port; Result = $pick[0].Result.Reason; Detail = $pick[0].Result.Detail; Tried = @($mine | ForEach-Object { $_.Address }) } }
        else { [pscustomobject]@{ Node = $n.Name; Reachable = $false; BestAddress = ''; Port = [int]$n.Port; Result = 'NoAddress'; Detail = 'no address to try (nodes[].management.ip_address, maintenance_address, or the address from the handoff)'; Tried = @() } }
    }
}

Export-ModuleMember -Function Set-AzlTransportHeartbeat, Send-AzlTransportHeartbeat, Wait-AzlNodeJob, ConvertTo-AzlNodeResult, New-AzlArcRunCommandTransport, New-AzlWinRmTransport, Invoke-AzlNodeScript, Send-AzlNodeFile, Set-AzlNodeRetryPolicy, Test-AzlTransportMember, Test-AzlTcpPort, Get-AzlRemotingDiagnosis, Test-AzlNodeConnectivity
