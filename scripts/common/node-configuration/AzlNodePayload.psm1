#Requires -Version 7.0
<#
.SYNOPSIS
    The scripts that run ON an Azure Local node for OS configuration: read its state, apply the changes the plan names,
    collect the last result, restart it.

.DESCRIPTION
    The node scripts are kept as text here, not as .ps1 files, because they don't run under PowerShell 7: Azure Arc Run
    Command (and a plain WinRM session) start Windows PowerShell 5.1 on the node, and an Azure Local node ships no pwsh. So
    they use 5.1 syntax only (no ternary, no ??, no &&). They are plain strings to this module, which is PowerShell 7.

    Each script takes the same two parameters:
      ParamsB64   base64 of a JSON object: what to read, or the actions to apply. Never a secret.
      SecretsB64  base64 of a JSON object with secrets (the local administrator's password). Sent as an Arc
                  protected parameter, so Azure never shows it back.
    Each writes its answer as one line, AZLRESULT:<base64 of gzip of JSON>. Arc Run Command keeps only the last 4 KB of
    output, and the compressed line is far smaller than the JSON, so a node with seven ports and six disks still fits.

    Get-AzlNodePayload     The script text for 'Read', 'Apply', 'Collect' or 'Restart'.
    The Read script changes nothing on the node. The Apply script changes only what its actions name, and each action checks
    the item again before it changes it.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# DOMAINJOIN HOOK (feat/os-config-domain-join): the DomainJoin step's node scripts live in their own module.
Import-Module (Join-Path $PSScriptRoot 'AzlNodeDomainJoinPayload.psm1')

# Shared by every payload: parameter decoding and the result line.
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
function Get-MacKey([string]$m) { return (($m -replace '[-:\.]', '')).ToLowerInvariant() }
$P = ConvertFrom-B64Json $ParamsB64
$S = ConvertFrom-B64Json $SecretsB64
$stateDir = 'C:\ProgramData\AzureLocal\osconfig'
'@

$script:ReadBody = @'
$Az = @{ err = @{}; nics = @(); remote = $null; time = $null; sbe = @(); drv = @(); adm = $null; stor = $null; san = $null; domainJoin = $null; reboot = $false }
function Invoke-Section([string]$name, [scriptblock]$sb) {
    try { & $sb } catch { $Az.err[$name] = $_.Exception.Message }
}
function Test-LinkLocal([string]$ip) { return $ip -like '169.254.*' }

$os = Get-CimInstance Win32_OperatingSystem
$ubr = ''
try { $ubr = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR } catch { $ubr = '' }

# ---- ports, found by MAC
Invoke-Section 'nics' {
    $Az.nics = @(foreach ($a in @(Get-NetAdapter -Physical)) {
            $idx = $a.ifIndex
            $ips = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { '{0}/{1}/{2}' -f $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin })
            $gw = @(Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop })
            $ipif = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $dns = @(Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
            $pci = ''
            if ($a.PnPDeviceID -match '^(PCI\\VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4})') { $pci = $Matches[1].ToUpperInvariant() }
            $vlan = $null
            if ((Get-MacKey $a.MacAddress) -eq (Get-MacKey ([string](Get-P $P 'mgmtMac' '')))) {
                $vp = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword 'VlanID' -ErrorAction SilentlyContinue
                if ($vp) { $vlan = [int](@($vp.RegistryValue)[0]) }
            }
            $dhcpState = ''
            if ($ipif) { $dhcpState = [string]$ipif.Dhcp }
            [pscustomobject]@{ n = $a.Name; mac = (Get-MacKey $a.MacAddress); st = [string]$a.Status; pci = $pci; drv = [string]$a.DriverVersionString
                desc = [string]$a.InterfaceDescription; dhcp = $dhcpState; ips = $ips; gw = $gw; dns = $dns; vlan = $vlan }
        })
}

