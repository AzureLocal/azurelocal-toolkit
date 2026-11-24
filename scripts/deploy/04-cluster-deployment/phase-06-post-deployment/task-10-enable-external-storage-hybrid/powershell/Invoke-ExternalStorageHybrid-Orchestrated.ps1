<#
.SYNOPSIS
    Attaches the external SAN of storage.san to a deployed hyperconverged Azure Local instance (hybrid: Storage Spaces Direct plus SAN volumes), step by step as
    the guide page "Task 10: Enable External Storage (Hybrid S2D plus SAN)" and Microsoft Learn (Connect an external storage array to Azure Local) describe.

.DESCRIPTION
    Phase 06 (post-deployment), Task 10 (enable external storage, hybrid). Hybrid is a day 2 operation: the instance is deployed with Storage Spaces Direct
    first, then the SAN is added. The steps of the page, and the script of the toolkit that does each one (this script holds no logic of its own for them):

      Checks    scenario.storage_architecture is hybrid (s2d: nothing to do, exit 0; san: the SAN-only route of phases 03 and 05, exit 2);
                scenario.topology is not rack_aware (Learn: rack aware instances are not supported with external SAN storage on hyperconverged deployments);
                storage.san.type is fibre_channel or iscsi. On a node (read only): the instance is a cluster, its solution release is 2604 or later, and no
                solution update is running (the page: check for a running update before you start).
      Steps 1-3, 5  MPIO, the array in MSDSM, the load balance policy and vendor MPIO timers, the iSCSI service, auto-claim, portals and persistent
                multipath sessions: scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Set-AzureLocalNodeConfiguration.ps1 -Step Mpio -NoRestart
                (-Execute unless -WhatIf). It reads storage.san (type, array vendor and model, iSCSI targets) and nodes[].san, and config/san/msdsm-vendors.json.
                The iSCSI network itself (static addresses, MTU, VLAN, /32 routes of page step 3) is the Network step of the same script from nodes[].
      Step 4    On the array and the fabric (zoning, LUN masking). Not a script: the page lists what to ask the storage administrator.
      Step 6    MPIO changes take effect after a restart. With -RollingRestart, each node in turn is drained, restarted and resumed by
                scripts/deploy/08-day2-operations/task-03-node-maintenance/powershell/Invoke-NodeMaintenanceReboot.ps1 (one node at a time, so the cluster
                stays up), then the MPIO step runs again to finish what waited for the restart. Without -RollingRestart, a node that needs a restart stops the
                run with exit code 1 and the message says what to run.
      Step 7    Every node sees the same SAN disks: Set-AzureLocalNodeConfiguration.ps1 -Step SanVerify (read only).
      Steps 8-9 The LUNs of storage.san.luns become NTFS Cluster Shared Volumes: scripts/deploy/04-cluster-deployment/phase-06-post-deployment/
                task-05-storage-configuration/powershell/New-SanVolume.ps1 (finds each disk by UniqueId and refuses any disk that is not exactly the LUN).
                With -ValidateStorage, Test-Cluster -Include Storage then runs on a node (Learn, step 9).
      Step 10   The SAN CSVs become storage paths in Azure: .../task-05-storage-configuration/powershell/New-StoragePath.ps1.

    A step that ends with exit code 2 stops the run with 2; exit code 1 stops it with 1. -WhatIf is passed to every step, which then reads and changes
    nothing; the restarts and Test-Cluster do not run under -WhatIf.

    Billing: adding external storage starts a 30-day trial, then Azure Local (L2) billing (the page, Prerequisites). The script says so; it does not
    change anything in billing.

    The login for the checks and Test-Cluster: -Credential, else the account the file names for the identity: identity.active_directory.lcm_user (as
    <netbios name>\<user>) with active_directory, identity.local_admin (as .\<user>) with local_identity; the password is a secret reference read through
    scripts/common/secrets/AzlSecret.psm1. -Credential is passed to the steps that take it. The script never asks.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure); the steps read their own keys:
        scenario.storage_architecture, scenario.topology, storage.san.type, scenario.identity, nodes[].name, nodes[].management.ip_address
        identity.active_directory.netbios_name, identity.active_directory.lcm_user (username, password), identity.local_admin (username, password)

    Exit codes: 0 every step ended with 0 (or planned under -WhatIf), or the design is not hybrid; 1 a check or a step failed, or a restart is needed and
    -RollingRestart was not given; 2 a value in the file is missing or not usable, or the design does not allow this task.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER Credential
    Optional. The account for the remoting sessions to the nodes. Without it the account of the file is used (see above).

