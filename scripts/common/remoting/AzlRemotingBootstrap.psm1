#Requires -Version 7.0
<#
.SYNOPSIS
    The one-time bootstrap: opens WinRM on a node whose firewall rule keeps this host out, without anyone touching the node.

.DESCRIPTION
    A node that Microsoft's OS install provisioned has WinRM on, but the Public-profile rule only lets its own subnet in. A remote
    orchestrator cannot use it. Invoke-AzlWinRmBootstrap fixes that once per node, over a route that does not need WinRM:

      smb   TCP 445 from a WINDOWS orchestrator. net use to \\node\IPC$ as the local Administrator (RID 500; the password comes from
            Key Vault by the same helper as identity.local_admin and is never printed or recorded), sc.exe creates a service that
            runs ONE small PowerShell script as LocalSystem, sc.exe starts it (error 1053 is expected and fine: the command is not
            a real service, the script still runs), the toolkit waits for the one-line result file, deletes the service, reads the
            file over the C$ share, deletes it, and net use /delete. sc.exe is Windows only; on a Linux orchestrator the route
            reports that and the next one is tried.
      arc   Azure Arc Run Command (outbound 443 only). The same script. The wait is CAPPED (default 3 minutes): on some nodes the
            run command handler wedged and a run hung for 10 minutes while stale Creating commands piled up. After the cap the
            route fails cleanly, this tool's own stale azl-osconfig-* commands older than 15 minutes are deleted, and the next
            allowed route is tried.
      none  nothing; the node fails with the diagnosis.
      auto  the allowed routes in the order smb, arc.

    The script (New-AzlRemotingBootstrapScript, Windows PowerShell 5.1, a few hundred characters) does only this: start WinRM and
    make it start automatically, Enable-PSRemoting if there is no listener, set Enabled, Profile Any and the RemoteAddress of
    the profile on the rules that let WinRM in (found by port, not by name), optionally RDP and ICMP echo per profile, optionally
    an HTTPS listener for a certificate that is already on the node, and write one result line. Everything else runs afterwards
    over WinRM (the RemoteManagement step). The class decides whether a bootstrap is allowed: production and dmz also need the
    pipeline approval (-ApprovedBootstrap).

    Every external command is a script block parameter (sc.exe, net use, the result file, the Arc calls, the clock), so the tests
    run the whole thing with fakes and no real SMB, no Azure.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AzlRemotingProfile.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlRemotingSession.psm1')
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))

$script:RunCommandApiVersion = '2026-09-01'
$script:ResultFile = 'C:\Windows\Temp\azl-bootstrap-winrm.txt'
$script:RunCommandPrefix = 'azl-osconfig-'