# ---- remote management and ping
Invoke-Section 'remote' {
    $svc = Get-Service WinRM
    $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count
    $deny = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
    $rdpRules = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' }).Count
    $icmp4 = @(Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' }).Count
    $icmp6 = @(Get-NetFirewallRule -Name 'FPS-ICMP6-ERQ-In' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' }).Count
    $Az.remote = [pscustomobject]@{ winrm = [string]$svc.Status; winrmStart = [string]$svc.StartType; listeners = $listeners; rdpDeny = [int]$deny; rdpRules = $rdpRules; icmp4 = $icmp4; icmp6 = $icmp6 }
}

# ---- time
Invoke-Section 'time' {
    $w = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $src = (& w32tm.exe /query /source 2>$null | Select-Object -First 1)
    $Az.time = [pscustomobject]@{ type = [string](Get-P $w 'Type' ''); peers = [string](Get-P $w 'NtpServer' ''); src = [string]$src }
}

# ---- the OEM's SBE package in C:\SBE
$sbeDir = [string](Get-P $P 'sbeDir' 'C:\SBE')
Invoke-Section 'sbe' {
    $Az.sbe = @(foreach ($f in @(Get-P $P 'sbeFiles' @())) {
            $path = Join-Path $sbeDir $f.name
            $len = 0
            $ok = $false
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $len = (Get-Item -LiteralPath $path).Length
                if ($len -eq [int64]$f.size) { $ok = ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq [string]$f.sha256) }
            }
            [pscustomobject]@{ n = [string]$f.name; len = [int64]$len; ok = $ok }
        })
}

# ---- network drivers the SBE carries, for the ports that exist here
Invoke-Section 'drivers' {
    $zipName = [string](Get-P $P 'sbeZip' '')
    $zipOk = $zipName -and @($Az.sbe | Where-Object { $_.n -eq $zipName -and $_.ok }).Count -gt 0
    if (-not $zipOk) { return }
    $wanted = @($Az.nics | ForEach-Object { $_.pci } | Where-Object { $_ } | Select-Object -Unique)
    $roots = @(Get-P $P 'driverPaths' @() | ForEach-Object { ([string]$_).Trim('/') })
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $sbeDir $zipName))
    try {
        $found = @()
        foreach ($e in $zip.Entries) {
            $full = $e.FullName -replace '\\', '/'
            if ($full -notlike '*.inf') { continue }
            $inRoot = $false
            foreach ($r in $roots) { if ($full -like ($r + '/*')) { $inRoot = $true } }
            if (-not $inRoot) { continue }
            $sr = New-Object IO.StreamReader($e.Open())
            try { $text = $sr.ReadToEnd() } finally { $sr.Close() }
            $ids = @([regex]::Matches($text.ToUpperInvariant(), 'PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}') | ForEach-Object { $_.Value } | Select-Object -Unique | Where-Object { $wanted -contains $_ })
            if ($ids.Count -eq 0) { continue }
            $ver = [regex]::Match($text, '(?im)^\s*DriverVer\s*=\s*[^,]+,\s*([\d.]+)').Groups[1].Value
            $found += [pscustomobject]@{ inf = (Split-Path $full -Leaf); ver = $ver; entry = $full; ids = $ids }
        }
        $Az.drv = $found
    }
    finally { $zip.Dispose() }
}

