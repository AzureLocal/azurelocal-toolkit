#Requires -Version 7.0
<#
.SYNOPSIS
    The rules of SDN enabled by Azure Arc that more than one script checks. One copy, so the enable script and the prerequisite check agree.

.DESCRIPTION
    Get-AzlSdnIntentProblem       The Network ATC intent layouts that Microsoft Learn does not support with SDN enabled by Arc.
    ConvertTo-AzlSdnIntentTraffic The traffic list of an intent as Get-NetIntent reports it on a machine (IsManagementIntentSet and the others).

    Source: Microsoft Learn, Software Defined Networking enabled by Azure Arc on Azure Local (sdn-overview): Supported networking patterns and
    Unsupported intent configurations. Nothing here reads a file or a machine: the caller passes the intents.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Export-ModuleMember -Function Get-AzlSdnIntentProblem, ConvertTo-AzlSdnIntentTraffic
