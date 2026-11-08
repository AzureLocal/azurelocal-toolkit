#Requires -Version 7.0
<#
.SYNOPSIS
    The DomainJoin step of the OS configuration, host side: what a node should look like, the comparison, the join with its
    restart, the verification and the events. Pure functions, a step that talks to the node only through a transport.

.DESCRIPTION
    With scenario.identity active_directory the OS configuration joins each node to identity.active_directory.domain_fqdn, in
    identity.active_directory.ou_path, with identity.active_directory.domain_join_account, before the cluster validation and the
    deployment. The design is section 4.10 of pmo/azure-local/os-configuration-design.md; the user documentation is "Joining the
    domain" in docs/os-configuration-and-arm-deployment.md.

    Get-AzlDomainJoinSpec            The desired state from the master file (Applicable is false for a local identity design). The join credential is
                                     the LCM user, or domain_join_account when the file sets it.
    Get-AzlDomainJoinReadParameter   What the Read script needs to read the membership (never a secret).
    Get-AzlDomainJoinPlanItem        The comparison (pure): Ok, Change (join, move before the deployment, add the local administrators, or finish a pending restart), Blocked with the
                                     reason, Skipped (waits for an earlier step, or local identity), Info. Never unjoins a node.
    Test-AzlDomainJoinVerification   After the restart: member, right domain, secure channel, right OU (an unknown OU is unverified, not OK).
    Get-AzlDomainJoinLdapComputer    Host side, read only: finds the computer object over LDAP (System.DirectoryServices, no RSAT) with the join credential
                                     and returns its distinguished name, for when the node cannot read its own yet. The node's own answer wins when it has one.
    Add-AzlDomainJoinLdapCheck       Attaches that answer to the state as domainJoin.ldap, for a member whose node has no distinguished name.
    Invoke-AzlDomainJoinStep         The apply: join (or move), the guarded restart, the reconnect, the verification, the events.
    Get-AzlDomainJoinSummary         The record the run report shows: joined, domain, OU, errors.
    Send-AzlDomainJoinEvent          The one adapter to the event feed (section 6 of the design).

    The join password is read from Key Vault (the SecretResolver) at the moment of the join, held as a SecureString, and sent to the
    node as a secret of the run command or the WinRM call. It is not written to a file, a log, an event or a report; the node builds
    a PSCredential from it and keeps nothing.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
