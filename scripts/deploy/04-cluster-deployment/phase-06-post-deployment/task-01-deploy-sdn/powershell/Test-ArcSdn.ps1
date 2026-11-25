<#
.SYNOPSIS
    Checks that SDN enabled by Azure Arc is on and healthy: the Network Controller cluster group and its resources are Online and the REST name resolves to the reserved address. Read only.

.DESCRIPTION
    Phase 06 (post-deployment), Task 01 (SDN), the validation table of the guide page. Run it after Enable-ArcSdn.ps1 (and before the network security
    group and logical network tasks). It connects to a machine of the instance with PowerShell remoting and changes nothing.

    The checks, from the guide page and Microsoft Learn (Enable SDN integration on Azure Local using PowerShell, view azloc-2611):
      1. OS build: 26100 or later (systeminfo shows 10.0.26100).
      2. Network Controller cluster group: it exists and its state is Online (Get-ClusterGroup, name matching Network Controller). The owner node is reported.
      3. Network Controller cluster resources: every resource of that group is Online (Get-ClusterGroup | Get-ClusterResource).
      4. DNS: <prefix>-NC.<domain> resolves, on the machine, to the fifth address of networking.management.infrastructure_pool, the reserved address
         that Learn names for the record (Resolve-DnsName).
    Not checked here, because it is a view of the Azure portal and not a command: Azure Local instance, Networking, Network Controller listed. Learn's
    outcome of the action plan is shown by Enable-ArcSdn.ps1 and kept in its -LogPath. The network security group scripts verify the Azure side
    (az stack-hci-vm network nsg).

    Exit codes: 0 every check passed (warnings and information allowed) or the checks were listed under -WhatIf; 1 a check failed or no machine answered;
    2 a value in the file is missing or not usable, or a secret reference is not usable (nothing was checked; 1 when the secret cannot be read). With sdn.enabled false or missing it reports that
    SDN is not planned and exits 0.

    The login is -Credential, else the deployment (LCM) user of the file with Active Directory identity, else identity.local_admin (see
    scripts/common/sdn/AzlSdn.psm1, Resolve-AzlSdnLogin). The password is a secret reference. The script never prompts.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        sdn.enabled, sdn.prefix (optional; cluster.name when it is not set: see Resolve-AzlSdnPrefix in scripts/common/sdn/AzlSdn.psm1, the same prefix as Enable-ArcSdn.ps1)
        networking.management.infrastructure_pool.start, end
        scenario.identity, identity.active_directory.domain_fqdn, identity.local_identity.dns_zone, nodes[].name, nodes[].management.ip_address
        identity.active_directory.netbios_name, identity.active_directory.lcm_user (username, password), identity.local_admin (username, password)

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read.

.PARAMETER ComputerName
    Optional. The machine to ask (a node name of the file or an address), instead of the first node of nodes[] that answers.

.PARAMETER Credential
    Optional. The account for the remoting session. Without it the account of the file is used (see above).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Test-ArcSdn.ps1 -InfrastructureFile ./infrastructure.yml

    Checks the Network Controller group, its resources and its DNS name.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$ComputerName,
    [pscredential]$Credential,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'sdn', 'AzlSdn.psm1'))) -Force

