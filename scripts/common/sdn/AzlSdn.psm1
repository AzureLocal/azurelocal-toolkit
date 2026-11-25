#Requires -Version 7.0
<#
.SYNOPSIS
    The rules of SDN enabled by Azure Arc that more than one script checks. One copy, so the enable script and the prerequisite check agree.

.DESCRIPTION
    Get-AzlSdnIntentProblem       The Network ATC intent layouts that Microsoft Learn does not support with SDN enabled by Arc.
    ConvertTo-AzlSdnIntentTraffic The traffic list of an intent as Get-NetIntent reports it on a machine (IsManagementIntentSet and the others).
    Resolve-AzlSdnLogin           The account that connects to a machine of the instance (the deployment user of the file), with its password read
                                  from the secret reference.
    Resolve-AzlSdnPrefix          The SDN prefix: sdn.prefix, or derived from cluster.name when it is not set.
    Resolve-AzlNsgAddressPrefix   The addresses of a network security group rule: literals as written, a reference (management, vlan:<name>, ...) as the subnet
                                  the file already holds.

    Source: Microsoft Learn, Software Defined Networking enabled by Azure Arc on Azure Local (sdn-overview): Supported networking patterns and
    Unsupported intent configurations. The intent functions read no file and no machine: the caller passes the intents. Resolve-AzlSdnLogin reads
    the loaded infrastructure file and one secret, and nothing else.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1')))
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'secrets', 'AzlSecret.psm1')))

function Get-AzlSdnField($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and "$($Map[$Key])" -ne '') { return $Map[$Key] }
    $Default
}

function Get-AzlSdnIntentProblem {
    <#
    .SYNOPSIS
        The reasons an intent layout is not supported by SDN enabled by Azure Arc, one sentence each. Empty when it is supported.
    .PARAMETER Intents
        The intents: mappings with name and traffic (management, compute, storage), as networking.intents[] of infrastructure.yml holds them.
    .PARAMETER NodeCount
        The number of machines of the instance.
    .PARAMETER Connectivity
        scenario.storage_connectivity: switched or switchless.
    .PARAMETER Architecture
        scenario.storage_architecture. The storage rules are not checked for san.
    .EXAMPLE
        Get-AzlSdnIntentProblem -Intents $infra.networking.intents -NodeCount 2 -Connectivity switchless -Architecture s2d
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([object[]]$Intents, [int]$NodeCount, [string]$Connectivity, [string]$Architecture)
    $problems = [System.Collections.Generic.List[string]]::new()
    $list = @($Intents | Where-Object { $_ -is [System.Collections.IDictionary] })
    if ($list.Count -eq 0) { return @() }
    $traffic = @{}
    foreach ($intent in $list) { $traffic[[string](Get-AzlSdnField $intent 'name' '?')] = @(@(Get-AzlSdnField $intent 'traffic' @()) | ForEach-Object { "$_".ToLowerInvariant() }) }
    if ($list.Count -gt 3) { $problems.Add("networking.intents holds $($list.Count) intents; SDN enabled by Arc supports at most three.") }
    foreach ($name in $traffic.Keys) {
        $t = $traffic[$name]
        if ('compute' -in $t -and 'storage' -in $t -and 'management' -notin $t) { $problems.Add("The intent '$name' carries compute and storage without management; SDN enabled by Arc does not support a combined compute and storage intent.") }
        if ($t.Count -eq 1 -and $t[0] -eq 'compute' -and $NodeCount -eq 1) { $problems.Add("The intent '$name' carries only compute on a single machine; SDN enabled by Arc does not support a standalone compute intent on one machine.") }
    }
    if ($Architecture -ne 'san') {
        $switchless = $Connectivity -eq 'switchless'
        if ($list.Count -eq 3 -and $NodeCount -in 2, 3 -and $switchless) { $problems.Add("Three intents on $NodeCount machines with switchless storage are not supported by SDN enabled by Arc.") }
        if ($list.Count -eq 1 -and @(@($traffic.Values)[0]).Count -ge 3 -and $switchless) { $problems.Add('The group-all-traffic intent is supported by SDN enabled by Arc only with switched storage (scenario.storage_connectivity).') }
        if ($NodeCount -ge 5 -and $switchless) { $problems.Add("$NodeCount machines are supported by SDN enabled by Arc only with switched storage (scenario.storage_connectivity).") }
        $storageIntents = @($traffic.Keys | Where-Object { 'storage' -in $traffic[$_] })
        $mgmtCompute = @($traffic.Keys | Where-Object { 'management' -in $traffic[$_] -and 'compute' -in $traffic[$_] -and 'storage' -notin $traffic[$_] })
        if ($mgmtCompute.Count -gt 0 -and $storageIntents.Count -eq 0 -and $NodeCount -gt 1) { $problems.Add('Management and compute in one intent without a storage intent is supported by SDN enabled by Arc only on a single machine.') }
    }
    @($problems)
}

