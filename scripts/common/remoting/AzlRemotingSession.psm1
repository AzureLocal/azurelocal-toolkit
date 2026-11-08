#Requires -Version 7.0
<#
.SYNOPSIS
    The orchestrator side of the remote management profile: the TrustedHosts policy of the machine running the automation, the
    events the profile writes, which WinRM endpoint to use, and what to tell an operator when a node does not answer.

.DESCRIPTION
    This is the single place that touches TrustedHosts. Invoke-AzlWithRemotingSession sets the policy of the profile before the
    run, records the previous value, and restores it in a finally block, so a failed or cancelled run never leaves a wildcard (or
    any entry it added) behind. TrustedHosts is a client-side setting: it does not open a node's firewall and it is machine-wide,
    so concurrent runs on one runner interfere (that is documented; the module does not try to serialise them).

    The store (where TrustedHosts is read and written) is an object with Get and Set script blocks, so a test passes a fake and no
    machine setting changes. The default store is WSMan:\localhost\Client\TrustedHosts on Windows; on another platform the policy is
    reported as not supported and nothing is changed.

    Events (JSON Lines, the contract of the OS configuration event feed): RemotingProfileResolved, RemotingFirewallChange,
    RemotingListenerChange, TrustedHostsChanged, TrustedHostsRestored, RemotingBootstrap. Set-AzlRemotingEventSink points them at
    the run's feed (a script block, or a file path); with neither they are only kept in memory for the report.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EventSink = $null
$script:EventPath = ''
$script:Events = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------------------------------------------------

function Set-AzlRemotingEventSink {
    <#
    .SYNOPSIS
        Where the profile's events go: a script block that takes the event (the run's feed writer), and/or a JSON Lines file path.
        Without either, events are only kept in memory (Get-AzlRemotingEvent).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([scriptblock]$Sink, [string]$Path = '', [switch]$Reset)
    if (-not $PSCmdlet.ShouldProcess('remoting event sink', 'Set')) { return }
    $script:EventSink = $Sink
    $script:EventPath = $Path
    if ($Reset) { $script:Events = [System.Collections.Generic.List[object]]::new() }
}

function Get-AzlRemotingEvent {
    <#
    .SYNOPSIS
        The events written since the sink was last reset, for the report.
    #>
    [CmdletBinding()]
    param()
    return $script:Events.ToArray()
}

function Write-AzlRemotingEvent {
    <#
    .SYNOPSIS
        One event of the remote management profile. Never throws: a sink that fails is reported with Write-Verbose.
    .PARAMETER State
        RemotingProfileResolved, RemotingFirewallChange, RemotingListenerChange, TrustedHostsChanged, TrustedHostsRestored or
        RemotingBootstrap.
    .PARAMETER Data
        Extra fields (class, posture, thumbprint, rules ...). Never a secret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$Node = '*',
        [string]$Evidence = '',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$NextAction = '',
        [System.Collections.IDictionary]$Data
    )
    $entry = [ordered]@{
        timestamp  = [datetime]::UtcNow.ToString('o')
        node       = $Node
        stage      = 'OsConfiguration'
        step       = 'RemoteManagement'
        state      = $State
        evidence   = $Evidence
        level      = $Level
        nextAction = $NextAction
    }
    if ($Data) { foreach ($key in $Data.Keys) { if (-not $entry.Contains([string]$key)) { $entry[[string]$key] = $Data[$key] } } }
    $script:Events.Add([pscustomobject]$entry)
    try {
        if ($script:EventSink) { & $script:EventSink ([pscustomobject]$entry) }
        if ($script:EventPath) {
            $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($script:EventPath))
            if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
            $line = (ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n"
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
            $stream = [System.IO.File]::Open($script:EventPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
    }
    catch { Write-Verbose "Remoting event $State not written: $($_.Exception.Message)" }
}

function Send-AzlRemotingProfileEvent {
    <#
    .SYNOPSIS
        RemotingProfileResolved with the class and the posture (Warning level when the posture is relaxed or the profile has errors).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$RemotingProfile)
    $level = if ($RemotingProfile.Errors.Count) { 'Error' } elseif ($RemotingProfile.Relaxed) { 'Warning' } else { 'Info' }
    $evidence = "class $($RemotingProfile.Class), posture $($RemotingProfile.Posture), WinRM $($RemotingProfile.Transport.Scheme), sources $(@($RemotingProfile.Firewall.RemoteAddress) -join ', ')$(if ($RemotingProfile.Warnings.Count) { '. ' + ($RemotingProfile.Warnings -join ' ') })"
    Write-AzlRemotingEvent -State RemotingProfileResolved -Evidence $evidence -Level $level -Data ([ordered]@{
            class = $RemotingProfile.Class; posture = $RemotingProfile.Posture; classSource = $RemotingProfile.ClassSource; relaxed = $RemotingProfile.Relaxed
            scheme = $RemotingProfile.Transport.Scheme; trustedHosts = $RemotingProfile.TrustedHosts.Mode; remoteAddress = @($RemotingProfile.Firewall.RemoteAddress)
        })
}

