#Requires -Version 7.0
<#
.SYNOPSIS
    The node scripts of the DomainJoin step: read the domain membership, join the domain, restart with a durable marker, resume
    after the restart. Text for Windows PowerShell 5.1 on the node, kept in a PowerShell 7 module like AzlNodePayload.

.DESCRIPTION
    Written as text because the node runs Windows PowerShell 5.1 (no ternary, no ??, no ?., no &&); to this module they are plain
    strings. AzlNodePayload.psm1 puts its prologue (the ParamsB64 / SecretsB64 decoding and Write-Result) in front of them, so every
    answer is the usual AZLRESULT line.

    Probe     Read only. PartOfDomain and Domain, the computer's distinguished name (so its OU), DNS resolution of the domain, a
              domain controller SRV lookup, a TCP check of the controllers, the time difference to a controller, the secure channel,
              the computer name, and the restart marker. Also embedded in the Read script (section 'domainJoin') so the plan needs
              no extra call.
    Apply     mode join: Add-Computer -DomainName -OUPath -Credential -Restart:$false. The credential is built on the node from a
              secure string made from the secret and is never written down. A durable marker (write to a temporary file, flush to
              disk, rename) says a restart is expected. mode move: moves an already joined computer object to the OU (ADSI).
              mode finalize: marks the marker complete after the orchestrator verified the join. mode admins: adds domain principals to the
              local Administrators group (idempotent; after the join and the restart, needs no credential).
    OuCheck   Read only, with the join credential: the dedicated OU exists, its Group Policy inheritance is blocked (gPOptions = 1), and which
              GPO links above it are Enforced (Block Inheritance does not stop those).
    Restart   The guarded restart: refuses without the marker, then restarts the node (shutdown /r, 20 s, so the answer still returns).
    Resume    Runs at startup (a one-time scheduled task registered by Apply): after the restart it verifies the join and writes the
              result into the marker, then removes its task. It holds no secret.

    Secrets in SecretsB64: joinUser, joinPassword. They are only read inside Apply. The marker, the result and the errors never
    contain them.

    Get-AzlDomainJoinPayloadBody    The body for 'Probe', 'Apply', 'Restart' or 'Resume'.
    Get-AzlDomainJoinReadSection    The functions and the section that the Read script embeds.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The functions the Probe and the Read section share.
