#Requires -Version 7.0
<#
.SYNOPSIS
    The scripts that run ON a node for the RemoteManagement step: read its remote management state, stage a profile, commit or
    revert it, or (bootstrap) open WinRM once through Azure Arc Run Command.

.DESCRIPTION
    The node scripts are kept as text here, not as .ps1 files, because they don't run under PowerShell 7: Azure Arc Run Command and
    a plain WinRM session start Windows PowerShell 5.1 on the node, and an Azure Local node ships no pwsh. They use 5.1 syntax
    only (no ternary, no ??, no &&). They are plain strings to this module, which is PowerShell 7.

    Each script takes the same two parameters as the other node payloads:
      ParamsB64   base64 of a JSON object: the mode and the profile to apply. Never a secret.
      SecretsB64  base64 of a JSON object with secrets (a PFX certificate read from Key Vault). Sent as an Arc protected
                  parameter, so Azure never shows it back.
    and writes its answer as one line, AZLRESULT:<base64 of gzip of JSON>.

    Get-AzlRemotingPayload
      Read       Changes nothing. The WinRM service settings, listeners, firewall rules (normalised to CIDR), RDP and NLA, the
                 network categories, the server certificates.
      Change     mode stage | commit | revert. This is the part the guarded change protocol wraps:
                   stage   snapshot of everything it will touch (written before the first change), then the baseline, the
                           listeners and the firewall rules. Nothing is taken away: a firewall scope becomes the union of the old
                           and the new, a second listener is ADDED, the HTTP listener and the * listener stay. If anything
                           throws, the snapshot is restored at once and the answer says so.
                   commit  after the orchestrator confirmed the new path: the exact scope, the HTTP listener and rule removed
                           when the profile says so AND the new path was verified (verified), the * listener removed.
                   revert  the snapshot put back: settings, removed listeners re-created, added ones removed, rules restored.
    The one-time bootstrap (Azure Arc Run Command or SMB) has its own tiny script, in AzlRemotingBootstrap.psm1.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prologue = @'
param([string]$ParamsB64, [string]$SecretsB64)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Get-P($o, [string]$n, $d = $null) {
    if ($null -ne $o -and $o.PSObject.Properties[$n]) { $v = $o.PSObject.Properties[$n].Value; if ($null -ne $v) { return $v } }
    return $d
}
function ConvertFrom-B64Json([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return (New-Object psobject) }
    return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) | ConvertFrom-Json)
}
function Write-Result($o) {
    $json = ConvertTo-Json -InputObject $o -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Close()
    Write-Output ('AZLRESULT:' + [Convert]::ToBase64String($ms.ToArray()))
}
$P = ConvertFrom-B64Json $ParamsB64
$S = ConvertFrom-B64Json $SecretsB64
$stateRoot = 'C:\ProgramData\AzureLocal\osconfig\remoting'
'@