function ConvertTo-AzlSdnIntentTraffic {
    <#
    .SYNOPSIS
        Turns intents as Get-NetIntent reports them (IntentName, IsManagementIntentSet, IsComputeIntentSet, IsStorageIntentSet) into the
        name and traffic mappings that Get-AzlSdnIntentProblem takes.
    .EXAMPLE
        ConvertTo-AzlSdnIntentTraffic -NetIntent (Get-NetIntent)
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([object[]]$NetIntent)
    foreach ($i in @($NetIntent | Where-Object { $null -ne $_ })) {
        $get = { param($o, $n) if ($o -is [System.Collections.IDictionary]) { $o[$n] } elseif ($o.PSObject.Properties[$n]) { $o.$n } else { $null } }
        $traffic = @()
        if ((& $get $i 'IsManagementIntentSet') -eq $true) { $traffic += 'management' }
        if ((& $get $i 'IsComputeIntentSet') -eq $true) { $traffic += 'compute' }
        if ((& $get $i 'IsStorageIntentSet') -eq $true) { $traffic += 'storage' }
        [ordered]@{ name = [string](& $get $i 'IntentName'); traffic = $traffic }
    }
}

function Resolve-AzlSdnLogin {
    <#
    .SYNOPSIS
        The account the SDN scripts use to connect to a machine of the instance, and its password read from the secret reference of the file.
    .DESCRIPTION
        One rule for Enable-ArcSdn.ps1, Test-ArcSdn.ps1 and Invoke-SdnPrerequisites-Orchestrated.ps1, so they ask the machine as the same account.
        Microsoft Learn runs the enablement as the deployment user (its example prompt is PS C:\DeploymentUser>), an account with the Azure Stack HCI
        administrator role. So: -Credential when given; otherwise, with Active Directory identity, the deployment (LCM) user
        identity.active_directory.lcm_user (as <netbios name>\<user>); with local identity, the local administrator identity.local_admin
        (as .\<user>). With -FallbackToLocalAdministrator an Active Directory file that has no deployment user uses the local administrator.
        The password is read through scripts/common/secrets/AzlSecret.psm1. Nothing is asked and nothing is printed.
    .PARAMETER Infrastructure
        The file as read by Import-AzlInfrastructure.
    .PARAMETER Credential
        Optional. Used as given.
    .PARAMETER FallbackToLocalAdministrator
        Optional. With Active Directory identity and no usable deployment user, use identity.local_admin.
    .OUTPUTS
        Credential (a pscredential, or null), Source (Parameter, DeploymentUser, LocalAdministrator, None), What (the file keys used), Problem (text, empty
        when the login is usable), ProblemKind (empty, Missing or Secret), ProblemExit (the exit code of the secret module for a reference that cannot be read: 1 or 2). Missing: the file names no account with a secret reference; the caller decides
        whether the account that runs the script is acceptable. Secret: the reference could not be read.
    .EXAMPLE
        $login = Resolve-AzlSdnLogin -Infrastructure $infra -Credential $Credential
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [pscredential]$Credential,
        [switch]$FallbackToLocalAdministrator
    )
    $result = { param($c, $s, $w, $p, $k) [pscustomobject]@{ Credential = $c; Source = $s; What = $w; Problem = $p; ProblemKind = $k; ProblemExit = 0 } }
    if ($Credential) { return & $result $Credential 'Parameter' '-Credential' '' '' }
    $text = { param($path) ([string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path $path)).Trim() }
    $mode = (& $text 'scenario.identity').ToLowerInvariant()
    $user = ''; $reference = ''; $account = ''; $what = ''; $source = ''
    if ($mode -ne 'local_identity') {
        $netbios = & $text 'identity.active_directory.netbios_name'
        $user = & $text 'identity.active_directory.lcm_user.username'; $reference = & $text 'identity.active_directory.lcm_user.password'
        $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'; $source = 'DeploymentUser'
    }
    if ($mode -eq 'local_identity' -or ((-not $user -or -not $reference) -and $FallbackToLocalAdministrator)) {
        $user = & $text 'identity.local_admin.username'; $reference = & $text 'identity.local_admin.password'
        $account = ".\$user"; $what = 'identity.local_admin'; $source = 'LocalAdministrator'
    }
    if (-not $user -or -not $reference) {
        return & $result $null 'None' $what "No login: pass -Credential, or set $what username and password (a secret reference) in the infrastructure file." 'Missing'
    }
    try { $secret = Get-AzlSecretValue -Reference $reference -Infrastructure $Infrastructure }
    catch {
        $failed = & $result $null 'None' $what "The password of $what could not be read: $($_.Exception.Message)" 'Secret'
        $code = 1
        if ($_.Exception.Data.Contains('AzlExit') -and -not [int]::TryParse([string]$_.Exception.Data['AzlExit'], [ref]$code)) { $code = 1 }
        $failed.ProblemExit = $code
        return $failed
    }
    & $result ([pscredential]::new($account, $secret)) $source $what '' ''
}