$script:ReadFunctions = @'
function Get-DjMarkerPath { return (Join-Path ([string](Get-P $P 'stateDir' $stateDir)) 'domainjoin-state.json') }
function Read-DjMarker {
    $path = Get-DjMarkerPath
    foreach ($candidate in @($path, ($path + '.bak'))) {
        if (Test-Path -LiteralPath $candidate) {
            try { return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { continue }
        }
    }
    return $null
}
if (-not (Test-Path 'function:Test-DjTcp')) {
    function Test-DjTcp([string]$Address, [int]$Port, [int]$Milliseconds) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $client.BeginConnect($Address, $Port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($Milliseconds, $false)) { return $false }
            $client.EndConnect($ar)
            return [bool]$client.Connected
        }
        catch { return $false }
        finally { $client.Close() }
    }
}
function Get-DjRead($dj) {
    $domain = [string](Get-P $dj 'domain' '')
    $dcs = @(Get-P $dj 'dcs' @())
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $r = [ordered]@{}
    $r.partOfDomain = [bool]$cs.PartOfDomain
    $r.domain = [string]$cs.Domain
    $r.host = [string]$cs.Name
    $r.boot = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    $r.dn = ''
    if ($cs.PartOfDomain) {
        try { $r.dn = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine' -Name 'Distinguished-Name' -ErrorAction Stop).'Distinguished-Name' } catch { $r.dn = '' }
    }
    $r.dnsOk = $false
    $r.dnsAddresses = @()
    $r.dnsError = ''
    $r.srvOk = $false
    $r.srvTargets = @()
    $r.dcReachable = $false
    $r.dcUsed = ''
    $r.skewSeconds = $null
    $r.secureChannel = $null
    $r.inCluster = [bool]((Test-Path 'HKLM:\Cluster') -or ((Get-Service ClusSvc -ErrorAction SilentlyContinue) -and (Get-Service ClusSvc).Status -eq 'Running'))
    $r.localAdmins = @()
    try { $r.localAdmins = @(& net.exe localgroup Administrators 2>$null | Where-Object { $_ -and $_ -notmatch '^(Alias name|Comment|Members|-+|The command completed)' } | ForEach-Object { ([string]$_).Trim() }) } catch { $r.localAdmins = @() }
    if ($domain) {
        try {
            $a = @(Resolve-DnsName -Name $domain -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
            $r.dnsAddresses = $a
            $r.dnsOk = ($a.Count -gt 0)
        }
        catch { $r.dnsError = [string]$_.Exception.Message }
        try {
            $t = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.' + $domain) -Type SRV -DnsOnly -ErrorAction Stop | Where-Object { $_.NameTarget } | ForEach-Object { [string]$_.NameTarget })
            $r.srvTargets = $t
            $r.srvOk = ($t.Count -gt 0)
        }
        catch { $r.srvOk = $false }
        $candidates = @($dcs) + @($r.srvTargets) + @($r.dnsAddresses)
        foreach ($c in $candidates) {
            if (-not $c) { continue }
            if (Test-DjTcp ([string]$c) 389 2500) { $r.dcReachable = $true; $r.dcUsed = [string]$c; break }
        }
        if ($r.dcUsed) {
            try {
                $out = @(& w32tm.exe /stripchart /computers:$($r.dcUsed) /samples:1 /dataonly 2>&1 | ForEach-Object { [string]$_ })
                foreach ($line in $out) {
                    $m = [regex]::Match($line, '([+-]\d+(?:[.,]\d+)?)s\s*$')
                    if ($m.Success) { $r.skewSeconds = [math]::Abs([double]::Parse($m.Groups[1].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)) }
                }
            }
            catch { $r.skewSeconds = $null }
        }
    }
    if ($cs.PartOfDomain) {
        try { $r.secureChannel = [bool](Test-ComputerSecureChannel -ErrorAction Stop) } catch { $r.secureChannel = $false }
    }
    $m = Read-DjMarker
    $r.marker = $null
    if ($m) { $r.marker = [pscustomobject]@{ state = [string](Get-P $m 'state' ''); changeId = [string](Get-P $m 'changeId' ''); bootBefore = [string](Get-P $m 'bootBefore' ''); domain = [string](Get-P $m 'domain' ''); error = [string](Get-P $m 'error' '') } }
    return [pscustomobject]$r
}
'@

$script:ReadSection = @'
if (Get-P $P 'domainJoin' $null) {
    try { $Az.domainJoin = Get-DjRead (Get-P $P 'domainJoin' $null) } catch { $Az.err['domainJoin'] = $_.Exception.Message }
}
'@

$script:ProbeBody = @'
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; domainJoin = (Get-DjRead $P) })
'@

$script:ApplyBody = @'
$mode = [string](Get-P $P 'mode' 'join')
$domain = [string](Get-P $P 'domain' '')
$netbios = [string](Get-P $P 'netbios' '')
$ouPath = [string](Get-P $P 'ou' '')
$changeId = [string](Get-P $P 'changeId' '')
$expectedHost = [string](Get-P $P 'expectedHost' '')
$jdDir = [string](Get-P $P 'stateDir' $stateDir)
$taskName = 'AzureLocal-OSConfig-DomainJoinResume'
$answer = [ordered]@{ v = 1; host = $env:COMPUTERNAME; finished = ''; mode = $mode; status = ''; reboot = $false; code = ''; label = ''; meaning = ''; errorText = ''; nextAction = ''; stillWorkgroup = $null; detail = ''; added = @() }

function Write-DjMarker($o) {
    # Durable: the bytes go to a temporary file, are flushed to the disk, and only then take the marker's name.
    $path = Get-DjMarkerPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $o -Depth 4 -Compress))
    $tmp = $path + '.tmp'
    $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($tmp, $path, ($path + '.bak')) } else { [System.IO.File]::Move($tmp, $path) }
}

