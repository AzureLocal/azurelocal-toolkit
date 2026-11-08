#Requires -Version 7.0
<#
.SYNOPSIS
    How the OS configuration reaches the nodes: PowerShell remoting (WinRM) by default, Azure Arc Run Command only when asked for, and the one-time
    bootstrap that opens a closed node firewall (that one lives in scripts/common/remoting: Invoke-AzlWinRmBootstrap, driven by the profile).

.DESCRIPTION
    Get-AzlRemotingSetting       transport (winrm | winrm_https | arc), UseSsl, Authentication, Port, BootstrapTransport (none | arc | smb | auto; the routes are the profile's, in scripts/common/remoting), AllowedSourceCidrs.
                                 Order of precedence: the run's -Settings (remoting = @{ ... }), the master file (os_configuration.remoting.*), the defaults.
    Get-AzlNodeRemotingAddress   The addresses to try for a node, in order: an override, nodes[].management.ip_address, maintenance_address, the addresses the Arc
                                 agent reports for the management MAC (the address the node holds now).
    Get-AzlRemotingPreCheckFinding       The pre-check, as rows: which node answers on which address, or why not (port closed, timeout, no route, no credential).
    Format-AzlRemotingPreCheckFinding    The one table.

    There is no bootstrap in this module. The earlier Arc bootstrap (a node script that opened the management subnet at any width, 5985 and 5986 in every
    class, RDP without NLA and ICMP regardless of the class) was removed: the one bootstrap is Invoke-AzlWinRmBootstrap, which takes every scope and flag
    from the remote management profile.

    There is no silent fallback to Arc: a node that can't be reached over remoting fails with what is missing and what to do.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path $PSScriptRoot 'AzlNodePayload.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzlNodeTransport.psm1')

$script:RemotingKeys = @('transport', 'bootstrapTransport', 'allowedSourceCidrs', 'useSsl', 'authentication')

function ConvertTo-AzlRemotingProfileOverride {
    <#
    .SYNOPSIS
        The run settings' remoting entry (bootstrapTransport, allowedSourceCidrs, useSsl, transport) as the override hashtable of Resolve-AzlRemotingProfile
        (bootstrap_transport, allowed_source_cidrs, use_https, transport), so one setting reaches both the transport rules and the security profile.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Setting)
    $override = @{}
    if ($Setting -and $Setting.ContainsKey('remoting') -and $Setting.remoting -is [System.Collections.IDictionary]) {
        $r = $Setting.remoting
        if ($r.Contains('bootstrapTransport')) { $override.bootstrap_transport = [string]$r.bootstrapTransport }
        if ($r.Contains('allowedSourceCidrs')) { $override.allowed_source_cidrs = @($r.allowedSourceCidrs) }
        if ($r.Contains('useSsl') -and $r.useSsl -eq $true) { $override.use_https = $true }
        if ($r.Contains('transport')) { $override.transport = [string]$r.transport }
    }
    return $override
}

function Get-AzlRemotingSetting {
    <#
    .SYNOPSIS
        The remoting settings of a run. Throws on a value that is not valid.
    .PARAMETER Setting
        The run settings (-Settings); its 'remoting' entry is a hashtable with transport, bootstrapTransport, allowedSourceCidrs, useSsl, authentication.
    .PARAMETER Transport
        The command line's -Transport (Auto, WinRM, ArcRunCommand). Auto defers to the settings and the file.
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Infrastructure, [hashtable]$Setting, [ValidateSet('Auto', 'WinRM', 'ArcRunCommand')][string]$Transport = 'Auto', [switch]$UseSsl, [string]$Authentication)
    $remote = @{}
    if ($Setting -and $Setting.ContainsKey('remoting')) {
        if ($Setting.remoting -isnot [System.Collections.IDictionary]) { throw "Setting 'remoting' must be a hashtable (transport, bootstrapTransport, allowedSourceCidrs, useSsl, authentication)." }
        foreach ($k in $Setting.remoting.Keys) {
            if ($k -notin $script:RemotingKeys) { throw "Unknown remoting setting '$k'. Known: $($script:RemotingKeys -join ', ')." }
            $remote[$k] = $Setting.remoting[$k]
        }
    }
    $file = if ($Infrastructure) { Get-AzlProp $Infrastructure 'os_configuration.remoting' } else { $null }
    $fromFile = { param($key, $default) $v = Get-AzlProp $file $key $null; if ($null -ne $v -and "$v" -ne '') { $v } else { $default } }
    $transportName = if ($Transport -eq 'WinRM') { 'winrm' } elseif ($Transport -eq 'ArcRunCommand') { 'arc' } elseif ($remote.ContainsKey('transport')) { [string]$remote.transport } else { [string](& $fromFile 'transport' 'winrm') }
    if ($transportName -notin 'winrm', 'winrm_https', 'arc') { throw "remoting.transport must be winrm, winrm_https or arc, not '$transportName'." }
    $bootstrap = if ($remote.ContainsKey('bootstrapTransport')) { [string]$remote.bootstrapTransport } else { [string](& $fromFile 'bootstrap_transport' 'none') }
    if ($bootstrap -notin 'none', 'arc', 'smb', 'auto') { throw "remoting.bootstrapTransport must be none, arc, smb or auto, not '$bootstrap'." }
    $cidrs = if ($remote.ContainsKey('allowedSourceCidrs')) { @($remote.allowedSourceCidrs) } else { @(Get-AzlProp $file 'allowed_source_cidrs' @()) }
    foreach ($c in $cidrs) { if ("$c" -notmatch '^[0-9a-fA-F:.]+/\d{1,3}$') { throw "remoting.allowedSourceCidrs must be CIDRs like 192.0.2.0/24 (the profile rules AZL-062 judge the width), not '$c'." } }
    $ssl = $UseSsl.IsPresent -or $transportName -eq 'winrm_https' -or ($remote.ContainsKey('useSsl') -and $remote.useSsl -eq $true)
    $auth = if ($Authentication) { $Authentication } elseif ($remote.ContainsKey('authentication')) { [string]$remote.authentication } else { 'Negotiate' }
    if ($auth -notin 'Default', 'Negotiate', 'Kerberos', 'Basic', 'CredSSP') { throw "remoting.authentication must be Default, Negotiate, Kerberos, Basic or CredSSP, not '$auth'." }
    [pscustomobject]@{
        Transport = $transportName; Kind = $(if ($transportName -eq 'arc') { 'ArcRunCommand' } else { 'WinRM' }); UseSsl = [bool]$ssl; Authentication = $auth; Port = $(if ($ssl) { 5986 } else { 5985 })
        BootstrapTransport = $bootstrap; AllowedSourceCidrs = @($cidrs | ForEach-Object { [string]$_ })
    }
}