# Read helpers shared by Read and Change.
$script:CoreBase = @'
function ConvertTo-Cidr([string]$a) {
    if (-not $a) { return '' }
    $a = $a.Trim()
    if ($a -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,3}(?:\.\d{1,3}){3})$') {
        $bits = 0
        foreach ($o in ($Matches[2] -split '\.')) { $b = [int]$o; while ($b -gt 0) { $bits += ($b -band 1); $b = $b -shr 1 } }
        return ($Matches[1] + '/' + $bits)
    }
    if ($a -match '^\d{1,3}(?:\.\d{1,3}){3}$') { return ($a + '/32') }
    if ($a -match ':' -and $a -notmatch '/') { return ($a.ToLowerInvariant() + '/128') }
    return $a
}
function Get-NormalProfile([string]$p) {
    if ($p -eq 'Any' -or $p -eq 'All') { return 'Any' }
    $parts = @($p -split ',\s*' | Where-Object { $_ } | Sort-Object)
    if ($parts.Count -eq 3) { return 'Any' }
    return ($parts -join ',')
}
function Get-RuleState([string]$name) {
    $r = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if (-not $r) { return $null }
    $af = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $r
    $pf = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $r
    return [pscustomobject]@{
        name = $name; enabled = ([string]$r.Enabled -eq 'True'); profile = (Get-NormalProfile ([string]$r.Profile))
        remote = @($af.RemoteAddress | ForEach-Object { ConvertTo-Cidr ([string]$_) }); local = @($af.LocalAddress | ForEach-Object { ConvertTo-Cidr ([string]$_) })
        protocol = [string]$pf.Protocol; port = [string]$pf.LocalPort
    }
}
# The rules that let WinRM in, found by what they allow (inbound TCP 5985 or 5986), not by a name: the names differ by Windows version
# (they differ by Windows version). The rules of this tool are left out.
function Get-WinRmRuleName {
    $names = @()
    foreach ($f in @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { @($_.LocalPort) -contains '5985' -or @($_.LocalPort) -contains '5986' })) {
        foreach ($r in @(Get-NetFirewallRule -AssociatedNetFirewallPortFilter $f -ErrorAction SilentlyContinue)) {
            if ([string]$r.Direction -eq 'Inbound' -and [string]$r.Action -eq 'Allow' -and [string]$r.Name -notlike 'AzlOsConfig-*') { $names += [string]$r.Name }
        }
    }
    return @($names | Select-Object -Unique)
}
function Get-WsmanValue([string]$path) {
    try { return [string](Get-Item -LiteralPath $path -ErrorAction Stop).Value } catch { return $null }
}
function Get-ServiceState {
    $running = ((Get-Service WinRM).Status -eq 'Running')
    return [pscustomobject]@{
        running = $running
        allowUnencrypted = $(if ($running) { Get-WsmanValue 'WSMan:\localhost\Service\AllowUnencrypted' } else { $null })
        basic = $(if ($running) { Get-WsmanValue 'WSMan:\localhost\Service\Auth\Basic' } else { $null })
        credSsp = $(if ($running) { Get-WsmanValue 'WSMan:\localhost\Service\Auth\CredSSP' } else { $null })
        cbt = $(if ($running) { Get-WsmanValue 'WSMan:\localhost\Service\Auth\CbtHardeningLevel' } else { $null })
        compatHttp = $(if ($running) { Get-WsmanValue 'WSMan:\localhost\Service\EnableCompatibilityHttpListener' } else { $null })
        compatHttps = $(if ($running) { Get-WsmanValue 'WSMan:\localhost\Service\EnableCompatibilityHttpsListener' } else { $null })
    }
}
function Get-ListenerState {
    $list = @()
    if ((Get-Service WinRM).Status -ne 'Running') { return $list }
    foreach ($l in @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)) {
        $keys = @{}
        foreach ($k in @($l.Keys)) { $pair = ([string]$k) -split '=', 2; if ($pair.Count -eq 2) { $keys[$pair[0]] = $pair[1] } }
        $props = @{}
        foreach ($c in @(Get-ChildItem -LiteralPath $l.PSPath -ErrorAction SilentlyContinue)) { $props[$c.Name] = [string]$c.Value }
        $list += [pscustomobject]@{ transport = [string]$keys['Transport']; address = [string]$keys['Address']; port = [string]$props['Port']; thumbprint = [string]$props['CertificateThumbprint']; hostname = [string]$props['Hostname'] }
    }
    return $list
}
function Get-CertState($c) {
    $dns = @(); $ips = @()
    $san = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if ($san) {
        foreach ($line in ($san.Format($true) -split "`r?`n")) {
            if ($line -match '^\s*(DNS Name|DNS-Name)\s*=\s*(.+?)\s*$') { $dns += $Matches[2] }
            elseif ($line -match '^\s*(IP Address|IP-Address)\s*=\s*(.+?)\s*$') { $ips += $Matches[2] }
        }
    }
    $eku = @($c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | ForEach-Object { $_.Format($false) })
    return [pscustomobject]@{
        thumbprint = $c.Thumbprint; subject = $c.Subject; notAfter = $c.NotAfter.ToUniversalTime().ToString('o'); dns = $dns; ips = $ips
        serverAuth = [bool]((($eku -join ' ') -match 'Server Authentication') -or $eku.Count -eq 0); privateKey = [bool]$c.HasPrivateKey; selfSigned = ($c.Subject -eq $c.Issuer)
    }
}
'@

