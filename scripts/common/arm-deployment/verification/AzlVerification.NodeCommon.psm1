#Requires -Version 7.0
<#
.SYNOPSIS
    What the node, network, storage and readiness verification modules share: the result builder, the node list and the intents of the
    file, the adapter plumbing, and the ONE read only payload that collects everything about a node in a single remote call.

.DESCRIPTION
    Part of the pre-cluster verification gate (docs/pre-cluster-verification.md). The category modules
    (AzlVerification.Nodes.psm1, .Network.psm1, .Storage.psm1) import this module and export Get-AzlVerificationCheckDefinition and
    Get-AzlVerificationAdapterDefault.

    The adapter members this family defines (all under $Context.Adapters; tests replace any of them with a fake):

      Remote.Invoke(node, scriptblock [, argumentList])  read only node query (shared with the identity checks)
      Node.GetSnapshot(node, Context)    the whole payload of one node (one remote call per node, cached in the Context)
      Node.GetOsBuild / GetHardware / GetTime / GetDns / GetFeatures / GetReboot / GetDisks / GetAdapters / GetMpio / GetProbes (node, Context)
                                         one section of the snapshot each
      Readiness.GetModule(node, Context) the Environment Checker modules a node has
      Readiness.Run(validator, Context)  runs an Environment Checker validator where the module is installed

    Everything here reads. Nothing here changes a node, Azure or Active Directory. No secret is read, kept or shown.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlVerification.Endpoints.psm1'))

$script:ConfigRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'config'))

$script:Learn = 'https://learn.microsoft.com/en-us/azure/azure-local'
$script:View = 'view=azloc-2610'
$script:Docs = 'https://azurelocal.cloud/docs/implementation'
$script:Src = @{
    Prereq     = "$script:Learn/deploy/deployment-prerequisites?$script:View"
    Install    = "$script:Learn/deploy/deployment-install-os?$script:View"
    InstallDa  = "$script:Learn/deploy/deployment-install-os-disaggregated?$script:View"
    ExtStorage = "$script:Learn/deploy/enable-external-storage?$script:View"
    NetPlan    = "$script:Learn/plan/cloud-deployment-network-considerations?$script:View"
    HostNet    = "$script:Learn/concepts/host-network-requirements?$script:View"
    SysReq     = "$script:Learn/concepts/system-requirements-23h2?$script:View"
    EnvChecker = "$script:Learn/manage/use-environment-checker?$script:View"
    Firewall   = "$script:Learn/concepts/firewall-requirements?$script:View"
    DocsOs     = "$script:Docs/04-cluster-deployment/phase-03-os-configuration"
    DocsEnv    = "$script:Docs/03-onprem-readiness/phase-02-enterprise-readiness/task-05-environment-checker-readiness"
}

# Defaults of the thresholds. A new setting is NOT registered by this module (registry first, one owner): the name below is read from
# $Context.Settings when it is there, else the default applies. See the report of the change that added this file for the registration.
$script:Default = @{
    verificationMinMemoryGiB        = 32
    verificationMinBootDiskGB       = 200
    verificationMinDataDiskGB       = 500
    verificationMinLinkGbps         = 10
    verificationMaxClockSkewSeconds = 300
}

# The Windows features the Azure Local OS carries and the deployment uses. Required are Failed when off; Advised are a Warning.
$script:RequiredFeature = @('Hyper-V', 'Failover-Clustering', 'Data-Center-Bridging', 'NetworkATC', 'BitLocker')
$script:AdvisedFeature = @('FS-Data-Deduplication', 'RSAT-AD-PowerShell', 'RSAT-Clustering-PowerShell')
$script:PublicDns = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220')

# OS build -> the solution line it ships with. Keep in step with $script:SolutionOsBuilds in AzlArmDeploymentRun.psm1 (same evidence).
$script:RunTable = @{}
$script:SolutionOsBuild = @(
    [pscustomobject]@{ OsBuild = '10.0.26100.33650'; Solution = '12.2610.1004'; Evidence = 'lab 2026-11-08: nodes on 10.0.26100.33650, Azure reported solution 12.2610.1004.50' }
)

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlVerList {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) { return @($Value) }
    return @($Value)
}

function Join-AzlVerList {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object[]]$Item)
    $list = @($Item | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [string]$_ })
    if ($list.Count -le 1) { return ($list -join '') }
    return (($list | Select-Object -SkipLast 1) -join ', ') + ' and ' + $list[-1]
}

function New-AzlVerResult {
    <#
    .SYNOPSIS
        One result of a check: Status, Node ('*' when it is not about one node), Message, Remedy (the exact command or steps) and Evidence.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('Passed', 'Failed', 'Warning', 'Skipped', 'NotApplicable')][string]$Status,
        [Parameter(Mandatory, Position = 1)][string]$Message,
        [Parameter(Position = 2)][string]$Remedy = '',
        [string]$Node = '*',
        [string]$Evidence = ''
    )
    if ($Evidence.Length -gt 600) { $Evidence = $Evidence.Substring(0, 597) + '...' }
    [pscustomobject]@{ Status = $Status; Node = $Node; Message = $Message; Remedy = $Remedy; Evidence = $Evidence }
}

function New-AzlVerDefinition {
    <#
    .SYNOPSIS
        One check definition of the contract: Id, Category, Title, Source, Reads, Blocking, Applies, Run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('nodes', 'network', 'storage', 'readiness')][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][scriptblock]$Run,
        [string]$Reads = 'the nodes (WinRM, read only)',
        [scriptblock]$Applies = { param($Context) $true },
        [bool]$Blocking = $true
    )
    # The Run the engine sees is a wrapper bound to this module: whatever the check throws (a skip, an error) becomes a result, never an exception.
    $script:RunTable[$Id] = $Run
    $wrapper = $ExecutionContext.SessionState.Module.NewBoundScriptBlock([scriptblock]::Create("param(`$Context) Invoke-AzlVerRegisteredRun -Id '$Id' -Context `$Context"))
    [pscustomobject]@{ Id = $Id; Category = $Category; Title = $Title; Source = $Source; Reads = $Reads; Blocking = $Blocking; Applies = $Applies; Run = $wrapper }
}

