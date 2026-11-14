<#
.SYNOPSIS
    Turns on SDN enabled by Azure Arc (Network Controller as a Failover Cluster service) when sdn.enabled of infrastructure.yml is true. THIS CANNOT BE UNDONE.

.DESCRIPTION
    Phase 06 (post-deployment), Task 01 (SDN). Microsoft Learn (Enable SDN integration on Azure Local using PowerShell, view azloc-2610) enables SDN on
    an instance that is already deployed with one orchestrator action plan, run on a machine of the instance:

        Add-EceFeature -Name NC -SDNPrefix <prefix> -AcknowledgeMaintenanceWindow [-AcknowledgeDNSRecordCreation]

    The script connects to a machine of the instance with PowerShell remoting, checks what Learn lists as prerequisites, and runs that command.
    After SDN is enabled you create logical networks, network interfaces and network security groups from Azure (New-LogicalNetwork.ps1 and
    New-NetworkSecurityGroup.ps1 read sdn.enabled for that). Nothing else comes with SDN enabled by Arc: no virtual networks, no software load
    balancer, no gateways. The older SDN managed by on-premises tools (SDN Express, Windows Admin Center, Network Controller VMs) is not built here.

    WARNINGS. Read them before you set sdn.enabled to true.
      - It CANNOT BE UNDONE. Learn: once you enable SDN you cannot roll back or disable it. sdn.enabled false does not turn it off.
      - It interrupts the network of running workloads for a short time while the Virtual Filtering Platform policies are applied. Learn: plan a
        maintenance window on a production instance. Existing Azure Local VMs and logical networks are taken into the Network Controller.
      - The action plan takes up to 20 minutes.
      - Never run it where Network Controller was deployed with on-premises tools. The two ways must not be mixed. The script cannot see that
        case: it is your check.
      - Learn does not support these with SDN enabled by Arc: network security groups on the logical network or the VMs of AKS workloads,
        multicast, management with Windows Admin Center or SDN Express, and some intent layouts (below).

    What the script checks before it sends anything (exit 2, a value or the design in the file is not usable):
      - sdn.prefix: not empty, at most 8 characters, letters, digits and single hyphens, no hyphen at the start or the end.
      - sdn.dns_records is dynamic or static, and the management infrastructure pool is in the file (the Network Controller record points at its fifth address).
      - the layout of networking.intents and the storage connectivity are ones Learn supports with SDN enabled by Arc (see sdn-overview):
        at most three intents; no intent with compute and storage but without management; no intent of compute only on a single machine;
        no three intents on two or three machines with switchless storage; the single group-all intent only with switched storage; five machines
        or more only with switched storage; management and compute without a storage intent only on a single machine.
        These rules are not checked for scenario.storage_architecture san.

    What it checks on the machine (exit 1, a documented prerequisite is not met; nothing is changed):
      - Add-EceFeature exists (the machine is an Azure Local machine) and the OS build is 26100 or later.
      - the DNS name <prefix>-NC.<domain> resolves as the DNS mode says: dynamic, the name is free or already points at the fifth address of the
        infrastructure pool; static, the record exists and points at that address. A record that points anywhere else is the DNS conflict Learn
        describes, and the action plan would fail on it.
      Not checked, because the script cannot: the Azure Stack HCI Administrator role of the account, the Azure role on the subscription, and that
      dynamic updates are on for the DNS zone (Learn: Secure only), which an Active Directory integrated zone does by default.

    Before it enables (exit 2, nothing is changed): sdn.acknowledge_maintenance_window must be true, and sdn.acknowledge_dns_record when sdn.dns_records is
    static. Add-EceFeature asks for these two confirmations at run time and a script cannot answer a prompt, so the file is the answer. Under -WhatIf a
    missing answer is a warning, not an error. An instance that already has SDN is reported before these are looked at.

    Idempotent. When the Network Controller cluster group already exists the script reports AlreadyEnabled and does nothing. This detection is the
    cluster group named Network Controller; Microsoft Learn names no check, so it is not proven on a real instance. A failed run can be run again
    after the cause is fixed (Learn: run the action plan again). -WhatIf reads the machine, prints the plan with the warnings, and changes nothing.

    With sdn.enabled false or missing the script does nothing and exits 0.

    The script does not sign in anywhere and asks nothing. Without -Credential it connects as the local administrator of identity.local_admin (the
    password is a secret reference, read through scripts/common/secrets/AzlSecret.psm1; sign in first with Connect-AzAccount when it is a
    Key Vault reference), or as the account that runs it when the file has no password.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        sdn.enabled, sdn.prefix, sdn.dns_records, sdn.acknowledge_maintenance_window, sdn.acknowledge_dns_record
        networking.management.infrastructure_pool.start, end    the Network Controller record points at the fifth address
        networking.intents[].name, traffic                      the layout Learn supports
        scenario.identity, identity.active_directory.domain_fqdn, identity.local_identity.dns_zone   the domain of the REST URL
        scenario.storage_architecture, scenario.storage_connectivity, nodes[].name, nodes[].management.ip_address
        identity.local_admin.username, identity.local_admin.password

    Exit codes: 0 SDN is enabled now, was already, was planned under -WhatIf, or sdn.enabled is not true; 1 the machine could not be reached, a
    prerequisite on the machine is not met, or the action failed; 2 a value in the file is missing or not usable, or the design is not supported.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to connect to instead of the first machine of nodes[] (its management address, else its name).