function ConvertTo-DjError($ex) {
    $text = [string]$ex.Message
    $codes = New-Object System.Collections.ArrayList
    $e = $ex
    while ($e) {
        if ($e -is [System.ComponentModel.Win32Exception]) { [void]$codes.Add([int]$e.NativeErrorCode) }
        $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.HResult), 0)
        if (($u -shr 16) -eq 0x8007) { [void]$codes.Add([int]($u -band 0xFFFF)) }
        $e = $e.InnerException
    }
    foreach ($m in [regex]::Matches($text, '(?i)(?:error(?: code)?|code|status)\D{0,3}(\d{1,5})\b')) { [void]$codes.Add([int]$m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($text, '(?i)0x([0-9A-F]{8})')) {
        $u = [Convert]::ToUInt32($m.Groups[1].Value, 16)
        if (($u -shr 16) -eq 0x8007) { [void]$codes.Add([int]($u -band 0xFFFF)) }
        if ($u -eq 3221225779) { [void]$codes.Add(37) }
    }
    $table = @(
        @{ code = 1326; label = 'bad credential'; pattern = 'user name or password is incorrect|logon failure|unknown user name'; meaning = 'The user name or password of the join account is wrong.'
            next = 'Check identity.active_directory.domain_join_account: the username, and the Key Vault secret behind the password. Do not run again with the same values; repeated bad passwords lock the account.' }
        @{ code = 1909; label = 'account locked out'; pattern = 'locked out'; meaning = 'The join account is locked out.'
            next = 'Unlock the account in Active Directory, check that the secret is right, then run again.' }
        @{ code = 1331; label = 'account disabled'; pattern = 'account is currently disabled|account has been disabled'; meaning = 'The join account is disabled.'
            next = 'Enable the join account in Active Directory, then run again.' }
        @{ code = 1355; label = 'domain not found'; pattern = 'domain either does not exist or could not be contacted|domain .* could not be contacted'; meaning = 'The domain does not exist or no domain controller could be contacted.'
            next = 'Check that the node''s DNS servers are the domain controllers (identity.active_directory.domain_controllers, rule AZL-052), that the node reaches them on the management network, and that domain_fqdn is right.' }
        @{ code = 2224; label = 'account exists'; pattern = 'account already exists'; meaning = 'A computer object with this name already exists in the domain (possibly in another OU).'
            next = 'Delete the computer object, or move it into the OU from the file, in Active Directory; or set identity.active_directory.join_options.allow_ou_move after a first join. Then run again.' }
        @{ code = 5; label = 'access denied'; pattern = 'access is denied'; meaning = 'The join account is not allowed to create the computer object in the OU.'
            next = 'Delegate to the join account on the OU: create and delete computer objects, reset password, write dNSHostName and servicePrincipalName (docs: Joining the domain).' }
        @{ code = 53; label = 'network path not found'; pattern = 'network path was not found'; meaning = 'The node could not reach a domain controller over the network.'
            next = 'Check routing and firewalls between the node and the domain controllers (TCP 135, 389, 445 and the dynamic RPC range) and the DNS servers of the management port.' }
        @{ code = 1722; label = 'RPC server unavailable'; pattern = 'rpc server is unavailable'; meaning = 'The node could not reach the RPC service of a domain controller.'
            next = 'Check routing and firewalls between the node and the domain controllers (TCP 135, 445 and the dynamic RPC range) and that the domain controller answers.' }
        @{ code = 37; label = 'clock skew'; pattern = 'time difference|clock skew|krb_ap_err_skew'; meaning = 'The clock of the node differs from the domain controller by more than the 5 minutes Kerberos allows.'
            next = 'Fix the time first (networking.ntp_servers, the Time step), check with w32tm /stripchart, then run again.' }
        @{ code = 8240; label = 'OU not found'; pattern = 'no such object|0x80072030|organizational unit .* does not exist'; meaning = 'The OU in ou_path does not exist in the domain.'
            next = 'Create the OU, or correct identity.active_directory.ou_path, then run again.' }
    )
    foreach ($row in $table) {
        if ($codes -contains $row.code -or $text -match $row.pattern) {
            return [pscustomobject]@{ code = [string]$row.code; label = $row.label; meaning = $row.meaning; nextAction = $row.next; text = $text }
        }
    }
    return [pscustomobject]@{ code = ''; label = 'not mapped'; meaning = 'Not one of the mapped errors; the exact text is in the evidence.'; nextAction = 'Read the error text, look the code up in Microsoft Learn (NetJoinDomain error codes), fix the cause, then run again. The node stays as it is.'; text = $text }
}