function Resolve-AzlSdnPrefix {
    <#
    .SYNOPSIS
        The SDN prefix (Add-EceFeature -SDNPrefix): sdn.prefix when the file sets it, otherwise derived from cluster.name.
    .DESCRIPTION
        One rule for Enable-ArcSdn.ps1 and Test-ArcSdn.ps1, so they use the same prefix. The registry key sdn.prefix is optional.
          1. sdn.prefix, when it is set, is used as written.
          2. Otherwise the prefix is derived from cluster.name: lower case, every character that is not a letter or a digit removed (hyphens too),
             the first eight characters kept.
        Either way the result must satisfy the rules of Microsoft Learn (Enable SDN integration): not empty, eight characters or fewer, letters,
        digits and hyphens only, no two hyphens in a row, no hyphen at the end; the toolkit also refuses a hyphen at the start. Two instances of one
        domain need two prefixes: when the derived prefix is shorter than the cluster name (Truncated), set sdn.prefix on the instances whose names
        share their first eight letters and digits.
    .PARAMETER Infrastructure
        The file as read by Import-AzlInfrastructure.
    .OUTPUTS
        Prefix (text, empty when there is a Problem), Source (sdn.prefix or cluster.name), Derived (bool), Truncated (bool, derived and cut to eight
        characters), Label (for the plan: 'prefix (sdn.prefix)' or 'prefix (derived from cluster.name)'), Problem (text, empty when usable).
    .EXAMPLE
        $p = Resolve-AzlSdnPrefix -Infrastructure $infra; Write-Information "$($p.Label): $($p.Prefix)"
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure)
    $rules = 'at most 8 characters, letters, digits and single hyphens, with no hyphen at the start or the end'
    $result = { param($p, $s, $d, $t, $problem) [pscustomobject]@{ Prefix = $(if ($problem) { '' } else { $p }); Source = $s; Derived = $d; Truncated = $t; Label = "prefix ($(if ($d) { 'derived from cluster.name' } else { 'sdn.prefix' }))"; Problem = $problem } }
    $set = ([string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'sdn.prefix')).Trim()
    $derived = $false; $truncated = $false; $source = 'sdn.prefix'
    if ($set) { $value = $set }
    else {
        $derived = $true; $source = 'cluster.name'
        $name = ([string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'cluster.name')).Trim()
        if (-not $name) { return & $result '' $source $true $false 'sdn.prefix is not set and cannot be derived, because cluster.name is missing. Set sdn.prefix, or cluster.name.' }
        $letters = ($name.ToLowerInvariant() -replace '[^a-z0-9]', '')
        if (-not $letters) { return & $result '' $source $true $false 'sdn.prefix is not set and cannot be derived: cluster.name holds no letter or digit. Set sdn.prefix.' }
        $truncated = $letters.Length -gt 8
        $value = $letters.Substring(0, [Math]::Min(8, $letters.Length))
    }
    if ($value.Length -gt 8 -or $value -notmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$') {
        return & $result '' $source $derived $truncated "The SDN prefix '$value' ($source) is not usable: $rules."
    }
    & $result $value $source $derived $truncated ''
}