.PARAMETER Credential
    Optional. The account for the remoting session. Without it the script uses identity.local_admin of the file, or the account that runs it.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Enable-ArcSdn.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Reads the machine, checks every prerequisite and shows the plan and the warnings. Changes nothing.

.EXAMPLE
    ./Enable-ArcSdn.ps1 -InfrastructureFile ./infrastructure.yml

    Enables SDN. It cannot be undone. Run it again: it reports AlreadyEnabled.
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

# Microsoft Learn: SDN enabled by Arc needs OS build 26100 or later; the Network Controller record is the fifth address of the infrastructure range.
$MinimumBuild = 26100
$RecordOffset = 4   # the fifth address: the first address plus four
# Microsoft Learn (Enable SDN): Add-EceFeature -Name accepts only NC, the Network Controller; the DNS record of the feature is named <prefix>-NC.
$FeatureName = 'NC'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Write-Caution([string]$Text) {
    Write-Warning $Text
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] WARNING {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

function Get-Field($Map, [string]$Key, $Default = $null) {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and "$($Map[$Key])" -ne '') { return $Map[$Key] }
    $Default
}
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

# The intent layouts Learn does not support with SDN enabled by Arc (Software Defined Networking enabled by Azure Arc on Azure Local, Unsupported intent
# configurations and Supported networking patterns). Returns one sentence per problem.
function Get-IntentProblem([object[]]$Intents, [int]$NodeCount, [string]$Connectivity, [string]$Architecture) {
    $problems = [System.Collections.Generic.List[string]]::new()
    $list = @($Intents | Where-Object { $_ -is [System.Collections.IDictionary] })
    if ($list.Count -eq 0) { return @() }
    $traffic = @{}
    foreach ($intent in $list) { $traffic[[string](Get-Field $intent 'name' '?')] = @(@(Get-Field $intent 'traffic' @()) | ForEach-Object { "$_".ToLowerInvariant() }) }
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

# The commands that run on the machine. Each takes the step name first, so one remoting call shape serves all of them.
$Remote = @{
    ReadState = {
        param($Step, $Fqdn)
        $groups = @(Get-ClusterGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Network Controller' } | ForEach-Object { [string]$_.Name })
        $addresses = @()
        if ($Fqdn) { $addresses = @(Resolve-DnsName -Name $Fqdn -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress }) }
        @{
            Computer     = [string]$env:COMPUTERNAME
            OsBuild      = [int][Environment]::OSVersion.Version.Build
            HasEce       = [bool](Get-Command -Name Add-EceFeature -ErrorAction SilentlyContinue)
            NcGroups     = $groups
            DnsAddresses = $addresses
        }
    }
    Enable    = {
        param($Step, $Prefix, $AcknowledgeDns, $FeatureName)
        $parameters = @{ Name = $FeatureName; SDNPrefix = $Prefix; AcknowledgeMaintenanceWindow = $true }
        if ($AcknowledgeDns) { $parameters.AcknowledgeDNSRecordCreation = $true }
        $null = Add-EceFeature @parameters
    }
}
function Invoke-Machine([string]$Step, [object[]]$Arguments = @()) {
    $call = @{ ComputerName = $script:target; ScriptBlock = $Remote[$Step]; ArgumentList = (, $Step + $Arguments); ErrorAction = 'Stop' }
    if ($script:remoteCredential) { $call.Credential = $script:remoteCredential }
    Invoke-Command @call
}

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$enabledRaw = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.enabled'
if ($null -eq $enabledRaw -or $enabledRaw -eq $false) {
    Write-Line 'sdn.enabled is not true: nothing to do. (SDN enabled by Azure Arc cannot be turned off, and this script never tries.)'
    exit 0
}
if ($enabledRaw -isnot [bool]) { Exit-InputProblem "sdn.enabled must be true or false; found '$enabledRaw'." }

$prefix = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.prefix')).Trim()
if (-not $prefix) { Exit-InputProblem 'sdn.prefix is missing. SDN needs a prefix of at most 8 characters (Add-EceFeature -SDNPrefix).' }
if ($prefix.Length -gt 8 -or $prefix -notmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$') {
    Exit-InputProblem "sdn.prefix '$prefix' is not usable: at most 8 characters, letters, digits and single hyphens, with no hyphen at the start or the end."
}
$dnsMode = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.dns_records')).Trim().ToLowerInvariant()
if ($dnsMode -notin 'dynamic', 'static') { Exit-InputProblem "sdn.dns_records must be dynamic or static; found '$dnsMode'." }
foreach ($key in 'acknowledge_maintenance_window', 'acknowledge_dns_record') {
    $value = Get-AzlInfrastructureValue -Infrastructure $infra -Path "sdn.$key"
    if ($null -ne $value -and $value -isnot [bool]) { Exit-InputProblem "sdn.$key must be true or false; found '$value'." }
}
$ackWindow = (Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.acknowledge_maintenance_window') -eq $true
$ackDns = (Get-AzlInfrastructureValue -Infrastructure $infra -Path 'sdn.acknowledge_dns_record') -eq $true

$poolStart = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.management.infrastructure_pool.start')).Trim()
$poolEnd = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.management.infrastructure_pool.end')).Trim()
if (-not (Test-Ipv4 $poolStart) -or -not (Test-Ipv4 $poolEnd)) { Exit-InputProblem 'networking.management.infrastructure_pool.start and end are missing or not IPv4 addresses. The Network Controller record points at the fifth address of this range.' }
$recordNumber = (ConvertTo-Number $poolStart) + $RecordOffset
if ($recordNumber -gt (ConvertTo-Number $poolEnd)) { Exit-InputProblem 'networking.management.infrastructure_pool holds fewer than five addresses, so it has no fifth address for the Network Controller record.' }
$reservedAddress = ConvertFrom-Number $recordNumber

$identityKind = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.identity')).Trim().ToLowerInvariant()
$domain = if ($identityKind -eq 'local_identity') { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_identity.dns_zone')).Trim() } else { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.active_directory.domain_fqdn')).Trim() }
$fqdn = if ($domain) { "$prefix-$FeatureName.$domain" } else { '' }
if (-not $domain -and $dnsMode -eq 'static') { Exit-InputProblem 'sdn.dns_records is static, so the record must be checked, but the domain is missing (identity.active_directory.domain_fqdn, or identity.local_identity.dns_zone with local identity).' }