function Get-AzlNodeRemotingAddress {
    <#
    .SYNOPSIS
        The addresses to try for a node: an override, the management address of the file, the maintenance address, then the addresses the Arc agent reports for the
        management MAC (what the node holds now).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Node, [string]$Override, [string]$ManagementMac, [object]$ArcMachine)
    $list = [System.Collections.Generic.List[string]]::new()
    if ($Override) { $list.Add($Override) }
    foreach ($key in 'management.ip_address', 'maintenance_address') { $v = Get-AzlProp $Node $key; if ($v) { $list.Add([string]$v) } }
    if ($ArcMachine) {
        $key = ($ManagementMac -replace '[-:\.\s]', '').ToLowerInvariant()
        foreach ($nic in @($ArcMachine.Interfaces)) {
            $mac = ([string](Get-AzlProp $nic 'macAddress' '') -replace '[-:\.\s]', '').ToLowerInvariant()
            if ($key -and $mac -and $mac -ne $key) { continue }
            foreach ($ip in @(Get-AzlProp $nic 'ipAddresses' @())) {
                $text = if ($ip -is [string]) { $ip } else { [string](Get-AzlProp $ip 'address' '') }
                if ($text -match '^\d{1,3}(\.\d{1,3}){3}$' -and $text -notlike '169.254.*') { $list.Add($text) }
            }
        }
    }
    return @($list | Select-Object -Unique)
}

function Get-AzlRemotingPreCheckFinding {
    <#
    .SYNOPSIS
        The pre-check: every node probed at the same time on its candidate addresses. One row per node with Reachable, the address that answers, the
        result and the diagnosis (what is missing and what to do next). Also checks that a credential exists.
    .PARAMETER Node
        Objects with Name and Addresses.
    .PARAMETER ArcAvailable
        Names of the nodes that have a Connected Arc machine (the bootstrap can open their firewall).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Node, [int]$Port = 5985, [bool]$HasCredential = $true, [string]$Origin = '', [string[]]$ArcAvailable = @(), [scriptblock]$Probe)
    $probeNodes = @($Node | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Addresses = @($_.Addresses); Port = $Port } })
    $arguments = @{ Node = $probeNodes }
    if ($Probe) { $arguments.Probe = $Probe }
    foreach ($r in @(Test-AzlNodeConnectivity @arguments)) {
        $diagnosis = Get-AzlRemotingDiagnosis -Reason $(if ($r.Result -eq 'NoAddress') { 'Error' } else { $r.Result }) -Address $r.BestAddress -Port $Port -HasCredential $HasCredential -Detail $r.Detail -ArcAvailable ($r.Node -in $ArcAvailable)
        if ($r.Result -eq 'NoAddress') { $diagnosis = "$($r.Detail). Put the address in the file or pass -NodeAddress." }
        [pscustomobject]@{
            Node = $r.Node; Reachable = ($r.Reachable -and $HasCredential); Address = $r.BestAddress; Port = $Port; Result = $(if ($r.Reachable -and -not $HasCredential) { 'NoCredential' } else { $r.Result })
            Credential = $(if ($HasCredential) { $Origin } else { 'none' }); Diagnosis = $diagnosis; Tried = @($r.Tried)
        }
    }
}

function Format-AzlRemotingPreCheckFinding {
    <#
    .SYNOPSIS
        The pre-check as one table, with the diagnosis of each unreachable node under it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Finding)
    $table = ($Finding | Format-Table Node, Address, Port, Result, Credential, @{ n = 'Tried'; e = { $_.Tried -join ', ' } } -AutoSize -Wrap | Out-String -Width 200).TrimEnd()
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($table)
    foreach ($f in $Finding | Where-Object { -not $_.Reachable }) { $lines.Add(''); $lines.Add("$($f.Node): $($f.Diagnosis)") }
    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function ConvertTo-AzlRemotingProfileOverride, Get-AzlRemotingSetting, Get-AzlNodeRemotingAddress, Get-AzlRemotingPreCheckFinding, Format-AzlRemotingPreCheckFinding