function Resolve-AzlNsgAddressPrefix {
    <#
    .SYNOPSIS
        The addresses of a network security group rule: literal values as written, and a symbolic reference replaced by the subnet the file already holds.
    .DESCRIPTION
        networking.network_security_groups[].rules[].source_address_prefixes and destination_address_prefixes take, per entry:
          *                           any address (kept)
          an IPv4 address or a CIDR   kept as written
          management                  networking.management.subnet
          oob, automation, compute, storage
                                      every networking.vlans[] entry with that purpose and a subnet (all of them, when there are several)
          vlan:<name>                 the subnet of the networking.vlans[] entry with that name
          logical-network:<name>      address_prefix of the networking.logical_networks[] entry with that name
        The words are matched without regard to case. A reference that the file cannot answer (no such network, no subnet) is a Problem, never
        a guess. Nothing is read from anywhere but the file passed in.
    .PARAMETER Infrastructure
        The file as read by Import-AzlInfrastructure.
    .PARAMETER Value
        The entries of the list as written in the file.
    .OUTPUTS
        Addresses (the list to validate and send, without duplicates), Notes (one line for every reference: the word, the address and the variable it
        came from), Problem (text, empty when every entry is usable).
    .EXAMPLE
        $r = Resolve-AzlNsgAddressPrefix -Infrastructure $infra -Value @('management')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Value
    )
    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    $literal = "^(\*|($octet\.){3}$octet(/([0-9]|[12][0-9]|3[0-2]))?)$"
    $addresses = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $fail = { param($text) [pscustomobject]@{ Addresses = @(); Notes = @($notes); Problem = $text } }
    $add = { param($items) foreach ($a in $items) { if ($addresses -notcontains $a) { $addresses.Add($a) } } }
    $list = { param($path) @(@(Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path $path) | Where-Object { $null -ne $_ } | ForEach-Object { $_ }) }
    foreach ($entry in $Value) {
        $text = $entry.Trim()
        if ($text -match $literal) { & $add @($text); continue }
        $key = $text.ToLowerInvariant()
        if ($key -eq 'management') {
            $subnet = ([string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'networking.management.subnet')).Trim()
            if (-not $subnet) { return & $fail "'$text' means networking.management.subnet, which the file does not set." }
            & $add @($subnet); $notes.Add("$text = $subnet (networking.management.subnet)")
        }
        elseif ($key -in 'oob', 'automation', 'compute', 'storage') {
            $found = @(& $list 'networking.vlans' | Where-Object { $_ -is [System.Collections.IDictionary] -and ([string](Get-AzlSdnField $_ 'purpose' '')).Trim() -ieq $key -and ([string](Get-AzlSdnField $_ 'subnet' '')).Trim() })
            if ($found.Count -eq 0) { return & $fail "'$text' means the networks of networking.vlans[] with purpose $key and a subnet, and the file has none." }
            $subnets = @($found | ForEach-Object { ([string]$_['subnet']).Trim() })
            & $add $subnets; $notes.Add("$text = $($subnets -join ', ') (networking.vlans[] with purpose ${key}: $(@($found | ForEach-Object { [string](Get-AzlSdnField $_ 'name' '?') }) -join ', '))")
        }
        elseif ($key -like 'vlan:*' -or $key -like 'logical-network:*') {
            $kind = $key.Substring(0, $key.IndexOf(':')); $name = $text.Substring($text.IndexOf(':') + 1).Trim()
            $path = if ($kind -eq 'vlan') { 'networking.vlans' } else { 'networking.logical_networks' }
            $field = if ($kind -eq 'vlan') { 'subnet' } else { 'address_prefix' }
            if (-not $name) { return & $fail "'$text' names no entry: write the name after the colon." }
            $hit = @(& $list $path | Where-Object { $_ -is [System.Collections.IDictionary] -and ([string](Get-AzlSdnField $_ 'name' '')).Trim() -ieq $name })
            if ($hit.Count -eq 0) { return & $fail "'$text' names '$name', which is not in ${path}[]." }
            if ($hit.Count -gt 1) { return & $fail "'$text' is ambiguous: ${path}[] has $($hit.Count) entries named '$name' (names are compared without regard to case)." }
            $subnet = ([string](Get-AzlSdnField $hit[0] $field '')).Trim()
            if (-not $subnet) { return & $fail "'${text}': the entry '${name}' of ${path}[] has no ${field}." }
            & $add @($subnet); $notes.Add("$text = $subnet (${path}[].${field} of '${name}')")
        }
        else { return & $fail "'$text' is not usable. Use *, an IPv4 address, an IPv4 range in CIDR form, or a reference: management, oob, automation, compute, storage, vlan:<name> or logical-network:<name>." }
    }
    [pscustomobject]@{ Addresses = @($addresses); Notes = @($notes); Problem = '' }
}

Export-ModuleMember -Function Get-AzlSdnIntentProblem, ConvertTo-AzlSdnIntentTraffic, Resolve-AzlSdnLogin, Resolve-AzlSdnPrefix, Resolve-AzlNsgAddressPrefix