$architecture = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.storage_architecture')).Trim().ToLowerInvariant()
$connectivity = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'scenario.storage_connectivity')).Trim().ToLowerInvariant()
$nodeInfo = @(Get-AzlInfrastructureNode -Infrastructure $infra)
$intentValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.intents'
$intents = @(@($intentValue) | Where-Object { $null -ne $_ })
$intentProblems = @(Get-IntentProblem -Intents $intents -NodeCount $nodeInfo.Count -Connectivity $connectivity -Architecture $architecture)
if ($intentProblems) { Exit-InputProblem ("This design is not supported by SDN enabled by Azure Arc (Microsoft Learn, sdn-overview):`n  " + ($intentProblems -join "`n  ")) }
if ($intents.Count -eq 0) { Write-Caution 'networking.intents is not in the file, so the intent layout was not checked against what SDN enabled by Arc supports.' }

# ---- the plan and the warnings (also under -WhatIf)
Write-Caution 'SDN enabled by Azure Arc CANNOT BE UNDONE. Microsoft Learn: once you enable SDN you cannot roll back or disable it.'
Write-Caution 'Enabling it interrupts the network of running workloads for a short time while the Virtual Filtering Platform policies are applied. Arrange a maintenance window on a production instance.'
Write-Caution 'The action plan takes up to 20 minutes. Never run it where Network Controller was deployed with on-premises tools (SDN Express, Windows Admin Center).'
Write-Line "Plan: Add-EceFeature -Name NC -SDNPrefix $prefix -AcknowledgeMaintenanceWindow$(if ($dnsMode -eq 'static') { ' -AcknowledgeDNSRecordCreation' }). DNS $dnsMode; the record $(if ($fqdn) { $fqdn } else { "$prefix-NC" }) must point at $reservedAddress."