# Microsoft Learn: SDN enabled by Arc needs OS build 26100 or later; the Network Controller record is the fifth address of the infrastructure range;
# the record of the feature is named <prefix>-NC.
$MinimumBuild = 26100
$RecordOffset = 4
$FeatureName = 'NC'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Test-Ipv4([string]$Value) {
    $address = $null
    $Value -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($Value, [ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
}
function ConvertTo-Number([string]$Address) {
    $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    [long][BitConverter]::ToUInt32($bytes, 0)
}
function ConvertFrom-Number([long]$Number) {
    $bytes = [BitConverter]::GetBytes([uint32]$Number)
    [Array]::Reverse($bytes)
    [Net.IPAddress]::new($bytes).ToString()
}

# The commands that run on the machine. Each takes the step name first, so one remoting call shape serves both.
$Remote = @{
    Probe     = { param($Step) [string]$env:COMPUTERNAME }
    ReadState = {
        param($Step, $Fqdn)
        $groups = @(Get-ClusterGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Network Controller' } | ForEach-Object {
                $resources = @(Get-ClusterGroup -Name $_.Name -ErrorAction SilentlyContinue | Get-ClusterResource -ErrorAction SilentlyContinue | ForEach-Object {
                        @{ Name = [string]$_.Name; Type = [string]$_.ResourceType; State = [string]$_.State }
                    })
                @{ Name = [string]$_.Name; State = [string]$_.State; Owner = [string]$_.OwnerNode; Resources = $resources }
            })
        $addresses = @()
        if ($Fqdn) { $addresses = @(Resolve-DnsName -Name $Fqdn -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress }) }
        @{
            Computer     = [string]$env:COMPUTERNAME
            OsBuild      = [int][Environment]::OSVersion.Version.Build
            Groups       = $groups
            AllGroups    = @(Get-ClusterGroup -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
            DnsAddresses = $addresses
        }
    }
}
function Invoke-Node([string]$Computer, [string]$Step, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $Computer; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop' }
    if ($script:remoteCredential) { $call.Credential = $script:remoteCredential }
    Invoke-Command @call
}

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Check, [string]$Result, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Check = $Check; Result = $Result; Detail = $Detail })
    Write-Line ("[{0,-4}] {1}{2}" -f $Result.ToLowerInvariant(), $Check, $(if ($Detail) { ": $Detail" } else { '' }))
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$enabledRaw = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.enabled'
if ($null -eq $enabledRaw -or $enabledRaw -eq $false) {
    Write-Line 'sdn.enabled is not true: SDN enabled by Azure Arc is not planned, so there is nothing to check.'
    exit 0
}
if ($enabledRaw -isnot [bool]) { Exit-InputProblem "sdn.enabled must be true or false; found '$enabledRaw'." }
$prefixResult = Resolve-AzlSdnPrefix -Infrastructure $infra   # sdn.prefix, or derived from cluster.name when it is not set
if ($prefixResult.Problem) { Exit-InputProblem $prefixResult.Problem }
$prefix = $prefixResult.Prefix
Write-Line "$($prefixResult.Label): $prefix"
$poolStart = Get-Text 'networking.management.infrastructure_pool.start'
$poolEnd = Get-Text 'networking.management.infrastructure_pool.end'
if (-not (Test-Ipv4 $poolStart) -or -not (Test-Ipv4 $poolEnd)) { Exit-InputProblem 'networking.management.infrastructure_pool.start and end are missing or not IPv4 addresses. The Network Controller record points at the fifth address of this range.' }
$recordNumber = (ConvertTo-Number $poolStart) + $RecordOffset
if ($recordNumber -gt (ConvertTo-Number $poolEnd)) { Exit-InputProblem 'networking.management.infrastructure_pool holds fewer than five addresses, so it has no fifth address for the Network Controller record.' }
$reservedAddress = ConvertFrom-Number $recordNumber
$identityKind = (Get-Text 'scenario.identity').ToLowerInvariant()
$domain = if ($identityKind -eq 'local_identity') { Get-Text 'identity.local_identity.dns_zone' } else { Get-Text 'identity.active_directory.domain_fqdn' }
$fqdn = if ($domain) { "$prefix-$FeatureName.$domain" } else { '' }
$nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
if ($nodes.Count -eq 0 -and -not $ComputerName) { Exit-InputProblem 'nodes[] is empty. The script asks a node of the instance (or give -ComputerName).' }

$checks = @('OS build', 'Network Controller cluster group', 'Network Controller cluster resources', 'DNS name of the Network Controller')
if ($WhatIfPreference) {
    foreach ($c in $checks) { Add-Check $c 'Plan' 'would be checked' }
    $rows
    exit 0
}

# ---- the login
$login = Resolve-AzlSdnLogin -Infrastructure $infra -Credential $Credential -FallbackToLocalAdministrator
if ($login.ProblemKind -eq 'Secret') { if ($login.ProblemExit -eq 2) { Exit-InputProblem $login.Problem } else { Write-Error $login.Problem -ErrorAction Continue; exit 1 } }
# With no account in the file the session is opened as the account that runs the script, as Enable-ArcSdn.ps1 does.
$remoteCredential = $login.Credential