Import-Module (Join-Path (Join-Path $here '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path $here 'AzlNodePayload.psm1')
Import-Module (Join-Path $here 'AzlNodeTransport.psm1')
# The event writer of the run (AzlOsConfigurationEvents.psm1) when this checkout has it; otherwise Send-AzlDomainJoinEvent writes the same line itself.
$script:EventsModule = Join-Path $here 'AzlOsConfigurationEvents.psm1'
if (Test-Path -LiteralPath $script:EventsModule -PathType Leaf) { Import-Module $script:EventsModule }

# Kerberos allows 5 minutes of clock difference between the node and a domain controller.
$script:SkewLimitSeconds = 300
$script:PayloadVersion = '1'
$script:PendingMarkerStates = @('RebootExpected', 'Restarting')
# LastBootUpTime is computed from the clock, so stepping the clock (W32Time after the join) moves it by seconds; a real restart moves it by minutes.
$script:BootToleranceSeconds = 120

function ConvertTo-DjUtc([object]$Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $text = [string]$Value
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ($text -and [datetime]::TryParse($text, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}
function Test-DjSameBoot([object]$First, [object]$Second) {
    # The same boot: the two times agree within the tolerance (an unreadable time falls back to the exact text).
    $a = ConvertTo-DjUtc $First
    $b = ConvertTo-DjUtc $Second
    if ($null -eq $a -or $null -eq $b) { return ([string]$First -eq [string]$Second) }
    return ([math]::Abs(($a - $b).TotalSeconds) -le $script:BootToleranceSeconds)
}
function Test-DjRestartDue([object]$DomainState) {
    # The join happened but the node has not restarted since: the marker says RebootExpected or Restarting, or it was left at Joining by a process that
    # died after Add-Computer (the node is a member), and the boot is still the one the marker recorded.
    $marker = Get-AzlProp $DomainState 'marker'
    $markerState = [string](Get-AzlProp $marker 'state' '')
    $pending = ($markerState -in $script:PendingMarkerStates) -or ($markerState -eq 'Joining' -and [bool](Get-AzlProp $DomainState 'partOfDomain' $false))
    return ($pending -and (Test-DjSameBoot (Get-AzlProp $marker 'bootBefore' '') (Get-AzlProp $DomainState 'boot' '')))
}

# ---------------------------------------------------------------------------------------------------------------------
# The desired state
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlDomainJoinSpec {
    <#
    .SYNOPSIS
        What the DomainJoin step should achieve, from the master file.
    .OUTPUTS
        Applicable (scenario.identity is active_directory), Domain, Netbios, OuPath, DomainControllers, Username, PasswordRef,
        CredentialSource (lcm_user or domain_join_account), HasAccount, AllowOuMove, RenameAfterJoin (always false), LocalAdminMembers
        (NETBIOS\name), EnvironmentClass (scenario.environment_class; missing or unknown is production).
    .EXAMPLE
        Get-AzlDomainJoinSpec -Infrastructure $infra
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $ad = Get-AzlProp $Infrastructure 'identity.active_directory'
    # The join credential: the LCM user by default (Microsoft's AD preparation gives it the right to create and delete computer objects in the
    # dedicated OU and it is the account used for domain-join actions); domain_join_account overrides it.
    $override = Get-AzlProp $ad 'domain_join_account'
    $useOverride = [bool]($override -and [string](Get-AzlProp $override 'username' '') -and [string](Get-AzlProp $override 'password' ''))
    $source = if ($useOverride) { 'domain_join_account' } else { 'lcm_user' }
    $user = [string](Get-AzlProp $ad "$source.username" '')
    $ref = [string](Get-AzlProp $ad "$source.password" '')
    $dcs = @(Get-AzlProp $ad 'domain_controllers' @() | ForEach-Object { [string]$_ })
    $domain = [string](Get-AzlProp $ad 'domain_fqdn' '')
    $netbios = [string](Get-AzlProp $ad 'netbios_name' '')
    $prefix = if ($netbios) { $netbios } elseif ($domain) { $domain.Split('.')[0].ToUpperInvariant() } else { '' }
    $qualify = { param($n) $n = [string]$n; if ($n -match '[\\@]' -or -not $prefix) { $n } else { "$prefix\$n" } }
    # Local administrators after the join: the file's list, else the groups whose purpose says they administer the instance, and the LCM user.
    $members = @(Get-AzlProp $ad 'local_admin_members' @() | ForEach-Object { [string]$_ })
    if (-not $members.Count) {
        $members = @(@(Get-AzlProp $ad 'security_groups' @()) | Where-Object { [string](Get-AzlProp $_ 'purpose' '') -match '(?i)administ' } | ForEach-Object { [string]$_['name'] })
        $lcmName = [string](Get-AzlProp $ad 'lcm_user.username' '')
        if ($lcmName) { $members += $lcmName }
    }
    $class = ([string](Get-AzlProp $Infrastructure 'scenario.environment_class' '')).ToLowerInvariant()
    # Missing or unknown means production (fail closed).
    if ($class -notin 'lab', 'test', 'dev', 'production', 'dmz') { $class = 'production' }
    [pscustomobject]@{
        Applicable        = ([string](Get-AzlProp $Infrastructure 'scenario.identity' '') -eq 'active_directory')
        Domain            = $domain
        Netbios           = $netbios
        OuPath            = [string](Get-AzlProp $ad 'ou_path' '')
        DomainControllers = $dcs
        Username          = $user
        PasswordRef       = $ref
        CredentialSource  = $source
        HasAccount        = [bool]($user -and $ref)
        AllowOuMove       = ((Get-AzlProp $ad 'join_options.allow_ou_move' $false) -eq $true)
        RenameAfterJoin   = $false
        LocalAdminMembers = @($members | Where-Object { $_ } | ForEach-Object { & $qualify $_ } | Select-Object -Unique)
        EnvironmentClass  = $class
    }
}
function Get-AzlDomainJoinReadParameter {
    <#
    .SYNOPSIS
        The part of the Read script's parameters that asks for the domain membership. $null when the step does not apply.
        Never a secret.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec)
    $dj = Get-AzlProp $Spec 'DomainJoin'
    if (-not $dj -or -not $dj.Applicable) { return $null }
    return @{ domain = $dj.Domain; netbios = $dj.Netbios; ou = $dj.OuPath; dcs = @($dj.DomainControllers); expectedHost = [string]$Spec.Hostname }
}

# ---------------------------------------------------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------------------------------------------------

function New-DjPlanItem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; nothing is changed.')]
    [CmdletBinding()]
    param([string]$Node, [string]$Item, [string]$Current, [string]$Desired, [ValidateSet('Ok', 'Change', 'Blocked', 'Info', 'Skipped')][string]$Action, [string]$Note = '', [hashtable]$Apply)
    [pscustomobject]@{ Node = $Node; Step = 'DomainJoin'; Item = $Item; Current = $Current; Desired = $Desired; Action = $Action; Note = $Note; Apply = $Apply }
}

function ConvertTo-DjOuKey([string]$Dn) {
    # A distinguished name or OU path compared without case and without spaces after the commas.
    return (($Dn -split '(?<!\\),' | ForEach-Object { $_.Trim() }) -join ',').ToLowerInvariant()
}

function Get-DjOuOfDn([string]$Dn) {
    # The OU a computer object sits in: its distinguished name without the first part (CN=NODE,OU=...).
    $parts = @($Dn -split '(?<!\\),' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -lt 2) { return '' }
    return ($parts[1..($parts.Count - 1)] -join ',')
}

function Get-DjSrvText([object]$DomainState) {
    # Why the node's SRV lookup failed, as the node recorded it (the servers asked, UDP or TCP, the time, the exception text).
    $reason = [string](Get-AzlProp $DomainState 'srvReason' '')
    $servers = @(Get-AzlProp $DomainState 'srvServers' @() | ForEach-Object { [string]$_ })
    $asked = if ($servers.Count) { "DNS servers asked: $($servers -join ', ')" } else { 'the node did not report which DNS server it asked' }
    if (-not $reason) { return "$asked; no reason was reported" }
    return "$asked; $reason"
}

function Get-DjDcText([object]$DomainState) {
    # What the node found out about each domain controller address of the file.
    $parts = foreach ($c in @(Get-AzlProp $DomainState 'dcChecks' @())) {
        $tcp = if ([bool](Get-AzlProp $c 'tcp389' $false)) { 'TCP 389 open' } else { 'TCP 389 closed' }
        $name = [string](Get-AzlProp $c 'name' '')
        $err = [string](Get-AzlProp $c 'error' '')
        "$(Get-AzlProp $c 'address' ''): $tcp, $(if ($name) { "name $name" } else { 'no name' })$(if ($err) { " ($err)" })"
    }
    return (@($parts) -join '; ')
}

function Get-DjMainItem {
    # The membership itself: one item, or two (with the secure channel) when the node is a member.
    param([object]$Spec, [object]$State, [object[]]$Prior)
    $n = [string]$Spec.Name
    $dj = $Spec.DomainJoin
    $want = "$($dj.Domain), OU $($dj.OuPath)"
    $ds = Get-AzlProp $State 'domainJoin'
    $isMember = [bool](Get-AzlProp $ds 'partOfDomain' $false)
    $domainNow = [string](Get-AzlProp $ds 'domain' '')
    $dn = [string](Get-AzlProp $ds 'dn' '')
    # The node's own answer wins. When it has none (Group Policy stores the distinguished name only after a refresh), the host-side LDAP answer stands in.
    $ldap = Get-AzlProp $ds 'ldap'
    $viaLdap = $false
    if (-not $dn -and $ldap -and [bool](Get-AzlProp $ldap 'found' $false) -and [string](Get-AzlProp $ldap 'dn' '')) { $dn = [string]$ldap.dn; $viaLdap = $true }
    $ouNow = Get-DjOuOfDn $dn
    $out = [System.Collections.Generic.List[object]]::new()

    if ($isMember) {
        if ($domainNow -ine $dj.Domain) {
            return , (New-DjPlanItem $n 'domain membership' "member of $domainNow" $want Blocked "The node is joined to a different domain. It is never unjoined automatically: if $domainNow is wrong, run Remove-Computer on the node yourself (then it joins $($dj.Domain)), or correct identity.active_directory.domain_fqdn.")
        }
        $marker = Get-AzlProp $ds 'marker'
        $restartDue = Test-DjRestartDue $ds
        $inCluster = [bool](Get-AzlProp $ds 'inCluster' $false)
        $channelNow = Get-AzlProp $ds 'secureChannel'
        $markerOpen = ([string](Get-AzlProp $marker 'state' '') -in $script:PendingMarkerStates) -or ([string](Get-AzlProp $marker 'state' '') -eq 'Joining')
        $ldapNote = 'The OU was read in Active Directory over LDAP from the orchestrator, because the node could not read its distinguished name yet.'
        if ($restartDue) {
            $out.Add((New-DjPlanItem $n 'domain membership' "joined $domainNow, restart pending" "$want, restarted and verified" Change 'The join succeeded but the node has not restarted since (the durable restart marker is still set). It is restarted and verified now.' @{ id = 'DomainJoin/restart'; kind = 'domain-restart'; domain = $dj.Domain; ou = $dj.OuPath; changeId = [string](Get-AzlProp $marker 'changeId' '') }))
        }
        elseif (-not $dn) {
            $why = [string](Get-AzlProp $ldap 'error' '')
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU not read" $want Info "OU unverified: Group Policy has not stored the computer's distinguished name on the node yet, so it is not known where the computer object is (an account that already existed is reused where it is).$(if ($why) { " The check from the orchestrator over LDAP did not give an answer either: $why." }) Run gpupdate /target:computer /force on the node and run again."))
        }
        elseif ((ConvertTo-DjOuKey $ouNow) -eq (ConvertTo-DjOuKey $dj.OuPath)) {
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU $ouNow" $want Ok $(if ($viaLdap) { $ldapNote } else { '' })))
            # The join was verified in the right OU but its restart marker was never completed (the run that joined it could not verify the OU): complete it now.
            if ($markerOpen -and $channelNow -ne $false) {
                $out.Add((New-DjPlanItem $n 'domain join marker' "$([string](Get-AzlProp $marker 'state' ''))" 'Completed' Change 'The node joined, restarted and its computer object is in the right OU, but the durable marker of the join was never completed. It is completed now (nothing is joined or restarted).' @{ id = 'DomainJoin/finalize'; kind = 'domain-finalize'; domain = $dj.Domain; ou = $dj.OuPath; dn = $dn; verifiedBy = $(if ($viaLdap) { 'ldap' } else { 'node' }); changeId = [string](Get-AzlProp $marker 'changeId' '') }))
            }
        }
        elseif ($viaLdap -and -not $inCluster) {
            # The distinguished name comes from the orchestrator's LDAP read, not from the node: nothing is moved on that evidence, whatever allow_ou_move says.
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU $ouNow" $want Blocked "The computer object $dn (read in Active Directory over LDAP) is in another OU than ou_path ($($dj.OuPath)). The node could not read its own distinguished name, so nothing is moved on that evidence. Move the computer object in Active Directory yourself, or correct identity.active_directory.ou_path to where it is. After the deployment Microsoft does not support a move."))
        }
        elseif ($inCluster) {
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU $ouNow" $want Blocked "The node is in a cluster (the deployment is done) and its computer object is in another OU than ou_path. Microsoft does not support moving the computer objects to a different OU after the deployment, so the toolkit never does. Correct identity.active_directory.ou_path to where the objects are, or plan the move with Microsoft's guidance (for example remove and add the node)."))
        }
        elseif ($dj.AllowOuMove) {
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU $ouNow" $want Change 'join_options.allow_ou_move is true and the node is not part of a cluster yet (before the deployment), so the computer object is moved into the OU from the file.' @{ id = 'DomainJoin/move'; kind = 'domain-move'; domain = $dj.Domain; ou = $dj.OuPath; dn = $dn; dcs = @($dj.DomainControllers) }))
        }
        else {
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU $ouNow" $want Blocked "The node is joined to the right domain but sits in another OU. Nothing is moved by default. Before the deployment you can set identity.active_directory.join_options.allow_ou_move to true to move it into $($dj.OuPath), or move the computer object in Active Directory yourself. After the deployment Microsoft does not support a move."))
        }
        $channel = Get-AzlProp $ds 'secureChannel'
        if ($null -ne $channel -and -not $restartDue) {
            $out.Add((New-DjPlanItem $n 'secure channel' $(if ($channel) { 'ok' } else { 'broken' }) 'ok' $(if ($channel) { 'Ok' } else { 'Blocked' }) $(if ($channel) { '' } else { 'Test-ComputerSecureChannel failed: the computer account password and the domain disagree. Run Test-ComputerSecureChannel -Repair -Credential <domain account> on the node, or unjoin and join again.' })))
        }
        return $out.ToArray()
    }

    # Not a member.
    $current = "workgroup $domainNow"
    $hostNow = [string](Get-AzlProp $ds 'host' ([string](Get-AzlProp $State 'host' '')))
    $hostnameChange = @($Prior | Where-Object { $_.Step -eq 'Hostname' -and $_.Action -eq 'Change' }).Count -gt 0
    if ($hostNow -and $hostNow -ine [string]$Spec.Hostname) {
        if ($hostnameChange) { return , (New-DjPlanItem $n 'domain membership' "$current, name $hostNow" $want Skipped "Waits for the Hostname step: the node is called $hostNow, the file says $($Spec.Hostname). It is renamed and restarted first, then joined, so the computer object has its final name.") }
        return , (New-DjPlanItem $n 'domain membership' "$current, name $hostNow" $want Blocked "The computer name is $hostNow but the file says $($Spec.Hostname). The Hostname step must run first (it is not part of this run, or ZTP named the machine differently): the node is joined only under its final name, and is never renamed after the join.")
    }
    $waitFor = @($Prior | Where-Object { $_.Step -in 'Network', 'Dns', 'Time', 'UnusedAdapters', 'Hostname' -and $_.Action -eq 'Change' } | ForEach-Object { $_.Step } | Select-Object -Unique)
    if ($waitFor.Count) {
        return , (New-DjPlanItem $n 'domain membership' $current $want Skipped "Waits for $($waitFor -join ', '): the join needs the domain controllers reachable by name and the clocks in agreement, so it runs after them (a later pass of this run).")
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    $joinServer = ''
    $srvWarning = ''
    if (-not [bool](Get-AzlProp $ds 'dnsOk' $false)) {
        $why = [string](Get-AzlProp $ds 'dnsError' '')
        $reasons.Add("DNS cannot resolve $($dj.Domain) from the node$(if ($why) { " ($why)" }). The management port's DNS servers must be the domain controllers (identity.active_directory.domain_controllers, rule AZL-052); the Dns step sets them.")
    }
    elseif (-not [bool](Get-AzlProp $ds 'srvOk' $false)) {
        $srvName = "_ldap._tcp.dc._msdcs.$($dj.Domain)"
        $dcServer = [string](Get-AzlProp $ds 'dcServer' '')
        if ([bool](Get-AzlProp $ds 'dcAllOk' $false) -and $dcServer) {
            # SRV discovery failed, but every domain controller of the file answers on TCP 389 and has a name in the node's DNS: the join names one, so it does not depend on SRV.
            $joinServer = $dcServer
            $srvWarning = "WARNING: domain controller discovery by SRV ($srvName) failed ($(Get-DjSrvText $ds)). Every domain controller of the file answers on TCP 389 and resolves by name from the node ($(Get-DjDcText $ds)), so the join names $dcServer (Add-Computer -Server) and does not depend on SRV discovery."
        }
        else {
            $dcText = Get-DjDcText $ds
            $reasons.Add("The domain controller SRV lookup ($srvName) failed: $(Get-DjSrvText $ds). The explicit domain controllers of the file do not work either: $(if ($dcText) { $dcText } else { 'none was checked (identity.active_directory.domain_controllers is empty or the node did not report them)' }). The DNS servers are not the domain's, or something between the node and them drops the answer or TCP 389.")
        }
    }
    if (-not [bool](Get-AzlProp $ds 'dcReachable' $false)) {
        $reasons.Add('No domain controller answers on TCP 389 from the node. Check the route and the firewall between the management network and the domain controllers.')
    }
    $skew = Get-AzlProp $ds 'skewSeconds'
    if ($null -ne $skew -and [double]$skew -gt $script:SkewLimitSeconds) {
        $reasons.Add("The node's clock differs from domain controller $(Get-AzlProp $ds 'dcUsed' '') by $([math]::Round([double]$skew)) seconds; Kerberos allows $script:SkewLimitSeconds (5 minutes). Fix the time first (networking.ntp_servers, the Time step).")
    }
    if (-not $dj.HasAccount) {
        $reasons.Add('There is no join credential: identity.active_directory.lcm_user (username and keyvault:// password) is missing, and no domain_join_account is set (rule AZL-050).')
    }
    if ($reasons.Count) {
        return , (New-DjPlanItem $n 'domain membership' $current $want Blocked ($reasons -join ' '))
    }
    $note = if ($null -eq $skew) { 'The time difference to the domain controller was not measured.' } else { '' }
    $apply = @{ id = 'DomainJoin/join'; kind = 'domain-join'; domain = $dj.Domain; netbios = $dj.Netbios; ou = $dj.OuPath; expectedHost = [string]$Spec.Hostname; dcs = @($dj.DomainControllers); server = $joinServer }
    $join = New-DjPlanItem $n 'domain membership' $current $want Change "Add-Computer into the OU with $($dj.CredentialSource)$(if ($joinServer) { ", against $joinServer (-Server)" }), then a guarded restart and a check. $note".Trim() $apply
    if ($srvWarning) { return @((New-DjPlanItem $n 'domain controller discovery' 'SRV lookup failed' 'SRV lookup answers, or explicit domain controllers' Info $srvWarning), $join) }
    return , $join
}

function Get-DjOuItem {
    # The dedicated OU Microsoft requires: it exists, Group Policy inheritance is blocked on it, and the enforced links above it.
    param([object]$Spec, [object]$State)
    $n = [string]$Spec.Name
    $dj = $Spec.DomainJoin
    $ou = Get-AzlProp (Get-AzlProp $State 'domainJoin') 'ou'
    if (-not $ou) { return @() }
    $items = [System.Collections.Generic.List[object]]::new()
    if ([bool](Get-AzlProp $ou 'authFailed' $false)) {
        # The domain controller rejected the join credential (wrong password, locked, disabled, expired). Never "the OU is missing", and never tried again.
        $why = [string](Get-AzlProp $ou 'error' '')
        $items.Add((New-DjPlanItem $n 'organizational unit' 'join credential rejected' "$($dj.OuPath), inheritance blocked" Blocked "The domain controller rejected the join credential ($($dj.CredentialSource) $($dj.Username)): $why The credential is not sent again in this run, to any node (repeated bad passwords lock the account). Check the Key Vault secret and the account (locked, disabled, expired) in Active Directory, then run again."))
        return $items.ToArray()
    }
    if (-not [bool](Get-AzlProp $ou 'checked' $false)) {
        $reason = [string](Get-AzlProp $ou 'error' '')
        if ([bool](Get-AzlProp $ou 'exists' $true) -eq $false -and $reason -match 'no such object|0x80072030|does not exist') {
            $items.Add((New-DjPlanItem $n 'organizational unit' 'not found' $dj.OuPath Blocked "The OU $($dj.OuPath) does not exist in the domain. Create it with New-HciAdObjectsPreCreation (it also blocks Group Policy inheritance and gives the LCM user its rights), or correct identity.active_directory.ou_path."))
        }
        else {
            $items.Add((New-DjPlanItem $n 'organizational unit' 'not verified' "$($dj.OuPath), inheritance blocked" Info "OU not verified: the OU and its Group Policy inheritance were not checked ($(if ($reason) { $reason } else { 'the join credential could not be used yet' }))."))
        }
        return $items.ToArray()
    }
    $class = [string]$dj.EnvironmentClass
    if ([bool](Get-AzlProp $ou 'blockInheritance' $false)) {
        $items.Add((New-DjPlanItem $n 'OU Group Policy inheritance' 'blocked' 'blocked' Ok))
    }
    elseif ($class -in 'lab', 'test') {
        $items.Add((New-DjPlanItem $n 'OU Group Policy inheritance' "not blocked (gPOptions $(Get-AzlProp $ou 'gpOptions' 0))" 'blocked' Info "WARNING ($class): Group Policy inheritance is not blocked on $($dj.OuPath). Azure Local requires it blocked so that GPOs do not conflict with its security settings; New-HciAdObjectsPreCreation does this. Allowed here only because the environment class is $class."))
    }
    else {
        $items.Add((New-DjPlanItem $n 'OU Group Policy inheritance' "not blocked (gPOptions $(Get-AzlProp $ou 'gpOptions' 0))" 'blocked' Blocked "Group Policy inheritance is not blocked on $($dj.OuPath), which Azure Local requires (environment class $class). Block it (Set-GPInheritance -Target '$($dj.OuPath)' -IsBlocked Yes, or New-HciAdObjectsPreCreation), then run again."))
    }
    $enforced = @(Get-AzlProp $ou 'enforcedLinks' @() | Where-Object { $_ })
    if ($enforced.Count) {
        $items.Add((New-DjPlanItem $n 'enforced GPO links above the OU' "$($enforced.Count) enforced link(s)" 'none, or filtered' Info "WARNING: Block Inheritance does not stop GPO links marked Enforced: $($enforced -join '; '). Microsoft suggests a WMI filter on those GPOs that excludes the Azure Local machine accounts."))
    }
    return $items.ToArray()
}

function Get-DjAdminItem {
    # The local Administrators group: the domain principals of local_admin_members, once the node is in the domain.
    param([object]$Spec, [object]$State)
    $n = [string]$Spec.Name
    $dj = $Spec.DomainJoin
    $ds = Get-AzlProp $State 'domainJoin'
    $wanted = @($dj.LocalAdminMembers)
    if (-not $wanted.Count -or -not [bool](Get-AzlProp $ds 'partOfDomain' $false) -or [string](Get-AzlProp $ds 'domain' '') -ine $dj.Domain) { return @() }
    if (Test-DjRestartDue $ds) { return @() }
    $have = Get-AzlProp $ds 'localAdmins'
    if ($null -eq $have) { return , (New-DjPlanItem $n 'local administrators' 'unreadable' ($wanted -join ', ') Info 'The node did not report its local Administrators group.') }
    $have = @($have | ForEach-Object { [string]$_ })
    # The exact name: net localgroup shows a domain principal qualified with the domain and a bare name is a local account, which is not the domain principal.
    $missing = @($wanted | Where-Object { $w = $_; -not (@($have | Where-Object { $_ -ieq $w }).Count) })
    if (-not $missing.Count) { return , (New-DjPlanItem $n 'local administrators' 'all present' ($wanted -join ', ') Ok) }
    return , (New-DjPlanItem $n 'local administrators' "missing: $($missing -join ', ')" ($wanted -join ', ') Change 'A domain account is not a local administrator by default. The accounts of local_admin_members are added to the local Administrators group (the deployment adds the LCM user itself later), so Kerberos remoting and log access can use a domain account.' @{ id = 'DomainJoin/admins'; kind = 'domain-admins'; members = @($missing) })
}

function Get-AzlDomainJoinPlanItem {
    <#
    .SYNOPSIS
        Compares a node's domain membership with the spec. Pure; nothing is touched.
    .DESCRIPTION
        Not joined and nothing in the way          Change (kind domain-join)
        Joined to the right domain and OU          Ok
        Joined, another OU                         Blocked. Microsoft does not support moving the computer objects to another OU after the
                                                   deployment: with the node in a cluster it is always Blocked; before the deployment it is
                                                   a Change (kind domain-move) only with join_options.allow_ou_move true.
        Joined, restart after the join still due   Change (kind domain-restart)
        Joined to a different domain               Blocked. It is never unjoined, whatever the file says.
        SRV lookup failed, but every domain_controllers address of the file answers on TCP 389 and resolves by name from the node
                                                   Change with a warning item (Info): the join passes -Server <dc fqdn> to Add-Computer
                                                   and does not depend on SRV discovery. The warning carries the reason the node recorded.
        Computer name differs from the file        Blocked, or Skipped when the Hostname step runs in this pass (it goes first)
        DNS cannot resolve the domain, no domain controller SRV record and the controllers of the file do not work either, none reachable,
        clock over 5 minutes apart,
        no join credential                         Blocked, with every reason
        An earlier step (Network, Dns, Time, UnusedAdapters, Hostname) has a Change   Skipped: it waits for it
        The OU (read with the join credential)     does not exist: Blocked. Inheritance not blocked: Blocked in dev, production and dmz, a
                                                   warning (Info) in lab and test. Enforced GPO links above it: a warning (Info).
                                                   A Blocked OU also blocks the join and the move.
        Joined, local_admin_members missing        Change (kind domain-admins), idempotent
        Local identity                             Skipped: "not applicable: local identity"
    .PARAMETER Prior
        The plan items of the earlier steps in the same comparison.
    .PARAMETER Step
        The steps being compared; Hostname in it means the name will be set first.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Step', Justification = 'Kept for the signature of the callers; the order of the steps is carried by -Prior.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][AllowNull()][object]$State,
        [string[]]$Step = @(),
        [object[]]$Prior = @()
    )
    $n = [string]$Spec.Name
    $dj = Get-AzlProp $Spec 'DomainJoin'
    if (-not $dj -or -not $dj.Applicable) {
        return , (New-DjPlanItem $n 'domain membership' 'local identity' 'no domain' Skipped 'not applicable: local identity (scenario.identity is not active_directory), so the node is not joined to a domain.')
    }
    $want = "$($dj.Domain), OU $($dj.OuPath)"
    $ds = Get-AzlProp $State 'domainJoin'
    if (-not $ds) {
        return , (New-DjPlanItem $n 'domain membership' 'unreadable' $want Info ([string](Get-AzlProp $State 'err.domainJoin' 'The node did not report its domain membership.')))
    }
    $main = @(Get-DjMainItem -Spec $Spec -State $State -Prior $Prior)
    $ouItems = @(Get-DjOuItem -Spec $Spec -State $State)
    $blockingOu = @($ouItems | Where-Object Action -eq 'Blocked')
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $main) {
        if ($i.Action -eq 'Change' -and $i.Apply -and $i.Apply.kind -in 'domain-join', 'domain-move' -and $blockingOu.Count) {
            $result.Add((New-DjPlanItem $i.Node $i.Item $i.Current $i.Desired Blocked "Not done: $($blockingOu[0].Note)"))
        }
        else { $result.Add($i) }
    }
    foreach ($i in $ouItems) { $result.Add($i) }
    foreach ($i in @(Get-DjAdminItem -Spec $Spec -State $State)) { $result.Add($i) }
    return $result.ToArray()
}