function Get-DjCredential {
    $user = [string](Get-P $S 'joinUser' '')
    $pw = [string](Get-P $S 'joinPassword' '')
    if (-not $user -or -not $pw) { throw 'No join account was passed to the node.' }
    if ($user -notmatch '[\\@]') {
        if ($netbios) { $user = $netbios + '\' + $user } else { $user = $user + '@' + $domain }
    }
    $secure = New-Object System.Security.SecureString
    foreach ($ch in $pw.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    $pw = $null
    return (New-Object System.Management.Automation.PSCredential($user, $secure))
}

function Set-DjResultFromError($ex, [string]$what) {
    $err = ConvertTo-DjError $ex
    $answer.status = 'failed'
    $answer.code = $err.code
    $answer.label = $err.label
    $answer.meaning = $err.meaning
    $answer.errorText = $err.text
    $answer.nextAction = $err.nextAction
    $answer.detail = $what
}

try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $bootNow = $os.LastBootUpTime.ToUniversalTime().ToString('o')

    if ($mode -eq 'join') {
        if ($expectedHost -and $cs.Name -ine $expectedHost) {
            $answer.status = 'failed'; $answer.label = 'host name differs'
            $answer.errorText = 'The computer name is ' + $cs.Name + ', the file says ' + $expectedHost + '.'
            $answer.nextAction = 'Run the Hostname step first (it renames the node and restarts it); the join happens after, so the computer object has the final name.'
        }
        elseif ($cs.PartOfDomain -and $cs.Domain -ine $domain) {
            $answer.status = 'failed'; $answer.label = 'joined to a different domain'
            $answer.errorText = 'The node is a member of ' + $cs.Domain + ', not ' + $domain + '.'
            $answer.nextAction = 'It is never unjoined automatically. If that is intended, run Remove-Computer on the node yourself, then run again.'
        }
        elseif ($cs.PartOfDomain) {
            $answer.status = 'unchanged'; $answer.detail = 'already a member of ' + $cs.Domain
        }
        else {
            $credential = Get-DjCredential
            $S = $null
            Write-DjMarker ([ordered]@{ state = 'Joining'; changeId = $changeId; domain = $domain; ou = $ouPath; host = $cs.Name; bootBefore = $bootNow; startedUtc = (Get-Date).ToUniversalTime().ToString('o'); error = '' })
            $joined = $false
            try {
                Add-Computer -DomainName $domain -OUPath $ouPath -Credential $credential -Force -Restart:$false -ErrorAction Stop | Out-Null
                $joined = $true
            }
            catch {
                Set-DjResultFromError $_.Exception ('Add-Computer to ' + $domain)
                $after = Get-CimInstance Win32_ComputerSystem
                $answer.stillWorkgroup = (-not [bool]$after.PartOfDomain)
                $why = $answer.label
                Write-DjMarker ([ordered]@{ state = 'JoinFailed'; changeId = $changeId; domain = $domain; ou = $ouPath; host = $cs.Name; bootBefore = $bootNow; error = ($why + ' ' + $answer.code).Trim() })
            }
            if ($joined) {
                Write-DjMarker ([ordered]@{ state = 'RebootExpected'; changeId = $changeId; domain = $domain; ou = $ouPath; host = $cs.Name; bootBefore = $bootNow; joinedUtc = (Get-Date).ToUniversalTime().ToString('o'); error = '' })
                $resume = [string](Get-P $P 'resumeScript' '')
                if ($resume) {
                    $resumePath = Join-Path $jdDir 'domainjoin-resume.ps1'
                    Set-Content -LiteralPath $resumePath -Value $resume -Encoding UTF8
                    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $resumePath + '"')
                    $trigger = New-ScheduledTaskTrigger -AtStartup
                    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
                    $answer.detail = 'joined ' + $domain + '; restart expected; resume task registered'
                }
                else { $answer.detail = 'joined ' + $domain + '; restart expected' }
                $answer.status = 'joined'
                $answer.reboot = $true
            }
        }
    }
    elseif ($mode -eq 'move') {
        $dn = [string](Get-P $P 'dn' '')
        $dc = [string](Get-P $P 'dc' $domain)
        if (-not $dn -or -not $ouPath) { throw 'The move needs the computer''s distinguished name and the target OU.' }
        $credential = Get-DjCredential
        $S = $null
        try {
            $plain = $credential.GetNetworkCredential().Password
            $source = New-Object System.DirectoryServices.DirectoryEntry(('LDAP://' + $dc + '/' + $dn), $credential.UserName, $plain)
            $target = New-Object System.DirectoryServices.DirectoryEntry(('LDAP://' + $dc + '/' + $ouPath), $credential.UserName, $plain)
            $plain = $null
            $source.MoveTo($target)
            $answer.status = 'moved'; $answer.detail = 'moved ' + $dn + ' to ' + $ouPath
        }
        catch { Set-DjResultFromError $_.Exception ('Move of ' + $dn) }
    }
    elseif ($mode -eq 'admins') {
        $members = @(Get-P $P 'members' @())
        $present = @(& net.exe localgroup Administrators 2>$null | ForEach-Object { ([string]$_).Trim() })
        $added = @()
        $failedMembers = @()
        foreach ($member in $members) {
            $short = ([string]$member -replace '^.*\\', '')
            if (@($present | Where-Object { $_ -ieq [string]$member -or $_ -ieq $short }).Count) { continue }
            try { Add-LocalGroupMember -Group 'Administrators' -Member ([string]$member) -ErrorAction Stop; $added += [string]$member }
            catch { $failedMembers += ([string]$member + ': ' + $_.Exception.Message) }
        }
        if ($failedMembers.Count) { $answer.status = 'failed'; $answer.label = 'local administrators'; $answer.errorText = ($failedMembers -join '; '); $answer.nextAction = 'Check that each name exists in the domain (a user or a group) and that the node can reach a domain controller; fix local_admin_members, then run again.' }
        else { $answer.status = 'configured'; $answer.detail = $(if ($added.Count) { 'added to Administrators: ' + ($added -join ', ') } else { 'already members' }) }
        $answer.added = $added
    }
    elseif ($mode -eq 'finalize') {        $m = Read-DjMarker
        $keep = [ordered]@{ state = 'Completed'; changeId = $changeId; domain = $domain; ou = $ouPath; host = $cs.Name; bootBefore = [string](Get-P $m 'bootBefore' ''); completedUtc = (Get-Date).ToUniversalTime().ToString('o'); error = '' }
        Write-DjMarker $keep
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
        $answer.status = 'finalized'; $answer.detail = 'marker completed'
    }
    else { throw ('Unknown mode ' + $mode) }
}
catch { Set-DjResultFromError $_.Exception ('DomainJoin ' + $mode) }

