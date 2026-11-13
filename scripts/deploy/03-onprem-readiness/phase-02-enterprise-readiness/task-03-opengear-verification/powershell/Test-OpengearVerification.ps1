<#
.SYNOPSIS
    Checks that every console server of network_devices in infrastructure.yml can be reached and that its login can be read. Changes nothing.

.DESCRIPTION
    Phase 02 (enterprise readiness), Task 03 (console server verification). The console server (Opengear, or another make) is the way to reach
    a node's serial console when the network is not there yet. Its serial ports, users and alerts are set up on the device, in its own tools and
    in its vendor's documentation; Microsoft Learn has nothing on them. The earlier script of this task called a REST interface of the device and
    tested serial port numbers it computed (3000 plus the port number). Neither call is documented for the device in the file, so the script no
    longer makes them. What it does is the check that comes before that work:

    For each entry of network_devices whose type is console_server it reports the device (hostname, role, vendor) and then:
      1. the management address (management.ip_address); an entry whose address is dhcp or missing is skipped, because the address is not known;
      2. whether the address answers a ping (information only: a console server may drop ICMP);
      3. whether the management port accepts a TCP connection. The port follows management.protocol: ssh 22, https 443, telnet 23 (ssh when the
         file gives none). snmp uses UDP, which a TCP check cannot test, so it is skipped;
      4. whether the login of the device can be read: credentials.password is a secret reference, which the toolkit's secret resolver
         (scripts/common/secrets/AzlSecret.psm1) reads into memory and discards. The value is never shown, written or sent anywhere. The script
         does not sign in to the console server.

    Nothing is sent to the device but the TCP connection and the ping. No prompt, no change, no file.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        network_devices[]: hostname, type, role, vendor, management.ip_address, management.protocol, credentials.username, credentials.password

    Exit codes: 0 every console server passed the checks or the file lists none (a skipped entry is not a failure); 1 a console server did not answer on
    its management port, or its password reference could not be read; 2 a value in the file is not usable (a host name listed twice, an address that is
    not IPv4 and not dhcp, a management protocol that is not ssh, https, telnet or snmp).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER TimeoutSeconds
    How long to wait for a ping or a TCP connection of one device. Default 5.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-OpengearVerification.ps1 -InfrastructureFile ./infrastructure.yml

    Checks the console servers of the file and prints one row each.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 5,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# The kind of device this script checks (the type values of network_devices).
$DeviceType = 'console_server'
# The TCP port of each management protocol (SSH, HTTPS and Telnet are fixed by their standards). SNMP is UDP: no TCP check.
$ManagementPort = @{ ssh = 22; https = 443; telnet = 23 }
$Ipv4 = '^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Entry([object]$Entry, [string]$Key) {
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Key) -and $null -ne $Entry[$Key]) { return ([string]$Entry[$Key]).Trim() }
    ''
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$raw = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'network_devices'
$devices = @(@($raw) | Where-Object { $_ -is [System.Collections.IDictionary] -and (Get-Entry $_ 'type') -ieq $DeviceType })
if ($devices.Count -eq 0) {
    Write-Line "The file lists no network_devices of type ${DeviceType}: nothing to do."
    exit 0
}