# ---- the deployment's local administrator
Invoke-Section 'admin' {
    $user = [string](Get-P $P 'adminUser' '')
    if (-not $user) { return }
    $u = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
    $inAdmins = $false
    $pwOk = $null
    if ($u) {
        $members = @(& net.exe localgroup Administrators 2>$null)
        $inAdmins = [bool]@($members | Where-Object { $_ -ieq $user -or $_ -like ('*\' + $user) }).Count
        $pw = [string](Get-P $S 'adminPassword' '')
        if ($pw -and $u.Enabled) {
            try {
                Add-Type -AssemblyName System.DirectoryServices.AccountManagement
                $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine')
                $pwOk = [bool]$ctx.ValidateCredentials($user, $pw)
                $ctx.Dispose()
            }
            catch { $pwOk = $null }
        }
    }
    $Az.adm = [pscustomobject]@{ ex = [bool]$u; en = $(if ($u) { [bool]$u.Enabled } else { $false }); adm = $inAdmins; pw = $pwOk }
}

# ---- storage left over from an earlier deployment (counts and a short list; nothing is changed)
Invoke-Section 'storage' {
    $pools = @(Get-StoragePool -ErrorAction SilentlyContinue | Where-Object { -not $_.IsPrimordial }).Count
    $vdisks = @(Get-VirtualDisk -ErrorAction SilentlyContinue).Count
    $skipBus = @('Fibre Channel', 'iSCSI', 'USB', 'File Backed Virtual', 'Spaces', 'Virtual', 'Unknown')
    $dirty = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and ($skipBus -notcontains [string]$_.BusType) -and ([string]$_.PartitionStyle -ne 'RAW' -or [string]$_.OperationalStatus -ne 'Online') } |
            ForEach-Object { '{0}:{1}:{2}' -f $_.Number, $_.BusType, $_.PartitionStyle })
    $Az.stor = [pscustomobject]@{ pools = $pools; vdisks = $vdisks; dirty = $dirty }
}

# ---- SAN: MPIO, MSDSM, FC ports, iSCSI initiator, the LUNs this node sees
if (Get-P $P 'san' $false) {
    Invoke-Section 'san' {
        $feature = ''
        try { $feature = [string](Get-WindowsOptionalFeature -Online -FeatureName MultipathIO).State } catch { $feature = 'Unknown' }
        $hw = @()
        $lb = ''
        $set = @{}
        if (Get-Command Get-MSDSMSupportedHW -ErrorAction SilentlyContinue) {
            $hw = @(Get-MSDSMSupportedHW -ErrorAction SilentlyContinue | ForEach-Object { ('{0}|{1}' -f ([string]$_.VendorId).Trim(), ([string]$_.ProductId).Trim()) })
            $lb = [string](Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction SilentlyContinue)
            $m = Get-MPIOSetting -ErrorAction SilentlyContinue
            if ($m) { foreach ($prop in $m.PSObject.Properties) { if ($prop.Value -is [ValueType] -or $prop.Value -is [string]) { $set[$prop.Name] = [string]$prop.Value } } }
        }
        $ports = @(Get-InitiatorPort -ErrorAction SilentlyContinue | Where-Object { [string]$_.ConnectionType -eq 'Fibre Channel' } |
                ForEach-Object { [pscustomobject]@{ wwpn = (([string]$_.PortAddress) -replace '[:\-\s]', '').ToLowerInvariant(); up = [string]$_.OperationalStatus } })
        $iqn = @(Get-InitiatorPort -ErrorAction SilentlyContinue | Where-Object { [string]$_.ConnectionType -eq 'iSCSI' } | ForEach-Object { [string]$_.NodeAddress })
        $paths = @{}
        try { foreach ($d in @((Get-CimInstance -Namespace root/wmi -ClassName MPIO_DISK_INFO -ErrorAction Stop).DriveInfo)) { $paths[([string]$d.SerialNumber).Trim()] = [int]$d.NumberPaths } } catch { $paths = @{} }
        $disks = @()
        if (Get-P $P 'sanDisks' $false) {
            $disks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { @('Fibre Channel', 'iSCSI') -contains [string]$_.BusType } | ForEach-Object {
                    $lun = $null
                    if ([string]$_.Location -match 'L(\d+)\)?$') { $lun = [int]$Matches[1] }
                    $serial = ([string]$_.SerialNumber).Trim()
                    $count = 0
                    if ($paths.ContainsKey($serial)) { $count = $paths[$serial] }
                    [pscustomobject]@{ n = $_.Number; bus = [string]$_.BusType; gb = [math]::Round($_.Size / 1GB, 1); ps = [string]$_.PartitionStyle; sn = $serial; uid = [string]$_.UniqueId; lun = $lun; paths = $count; st = [string]$_.OperationalStatus }
                })
        }
        $iscsiSvc = ''
        $iscsiClaim = ''
        if ((Get-P $P 'sanType' '') -eq 'iscsi') {
            $svc = Get-Service MSiSCSI -ErrorAction SilentlyContinue
            if ($svc) { $iscsiSvc = ('{0}/{1}' -f $svc.Status, $svc.StartType) }
            if (Get-Command Get-MSDSMAutomaticClaimSettings -ErrorAction SilentlyContinue) { $iscsiClaim = [string](Get-MSDSMAutomaticClaimSettings).iSCSI }
        }
        $Az.san = [pscustomobject]@{ feature = $feature; hw = $hw; lb = $lb; set = $set; fc = $ports; iqn = $iqn; disks = $disks; iscsiSvc = $iscsiSvc; iscsiClaim = $iscsiClaim }
    }
}

