<#
.SYNOPSIS
    Checks that a deployed Azure Local instance meets the prerequisites of SDN enabled by Azure Arc, before Enable-ArcSdn.ps1 turns it on. Read only.

.DESCRIPTION
    Operational foundations, phase 01 (SDN), Task 01 (validate SDN prerequisites). It runs from a management host and asks one node of the instance
    over PowerShell remoting. Nothing is created, changed or deleted.

    The checks, from Microsoft Learn (Software Defined Networking enabled by Azure Arc on Azure Local, sdn-overview; Enable SDN integration):
      1. OS build: 26100 or later.
      2. Azure Local version: 2506 or later (Learn: "available with Azure Local 2506 with OS version 26100.xxxx or later"). Read from
         Get-SolutionUpdateEnvironment (CurrentVersion, the second part is the release yymm). When it cannot be read the check is a warning.
      3. Azure Local registration: the instance is registered and its connection status is Connected (Get-AzureStackHCI). This is the connection of
         the instance, not the health of each Arc machine; Invoke-VerifyPostDeployment.azcli.ps1 (phase 06, task 09) checks the Arc machines.
      4. Network intents, as the file plans them (networking.intents[]) and as the machine has them (Get-NetIntent): a layout Learn supports with
         SDN enabled by Arc (at most three intents; no compute and storage without management; no compute-only intent on one machine; no three
         intents on two or three machines with switchless storage; group-all only with switched storage; five machines or more only with
         switched storage; management and compute without storage only on one machine). The rules are in scripts/common/sdn/AzlSdn.psm1, the
         same copy Enable-ArcSdn.ps1 uses. A difference between the intent names of the file and of the machine is a warning.
      5. SDN state: when the Network Controller cluster group exists, SDN enabled by Arc is already on (reported, not a failure).
      6. SDN managed by on-premises tools: Learn says never to enable SDN by Arc where Network Controller was deployed with on-premises tools
         (SDN Express, Windows Admin Center). The script cannot prove it. It reports a warning when the Network Controller host agent service
         (NcHostAgent) runs while the Network Controller cluster group of SDN by Arc does not exist: a sign to check, not a failure.
      7. AKS: Learn supports AKS with SDN enabled by Arc, but not a network security group on the logical network of AKS workloads or on their VM
         NICs. Reported as information; the script does not read AKS.

    -WhatIf lists the checks and runs none.

    The login is -Credential, else the account the file names for the identity: the deployment (LCM) user identity.active_directory.lcm_user
    (as <netbios name>\<user>) with active_directory, the local administrator identity.local_admin (as .\<user>) with local_identity. The password is
    a secret reference read through scripts/common/secrets/AzlSecret.psm1. The script never asks. With neither it stops with exit code 2.
    It connects to -ComputerName, else to the management address of the first node of nodes[] that answers.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        networking.intents[] (name, traffic), scenario.storage_connectivity, scenario.storage_architecture, scenario.identity
        nodes[].name, nodes[].management.ip_address
        identity.active_directory.netbios_name, identity.active_directory.lcm_user (username, password), identity.local_admin (username, password)

    Exit codes: 0 every check passed (warnings and information allowed) or the checks were listed under -WhatIf; 1 a check failed or no node
    answered; 2 a value in the file is missing or not usable, or there is no login (nothing was checked).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER ComputerName
    Optional. The machine to ask (a node name of the file or an address), instead of the first node of nodes[] that answers.

.PARAMETER Credential
    Optional. The account for the remoting session. Without it the account of the file is used (see above).

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-SdnPrerequisites-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml

    Checks the prerequisites. Then run ./Enable-ArcSdn.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf (phase 06, task 01) for the plan.
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

# Microsoft Learn (sdn-overview): SDN enabled by Arc needs Azure Local 2506 or later with OS build 26100 or later.
$MinimumBuild = 26100
$MinimumRelease = 2506
# The service of the Network Controller host agent on a machine that a Network Controller manages.
$HostAgentService = 'NcHostAgent'

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