# ---------------------------------------------------------------------------------------------------------------------
# TrustedHosts on the machine running the automation
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlTrustedHostsStore {
    <#
    .SYNOPSIS
        The default TrustedHosts store: Get returns the current value (a comma separated string), Set writes one. On a platform
        that has no WSMan client settings (pwsh on Linux) Supported is false and nothing is read or written.
    #>
    [CmdletBinding()]
    param()
    if (-not $IsWindows) {
        return [pscustomobject]@{ Supported = $false; Get = { '' }; Set = { param($Value) $null = $Value } }
    }
    [pscustomobject]@{
        Supported = $true
        # Where the previous and the applied value are kept while this machine's TrustedHosts is changed, so a run that is killed can be undone at the next start.
        StatePath = (Join-Path (Join-Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AzureLocal') 'osconfig') 'trustedhosts-state.json')
        Get       = { try { [string](Get-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value } catch { '' } }
        Set       = { param($Value) Set-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -Value $Value -Force }
    }
}

function Split-AzlTrustedHost([AllowNull()][string]$Value) {
    return @(([string]$Value) -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-AzlTrustedHostEntry {
    <#
    .SYNOPSIS
        Whether a value is one TrustedHosts entry this tool may write: an IP address or a plain host name. Never a wildcard, never a list
        (a comma or a semicolon), never a space or a scope id.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -ne $Value.Trim() -or $Value -match '[\*,;\s%]') { return $false }
    $bare = $Value
    if ($bare.StartsWith('[') -and $bare.EndsWith(']')) { $bare = $bare.Substring(1, $bare.Length - 2) }
    $address = $null
    if ([System.Net.IPAddress]::TryParse($bare, [ref]$address)) { return ($bare -match ':' -or $bare -match '^\d{1,3}(\.\d{1,3}){3}$') }
    return ($Value -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$')
}

function Get-AzlTrustedHostsStatePath([object]$Store) {
    if ($Store -and $Store.PSObject.Properties['StatePath'] -and $Store.StatePath) { return [string]$Store.StatePath }
    return ''
}

function Remove-AzlTrustedHostsState {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf) -and $PSCmdlet.ShouldProcess($Path, 'Remove the TrustedHosts state file')) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Restore-AzlStaleTrustedHost {
    <#
    .SYNOPSIS
        Undoes what a run that was killed (so its finally block never ran) left in TrustedHosts: the state file it wrote before it changed
        the value says what the value was and what the run set. The previous value goes back only when the value is still the one the
        killed run set; something changed in the meantime is left alone. A run that is still alive in another process is never undone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Store = (Get-AzlTrustedHostsStore))
    $path = Get-AzlTrustedHostsStatePath $Store
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $record = $null
    try { $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { Write-Warning "The TrustedHosts state file $path is damaged and was removed; TrustedHosts was not touched."; Remove-AzlTrustedHostsState $path; return }
    if ($null -eq $record -or -not $record.PSObject.Properties['previous'] -or -not $record.PSObject.Properties['applied']) {
        Write-Warning "The TrustedHosts state file $path is not one this tool wrote and was removed; TrustedHosts was not touched."
        Remove-AzlTrustedHostsState $path
        return
    }
    $ownerId = $(if ($record.PSObject.Properties['processId']) { [int]$record.processId } else { 0 })
    if ($ownerId -gt 0 -and $ownerId -ne $PID) {
        $owner = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
        $sameStart = $false
        if ($owner -and $record.PSObject.Properties['processStart']) { try { $sameStart = ($owner.StartTime.ToUniversalTime().Ticks -eq [long]$record.processStart) } catch { $sameStart = $false } }
        if ($owner -and $sameStart) {
            Write-Warning "TrustedHosts was changed by a run that is still active (process $ownerId); it is not undone."
            return
        }
    }
    $current = [string](& $Store.Get)
    if ($current -ne [string]$record.applied) {
        Write-Warning "A run that was cut short left a TrustedHosts record, but TrustedHosts is now '$current', not the '$($record.applied)' that run set. It is left as it is."
        if ($PSCmdlet.ShouldProcess($path, 'Remove the TrustedHosts state file')) { Remove-AzlTrustedHostsState $path }
        return
    }
    if ($PSCmdlet.ShouldProcess('TrustedHosts', "Restore '$($record.previous)' (left behind by a run that was cut short)")) {
        & $Store.Set ([string]$record.previous)
        Remove-AzlTrustedHostsState $path
        Write-Warning "A run that was cut short had left TrustedHosts at '$($record.applied)'; it was put back to '$($record.previous)'."
        Write-AzlRemotingEvent -State TrustedHostsRestored -Level Warning -Evidence "TrustedHosts restored to '$($record.previous)': an earlier run was cut short and had left '$($record.applied)'." -Data ([ordered]@{ restored = [string]$record.previous; replaced = [string]$record.applied; stale = $true })
    }
}

function Write-AzlTrustedHostsState {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$Previous, [string]$Applied)
    if (-not $Path) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Record the TrustedHosts values before they change')) { return }
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
    $me = Get-Process -Id $PID
    $record = [ordered]@{ previous = $Previous; applied = $Applied; processId = $PID; processStart = $me.StartTime.ToUniversalTime().Ticks; written = [datetime]::UtcNow.ToString('o') }
    Set-Content -LiteralPath $Path -Value (ConvertTo-Json -InputObject $record -Compress) -Encoding utf8NoBOM
}

function Set-AzlTrustedHostsPolicy {
    <#
    .SYNOPSIS
        Applies the TrustedHosts policy of the profile on this machine and returns what is needed to put it back.
    .DESCRIPTION
        wildcard   '*' (lab and test only; the profile refuses it elsewhere)
        exact      the previous entries plus the nodes' addresses that are missing
        none       nothing is written; an existing '*' is reported (it was not set by this run and is never copied)
        The previous value is recorded in the returned session. Restore with Restore-AzlTrustedHostsPolicy.
    .OUTPUTS
        Mode, Previous, Applied, Changed, Supported, Warnings.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$RemotingProfile,
        [string[]]$Address = @(),
        [object]$Store = (Get-AzlTrustedHostsStore)
    )
    $mode = [string]$RemotingProfile.TrustedHosts.Mode
    # A run that was killed leaves its wildcard behind; put the old value back first, so it is never taken for the "previous" value of this run.
    if ($Store.Supported) { Restore-AzlStaleTrustedHost -Store $Store -WhatIf:$WhatIfPreference -Confirm:$false }
    $statePath = Get-AzlTrustedHostsStatePath $Store
    $previous = [string](& $Store.Get)
    $existing = Split-AzlTrustedHost $previous
    $warnings = [System.Collections.Generic.List[string]]::new()
    $applied = $previous
    $changed = $false
    if ($RemotingProfile.Class -notin 'lab', 'test' -and $mode -eq 'wildcard') { throw "The class $($RemotingProfile.Class) never sets a TrustedHosts wildcard." }
    if (-not $Store.Supported) {
        $warnings.Add('TrustedHosts is not available on this platform; the policy was not applied. Use HTTPS with a trusted certificate.')
    }
    else {
        switch ($mode) {
            'wildcard' {
                if ($existing -notcontains '*') { $applied = '*'; $changed = $true }
            }
            'exact' {
                $wanted = @($Address | Where-Object { $_ } | Select-Object -Unique)
                $bad = @($wanted | Where-Object { -not (Test-AzlTrustedHostEntry $_) })
                if ($bad.Count) {
                    $exception = [System.ArgumentException]::new("TrustedHosts takes an IP address or a host name for each node, and nothing else: no wildcard, no list. Not accepted: $($bad -join ' | '). Fix -NodeAddress or the node addresses in the master file.")
                    $exception.Data['AzlInput'] = $true
                    throw $exception
                }
                $missing = @($wanted | Where-Object { $existing -notcontains $_ -and $existing -notcontains '*' })
                if ($missing.Count) { $applied = (@($existing) + @($missing)) -join ','; $changed = $true }
            }
            'none' {
                if ($existing -contains '*') { $warnings.Add("TrustedHosts on this machine already contains '*' (not set by this run). The class $($RemotingProfile.Class) never sets it and does not copy it; remove it when this machine is no longer a lab-only machine.") }
            }
        }
        if ($changed -and $PSCmdlet.ShouldProcess('TrustedHosts', "Set to '$applied'")) {
            # The previous and the applied value are on disk BEFORE the value changes: a hard kill after this line is undone at the next start.
            if ($RemotingProfile.TrustedHosts.RestoreAfterRun) { Write-AzlTrustedHostsState -Path $statePath -Previous $previous -Applied $applied -Confirm:$false }
            & $Store.Set $applied
        }
        elseif ($changed) { $changed = $false; $applied = $previous }
    }
    if ($changed) {
        Write-AzlRemotingEvent -State TrustedHostsChanged -Level $(if ($applied -eq '*') { 'Warning' } else { 'Info' }) -Evidence "TrustedHosts changed from '$previous' to '$applied' (class $($RemotingProfile.Class), mode $mode). It is restored after the run$(if (-not $RemotingProfile.TrustedHosts.RestoreAfterRun) { ' is NOT' })." -Data ([ordered]@{ class = $RemotingProfile.Class; mode = $mode; previous = $previous; applied = $applied })
    }
    foreach ($w in $warnings) { Write-Warning $w }
    [pscustomobject]@{ Mode = $mode; Previous = $previous; Applied = $applied; Changed = $changed; Supported = [bool]$Store.Supported; Restore = [bool]$RemotingProfile.TrustedHosts.RestoreAfterRun; Warnings = $warnings.ToArray(); StatePath = $statePath }
}

function Restore-AzlTrustedHostsPolicy {
    <#
    .SYNOPSIS
        Puts the previous TrustedHosts value back, when the policy changed it and the profile says to restore. A value that someone
        else changed in the meantime is left alone and reported.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Session, [object]$Store = (Get-AzlTrustedHostsStore))
    if ($Session.PSObject.Properties['Restored'] -and $Session.Restored) { return [pscustomobject]@{ Restored = $true; Reason = 'already restored' } }
    $statePath = $(if ($Session.PSObject.Properties['StatePath']) { [string]$Session.StatePath } else { '' })
    if (-not $Session.Changed -or -not $Session.Restore) { return [pscustomobject]@{ Restored = $false; Reason = $(if (-not $Session.Changed) { 'the policy changed nothing' } else { 'the profile keeps the value' }) } }
    $current = [string](& $Store.Get)
    if ($current -ne $Session.Applied) {
        Write-Warning "TrustedHosts is '$current', not the '$($Session.Applied)' this run set; it was changed meanwhile and is left as it is."
        Remove-AzlTrustedHostsState $statePath
        return [pscustomobject]@{ Restored = $false; Reason = 'changed by something else meanwhile' }
    }
    if ($PSCmdlet.ShouldProcess('TrustedHosts', "Restore '$($Session.Previous)'")) {
        & $Store.Set $Session.Previous
        Remove-AzlTrustedHostsState $statePath
        $Session | Add-Member -NotePropertyName Restored -NotePropertyValue $true -Force
        Write-AzlRemotingEvent -State TrustedHostsRestored -Evidence "TrustedHosts restored to '$($Session.Previous)'." -Data ([ordered]@{ restored = $Session.Previous; replaced = $Session.Applied })
        return [pscustomobject]@{ Restored = $true; Reason = '' }
    }
    return [pscustomobject]@{ Restored = $false; Reason = 'not confirmed' }
}

function Invoke-AzlWithRemotingSession {
    <#
    .SYNOPSIS
        Runs a script block with the TrustedHosts policy of the profile applied, and restores it in a finally block. The one place
        the orchestrator's TrustedHosts is changed.
    .EXAMPLE
        Invoke-AzlWithRemotingSession -RemotingProfile $RemotingProfile -Address $addresses -ScriptBlock { Invoke-Something }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RemotingProfile,
        [string[]]$Address = @(),
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object]$Store = (Get-AzlTrustedHostsStore)
    )
    $session = Set-AzlTrustedHostsPolicy -RemotingProfile $RemotingProfile -Address $Address -Store $Store -Confirm:$false
    try { & $ScriptBlock $session }
    finally { $null = Restore-AzlTrustedHostsPolicy -Session $session -Store $Store -Confirm:$false }
}