$script:ReadBody = @'
$err = @{}
$service = $null; $listeners = @(); $rules = @(); $winrmRules = @(); $certs = @(); $categories = @(); $rdp = $null; $tls = $null; $domain = $false; $addresses = @(); $wantCert = $null
try { $service = Get-ServiceState } catch { $err['service'] = $_.Exception.Message }
try { $listeners = @(Get-ListenerState) } catch { $err['listeners'] = $_.Exception.Message }
try { foreach ($n in @(Get-P $P 'ruleNames' @())) { $r = Get-RuleState ([string]$n); if ($r) { $rules += $r } } } catch { $err['rules'] = $_.Exception.Message }
try { foreach ($n in @(Get-WinRmRuleName)) { $r = Get-RuleState $n; if ($r) { $winrmRules += $r } } } catch { $err['winrmRules'] = $_.Exception.Message }
try {
    $min = (Get-Date).AddDays(1)
    $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.NotAfter -gt $min -and $_.HasPrivateKey } | Select-Object -First 12 | ForEach-Object { Get-CertState $_ })
    $thumb = [string](Get-P $P 'certThumbprint' '')
    if ($thumb) { $c = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $thumb) -ErrorAction SilentlyContinue; if ($c) { $wantCert = Get-CertState $c } }
} catch { $err['certs'] = $_.Exception.Message }
try { $categories = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ alias = [string]$_.InterfaceAlias; category = [string]$_.NetworkCategory } }) } catch { $err['categories'] = $_.Exception.Message }
try {
    $ts = Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    $nla = Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction SilentlyContinue
    $rdp = [pscustomobject]@{ deny = [int]$ts.fDenyTSConnections; nla = $(if ($nla) { [int]$nla.UserAuthentication } else { $null }) }
} catch { $err['rdp'] = $_.Exception.Message }
try {
    $t = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name Enabled -ErrorAction SilentlyContinue
    $tls = [pscustomobject]@{ tls12ServerEnabled = $(if ($t) { [int]$t.Enabled } else { $null }) }
} catch { $err['tls'] = $_.Exception.Message }
try { $domain = [bool](Get-CimInstance Win32_ComputerSystem).PartOfDomain } catch { $err['domain'] = $_.Exception.Message }
try { $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { [string]$_.IPAddress }) } catch { $err['addresses'] = $_.Exception.Message }
$pending = $null
$pendingFile = Join-Path $stateRoot 'pending.json'
if (Test-Path -LiteralPath $pendingFile) { try { $pending = Get-Content -LiteralPath $pendingFile -Raw | ConvertFrom-Json } catch { $pending = $null } }
Write-Result ([pscustomobject]@{
        v = 1; host = $env:COMPUTERNAME; domainJoined = $domain; service = $service; listeners = $listeners; rules = $rules; winrmRules = $winrmRules; certs = $certs
        wantCert = $wantCert; categories = $categories; rdp = $rdp; tls = $tls; addresses = $addresses; pending = $pending; err = $err
    })
'@