$plan = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$index = -1
foreach ($device in $devices) {
    $index++
    $name = Get-Entry $device 'hostname'
    if (-not $name) { Exit-InputProblem "A network_devices entry of type $DeviceType has no hostname." }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "The hostname '$name' is listed twice in network_devices." }
    $seen[$name.ToLowerInvariant()] = $true
    $management = if ($device.Contains('management') -and $device['management'] -is [System.Collections.IDictionary]) { $device['management'] } else { @{} }
    $address = Get-Entry $management 'ip_address'
    if ($address -and $address -ine 'dhcp' -and $address -notmatch $Ipv4) { Exit-InputProblem "network_devices '$name': management.ip_address '$address' is not an IPv4 address or dhcp." }
    $protocol = (Get-Entry $management 'protocol').ToLowerInvariant()
    if (-not $protocol) { $protocol = 'ssh' }
    if ($protocol -notin 'ssh', 'https', 'telnet', 'snmp') { Exit-InputProblem "network_devices '$name': management.protocol '$protocol' is not ssh, https, telnet or snmp." }
    $credentials = if ($device.Contains('credentials') -and $device['credentials'] -is [System.Collections.IDictionary]) { $device['credentials'] } else { @{} }
    $plan.Add([pscustomobject]@{
            Name = $name; Role = (Get-Entry $device 'role'); Vendor = (Get-Entry $device 'vendor'); Address = $address; Protocol = $protocol
            User = (Get-Entry $credentials 'username'); PasswordReference = (Get-Entry $credentials 'password')
        })
}

Write-Line "Checking $($plan.Count) device(s) of type $DeviceType"
$rows = foreach ($item in $plan) {
    $row = [ordered]@{ Device = $item.Name; Role = $item.Role; Vendor = $item.Vendor; Address = $item.Address; Port = ''; Ping = ''; Management = ''; Login = ''; Action = ''; Detail = '' }
    $problems = [System.Collections.Generic.List[string]]::new()
    if (-not $item.Address -or $item.Address -ieq 'dhcp') {
        $row.Action = 'Skipped'; $row.Detail = 'The management address is dhcp or not set, so the device cannot be reached from the file.'
        Write-Line "[skip]    $($item.Name): $($row.Detail)"
        [pscustomobject]$row
        continue
    }
    $row.Ping = if (Test-Connection -TargetName $item.Address -Count 1 -TimeoutSeconds $TimeoutSeconds -Quiet) { 'Answers' } else { 'NoAnswer' }
    if ($ManagementPort.ContainsKey($item.Protocol)) {
        $row.Port = [string]$ManagementPort[$item.Protocol]
        if (Test-Connection -TargetName $item.Address -TcpPort $ManagementPort[$item.Protocol] -TimeoutSeconds $TimeoutSeconds -Quiet) { $row.Management = 'Open' }
        else { $row.Management = 'Closed'; $problems.Add("$($item.Protocol) port $($row.Port) did not accept a connection") }
    }
    else { $row.Management = 'Skipped'; $row.Detail = 'snmp is UDP; a TCP check cannot test it. ' }
    if (-not $item.PasswordReference) { $row.Login = 'NotListed' }
    else {
        $check = Test-AzlSecretReference -Reference $item.PasswordReference -Infrastructure $infra -Detailed
        if ($check.Resolvable) { $row.Login = 'Readable' }
        else { $row.Login = 'NotReadable'; $problems.Add("the password reference could not be read ($($check.Category))") }
    }
    if (-not $item.User) { $row.Login = if ($row.Login -eq 'Readable') { 'NoUserName' } else { $row.Login } }
    if ($problems.Count) { $row.Action = 'Failed'; $row.Detail += ($problems -join '; ') }
    else { $row.Action = 'Verified' }
    Write-Line ("[{0}] {1} ({2}, {3}): ping {4}, {5} {6}, login {7}{8}" -f $(if ($problems.Count) { 'failed  ' } else { 'ok      ' }), $item.Name, $item.Address, $(if ($item.Role) { $item.Role } else { 'no role' }), $row.Ping, $item.Protocol, $row.Management, $row.Login, $(if ($problems.Count) { " - $($problems -join '; ')" } else { '' }))
    [pscustomobject]$row
}
$rows = @($rows)
$rows
$failed = @($rows | Where-Object Action -EQ 'Failed').Count
Write-Line "Summary: $(@($rows | Where-Object Action -EQ 'Verified').Count) verified, $(@($rows | Where-Object Action -EQ 'Skipped').Count) skipped, $failed failed."
if ($failed -gt 0) { exit 1 }
exit 0