function Invoke-AzlVerRegisteredRun {
    <#
    .SYNOPSIS
        Runs the check registered under -Id. A skip (Stop-AzlVerSkip) becomes one Skipped result, any other error one Failed result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)]$Context)
    try { & $script:RunTable[$Id] $Context }
    catch {
        if ($_.Exception.Data['AzlSkip']) { New-AzlVerResult Skipped $_.Exception.Message ([string]$_.Exception.Data['AzlRemedy']) }
        else { New-AzlVerResult Failed "The check could not run: $($_.Exception.Message)" 'Read the message, fix the cause and run the verification again.' }
    }
}

function Get-AzlVerSetting {
    <#
    .SYNOPSIS
        A threshold: $Context.Settings.<name> when set, else the default of this module.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $v = Get-AzlProp (Get-AzlVerContextValue $Context 'Settings') $Name $null
    if ($null -ne $v -and "$v" -ne '') { return $v }
    return $script:Default[$Name]
}

function Get-AzlVerContextValue {
    param($Context, [string]$Name, $Default = $null)
    if ($null -eq $Context) { return $Default }
    if ($Context -is [System.Collections.IDictionary]) { if ($Context.Contains($Name)) { return $Context[$Name] } else { return $Default } }
    $p = $Context.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Get-AzlVerInfra {
    param([Parameter(Mandatory)]$Context)
    $i = Get-AzlVerContextValue $Context 'Infrastructure'
    if ($null -eq $i) { throw 'The context has no Infrastructure.' }
    return $i
}

function Get-AzlVerArchitecture {
    <#
    .SYNOPSIS
        scenario.storage_architecture (s2d | san | hybrid); s2d when the file says nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Context)
    $a = ([string](Get-AzlProp (Get-AzlVerInfra $Context) 'scenario.storage_architecture' 's2d')).ToLowerInvariant()
    if ($a -in 's2d', 'san', 'hybrid') { return $a }
    return 's2d'
}

function Test-AzlVerSanDeclared {
    <#
    .SYNOPSIS
        $true when the file declares a SAN: storage_architecture san or hybrid, or a storage.san block.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Context)
    if ((Get-AzlVerArchitecture $Context) -in 'san', 'hybrid') { return $true }
    $san = Get-AzlProp (Get-AzlVerInfra $Context) 'storage.san' $null
    if ($san -is [System.Collections.IDictionary]) { return ($san.Count -gt 0) }
    return $false
}

function Get-AzlVerNodeList {
    <#
    .SYNOPSIS
        The nodes of the file: Name, ManagementIp, Adapters (nodes[].network_adapters).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    @(foreach ($n in (ConvertTo-AzlVerList (Get-AzlProp (Get-AzlVerInfra $Context) 'nodes' @()))) {
            $name = [string](Get-AzlProp $n 'name' '')
            if (-not $name) { continue }
            $adapters = @(ConvertTo-AzlVerList (Get-AzlProp $n 'network_adapters' @()))
            $ip = ''
            foreach ($a in $adapters) {
                $roles = @(ConvertTo-AzlVerList (Get-AzlProp $a 'roles' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
                $candidate = [string](Get-AzlProp $a 'ip_address' '')
                if ($candidate -and ('management' -in $roles)) { $ip = $candidate; break }
            }
            if (-not $ip) { $ip = [string](Get-AzlProp $n 'management.ip_address' '') }
            [pscustomobject]@{ Name = $name; ManagementIp = $ip; Adapters = $adapters }
        })
}

function Get-AzlVerIntent {
    <#
    .SYNOPSIS
        The network intents of the file (networking.intents): Name, Traffic (lower case), Adapters, NetworkDirect (Enabled, Disabled or
        '' = Network ATC default), Jumbo.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    @(foreach ($i in (ConvertTo-AzlVerList (Get-AzlProp (Get-AzlVerInfra $Context) 'networking.intents' @()))) {
            $traffic = @(ConvertTo-AzlVerList (Get-AzlProp $i 'traffic' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $direct = Get-AzlProp $i 'overrides.adapter.network_direct' $null
            $nd = ''
            if ($null -ne $direct) { $nd = $(if ([bool]$direct) { 'Enabled' } else { 'Disabled' }) }
            [pscustomobject]@{
                Name          = [string](Get-AzlProp $i 'name' '')
                Traffic       = $traffic
                Adapters      = @(ConvertTo-AzlVerList (Get-AzlProp $i 'adapters' @()) | ForEach-Object { [string]$_ })
                NetworkDirect = $nd
                Jumbo         = [string](Get-AzlProp $i 'overrides.adapter.jumbo_packet' '')
            }
        })
}

function Test-AzlVerNetworkDirect {
    <#
    .SYNOPSIS
        Whether RDMA (Network Direct) is on for an intent: the file's override, else Network ATC's default (on for storage, off otherwise).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Intent)
    if ($Intent.NetworkDirect -eq 'Enabled') { return $true }
    if ($Intent.NetworkDirect -eq 'Disabled') { return $false }
    return ('storage' -in $Intent.Traffic)
}

function Get-AzlVerTargetSolution {
    <#
    .SYNOPSIS
        The solution version the deployment installs: Settings.solutionVersion, the ZTP handoff (VsrVersion), else provisioning.os_version.
        '' when none is declared.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Context)
    $re = '^\d+\.\d+\.\d+\.\d+$'
    $s = [string](Get-AzlProp (Get-AzlVerContextValue $Context 'Settings') 'solutionVersion' '')
    if ($s -match $re) { return $s }
    $h = [string](Get-AzlProp (Get-AzlVerContextValue $Context 'Handoff') 'VsrVersion' '')
    if ($h -match $re) { return $h }
    $v = [string](Get-AzlProp (Get-AzlVerInfra $Context) 'provisioning.os_version' '')
    if ($v -match $re) { return $v }
    return ''
}

function ConvertFrom-AzlVerOsBuild {
    <#
    .SYNOPSIS
        The solution line (three parts) an OS build ships with, from the table of builds seen on a real deployment; $null for any other.
        Accepts 10.0.26100.33650 and 26100.33650.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$OsBuild)
    if (-not $OsBuild) { return $null }
    $b = $OsBuild.Trim()
    if ($b -match '^\d+\.\d+$') { $b = "10.0.$b" }
    $row = $script:SolutionOsBuild | Where-Object { $_.OsBuild -eq $b } | Select-Object -First 1
    if (-not $row) { return $null }
    [pscustomobject]@{ Version = $row.Solution; OsBuild = $row.OsBuild; Evidence = $row.Evidence }
}

function Get-AzlVerSanVendor {
    <#
    .SYNOPSIS
        The MSDSM hardware IDs for a SAN array from config/san/msdsm-vendors.json; $null for a vendor not in the table.
    #>
    [CmdletBinding()]
    param([string]$Vendor, [string]$Model, [string]$ConfigRoot = $script:ConfigRoot)
    $file = Join-Path (Join-Path $ConfigRoot 'san') 'msdsm-vendors.json'
    $table = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -Depth 10
    foreach ($v in $table.vendors) {
        if ($Vendor -notmatch "(?i)^($($v.match))") { continue }
        if ($v.model -and $Model -notmatch "(?i)($($v.model))") { continue }
        return [pscustomobject]@{ Hardware = @($v.hardware) }
    }
    return $null
}

function Format-AzlVerMsdsmId {
    <#
    .SYNOPSIS
        The device string mpclaim wants: the vendor ID padded to 8 and the product ID padded to 16 characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VendorId, [Parameter(Mandatory)][string]$ProductId)
    return ($VendorId.PadRight(8) + $ProductId.PadRight(16))
}

