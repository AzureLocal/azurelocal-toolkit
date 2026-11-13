<#
.SYNOPSIS
    Suspends a cluster node (drains the workloads), reboots it, waits for it to come back, then resumes it.

.DESCRIPTION
    Reads the infrastructure file, finds the machine in nodes[], and works over PowerShell remoting from the management server.
    The credential is the local administrator (identity.local_admin, the password is a secret reference read by the toolkit's secret
    resolver); the LCM account (identity.active_directory.lcm_user) is the fallback when the local administrator is denied.
    -Credential replaces both. The script never asks for a credential or a value.

    Keys read from -InfrastructureFile:
        nodes[].name, nodes[].management.ip_address (and the management port of nodes[].network_adapters)   find the machine and its address
        identity.active_directory.domain_fqdn                  the node's fully qualified name (name.domain) is accepted as -TargetNode
        identity.local_admin.username and .password            the local administrator
        identity.active_directory.lcm_user.username and .password, identity.active_directory.netbios_name   the fallback account

    A -TargetNode that is not in the file is used as it is (a host name or an address).

    Exit codes: 0 done (or planned under -WhatIf); 1 the node did not come back, or a call failed; 2 the file is missing or unusable,
    or no credential could be built.

.PARAMETER InfrastructureFile
    Path to infrastructure.yml (schema 5). The old name -ConfigPath still works.

.PARAMETER Credential
    Use this account instead of the ones in the file.

.PARAMETER TargetNode
    Host name, fully qualified name or management address of the node to reboot.

.PARAMETER LogPath
    Log file. Default: logs\node-maintenance-reboot\<date>_<time>_<node>.log in the current folder.

.PARAMETER SkipDrain
    Reboot without Suspend-ClusterNode.

.PARAMETER SkipResume
    Leave the node in maintenance after the reboot.

.PARAMETER ResumeOnly
    Skip the drain and the reboot; only resume a node that is in maintenance.

.PARAMETER FailbackMode
    Workload failback on resume: Immediate (default), NoFailback or Policy.

.PARAMETER TimeoutSeconds
    Most seconds to wait for the node to come back.

.PARAMETER PingIntervalSeconds
    Seconds between connectivity checks while waiting.

.EXAMPLE
    ./Invoke-NodeMaintenanceReboot.ps1 -InfrastructureFile ./infrastructure.yml -TargetNode node01 -WhatIf

    Shows what would happen. Changes nothing.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][Alias('ConfigPath')][string]$InfrastructureFile,   # Path to infrastructure.yml
    [PSCredential]$Credential,                 # Override credential resolution
    [Parameter(Mandatory)][string]$TargetNode, # Required — hostname or management IP of node to reboot
    [string]$LogPath           = "",           # Override log file path

    # Behaviour overrides
    [switch]$SkipDrain,                        # Skip Suspend-ClusterNode; reboot without draining
    [switch]$SkipResume,                       # Leave node in maintenance after reboot; do not Resume-ClusterNode
    [switch]$ResumeOnly,                       # Skip drain+reboot entirely — only resume a node already in maintenance
    [ValidateSet('Immediate','NoFailback','Policy')]
    [string]$FailbackMode      = 'Immediate',  # Workload failback behaviour on resume: Immediate (default), NoFailback, Policy
    [int]$TimeoutSeconds       = 500,          # Max seconds to wait for node to come back online
    [int]$PingIntervalSeconds  = 10            # Seconds between connectivity checks during wait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# ── Logging ───────────────────────────────────────────────────────────────────
$taskFolderName = "node-maintenance-reboot"
if (-not $LogPath) {
    $logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $logFile = Join-Path $logDir ("{0}_{1}_{2}.log" -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HHmmss'), ($TargetNode -replace '[^a-zA-Z0-9-]', '-'))
} else {
    $logDir  = Split-Path $LogPath
    $logFile = $LogPath
}
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } default { 'Cyan' } })
    Add-Content -Path $logFile -Value $line -WhatIf:$false
}

Write-Log "Invoke-NodeMaintenanceReboot started"
Write-Log "Target node    : $TargetNode"
Write-Log "ResumeOnly     : $ResumeOnly"
Write-Log "SkipDrain      : $SkipDrain"
Write-Log "SkipResume     : $SkipResume"
Write-Log "FailbackMode   : $FailbackMode"
Write-Log "TimeoutSeconds : $TimeoutSeconds"
Write-Log "Log            : $logFile"

# ── Config loading ────────────────────────────────────────────────────────────
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

# ── Resolve node IP from config ───────────────────────────────────────────────
$nodeHostname = $TargetNode
$nodeIp       = $TargetNode

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
} else {
    Write-Log "Node '$TargetNode' not found in config — using as-is (hostname/IP passthrough)" 'WARN'
}