# ---------------------------------------------------------------------------------------------------------------------
# Which endpoint, and what to say when there is none
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlRemotingEndpoint {
    <#
    .SYNOPSIS
        Which WinRM endpoint of a node this host should use, from the profile: HTTPS 5986 first when the profile uses HTTPS (HTTP
        5985 only in the classes that allow it, or in the bootstrap window after this run opened the node with -BootstrapWindow), HTTP 5985 first in lab and test (5986 when the node already
        has the HTTPS listener).
    .PARAMETER PortTest
        { param($Address, $Port) $true/$false }. Default: a TCP connection with a short timeout.
    .OUTPUTS
        Answers, UseSsl, Port, Tried (what was tried), Message (the diagnosis when nothing answers).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RemotingProfile,
        [Parameter(Mandatory)][string]$Address,
        [switch]$BootstrapWindow,
        [scriptblock]$PortTest = { param($Address, $Port) $c = [System.Net.Sockets.TcpClient]::new(); try { $a = $c.ConnectAsync($Address, $Port); $a.Wait(4000) -and $c.Connected } catch { $false } finally { $c.Dispose() } }
    )
    $t = $RemotingProfile.Transport
    $order = [System.Collections.Generic.List[int]]::new()
    if ($t.Scheme -eq 'https') {
        $order.Add($t.HttpsPort)
        if ($t.OrchestratorMayFallBackToHttp -or ($BootstrapWindow -and $t.BootstrapWindowHttp)) { $order.Add($t.HttpPort) }
    }
    else {
        $order.Add($t.HttpPort)
        $order.Add($t.HttpsPort)
    }
    foreach ($port in $order) {
        if (& $PortTest $Address $port) { return [pscustomobject]@{ Answers = $true; UseSsl = ($port -eq $t.HttpsPort); Port = $port; Tried = $order.ToArray(); Message = '' } }
    }
    [pscustomobject]@{ Answers = $false; UseSsl = ($t.Scheme -eq 'https'); Port = $order[0]; Tried = $order.ToArray(); Message = (Format-AzlWinRmUnreachableMessage -RemotingProfile $RemotingProfile -Address $Address -Port $order.ToArray()) }
}