function Test-AzlDomainJoinVerification {
    <#
    .SYNOPSIS
        The checks after the join and the restart: member of a domain, the right domain, the secure channel, the right OU.
    .OUTPUTS
        Check, Ok, Detail. The OU check is not OK (unverified) when the node has no distinguished name to read.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [AllowNull()][object]$State)
    $dj = $Spec.DomainJoin
    $ds = Get-AzlProp $State 'domainJoin'
    $domainNow = [string](Get-AzlProp $ds 'domain' '')
    $member = [bool](Get-AzlProp $ds 'partOfDomain' $false)
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([pscustomobject]@{ Check = 'PartOfDomain'; Ok = $member; Unverified = $false; Detail = "PartOfDomain is $member" })
    $checks.Add([pscustomobject]@{ Check = 'Domain'; Ok = ($member -and $domainNow -ieq $dj.Domain); Unverified = $false; Detail = "domain is '$domainNow', the file says '$($dj.Domain)'" })
    $channel = Get-AzlProp $ds 'secureChannel'
    $checks.Add([pscustomobject]@{ Check = 'SecureChannel'; Ok = ($channel -eq $true); Unverified = $false; Detail = "Test-ComputerSecureChannel returned $channel" })
    $dn = [string](Get-AzlProp $ds 'dn' '')
    # The host-side answer (Get-AzlDomainJoinLdapComputer) stands in only when the node has no distinguished name.
    $ldap = Get-AzlProp $ds 'ldap'
    $ldapDn = if ($ldap -and [bool](Get-AzlProp $ldap 'found' $false)) { [string](Get-AzlProp $ldap 'dn' '') } else { '' }
    if ($dn) {
        $ouNow = Get-DjOuOfDn $dn
        $checks.Add([pscustomobject]@{ Check = 'OU'; Ok = ((ConvertTo-DjOuKey $ouNow) -eq (ConvertTo-DjOuKey $dj.OuPath)); Unverified = $false; Detail = "the computer object is in '$ouNow', the file says '$($dj.OuPath)'" })
    }
    elseif ($ldapDn) {
        $ouNow = Get-DjOuOfDn $ldapDn
        $checks.Add([pscustomobject]@{ Check = 'OU'; Ok = ((ConvertTo-DjOuKey $ouNow) -eq (ConvertTo-DjOuKey $dj.OuPath)); Unverified = $false; Detail = "the computer object $ldapDn (read in Active Directory over LDAP from the orchestrator) is in '$ouNow', the file says '$($dj.OuPath)'" })
    }
    else {
        # No distinguished name: unverified, never OK. Add-Computer reuses a computer account that already exists, possibly in another OU, and nothing
        # moves it after the deployment.
        $why = [string](Get-AzlProp $ldap 'error' '')
        $checks.Add([pscustomobject]@{ Check = 'OU'; Ok = $false; Unverified = $true; Detail = "unverified: the node has no distinguished name to read, so it is not known that the computer object is in '$($dj.OuPath)'$(if ($ldap) { "; the check from the orchestrator over LDAP gave no answer either ($(if ($why) { $why } else { 'no reason was reported' }))" })" })
    }
    return $checks.ToArray()
}