#AZL-HOOK:DomainJoinRead
$rebootPending = [bool]((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))

# A section that came back with nothing says why, so a read that returns no data is never mistaken for a node that has none.
if (@($Az.nics).Count -eq 0 -and -not $Az.err.ContainsKey('nics')) { $Az.err['nics'] = 'Get-NetAdapter -Physical returned no adapter (not elevated, or the NetAdapter module is not available)' }
if ($null -eq $Az.remote -and -not $Az.err.ContainsKey('remote')) { $Az.err['remote'] = 'the remote management section returned no data' }
if ($null -eq $Az.time -and -not $Az.err.ContainsKey('time')) { $Az.err['time'] = 'the time section returned no data' }
if ($null -eq $Az.adm -and [string](Get-P $P 'adminUser' '') -and -not $Az.err.ContainsKey('admin')) { $Az.err['admin'] = 'the local administrator section returned no data' }
Write-Result ([pscustomobject]@{
        v = 1; host = $env:COMPUTERNAME; boot = $os.LastBootUpTime.ToUniversalTime().ToString('o'); os = ('{0}.{1}' -f $os.Version, $ubr); reboot = $rebootPending
        nics = $Az.nics; remote = $Az.remote; time = $Az.time; sbe = $Az.sbe; drv = $Az.drv; admin = $Az.adm; stor = $Az.stor; san = $Az.san; domainJoin = $Az.domainJoin; err = $Az.err
    })
'@

$script:ApplyBody = @'
$sbeDir = [string](Get-P $P 'sbeDir' 'C:\SBE')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$results = New-Object System.Collections.ArrayList
$Az = @{ reboot = $false }
function Add-Result([string]$id, [string]$status, [string]$detail) { [void]$results.Add([pscustomobject]@{ id = $id; status = $status; detail = $detail }) }
function Get-NicByMac([string]$mac) {
    return (Get-NetAdapter -Physical | Where-Object { (Get-MacKey $_.MacAddress) -eq (Get-MacKey $mac) } | Select-Object -First 1)
}