# The pieces that change things: used by Change.
$script:CoreApply = @'
$mgmtIp = [string](Get-P $P 'managementIp' '')
$currentIp = [string](Get-P $P 'currentAddress' '')
$bind = [string](Get-P $P 'listenerBind' 'any')
function Test-OwnAddress([string]$ip) { return [bool]($ip -and @(Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue).Count -gt 0) }
# The addresses this node holds out of the management address in the file and the address this session came in on. The file's
# address may not be assigned yet (the Network step runs after this one); the address in use must stay reachable.
function Get-OwnManagementAddress { return @(@($mgmtIp, $currentIp) | Where-Object { $_ -and (Test-OwnAddress $_) } | Select-Object -Unique) }
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$id, [string]$status, [string]$detail) { [void]$results.Add([pscustomobject]@{ id = $id; status = $status; detail = $detail }) }
function Set-WsmanValue([string]$path, $value) { Set-Item -LiteralPath $path -Value $value -Force }
function Set-Baseline {
    if ((Get-Service WinRM).StartType -ne 'Automatic') { Set-Service -Name WinRM -StartupType Automatic }
    if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
    # Enable-PSRemoting creates the listener and enables the built-in rules on every profile (SkipNetworkProfileCheck: a Public network is fine). The scope of those rules is set below, from the profile.
    if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count -eq 0 -or (Get-P $P 'httpListener' $false)) { Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null }
    $want = @(
        @('WSMan:\localhost\Service\AllowUnencrypted', 'false'), @('WSMan:\localhost\Service\Auth\Basic', 'false'), @('WSMan:\localhost\Service\Auth\CredSSP', 'false'),
        @('WSMan:\localhost\Service\Auth\CbtHardeningLevel', 'Strict'), @('WSMan:\localhost\Service\EnableCompatibilityHttpListener', 'false'), @('WSMan:\localhost\Service\EnableCompatibilityHttpsListener', 'false')
    )
    $changed = @()
    foreach ($w in $want) {
        $have = Get-WsmanValue $w[0]
        if ($have -ne $w[1]) { Set-WsmanValue $w[0] $w[1]; $changed += ($w[0].Split('\')[-1] + '=' + $w[1]) }
    }
    if ($changed.Count) { return ('WinRM baseline set: ' + ($changed -join ', ')) }
    return 'WinRM baseline already set'
}
function Resolve-ServerCertificate {
    $mode = [string](Get-P $P 'certMode' 'none')
    if ($mode -eq 'thumbprint') {
        $c = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + [string](Get-P $P 'certThumbprint' '')) -ErrorAction SilentlyContinue
        if (-not $c) { throw ('The certificate ' + [string](Get-P $P 'certThumbprint' '') + ' is not in LocalMachine\My on this node.') }
        return $c
    }
    if ($mode -eq 'keyVault') {
        $pfx = [string](Get-P $S 'certificatePfx' '')
        if (-not $pfx) { throw 'The certificate (Key Vault PFX) was not passed to the node.' }
        $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
        $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2([Convert]::FromBase64String($pfx), '', $flags)
        $store = New-Object Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
        $store.Open('ReadWrite'); $store.Add($c); $store.Close()
        return $c
    }
    # selfSigned: the pre-join bootstrap certificate, with DNS names and IP addresses as subject alternative names ONLY
    $names = @(@(Get-P $P 'dnsNames' @()) + @($env:COMPUTERNAME.ToLowerInvariant()) | Where-Object { $_ } | Select-Object -Unique)
    $ips = @(@(Get-P $P 'ipAddresses' @()) + @($mgmtIp) | Where-Object { $_ } | Select-Object -Unique)
    $soon = (Get-Date).AddDays(30)
    $existing = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'AzlOsConfig WinRM bootstrap' -and $_.NotAfter -gt $soon -and $_.HasPrivateKey } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($existing) {
        $state = Get-CertState $existing
        $missing = @($names | Where-Object { $state.dns -notcontains $_ }) + @($ips | Where-Object { $state.ips -notcontains $_ })
        if ($missing.Count -eq 0) { return $existing }
    }
    $san = ((@($names | ForEach-Object { 'DNS=' + $_ }) + @($ips | ForEach-Object { 'IPAddress=' + $_ })) -join '&')
    $days = [int](Get-P $P 'certDays' 365)
    return (New-SelfSignedCertificate -Subject ('CN=' + $names[0]) -FriendlyName 'AzlOsConfig WinRM bootstrap' -CertStoreLocation Cert:\LocalMachine\My -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays($days) -KeyUsage DigitalSignature, KeyEncipherment -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1', ('2.5.29.17={text}' + $san)))
}
function Add-Listener([string]$transport, [string]$address, $cert) {
    $sel = @{ Address = $address; Transport = $transport }
    if ($transport -eq 'HTTPS') {
        $cn = ($cert.Subject -replace '^CN=', '' -split ',')[0]
        New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet $sel -ValueSet @{ Hostname = $cn; CertificateThumbprint = $cert.Thumbprint } | Out-Null
    }
    else { New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet $sel | Out-Null }
}
function Remove-Listener([string]$transport, [string]$address) {
    Remove-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{ Address = $address; Transport = $transport }
}
function Get-ListenerAddress {
    if ($bind -eq 'managementIp') {
        $own = @(Get-OwnManagementAddress)
        if ($own.Count -eq 0) { throw 'The listener is to be bound to the management IP, and neither the management IP in the file nor the address of this session is an address of this node.' }
        return ('IP:' + $own[0])
    }
    return '*'
}
function Add-Listeners($cert) {
    $address = Get-ListenerAddress
    $have = @(Get-ListenerState)
    $text = @()
    if (Get-P $P 'httpListener' $false) {
        $anyHttp = @($have | Where-Object { $_.transport -eq 'HTTP' -and ($_.address -eq $address -or ($bind -eq 'any')) })
        if ($anyHttp.Count -eq 0) { Add-Listener 'HTTP' $address $null; $text += ('HTTP listener on ' + $address) }
    }
    if ((Get-P $P 'httpsListener' $false) -and $cert) {
        $same = @($have | Where-Object { $_.transport -eq 'HTTPS' -and $_.address -eq $address -and $_.thumbprint -eq $cert.Thumbprint })
        if ($same.Count -eq 0) {
            foreach ($old in @($have | Where-Object { $_.transport -eq 'HTTPS' -and $_.address -eq $address })) { Remove-Listener 'HTTPS' $old.address }
            Add-Listener 'HTTPS' $address $cert
            $text += ('HTTPS listener on ' + $address + ' with ' + $cert.Thumbprint)
        }
    }
    if ($text.Count) { return ($text -join '; ') }
    return 'listeners already as wanted'
}
function Set-ManagedRule($spec, [bool]$union) {
    $name = [string]$spec.name
    $remote = @($spec.remote | ForEach-Object { [string]$_ })
    $local = @(Get-OwnManagementAddress)
    if ($local.Count -eq 0 -or -not [bool](Get-P $spec 'useLocal' $true)) { $local = @('Any') }
    $have = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if ($have -and $union) {
        $now = Get-RuleState $name
        if ($now -and $now.remote -notcontains 'Any') { $remote = @(@($remote) + @($now.remote) | Select-Object -Unique) }
        elseif ($now) { $remote = @('Any') }
    }
    if ($remote -contains 'Any') { $remote = @('Any') }
    if (-not $have) {
        $args2 = @{ Name = $name; DisplayName = [string]$spec.display; Group = 'Azure Local OS configuration'; Direction = 'Inbound'; Action = 'Allow'; Protocol = [string]$spec.protocol; Profile = 'Any'; RemoteAddress = $remote; LocalAddress = $local; Enabled = 'True' }
        if ([string](Get-P $spec 'port' '')) { $args2['LocalPort'] = [string]$spec.port }
        if ([string](Get-P $spec 'icmpType' '')) { $args2['IcmpType'] = [string]$spec.icmpType }
        New-NetFirewallRule @args2 | Out-Null
    }
    else { Set-NetFirewallRule -Name $name -Enabled True -Profile Any -RemoteAddress $remote -LocalAddress $local }
    return ($name + ' from ' + ($remote -join ', '))
}
# The rules Windows ships for WinRM, found by port: enabled, on every profile, with the scope of the profile. The OS install ships the
# Public one limited to LocalSubnet, which a remote orchestrator cannot use. None found: our own rules carry the scope.
function Set-DiscoveredWinRmScope($spec, [bool]$union) {
    $names = @(Get-WinRmRuleName)
    if ($names.Count -eq 0) { return 'no built-in WinRM rule found' }
    $done = @()
    foreach ($name in $names) {
        $remote = @($spec.remote | ForEach-Object { [string]$_ })
        if ($union) {
            $now = Get-RuleState $name
            if ($now -and $now.remote -notcontains 'Any') { $remote = @(@($remote) + @($now.remote) | Select-Object -Unique) }
            elseif ($now) { $remote = @('Any') }
        }
        if ($remote -contains 'Any') { $remote = @('Any') }
        Set-NetFirewallRule -Name $name -Enabled True -Profile Any -RemoteAddress $remote
        $done += ($name + ' (every profile, from ' + ($remote -join ', ') + ')')
    }
    return ($done -join '; ')
}
function Disable-DiscoveredWinRm {
    $names = @(Get-WinRmRuleName)
    foreach ($name in $names) { Set-NetFirewallRule -Name $name -Enabled False }
    return ('disabled: ' + ($names -join ', '))
}function Remove-ManagedRule([string]$name) {
    if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name; return ($name + ' removed') }
    return ($name + ' already absent')
}
'@

