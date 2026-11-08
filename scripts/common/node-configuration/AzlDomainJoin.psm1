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
    Test-AzlDomainJoinVerification   After the restart: member, right domain, secure channel, right OU.
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
    $ouNow = Get-DjOuOfDn $dn
    $out = [System.Collections.Generic.List[object]]::new()

    if ($isMember) {
        if ($domainNow -ine $dj.Domain) {
            return , (New-DjPlanItem $n 'domain membership' "member of $domainNow" $want Blocked "The node is joined to a different domain. It is never unjoined automatically: if $domainNow is wrong, run Remove-Computer on the node yourself (then it joins $($dj.Domain)), or correct identity.active_directory.domain_fqdn.")
        }
        $marker = Get-AzlProp $ds 'marker'
        $markerState = [string](Get-AzlProp $marker 'state' '')
        $restartDue = $markerState -in $script:PendingMarkerStates -and [string](Get-AzlProp $marker 'bootBefore' '') -eq [string](Get-AzlProp $ds 'boot' '')
        $inCluster = [bool](Get-AzlProp $ds 'inCluster' $false)
        if ($restartDue) {
            $out.Add((New-DjPlanItem $n 'domain membership' "joined $domainNow, restart pending" "$want, restarted and verified" Change 'The join succeeded but the node has not restarted since (the durable restart marker is still set). It is restarted and verified now.' @{ id = 'DomainJoin/restart'; kind = 'domain-restart'; domain = $dj.Domain; ou = $dj.OuPath }))
        }
        elseif (-not $dn) {
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU not read" $want Info 'The OU could not be verified: Group Policy has not stored the computer''s distinguished name on the node yet.'))
        }
        elseif ((ConvertTo-DjOuKey $ouNow) -eq (ConvertTo-DjOuKey $dj.OuPath)) {
            $out.Add((New-DjPlanItem $n 'domain membership' "member of $domainNow, OU $ouNow" $want Ok))
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
    if (-not [bool](Get-AzlProp $ds 'dnsOk' $false)) {
        $why = [string](Get-AzlProp $ds 'dnsError' '')
        $reasons.Add("DNS cannot resolve $($dj.Domain) from the node$(if ($why) { " ($why)" }). The management port's DNS servers must be the domain controllers (identity.active_directory.domain_controllers, rule AZL-052); the Dns step sets them.")
    }
    elseif (-not [bool](Get-AzlProp $ds 'srvOk' $false)) {
        $reasons.Add("DNS answers for $($dj.Domain) but has no domain controller SRV record (_ldap._tcp.dc._msdcs.$($dj.Domain)). The DNS servers are not the domain's.")
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
    $apply = @{ id = 'DomainJoin/join'; kind = 'domain-join'; domain = $dj.Domain; netbios = $dj.Netbios; ou = $dj.OuPath; expectedHost = [string]$Spec.Hostname; dcs = @($dj.DomainControllers) }
    return , (New-DjPlanItem $n 'domain membership' $current $want Change "Add-Computer into the OU with $($dj.CredentialSource), then a guarded restart and a check. $note".Trim() $apply)
}

function Get-DjOuItem {
    # The dedicated OU Microsoft requires: it exists, Group Policy inheritance is blocked on it, and the enforced links above it.
    param([object]$Spec, [object]$State)
    $n = [string]$Spec.Name
    $dj = $Spec.DomainJoin
    $ou = Get-AzlProp (Get-AzlProp $State 'domainJoin') 'ou'
    if (-not $ou) { return @() }
    $items = [System.Collections.Generic.List[object]]::new()
    if (-not [bool](Get-AzlProp $ou 'checked' $false)) {
        $reason = [string](Get-AzlProp $ou 'error' '')
        if ([bool](Get-AzlProp $ou 'exists' $true) -eq $false -and $reason -match 'no such object|0x80072030|does not exist') {
            $items.Add((New-DjPlanItem $n 'organizational unit' 'not found' $dj.OuPath Blocked "The OU $($dj.OuPath) does not exist in the domain. Create it with New-HciAdObjectsPreCreation (it also blocks Group Policy inheritance and gives the LCM user its rights), or correct identity.active_directory.ou_path."))
        }
        else {
            $items.Add((New-DjPlanItem $n 'organizational unit' 'not checked' "$($dj.OuPath), inheritance blocked" Info "The OU and its Group Policy inheritance were not checked: $(if ($reason) { $reason } else { 'the join credential could not be used yet' })."))
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
    $marker = Get-AzlProp $ds 'marker'
    if ([string](Get-AzlProp $marker 'state' '') -in $script:PendingMarkerStates -and [string](Get-AzlProp $marker 'bootBefore' '') -eq [string](Get-AzlProp $ds 'boot' '')) { return @() }
    $have = Get-AzlProp $ds 'localAdmins'
    if ($null -eq $have) { return , (New-DjPlanItem $n 'local administrators' 'unreadable' ($wanted -join ', ') Info 'The node did not report its local Administrators group.') }
    $have = @($have | ForEach-Object { [string]$_ })
    $missing = @($wanted | Where-Object { $w = $_; $short = $w -replace '^.*\\', ''; -not (@($have | Where-Object { $_ -ieq $w -or $_ -ieq $short }).Count) })
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
        Computer name differs from the file        Blocked, or Skipped when the Hostname step runs in this pass (it goes first)
        DNS cannot resolve the domain, no domain controller SRV record or none reachable, clock over 5 minutes apart,
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
        Check, Ok, Detail. The OU check passes with a note when the node has no distinguished name to read yet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [AllowNull()][object]$State)
    $dj = $Spec.DomainJoin
    $ds = Get-AzlProp $State 'domainJoin'
    $domainNow = [string](Get-AzlProp $ds 'domain' '')
    $member = [bool](Get-AzlProp $ds 'partOfDomain' $false)
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([pscustomobject]@{ Check = 'PartOfDomain'; Ok = $member; Detail = "PartOfDomain is $member" })
    $checks.Add([pscustomobject]@{ Check = 'Domain'; Ok = ($member -and $domainNow -ieq $dj.Domain); Detail = "domain is '$domainNow', the file says '$($dj.Domain)'" })
    $channel = Get-AzlProp $ds 'secureChannel'
    $checks.Add([pscustomobject]@{ Check = 'SecureChannel'; Ok = ($channel -eq $true); Detail = "Test-ComputerSecureChannel returned $channel" })
    $dn = [string](Get-AzlProp $ds 'dn' '')
    if ($dn) {
        $ouNow = Get-DjOuOfDn $dn
        $checks.Add([pscustomobject]@{ Check = 'OU'; Ok = ((ConvertTo-DjOuKey $ouNow) -eq (ConvertTo-DjOuKey $dj.OuPath)); Detail = "the computer object is in '$ouNow', the file says '$($dj.OuPath)'" })
    }
    else { $checks.Add([pscustomobject]@{ Check = 'OU'; Ok = $true; Detail = 'not verified: the node has no distinguished name to read yet' }) }
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
        localAdminsPresent = $(if ($joined -and $null -ne (Get-AzlProp $ds 'localAdmins')) { @($dj.LocalAdminMembers | Where-Object { $w = $_; $short = $w -replace '^.*\\\\', ''; -not @(@($ds.localAdmins) | Where-Object { $_ -ieq $w -or $_ -ieq $short }).Count }).Count -eq 0 } else { $null })
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

function Add-AzlDomainJoinOuCheck {
    <#
    .SYNOPSIS
        Reads the dedicated OU over LDAP from the node with the join credential (it exists, gPOptions says inheritance is blocked, the
        enforced GPO links above it) and attaches the answer to the state as domainJoin.ou. Returns the state. Never throws: when the
        credential or the domain controller is not usable yet, the answer says why and the plan shows Info.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret was just read from Key Vault; it is made a SecureString at once and only ever lives in memory.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec, [Parameter(Mandatory)][object]$Transport, [Parameter(Mandatory)][object]$State, [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecret -Reference $Ref })
    $dj = $Spec.DomainJoin
    $ds = Get-AzlProp $State 'domainJoin'
    if (-not $dj -or -not $dj.Applicable -or -not $ds) { return $State }
    $ou = [pscustomobject]@{ checked = $false; exists = $true; gpOptions = $null; blockInheritance = $false; enforcedLinks = @(); error = '' }
    if (-not [bool](Get-AzlProp $ds 'dcReachable' $false)) { $ou.error = 'no domain controller is reachable from the node yet' }
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
        }
        catch { $ou.error = "can't read the OU: $($_.Exception.Message)" }
        finally { if ($secrets) { $secrets.Clear() } }
    }
    Add-Member -InputObject $ds -NotePropertyName ou -NotePropertyValue $ou -Force
    return $State
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
        [hashtable]$EventContext
    )
    $node = [string]$Spec.Name
    $dj = $Spec.DomainJoin
    $kind = [string]$Item.Apply.kind
    $transportKind = [string]$Transport.Kind
    $changes = [System.Collections.Generic.List[object]]::new()
    $out = [ordered]@{ Changes = $null; Failed = $false; Error = ''; NextAction = ''; Restarted = $false; Joined = $false; Moved = $false; State = $State; Kind = $kind }
    $changeId = [guid]::NewGuid().ToString('N')
    $id = [string]$Item.Apply.id
    $emit = { param($name, $evidence, $level, $next, $data) Send-AzlDomainJoinEvent -EventContext $EventContext -Node $node -State $name -Evidence $evidence -Level $level -NextAction $next -Transport $transportKind -Data $data }
    $fail = {
        param($text, $next, $code)
        $out.Failed = $true; $out.Error = $text; $out.NextAction = $next
        $changes.Add([pscustomobject]@{ Id = $id; Status = 'failed'; Detail = "$text$(if ($next) { " Next: $next" })" })
        & $emit 'DomainJoinFailed' $text 'Error' $next @{ code = $code; domain = $dj.Domain; ou = $dj.OuPath }
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

    # The join account. Held as a SecureString; the plain text exists only in the hashtable handed to the transport.
    $secure = $null
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
        $parameters = @{ mode = 'join'; domain = $dj.Domain; netbios = $dj.Netbios; ou = $dj.OuPath; expectedHost = [string]$Spec.Hostname; changeId = $changeId; resumeScript = (Get-AzlNodePayload -Name DomainJoinResume) }
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
    catch { if ($_.Exception.Data['AzlState'] -ne 'Unknown') { throw } }
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
    $bad = @(Test-AzlDomainJoinVerification -Spec $Spec -State $after | Where-Object { -not $_.Ok })
    if ($bad.Count) {
        & $fail "The node joined $($dj.Domain) but the check after the restart failed: $(($bad | ForEach-Object { "$($_.Check) ($($_.Detail))" }) -join '; ')." 'Test-ComputerSecureChannel -Repair on the node, check the time and the domain controllers, then run again.' ''
        $out.Changes = $changes.ToArray()
        return [pscustomobject]$out
    }
    try { $null = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name DomainJoinApply) -Parameters @{ mode = 'finalize'; domain = $dj.Domain; ou = $dj.OuPath; changeId = $changeId } -TimeoutSeconds 300 -Tries 1 }
    catch { Write-Verbose "The marker of $node was not completed: $($_.Exception.Message)" }
    $out.Joined = $true
    $changes.Add([pscustomobject]@{ Id = "$id-verified"; Status = 'changed'; Detail = "$node is a member of $($dj.Domain), secure channel ok$(if (Get-AzlProp $after 'domainJoin.dn') { ", OU $(Get-DjOuOfDn ([string]$after.domainJoin.dn))" })" })
    & $emit 'DomainJoined' "$node is a member of $($dj.Domain) in $($dj.OuPath)" 'Info' '' @{ domain = $dj.Domain; ou = $dj.OuPath; netbios = $dj.Netbios; dn = [string](Get-AzlProp $after 'domainJoin.dn' '') }
    $out.Changes = $changes.ToArray()
    return [pscustomobject]$out
}

Export-ModuleMember -Function Get-AzlDomainJoinSpec, Get-AzlDomainJoinReadParameter, Get-AzlDomainJoinPlanItem, Test-AzlDomainJoinVerification, Get-AzlDomainJoinSummary, Send-AzlDomainJoinEvent, Send-AzlDomainJoinPlanEvent, Merge-AzlDomainJoinOutcome, Add-AzlDomainJoinOuCheck, Invoke-AzlDomainJoinStep