function Invoke-Action($a) {
    $id = [string](Get-P $a 'id' '')
    switch ([string](Get-P $a 'kind' '')) {
        'winrm' {
            Set-Service -Name WinRM -StartupType Automatic
            if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
            if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count -eq 0) { Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null }
            return 'WinRM running, automatic, listening'
        }
        'rdp' {
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
            Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
            return 'RDP allowed, firewall group enabled'
        }
        'icmp' {
            foreach ($n in 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In') { Enable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue }
            return 'ICMP echo rules enabled'
        }
        'sbe-file' {
            New-Item -ItemType Directory -Force -Path $sbeDir | Out-Null
            $final = Join-Path $sbeDir ([string]$a.name)
            $tmp = $final + '.part'
            # node_pull: the node downloads the file from the address in infrastructure.yml (hardware.sbe.node_pull_url);
            # the toolkit never sends the file itself. A winrm_copy file never reaches this action.
            $url = [string](Get-P $a 'url' '')
            if (-not $url) { throw ('No download address for ' + $a.name + ' and it is not in ' + $sbeDir) }
            $need = [int64](Get-P $a 'size' 0)
            if ($need -gt 0) {
                $free = (Get-PSDrive -Name ($sbeDir.Substring(0, 1))).Free
                if ($free -lt ($need + 104857600)) { throw ('Only ' + [math]::Round($free / 1MB) + ' MB free on ' + $sbeDir.Substring(0, 2) + '; ' + $a.name + ' needs ' + [math]::Round($need / 1MB) + ' MB plus 100 MB') }
            }
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
            if ($url.StartsWith('\\')) { Copy-Item -LiteralPath $url -Destination $tmp -Force }
            else { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp }
            $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
            if ($hash -ine [string]$a.sha256) { Remove-Item $tmp -Force; throw ('SHA-256 of ' + $a.name + ' is ' + $hash + ', expected ' + $a.sha256) }
            if (Test-Path $final) { Remove-Item $final -Force }
            Move-Item -LiteralPath $tmp -Destination $final
            return ($a.name + ' pulled from ' + $url + ' and SHA-256 verified')
        }
        'driver' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zipPath = Join-Path $sbeDir ([string]$a.zip)
            $dir = Join-Path 'C:\ProgramData\AzureLocal\drivers' ([string]$a.folder)
            if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $entryDir = ([string]$a.entry -replace '\\', '/')
            $entryDir = $entryDir.Substring(0, $entryDir.LastIndexOf('/'))
            $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                foreach ($e in $zip.Entries) {
                    $full = $e.FullName -replace '\\', '/'
                    if (-not $e.Name -or -not $full.StartsWith($entryDir + '/')) { continue }
                    $out = [IO.Path]::GetFullPath((Join-Path $dir ($full.Substring($entryDir.Length + 1) -replace '/', '\')))
                    if (-not $out.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { throw ('Entry ' + $full + ' unpacks outside ' + $dir) }
                    New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
                }
            }
            finally { $zip.Dispose() }
            foreach ($cat in @(Get-ChildItem -LiteralPath $dir -Filter '*.cat' -Recurse)) {
                $sig = Get-AuthenticodeSignature -LiteralPath $cat.FullName
                if ([string]$sig.Status -ne 'Valid') { throw ($cat.Name + ' has signature ' + $sig.Status) }
            }
            $infPath = Join-Path $dir ([string]$a.inf)
            $out = & pnputil.exe /add-driver $infPath /install 2>&1
            $code = $LASTEXITCODE
            if ($code -notin 0, 259, 3010) { throw ('pnputil ' + $a.inf + ' exit ' + $code + ': ' + ($out -join ' ')) }
            if ($code -eq 3010) { $Az.reboot = $true }
            return ('driver ' + $a.inf + ' ' + $a.ver + ' installed (pnputil ' + $code + ')')
        }
        'nic-clean' {
            $nic = Get-NicByMac ([string]$a.mac)
            if (-not $nic) { throw ('No port with MAC ' + $a.mac) }
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled
            Get-NetRoute -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            return ($nic.Name + ': DHCP off, no address, no default route')
        }
        'nic-static' {
            $nic = Get-NicByMac ([string]$a.mac)
            if (-not $nic) { throw ('No port with MAC ' + $a.mac) }
            $gateway = [string](Get-P $a 'gateway' '')
            $wantIp = [string]$a.ip
            $have = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $wantIp -and $_.PrefixOrigin -eq 'Manual' -and $_.PrefixLength -eq [int]$a.prefix }
            $route = $null
            if ($gateway) { $route = Get-NetRoute -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $gateway } }
            if ($have -and ($route -or -not $gateway)) { return ($nic.Name + ': already ' + $wantIp) }
            if ($have -and $gateway) {
                New-NetRoute -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -NextHop $gateway | Out-Null
                return ($nic.Name + ': gateway ' + $gateway + ' added')
            }
            try {
                Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled
                Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                Get-NetRoute -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                if ($gateway) { New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $wantIp -PrefixLength ([int]$a.prefix) -DefaultGateway $gateway | Out-Null }
                else { New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $wantIp -PrefixLength ([int]$a.prefix) | Out-Null }
            }
            catch {
                Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Enabled
                throw ('Static address failed, DHCP turned back on: ' + $_.Exception.Message)
            }
            return ($nic.Name + ': static ' + $wantIp + '/' + $a.prefix + $(if ($gateway) { ' gateway ' + $gateway } else { '' }))
        }
        'nic-dns' {
            $nic = Get-NicByMac ([string]$a.mac)
            if (-not $nic) { throw ('No port with MAC ' + $a.mac) }
            Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($a.servers)
            return ($nic.Name + ': DNS ' + (@($a.servers) -join ','))
        }
        'nic-disable' {
            $nic = Get-NicByMac ([string]$a.mac)
            if (-not $nic) { throw ('No port with MAC ' + $a.mac) }
            Disable-NetAdapter -Name $nic.Name -Confirm:$false
            return ($nic.Name + ': disabled')
        }
        'ntp' {
            $peers = (@($a.servers) | ForEach-Object { $_ + ',0x8' }) -join ' '
            & w32tm.exe /config /manualpeerlist:"$peers" /syncfromflags:manual /reliable:no /update | Out-Null
            Restart-Service w32time
            Start-Sleep -Seconds 3
            & w32tm.exe /resync /force 2>&1 | Out-Null
            return ('time source ' + (@($a.servers) -join ','))
        }
        'hostname' {
            Rename-Computer -NewName ([string]$a.name) -Force
            $Az.reboot = $true
            return ('renamed to ' + $a.name + ' (restart needed)')
        }
        'admin' {
            $user = [string]$a.user
            if ($user -in 'Administrator', 'Guest') { throw ('Refusing built-in account ' + $user + ' as the deployment administrator') }
            $pw = [string](Get-P $S 'adminPassword' '')
            $secure = $null
            if ($pw) { $secure = ConvertTo-SecureString -String $pw -AsPlainText -Force }
            $u = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
            if (-not $u) {
                if (-not $secure) { throw ('No password was given for the new account ' + $user) }
                New-LocalUser -Name $user -Password $secure -PasswordNeverExpires -Description 'Azure Local deployment administrator' | Out-Null
            }
            else {
                if ($a.setPassword -and $secure) { Set-LocalUser -Name $user -Password $secure }
                Set-LocalUser -Name $user -PasswordNeverExpires $true
                if (-not $u.Enabled) { Enable-LocalUser -Name $user }
            }
            $members = @(& net.exe localgroup Administrators 2>$null)
            if (-not @($members | Where-Object { $_ -ieq $user -or $_ -like ('*\' + $user) }).Count) { Add-LocalGroupMember -Group Administrators -Member $user }
            return ($user + ' present, enabled, in Administrators')
        }
        'mpio-feature' {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName MultipathIO -NoRestart
            if ($r.RestartNeeded) { $Az.reboot = $true }
            return 'MultipathIO enabled'
        }
        'msdsm-hw' {
            if ([string](Get-P $a 'mpclaim' '')) { & mpclaim.exe -n -i -d ([string]$a.mpclaim) | Out-Null }
            else { New-MSDSMSupportedHW -VendorId ([string]$a.vendor) -ProductId ([string]$a.product) | Out-Null }
            $Az.reboot = $true
            return ('MSDSM hardware ' + $a.vendor + ' ' + $a.product + ' registered (restart so MPIO claims the LUNs)')
        }
        'msdsm-lb' {
            Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy ([string]$a.policy)
            return ('load balance policy ' + $a.policy)
        }
        'mpio-setting' {
            $map = @{ RetryCount = 'NewRetryCount'; RetryInterval = 'NewRetryInterval'; PathVerificationState = 'NewPathVerificationState'; PathVerificationPeriod = 'NewPathVerificationPeriod'
                PDORemovePeriod = 'NewPDORemovePeriod'; DiskTimeout = 'NewDiskTimeout'; PathRecoveryInterval = 'NewPathRecoveryInterval'; CustomPathRecovery = 'CustomPathRecovery' }
            $args2 = @{}
            foreach ($prop in $a.settings.PSObject.Properties) { if ($map.ContainsKey($prop.Name)) { $args2[$map[$prop.Name]] = $prop.Value } }
            Set-MPIOSetting @args2
            return ('MPIO settings ' + (($args2.Keys | Sort-Object | ForEach-Object { $_ + '=' + $args2[$_] }) -join ', '))
        }
        'iscsi-service' {
            Set-Service -Name MSiSCSI -StartupType Automatic
            Start-Service -Name MSiSCSI
            return 'MSiSCSI automatic and running'
        }
        'iscsi-claim' {
            Enable-MSDSMAutomaticClaim -BusType iSCSI
            return 'MSDSM claims iSCSI disks automatically'
        }
        'storage-clear' {
            # Never touches SAN LUNs, USB or virtual media, boot or system disks.
            Update-StorageProviderCache -ErrorAction SilentlyContinue
            Get-StoragePool -ErrorAction SilentlyContinue | Where-Object { -not $_.IsPrimordial } | Set-StoragePool -IsReadOnly $false -ErrorAction SilentlyContinue
            Get-VirtualDisk -ErrorAction SilentlyContinue | Remove-VirtualDisk -Confirm:$false
            Get-StoragePool -ErrorAction SilentlyContinue | Where-Object { -not $_.IsPrimordial } | Remove-StoragePool -Confirm:$false
            Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { @('Fibre Channel', 'iSCSI', 'USB') -notcontains [string]$_.BusType } | Reset-PhysicalDisk -ErrorAction SilentlyContinue
            $skipBus = @('Fibre Channel', 'iSCSI', 'USB', 'File Backed Virtual', 'Spaces', 'Virtual', 'Unknown')
            $cleared = @()
            foreach ($d in @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and ($skipBus -notcontains [string]$_.BusType) })) {
                if ($d.IsOffline) { Set-Disk -Number $d.Number -IsOffline $false -ErrorAction SilentlyContinue }
                if ($d.IsReadOnly) { Set-Disk -Number $d.Number -IsReadOnly $false -ErrorAction SilentlyContinue }
                if ([string]$d.PartitionStyle -ne 'RAW') { Clear-Disk -Number $d.Number -RemoveData -RemoveOEM -Confirm:$false; $cleared += $d.Number }
            }
            return ('storage cleared; disks reset: ' + ($cleared -join ','))
        }
        default { throw ('Unknown action ' + [string](Get-P $a 'kind' '')) }
    }
}

foreach ($a in @(Get-P $P 'actions' @())) {
    $id = [string](Get-P $a 'id' '')
    try { Add-Result $id 'changed' (Invoke-Action $a) }
    catch { Add-Result $id 'failed' $_.Exception.Message }
}

$answer = [pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; finished = (Get-Date).ToUniversalTime().ToString('o'); reboot = $Az.reboot; results = @($results) }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
ConvertTo-Json -InputObject $answer -Depth 6 -Compress | Set-Content -LiteralPath (Join-Path $stateDir 'last-apply.json') -Encoding UTF8
Write-Result $answer
'@

$script:CollectBody = @'
$file = Join-Path $stateDir 'last-apply.json'
if (-not (Test-Path -LiteralPath $file)) { Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; none = $true }); return }
Write-Result (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
'@

$script:RestartBody = @'
& shutdown.exe /r /t 20 /d p:2:4 /c 'Azure Local OS configuration: restart to finish the changes'
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; restartScheduled = $true })
'@

