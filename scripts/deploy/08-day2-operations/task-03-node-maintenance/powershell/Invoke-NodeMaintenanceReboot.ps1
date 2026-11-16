<#
.SYNOPSIS
    Takes one Azure Local node through maintenance: checks it is safe, drains it, reboots it, waits for it, resumes it and waits for the storage to repair.

.DESCRIPTION
    Day 2, stage 08 task 03. The procedure follows Microsoft Learn (Suspend and resume Azure Local machines for maintenance; Failover cluster maintenance procedures):

      0. Safe to take the node out? Every other node is Up, every virtual disk is Healthy and OK, and no storage repair job is running (Get-VirtualDisk, Get-StorageJob).
         Both Azure Local cmdlets of the procedure must exist on the node (Remove-MocPhysicalNode, New-MocPhysicalNode; Azure Local 2311.2 or later). If not, the
         script stops before it changes anything.
      1. Suspend-ClusterNode -Drain -Wait: the roles and virtual machines live migrate to the other nodes; the node must show Paused.
      2. Remove-MocPhysicalNode: no new virtual machine is placed on the node.
      3. Restart-Computer, then wait for the node: it goes offline, comes back (ping), and PowerShell remoting works again. The reboot must be proven before the
         node is resumed: the last boot time (Win32_OperatingSystem.LastBootUpTime) must be newer than before the restart (when it cannot be read, the node must have been
         seen offline). A restart command that fails with an unexpected error, or a node that comes back without a new boot, ends the run with exit code 1 and the node stays Paused.
      4. Resume-ClusterNode -Failback <mode>: the node is Up and its roles fail back; New-MocPhysicalNode adds it to the virtual machine configuration again.
      5. Wait for the storage to repair: Get-StorageJob shows no job that is running or suspended, and every virtual disk is Healthy and OK again. Learn: it is not safe to take
         another server offline until the repair jobs finish. Run the script for the next node only after this one has ended with exit code 0.

    Reads the infrastructure file, finds the machine in nodes[], and works over PowerShell remoting from the management server. The credential is the local administrator
    (identity.local_admin, the password is a secret reference read by the toolkit's secret resolver); the LCM account (identity.active_directory.lcm_user) is the fallback when
    the local administrator is denied. -Credential replaces both. The script never asks for a credential or a value.

    Keys read from -InfrastructureFile:
        nodes[].name, nodes[].management.ip_address (and the management port of nodes[].network_adapters)   find the machine and its address
        identity.active_directory.domain_fqdn                  the node's fully qualified name (name.domain) is accepted as -TargetNode
        identity.local_admin.username and .password            the local administrator
        identity.active_directory.lcm_user.username and .password, identity.active_directory.netbios_name   the fallback account

    A -TargetNode that is not in the file is used as it is (a host name or an address).

    -WhatIf prints the plan and sends nothing to any machine.

    Exit codes: 0 done and the storage is healthy (or planned under -WhatIf); 1 it was not safe, -SkipDrain was given for a node that is not Paused, the restart failed, there is no
    proof that the node rebooted, the node did not come back, a step failed, or the storage had not repaired when -StorageRepairTimeoutMinutes ran out; 2 the file is missing or
    unusable, or no credential could be built.

    What exit code 0 means with the two documented opt-outs (the script does not end them with a different code; read the result object, which says it too):
      -SkipResume                       the node was rebooted and came back, and it is still Paused (in maintenance). It was NOT resumed, it is not in the virtual machine
                                        configuration again, and the storage was not checked (StorageRepair is NotWaited, Resumed is false). Run -ResumeOnly next.
      -StorageRepairTimeoutMinutes 0    the node was rebooted, resumed and is Up, but the storage repair was NOT waited for (StorageRepair is NotWaited). Exit code 0 does not
                                        say the storage is healthy: do not take another node offline until Get-StorageJob shows no job and every virtual disk is Healthy.
    Only a result with Resumed true and StorageRepair Repaired means that the next node is safe to take.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Reads nodes[] (name and management address), identity.active_directory.domain_fqdn, identity.local_admin (username, password reference) and identity.active_directory.lcm_user (username, password reference) with identity.active_directory.netbios_name.

.PARAMETER Credential
    Optional. The account for the remoting sessions, instead of the local administrator and LCM accounts of the file.

.PARAMETER TargetNode
    The node to reboot: host name, fully qualified name or management address.

.PARAMETER LogPath
    Optional. The log file. Default: logs\node-maintenance-reboot\<date>_<time>_<node>.log in the current folder.

.PARAMETER SkipDrain
    Reboot without draining the node (no Suspend-ClusterNode, no Remove-MocPhysicalNode). The node must already be Paused: the script reads its state first and stops with exit
    code 1, before anything is changed, when it is not. The other checks of step 0 still apply (every other node Up, every virtual disk Healthy and OK, no storage repair job
    running, and New-MocPhysicalNode present when the node is resumed).

.PARAMETER SkipResume
    Leave the node in maintenance after the reboot (no resume, no wait for the storage). Exit code 0 then means: rebooted and back, still Paused. Run again with -ResumeOnly when ready.

.PARAMETER ResumeOnly
    Skip the drain and the reboot; only resume a node that is in maintenance and wait for the storage to repair.

.PARAMETER FailbackMode
    Workload failback when the node resumes: Immediate (default), NoFailback or Policy.

.PARAMETER TimeoutSeconds
    Most seconds to wait for the node to come back.

.PARAMETER PingIntervalSeconds
    Seconds between connectivity checks while waiting.

.PARAMETER StorageRepairTimeoutMinutes
    Most minutes to wait for the storage repair jobs to finish after the resume (0 to 1440). 0 does not wait: exit code 0 then does not say the storage is healthy (StorageRepair is NotWaited), and the script says the next node must not be taken offline yet. Default: 180.

.PARAMETER StoragePollSeconds
    Seconds between two reads of the storage repair jobs while waiting (5 to 600). Default: 30.

.EXAMPLE
    ./Invoke-NodeMaintenanceReboot.ps1 -InfrastructureFile ./infrastructure.yml -TargetNode node01 -WhatIf

    Shows what would happen. Changes nothing.
#>
#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Write-Log is the logging function of the script (the secret helper tests expect this name); it does not replace a cmdlet of PowerShell 7.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password was just read through the secret resolver and only lives in memory; remoting needs a PSCredential.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [PSCredential]$Credential,
    [Parameter(Mandatory)][string]$TargetNode,
    [string]$LogPath = '',
    [switch]$SkipDrain,
    [switch]$SkipResume,
    [switch]$ResumeOnly,
    [ValidateSet('Immediate', 'NoFailback', 'Policy')][string]$FailbackMode = 'Immediate',
    [int]$TimeoutSeconds = 500,
    [int]$PingIntervalSeconds = 10,
    [ValidateRange(0, 1440)][int]$StorageRepairTimeoutMinutes = 180,
    [ValidateRange(5, 600)][int]$StoragePollSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$storagePoll = $StoragePollSeconds
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# -- Logging
$taskFolderName = 'node-maintenance-reboot'
if (-not $LogPath) {
    $logDir = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $logFile = Join-Path $logDir ('{0}_{1}_{2}.log' -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HHmmss'), ($TargetNode -replace '[^a-zA-Z0-9-]', '-'))
}
else {
    $logDir = Split-Path $LogPath
    $logFile = $LogPath
}
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } default { 'Cyan' } })
    Add-Content -Path $logFile -Value $line -WhatIf:$false
}
function Exit-Failed([string]$Message) { Write-Log $Message 'ERROR'; exit 1 }

