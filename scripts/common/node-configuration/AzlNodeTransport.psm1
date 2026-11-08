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
                   in protectedParameters. A file is staged through a blob: it is uploaded to a storage account the
                   operator names and the node downloads it with a short-lived read-only SAS.
    WinRM          New-PSSession to the node. For a host that can reach the management subnet. A file is copied with
                   Copy-Item -ToSession.

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

function New-AzlArcRunCommandTransport {
    <#
    .SYNOPSIS
        A transport that runs node scripts through Azure Arc Run Command.
    .PARAMETER ArcResourceId
        Hashtable: node name -> the Arc machine's resource ID.
    .PARAMETER PollSeconds
        How often the run command is read while its script runs.
    .PARAMETER StagingStorageAccount
        Storage account (name) whose container receives files for a node to download. Needed only when a file has to reach
        a node (the SBE package); a node that already holds the right files needs none.
    .PARAMETER StagingContainer
        Container for the files. Default azl-staging.
    .EXAMPLE
        New-AzlArcRunCommandTransport -ArcResourceId @{ 'node-01' = $arcId }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ArcResourceId,
        [int]$PollSeconds = 15,
        [string]$StagingStorageAccount,
        [string]$StagingContainer = 'azl-staging',
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
        State  = @{ Ids = $ArcResourceId; Poll = $PollSeconds; Api = $ApiVersion; Account = $StagingStorageAccount; Container = $StagingContainer; Uploaded = @{} }
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
                do {
                    Start-Sleep -Seconds $s.Poll
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
                try { $null = Invoke-AzlArm -Method DELETE -Path $path -ApiVersion $s.Api -AllowNotFound }
                catch { Write-Warning "Couldn't delete run command ${name} on ${Node}: $($_.Exception.Message)" }
            }
        }
        Stage  = {
            param($Self, $Node, [string]$LocalPath, [string]$RemotePath, [string]$Sha256)
            $s = $Self.State
            if (-not $s.Account) { throw "File $([IO.Path]::GetFileName($LocalPath)) has to reach $Node, and Azure Arc Run Command can't carry a file. Name a staging storage account (-StagingStorageAccount); the node downloads from it with a short-lived read-only SAS." }
            $blob = [IO.Path]::GetFileName($LocalPath)
            if (-not $s.Uploaded.ContainsKey($blob)) {
                $context = New-AzStorageContext -StorageAccountName $s.Account -UseConnectedAccount
                $null = New-AzStorageContainer -Name $s.Container -Context $context -ErrorAction SilentlyContinue
                $null = Set-AzStorageBlobContent -File $LocalPath -Container $s.Container -Blob $blob -Context $context -Force
                $s.Uploaded[$blob] = $context
            }
            $url = New-AzStorageBlobSASToken -Container $s.Container -Blob $blob -Context $s.Uploaded[$blob] -Permission r -ExpiryTime (Get-Date).AddHours(4) -FullUri
            [pscustomobject]@{ Name = $blob; Url = [string]$url }
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
                $output = Invoke-Command -Session $session -ScriptBlock {
                    param($Text, $ParamsB64, $SecretsB64)
                    & ([scriptblock]::Create($Text)) -ParamsB64 $ParamsB64 -SecretsB64 $SecretsB64
                } -ArgumentList $Script, $p, $q
                [pscustomobject]@{ Output = ($output -join [Environment]::NewLine); Error = ''; Failed = $false; State = 'Succeeded' }
            }
            catch { [pscustomobject]@{ Output = ''; Error = $_.Exception.Message; Failed = $true; State = 'Failed' } }
        }
        Stage  = {
            param($Self, $Node, [string]$LocalPath, [string]$RemotePath, [string]$Sha256)
            $session = Get-AzlWinRmSession -State $Self.State -Node $Node
            Invoke-Command -Session $session -ScriptBlock { param($Folder) New-Item -ItemType Directory -Force -Path $Folder | Out-Null } -ArgumentList $RemotePath.Substring(0, [Math]::Max(0, $RemotePath.LastIndexOf([char]92)))
            Copy-Item -LiteralPath $LocalPath -Destination $RemotePath -ToSession $session -Force
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
        if ($result) { return $result }
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
        Puts a file on a node through its transport. Returns the staging record (Name, and Url for the Arc path).
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

Export-ModuleMember -Function ConvertTo-AzlNodeResult, New-AzlArcRunCommandTransport, New-AzlWinRmTransport, Invoke-AzlNodeScript, Send-AzlNodeFile, Set-AzlNodeRetryPolicy, Test-AzlTransportMember, Test-AzlTcpPort, Get-AzlRemotingDiagnosis, Test-AzlNodeConnectivity