$answersMissing = [System.Collections.Generic.List[string]]::new()
if (-not $ackWindow) { $answersMissing.Add('sdn.acknowledge_maintenance_window is not true: set it to true when a maintenance window is arranged.') }
if ($dnsMode -eq 'static' -and -not $ackDns) { $answersMissing.Add("sdn.acknowledge_dns_record is not true: set it to true when the record $fqdn exists and points at $reservedAddress.") }
if ($answersMissing -and $WhatIfPreference) { foreach ($m in $answersMissing) { Write-Caution "The real run would stop: $m" } }

# ---- where to connect, and as whom
$target = if ($ComputerName) { $ComputerName.Trim() } elseif ($nodeInfo.Count -gt 0) { $(if ($nodeInfo[0].ManagementIp) { $nodeInfo[0].ManagementIp } else { $nodeInfo[0].Name }) } else { '' }
if (-not $target) { Exit-InputProblem 'nodes[] is empty. The script connects to a machine of the instance (or give -ComputerName).' }
$remoteCredential = $Credential
if (-not $remoteCredential) {
    $adminUser = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.username')).Trim()
    $adminReference = ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.password')).Trim()
    if ($adminUser -and $adminReference) {
        try { $secret = Get-AzlSecretValue -Reference $adminReference -Infrastructure $infra }
        catch {
            $code = if ($_.Exception.Data.Contains('AzlExit')) { [int]$_.Exception.Data['AzlExit'] } else { 1 }
            if ($code -eq 2) { Exit-InputProblem "The password of identity.local_admin could not be read: $($_.Exception.Message)" }
            Exit-Failed "The password of identity.local_admin could not be read: $($_.Exception.Message)"
        }
        $remoteCredential = [pscredential]::new(".\$adminUser", $secret)
    }
}

# ---- the machine as it is (read only)
Write-Line "Machine '$target': reading the OS build, the Network Controller cluster group and the DNS name"
try { $state = Invoke-Machine 'ReadState' @($fqdn) }
catch { Exit-Failed "The machine '$target' could not be read: $($_.Exception.Message)" }