# Used by the OS configuration run on a machine installed from an ISO: what OS is this, before anything else touches it.
$script:PreflightBody = @'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$ubr = ''
try { $ubr = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR } catch { $ubr = '' }
$agent = Test-Path -LiteralPath 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
$hasArcInit = [bool](Get-Command Invoke-AzStackHciArcInitialization -ErrorAction SilentlyContinue)
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; caption = [string]$os.Caption; build = [int]$os.BuildNumber; ubr = $ubr; productType = [int]$os.ProductType; sku = [int]$os.OperatingSystemSKU; domainJoined = [bool]$cs.PartOfDomain; arcAgent = $agent; arcInit = $hasArcInit })
'@

# Azure Arc registration of a machine installed from an ISO, with the ARM token the caller got from its own Azure sign-in (a Secret).
$script:ArcRegistrationBody = @'
$cmd = Get-Command Invoke-AzStackHciArcInitialization -ErrorAction SilentlyContinue
if (-not $cmd) { throw 'Invoke-AzStackHciArcInitialization is not on this machine. Install the Azure Stack HCI OS (23H2 or later) image from Azure; it ships the Arc initialization module.' }
$token = [string](Get-P $S 'armToken' '')
if (-not $token) { throw 'No ARM access token was passed.' }
$arguments = @{
    SubscriptionID = [string](Get-P $P 'subscriptionId' '')
    ResourceGroup  = [string](Get-P $P 'resourceGroup' '')
    TenantID       = [string](Get-P $P 'tenantId' '')
    Region         = [string](Get-P $P 'region' '')
    Cloud          = [string](Get-P $P 'cloud' 'AzureCloud')
    ArmAccessToken = $token
    AccountID      = [string](Get-P $P 'accountId' '')
}
$gateway = [string](Get-P $P 'arcGatewayId' '')
if ($gateway) { $arguments['ArcGatewayID'] = $gateway }
$null = Invoke-AzStackHciArcInitialization @arguments
Write-Result ([pscustomobject]@{ v = 1; host = $env:COMPUTERNAME; registered = $true })
'@