function Get-AzlDomainJoinSummary {
    <#
    .SYNOPSIS
        What the run report shows for the step: applicable, joined (member of the right domain), domain, OU, the failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [AllowNull()][object]$State, [object[]]$Change = @())
    $dj = Get-AzlProp $Spec 'DomainJoin'
    $ds = Get-AzlProp $State 'domainJoin'
    $applicable = [bool]($dj -and $dj.Applicable)
    $joined = $applicable -and $ds -and [bool](Get-AzlProp $ds 'partOfDomain' $false) -and [string](Get-AzlProp $ds 'domain' '') -ieq $dj.Domain
    $failure = @($Change | Where-Object { $_.Status -eq 'failed' -and [string]$_.Id -like 'DomainJoin/*' } | Select-Object -First 1)
    $dn = [string](Get-AzlProp $ds 'dn' '')
    [ordered]@{
        applicable   = $applicable
        domainJoined = [bool]$joined
        domain       = $(if ($joined) { [string]$ds.domain } elseif ($applicable) { $dj.Domain } else { '' })
        ou           = $(if ($joined -and $dn) { Get-DjOuOfDn $dn } elseif ($applicable) { $dj.OuPath } else { '' })
        secureChannel = $(if ($joined) { Get-AzlProp $ds 'secureChannel' } else { $null })
        credential   = $(if ($applicable) { $dj.CredentialSource } else { '' })
        localAdminMembers = $(if ($applicable) { @($dj.LocalAdminMembers) } else { @() })
        localAdminsPresent = $(if ($joined -and $null -ne (Get-AzlProp $ds 'localAdmins')) { @($dj.LocalAdminMembers | Where-Object { $w = $_; -not @(@($ds.localAdmins) | Where-Object { $_ -ieq $w }).Count }).Count -eq 0 } else { $null })
        srvDiscovery = $(if ($applicable -and $ds) { [ordered]@{ ok = [bool](Get-AzlProp $ds 'srvOk' $false); server = [string](Get-AzlProp $ds 'srvServer' ''); transport = [string](Get-AzlProp $ds 'srvTransport' ''); elapsedMs = [int](Get-AzlProp $ds 'srvElapsedMs' 0); reason = [string](Get-AzlProp $ds 'srvReason' ''); joinServer = [string](Get-AzlProp $ds 'dcServer' '') } } else { $null })
        error        = $(if ($failure.Count) { [string]$failure[0].Detail } else { '' })
    }
}

function Merge-AzlDomainJoinOutcome {
    <#
    .SYNOPSIS
        Corrects a comparison for what the run already did to the DomainJoin step: after a failed join the pending Change becomes
        Blocked with the exact error (so the plan, the exit code and the report say it), after a successful move it becomes Ok
        (the node's own view of its OU follows with Group Policy).
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Plan = @(), [object]$Failure, [switch]$Moved)
    foreach ($i in $Plan) {
        # A join that worked but whose OU could not be verified: the later passes read the node as a member without a distinguished name (Info). That must not
        # read as converged, so the item is Blocked with the failure while the independent steps carry on.
        if ($Failure -and [bool](Get-AzlProp $Failure 'Unverified' $false) -and $i.Step -eq 'DomainJoin' -and $i.Action -eq 'Info' -and $i.Item -eq 'domain membership') {
            New-DjPlanItem $i.Node $i.Item $i.Current $i.Desired Blocked "The node joined, but the check after the restart could not verify the OU: $($Failure.Error) Next: $($Failure.NextAction)".Trim(); continue
        }
        if ($i.Step -ne 'DomainJoin' -or $i.Action -ne 'Change') { $i; continue }
        if ($Failure -and (-not (Get-AzlProp $Failure 'Kind') -or $i.Apply.kind -eq $Failure.Kind)) { New-DjPlanItem $i.Node $i.Item $i.Current $i.Desired Blocked "The join failed and is not tried again in this run: $($Failure.Error) Next: $($Failure.NextAction)".Trim(); continue }
        if ($Moved -and $i.Apply -and $i.Apply.kind -eq 'domain-move') { New-DjPlanItem $i.Node $i.Item "moved to $($i.Apply.ou)" $i.Desired Ok 'The computer object was moved; the node reads its OU again when Group Policy refreshes.'; continue }
        $i
    }
}
# ---------------------------------------------------------------------------------------------------------------------
# The events (one adapter to the feed, section 6 of the design)
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlDomainJoinEventWriter {
    # The one place the feed is written. The run's own writer when the checkout has it (Write-AzlOsConfigurationEvent), else the
    # same line is written here: JSON Lines, UTC round-trip timestamp, the fields of section 6.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Record)
    $writer = Get-Command -Name Write-AzlOsConfigurationEvent -ErrorAction SilentlyContinue
    if ($writer) { $null = & $writer @Record; return }
    if (-not $Record.Path) { return }
    try {
        $entry = [ordered]@{
            timestamp = [datetime]::UtcNow.ToString('o', [cultureinfo]::InvariantCulture); node = $Record.Node; stage = 'OsConfiguration'; step = $Record.Step; state = $Record.State
            evidence = $Record.Evidence; level = $Record.Level; nextAction = $Record.NextAction; method = $Record.Method; transport = $Record.Transport
            payloadVersion = $Record.PayloadVersion; schemaVersion = $Record.SchemaVersion
        }
        if ($Record.Data) { foreach ($k in $Record.Data.Keys) { if (-not $entry.Contains([string]$k)) { $entry[[string]$k] = $Record.Data[$k] } } }
        $line = (ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n"
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line)
        $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Record.Path))
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
        $stream = [System.IO.File]::Open($Record.Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    }
    catch { Write-Verbose "DomainJoin event not written to $($Record.Path): $($_.Exception.Message)" }
}