.PARAMETER RollingRestart
    Optional. Restart the nodes one at a time (drain, restart, resume) after the MPIO step, as page step 6 asks, then run the MPIO step again.

.PARAMETER ValidateStorage
    Optional. Run Test-Cluster -Include Storage on a node after the volumes are created (page step 9).

.PARAMETER LogPath
    Optional. Passed to the steps that take it; the progress lines of this script are appended to it. Keep it out of the repository.

.EXAMPLE
    ./Invoke-ExternalStorageHybrid-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

.EXAMPLE
    ./Invoke-ExternalStorageHybrid-Orchestrated.ps1 -InfrastructureFile ./infrastructure.yml -RollingRestart -ValidateStorage
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [pscredential]$Credential,
    [switch]$RollingRestart,
    [switch]$ValidateStorage,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

$deploy = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
$NodeConfigScript = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-03-os-configuration', 'Set-AzureLocalNodeConfiguration.ps1')
$SanVolumeScript = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-SanVolume.ps1')
$StoragePathScript = [IO.Path]::Combine($deploy, '04-cluster-deployment', 'phase-06-post-deployment', 'task-05-storage-configuration', 'powershell', 'New-StoragePath.ps1')
$RebootScript = [IO.Path]::Combine($deploy, '08-day2-operations', 'task-03-node-maintenance', 'powershell', 'Invoke-NodeMaintenanceReboot.ps1')
# The page (Prerequisites) and Learn: hybrid needs Azure Local 2604 or later.
$MinimumRelease = 2604

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }

$Remote = @{
    ReadState     = {
        param($Step)
        $version = ''
        try { $version = [string](@(Get-SolutionUpdateEnvironment -ErrorAction Stop)[0].CurrentVersion) } catch { $version = '' }
        $running = @()
        try { $running = @(Get-SolutionUpdate -ErrorAction Stop | Where-Object { [string]$_.State -match 'Installing|Preparing|Downloading|HealthChecking' } | ForEach-Object { "$($_.Version) $($_.State)" }) } catch { $running = @() }
        $cluster = ''
        try { $cluster = [string](Get-Cluster -ErrorAction Stop).Name } catch { $cluster = '' }
        @{ Computer = [string]$env:COMPUTERNAME; SolutionVersion = $version; RunningUpdates = $running; Cluster = $cluster }
    }
    ValidateStore = {
        param($Step)
        $report = Test-Cluster -Include 'Storage' -ErrorAction Stop
        @{ Report = [string]$report.FullName }
    }
}
function Invoke-Node([string]$Computer, [string]$Step) {
    Invoke-Command -ComputerName $Computer -Credential $script:remoteCredential -ScriptBlock $Remote[$Step] -ArgumentList $Step -ErrorAction Stop
}

$summary = [System.Collections.Generic.List[object]]::new()
function Add-Step([string]$Step, [string]$Result, [string]$Detail = '') {
    $summary.Add([pscustomobject][ordered]@{ Step = $Step; Result = $Result; Detail = $Detail })
    Write-Line ("[{0,-12}] {1}{2}" -f $Result.ToLowerInvariant(), $Step, $(if ($Detail) { ": $Detail" } else { '' }))
}
function Complete-Run([int]$Code) { $script:summary; exit $Code }
# Runs one step script. Returns its exit code; on 1 or 2 the run ends with that code.
function Invoke-StepScript([string]$Name, [string]$Path, [hashtable]$Arguments, [switch]$ContinueOnFailure) {
    Write-Line "---- $Name"
    $global:LASTEXITCODE = 0
    & $Path @Arguments
    $code = [int]$LASTEXITCODE
    Add-Step $Name $(switch ($code) { 0 { 'Passed' } 2 { 'InputProblem' } default { 'Failed' } }) "exit code $code"
    if ($code -ne 0 -and -not $ContinueOnFailure) { Complete-Run $(if ($code -eq 2) { 2 } else { 1 }) }
    $code
}