function Get-AzlNodePayload {
    <#
    .SYNOPSIS
        The text of a node script: Read (changes nothing), Apply, Collect (the last Apply's result) or Restart; Preflight and ArcRegistration for the ISO path; DomainJoinProbe, DomainJoinApply, DomainJoinRestart and DomainJoinResume for the DomainJoin step.
    .EXAMPLE
        Get-AzlNodePayload -Name Read
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('Read', 'Apply', 'Collect', 'Restart', 'Preflight', 'ArcRegistration', 'DomainJoinProbe', 'DomainJoinApply', 'DomainJoinOuCheck', 'DomainJoinRestart', 'DomainJoinResume')][string]$Name)
    $body = switch ($Name) {
        'Read' { $script:ReadBody.Replace('#AZL-HOOK:DomainJoinRead', (Get-AzlDomainJoinReadSection)) } # DOMAINJOIN HOOK
        'Apply' { $script:ApplyBody }
        'Collect' { $script:CollectBody }
        'Restart' { $script:RestartBody }
        'Preflight' { $script:PreflightBody }
        'ArcRegistration' { $script:ArcRegistrationBody }
        'DomainJoinProbe' { Get-AzlDomainJoinPayloadBody -Name Probe } # DOMAINJOIN HOOK: the four DomainJoin scripts
        'DomainJoinApply' { Get-AzlDomainJoinPayloadBody -Name Apply }
        'DomainJoinOuCheck' { Get-AzlDomainJoinPayloadBody -Name OuCheck }
        'DomainJoinRestart' { Get-AzlDomainJoinPayloadBody -Name Restart }
        'DomainJoinResume' { Get-AzlDomainJoinPayloadBody -Name Resume }
    }
    return ($script:Prologue + [Environment]::NewLine + $body)
}

function Get-AzlNodePrologue {
    <#
    .SYNOPSIS
        The shared start of every node script: parameter decoding, Get-P, Write-Result, the state directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:Prologue
}

Export-ModuleMember -Function Get-AzlNodePayload, Get-AzlNodePrologue