function Send-AzlDomainJoinEvent {
    <#
    .SYNOPSIS
        Appends one DomainJoin event to the run's feed: DomainJoinPlanned, DomainJoinApplying, DomainJoined, DomainJoinFailed,
        DomainAdminsConfigured, NodeRestarting, NodeReconnected. Does nothing without a feed path in -EventContext. Never throws.
    .PARAMETER EventContext
        Path (the feed file), Method (Ztp or Iso), SchemaVersion, PayloadVersion.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$EventContext,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][ValidateSet('DomainJoinPlanned', 'DomainJoinApplying', 'DomainJoined', 'DomainJoinFailed', 'DomainAdminsConfigured', 'NodeRestarting', 'NodeReconnected')][string]$State,
        [string]$Evidence = '',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$NextAction = '',
        [string]$Transport = '',
        [hashtable]$Data
    )
    if (-not $EventContext -or -not $EventContext.ContainsKey('Path') -or -not $EventContext.Path) { return }
    try {
        $method = if ($EventContext.ContainsKey('Method') -and [string]$EventContext.Method -in 'Ztp', 'Iso') { [string]$EventContext.Method } else { '' }
        $kind = if ($Transport -in 'WinRM', 'ArcRunCommand') { $Transport } else { '' }
        Invoke-AzlDomainJoinEventWriter -Record @{
            Path = [string]$EventContext.Path; Node = $Node; State = $State; Step = 'DomainJoin'; Evidence = $Evidence; Level = $Level; NextAction = $NextAction
            Method = $method; Transport = $kind
            PayloadVersion = $(if ($EventContext.ContainsKey('PayloadVersion')) { [string]$EventContext.PayloadVersion } else { $script:PayloadVersion })
            SchemaVersion = $(if ($EventContext.ContainsKey('SchemaVersion')) { [string]$EventContext.SchemaVersion } else { '' })
            Data = $Data
        }
    }
    catch { Write-Verbose "DomainJoin event skipped: $($_.Exception.Message)" }
}

function Send-AzlDomainJoinPlanEvent {
    <#
    .SYNOPSIS
        DomainJoinPlanned for a plan: what the comparison decided for the step (Warning when it is blocked).
    #>
    [CmdletBinding()]
    param([AllowNull()][hashtable]$EventContext, [Parameter(Mandatory)][string]$Node, [object[]]$Plan = @(), [string]$Transport = '')
    if ($EventContext -and $EventContext.ContainsKey('Phase') -and $EventContext.Phase -ne 'Plan') { return }
    $items = @($Plan | Where-Object { $_.Step -eq 'DomainJoin' -and $_.Action -ne 'Skipped' })
    if (-not $items.Count) { return }
    $worst = if (@($items | Where-Object Action -eq 'Blocked').Count) { 'Blocked' } elseif (@($items | Where-Object Action -eq 'Change').Count) { 'Change' } elseif (@($items | Where-Object Action -eq 'Info').Count) { 'Info' } else { 'Ok' }
    $first = @($items | Where-Object Action -eq $worst | Select-Object -First 1)[0]
    $text = "$($first.Item): $($first.Current)$(if ($worst -in 'Change', 'Blocked') { " -> $($first.Desired)" })"
    Send-AzlDomainJoinEvent -EventContext $EventContext -Node $Node -State DomainJoinPlanned -Evidence $text -Level $(if ($worst -eq 'Blocked') { 'Warning' } else { 'Info' }) -NextAction $(if ($worst -eq 'Blocked') { [string]$first.Note } else { '' }) -Transport $Transport -Data @{ action = $worst }
}

# ---------------------------------------------------------------------------------------------------------------------
# The apply
# ---------------------------------------------------------------------------------------------------------------------

function Lock-DjCredential {
    # The run-wide latch: after the domain controller rejected the join credential once, nothing in the run sends it again (to any node).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets a flag in the hashtable of the run.')]
    param([hashtable]$Latch, [string]$Node, [string]$Reason)
    if ($Latch -and -not [bool]$Latch['Tripped']) { $Latch['Tripped'] = $true; $Latch['Reason'] = "${Node}: $Reason".Trim() }
}
function Test-DjCredentialLocked([hashtable]$Latch) { return [bool]($Latch -and $Latch.ContainsKey('Tripped') -and $Latch['Tripped']) }
function Get-DjLatchText([hashtable]$Latch) { return "The join credential was rejected earlier in this run ($([string]$Latch['Reason'])), so it is not sent again." }

function Add-AzlDomainJoinOuCheck {
    <#
    .SYNOPSIS
        Reads the dedicated OU over LDAP from the node with the join credential (it exists, gPOptions says inheritance is blocked, the
        enforced GPO links above it) and attaches the answer to the state as domainJoin.ou. Returns the state. Never throws: when the
        credential or the domain controller is not usable yet, the answer says why and the plan shows Info.
    .DESCRIPTION
        The credential is sent only with -Execute: a plan never sends it ("OU not verified"). A credential the domain controller rejects is
        reported as authFailed (the plan shows Blocked) and trips -Latch, the run-wide latch: while it is tripped no node gets an OU check or a join.
    .PARAMETER Execute
        Without it nothing is sent to the node and the OU is reported as not verified.
    .PARAMETER Latch
        A hashtable (Tripped, Reason) shared by the nodes of one run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it is made a SecureString at once and only ever lives in memory.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][object]$State, [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecret -Reference $Ref }, [switch]$Execute, [hashtable]$Latch)
    $dj = $Spec.DomainJoin
    $ds = Get-AzlProp $State 'domainJoin'
    if (-not $dj -or -not $dj.Applicable -or -not $ds) { return $State }
    $ou = [pscustomobject]@{ checked = $false; exists = $true; authFailed = $false; gpOptions = $null; blockInheritance = $false; enforcedLinks = @(); error = '' }
    if (-not $Execute) { $ou.error = 'a plan never sends the join credential to a node; the OU is read with -Execute' }
    elseif (Test-DjCredentialLocked $Latch) { $ou.authFailed = $true; $ou.error = Get-DjLatchText $Latch }
    elseif (-not [bool](Get-AzlProp $ds 'dcReachable' $false)) { $ou.error = 'no domain controller is reachable from the node yet' }
    elseif (-not $dj.HasAccount) { $ou.error = 'there is no join credential' }
    else {
        $secrets = $null
        try {
            $plain = [string](& $SecretResolver $dj.PasswordRef)
            $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $plain = $null
            $secrets = @{ joinUser = [string]$dj.Username; joinPassword = [System.Net.NetworkCredential]::new('', $secure).Password }
            $r = Invoke-AzlNodeScript -Transport $Transport -Node ([string]$Spec.Name) -Script (Get-AzlNodePayload -Name DomainJoinOuCheck) -Parameters @{ domain = $dj.Domain; netbios = $dj.Netbios; ou = $dj.OuPath; dcs = @($dj.DomainControllers) } -Secrets $secrets -TimeoutSeconds 300 -Tries 1
            $ou = $r.ou
            if (-not (Get-AzlProp $ou 'authFailed')) { Add-Member -InputObject $ou -NotePropertyName authFailed -NotePropertyValue $false -Force }
            if ([bool](Get-AzlProp $ou 'authFailed' $false)) { Lock-DjCredential -Latch $Latch -Node ([string]$Spec.Name) -Reason ([string](Get-AzlProp $ou 'error' 'the domain controller rejected the credential')) }
        }
        catch { $ou.error = "can't read the OU: $($_.Exception.Message)" }
        finally { if ($secrets) { $secrets.Clear() } }
    }
    Add-Member -InputObject $ds -NotePropertyName ou -NotePropertyValue $ou -Force
    return $State
}

# ---------------------------------------------------------------------------------------------------------------------
# The computer object over LDAP, from this host (read only)
# ---------------------------------------------------------------------------------------------------------------------

function Get-DjLdapFilterValue([string]$Value) {
    # RFC 4515 escaping, so a name can never change the filter.
    $escaped = $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
    return $escaped
}

function Get-DjDomainDn([string]$Domain, [string]$OuPath) {
    # The search root: the DC= parts of ou_path when it has them, else the domain name (improbability.cloud -> DC=improbability,DC=cloud).
    $dc = @($OuPath -split '(?<!\\),' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(?i)DC=' })
    if ($dc.Count) { return ($dc -join ',') }
    return ((@($Domain.Split('.') | Where-Object { $_ }) | ForEach-Object { "DC=$_" }) -join ',')
}

function Test-DjLdapPort {
    # TCP connect with a timeout. Nothing is sent.
    param([string]$Address, [int]$Port, [int]$Milliseconds)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Address, $Port)
        return ($task.Wait($Milliseconds) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Find-DjReachableServer {
    # The first address of the list, in the order of the file, that answers on the port. '' when none does.
    param([string[]]$Server = @(), [int]$Port = 389, [int]$Milliseconds = 3000, [scriptblock]$Probe = { param($Address, $PortNumber, $Ms) Test-DjLdapPort -Address $Address -Port $PortNumber -Milliseconds $Ms })
    foreach ($s in @($Server | Where-Object { $_ })) {
        if (& $Probe $s $Port $Milliseconds) { return [string]$s }
    }
    return ''
}

function Test-DjLdapAuthFailure($Exception) {
    # A rejected credential (wrong password, locked, disabled, expired) is not "the computer object is missing": the run stops using the credential.
    $e = $Exception
    while ($e) {
        $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$e.HResult), 0)
        if (($u -shr 16) -eq 0x8007 -and (($u -band 0xFFFF) -in 1326, 1327, 1328, 1329, 1330, 1331, 1793, 1909)) { return $true }
        $ext = $e.PSObject.Properties['ExtendedError']
        if ($ext -and ([int]$ext.Value -in 1326, 1327, 1328, 1329, 1330, 1331, 1793, 1909)) { return $true }
        $e = $e.InnerException
    }
    return ([string]$Exception.Message -match '(?i)logon failure|user name or password is incorrect|account currently disabled|account has been disabled|locked out|invalid credentials|password has expired|account has expired')
}