$rows = [System.Collections.Generic.List[object]]::new()
$item = 'SDN enabled by Azure Arc'
function Add-Row([string]$Action, [string]$Detail = '') {
    $rows.Add([pscustomobject][ordered]@{ Item = $item; Action = $Action; Detail = $Detail })
    $tag = switch ($Action) { 'Failed' { '[failed] ' } 'AlreadyEnabled' { '[exists] ' } { $_ -like 'Would*' } { '[plan]    ' } default { '[done]   ' } }
    Write-Line ("{0}{1}: {2}{3}" -f $tag, $item, $Action, $(if ($Detail) { " ($Detail)" } else { '' }))
}

if (@($state.NcGroups).Count -gt 0) {
    Add-Row 'AlreadyEnabled' "cluster group '$(@($state.NcGroups)[0])' exists; left as it is"
    $rows
    exit 0
}
if (-not $state.HasEce) { Exit-Failed "Add-EceFeature is not available on '$target'. It is the command of Azure Local that enables SDN; run this against a machine of an Azure Local instance." }
if ([int]$state.OsBuild -lt $MinimumBuild) { Exit-Failed "The OS build of '$target' is $($state.OsBuild). SDN enabled by Azure Arc needs Azure Local 2506 or later with OS build $MinimumBuild or later." }
$resolved = @($state.DnsAddresses)
if ($fqdn) {
    if ($resolved.Count -eq 0 -and $dnsMode -eq 'static') { Exit-Failed "sdn.dns_records is static, but $fqdn does not resolve on '$target'. Create the A record $fqdn pointing at $reservedAddress first." }
    $others = @($resolved | Where-Object { $_ -ne $reservedAddress })
    if ($others) { Exit-Failed "DNS conflict for ${fqdn}: it resolves to $($others -join ', '), but the Network Controller record must point at $reservedAddress (the fifth address of networking.management.infrastructure_pool). Fix the record or choose another sdn.prefix." }
    Write-Line "DNS: $fqdn $(if ($resolved.Count) { "points at $reservedAddress" } else { 'is free; dynamic DNS creates it' })"
}
else { Write-Caution 'The domain is not in the file, so the DNS name of the Network Controller was not checked.' }

if ($answersMissing -and -not $WhatIfPreference) {
    Exit-InputProblem ("SDN enabled by Arc was not enabled; nothing was changed. These answers are missing in the file (the command asks them at run time and a script cannot answer a prompt):`n  " + ($answersMissing -join "`n  "))
}
if ($PSCmdlet.ShouldProcess("the instance of '$target'", "Enable SDN enabled by Azure Arc (Add-EceFeature -Name NC -SDNPrefix $prefix); this cannot be undone")) {
    try {
        Write-Line 'Running the action plan. This takes up to 20 minutes.'
        Invoke-Machine 'Enable' @($prefix, ($dnsMode -eq 'static' -and $ackDns), $FeatureName)
        $after = Invoke-Machine 'ReadState' @('')
        if (@($after.NcGroups).Count -gt 0) { Add-Row 'Enabled' "cluster group '$(@($after.NcGroups)[0])' exists" }
        else {
            Add-Row 'Enabled' 'Add-EceFeature finished without an error; the Network Controller cluster group was not found by name, so check it with Get-ClusterGroup on the machine'
            Write-Caution 'The Network Controller cluster group was not found by name after the action plan. Check the output of Add-EceFeature and Get-ClusterGroup before you create logical networks.'
        }
    }
    catch { Add-Row 'Failed' "$($_.Exception.Message). Fix the cause and run the script again; Learn says to run the action plan again." }
}
else { Add-Row 'WouldEnable' "prefix $prefix, DNS $dnsMode, record points at $reservedAddress; cannot be undone" }

$rows
if (@($rows | Where-Object Action -EQ 'Failed')) { exit 1 }
exit 0