$answer.finished = (Get-Date).ToUniversalTime().ToString('o')
Write-Result ([pscustomobject]$answer)
'@

# Read only, with the join credential from the secrets: is the dedicated OU there, is Group Policy inheritance blocked on it (the
# gPOptions attribute is 1), and which GPO links above it are Enforced (flag 2 in gPLink; Block Inheritance does not stop those).
$script:OuCheckBody = @'
$ouPath = [string](Get-P $P 'ou' '')
$domain = [string](Get-P $P 'domain' '')
$dcList = @(Get-P $P 'dcs' @())
$dcHost = $domain
if ($dcList.Count) { $dcHost = [string]$dcList[0] }
$r = [ordered]@{ checked = $false; exists = $false; authFailed = $false; gpOptions = $null; blockInheritance = $false; enforcedLinks = @(); error = '' }
# A rejected credential (wrong password, locked, disabled, expired: HRESULT 0x8007052E and its relatives, LDAP error 49) is not "the OU is missing":
# it is reported as authFailed so that the host stops using the credential. Nothing else is bound after the first rejection.
function Test-DjAuthFailure($ex) {
    $e = $ex
    while ($e) {
        $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.HResult), 0)
        if (($u -shr 16) -eq 0x8007 -and (($u -band 0xFFFF) -in 1326, 1327, 1328, 1329, 1330, 1331, 1793, 1909)) { return $true }
        $ext = $e.PSObject.Properties['ExtendedError']
        if ($ext -and ([int]$ext.Value -in 1326, 1327, 1328, 1329, 1330, 1331, 1793, 1909)) { return $true }
        $e = $e.InnerException
    }
    return ([string]$ex.Message -match '(?i)logon failure|user name or password is incorrect|account currently disabled|account has been disabled|locked out|invalid credentials|password has expired|account has expired')
}
try {
    $user = [string](Get-P $S 'joinUser' '')
    $pw = [string](Get-P $S 'joinPassword' '')
    if (-not $user -or -not $pw) { throw 'No credential was passed to read the OU.' }
    if ($user -notmatch '[\\@]') { $netbios = [string](Get-P $P 'netbios' ''); if ($netbios) { $user = $netbios + '\' + $user } else { $user = $user + '@' + $domain } }
    $parts = @($ouPath -split '(?<!\\),' | ForEach-Object { $_.Trim() })
    $entry = New-Object System.DirectoryServices.DirectoryEntry(('LDAP://' + $dcHost + '/' + $ouPath), $user, $pw)
    try { $entry.RefreshCache(@('gPOptions', 'distinguishedName')); $r.exists = $true }
    catch {
        $r.error = [string]$_.Exception.Message
        if (Test-DjAuthFailure $_.Exception) { $r.authFailed = $true; $r.exists = $true } else { $r.exists = $false }
    }
    if ($r.exists -and -not $r.authFailed) {
        $r.checked = $true
        $opt = 0
        if ($entry.Properties['gPOptions'].Count) { $opt = [int]$entry.Properties['gPOptions'][0] }
        $r.gpOptions = $opt
        $r.blockInheritance = (($opt -band 1) -eq 1)
        $links = @()
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $container = ($parts[$i..($parts.Count - 1)] -join ',')
            try {
                $c = New-Object System.DirectoryServices.DirectoryEntry(('LDAP://' + $dcHost + '/' + $container), $user, $pw)
                $c.RefreshCache(@('gPLink'))
                $gp = ''
                if ($c.Properties['gPLink'].Count) { $gp = [string]$c.Properties['gPLink'][0] }
                foreach ($m in [regex]::Matches($gp, '\[LDAP://([^;\]]+);(\d+)\]')) {
                    $flags = [int]$m.Groups[2].Value
                    if ((($flags -band 2) -eq 2) -and (($flags -band 1) -eq 0)) { $links += ($m.Groups[1].Value + ' (linked at ' + $container + ')') }
                }
            }
            catch { continue }
        }
        $r.enforcedLinks = @($links)
    }
}
catch { $r.error = [string]$_.Exception.Message }
$pw = $null
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; ou = [pscustomobject]$r })
'@