function Format-AzlWinRmUnreachableMessage {
    <#
    .SYNOPSIS
        The diagnosis when a node does not answer on WinRM, with the bootstrap options this profile gives.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$RemotingProfile, [string]$Node = '', [Parameter(Mandatory)][string]$Address, [int[]]$Port = @(5985))
    $who = if ($Node) { "${Node}: " } else { '' }
    $b = $RemotingProfile.Bootstrap
    $routes = @($b.Routes) -join ', '
    $smbNote = 'The smb route needs TCP 445 from this host and a Windows orchestrator (sc.exe); the arc route needs the Arc agent connected and outbound 443 only.'
    $options = if ($b.Permitted) { "The one-time bootstrap is chosen and permitted for the class $($RemotingProfile.Class) (route$(if (@($b.Routes).Count -gt 1) { 's' }): $routes): the run opens WinRM through it once per node, then continues over WinRM. $smbNote" }
    elseif ($b.Allowed -and $b.Chosen) { "Bootstrap option: the bootstrap ($($b.Transport)) is chosen but not approved. Approve it for this run (-ApprovedBootstrap), or open WinRM from the console or the BMC." }
    elseif ($b.Allowed -and $b.RequiresExplicitChoice) { "Bootstrap options: the class $($RemotingProfile.Class) allows a one-time bootstrap only with bootstrap_transport: arc, smb or auto in os_configuration.remoting and a pipeline approval (-ApprovedBootstrap); otherwise open WinRM from the console or the BMC. $smbNote" }
    elseif ($b.Allowed) { "Bootstrap option: set os_configuration.remoting.bootstrap_transport to smb, arc or auto (the class $($RemotingProfile.Class) allows it), or open WinRM from the console or the BMC. $smbNote" }
    else { "Bootstrap option: the class $($RemotingProfile.Class) has no bootstrap; open WinRM from the console or the BMC." }
    "${who}no answer on $Address TCP $($Port -join '/'). A freshly provisioned node's firewall allows WinRM from its own subnet only, so the node firewall probably limits WinRM to its own subnet and this host is outside it. $options Class $($RemotingProfile.Class) allows these sources: $(@($RemotingProfile.Firewall.RemoteAddress) -join ', ')."
}

Export-ModuleMember -Function Set-AzlRemotingEventSink, Get-AzlRemotingEvent, Write-AzlRemotingEvent, Send-AzlRemotingProfileEvent, Get-AzlTrustedHostsStore, Test-AzlTrustedHostEntry, Restore-AzlStaleTrustedHost, Set-AzlTrustedHostsPolicy, Restore-AzlTrustedHostsPolicy, Invoke-AzlWithRemotingSession, Resolve-AzlRemotingEndpoint, Format-AzlWinRmUnreachableMessage