# ---------------------------------------------------------------------------------------------------------------------
# Adapter plumbing
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlVerAdapterMember {
    <#
    .SYNOPSIS
        The scriptblock at $Context.Adapters.<Group>.<Name>, or $null when the adapter has no such member.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Name)
    $adapters = Get-AzlVerContextValue $Context 'Adapters'
    if ($null -eq $adapters) { return $null }
    $g = Get-AzlProp $adapters $Group $null
    if ($null -eq $g) { return $null }
    $m = Get-AzlProp $g $Name $null
    if ($m -is [scriptblock]) { return $m }
    return $null
}

function Stop-AzlVerSkip {
    <#
    .SYNOPSIS
        Ends the check as Skipped, with the reason (a skipped check is never read as fine).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws a control-flow exception; changes no system state.')]
    param([Parameter(Mandatory)][string]$Reason, [string]$Remedy = '')
    $e = [System.InvalidOperationException]::new($Reason)
    $e.Data['AzlSkip'] = $true
    $e.Data['AzlRemedy'] = $Remedy
    throw $e
}

function Invoke-AzlVerNodeAdapter {
    <#
    .SYNOPSIS
        Calls Adapters.<Group>.<Name>(node, Context). Throws a skip when the adapter has no such member.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Node)
    $m = Get-AzlVerAdapterMember -Context $Context -Group $Group -Name $Name
    if (-not $m) { Stop-AzlVerSkip "The adapter has no $Group.$Name here (nodes are not reachable from this host)." 'Run the verification from the host that reaches the nodes over WinRM.' }
    return (& $m $Node $Context)
}

function Get-AzlVerNodeData {
    <#
    .SYNOPSIS
        What one section of one node says, read once per run. Ok, Error and Data. A node that cannot be read gives Ok = $false and the
        reason; the caller reports that node as Skipped.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][string]$Section)
    $cache = Get-AzlVerCache $Context
    $key = "$Section|$Node"
    if ($cache.ContainsKey($key)) { return $cache[$key] }
    $r = [pscustomobject]@{ Node = $Node; Section = $Section; Ok = $false; Error = ''; Data = $null }
    try {
        $r.Data = Invoke-AzlVerNodeAdapter -Context $Context -Group 'Node' -Name $Section -Node $Node
        if ($null -eq $r.Data) { throw "The node answered nothing for $Section." }
        $r.Ok = $true
    }
    catch {
        $r.Error = $_.Exception.Message
        if ($_.Exception.Data['AzlSkip']) { $r | Add-Member -NotePropertyName NoAdapter -NotePropertyValue $true }
    }
    $cache[$key] = $r
    return $r
}

function Get-AzlVerCache {
    param([Parameter(Mandatory)]$Context)
    if ($Context -is [System.Collections.IDictionary]) {
        if (-not $Context.Contains('Cache') -or $null -eq $Context['Cache']) { $Context['Cache'] = @{} }
        return $Context['Cache']
    }
    if (-not $Context.PSObject.Properties['Cache']) { $Context | Add-Member -NotePropertyName Cache -NotePropertyValue @{} }
    return $Context.Cache
}

function Invoke-AzlVerPerNode {
    <#
    .SYNOPSIS
        Runs -Body for every node of the file whose -Section could be read, as { param($Name, $Data, $NodeInfo) }. A node that could not
        be read gets one Skipped result that says why (ND-001 holds the reason); a body that throws gets a Failed result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][scriptblock]$Body)
    $nodes = @(Get-AzlVerNodeList $Context)
    if (-not $nodes.Count) { New-AzlVerResult Skipped 'The file lists no nodes (nodes[].name).' 'Fill nodes[] in the infrastructure file.'; return }
    foreach ($n in $nodes) {
        $d = Get-AzlVerNodeData -Context $Context -Node $n.Name -Section $Section
        if (-not $d.Ok) {
            New-AzlVerResult Skipped "$($n.Name) could not be read ($Section), so this was not checked on it: $($d.Error)" 'Make the node reachable first (ND-001), then run the verification again.' -Node $n.Name
            continue
        }
        try { & $Body $n.Name $d.Data $n }
        catch {
            if ($_.Exception.Data['AzlSkip']) { New-AzlVerResult Skipped $_.Exception.Message ([string]$_.Exception.Data['AzlRemedy']) -Node $n.Name }
            else { New-AzlVerResult Failed "$($n.Name): the check could not run: $($_.Exception.Message)" 'Read the message, fix the cause and run the verification again.' -Node $n.Name }
        }
    }
}