# ---------------------------------------------------------------------------------------------------------------------
# The script that runs on the node
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlRemotingBootstrapScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure: builds a string, changes nothing.')]
    <#
    .SYNOPSIS
        The small Windows PowerShell 5.1 script both routes run on the node. Built from the profile's values, which are validated
        (addresses and thumbprints only), so nothing the operator typed becomes code.
    .PARAMETER RemoteAddress
        The WinRM source scope: 'Any' or CIDRs.
    .PARAMETER ResultPath
        A file the script writes its one-line result to (the smb route reads it over C$). Empty: no file, the result is only written
        to the output (the Arc route reads the output).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$RemoteAddress,
        [bool]$Rdp = $false, [string[]]$RdpRemoteAddress = @(),
        [bool]$Icmp = $false, [string[]]$IcmpRemoteAddress = @(),
        [string]$Thumbprint = '',
        [string]$ResultPath = $script:ResultFile
    )
    $address = '^(Any|LocalSubnet|[0-9A-Fa-f:.]+(/[0-9]{1,3})?)$'
    $quote = {
        param($list, $name)
        $clean = @($list | Where-Object { $_ })
        foreach ($a in $clean) { if ($a -notmatch $address) { throw "The $name '$a' isn't an address or a CIDR, so it isn't put in the bootstrap script." } }
        "@('" + ($clean -join "','") + "')"
    }
    if ($Thumbprint -and $Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'The certificate thumbprint is not 40 hex digits.' }
    if ($ResultPath -and $ResultPath -notmatch '^[A-Za-z]:\\[A-Za-z0-9_.\\ -]+$') { throw 'The result path is not a plain Windows path.' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('$ErrorActionPreference="Stop";$o=@{ok=$false}')
    $lines.Add('try{')
    $lines.Add('Set-Service WinRM -StartupType Automatic;if((Get-Service WinRM).Status -ne "Running"){Start-Service WinRM}')
    $lines.Add('if(-not @(Get-ChildItem WSMan:\localhost\Listener -EA 0).Count){Enable-PSRemoting -Force -SkipNetworkProfileCheck|Out-Null}')
    $lines.Add('$ra=' + (& $quote $RemoteAddress 'WinRM source'))
    $lines.Add('$n=@(Get-NetFirewallPortFilter -Protocol TCP|?{@($_.LocalPort) -contains "5985" -or @($_.LocalPort) -contains "5986"}|%{Get-NetFirewallRule -AssociatedNetFirewallPortFilter $_}|?{$_.Direction -eq "Inbound" -and $_.Action -eq "Allow"}|%{$_.Name}|Select-Object -Unique)')
    $lines.Add('foreach($r in $n){Set-NetFirewallRule -Name $r -Enabled True -Profile Any -RemoteAddress $ra}')
    if ($Thumbprint) {
        $lines.Add('$t="' + $Thumbprint.ToUpperInvariant() + '";$c=Get-Item "Cert:\LocalMachine\My\$t";$h=($c.Subject -replace "^CN=","" -split ",")[0]')
        $lines.Add('if(-not @(Get-ChildItem WSMan:\localhost\Listener|?{$_.Keys -contains "Transport=HTTPS"}).Count){New-WSManInstance winrm/config/Listener -SelectorSet @{Address="*";Transport="HTTPS"} -ValueSet @{Hostname=$h;CertificateThumbprint=$t}|Out-Null}')
        $lines.Add('if(-not (Get-NetFirewallRule -Name AzlOsConfig-WinRM-HTTPS-In -EA 0)){New-NetFirewallRule -Name AzlOsConfig-WinRM-HTTPS-In -DisplayName "Azure Local OS configuration: WinRM HTTPS" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5986 -Profile Any|Out-Null}')
        $lines.Add('Set-NetFirewallRule -Name AzlOsConfig-WinRM-HTTPS-In -Enabled True -Profile Any -RemoteAddress $ra')
    }
    if ($Rdp) {
        $lines.Add('Set-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server" fDenyTSConnections 0;Set-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" UserAuthentication 1')
        $lines.Add('foreach($r in "RemoteDesktop-UserMode-In-TCP","RemoteDesktop-UserMode-In-UDP"){if(Get-NetFirewallRule -Name $r -EA 0){Set-NetFirewallRule -Name $r -Enabled True -Profile Any -RemoteAddress ' + (& $quote $RdpRemoteAddress 'RDP source') + '}}')
    }
    if ($Icmp) {
        $lines.Add('foreach($r in "FPS-ICMP4-ERQ-In","FPS-ICMP6-ERQ-In"){if(Get-NetFirewallRule -Name $r -EA 0){Set-NetFirewallRule -Name $r -Enabled True -Profile Any -RemoteAddress ' + (& $quote $IcmpRemoteAddress 'ICMP source') + '}}')
    }
    $lines.Add('$o.ok=$true;$o.rules=@($n|%{$x=Get-NetFirewallRule -Name $_;$a=Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $x;"$_|$($x.Enabled)|$($x.Profile)|$($a.RemoteAddress -join ",")"})')
    $lines.Add('}catch{$o.err=$_.Exception.Message}')
    $lines.Add('$j="AZLBOOT:"+(ConvertTo-Json $o -Compress)')
    if ($ResultPath) { $lines.Add('Set-Content -LiteralPath "' + $ResultPath + '" -Value $j -Encoding ASCII') }
    $lines.Add('Write-Output $j')
    return ($lines -join "`n")
}