function Invoke-DjLdapSearch {
    <#
    .SYNOPSIS
        The default LDAP query of Get-AzlDomainJoinLdapComputer: binds to the first domain controller that answers on the port and searches the
        domain for the filter, read only. System.DirectoryServices only (no RSAT, no module), so it runs where Windows does.
    .OUTPUTS
        Reachable, Server, Entries (distinguishedName, dnsHostName), AuthFailed, Error. Never throws; the password is not in the error.
    #>
    param([Parameter(Mandatory)][object]$Request)
    $result = [pscustomobject]@{ Reachable = $false; Server = ''; Entries = @(); AuthFailed = $false; Error = '' }
    if (-not $IsWindows) { $result.Error = 'the host-side LDAP lookup needs System.DirectoryServices, which is only on Windows'; return $result }
    $port = [int]$Request.Port
    $seconds = [int]$Request.TimeoutSeconds
    $server = Find-DjReachableServer -Server @($Request.Servers) -Port $port
    if (-not $server) { $result.Error = "no domain controller of the file answered on TCP $port from this host (tried $(@($Request.Servers) -join ', '))"; return $result }
    $result.Reachable = $true
    $result.Server = $server
    $entry = $null; $searcher = $null; $found = $null
    try {
        Add-Type -AssemblyName System.DirectoryServices
        $plain = $Request.Credential.GetNetworkCredential().Password
        # Secure (Kerberos or NTLM) with signing and sealing: a domain controller that requires LDAP signing refuses a plain simple bind.
        $auth = [System.DirectoryServices.AuthenticationTypes]::Secure -bor [System.DirectoryServices.AuthenticationTypes]::Signing -bor [System.DirectoryServices.AuthenticationTypes]::Sealing
        $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://${server}:$port/$($Request.SearchRoot)", $Request.Credential.UserName, $plain, $auth)
        $plain = $null
        $searcher = [System.DirectoryServices.DirectorySearcher]::new($entry, [string]$Request.Filter, [string[]]@($Request.Properties), [System.DirectoryServices.SearchScope]::Subtree)
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds($seconds)
        $searcher.ServerTimeLimit = [TimeSpan]::FromSeconds($seconds)
        $searcher.SizeLimit = 10
        $found = $searcher.FindAll()
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $found) {
            $dnValues = $r.Properties['distinguishedname']
            $hostValues = $r.Properties['dnshostname']
            $list.Add([pscustomobject]@{ distinguishedName = $(if ($dnValues.Count) { [string]$dnValues[0] } else { '' }); dnsHostName = $(if ($hostValues.Count) { [string]$hostValues[0] } else { '' }) })
        }
        $result.Entries = $list.ToArray()
    }
    catch {
        $result.Error = "LDAP search on ${server}:$port failed: $($_.Exception.Message)"
        if (Test-DjLdapAuthFailure $_.Exception) { $result.AuthFailed = $true }
    }
    finally {
        if ($found) { $found.Dispose() }
        if ($searcher) { $searcher.Dispose() }
        if ($entry) { $entry.Dispose() }
    }
    return $result
}

function Get-AzlDomainJoinLdapComputer {
    <#
    .SYNOPSIS
        Finds the node's computer object in Active Directory over LDAP, from this host, read only, and returns where it is.
    .DESCRIPTION
        A node cannot always read its own distinguished name right after the join (the Group Policy machine DN value stays empty until a policy
        refresh). This asks Active Directory instead: System.DirectoryServices.DirectorySearcher (no RSAT), bound with the join credential the run
        already holds (lcm_user, or domain_join_account) to the first address of identity.active_directory.domain_controllers that answers on TCP 389,
        filter (&(objectCategory=computer)(cn=<node name>)), reading distinguishedname and dnshostname. Nothing is written to Active Directory.
        The bind is the credential's attempt of the run: a tripped -Latch stops it before the secret is read, and a rejected bind trips the latch.
        The password is not logged, not in the result and not in an event. When no domain controller answers within the time, or anything else goes
        wrong, the answer is "not checked" with the reason (the OU stays unverified, as before); this never throws.
    .PARAMETER LdapQuery
        Test seam: { param($Request) } returning Reachable, Server, Entries, AuthFailed, Error. Default Invoke-DjLdapSearch.
    .OUTPUTS
        checked (an answer came from a domain controller), found, dn, dnsHostName, ou (the parent of the distinguished name), server, count,
        authFailed, error.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it is made a SecureString at once and only ever lives in memory.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecret -Reference $Ref },
        [hashtable]$Latch,
        [scriptblock]$LdapQuery,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15
    )
    $dj = Get-AzlProp $Spec 'DomainJoin'
    $name = [string](Get-AzlProp $Spec 'Name' '')
    $r = [pscustomobject]@{ checked = $false; found = $false; dn = ''; dnsHostName = ''; ou = ''; server = ''; count = 0; authFailed = $false; error = '' }
    if (-not $dj -or -not $dj.Applicable) { $r.error = 'the design does not join a domain'; return $r }
    if (Test-DjCredentialLocked $Latch) { $r.authFailed = $true; $r.error = Get-DjLatchText $Latch; return $r }
    $servers = @($dj.DomainControllers | Where-Object { $_ })
    if (-not $servers.Count) { $r.error = 'identity.active_directory.domain_controllers is empty, so there is no domain controller to ask'; return $r }
    if (-not $dj.HasAccount) { $r.error = 'there is no join credential'; return $r }
    $secure = $null
    $answer = $null
    try {
        try {
            $plain = [string](& $SecretResolver $dj.PasswordRef)
            $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $plain = $null
        }
        catch { $r.error = "Can't read the join account's password ($($dj.PasswordRef)): $($_.Exception.Message)"; return $r }
        $prefix = if ($dj.Netbios) { [string]$dj.Netbios } elseif ($dj.Domain) { ([string]$dj.Domain).Split('.')[0].ToUpperInvariant() } else { '' }
        $user = [string]$dj.Username
        if ($user -notmatch '[\\@]') { $user = if ($prefix) { "$prefix\$user" } else { "$user@$($dj.Domain)" } }
        $request = [pscustomobject]@{
            Servers = @($servers); Port = 389; Credential = [pscredential]::new($user, $secure); SearchRoot = (Get-DjDomainDn -Domain ([string]$dj.Domain) -OuPath ([string]$dj.OuPath))
            Filter = "(&(objectCategory=computer)(cn=$(Get-DjLdapFilterValue $name)))"; Properties = @('distinguishedname', 'dnshostname'); TimeoutSeconds = $TimeoutSeconds
        }
        $query = if ($LdapQuery) { $LdapQuery } else { { param($Request) Invoke-DjLdapSearch -Request $Request } }
        try { $answer = & $query $request }
        catch { $r.error = "the LDAP lookup of $name failed: $($_.Exception.Message)"; return $r }
    }
    finally { if ($secure) { $secure.Dispose() } }
    $r.server = [string](Get-AzlProp $answer 'Server' '')
    if ([bool](Get-AzlProp $answer 'AuthFailed' $false)) {
        # The one use of the credential per run: a rejection stops every later use of it, on every node (repeated bad passwords lock the account).
        $r.authFailed = $true
        $r.error = "the domain controller rejected the join credential ($($dj.CredentialSource) $($dj.Username)): $([string](Get-AzlProp $answer 'Error' ''))"
        Lock-DjCredential -Latch $Latch -Node $name -Reason $r.error
        return $r
    }
    if (-not [bool](Get-AzlProp $answer 'Reachable' $false)) {
        $why = [string](Get-AzlProp $answer 'Error' '')
        $r.error = if ($why) { $why } else { "no domain controller of the file answered on TCP 389 from this host (tried $($servers -join ', '))" }
        return $r
    }
    $why = [string](Get-AzlProp $answer 'Error' '')
    if ($why) { $r.error = $why; return $r }
    $entries = @(Get-AzlProp $answer 'Entries' @() | Where-Object { $_ })
    $r.checked = $true
    $r.count = $entries.Count
    if (-not $entries.Count) { $r.error = "no computer object named $name in $($dj.Domain) on $($r.server)"; return $r }
    # An object is this node's when its dnsHostName is empty (not set yet) or starts with the node's name.
    $mine = @($entries | Where-Object { $h = [string](Get-AzlProp $_ 'dnsHostName' ''); -not $h -or $h -like "$name.*" -or $h -ieq $name })
    if ($entries.Count -eq 1 -and -not $mine.Count) {
        $r.error = "the computer object $([string](Get-AzlProp $entries[0] 'distinguishedName' '')) has dnsHostName $([string](Get-AzlProp $entries[0] 'dnsHostName' '')), which is not $name, so it is not this node's"
        return $r
    }
    $exact = @($mine | Where-Object { [string](Get-AzlProp $_ 'dnsHostName' '') -like "$name.*" })
    $pick = if ($mine.Count -eq 1) { $mine[0] } elseif ($exact.Count -eq 1) { $exact[0] } else { $null }
    if (-not $pick) {
        $r.error = "$($entries.Count) computer objects are named ${name}: $((@($entries | ForEach-Object { [string](Get-AzlProp $_ 'distinguishedName' '') })) -join '; '); it is not known which one is this node's"
        return $r
    }
    $r.found = $true
    $r.dn = [string](Get-AzlProp $pick 'distinguishedName' '')
    $r.dnsHostName = [string](Get-AzlProp $pick 'dnsHostName' '')
    $r.ou = Get-DjOuOfDn $r.dn
    return $r
}