# ── Credential resolution ─────────────────────────────────────────────────────
function Resolve-KeyVaultRef {
    # Reads a secret reference through the toolkit's one secret resolver (AzlSecret.psm1): any provider, no Azure CLI.
    # Returns the text, or $null when it cannot be read; the caller then falls back as before. No value is logged.
    param([string]$KvUri)
    if (-not (Get-AzlSecretProvider -Reference $KvUri)) { Write-Log "  The value is not a secret reference." 'WARN'; return $null }
    try {
        $value = Get-AzlSecretPlainText -Reference $KvUri -Infrastructure $script:SecretInfrastructure
        Write-Log "  Secret retrieved."
        return $value
    }
    catch { Write-Log "  The secret could not be read: $($_.Exception.Message)" 'WARN'; return $null }
}

if (-not $Credential) {
    $adminUser    = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.local_admin.username')
    $adminPassUri = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.local_admin.password')
    $lcmUser      = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.lcm_user.username')
    $lcmPassUri   = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.lcm_user.password')
    $netbiosName  = [string](Get-AzlInfrastructureValue -Infrastructure $cfg -Path 'identity.active_directory.netbios_name')

    $localAdminCred = $null
    if ($adminUser -and $adminPassUri) {
        Write-Log "Resolving local admin credentials from the secret reference..."
        $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
        $adminUserFull = if ($adminUser -notmatch '\\|@') { ".\$adminUser" } else { $adminUser }
        if ($adminPass) {
            $localAdminCred = New-Object PSCredential($adminUserFull, (ConvertTo-SecureString $adminPass -AsPlainText -Force))
            Write-Log "  Local admin resolved: '$adminUserFull'"
        }
    }

    $lcmCred = $null
    if ($lcmUser -and $lcmPassUri) {
        Write-Log "Resolving LCM credentials from the secret reference..."
        $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
        $lcmUserFull = if ($lcmUser -notmatch '\\|@' -and $netbiosName) { "$netbiosName\$lcmUser" } else { $lcmUser }
        if ($lcmPass) {
            $lcmCred = New-Object PSCredential($lcmUserFull, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
            Write-Log "  LCM resolved: '$lcmUserFull'"
        } else {
            Write-Log "  LCM secret unavailable — LCM fallback will not be available." 'WARN'
        }
    }

    if (-not $localAdminCred -and $lcmCred) {
        Write-Log "  Local admin unavailable — the LCM account is used." 'WARN'
        $localAdminCred = $lcmCred
        $lcmCred        = $null
    }
    if (-not $localAdminCred) {
        Write-Log "No credential could be built: identity.local_admin (username and a readable password reference) is needed, or give -Credential." 'ERROR'
        exit 2
    }
} else {
    $localAdminCred = $Credential
    $lcmCred        = $null
    Write-Log "Using supplied -Credential: '$($Credential.UserName)'"
}

# ── PSRemoting helper — local admin first, LCM fallback ──────────────────────
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
    } catch {
        if ($_ -match 'Access is denied|LogonFailure|logon failure') {
            if ($LcmCred) {
                Write-Log "  Local admin denied — retrying with LCM account ($($LcmCred.UserName))..." 'WARN'
                $params['Credential'] = $LcmCred
                return Invoke-Command @params
            }
            Write-Log "  Local admin denied and no LCM credential available." 'ERROR'
        }
        throw
    }
}

# ── WhatIf guard ──────────────────────────────────────────────────────────────
if ($WhatIfPreference) {
    if ($ResumeOnly) {
        Write-Log "[WhatIf] Would resume cluster node    : $nodeHostname ($nodeIp) (ResumeOnly)" 'WARN'
        Write-Log "[WhatIf] Failback mode                : $FailbackMode" 'WARN'
    } else {
        Write-Log "[WhatIf] Would suspend cluster node  : $nodeHostname ($nodeIp)" 'WARN'
        Write-Log "[WhatIf] Would reboot                : $nodeHostname ($nodeIp)" 'WARN'
        Write-Log "[WhatIf] Would wait up to            : $TimeoutSeconds seconds for node to return" 'WARN'
        if (-not $SkipResume) {
            Write-Log "[WhatIf] Would resume cluster node   : $nodeHostname ($nodeIp) (Failback: $FailbackMode)" 'WARN'
        }
    }
    Write-Log "WhatIf complete — no changes made" 'WARN'
    return
}

# ── ResumeOnly shortcut ───────────────────────────────────────────────────────
if ($ResumeOnly) {
    Write-Log "ResumeOnly mode — skipping drain and reboot"
    Write-Log "Resuming cluster node '$nodeHostname' (Failback: $FailbackMode)..."
    Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
        param($NodeName, $FbMode)
        Resume-ClusterNode -Name $NodeName -Failback $FbMode -ErrorAction Stop
    } -ArgumentList $nodeHostname, $FailbackMode
    Write-Log "Node '$nodeHostname' resumed (Failback: $FailbackMode)." 'SUCCESS'

    $finalState = Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
        $node = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Name = $node.Name; State = $node.State; DrainStatus = $node.DrainStatus }
    }
    Write-Log "  Node         : $($finalState.Name)"
    Write-Log "  State        : $($finalState.State)"
    Write-Log "  DrainStatus  : $($finalState.DrainStatus)"
    Write-Log "Invoke-NodeMaintenanceReboot complete"
    return [PSCustomObject]@{ Node = $nodeHostname; NodeIp = $nodeIp; State = $finalState.State; DrainStatus = $finalState.DrainStatus; Duration = 0 }
}