$Remote = @{
    Probe     = { param($Step) [string]$env:COMPUTERNAME }
    ReadState = {
        param($Step, $HostAgent)
        $version = ''
        try { $version = [string](@(Get-SolutionUpdateEnvironment -ErrorAction Stop)[0].CurrentVersion) } catch { $version = '' }
        $registration = $null
        try { $registration = Get-AzureStackHCI -ErrorAction Stop } catch { $registration = $null }
        $intents = @()
        try { $intents = @(Get-NetIntent -ErrorAction Stop | ForEach-Object { @{ IntentName = [string]$_.IntentName; IsManagementIntentSet = [bool]$_.IsManagementIntentSet; IsComputeIntentSet = [bool]$_.IsComputeIntentSet; IsStorageIntentSet = [bool]$_.IsStorageIntentSet } }) } catch { $intents = @() }
        $agent = Get-Service -Name $HostAgent -ErrorAction SilentlyContinue
        @{
            Computer           = [string]$env:COMPUTERNAME
            OsBuild            = [int][Environment]::OSVersion.Version.Build
            SolutionVersion    = $version
            RegistrationStatus = $(if ($registration) { [string]$registration.RegistrationStatus } else { '' })
            ConnectionStatus   = $(if ($registration) { [string]$registration.ConnectionStatus } else { '' })
            NetIntents         = $intents
            NodeCount          = @(Get-ClusterNode -ErrorAction SilentlyContinue).Count
            NcGroups           = @(Get-ClusterGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Network Controller' } | ForEach-Object { [string]$_.Name })
            HostAgentStatus    = $(if ($agent) { [string]$agent.Status } else { '' })
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
$architecture = (Get-Text 'scenario.storage_architecture').ToLowerInvariant()
$connectivity = (Get-Text 'scenario.storage_connectivity').ToLowerInvariant()
$nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
if ($nodes.Count -eq 0 -and -not $ComputerName) { Exit-InputProblem 'nodes[] is empty. The script asks a node of the instance (or give -ComputerName).' }
$intentValue = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.intents'
$fileIntents = @(@($intentValue) | Where-Object { $null -ne $_ })

$checks = @('OS build', 'Azure Local version', 'Azure Local registration', 'Network intents (file)', 'Network intents (machine)', 'SDN enabled by Arc', 'SDN managed by on-premises tools', 'AKS workloads')
if ($WhatIfPreference) {
    foreach ($c in $checks) { Add-Check $c 'Plan' 'would be checked' }
    $rows
    exit 0
}

# ---- the login: -Credential, else the account of the file. Nothing is asked.
$remoteCredential = $Credential
if (-not $remoteCredential) {
    $identityMode = (Get-Text 'scenario.identity').ToLowerInvariant()
    if ($identityMode -eq 'local_identity') {
        $user = Get-Text 'identity.local_admin.username'; $reference = Get-Text 'identity.local_admin.password'; $account = ".\$user"; $what = 'identity.local_admin'
    }
    else {
        $netbios = Get-Text 'identity.active_directory.netbios_name'
        $user = Get-Text 'identity.active_directory.lcm_user.username'; $reference = Get-Text 'identity.active_directory.lcm_user.password'
        $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'
    }
    if (-not $user -or -not $reference) { Exit-InputProblem "No login: pass -Credential, or set $what username and password (a secret reference) in the infrastructure file." }
    try { $secret = Get-AzlSecretValue -Reference $reference -Infrastructure $infra }
    catch { Exit-InputProblem "The password of $what could not be read: $($_.Exception.Message)" }
    $remoteCredential = [pscredential]::new($account, $secret)
}

# ---- the file: the planned intents
$fileProblems = @(Get-AzlSdnIntentProblem -Intents $fileIntents -NodeCount $nodes.Count -Connectivity $connectivity -Architecture $architecture)
if ($fileIntents.Count -eq 0) { Add-Check 'Network intents (file)' 'Warn' 'networking.intents is not in the file' }
elseif ($fileProblems) { Add-Check 'Network intents (file)' 'Fail' ($fileProblems -join ' ') }
else { Add-Check 'Network intents (file)' 'Pass' "$($fileIntents.Count) intent(s), a layout SDN enabled by Arc supports" }

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
try { $state = Invoke-Node $target 'ReadState' @($HostAgentService) }
catch { Add-Check 'Connection' 'Fail' "'$target' could not be read: $($_.Exception.Message)"; $rows; exit 1 }
Write-Line "Asked '$target' ($($state.Computer)) as $($remoteCredential.UserName)."

if ([int]$state.OsBuild -ge $MinimumBuild) { Add-Check 'OS build' 'Pass' "$($state.OsBuild)" } else { Add-Check 'OS build' 'Fail' "$($state.OsBuild); SDN enabled by Arc needs $MinimumBuild or later" }

$release = 0
$parts = ([string]$state.SolutionVersion).Split('.')
if ($parts.Count -ge 2) { $null = [int]::TryParse($parts[1], [ref]$release) }
if ($release -ge 1000) {
    if ($release -ge $MinimumRelease) { Add-Check 'Azure Local version' 'Pass' "$($state.SolutionVersion) (release $release)" }
    else { Add-Check 'Azure Local version' 'Fail' "$($state.SolutionVersion) (release $release); SDN enabled by Arc needs $MinimumRelease or later" }
}
else { Add-Check 'Azure Local version' 'Warn' "the solution version could not be read ('$($state.SolutionVersion)'); check that it is $MinimumRelease or later" }

if ([string]$state.ConnectionStatus -eq 'Connected') { Add-Check 'Azure Local registration' 'Pass' "$($state.RegistrationStatus), $($state.ConnectionStatus)" }
else { Add-Check 'Azure Local registration' 'Fail' "registration '$($state.RegistrationStatus)', connection '$($state.ConnectionStatus)'; the instance must be registered and connected (Sync-AzureStackHCI on a node)" }

$liveIntents = @(ConvertTo-AzlSdnIntentTraffic -NetIntent @($state.NetIntents))
$liveNodes = if ([int]$state.NodeCount -gt 0) { [int]$state.NodeCount } else { $nodes.Count }
if ($liveIntents.Count -eq 0) { Add-Check 'Network intents (machine)' 'Warn' 'Get-NetIntent returned no intent' }
else {
    $liveProblems = @(Get-AzlSdnIntentProblem -Intents $liveIntents -NodeCount $liveNodes -Connectivity $connectivity -Architecture $architecture)
    if ($liveProblems) { Add-Check 'Network intents (machine)' 'Fail' ($liveProblems -join ' ') }
    else { Add-Check 'Network intents (machine)' 'Pass' "$(($liveIntents | ForEach-Object { "$($_.name) ($($_.traffic -join '+'))" }) -join ', ')" }
    $fileNames = @($fileIntents | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['name'] } | Sort-Object)
    $liveNames = @($liveIntents | ForEach-Object { [string]$_.name } | Sort-Object)
    if ($fileNames.Count -gt 0 -and (Compare-Object $fileNames $liveNames)) { Add-Check 'Network intents (file and machine)' 'Warn' "the file plans [$($fileNames -join ', ')], the machine has [$($liveNames -join ', ')]" }
}

$ncGroups = @($state.NcGroups)
if ($ncGroups.Count -gt 0) { Add-Check 'SDN enabled by Arc' 'Pass' "already enabled: the cluster group '$($ncGroups[0])' exists" }
else { Add-Check 'SDN enabled by Arc' 'Pass' 'not enabled yet' }

if ($ncGroups.Count -eq 0 -and [string]$state.HostAgentStatus -eq 'Running') { Add-Check 'SDN managed by on-premises tools' 'Warn' "the service $HostAgentService runs but SDN enabled by Arc is not on. Check that no Network Controller deployed with on-premises tools (SDN Express, Windows Admin Center) manages this machine: Learn says never to enable SDN by Arc there." }
else { Add-Check 'SDN managed by on-premises tools' 'Pass' "no sign of it ($HostAgentService $(if ($state.HostAgentStatus) { $state.HostAgentStatus } else { 'not present' }))" }

Add-Check 'AKS workloads' 'Info' 'AKS is supported with SDN enabled by Arc; Learn does not support a network security group on the logical network of AKS workloads or on their VM NICs'

$rows
if (@($rows | Where-Object Result -EQ 'Fail')) { exit 1 }
exit 0