function Add-AzlDomainJoinLdapCheck {
    <#
    .SYNOPSIS
        For a member of the right domain whose node reports no distinguished name, asks Active Directory over LDAP from this host
        (Get-AzlDomainJoinLdapComputer) and attaches the answer to the state as domainJoin.ldap. Returns the answer, or $null when it does not apply.
    .DESCRIPTION
        Does nothing (and sends nothing) when the node is not a member of the domain of the file, when the node has its distinguished name (its own answer
        wins), or when the design does not join a domain. Read only; never throws. -Cached is an answer already obtained in this call, attached again
        instead of asking a second time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec, [Parameter(Mandatory)][AllowNull()][object]$State,
        [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecret -Reference $Ref }, [hashtable]$Latch, [scriptblock]$LdapQuery, [object]$Cached
    )
    $dj = Get-AzlProp $Spec 'DomainJoin'
    $ds = Get-AzlProp $State 'domainJoin'
    if (-not $dj -or -not $dj.Applicable -or -not $ds) { return $null }
    if (-not [bool](Get-AzlProp $ds 'partOfDomain' $false) -or [string](Get-AzlProp $ds 'domain' '') -ine $dj.Domain) { return $null }
    if ([string](Get-AzlProp $ds 'dn' '')) { return $null }
    $answer = if ($Cached) { $Cached } else { Get-AzlDomainJoinLdapComputer -Spec $Spec -SecretResolver $SecretResolver -Latch $Latch -LdapQuery $LdapQuery }
    Add-Member -InputObject $ds -NotePropertyName ldap -NotePropertyValue $answer -Force
    return $answer
}