function ConvertTo-AzlEncodedCommand {
    <#
    .SYNOPSIS
        What powershell.exe -EncodedCommand takes: base64 of the UTF-16LE text.
    #>
    # What powershell.exe -EncodedCommand takes: base64 of the UTF-16LE text.
    param([Parameter(Mandatory)][string]$Script)
    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
}

function Get-AzlBootstrapCommandLine {
    <#
    .SYNOPSIS
        The service command line sc.exe gets as binPath. Throws when it would not fit cmd.exe's 8191 characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Script)
    $line = 'cmd.exe /c powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + (ConvertTo-AzlEncodedCommand $Script)
    if ($line.Length -gt 7800) { throw "The bootstrap command line is $($line.Length) characters; cmd.exe takes 8191. The script is too long for the smb route." }
    return $line
}

function Format-AzlRedacted {
    # The text with every secret removed.
    param([AllowNull()][string]$Text, [string[]]$Secret = @())
    $out = [string]$Text
    foreach ($s in $Secret) { if ($s) { $out = $out.Replace($s, '***') } }
    return $out
}

function Read-AzlBootstrapResult {
    <#
    .SYNOPSIS
        The AZLBOOT line of the script's answer (the result file or the Arc output) as an object; $null when there is none.
    #>
    # The AZLBOOT line of the script's answer (from the result file or the Arc output) as an object; $null when there is none.
    param([AllowNull()][string]$Text)
    $line = @(([string]$Text -split "`r?`n") | Where-Object { $_.Trim().StartsWith('AZLBOOT:') }) | Select-Object -Last 1
    if (-not $line) { return $null }
    try { return ($line.Trim().Substring(8) | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------------------------------------------------------------
# Route: SMB
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlSmbBootstrap {
    <#
    .SYNOPSIS
        The smb route for one node. Windows orchestrator only. Returns Route, Ok, Reason, Result and Steps (what was done, no secret).
    .PARAMETER Credential
        The local Administrator (RID 500) of the node: UserName as given (Administrator), the password from Key Vault.
    .PARAMETER Sc
        { param([string[]]$Arguments) } returns ExitCode and Output. Default: sc.exe.
    .PARAMETER NetUse
        { param([string[]]$Arguments) } returns ExitCode and Output. Default: net.exe.
    .PARAMETER PortTest, TestFile, ReadFile, DeleteFile, Sleep
        Seams: TCP 445, the result file on \\node\C$, its content, deleting it, waiting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$WaitSeconds = 60,
        [scriptblock]$Sc = { param($Arguments) $o = & sc.exe @Arguments 2>&1; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($o -join ' ') } },
        [scriptblock]$NetUse = { param($Arguments) $o = & net.exe @Arguments 2>&1; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($o -join ' ') } },
        [scriptblock]$PortTest = { param($Address, $Port) $c = [System.Net.Sockets.TcpClient]::new(); try { $a = $c.ConnectAsync($Address, $Port); $a.Wait(4000) -and $c.Connected } catch { $false } finally { $c.Dispose() } },
        [scriptblock]$TestFile = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf },
        [scriptblock]$ReadFile = { param($Path) Get-Content -LiteralPath $Path -Raw },
        [scriptblock]$DeleteFile = { param($Path) Remove-Item -LiteralPath $Path -Force },
        [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds },
        [switch]$SkipPlatformCheck
    )
    $steps = [System.Collections.Generic.List[string]]::new()
    $steps.Add("node $Node")
    $password = $Credential.GetNetworkCredential().Password
    $user = $Credential.UserName
    $fail = { param($why) [pscustomobject]@{ Route = 'smb'; Ok = $false; Reason = (Format-AzlRedacted $why @($password)); Result = $null; Steps = $steps } }
    if (-not $SkipPlatformCheck -and -not $IsWindows) { return (& $fail 'The smb route needs a Windows orchestrator (sc.exe and net use). This host is not Windows; use the arc route or open WinRM from the console or the BMC.') }
    if (-not (& $PortTest $Address 445)) { return (& $fail "TCP 445 on $Address is not reachable from this host.") }
    $steps.Add('TCP 445 answers')
    $share = "\\$Address\IPC`$"
    $service = 'azl-bootstrap-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = "\\$Address\C`$\Windows\Temp\azl-bootstrap-winrm.txt"
    $connected = $false
    $created = $false
    $text = $null
    try {
        $use = & $NetUse @('use', $share, $password, "/user:$user")
        if ($use.ExitCode -ne 0) { return (& $fail "net use $share as $user failed (exit $($use.ExitCode)): $($use.Output)") }
        $connected = $true
        $steps.Add("authenticated to $share as $user")
        $binPath = Get-AzlBootstrapCommandLine -Script $Script
        $create = & $Sc @("\\$Address", 'create', $service, 'binPath=', $binPath, 'start=', 'demand', 'obj=', 'LocalSystem')
        if ($create.ExitCode -ne 0) { return (& $fail "sc create failed (exit $($create.ExitCode)): $($create.Output)") }
        $created = $true
        $steps.Add("service $service created")
        $start = & $Sc @("\\$Address", 'start', $service)
        # 1053: the service did not respond to the start request in time. The command is not a real service, so that is what happens, and the script still runs.
        if ($start.ExitCode -notin 0, 1053) { return (& $fail "sc start failed (exit $($start.ExitCode)): $($start.Output)") }
        $steps.Add("service started (exit $($start.ExitCode)$(if ($start.ExitCode -eq 1053) { ', expected for a command that is not a service' }))")
        $waited = 0
        while (-not (& $TestFile $resultPath) -and $waited -lt $WaitSeconds) { & $Sleep 2; $waited += 2 }
        $steps.Add("waited $waited s for the result file")
        $null = & $Sc @("\\$Address", 'delete', $service)
        $created = $false
        $steps.Add("service $service deleted")
        if (& $TestFile $resultPath) {
            $text = [string](& $ReadFile $resultPath)
            & $DeleteFile $resultPath
            $steps.Add('result file read and deleted')
        }
    }
    finally {
        if ($created) { try { $null = & $Sc @("\\$Address", 'delete', $service) } catch { Write-Verbose "sc delete: $(Format-AzlRedacted $_.Exception.Message @($password))" } }
        if ($connected) { try { $null = & $NetUse @('use', $share, '/delete') } catch { Write-Verbose "net use /delete: $($_.Exception.Message)" } }
    }
    $result = Read-AzlBootstrapResult -Text $text
    if (-not $result) { return (& $fail "No result from the node within $WaitSeconds s (the script did not write $($script:ResultFile)).") }
    if (-not $result.ok) { return (& $fail "The script on the node failed: $(Format-AzlRedacted ([string]$result.err) @($password))") }
    [pscustomobject]@{ Route = 'smb'; Ok = $true; Reason = ''; Result = $result; Steps = $steps }
}