$script:RestartBody = @'
$changeId = [string](Get-P $P 'changeId' '')
$delay = [int](Get-P $P 'delaySeconds' 20)
$m = Read-DjMarker
if (-not $m -or [string](Get-P $m 'state' '') -ne 'RebootExpected' -or ($changeId -and [string](Get-P $m 'changeId' '') -ne $changeId)) {
    Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; restartScheduled = $false; reason = 'No durable restart marker for this change (state ' + $(if ($m) { [string](Get-P $m 'state' '') } else { 'none' }) + '); the node is not restarted.' })
    return
}
$path = Get-DjMarkerPath
$next = [ordered]@{ state = 'Restarting'; changeId = [string](Get-P $m 'changeId' ''); domain = [string](Get-P $m 'domain' ''); ou = [string](Get-P $m 'ou' ''); host = [string](Get-P $m 'host' ''); bootBefore = [string](Get-P $m 'bootBefore' ''); restartingUtc = (Get-Date).ToUniversalTime().ToString('o'); error = '' }
$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $next -Depth 4 -Compress))
$fs = New-Object System.IO.FileStream(($path + '.tmp'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
[System.IO.File]::Replace(($path + '.tmp'), $path, ($path + '.bak'))
& shutdown.exe /r /t $delay /d p:2:4 /c 'Azure Local OS configuration: restart to finish joining the domain'
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; restartScheduled = $true; seconds = $delay })
'@