function Invoke-AzlDomainJoinStep {    <#
    .SYNOPSIS
        Applies one DomainJoin plan item (join, move, add the local administrators, or finish a pending restart) on one node and verifies the result.
    .DESCRIPTION
        join     The Apply script runs Add-Computer -DomainName -OUPath -Credential -Restart:$false from a secure string. On a
                 failure the node stays in its workgroup and the exact error comes back with its code and a next action; the
                 join is not tried again in this run (a wrong password must not be sent twice). On success the node holds a
                 durable restart marker, then the guarded restart runs, the node is waited for (-WaitForRestart), read again,
                 verified (member, domain, secure channel, OU) and the marker is completed.
        move     Before the deployment and only with join_options.allow_ou_move: the computer object of a node already in the domain is
                 moved into the OU from the file (ADSI, join credential). Never after the deployment (Microsoft does not support it).
        admins   Adds the principals of local_admin_members to the local Administrators group (idempotent, no credential needed), event
                 DomainAdminsConfigured.
        restart  The join is done but the restart is still due (a run that stopped in between): restart, wait, verify.
        With -NoRestart nothing restarts; the result says the restart is pending.
    .PARAMETER WaitForRestart
        Scriptblock { param($PreviousBoot, $WaitContext) } that waits until the node answers with a new boot time and returns the fresh Read state.
    .PARAMETER WaitContext
        Handed to -WaitForRestart as its second argument (a scriptblock bound to another module cannot be a closure over the caller's variables).
    .OUTPUTS
        Changes (Id, Status, Detail), Failed, Error, NextAction, Restarted, Joined, Moved, State (the latest Read state, or the one given).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it is made a SecureString at once and only ever lives in memory.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EventContext', Justification = 'Used inside the script blocks that emit the events.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$Transport,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Item,
        [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecret -Reference $Ref },
        [switch]$NoRestart,
        [scriptblock]$WaitForRestart,
        [object]$WaitContext,
        [hashtable]$EventContext,
        [hashtable]$Latch,
        [scriptblock]$LdapQuery
    )
    $node = [string]$Spec.Name
    $dj = $Spec.DomainJoin
    $kind = [string]$Item.Apply.kind
    $transportKind = [string]$Transport.Kind
    $changes = [System.Collections.Generic.List[object]]::new()
    $out = [ordered]@{ Changes = $null; Failed = $false; Error = ''; NextAction = ''; Restarted = $false; Joined = $false; Moved = $false; State = $State; Kind = $kind; Unverified = $false; Ldap = $null }
    $changeId = [guid]::NewGuid().ToString('N')
    # A pending restart finishes the change of the marker: the node refuses a restart for any other changeId.
    # (An empty one asks the node to accept the marker whatever its changeId.)
    if ($kind -in 'domain-restart', 'domain-finalize') { $changeId = [string](Get-AzlProp $Item.Apply 'changeId' '') }
    $id = [string]$Item.Apply.id
    $emit = { param($name, $evidence, $level, $next, $data) Send-AzlDomainJoinEvent -EventContext $EventContext -Node $node -State $name -Evidence $evidence -Level $level -NextAction $next -Transport $transportKind -Data $data }
    $fail = {
        param($text, $next, $code)
        $out.Failed = $true; $out.Error = $text; $out.NextAction = $next
        $changes.Add([pscustomobject]@{ Id = $id; Status = 'failed'; Detail = "$text$(if ($next) { " Next: $next" })" })
        & $emit 'DomainJoinFailed' $text 'Error' $next @{ code = $code; domain = $dj.Domain; ou = $dj.OuPath }
        # A rejected credential (bad password 1326, disabled 1331, locked out 1909) stops every later use of it in the run, on every node.
        if ([string]$code -in '1326', '1331', '1909') { Lock-DjCredential -Latch $Latch -Node $node -Reason $text }
    }

    if ($kind -eq 'domain-admins') {
        $members = @($Item.Apply.members)
        try { $result = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinApply) -Parameters @{ mode = 'admins'; members = $members; changeId = $changeId } -TimeoutSeconds 600 -Tries 1 }
        catch {
            if ($_.Exception.Data['AzlState'] -eq 'Unknown') { $changes.Add([pscustomobject]@{ Id = $id; Status = 'unknown'; Detail = $_.Exception.Message }); $out.Changes = $changes.ToArray(); return [pscustomobject]$out }
            & $fail "The local administrators script failed on ${node}: $($_.Exception.Message)" 'Run again after fixing the cause.' ''
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
        if ([string]$result.status -eq 'failed') { & $fail "Could not add the local administrators: $($result.errorText)" ([string]$result.nextAction) '' }
        else {
            $changes.Add([pscustomobject]@{ Id = $id; Status = 'changed'; Detail = [string]$result.detail })
            & $emit 'DomainAdminsConfigured' "$node local Administrators: $($result.detail)" 'Info' '' @{ members = @($dj.LocalAdminMembers); added = @($result.added) }
        }
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }

    if ($kind -eq 'domain-finalize') {
        # The join was verified (the OU read, by the node or over LDAP from this host) in a run that could not complete the durable marker: complete it. Nothing is joined or restarted.
        try { $null = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinApply) -Parameters @{ mode = 'finalize'; domain = $dj.Domain; ou = $dj.OuPath; changeId = $changeId } -TimeoutSeconds 300 -Tries 1 }
        catch {
            if ($_.Exception.Data['AzlState'] -eq 'Unknown') { $changes.Add([pscustomobject]@{ Id = $id; Status = 'unknown'; Detail = $_.Exception.Message }); $out.Changes = $changes.ToArray(); return [pscustomobject]$out }
            & $fail "The marker of $node could not be completed: $($_.Exception.Message)" 'Run again; the join is verified and only its marker is left.' ''
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
        $by = [string](Get-AzlProp $Item.Apply 'verifiedBy' 'node')
        $changes.Add([pscustomobject]@{ Id = $id; Status = 'changed'; Detail = "$node is a member of $($dj.Domain), OU verified$(if ($by -eq 'ldap') { ' in Active Directory over LDAP' }), join marker completed" })
        $out.Joined = $true
        & $emit 'DomainJoined' "$node is a member of $($dj.Domain) in $($dj.OuPath)" 'Info' '' @{ domain = $dj.Domain; ou = $dj.OuPath; netbios = $dj.Netbios; dn = [string](Get-AzlProp $Item.Apply 'dn' ''); ouVerifiedBy = $by }
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }

    # The join account. Held as a SecureString; the plain text exists only in the hashtable handed to the transport.
    $secure = $null
    if (($kind -in 'domain-join', 'domain-move') -and (Test-DjCredentialLocked $Latch)) {
        # A wrong password must not be sent twice: after the first rejection no node in the run gets the credential.
        & $fail (Get-DjLatchText $Latch) 'Fix the secret or the account (locked, disabled, expired), then run again.' ''
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }
    if ($kind -in 'domain-join', 'domain-move') {
        try {
            $plain = [string](& $SecretResolver $dj.PasswordRef)
            $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $plain = $null
        }
        catch {
            & $fail "Can't read the join account's password ($($dj.PasswordRef)): $($_.Exception.Message)" 'Make identity.active_directory.domain_join_account.password readable (Key Vault secret get), then run again.' ''
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
    }
    $newSecrets = { @{ joinUser = [string]$dj.Username; joinPassword = [System.Net.NetworkCredential]::new('', $secure).Password } }

    $needRestart = $false
    if ($kind -eq 'domain-restart') { $needRestart = $true }
    elseif ($kind -eq 'domain-join') {
        & $emit 'DomainJoinApplying' "Joining $($dj.Domain), OU $($dj.OuPath), as $($dj.Username)" 'Info' '' @{ domain = $dj.Domain; ou = $dj.OuPath }
        $parameters = @{ mode = 'join'; domain = $dj.Domain; netbios = $dj.Netbios; ou = $dj.OuPath; expectedHost = [string]$Spec.Hostname; changeId = $changeId; resumeScript = (Get-AzlNodePayload -Name DomainJoinResume); server = [string](Get-AzlProp $Item.Apply 'server' '') }
        $secrets = & $newSecrets
        try { $result = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinApply) -Parameters $parameters -Secrets $secrets -TimeoutSeconds 1800 -Tries 1 }
        catch {
            if ($_.Exception.Data['AzlState'] -eq 'Unknown') {
                $changes.Add([pscustomobject]@{ Id = $id; Status = 'unknown'; Detail = $_.Exception.Message })
                $out.Changes = $changes.ToArray()
                return [pscustomobject]$out
            }
            & $fail "The join script failed on ${node}: $($_.Exception.Message)" 'Read the error; the node was not changed unless the report says otherwise. Run again after fixing the cause.' ''
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
        finally { $secrets.Clear() }
        if ([string]$result.status -eq 'failed') {
            $text = "$($result.errorText)$(if ($result.code) { " (error $($result.code), $($result.label))" } elseif ($result.label) { " ($($result.label))" })"
            & $fail $text ([string]$result.nextAction) ([string]$result.code)
            $stay = if ($null -ne $result.stillWorkgroup -and $result.stillWorkgroup -eq $true) { ' The node stays in its workgroup.' } else { '' }
            $changes[$changes.Count - 1].Detail += $stay
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
        $changes.Add([pscustomobject]@{ Id = $id; Status = 'changed'; Detail = [string]$result.detail })
        $needRestart = [bool]$result.reboot
        if (-not $needRestart) { $out.Joined = $true }
    }
    elseif ($kind -eq 'domain-move') {
        & $emit 'DomainJoinApplying' "Moving the computer object to $($dj.OuPath)" 'Info' '' @{ domain = $dj.Domain; ou = $dj.OuPath }
        $dcName = @($dj.DomainControllers | Select-Object -First 1)
        $parameters = @{ mode = 'move'; domain = $dj.Domain; netbios = $dj.Netbios; ou = $dj.OuPath; dn = [string]$Item.Apply.dn; dc = $(if ($dcName.Count) { [string]$dcName[0] } else { $dj.Domain }); changeId = $changeId }
        $secrets = & $newSecrets
        try { $result = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinApply) -Parameters $parameters -Secrets $secrets -TimeoutSeconds 600 -Tries 1 }
        catch {
            & $fail "The move script failed on ${node}: $($_.Exception.Message)" 'Run again after fixing the cause.' ''
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
        finally { $secrets.Clear() }
        if ([string]$result.status -eq 'failed') {
            & $fail "$($result.errorText)$(if ($result.code) { " (error $($result.code), $($result.label))" })" ([string]$result.nextAction) ([string]$result.code)
        }
        else {
            $changes.Add([pscustomobject]@{ Id = $id; Status = 'changed'; Detail = [string]$result.detail })
            $out.Moved = $true; $out.Joined = $true
            & $emit 'DomainJoined' "The computer object is now in $($dj.OuPath)" 'Info' '' @{ domain = $dj.Domain; ou = $dj.OuPath; moved = $true }
        }
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }

    if (-not $needRestart) { $out.Changes = $changes.ToArray(); return [pscustomobject]$out }
    if ($NoRestart) {
        $changes.Add([pscustomobject]@{ Id = "$id-restart"; Status = 'pending'; Detail = "$node joined $($dj.Domain) and still needs its restart (-NoRestart): restart it, then run the check again." })
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }

    # The guarded restart: the node refuses without its durable marker; we wait for a new boot, read it again and verify.
    & $emit 'NodeRestarting' "Restarting $node to finish joining $($dj.Domain)" 'Info' '' @{ domain = $dj.Domain }
    try {
        $r = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinRestart) -Parameters @{ changeId = $changeId; delaySeconds = 20 } -TimeoutSeconds 300 -Tries 1
        if ($null -ne $r.restartScheduled -and $r.restartScheduled -eq $false) {
            & $fail "The node did not restart: $($r.reason)" 'Run again; the join step reads the marker and finishes the restart.' ''
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
    }
    catch {
        # The node going away mid-call (state Unknown) is expected. Any other error is a failed step: it must not end the run of all nodes and lose the changes so far.
        if ($_.Exception.Data['AzlState'] -ne 'Unknown') {
            & $fail "The restart script failed on ${node}: $($_.Exception.Message)" 'Run again; the join step reads the marker and finishes the restart.' ''
            $out.Changes = $changes.ToArray()
            return [pscustomobject]$out
        }
    }
    try {
        $after = if ($WaitForRestart) { & $WaitForRestart ([string](Get-AzlProp $State 'boot' '')) $WaitContext } else { $State }
    }
    catch {
        & $fail "$node did not come back after the join restart: $($_.Exception.Message)" 'Check the node on its console (BMC); it is a member of the domain if the join succeeded. Run again when it answers.' ''
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }
    $out.State = $after
    $out.Restarted = $true
    & $emit 'NodeReconnected' "$node answers again after the restart (boot $(Get-AzlProp $after 'boot' ''))" 'Info' '' @{ boot = [string](Get-AzlProp $after 'boot' '') }
    # Group Policy stores the computer's distinguished name only after a refresh. Without it the OU cannot be checked, and Add-Computer reuses an existing
    # computer account wherever it sits (nothing moves it after the deployment), so the node refreshes the computer policy and reads the name again.
    if (-not [string](Get-AzlProp $after 'domainJoin.dn' '') -and (Get-AzlProp $after 'domainJoin')) {
        try {
            $located = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinApply) -Parameters @{ mode = 'locate'; domain = $dj.Domain; ou = $dj.OuPath; changeId = $changeId } -TimeoutSeconds 600 -Tries 1
            if ([string](Get-AzlProp $located 'dn' '')) { Add-Member -InputObject $after.domainJoin -NotePropertyName dn -NotePropertyValue ([string]$located.dn) -Force }
        }
        catch { Write-Verbose "The distinguished name of $node was not read: $($_.Exception.Message)" }
    }
    # Still no distinguished name on the node (the refresh did not fill it in time, or the call failed): ask Active Directory over LDAP from this host. The node's own answer wins when it has one.
    if (-not [string](Get-AzlProp $after 'domainJoin.dn' '') -and (Get-AzlProp $after 'domainJoin')) {
        $ldap = Add-AzlDomainJoinLdapCheck -Spec $Spec -State $after -SecretResolver $SecretResolver -Latch $Latch -LdapQuery $LdapQuery
        $out.Ldap = $ldap
    }
    $bad = @(Test-AzlDomainJoinVerification -Spec $Spec -State $after | Where-Object { -not $_.Ok })
    if ($bad.Count) {
        # Only "unverified" (the joined node is a member, secure channel and domain are right, the OU just could not be read): the other steps are independent and go on.
        $out.Unverified = (@($bad | Where-Object { -not $_.Unverified }).Count -eq 0)
        $next = if ($out.Unverified) { "The node is joined. Its OU could not be read from the node or from Active Directory: run again when a domain controller of identity.active_directory.domain_controllers answers on TCP 389 from the host running this command and the join credential is accepted (the join is not repeated; only the check and the marker are done), or check in Active Directory which OU the computer object is in (an account that already existed is reused where it is, and is not moved after the deployment)." } else { 'Test-ComputerSecureChannel -Repair on the node, check the time and the domain controllers, then run again. If the OU is wrong: check in Active Directory which OU the computer object is in (an account that already existed is reused where it is, and is not moved after the deployment).' }
        & $fail "The node joined $($dj.Domain) but the check after the restart failed: $(($bad | ForEach-Object { "$($_.Check) ($($_.Detail))" }) -join '; ')." $next ''
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }
    try { $null = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinApply) -Parameters @{ mode = 'finalize'; domain = $dj.Domain; ou = $dj.OuPath; changeId = $changeId } -TimeoutSeconds 300 -Tries 1 }
    catch { Write-Verbose "The marker of $node was not completed: $($_.Exception.Message)" }
    $out.Joined = $true
    $viaLdap = (-not [string](Get-AzlProp $after 'domainJoin.dn' '')) -and [bool](Get-AzlProp $after 'domainJoin.ldap.found' $false)
    $dnNow = if ([string](Get-AzlProp $after 'domainJoin.dn' '')) { [string]$after.domainJoin.dn } elseif ($viaLdap) { [string]$after.domainJoin.ldap.dn } else { '' }
    $changes.Add([pscustomobject]@{ Id = "$id-verified"; Status = 'changed'; Detail = "$node is a member of $($dj.Domain), secure channel ok$(if ($dnNow) { ", OU $(Get-DjOuOfDn $dnNow)" })$(if ($viaLdap) { ' (read in Active Directory over LDAP)' })" })
    & $emit 'DomainJoined' "$node is a member of $($dj.Domain) in $($dj.OuPath)" 'Info' '' @{ domain = $dj.Domain; ou = $dj.OuPath; netbios = $dj.Netbios; dn = $dnNow; ouVerifiedBy = $(if ($viaLdap) { 'ldap' } else { 'node' }) }
    $out.Changes = $changes.ToArray()
    return [pscustomobject]$out
}

Export-ModuleMember -Function Get-AzlDomainJoinSpec, Get-AzlDomainJoinReadParameter, Get-AzlDomainJoinPlanItem, Test-AzlDomainJoinVerification, Get-AzlDomainJoinSummary, Send-AzlDomainJoinEvent, Send-AzlDomainJoinPlanEvent, Merge-AzlDomainJoinOutcome, Add-AzlDomainJoinOuCheck, Get-AzlDomainJoinLdapComputer, Add-AzlDomainJoinLdapCheck, Invoke-AzlDomainJoinStep
