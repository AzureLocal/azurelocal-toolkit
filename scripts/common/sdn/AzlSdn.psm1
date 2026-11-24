#Requires -Version 7.0
<#
.SYNOPSIS
    The rules of SDN enabled by Azure Arc that more than one script checks. One copy, so the enable script and the prerequisite check agree.

.DESCRIPTION
    Get-AzlSdnIntentProblem       The Network ATC intent layouts that Microsoft Learn does not support with SDN enabled by Arc.
    ConvertTo-AzlSdnIntentTraffic The traffic list of an intent as Get-NetIntent reports it on a machine (IsManagementIntentSet and the others).
    Resolve-AzlSdnLogin           The account that connects to a machine of the instance (the deployment user of the file), with its password read
                                  from the secret reference.

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

Export-ModuleMember -Function Get-AzlSdnIntentProblem, ConvertTo-AzlSdnIntentTraffic, Resolve-AzlSdnLogin
