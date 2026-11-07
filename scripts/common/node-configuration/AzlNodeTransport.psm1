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

Import-Module (Join-Path $PSScriptRoot '..\azure-local\AzlAzure.psm1')

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
    .EXAMPLE
        New-AzlArcRunCommandTransport -ArcResourceId @{ 'node-01' = $arcId }
    #>
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
        State  = @{ Ids = $ArcResourceId; Poll = $PollSeconds; Api = $ApiVersion }
        Invoke = {
            param($Self, $Node, [string]$Script, [hashtable]$Parameters, [hashtable]$Secrets, [int]$TimeoutSeconds)
            $s = $Self.State
            if (-not $s.Ids.ContainsKey($Node)) { throw "No Arc machine resource ID for node $Node. Give one in the handoff file, or let it be found by name." }
            $machine = $s.Ids[$Node]
            $name = 'azl-osconfig-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 12)
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
                do {
                    Start-Sleep -Seconds $s.Poll
                    $run = Invoke-AzlArm -Method GET -Path $path -ApiVersion $s.Api
                    $state = [string](Get-AzlProp $run 'properties.instanceView.executionState' '')
                    $provisioning = [string](Get-AzlProp $run 'properties.provisioningState' '')
                } while ($state -notin $terminal -and $provisioning -ne 'Failed' -and (Get-Date) -lt $deadline)
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
            throw "File $([IO.Path]::GetFileName($LocalPath)) has to reach $Node, and Azure Arc Run Command can't carry a file. Set hardware.sbe.delivery to node_pull (the node downloads it) or winrm_copy (copied over WinRM from a host that reaches the node)."
        }
    }
}

function Get-AzlWinRmSession {
    param([hashtable]$State, [string]$Node)
    if (-not $State.Addresses.ContainsKey($Node)) { throw "No address for node $Node." }
    if ($State.Sessions.ContainsKey($Node) -and $State.Sessions[$Node].State -eq 'Opened') { return $State.Sessions[$Node] }
    $State.Sessions[$Node] = New-PSSession -ComputerName $State.Addresses[$Node] -Credential $State.Credential -Authentication Negotiate -UseSSL:$State.Ssl
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
    param([Parameter(Mandatory)][hashtable]$Address, [Parameter(Mandatory)][pscredential]$Credential, [switch]$UseSsl)
    [pscustomobject]@{
        Kind   = 'WinRM'
        State  = @{ Addresses = $Address; Credential = $Credential; Ssl = [bool]$UseSsl; Sessions = @{} }
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
            $part = "$RemotePath.part"
            Invoke-Command -Session $session -ScriptBlock { param($Folder, $Part) New-Item -ItemType Directory -Force -Path $Folder | Out-Null; if (Test-Path -LiteralPath $Part) { Remove-Item -LiteralPath $Part -Force } } -ArgumentList (Split-Path $RemotePath), $part
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

function Invoke-AzlNodeScript {
    <#
    .SYNOPSIS
        Runs a node script on a node through a transport and returns the decoded result object.
    .DESCRIPTION
        Throws when the script failed or wrote no result. -Secrets never appear in the returned object or the messages.
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
        [int]$TimeoutSeconds = 900
    )
    $run = & $Transport.Invoke $Transport $Node $Script $Parameters $Secrets $TimeoutSeconds
    $result = ConvertTo-AzlNodeResult -Text $run.Output
    if ($run.Failed -and -not $result) {
        $detail = if ($run.Error) { $run.Error } else { "state $($run.State)" }
        throw "The script failed on ${Node} through $($Transport.Kind): $detail"
    }
    if (-not $result) { throw "The script on $Node through $($Transport.Kind) wrote no result. Output: $($run.Output)" }
    return $result
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

Export-ModuleMember -Function ConvertTo-AzlNodeResult, New-AzlArcRunCommandTransport, New-AzlWinRmTransport, Invoke-AzlNodeScript, Send-AzlNodeFile