$script:SnapshotCore = @'
function New-Snapshot([string]$id) {
    $dir = Join-Path $stateRoot 'changes'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    & icacls.exe $stateRoot /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
    $path = Join-Path $dir ($id + '.json')
    if (Test-Path -LiteralPath $path) { return $path }
    $names = @(@(Get-P $P 'ruleNames' @()) + @(Get-WinRmRuleName) | Select-Object -Unique)
    $snap = [pscustomobject]@{
        changeId = $id; taken = (Get-Date).ToUniversalTime().ToString('o'); service = (Get-ServiceState); listeners = @(Get-ListenerState)
        rules = @($names | ForEach-Object { Get-RuleState ([string]$_) } | Where-Object { $_ }); ruleNames = $names
        rdp = $(try { $ts = Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server'; $nla = Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction SilentlyContinue; [pscustomobject]@{ deny = [int]$ts.fDenyTSConnections; nla = $(if ($nla) { [int]$nla.UserAuthentication } else { $null }) } } catch { $null })
    }
    ConvertTo-Json -InputObject $snap -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
function Restore-Snapshot([string]$id) {
    $path = Join-Path (Join-Path $stateRoot 'changes') ($id + '.json')
    if (-not (Test-Path -LiteralPath $path)) { throw ('No snapshot for change ' + $id + ' on this node.') }
    $snap = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $done = @()
    # WinRM settings
    $map = @{ allowUnencrypted = 'AllowUnencrypted'; compatHttp = 'EnableCompatibilityHttpListener'; compatHttps = 'EnableCompatibilityHttpsListener' }
    foreach ($k in $map.Keys) { $v = [string](Get-P $snap.service $k ''); if ($v) { try { Set-WsmanValue ('WSMan:\localhost\Service\' + $map[$k]) $v.ToLowerInvariant() } catch { $done += ('setting ' + $k + ': ' + $_.Exception.Message) } } }
    foreach ($pair in @(@('basic', 'Auth\Basic'), @('credSsp', 'Auth\CredSSP'), @('cbt', 'Auth\CbtHardeningLevel'))) { $v = [string](Get-P $snap.service $pair[0] ''); if ($v) { try { Set-WsmanValue ('WSMan:\localhost\Service\' + $pair[1]) $v } catch { $done += ('setting ' + $pair[0] + ': ' + $_.Exception.Message) } } }
    # listeners: put back what was there, then take away what was added
    $now = @(Get-ListenerState)
    foreach ($l in @($snap.listeners)) {
        $still = @($now | Where-Object { $_.transport -eq $l.transport -and $_.address -eq $l.address })
        if ($still.Count -eq 0) {
            try {
                $sel = @{ Address = [string]$l.address; Transport = [string]$l.transport }
                if ($l.transport -eq 'HTTPS') { New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet $sel -ValueSet @{ Hostname = [string]$l.hostname; CertificateThumbprint = [string]$l.thumbprint } | Out-Null }
                else { New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet $sel | Out-Null }
            } catch { $done += ('listener ' + $l.transport + ' ' + $l.address + ': ' + $_.Exception.Message) }
        }
    }
    $now = @(Get-ListenerState)
    foreach ($l in $now) {
        $was = @($snap.listeners | Where-Object { $_.transport -eq $l.transport -and $_.address -eq $l.address })
        if ($was.Count -eq 0) { try { Remove-Listener $l.transport $l.address } catch { $done += ('listener ' + $l.transport + ' ' + $l.address + ': ' + $_.Exception.Message) } }
    }
    # firewall rules: back to their old scope, or removed when they did not exist
    foreach ($n in @($snap.ruleNames)) {
        $was = @($snap.rules | Where-Object { $_.name -eq $n }) | Select-Object -First 1
        try {
            if ($was) {
                if (Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue) { Set-NetFirewallRule -Name $n -Enabled $(if ($was.enabled) { 'True' } else { 'False' }) -Profile ([string]$was.profile) -RemoteAddress @($was.remote) -LocalAddress @($was.local) }
            }
            else { $null = Remove-ManagedRule $n }
        } catch { $done += ('rule ' + $n + ': ' + $_.Exception.Message) }
    }

    if ($snap.rdp) {
        try {
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ([int]$snap.rdp.deny)
            if ($null -ne $snap.rdp.nla) { Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value ([int]$snap.rdp.nla) }
        } catch { $done += ('RDP: ' + $_.Exception.Message) }
    }
    return $done
}
function Test-LocalPort([string]$address, [int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $a = $c.BeginConnect($address, $port, $null, $null); if ($a.AsyncWaitHandle.WaitOne(3000) -and $c.Connected) { $c.EndConnect($a); return $true } return $false } catch { return $false } finally { $c.Close() }
}
'@

$script:ChangeBody = @'
$mode = [string](Get-P $P 'mode' 'stage')
$changeId = [string](Get-P $P 'changeId' '')
if (-not $changeId) { throw 'No change id.' }
$verified = [bool](Get-P $P 'verified' $false)
$rules = @(Get-P $P 'rules' @())
$listeners = @(Get-P $P 'listeners' @())
$cert = $null
$reverted = $false
$thumb = ''
$certPublic = ''
$fail = ''

# Turning RDP on (with NLA) happens at stage; turning it off waits for the commit, like everything else that is taken away.
function Set-RdpState([bool]$committing) {
    $on = [bool](Get-P $P 'rdpEnabled' $false)
    if ($on) {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
    }
    elseif ($committing) { Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1 }
}
function Disable-BuiltinRule([string]$name) {
    $r = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if ($r) { Set-NetFirewallRule -Name $name -Enabled False; return ($name + ' disabled') }
    return ($name + ' not on this node')
}

if ($mode -eq 'revert') {
    try { $problems = @(Restore-Snapshot $changeId); Add-Result 'revert' 'changed' $(if ($problems.Count) { 'restored with problems: ' + ($problems -join '; ') } else { 'the snapshot was restored' }); $reverted = ($problems.Count -eq 0); if ($reverted) { Remove-Item -LiteralPath (Join-Path $stateRoot 'pending.json') -Force -ErrorAction SilentlyContinue } }
    catch { Add-Result 'revert' 'failed' $_.Exception.Message }
}
elseif ($mode -eq 'stage') {
    try {
        $null = New-Snapshot $changeId
        New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
        ConvertTo-Json -InputObject ([pscustomobject]@{ changeId = $changeId; taken = (Get-Date).ToUniversalTime().ToString('o') }) -Compress | Set-Content -LiteralPath (Join-Path $stateRoot 'pending.json') -Encoding UTF8
        Add-Result 'baseline' 'changed' (Set-Baseline)
        if (Get-P $P 'httpsListener' $false) {
            $cert = Resolve-ServerCertificate
            $thumb = $cert.Thumbprint
            $certPublic = [Convert]::ToBase64String($cert.RawData)
        }
        Add-Result 'listeners' 'changed' (Add-Listeners $cert)
        foreach ($r in $rules) {
            if ([string]$r.kind -eq 'managed' -and [string]$r.desired -ne 'absent') { Add-Result ([string]$r.name) 'changed' (Set-ManagedRule $r $true) }
            elseif ([string]$r.kind -eq 'discoverWinRm') { Add-Result 'winrm-builtin-rules' 'changed' (Set-DiscoveredWinRmScope $r $true) }
        }
        Set-RdpState $false
        Add-Result 'rdp' 'changed' $(if ([bool](Get-P $P 'rdpEnabled' $false)) { 'RDP allowed, NLA required' } else { 'RDP left as it is until the commit' })
        # local proof: the listeners answer on this node
        foreach ($l in $listeners) {
            if ([string]$l.desired -eq 'present') {
                $own = @(Get-OwnManagementAddress)
                $ip = $(if ($own.Count) { $own[0] } else { '127.0.0.1' })
                if (-not (Test-LocalPort $ip ([int]$l.port))) { throw ('The ' + $l.transport + ' listener does not answer on ' + $ip + ':' + $l.port + ' after the change.') }
            }
        }
        Add-Result 'verify' 'changed' 'the listeners answer locally'
    }
    catch {
        $fail = $_.Exception.Message
        Add-Result 'stage' 'failed' $fail
        try { $problems = @(Restore-Snapshot $changeId); $reverted = ($problems.Count -eq 0); Add-Result 'revert' 'changed' $(if ($problems.Count) { 'restored with problems: ' + ($problems -join '; ') } else { 'the snapshot was restored after the failure' }) }
        catch { Add-Result 'revert' 'failed' $_.Exception.Message }
    }
}
elseif ($mode -eq 'commit') {
    try {
        foreach ($r in $rules) {
            $kind = [string]$r.kind
            $desired = [string]$r.desired
            if ($kind -eq 'managed') {
                if ($desired -eq 'present') { Add-Result ([string]$r.name) 'changed' (Set-ManagedRule $r $false) }
                elseif ($desired -eq 'absent' -or ($desired -eq 'absentAfterVerify' -and $verified)) { Add-Result ([string]$r.name) 'changed' (Remove-ManagedRule ([string]$r.name)) }
                else { Add-Result ([string]$r.name) 'skipped' 'kept: the new path is not verified yet' }
            }
            elseif ($kind -eq 'discoverWinRm') {
                if ($desired -eq 'present') { Add-Result 'winrm-builtin-rules' 'changed' (Set-DiscoveredWinRmScope $r $false) }
                elseif ($desired -eq 'absent' -or ($desired -eq 'absentAfterVerify' -and $verified)) { Add-Result 'winrm-builtin-rules' 'changed' (Disable-DiscoveredWinRm) }
            }
            elseif ($kind -eq 'disableRule') {
                if ($desired -eq 'absent' -or ($desired -eq 'absentAfterVerify' -and $verified)) { Add-Result ([string]$r.name) 'changed' (Disable-BuiltinRule ([string]$r.name)) }
            }
        }
        $address = Get-ListenerAddress
        $keep = @()
        if (Get-P $P 'httpListener' $false) { $keep += ('HTTP|' + $address) }
        if (Get-P $P 'httpsListener' $false) { $keep += ('HTTPS|' + $address) }
        foreach ($l in $listeners) {
            $desired = [string]$l.desired
            if ($desired -eq 'absent' -or ($desired -eq 'absentAfterVerify' -and $verified)) {
                foreach ($have in @(Get-ListenerState | Where-Object { $_.transport -eq [string]$l.transport -and ([string]$l.address -eq 'ANY' -or $_.address -eq [string]$l.address) })) {
                    if ($keep -notcontains ($have.transport + '|' + $have.address)) { Remove-Listener $have.transport $have.address; Add-Result 'listeners' 'changed' ('removed ' + $have.transport + ' listener on ' + $have.address) }
                }
            }
        }        Set-RdpState $true
        Add-Result 'commit' 'changed' 'committed'
        Remove-Item -LiteralPath (Join-Path $stateRoot 'pending.json') -Force -ErrorAction SilentlyContinue
    }
    catch { $fail = $_.Exception.Message; Add-Result 'commit' 'failed' $fail }
}
else { throw ('Unknown mode ' + $mode) }

Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; mode = $mode; changeId = $changeId; ok = ($fail -eq ''); reverted = $reverted; thumbprint = $thumb; certPublic = $certPublic; results = @($results) })
'@

function Get-AzlRemotingPayload {
    <#
    .SYNOPSIS
        The text of a RemoteManagement node script: Read (changes nothing), Change (stage, commit or revert).
    .EXAMPLE
        Get-AzlRemotingPayload -Name Read
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('Read', 'Change')][string]$Name)
    $nl = "`n"
    switch ($Name) {
        'Read' { return ($script:Prologue + $nl + $script:CoreBase + $nl + $script:ReadBody) }
        'Change' { return ($script:Prologue + $nl + $script:CoreBase + $nl + $script:CoreApply + $nl + $script:SnapshotCore + $nl + $script:ChangeBody) }
    }
}

Export-ModuleMember -Function Get-AzlRemotingPayload