Write-Log 'Invoke-NodeMaintenanceReboot started'
Write-Log "Target node    : $TargetNode"
Write-Log "ResumeOnly     : $ResumeOnly"
Write-Log "SkipDrain      : $SkipDrain"
Write-Log "SkipResume     : $SkipResume"
Write-Log "FailbackMode   : $FailbackMode"
Write-Log "TimeoutSeconds : $TimeoutSeconds"
Write-Log "Log            : $logFile"

# -- Config loading
if (-not (Test-Path -LiteralPath $InfrastructureFile)) {
    Write-Log "Infrastructure file not found: $InfrastructureFile" 'ERROR'
    exit 2
}
Write-Log "Loading config: $InfrastructureFile"
try { $cfg = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch {
    Write-Log "The infrastructure file could not be read: $($_.Exception.Message)" 'ERROR'
    exit 2
}
$script:SecretInfrastructure = $cfg

# -- Resolve node IP from config
$nodeHostname = $TargetNode
$nodeIp = $TargetNode
$domainFqdn = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.domain_fqdn')
$matchedNode = @(Get-AzlInfrastructureNode -Infrastructure $cfg | Where-Object {
        $_.Name -eq $TargetNode -or
        ($_.ManagementIp -and $_.ManagementIp -eq $TargetNode) -or
        ($domainFqdn -and "$($_.Name).$domainFqdn" -eq $TargetNode)
    } | Select-Object -First 1)
if ($matchedNode.Count -gt 0) {
    $nodeHostname = $matchedNode[0].Name
    if ($matchedNode[0].ManagementIp) { $nodeIp = $matchedNode[0].ManagementIp }
    Write-Log "Node resolved  : $nodeHostname ($nodeIp)"
}
else {
    Write-Log "Node '$TargetNode' not found in config - using as-is (hostname/IP passthrough)" 'WARN'
}

# -- Credential resolution
function Resolve-KeyVaultRef {
    # Reads a secret reference through the toolkit's one secret resolver (AzlSecret.psm1): any provider, no Azure CLI.
    # Returns the text, or $null when it cannot be read; the caller then falls back as before. No value is logged.
    param([string]$KvUri)
    if (-not (Get-AzlSecretProvider -Reference $KvUri)) { Write-Log '  The value is not a secret reference.' 'WARN'; return $null }
    try {
        $value = Get-AzlSecretPlainText -Reference $KvUri -Infrastructure $script:SecretInfrastructure
        Write-Log '  Secret retrieved.'
        return $value
    }
    catch { Write-Log "  The secret could not be read: $($_.Exception.Message)" 'WARN'; return $null }
}

if (-not $Credential) {
    $adminUser = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.local_admin.username')
    $adminPassUri = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.local_admin.password')
    $lcmUser = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.lcm_user.username')
    $lcmPassUri = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.lcm_user.password')
    $netbiosName = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.netbios_name')

    $localAdminCred = $null
    if ($adminUser -and $adminPassUri) {
        Write-Log 'Resolving local admin credentials from the secret reference...'
        $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
        $adminUserFull = if ($adminUser -notmatch '\\|@') { ".\$adminUser" } else { $adminUser }
        if ($adminPass) {
            $localAdminCred = New-Object PSCredential($adminUserFull, (ConvertTo-SecureString $adminPass -AsPlainText -Force))
            Write-Log "  Local admin resolved: '$adminUserFull'"
        }
    }

    $lcmCred = $null
    if ($lcmUser -and $lcmPassUri) {
        Write-Log 'Resolving LCM credentials from the secret reference...'
        $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
        $lcmUserFull = if ($lcmUser -notmatch '\\|@' -and $netbiosName) { "$netbiosName\$lcmUser" } else { $lcmUser }
        if ($lcmPass) {
            $lcmCred = New-Object PSCredential($lcmUserFull, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
            Write-Log "  LCM resolved: '$lcmUserFull'"
        }
        else {
            Write-Log '  LCM secret unavailable - LCM fallback will not be available.' 'WARN'
        }
    }

    if (-not $localAdminCred -and $lcmCred) {
        Write-Log '  Local admin unavailable - the LCM account is used.' 'WARN'
        $localAdminCred = $lcmCred
        $lcmCred = $null
    }
    if (-not $localAdminCred) {
        Write-Log 'No credential could be built: identity.local_admin (username and a readable password reference) is needed, or give -Credential.' 'ERROR'
        exit 2
    }
}
else {
    $localAdminCred = $Credential
    $lcmCred = $null
    Write-Log "Using supplied -Credential: '$($Credential.UserName)'"
}

# -- PSRemoting helper: local admin first, LCM fallback
function Invoke-NodeCommand {
    param(
        [string]$ComputerName,
        [PSCredential]$LocalAdminCred,
        [PSCredential]$LcmCred,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = $null
    )
    $params = @{ ComputerName = $ComputerName; Credential = $LocalAdminCred; ScriptBlock = $ScriptBlock; ErrorAction = 'Stop' }
    if ($ArgumentList) { $params['ArgumentList'] = $ArgumentList }
    try {
        Write-Log "  Trying local admin ($($LocalAdminCred.UserName)) on $ComputerName..."
        return Invoke-Command @params
    }
    catch {
        if ($_ -match 'Access is denied|LogonFailure|logon failure') {
            if ($LcmCred) {
                Write-Log "  Local admin denied - retrying with LCM account ($($LcmCred.UserName))..." 'WARN'
                $params['Credential'] = $LcmCred
                return Invoke-Command @params
            }
            Write-Log '  Local admin denied and no LCM credential available.' 'ERROR'
        }
        throw
    }
}
function Invoke-OnNode([scriptblock]$Block, [object[]]$Arguments = $null) {
    Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock $Block -ArgumentList $Arguments
}

# -- The remote blocks (Windows PowerShell on the node)
$CheckSafe = {
    param($NodeName, $RequiredCmdlet)
    $others = @(Get-ClusterNode | Where-Object { $_.Name -ne $NodeName -and [string]$_.State -ne 'Up' } | ForEach-Object { "$($_.Name) is $($_.State)" })
    $disks = @(Get-VirtualDisk | Where-Object { [string]$_.HealthStatus -ne 'Healthy' -or [string]$_.OperationalStatus -ne 'OK' } | ForEach-Object { "virtual disk $($_.FriendlyName) is $($_.HealthStatus)/$($_.OperationalStatus)" })
    $jobs = @(Get-StorageJob | Where-Object { [string]$_.JobState -ne 'Completed' } | ForEach-Object { "storage job $($_.Name) is $($_.JobState) at $($_.PercentComplete) percent" })
    $missing = @($RequiredCmdlet | Where-Object { $_ -and -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    @{ Problems = @($others + $disks + $jobs); MissingCmdlet = @($missing); NodeState = [string](Get-ClusterNode -Name $NodeName -ErrorAction SilentlyContinue).State }
}
$CheckResumeCmdlet = { @('New-MocPhysicalNode' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }) }
$SuspendNode = { param($NodeName) Suspend-ClusterNode -Name $NodeName -Drain -Wait -ErrorAction Stop | Out-Null; [string](Get-ClusterNode -Name $NodeName).State }
$RemoveMoc = { param($NodeName) Remove-MocPhysicalNode -NodeName $NodeName -ErrorAction Stop | Out-Null }
$RestartNode = { Restart-Computer -Force }
$ProbeNode = { [string](Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue).State }
$ReadBootTime = { (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime }
$ResumeNode = { param($NodeName, $FbMode) Resume-ClusterNode -Name $NodeName -Failback $FbMode -ErrorAction Stop | Out-Null }
$AddMoc = { param($NodeName) New-MocPhysicalNode -NodeName $NodeName -ErrorAction Stop | Out-Null; @(Get-MocPhysicalNode | ForEach-Object { [string]$_.NodeName }) }
$ReadNodeState = {
    $n = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
    [PSCustomObject]@{ Name = $n.Name; State = [string]$n.State; DrainStatus = [string]$n.DrainStatus }
}
$ReadStorage = {
    @{
        Jobs  = @(Get-StorageJob | Where-Object { [string]$_.JobState -ne 'Completed' } | ForEach-Object { "$($_.Name) $($_.JobState) $($_.PercentComplete)%" })
        Disks = @(Get-VirtualDisk | Where-Object { [string]$_.HealthStatus -ne 'Healthy' -or [string]$_.OperationalStatus -ne 'OK' } | ForEach-Object { "$($_.FriendlyName) $($_.HealthStatus)/$($_.OperationalStatus)" })
    }
}

# -- WhatIf: the plan, nothing is sent
if ($WhatIfPreference) {
    if ($ResumeOnly) {
        Write-Log "[WhatIf] Would resume cluster node    : $nodeHostname ($nodeIp) (ResumeOnly)" 'WARN'
        Write-Log "[WhatIf] Failback mode                : $FailbackMode" 'WARN'
        Write-Log "[WhatIf] Would add the node to the virtual machine configuration (New-MocPhysicalNode) and wait for the storage repair jobs" 'WARN'
    }
    else {
        if (-not $SkipDrain) { Write-Log "[WhatIf] Would check that it is safe (other nodes Up, virtual disks Healthy, no repair job running)" 'WARN' }
        else { Write-Log "[WhatIf] Would check that the node is Paused (-SkipDrain) and that it is safe (other nodes Up, virtual disks Healthy, no repair job running)" 'WARN' }
        if (-not $SkipDrain) { Write-Log "[WhatIf] Would suspend cluster node  : $nodeHostname ($nodeIp)" 'WARN' }
        if (-not $SkipDrain) { Write-Log "[WhatIf] Would remove the node from the virtual machine configuration (Remove-MocPhysicalNode)" 'WARN' }
        Write-Log "[WhatIf] Would reboot                : $nodeHostname ($nodeIp)" 'WARN'
        Write-Log "[WhatIf] Would wait up to            : $TimeoutSeconds seconds for node to return, and check that it really rebooted before it is resumed" 'WARN'
        if (-not $SkipResume) {
            Write-Log "[WhatIf] Would resume cluster node   : $nodeHostname ($nodeIp) (Failback: $FailbackMode)" 'WARN'
            Write-Log "[WhatIf] Would wait up to $StorageRepairTimeoutMinutes minutes for the storage repair jobs to finish" 'WARN'
        }
    }
    Write-Log 'WhatIf complete - no changes made' 'WARN'
    return
}
if (-not $PSCmdlet.ShouldProcess($nodeHostname, $(if ($ResumeOnly) { 'Resume the node and wait for the storage to repair' } else { 'Drain, reboot and resume the node' }))) {
    Write-Log 'Not confirmed - no changes made' 'WARN'
    return
}

function Wait-StorageRepair {
    # Learn: it is not safe to take another server offline until the repair jobs have finished and the virtual disks are Healthy again.
    if ($StorageRepairTimeoutMinutes -eq 0) {
        Write-Log 'StorageRepairTimeoutMinutes is 0: the storage repair is not waited for. Do not take another node offline until Get-StorageJob shows no job and every virtual disk is Healthy.' 'WARN'
        return 'NotWaited'
    }
    $until = (Get-Date).AddMinutes($StorageRepairTimeoutMinutes)
    while ($true) {
        $storage = Invoke-OnNode $ReadStorage
        $jobs = @($storage.Jobs); $disks = @($storage.Disks)
        if ($jobs.Count -eq 0 -and $disks.Count -eq 0) { Write-Log 'Storage is repaired: no repair job is running and every virtual disk is Healthy and OK.' 'SUCCESS'; return 'Repaired' }
        Write-Log "  Storage is repairing: $(@($jobs + $disks) -join '; ')"
        if ((Get-Date) -ge $until) { return 'Timeout' }
        Start-Sleep -Seconds $storagePoll
    }
}
function Resume-NodeAndWait {
    Write-Log "Resuming cluster node '$nodeHostname' (Failback: $FailbackMode)..."
    Invoke-OnNode $ResumeNode @($nodeHostname, $FailbackMode)
    Write-Log "Node '$nodeHostname' resumed (Failback: $FailbackMode)." 'SUCCESS'
    Write-Log 'Adding the node to the virtual machine configuration (New-MocPhysicalNode)...'
    $members = @(Invoke-OnNode $AddMoc @($nodeHostname))
    if ($members -notcontains $nodeHostname) { throw "The node '$nodeHostname' is not in the virtual machine configuration after New-MocPhysicalNode." }
    Write-Log 'The node takes virtual machines again.' 'SUCCESS'
    Write-Log 'Waiting for the storage repair jobs (Get-StorageJob)...'
    Wait-StorageRepair
}

try {
    $rebootTime = Get-Date
    $storageResult = 'NotWaited'

    # -- ResumeOnly shortcut
    if ($ResumeOnly) {
        Write-Log 'ResumeOnly mode - skipping drain and reboot'
        $missing = @(Invoke-OnNode $CheckResumeCmdlet)
        if ($missing.Count -gt 0) { Exit-Failed "The node does not have $($missing -join ', ') (Azure Local 2311.2 or later); nothing was changed." }
        $storageResult = Resume-NodeAndWait
    }
    else {
        # -- Step 0: is it safe (also with -SkipDrain: the node must already be Paused, and the cluster and the storage must still be fit for a reboot)
        $requiredCmdlet = if ($SkipDrain) { if ($SkipResume) { @() } else { @('New-MocPhysicalNode') } } else { @('Remove-MocPhysicalNode', 'New-MocPhysicalNode') }
        Write-Log 'Checking that it is safe to take the node out (other nodes Up, virtual disks Healthy, no repair job running)...'
        $safe = Invoke-OnNode $CheckSafe @($nodeHostname, @($requiredCmdlet))
        if ($SkipDrain -and [string]$safe.NodeState -ne 'Paused') {
            Exit-Failed "-SkipDrain needs a node that is already Paused (Suspend-ClusterNode -Drain), but node '$nodeHostname' is '$([string]$safe.NodeState)'. It was not rebooted and nothing was changed. Drain it first (run without -SkipDrain), or suspend it by hand."
        }
        if (@($safe.MissingCmdlet).Count -gt 0) { Exit-Failed "The node does not have $(@($safe.MissingCmdlet) -join ', ') (Azure Local 2311.2 or later); nothing was changed." }
        if (@($safe.Problems).Count -gt 0) { Exit-Failed "Not safe to take '$nodeHostname' out: $(@($safe.Problems) -join '; '). Nothing was changed. Wait for the storage repair to finish, then run again." }
        Write-Log 'It is safe.' 'SUCCESS'
        if (-not $SkipDrain) {
            # -- Step 1 and 2: suspend, drain, remove from the virtual machine configuration
            Write-Log "Suspending cluster node '$nodeHostname' (draining workloads)..."
            $state = [string](Invoke-OnNode $SuspendNode @($nodeHostname))
            if ($state -ne 'Paused') { Exit-Failed "Node '$nodeHostname' is '$state' after the drain; it should be Paused." }
            Write-Log "Node '$nodeHostname' suspended and drained." 'SUCCESS'
            Invoke-OnNode $RemoveMoc @($nodeHostname)
            Write-Log 'The node was removed from the virtual machine configuration (Remove-MocPhysicalNode).' 'SUCCESS'
        }
        else {
            Write-Log "SkipDrain specified - the node is Paused as required; Suspend-ClusterNode and Remove-MocPhysicalNode are skipped" 'WARN'
        }

        # -- Step 3: reboot. The last boot time before the restart is the proof afterwards.
        $bootBefore = $null
        try { $bootBefore = [datetime](Invoke-OnNode $ReadBootTime) }
        catch { Write-Log "  The last boot time could not be read before the restart ($($_.Exception.Message)); the node must then be seen offline." 'WARN' }
        Write-Log "Sending reboot to '$nodeHostname' ($nodeIp)..."
        try { Invoke-OnNode $RestartNode }
        catch {
            # WinRM will drop the connection mid-reboot: this is expected
            if ($_ -match 'pipeline has been stopped|connection.*closed|network|The system is shutting down') { Write-Log '  Connection dropped (expected - node is rebooting).' }
            else { Exit-Failed "Restart-Computer failed: $($_.Exception.Message). The node was not rebooted as far as the script can tell, and it stays Paused: nothing was resumed. Check the node, then run again." }
        }
        $rebootTime = Get-Date
        Write-Log "Reboot command sent at $rebootTime."

        Write-Log 'Waiting for node to go offline...'
        $sawOffline = $false
        $offlineDeadline = $rebootTime.AddSeconds(120)
        while ((Get-Date) -lt $offlineDeadline) {
            if (-not (Test-Connection -ComputerName $nodeIp -Count 1 -Quiet -ErrorAction SilentlyContinue)) { Write-Log '  Node is offline.'; $sawOffline = $true; break }
            Start-Sleep -Seconds 5
        }

        Write-Log "Waiting for node to come back online (timeout: $TimeoutSeconds seconds)..."
        $onlineDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $isOnline = $false
        while ((Get-Date) -lt $onlineDeadline) {
            $elapsed = [int]((Get-Date) - $rebootTime).TotalSeconds
            if (Test-Connection -ComputerName $nodeIp -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                Write-Log "  Node responded to ping after ${elapsed}s - verifying WinRM..."
                Start-Sleep -Seconds 15
                try {
                    $nodeState = Invoke-OnNode $ProbeNode
                    Write-Log "  WinRM responsive. Cluster node state: $nodeState" 'SUCCESS'
                    $isOnline = $true
                    break
                }
                catch { Write-Log "  Ping OK but WinRM not yet ready - retrying in $($PingIntervalSeconds)s..." 'WARN' }
            }
            else { Write-Log "  Still offline... (${elapsed}s elapsed)" }
            Start-Sleep -Seconds $PingIntervalSeconds
        }
        if (-not $isOnline) { Exit-Failed "Node '$nodeHostname' did not come back online within $TimeoutSeconds seconds." }

        # -- Proof of the reboot before anything is resumed: a newer last boot time; when a boot time cannot be compared, the node must have been seen offline.
        $bootAfter = $null
        try { $bootAfter = [datetime](Invoke-OnNode $ReadBootTime) }
        catch { Write-Log "  The last boot time could not be read after the restart ($($_.Exception.Message))." 'WARN' }
        $rebooted = if ($null -ne $bootBefore -and $null -ne $bootAfter) { $bootAfter -gt $bootBefore } else { $sawOffline }
        if (-not $rebooted) {
            Exit-Failed "There is no proof that node '$nodeHostname' rebooted: it $(if ($sawOffline) { 'was seen offline' } else { 'was never seen offline' }) and its last boot time did not change. It stays Paused and was not resumed. Check the node, reboot it, then run with -ResumeOnly."
        }
        Write-Log "The node rebooted (last boot time $(if ($null -ne $bootAfter) { $bootAfter.ToString('s') } else { 'not readable' }); seen offline: $sawOffline)." 'SUCCESS'

        # -- Step 4 and 5: resume, add to the virtual machine configuration, wait for the storage
        if (-not $SkipResume) { $storageResult = Resume-NodeAndWait }
        else { Write-Log 'SkipResume specified - the node remains Paused (in maintenance). Exit code 0 means: rebooted and back, NOT resumed, storage not checked. Run with -ResumeOnly when ready.' 'WARN' }
    }

    # -- Final validation
    Write-Log 'Validating final cluster node state...'
    $finalState = Invoke-OnNode $ReadNodeState
    Write-Log "  Node         : $($finalState.Name)"
    Write-Log "  State        : $($finalState.State)"
    Write-Log "  DrainStatus  : $($finalState.DrainStatus)"
    $expectUp = $ResumeOnly -or -not $SkipResume
    if ($expectUp -and $finalState.State -ne 'Up') { Exit-Failed "Node '$nodeHostname' state is '$($finalState.State)' - expected 'Up'." }
    if ($expectUp) { Write-Log "Node '$nodeHostname' is Up." 'SUCCESS' }
    if ($storageResult -eq 'Timeout') { Exit-Failed "The storage had not finished repairing after $StorageRepairTimeoutMinutes minutes. Do not take another node offline; check Get-StorageJob and Get-VirtualDisk." }
    Write-Log 'Invoke-NodeMaintenanceReboot complete'

    [PSCustomObject]@{
        Node          = $nodeHostname
        NodeIp        = $nodeIp
        State         = $finalState.State
        DrainStatus   = $finalState.DrainStatus
        Resumed       = [bool]$expectUp
        StorageRepair = $storageResult
        Duration      = [int]((Get-Date) - $rebootTime).TotalSeconds
    }
}
catch {
    Write-Log "Node maintenance stopped: $($_.Exception.Message)" 'ERROR'
    exit 1
}