# ---------------------------------------------------------------------------------------------------------------------
# Route: Arc
# ---------------------------------------------------------------------------------------------------------------------

function Remove-AzlBootstrapStaleRunCommand {
    [CmdletBinding(SupportsShouldProcess)]
    <#
    .SYNOPSIS
        Deletes this tool's own run commands (azl-osconfig-*) on one Arc machine that are older than -MinutesOld (default 15): a
        wedged handler leaves them in state Creating. Other names are never touched. A command with no timestamp is stale only
        when it is not Succeeded.
    .PARAMETER Arm
        { param($Method, $Path, $ApiVersion, $Body) } default Invoke-AzlArm.
    #>
    param(
        [Parameter(Mandatory)][string]$MachineId,
        [int]$MinutesOld = 15,
        [scriptblock]$Arm = { param($Method, $Path, $ApiVersion, $Body) $null = $Body; Invoke-AzlArm -Method $Method -Path $Path -ApiVersion $ApiVersion -AllowNotFound },
        [datetime]$Now = [datetime]::UtcNow
    )
    $list = & $Arm 'GET' "$MachineId/runCommands" $script:RunCommandApiVersion $null
    $deleted = [System.Collections.Generic.List[string]]::new()
    foreach ($run in @($(if ($list -and $list.PSObject.Properties['value']) { $list.value } else { @() }))) {
        $name = [string](Get-AzlProp $run 'name' '')
        if (-not $name.StartsWith($script:RunCommandPrefix)) { continue }
        $started = $null
        foreach ($candidate in @((Get-AzlProp $run 'systemData.createdAt'), (Get-AzlProp $run 'properties.instanceView.startTime'))) {
            $parsed = [datetime]::MinValue
            if ($candidate -and [datetime]::TryParse([string]$candidate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $started = $parsed; break }
        }
        $stale = if ($started) { ($Now - $started).TotalMinutes -gt $MinutesOld } else { [string](Get-AzlProp $run 'properties.provisioningState' '') -ne 'Succeeded' }
        if ($stale -and $PSCmdlet.ShouldProcess($name, 'Delete the stale run command')) {
            try { $null = & $Arm 'DELETE' "$MachineId/runCommands/$name" $script:RunCommandApiVersion $null; $deleted.Add($name) }
            catch { Write-Warning "Couldn't delete the stale run command ${name}: $($_.Exception.Message)" }
        }
    }
    return $deleted.ToArray()
}

function Invoke-AzlArcBootstrap {
    <#
    .SYNOPSIS
        The arc route for one node: one run command, polled for at most -WaitSeconds, then deleted. Returns Route, Ok, Reason, Result,
        Steps, TimedOut.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$ArcResourceId,
        [Parameter(Mandatory)][string]$Script,
        [int]$WaitSeconds = 180,
        [int]$PollSeconds = 10,
        [scriptblock]$Arm = { param($Method, $Path, $ApiVersion, $Body) Invoke-AzlArm -Method $Method -Path $Path -ApiVersion $ApiVersion -Body $Body -AllowNotFound },
        [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds },
        [scriptblock]$Clock = { [datetime]::UtcNow }
    )
    $steps = [System.Collections.Generic.List[string]]::new()
    $steps.Add("node $Node")
    $fail = { param($why, $timedOut) [pscustomobject]@{ Route = 'arc'; Ok = $false; Reason = $why; Result = $null; Steps = $steps; TimedOut = [bool]$timedOut } }
    try {
        $stale = @(Remove-AzlBootstrapStaleRunCommand -MachineId $ArcResourceId -Arm $Arm -Now (& $Clock))
        if ($stale.Count) { $steps.Add("deleted $($stale.Count) stale run command(s): $($stale -join ', ')") }
    }
    catch { $steps.Add("stale run commands not listed: $($_.Exception.Message)") }
    $name = $script:RunCommandPrefix + 'boot-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = "$ArcResourceId/runCommands/$name"
    $created = $false
    try {
        $machine = & $Arm 'GET' $ArcResourceId '2024-07-10' $null
        $location = [string](Get-AzlProp $machine 'location' '')
        $body = @{ location = $location; properties = @{ source = @{ script = $Script }; timeoutInSeconds = $WaitSeconds; asyncExecution = $true } }
        $null = & $Arm 'PUT' $path $script:RunCommandApiVersion $body
        $created = $true
        $steps.Add("run command $name created")
        $deadline = (& $Clock).AddSeconds($WaitSeconds)
        $terminal = @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
        $run = $null; $state = ''
        do {
            & $Sleep $PollSeconds
            $run = & $Arm 'GET' $path $script:RunCommandApiVersion $null
            $state = [string](Get-AzlProp $run 'properties.instanceView.executionState' '')
            $provisioning = [string](Get-AzlProp $run 'properties.provisioningState' '')
        } while ($state -notin $terminal -and $provisioning -ne 'Failed' -and (& $Clock) -lt $deadline)
        if ($state -notin $terminal -and $provisioning -ne 'Failed') {
            return (& $fail "The run command did not finish within $WaitSeconds s (state '$state'); the Arc run command handler on the node may be wedged. The route is given up and the run command is deleted." $true)
        }
        $output = [string](Get-AzlProp $run 'properties.instanceView.output' '')
        $result = Read-AzlBootstrapResult -Text $output
        if ($state -ne 'Succeeded' -and -not $result) { return (& $fail "The run command ended in state '$state': $([string](Get-AzlProp $run 'properties.instanceView.error' ''))" $false) }
        if (-not $result) { return (& $fail 'The run command finished but wrote no result line.' $false) }
        if (-not $result.ok) { return (& $fail "The script on the node failed: $([string]$result.err)" $false) }
        return [pscustomobject]@{ Route = 'arc'; Ok = $true; Reason = ''; Result = $result; Steps = $steps; TimedOut = $false }
    }
    catch { return (& $fail "The Arc call failed: $($_.Exception.Message)" $false) }
    finally {
        if ($created) {
            try { $null = & $Arm 'DELETE' $path $script:RunCommandApiVersion $null; $steps.Add("run command $name deleted") }
            catch { Write-Warning "Couldn't delete the run command ${name} on ${Node}: $($_.Exception.Message)" }
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The orchestration of the routes
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlWinRmBootstrap {
    <#
    .SYNOPSIS
        Opens WinRM on one node once, over the routes the profile allows and the operator chose, in order, until one works.
    .DESCRIPTION
        Gate: Test-AzlBootstrapPermitted (the class allows it, bootstrap_transport is arc, smb or auto, and production and dmz have
        -ApprovedBootstrap). Events: RemotingBootstrapStarted (route) before each route, RemotingBootstrapSucceeded or
        RemotingBootstrapFailed (route, reason) after it. A route that cannot run on this host (smb on Linux, arc without a machine)
        fails with that reason and the next route is tried. No password appears in an event, a result or a message.
    .PARAMETER Credential
        The node's local Administrator for the smb route (password from Key Vault by Get-AzlLocalAdminCredential).
    .PARAMETER Thumbprint
        A certificate already on the node, for an HTTPS listener in the bootstrap (needed for dmz, where HTTP never opens).
    .PARAMETER SmbCommand, ArcCommand
        Seams: replace the route functions with script blocks (a test).
    .OUTPUTS
        Node, Ok, Route (the one that worked), Attempts (Route, Ok, Reason), Reason, Result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RemotingProfile,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$Address,
        [string]$ArcResourceId = '',
        [pscredential]$Credential,
        [switch]$ApprovedBootstrap,
        [string]$Thumbprint = '',
        [int]$ArcWaitSeconds = 180,
        [int]$SmbWaitSeconds = 60,
        [scriptblock]$SmbCommand,
        [scriptblock]$ArcCommand
    )
    $verdict = Test-AzlBootstrapPermitted -Bootstrap $RemotingProfile.Bootstrap -Class $RemotingProfile.Class -ApprovedBootstrap:$ApprovedBootstrap
    if (-not $verdict.Permitted) {
        return [pscustomobject]@{ Node = $Node; Ok = $false; Route = ''; Attempts = @(); Reason = $verdict.Reason; Result = $null }
    }
    $fw = $RemotingProfile.Firewall
    $armScript = New-AzlRemotingBootstrapScript -RemoteAddress @($fw.RemoteAddress) -Rdp ([bool]$fw.RdpEnabled) -RdpRemoteAddress @($fw.RdpRemoteAddress) -Icmp ([bool]$fw.IcmpEnabled) -IcmpRemoteAddress @($fw.IcmpRemoteAddress) -Thumbprint $Thumbprint -ResultPath ''
    $smbScript = New-AzlRemotingBootstrapScript -RemoteAddress @($fw.RemoteAddress) -Rdp ([bool]$fw.RdpEnabled) -RdpRemoteAddress @($fw.RdpRemoteAddress) -Icmp ([bool]$fw.IcmpEnabled) -IcmpRemoteAddress @($fw.IcmpRemoteAddress) -Thumbprint $Thumbprint
    $secret = @()
    if ($Credential) { $secret = @($Credential.GetNetworkCredential().Password) }
    $attempts = [System.Collections.Generic.List[object]]::new()
    foreach ($route in @($RemotingProfile.Bootstrap.Routes)) {
        Write-AzlRemotingEvent -State RemotingBootstrapStarted -Node $Node -Evidence "Bootstrap route $route started for $Node (class $($RemotingProfile.Class))." -Data ([ordered]@{ route = $route; class = $RemotingProfile.Class; approved = [bool]($RemotingProfile.Bootstrap.Approved -or $ApprovedBootstrap) })
        $outcome = $null
        try {
            switch ($route) {
                'smb' {
                    if (-not $Credential) { $outcome = [pscustomobject]@{ Route = 'smb'; Ok = $false; Reason = 'The smb route needs the local administrator credential and none is available.'; Result = $null } }
                    elseif ($SmbCommand) { $outcome = & $SmbCommand $Node $Address $smbScript $Credential }
                    else { $outcome = Invoke-AzlSmbBootstrap -Node $Node -Address $Address -Script $smbScript -Credential $Credential -WaitSeconds $SmbWaitSeconds }
                }
                'arc' {
                    if (-not $ArcResourceId) { $outcome = [pscustomobject]@{ Route = 'arc'; Ok = $false; Reason = "The arc route needs the Arc machine of $Node and none was found."; Result = $null } }
                    elseif ($ArcCommand) { $outcome = & $ArcCommand $Node $ArcResourceId $armScript }
                    else { $outcome = Invoke-AzlArcBootstrap -Node $Node -ArcResourceId $ArcResourceId -Script $armScript -WaitSeconds $ArcWaitSeconds }
                }
            }
        }
        catch { $outcome = [pscustomobject]@{ Route = $route; Ok = $false; Reason = $_.Exception.Message; Result = $null } }
        $reason = Format-AzlRedacted ([string]$outcome.Reason) $secret
        $attempts.Add([pscustomobject]@{ Route = $route; Ok = [bool]$outcome.Ok; Reason = $reason })
        if ($outcome.Ok) {
            Write-AzlRemotingEvent -State RemotingBootstrapSucceeded -Node $Node -Evidence "Bootstrap route $route opened WinRM on $Node." -Data ([ordered]@{ route = $route; class = $RemotingProfile.Class })
            return [pscustomobject]@{ Node = $Node; Ok = $true; Route = $route; Attempts = $attempts.ToArray(); Reason = ''; Result = $outcome.Result }
        }
        Write-AzlRemotingEvent -State RemotingBootstrapFailed -Node $Node -Level Warning -Evidence "Bootstrap route $route failed for ${Node}: $reason" -NextAction $(if ($route -ne @($RemotingProfile.Bootstrap.Routes)[-1]) { 'The next allowed route is tried.' } else { 'Open WinRM from the console or the BMC, or fix the cause and run again.' }) -Data ([ordered]@{ route = $route; reason = $reason; class = $RemotingProfile.Class })
    }
    [pscustomobject]@{ Node = $Node; Ok = $false; Route = ''; Attempts = $attempts.ToArray(); Reason = (($attempts | ForEach-Object { "$($_.Route): $($_.Reason)" }) -join ' | '); Result = $null }
}

Export-ModuleMember -Function New-AzlRemotingBootstrapScript, ConvertTo-AzlEncodedCommand, Get-AzlBootstrapCommandLine, Read-AzlBootstrapResult, Invoke-AzlSmbBootstrap, Remove-AzlBootstrapStaleRunCommand, Invoke-AzlArcBootstrap, Invoke-AzlWinRmBootstrap