foreach ($p in $NodeConfigScript, $SanVolumeScript, $StoragePathScript, $RebootScript) { if (-not (Test-Path -LiteralPath $p)) { Write-Error "The step script is missing: $p" -ErrorAction Continue; exit 1 } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }
$architecture = (Get-Text 'scenario.storage_architecture').ToLowerInvariant()
if ($architecture -in '', 's2d') { Write-Line "scenario.storage_architecture is '$(if ($architecture) { $architecture } else { 's2d (default)' })': no external SAN to attach. Nothing to do."; exit 0 }
if ($architecture -eq 'san') { Exit-InputProblem 'scenario.storage_architecture is san: a SAN-only instance is prepared before the deployment (phase 03, tasks 12 to 14) and deployed with the SAN runbooks of phase 05. This task is for hybrid (S2D plus SAN) only.' }
if ($architecture -ne 'hybrid') { Exit-InputProblem "scenario.storage_architecture must be s2d, san or hybrid; found '$architecture'." }
if ((Get-Text 'scenario.topology').ToLowerInvariant() -eq 'rack_aware') { Exit-InputProblem 'scenario.topology is rack_aware. Microsoft Learn: rack aware instances are not supported with external SAN storage on hyperconverged deployments.' }
$sanType = (Get-Text 'storage.san.type').ToLowerInvariant()
if ($sanType -notin 'fibre_channel', 'iscsi') { Exit-InputProblem "storage.san.type must be fibre_channel or iscsi; found '$sanType'." }
$nodes = @(Get-AzlInfrastructureNode -Infrastructure $infra)
if ($nodes.Count -eq 0) { Exit-InputProblem 'nodes[] is empty.' }

# ---- the login for the checks
$remoteCredential = $Credential
if (-not $remoteCredential) {
    if ((Get-Text 'scenario.identity').ToLowerInvariant() -eq 'local_identity') { $user = Get-Text 'identity.local_admin.username'; $reference = Get-Text 'identity.local_admin.password'; $account = ".\$user"; $what = 'identity.local_admin' }
    else {
        $netbios = Get-Text 'identity.active_directory.netbios_name'
        $user = Get-Text 'identity.active_directory.lcm_user.username'; $reference = Get-Text 'identity.active_directory.lcm_user.password'
        $account = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } else { $user }
        $what = 'identity.active_directory.lcm_user'
    }
    if (-not $user -or -not $reference) { Exit-InputProblem "No login for the nodes: pass -Credential, or set $what username and password (a secret reference)." }
    try { $remoteCredential = [pscredential]::new($account, (Get-AzlSecretValue -Reference $reference -Infrastructure $infra)) }
    catch { Exit-InputProblem "The password of $what could not be read: $($_.Exception.Message)" }
}

Write-Warning 'Adding external storage starts a 30-day trial, then the instance is billed at Azure Local (L2); Azure Hybrid Benefit does not apply to L2.'

# ---- checks on a node (read only)
$state = $null; $target = ''
foreach ($n in $nodes) {
    $address = if ($n.ManagementIp) { $n.ManagementIp } else { $n.Name }
    try { $state = Invoke-Node $address 'ReadState'; $target = $address; break } catch { Write-Line "  $($n.Name): $($_.Exception.Message)" }
}
if (-not $state) { Add-Step 'Checks' 'Failed' 'no node answered over PowerShell remoting'; Complete-Run 1 }
if (-not $state.Cluster) { Add-Step 'Checks' 'Failed' "'$target' is not a member of a cluster: deploy the instance first (hybrid is a day 2 operation)"; Complete-Run 1 }
$release = 0
$parts = ([string]$state.SolutionVersion).Split('.')
if ($parts.Count -ge 2) { $null = [int]::TryParse($parts[1], [ref]$release) }
if ($release -lt $MinimumRelease) { Add-Step 'Checks' 'Failed' "the solution version is '$($state.SolutionVersion)'; external storage on a hyperconverged instance needs $MinimumRelease or later"; Complete-Run 1 }
if (@($state.RunningUpdates).Count) { Add-Step 'Checks' 'Failed' "a solution update is running ($(@($state.RunningUpdates) -join ', ')); start this task after it ends"; Complete-Run 1 }
Add-Step 'Checks' 'Passed' "cluster $($state.Cluster), solution $($state.SolutionVersion), no update running, $sanType"