# Runs at startup, as SYSTEM, from the one-time task Apply registered. No parameters, no secrets.
$script:ResumeBody = @'
$taskName = 'AzureLocal-OSConfig-DomainJoinResume'
$m = Read-DjMarker
if (-not $m) { return }
$state = [string](Get-P $m 'state' '')
if ($state -notin 'RebootExpected', 'Restarting') { return }
$os = Get-CimInstance Win32_OperatingSystem
$bootNow = $os.LastBootUpTime.ToUniversalTime().ToString('o')
$culture = [Globalization.CultureInfo]::InvariantCulture
$round = [Globalization.DateTimeStyles]::RoundtripKind
if ([datetime]::Parse($bootNow, $culture, $round) -le [datetime]::Parse([string](Get-P $m 'bootBefore' ''), $culture, $round)) { return }
$wantDomain = [string](Get-P $m 'domain' '')
$ok = $false
$detail = ''
for ($try = 1; $try -le 8; $try++) {
    $cs = Get-CimInstance Win32_ComputerSystem
    $channel = $false
    try { $channel = [bool](Test-ComputerSecureChannel -ErrorAction Stop) } catch { $channel = $false }
    $ok = ([bool]$cs.PartOfDomain) -and ($cs.Domain -ieq $wantDomain) -and $channel
    $detail = 'PartOfDomain=' + $cs.PartOfDomain + ' Domain=' + $cs.Domain + ' SecureChannel=' + $channel
    if ($ok) { break }
    Start-Sleep -Seconds 15
}
$path = Get-DjMarkerPath
$next = [ordered]@{ state = $(if ($ok) { 'VerifiedAfterRestart' } else { 'VerifyFailedAfterRestart' }); changeId = [string](Get-P $m 'changeId' ''); domain = $wantDomain; ou = [string](Get-P $m 'ou' ''); host = [string](Get-P $m 'host' ''); bootBefore = [string](Get-P $m 'bootBefore' ''); verifiedUtc = (Get-Date).ToUniversalTime().ToString('o'); error = $(if ($ok) { '' } else { $detail }) }
$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $next -Depth 4 -Compress))
$fs = New-Object System.IO.FileStream(($path + '.tmp'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
[System.IO.File]::Replace(($path + '.tmp'), $path, ($path + '.bak'))
try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
'@

function Get-AzlDomainJoinReadSection {
    <#
    .SYNOPSIS
        The text AzlNodePayload puts into the Read script: the domain join functions and the section that fills $Az.domainJoin
        (only when the plan passed a domainJoin parameter, so a node of a local identity design is not asked anything).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ($script:ReadFunctions + [Environment]::NewLine + $script:ReadSection)
}

function Get-AzlDomainJoinPayloadBody {
    <#
    .SYNOPSIS
        The body of a DomainJoin node script: Probe (read only), Apply (join, move, admins, finalize), OuCheck (read only), Restart, Resume. Without the prologue.
    .EXAMPLE
        Get-AzlDomainJoinPayloadBody -Name Apply
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('Probe', 'Apply', 'OuCheck', 'Restart', 'Resume')][string]$Name)
    switch ($Name) {
        'Probe' { return ($script:ReadFunctions + [Environment]::NewLine + $script:ProbeBody) }
        'Apply' { return ($script:ReadFunctions + [Environment]::NewLine + $script:ApplyBody) }
        'OuCheck' { return ($script:ReadFunctions + [Environment]::NewLine + $script:OuCheckBody) }
        'Restart' { return ($script:ReadFunctions + [Environment]::NewLine + $script:RestartBody) }
        'Resume' { return ($script:ReadFunctions + [Environment]::NewLine + $script:ResumeBody) }
    }
}

Export-ModuleMember -Function Get-AzlDomainJoinPayloadBody, Get-AzlDomainJoinReadSection