function Invoke-AzlVerCheckBody {
    <#
    .SYNOPSIS
        Runs a check body that is not per node; a Stop-AzlVerSkip inside it becomes one Skipped result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Body)
    try { & $Body }
    catch {
        if ($_.Exception.Data['AzlSkip']) { New-AzlVerResult Skipped $_.Exception.Message ([string]$_.Exception.Data['AzlRemedy']) }
        else { New-AzlVerResult Failed "The check could not run: $($_.Exception.Message)" 'Read the message, fix the cause and run the verification again.' }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The payload that runs on a node (Windows PowerShell 5.1 syntax; a node ships no pwsh). READ ONLY.
# ---------------------------------------------------------------------------------------------------------------------

$script:SnapshotBody = @'
# Pre-cluster verification read of one node. Changes nothing.
$ErrorActionPreference = 'Continue'
$P = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PARAMS__')))
function Get-P($o, [string]$n, $d = $null) { if ($null -eq $o) { return $d }; $p = $o.PSObject.Properties[$n]; if ($p -and $null -ne $p.Value) { return $p.Value }; return $d }
$Az = @{ err = @{} }
function Invoke-Section([string]$name, [scriptblock]$sb) { try { & $sb } catch { $Az.err[$name] = $_.Exception.Message } }
Invoke-Section 'base' {
    $Az.host = $env:COMPUTERNAME
    $Az.utc = (Get-Date).ToUniversalTime().ToString('o')
}
Invoke-Section 'os' {
    $os = Get-CimInstance Win32_OperatingSystem
    $ubr = ''
    try { $ubr = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR } catch { $ubr = '' }
    $Az.os = @{ caption = [string]$os.Caption; version = [string]$os.Version; ubr = $ubr; build = ('{0}.{1}' -f $os.Version, $ubr) }
}
Invoke-Section 'cs' {
    $c = Get-CimInstance Win32_ComputerSystem
    $Az.cs = @{ partOfDomain = [bool]$c.PartOfDomain; domain = [string]$c.Domain; memBytes = [int64]$c.TotalPhysicalMemory; manufacturer = [string]$c.Manufacturer; model = [string]$c.Model; hypervisor = [bool]$c.HypervisorPresent }
}
Invoke-Section 'cpu' {
    $Az.cpu = @(Get-CimInstance Win32_Processor | ForEach-Object {
            @{ caption = [string]$_.Caption; family = [int]$_.Family; manufacturer = [string]$_.Manufacturer; maxClock = [int]$_.MaxClockSpeed; cores = [int]$_.NumberOfEnabledCore; logical = [int]$_.NumberOfLogicalProcessors
                threads = [int]$_.ThreadCount; vt = [bool]$_.VirtualizationFirmwareEnabled; slat = [bool]$_.SecondLevelAddressTranslationExtensions }
        })
}
Invoke-Section 'mem' { $Az.mem = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object { [int64]$_.Capacity }) }
Invoke-Section 'fw' {
    $b = Get-CimInstance Win32_BIOS
    $sb = $null; try { $sb = [bool](Confirm-SecureBootUEFI) } catch { $sb = $null }
    $tpm = $null; try { $tpm = Get-Tpm } catch { $tpm = $null }
    $spec = ''; try { $spec = [string](Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm).SpecVersion } catch { $spec = '' }
    $present = $null; $ready = $null
    if ($tpm) { $present = [bool]$tpm.TpmPresent; $ready = [bool]$tpm.TpmReady }
    $Az.fw = @{ biosVersion = [string]$b.SMBIOSBIOSVersion; secureBoot = $sb; tpmPresent = $present; tpmReady = $ready; tpmSpec = $spec }
}
Invoke-Section 'features' {
    $all = @{}
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) { foreach ($f in @(Get-WindowsFeature)) { $all[[string]$f.Name] = [bool]$f.Installed } }
    $Az.features = @(foreach ($w in @(Get-P $P 'features' @())) {
            $found = $all.ContainsKey([string]$w)
            $inst = $null
            if ($found) { $inst = $all[[string]$w] }
            @{ n = [string]$w; found = $found; installed = $inst }
        })
}
Invoke-Section 'reboot' {
    $r = @{ cbs = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'); wu = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'); files = $false; rename = $false }
    try { $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop; $r.files = [bool]$v.PendingFileRenameOperations } catch { $null = $_ }
    try {
        $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
        $n = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
        $r.rename = ($a -ne $n)
    } catch { $null = $_ }
    $Az.reboot = $r
}
Invoke-Section 'time' {
    $src = (& w32tm.exe /query /source 2>$null | Select-Object -First 1)
    $w = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $Az.time = @{ src = [string]$src; type = [string](Get-P $w 'Type' ''); peers = [string](Get-P $w 'NtpServer' '') }
}
Invoke-Section 'dns' {
    $Az.dns = @(Get-DnsClient -ErrorAction SilentlyContinue | ForEach-Object {
            $row = $_
            $sv = @(Get-DnsClientServerAddress -InterfaceIndex $row.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
            @{ n = [string]$row.InterfaceAlias; idx = [int]$row.InterfaceIndex; servers = @($sv | ForEach-Object { [string]$_ }) }
        })
}
Invoke-Section 'disks' {
    $lun = @{}
    foreach ($w in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) { $lun[[int]$w.Index] = @{ lun = [int]$w.SCSILogicalUnit; port = [int]$w.SCSIPort; target = [int]$w.SCSITargetId } }
    $disks = @(Get-Disk -ErrorAction SilentlyContinue)
    $byNum = @{}
    foreach ($d in $disks) { $byNum[[int]$d.Number] = $d }
    $Az.disks = @($disks | ForEach-Object {
            $l = $lun[[int]$_.Number]
            $lu = $null; $po = $null; $ta = $null
            if ($l) { $lu = $l.lun; $po = $l.port; $ta = $l.target }
            @{ num = [int]$_.Number; name = [string]$_.FriendlyName; model = [string]$_.Model; serial = ([string]$_.SerialNumber).Trim(); uid = ([string]$_.UniqueId).Trim(); uidFormat = [string]$_.UniqueIdFormat; bus = [string]$_.BusType
                size = [int64]$_.Size; style = [string]$_.PartitionStyle; parts = [int]$_.NumberOfPartitions; offline = [bool]$_.IsOffline; boot = [bool]$_.IsBoot; system = [bool]$_.IsSystem; lun = $lu; port = $po; target = $ta }
        })
    $Az.physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            $num = $null
            if ([string]$_.DeviceId -match '^\d+$') { $num = [int]$_.DeviceId }
            $d = $null
            if ($null -ne $num -and $byNum.ContainsKey($num)) { $d = $byNum[$num] }
            $boot = $false; $system = $false; $style = ''; $parts = 0
            if ($d) { $boot = [bool]$d.IsBoot; $system = [bool]$d.IsSystem; $style = [string]$d.PartitionStyle; $parts = [int]$d.NumberOfPartitions }
            @{ num = $num; name = [string]$_.FriendlyName; serial = ([string]$_.SerialNumber).Trim(); size = [int64]$_.Size; bus = [string]$_.BusType; media = [string]$_.MediaType; canPool = [bool]$_.CanPool
                reason = (@($_.CannotPoolReason) -join ','); health = [string]$_.HealthStatus; boot = $boot; system = $system; style = $style; parts = $parts }
        })
}
Invoke-Section 'pools' {
    $Az.pools = @(Get-StoragePool -ErrorAction SilentlyContinue | Where-Object { -not $_.IsPrimordial } | ForEach-Object { [string]$_.FriendlyName })
    $Az.vdisks = @(Get-VirtualDisk -ErrorAction SilentlyContinue).Count
}
Invoke-Section 'cluster' {
    $svc = Get-Service ClusSvc -ErrorAction SilentlyContinue
    $name = ''; $status = ''
    if ($svc) { $status = [string]$svc.Status }
    if ($svc -and $svc.Status -eq 'Running') { try { $name = [string](Get-Cluster -ErrorAction Stop).Name } catch { $name = '' } }
    $Az.cluster = @{ svc = $status; name = $name }
}
Invoke-Section 'nics' {
    $Az.nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
            $a = $_
            $jumbo = $null
            $jp = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue
            if ($jp) { $jumbo = [string]@($jp.RegistryValue)[0] }
            $nd = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*NetworkDirect' -ErrorAction SilentlyContinue
            $rdma = Get-NetAdapterRdma -Name $a.Name -ErrorAction SilentlyContinue
            $op = $null; $en = $false
            if ($rdma) { $en = [bool]$rdma.Enabled; if ($rdma.PSObject.Properties['Operational']) { $op = [bool]$rdma.Operational } }
            $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | ForEach-Object { [string]$_.IPAddress })
            $gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop })
            $dhcp = ''
            $ifc = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ifc) { $dhcp = [string]$ifc.Dhcp }
            @{ n = [string]$a.Name; desc = [string]$a.InterfaceDescription; st = [string]$a.Status; admin = [string]$a.AdminStatus; speed = [int64]$a.Speed; mac = ([string]$a.MacAddress -replace '[-:]', '').ToLowerInvariant(); drvProv = [string]$a.DriverProvider
                drvVer = [string]$a.DriverVersion; idx = [int]$a.ifIndex; mtu = [int]$a.MtuSize; jumbo = $jumbo; rdmaCapable = [bool]($nd -or $rdma); rdmaEnabled = $en; rdmaOp = $op; ips = $ips; gw = $gw; dhcp = $dhcp }
        })
    # Every adapter, physical or not, whose description says Remote NDIS (the BMC's USB NIC arrives as one).
    $Az.remoteNdis = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceDescription -match 'Remote NDIS' } | ForEach-Object { @{ n = [string]$_.Name; desc = [string]$_.InterfaceDescription; st = [string]$_.Status; admin = [string]$_.AdminStatus } })
}
Invoke-Section 'clussvc' {
    $found = @{}
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\ClusSvc\Parameters'
    if (Test-Path $k) {
        $it = Get-ItemProperty $k
        foreach ($p in $it.PSObject.Properties) { if ($p.Name -like 'Exclude*') { $found[$p.Name] = (@($p.Value) -join ';') } }
    }
    $Az.clusSvc = $found
}
Invoke-Section 'proxy' {
    $w = (& netsh.exe winhttp show proxy 2>$null | Out-String).Trim()
    $ie = ''
    try { $s = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; if ($s.ProxyEnable -eq 1) { $ie = [string]$s.ProxyServer } } catch { $ie = '' }
    $Az.proxy = @{ winhttp = $w; wininet = $ie; envHttps = [string]$env:HTTPS_PROXY; envHttp = [string]$env:HTTP_PROXY; envNo = [string]$env:NO_PROXY }
}
Invoke-Section 'vms' {
    $sw = @()
    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) { $sw = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object { @{ n = [string]$_.Name; uplinks = @($_.NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ }) } }) }
    $in = @()
    if (Get-Command Get-NetIntent -ErrorAction SilentlyContinue) { try { $in = @(Get-NetIntent -ErrorAction Stop | ForEach-Object { [string]$_.IntentName }) } catch { $in = @() } }
    $Az.vms = @{ switches = $sw; intents = $in }
}
Invoke-Section 'mpio' {
    $feature = ''
    $f = Get-WindowsOptionalFeature -Online -FeatureName MultipathIO -ErrorAction SilentlyContinue
    if ($f) { $feature = [string]$f.State }
    elseif (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) { $g = Get-WindowsFeature Multipath-IO; if ($g) { $feature = $(if ($g.Installed) { 'Enabled' } else { 'Disabled' }) } }
    $avail = @(); $supp = @(); $claims = @(); $lb = ''
    if (Get-Command Get-MPIOAvailableHW -ErrorAction SilentlyContinue) {
        $avail = @(Get-MPIOAvailableHW -ErrorAction SilentlyContinue | ForEach-Object { @{ vendor = ([string]$_.VendorId).Trim(); product = ([string]$_.ProductId).Trim(); bus = [string]$_.BusType; multipathed = [bool]$_.IsMultipathed; spc3 = [bool]$_.IsSPC3Supported } })
        $supp = @(Get-MSDSMSupportedHW -ErrorAction SilentlyContinue | ForEach-Object { @{ vendor = ([string]$_.VendorId).Trim(); product = ([string]$_.ProductId).Trim() } })
        try { $lb = [string](Get-MSDSMGlobalDefaultLoadBalancePolicy) } catch { $lb = '' }
    }
    $raw = @()
    if (Get-Command mpclaim.exe -ErrorAction SilentlyContinue) { $raw = @(& mpclaim.exe -s -d 2>$null | ForEach-Object { [string]$_ }) }
    foreach ($line in $raw) {
        if ($line -match '^\s*MPIO Disk\s*(\d+)\s+(?:Disk\s*)?(\d+)?\s*(\S+)?\s+(.*?)\s*$') { $claims += @{ mpio = [int]$Matches[1]; disk = $Matches[2]; policy = $Matches[3]; dsm = $Matches[4] } }
    }
    # What MPIO itself will claim: HKLM\SYSTEM\CurrentControlSet\Control\MPDEV\MPIOSupportedDeviceList, each entry the vendor padded to 8 and the product padded to 16 (what mpclaim -n -i -d writes).
    $mpdev = @(); $mpdevRead = $false
    $mpdevKey = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MPDEV' -ErrorAction SilentlyContinue
    if ($mpdevKey) {
        $mpdevRead = $true
        if ($mpdevKey.PSObject.Properties['MPIOSupportedDeviceList']) { $mpdev = @($mpdevKey.MPIOSupportedDeviceList | ForEach-Object { $e = [string]$_; if ($e.Length -gt 8) { @{ vendor = $e.Substring(0, 8).Trim(); product = $e.Substring(8).Trim() } } else { @{ vendor = $e.Trim(); product = '' } } }) }
    }
    $Az.mpio = @{ feature = $feature; availableHw = $avail; supportedHw = $supp; claims = $claims; lb = $lb; mpclaimLines = $raw.Count; mpdev = $mpdev; mpdevRead = $mpdevRead }
}
Invoke-Section 'fc' {
    $Az.fc = @(Get-InitiatorPort -ErrorAction SilentlyContinue | Where-Object { [string]$_.ConnectionType -match 'Fibre' } | ForEach-Object { @{ wwpn = [string]$_.PortAddress; wwnn = [string]$_.NodeAddress } })
    $s = Get-Service MSiSCSI -ErrorAction SilentlyContinue
    if ($s) { $Az.iscsi = @{ status = [string]$s.Status; start = [string]$s.StartType } }
}
Invoke-Section 'ec' {
    $Az.ec = @(Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker -ErrorAction SilentlyContinue | ForEach-Object { @{ name = [string]$_.Name; version = [string]$_.Version } })
}
function Test-Tcp([string]$Address, [int]$Port, [int]$Milliseconds) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Milliseconds, $false)) { return $false }
        $client.EndConnect($ar)
        return [bool]$client.Connected
    } catch { return $false } finally { $client.Close() }
}
Invoke-Section 'tcp' { $Az.tcp = @(foreach ($t in @(Get-P $P 'tcp' @())) { @{ h = [string]$t.h; p = [int]$t.p; ok = (Test-Tcp ([string]$t.h) ([int]$t.p) 3000) } }) }
Invoke-Section 'https' {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
    $proxy = [string](Get-P $P 'proxy' '')
    $Az.https = @(foreach ($u in @(Get-P $P 'https' @())) {
            $ok = $false; $status = ''; $err = ''
            try {
                $a = @{ Uri = [string]$u; UseBasicParsing = $true; TimeoutSec = 6; ErrorAction = 'Stop' }
                if ($proxy) { $a.Proxy = $proxy }
                $r = Invoke-WebRequest @a
                $ok = $true; $status = [string][int]$r.StatusCode
            } catch {
                $resp = $null; try { $resp = $_.Exception.Response } catch { $resp = $null }
                if ($resp) { $ok = $true; $status = [string][int]$resp.StatusCode } else { $err = $_.Exception.Message }
            }
            @{ u = [string]$u; ok = $ok; status = $status; err = $err }
        })
}
Invoke-Section 'ping' { $Az.ping = @(foreach ($a in @(Get-P $P 'ping' @())) { @{ a = [string]$a; ok = [bool](Test-Connection -ComputerName ([string]$a) -Count 2 -Quiet -ErrorAction SilentlyContinue) } }) }
$Az | ConvertTo-Json -Depth 8 -Compress
'@