# ---- steps 1-3 and 5: MPIO, MSDSM, iSCSI
$nodeArgs = @{ InfrastructureFile = $InfrastructureFile; Step = @('Mpio'); NoRestart = $true; Credential = $remoteCredential }
if (-not $WhatIfPreference) { $nodeArgs.Execute = $true }
$mpioCode = Invoke-StepScript 'Steps 1-3, 5: MPIO, MSDSM, iSCSI (Set-AzureLocalNodeConfiguration.ps1 -Step Mpio)' $NodeConfigScript $nodeArgs -ContinueOnFailure
if ($mpioCode -eq 2) { Complete-Run 2 }

# ---- step 6: restart, one node at a time
if ($WhatIfPreference) {
    Add-Step 'Step 6: rolling restart' 'Plan' $(if ($RollingRestart) { "each of $($nodes.Count) node(s) in turn: drain, restart, resume (Invoke-NodeMaintenanceReboot.ps1)" } else { 'not asked for (-RollingRestart)' })
}
elseif ($RollingRestart) {
    foreach ($n in $nodes) {
        $rebootArgs = @{ InfrastructureFile = $InfrastructureFile; TargetNode = $n.Name; Credential = $remoteCredential }
        if ($LogPath) { $rebootArgs.LogPath = $LogPath }
        $null = Invoke-StepScript "Step 6: restart $($n.Name) (Invoke-NodeMaintenanceReboot.ps1)" $RebootScript $rebootArgs
    }
    $mpioCode = Invoke-StepScript 'Steps 1-3, 5 after the restarts (Set-AzureLocalNodeConfiguration.ps1 -Step Mpio)' $NodeConfigScript $nodeArgs -ContinueOnFailure
    if ($mpioCode -ne 0) { Complete-Run $(if ($mpioCode -eq 2) { 2 } else { 1 }) }
}
elseif ($mpioCode -ne 0) {
    Add-Step 'Step 6: rolling restart' 'Failed' 'the MPIO step is not finished: MPIO changes take effect after a restart. Run this script again with -RollingRestart, or restart each node in turn with Invoke-NodeMaintenanceReboot.ps1 and run it again.'
    Complete-Run 1
}
else { Add-Step 'Step 6: rolling restart' 'Skipped' 'the MPIO step reports nothing left to do; restart the nodes in turn if you changed MPIO by hand' }

# ---- step 7: every node sees the same SAN disks
$verifyArgs = @{ InfrastructureFile = $InfrastructureFile; Step = @('SanVerify'); Credential = $remoteCredential }
$null = Invoke-StepScript 'Step 7: SAN disks on every node (Set-AzureLocalNodeConfiguration.ps1 -Step SanVerify)' $NodeConfigScript $verifyArgs

# ---- steps 8-9: the CSVs
$volumeArgs = @{ InfrastructureFile = $InfrastructureFile; WhatIf = [bool]$WhatIfPreference; Credential = $remoteCredential }
if ($LogPath) { $volumeArgs.LogPath = $LogPath }
$null = Invoke-StepScript 'Steps 8-9: SAN CSVs (New-SanVolume.ps1)' $SanVolumeScript $volumeArgs
if ($ValidateStorage) {
    if ($WhatIfPreference) { Add-Step 'Step 9: Test-Cluster -Include Storage' 'Plan' "would run on '$target'" }
    else {
        try { $v = Invoke-Node $target 'ValidateStore'; Add-Step 'Step 9: Test-Cluster -Include Storage' 'Passed' "report $($v.Report)" }
        catch { Add-Step 'Step 9: Test-Cluster -Include Storage' 'Failed' $_.Exception.Message; Complete-Run 1 }
    }
}

# ---- step 10: storage paths in Azure
$pathArgs = @{ InfrastructureFile = $InfrastructureFile; WhatIf = [bool]$WhatIfPreference }
if ($LogPath) { $pathArgs.LogPath = $LogPath }
$null = Invoke-StepScript 'Step 10: storage paths in Azure (New-StoragePath.ps1)' $StoragePathScript $pathArgs

Complete-Run 0