# ── Step 1: Suspend (drain) cluster node ──────────────────────────────────────
if (-not $SkipDrain) {
    Write-Log "Suspending cluster node '$nodeHostname' (draining workloads)..."
    Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
        param($NodeName)
        Suspend-ClusterNode -Name $NodeName -Drain -Wait -ErrorAction Stop
    } -ArgumentList $nodeHostname
    Write-Log "Node '$nodeHostname' suspended and drained." 'SUCCESS'
} else {
    Write-Log "SkipDrain specified — skipping Suspend-ClusterNode" 'WARN'
}

# ── Step 2: Reboot ────────────────────────────────────────────────────────────
Write-Log "Sending reboot to '$nodeHostname' ($nodeIp)..."
try {
    Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
        Restart-Computer -Force
    }
} catch {
    # WinRM will drop the connection mid-reboot — this is expected
    if ($_ -match 'pipeline has been stopped|connection.*closed|network|The system is shutting down') {
        Write-Log "  Connection dropped (expected — node is rebooting)."
    } else {
        Write-Log "  Unexpected error during reboot: $_" 'WARN'
    }
}
$rebootTime = Get-Date
Write-Log "Reboot command sent at $rebootTime."

# ── Step 3: Wait for node to go offline ───────────────────────────────────────
Write-Log "Waiting for node to go offline..."
$offlineDeadline = $rebootTime.AddSeconds(120)
while ((Get-Date) -lt $offlineDeadline) {
    if (-not (Test-Connection -ComputerName $nodeIp -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Log "  Node is offline."
        break
    }
    Start-Sleep -Seconds 5
}

# ── Step 4: Wait for node to come back online ─────────────────────────────────
Write-Log "Waiting for node to come back online (timeout: $TimeoutSeconds seconds)..."
$onlineDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
$isOnline        = $false

while ((Get-Date) -lt $onlineDeadline) {
    $elapsed = [int]((Get-Date) - $rebootTime).TotalSeconds
    if (Test-Connection -ComputerName $nodeIp -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Write-Log "  Node responded to ping after ${elapsed}s — verifying WinRM..."
        # Give WinRM a few extra seconds to start
        Start-Sleep -Seconds 15
        try {
            $state = Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
                (Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue).State
            }
            Write-Log "  WinRM responsive. Cluster node state: $state" 'SUCCESS'
            $isOnline = $true
            break
        } catch {
            Write-Log "  Ping OK but WinRM not yet ready — retrying in $($PingIntervalSeconds)s..." 'WARN'
        }
    } else {
        Write-Log "  Still offline... (${elapsed}s elapsed)"
    }
    Start-Sleep -Seconds $PingIntervalSeconds
}

if (-not $isOnline) {
    Write-Log "Node '$nodeHostname' did not come back online within $TimeoutSeconds seconds." 'ERROR'
    throw "Timeout waiting for '$nodeHostname' to return online."
}

# ── Step 5: Resume cluster node ───────────────────────────────────────────────
if (-not $SkipResume) {
    Write-Log "Resuming cluster node '$nodeHostname' (Failback: $FailbackMode)..."
    Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
        param($NodeName, $FbMode)
        Resume-ClusterNode -Name $NodeName -Failback $FbMode -ErrorAction Stop
    } -ArgumentList $nodeHostname, $FailbackMode
    Write-Log "Node '$nodeHostname' resumed (Failback: $FailbackMode)." 'SUCCESS'
} else {
    Write-Log "SkipResume specified — node remains in maintenance mode. Run with -ResumeOnly when ready." 'WARN'
}

# ── Step 6: Final validation ──────────────────────────────────────────────────
Write-Log "Validating final cluster node state..."
$finalState = Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
    $node = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        Name           = $node.Name
        State          = $node.State
        DrainStatus    = $node.DrainStatus
    }
}

Write-Log "  Node         : $($finalState.Name)"
Write-Log "  State        : $($finalState.State)"
Write-Log "  DrainStatus  : $($finalState.DrainStatus)"

if ($finalState.State -eq 'Up' -or [int]$finalState.State -eq 0) {
    Write-Log "Node '$nodeHostname' is Up and healthy." 'SUCCESS'
} else {
    Write-Log "Node '$nodeHostname' state is '$($finalState.State)' — expected 'Up'." 'WARN'
}

Write-Log "Invoke-NodeMaintenanceReboot complete"

return [PSCustomObject]@{
    Node        = $nodeHostname
    NodeIp      = $nodeIp
    State       = $finalState.State
    DrainStatus = $finalState.DrainStatus
    Duration    = [int]((Get-Date) - $rebootTime).TotalSeconds
}