function Get-AzlVerSnapshotScript {
    <#
    .SYNOPSIS
        The script block that collects everything about a node in one remote call (read only). -Parameter is baked into the script text
        (features, probes, proxy); it holds no secret.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([hashtable]$Parameter = @{})
    $json = ($Parameter | ConvertTo-Json -Depth 6 -Compress)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    return [scriptblock]::Create($script:SnapshotBody.Replace('__PARAMS__', $b64))
}

function Get-AzlVerProbeParameter {
    <#
    .SYNOPSIS
        What the node payload probes, from the file: the Windows features, TCP 53 to the DNS servers, the default gateway (ping) and the
        outbound endpoints on 443. Never a secret.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $infra = Get-AzlVerInfra $Context
    $dns = @(ConvertTo-AzlVerList (Get-AzlProp $infra 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
    $gateway = [string](Get-AzlProp $infra 'networking.management.gateway' '')
    $proxy = [string](Get-AzlProp $infra 'networking.outbound.proxy.url' '')
    [ordered]@{
        features = @($script:RequiredFeature + $script:AdvisedFeature + 'Multipath-IO')
        tcp      = @(@($dns | ForEach-Object { @{ h = $_; p = 53 } }) + @(Get-AzlVerEndpointList $Context | Where-Object { $_.Port -ne 443 } | ForEach-Object { @{ h = $_.Host; p = $_.Port } }))
        ping     = @($(if ($gateway) { $gateway }))
        https    = @(Get-AzlVerEndpointList $Context | Where-Object { $_.Port -eq 443 } | ForEach-Object { "https://$($_.Host)" })
        proxy    = $proxy
    }
}

function Get-AzlVerEndpointList {
    <#
    .SYNOPSIS
        The concrete outbound hosts a node is probed for: the one documented list (AzlVerification.Endpoints.psm1, from Learn's firewall requirements and the Arc agent
        network requirements) with the region of the file. Host, Port, Group, Tier. Only for the Azure public cloud, the lists of Learn are for it; empty otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $infra = Get-AzlVerInfra $Context
    $cloud = [string](Get-AzlProp $infra 'scenario.cloud' 'public')
    if ($cloud -ne 'public') { return @() }
    @(Get-AzlEndpointSet -Location ([string](Get-AzlProp $infra 'azure.location' '')))
}
# ---------------------------------------------------------------------------------------------------------------------
# Default adapter members (real, read only)
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlVerRemoteDefault {
    <#
    .SYNOPSIS
        The default Remote.Invoke(node, scriptblock [, argumentList]): the script block runs on the node over WinRM in Windows PowerShell
        5.1 (the node's Microsoft.PowerShell endpoint) and its output comes back. Read only by construction of the callers.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory scriptblock or table; changes no system state.')]
    [CmdletBinding()]
    param([pscredential]$Credential, [hashtable]$Address = @{}, [switch]$UseSsl, [string]$Authentication = 'Default')
    $cred = $Credential; $map = $Address; $ssl = [bool]$UseSsl; $auth = $Authentication
    return {
        param($Node, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
        $target = $Node
        if ($map -and $map.ContainsKey($Node)) { $target = [string]$map[$Node] }
        $p = @{ ComputerName = $target; ScriptBlock = $ScriptBlock; ArgumentList = $ArgumentList; ConfigurationName = 'Microsoft.PowerShell'; ErrorAction = 'Stop' }
        if ($cred) { $p.Credential = $cred }
        if ($ssl) { $p.UseSSL = $true }
        if ($auth -and $auth -ne 'Default') { $p.Authentication = $auth }
        Invoke-Command @p
    }.GetNewClosure()
}

function ConvertFrom-AzlVerSnapshot {
    <#
    .SYNOPSIS
        The snapshot a node returned (a JSON text, or already an object) as an object. Throws when it is not one.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Raw)
    $text = $Raw
    if ($Raw -is [System.Collections.IEnumerable] -and $Raw -isnot [string] -and $Raw -isnot [System.Collections.IDictionary]) { $text = (@($Raw) | Where-Object { $_ -is [string] }) -join '' }
    if ($text -is [string]) {
        if (-not $text.Trim()) { throw 'The node returned an empty answer.' }
        return ($text | ConvertFrom-Json -Depth 10)
    }
    if ($null -eq $text) { throw 'The node returned nothing.' }
    return $text
}

function Get-AzlVerNodeSection {
    <#
    .SYNOPSIS
        One section of a node's snapshot (the properties each Node.Get* member returns), read through Node.GetSnapshot.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $map = @{
        GetOsBuild = @('host', 'utc', 'os', 'cs'); GetHardware = @('host', 'cs', 'cpu', 'mem', 'fw', 'physical'); GetTime = @('utc', 'time'); GetDns = @('dns', 'nics')
        GetFeatures = @('features'); GetReboot = @('reboot'); GetDisks = @('physical', 'disks', 'pools', 'vdisks', 'cluster')
        GetAdapters = @('nics', 'dns', 'remoteNdis', 'clusSvc', 'proxy', 'vms'); GetMpio = @('mpio', 'disks', 'fc', 'iscsi'); GetProbes = @('tcp', 'https', 'ping', 'proxy'); GetEnvChecker = @('ec')
    }
    $snapshot = Get-AzlVerAdapterMember -Context $Context -Group 'Node' -Name 'GetSnapshot'
    if (-not $snapshot) { Stop-AzlVerSkip 'The adapter has no Node.GetSnapshot here (nodes are not reachable from this host).' 'Run the verification from the host that reaches the nodes over WinRM.' }
    $snap = & $snapshot $Node $Context
    # The node script records a section that threw in err.<section> and leaves the value at its default (no features, no pending restart, no pool). A check
    # that reads such a section would pass on nothing, so a section whose read failed is not handed out: the caller reports the node Skipped with the reason.
    $needs = @{
        GetOsBuild = @('base', 'os', 'cs'); GetHardware = @('base', 'cs', 'cpu', 'mem', 'fw', 'disks'); GetTime = @('base', 'time'); GetDns = @('dns', 'nics')
        GetFeatures = @('features'); GetReboot = @('reboot'); GetDisks = @('disks', 'pools', 'cluster'); GetAdapters = @('nics', 'dns', 'clussvc', 'proxy', 'vms')
        GetMpio = @('mpio', 'disks', 'fc'); GetProbes = @('tcp', 'https', 'ping', 'proxy'); GetEnvChecker = @('ec')
    }
    $err = Get-AzlProp $snap 'err' $null
    $errNames = @(); if ($err -is [System.Collections.IDictionary]) { $errNames = @($err.Keys) } elseif ($err) { $errNames = @($err.PSObject.Properties | ForEach-Object { $_.Name }) }
    $broken = @($needs[$Name] | Where-Object { $_ -and ($_ -in $errNames) })
    if ($broken.Count) {
        $why = @($broken | ForEach-Object { $e = if ($err -is [System.Collections.IDictionary]) { $err[$_] } else { $err.$_ }; "$_ ($e)" })
        throw "The read of $($broken -join ', ') failed on the node: $($why -join '; ')"
    }
    $o = [ordered]@{}
    foreach ($p in $map[$Name]) { $o[$p] = Get-AzlProp $snap $p $null }
    $o['err'] = $err
    [pscustomobject]$o
}
function New-AzlVerNodeAdapterDefault {
    <#
    .SYNOPSIS
        The default Node.* members: GetSnapshot reads the node once (Remote.Invoke of the payload) and caches it; every other member
        returns its section of the snapshot.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory scriptblock or table; changes no system state.')]
    [CmdletBinding()]
    param()
    $node = @{}
    $node['GetSnapshot'] = {
        param($Node, $Context)
        # One remote call per node and run: the answer, or the failure, is kept in the Context.
        $cache = Get-AzlVerCache $Context
        $key = "snapshot|$Node"
        if ($cache.ContainsKey($key)) {
            if ($cache[$key] -is [System.Management.Automation.ErrorRecord]) { throw $cache[$key].Exception }
            return $cache[$key]
        }
        try {
            $remote = Get-AzlVerAdapterMember -Context $Context -Group 'Remote' -Name 'Invoke'
            if (-not $remote) { Stop-AzlVerSkip 'The adapter has no Remote.Invoke here (nodes are not reachable from this host).' 'Run the verification from the host that reaches the nodes over WinRM.' }
            $payload = Get-AzlVerSnapshotScript -Parameter (Get-AzlVerProbeParameter $Context)
            $snap = ConvertFrom-AzlVerSnapshot (& $remote $Node $payload)
        }
        catch { $cache[$key] = $_; throw }
        $cache[$key] = $snap
        return $snap
    }
    $node['GetOsBuild'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetOsBuild' }
    $node['GetHardware'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetHardware' }
    $node['GetTime'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetTime' }
    $node['GetDns'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetDns' }
    $node['GetFeatures'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetFeatures' }
    $node['GetReboot'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetReboot' }
    $node['GetDisks'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetDisks' }
    $node['GetAdapters'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetAdapters' }
    $node['GetMpio'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetMpio' }
    $node['GetProbes'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetProbes' }
    $node['GetEnvChecker'] = { param($Node, $Context) Get-AzlVerNodeSection -Node $Node -Context $Context -Name 'GetEnvChecker' }
    return $node
}

function Get-AzlVerConstant {
    <#
    .SYNOPSIS
        A constant the category modules share: Source (the Learn and docs URLs by key), RequiredFeature, AdvisedFeature, PublicDns.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Source', 'RequiredFeature', 'AdvisedFeature', 'PublicDns')][string]$Name)
    switch ($Name) {
        'Source' { return $script:Src }
        'RequiredFeature' { return $script:RequiredFeature }
        'AdvisedFeature' { return $script:AdvisedFeature }
        'PublicDns' { return $script:PublicDns }
    }
}

function Get-AzlVerAllNodeData {
    <#
    .SYNOPSIS
        One section of every node: Data (ordered, node name -> data, only the nodes that could be read) and Unread (name -> reason).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Section)
    $data = [ordered]@{}; $unread = [ordered]@{}
    foreach ($n in (Get-AzlVerNodeList $Context)) {
        $d = Get-AzlVerNodeData -Context $Context -Node $n.Name -Section $Section
        if ($d.Ok) { $data[$n.Name] = $d.Data } else { $unread[$n.Name] = $d.Error }
    }
    [pscustomobject]@{ Data = $data; Unread = $unread }
}

function Get-AzlVerNow {
    <#
    .SYNOPSIS
        The current UTC time of this host: Adapters.Now when the adapter has one (tests), else the clock.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)]$Context)
    $now = Get-AzlProp (Get-AzlVerContextValue $Context 'Adapters') 'Now' $null
    if ($now -is [scriptblock]) { return ([datetime](& $now)).ToUniversalTime() }
    return [datetime]::UtcNow
}

Export-ModuleMember -Function Invoke-AzlVerRegisteredRun, Get-AzlVerNodeSection, Get-AzlVerConstant, Get-AzlVerAllNodeData, Get-AzlVerNow, ConvertTo-AzlVerList, Join-AzlVerList, New-AzlVerResult, New-AzlVerDefinition, Get-AzlVerSetting, Get-AzlVerContextValue, Get-AzlVerInfra, Get-AzlVerArchitecture, Test-AzlVerSanDeclared, Get-AzlVerNodeList, Get-AzlVerIntent, Test-AzlVerNetworkDirect, Get-AzlVerTargetSolution, ConvertFrom-AzlVerOsBuild, Get-AzlVerSanVendor, Format-AzlVerMsdsmId, Get-AzlVerAdapterMember, Stop-AzlVerSkip, Invoke-AzlVerNodeAdapter, Get-AzlVerNodeData, Get-AzlVerCache, Invoke-AzlVerPerNode, Invoke-AzlVerCheckBody, Get-AzlVerSnapshotScript, Get-AzlVerProbeParameter, Get-AzlVerEndpointList, New-AzlVerRemoteDefault, ConvertFrom-AzlVerSnapshot, New-AzlVerNodeAdapterDefault