# ---- the machine
$candidates = if ($ComputerName) {
    $match = @($nodes | Where-Object { $_.Name -ieq $ComputerName.Trim() } | Select-Object -First 1)
    @($(if ($match -and $match[0].ManagementIp) { $match[0].ManagementIp } else { $ComputerName.Trim() }))
}
else { @($nodes | ForEach-Object { if ($_.ManagementIp) { $_.ManagementIp } else { $_.Name } }) }
$target = ''; $firstError = ''
foreach ($candidate in $candidates) {
    try { $null = Invoke-Node $candidate 'Probe'; $target = $candidate; break }
    catch { if (-not $firstError) { $firstError = "${candidate}: $($_.Exception.Message)" } }
}
if (-not $target) { Add-Check 'Connection' 'Fail' "no node answered over PowerShell remoting ($firstError)"; $rows; exit 1 }
try { $state = Invoke-Node $target 'ReadState' @($fqdn) }
catch { Add-Check 'Connection' 'Fail' "'$target' could not be read: $($_.Exception.Message)"; $rows; exit 1 }
Write-Line "Asked '$target' ($($state.Computer)) as $(if ($remoteCredential) { $remoteCredential.UserName } else { 'the account that runs the script' })."

if ([int]$state.OsBuild -ge $MinimumBuild) { Add-Check 'OS build' 'Pass' "$($state.OsBuild)" } else { Add-Check 'OS build' 'Fail' "$($state.OsBuild); SDN enabled by Arc needs $MinimumBuild or later" }

$groups = @($state.Groups)
if ($groups.Count -eq 0) {
    Add-Check 'Network Controller cluster group' 'Fail' "no cluster group named like Network Controller (groups: $((@($state.AllGroups)) -join ', ')); SDN enabled by Arc is not on, or the group has another name"
    Add-Check 'Network Controller cluster resources' 'Fail' 'no Network Controller cluster group to read'
}
else {
    foreach ($g in $groups) {
        if ([string]$g.State -eq 'Online') { Add-Check "Network Controller cluster group '$($g.Name)'" 'Pass' "Online, owner $($g.Owner)" }
        else { Add-Check "Network Controller cluster group '$($g.Name)'" 'Fail' "state $($g.State), owner $($g.Owner); Learn: start it with Start-ClusterGroup after you check the cause" }
        $resources = @($g.Resources)
        if ($resources.Count -eq 0) { Add-Check "Network Controller cluster resources of '$($g.Name)'" 'Warn' 'the group has no cluster resource that could be read' }
        else {
            $notOnline = @($resources | Where-Object { [string]$_.State -ne 'Online' })
            if ($notOnline) { Add-Check "Network Controller cluster resources of '$($g.Name)'" 'Fail' "not Online: $(($notOnline | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', ')" }
            else { Add-Check "Network Controller cluster resources of '$($g.Name)'" 'Pass' "$($resources.Count) resource(s), all Online" }
        }
    }
}

if (-not $fqdn) { Add-Check 'DNS name of the Network Controller' 'Warn' 'the domain is not in the file, so the name was not checked' }
else {
    $resolved = @($state.DnsAddresses)
    if ($resolved.Count -eq 0) { Add-Check 'DNS name of the Network Controller' 'Fail' "$fqdn does not resolve on '$target'; it must point at $reservedAddress" }
    elseif (@($resolved | Where-Object { $_ -ne $reservedAddress })) { Add-Check 'DNS name of the Network Controller' 'Fail' "$fqdn resolves to $($resolved -join ', '); it must point at $reservedAddress (the fifth address of networking.management.infrastructure_pool)" }
    else { Add-Check 'DNS name of the Network Controller' 'Pass' "$fqdn points at $reservedAddress" }
}

$rows
if (@($rows | Where-Object Result -EQ 'Fail')) { exit 1 }
exit 0
