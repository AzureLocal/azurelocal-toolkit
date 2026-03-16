# ==============================================================================
# Script : Invoke-NodeMaintenanceReboot.ps1
# Purpose: Suspend a cluster node (drain workloads), reboot it, wait for it to
#          come back online, then optionally resume it in the cluster.
# Run    : From management server — reads infrastructure.yml, uses PSRemoting
# Prereqs: FailoverClusters module on target node; KV access for credentials
# ==============================================================================

[CmdletBinding()]
param(
    [string]$ConfigPath        = "",           # Path to infrastructure.yml; CWD-relative default
    [PSCredential]$Credential,                 # Override credential resolution
    [Parameter(Mandatory)][string]$TargetNode, # Required — hostname or management IP of node to reboot
    [switch]$WhatIf,                           # Dry-run — validate only, no changes
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

# ── Logging ───────────────────────────────────────────────────────────────────
$taskFolderName = "node-maintenance-reboot"
if (-not $LogPath) {
    $logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $logFile = Join-Path $logDir ("{0}_{1}_{2}.log" -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HHmmss'), ($TargetNode -replace '[^a-zA-Z0-9-]', '-'))
} else {
    $logDir  = Split-Path $LogPath
    $logFile = $LogPath
}
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } default { 'Cyan' } })
    Add-Content -Path $logFile -Value $line
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
if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Get-Location).Path "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config file not found: $ConfigPath" 'ERROR'
    throw "Config file not found: $ConfigPath"
}
Write-Log "Loading config: $ConfigPath"
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

# ── Resolve node IP from config ───────────────────────────────────────────────
$nodeHostname = $TargetNode
$nodeIp       = $TargetNode

$matchedKey = $cfg.compute.cluster_nodes.Keys | Where-Object {
    $cfg.compute.cluster_nodes[$_].hostname -eq $TargetNode -or
    $cfg.compute.cluster_nodes[$_].management_ip -eq $TargetNode -or
    $cfg.compute.cluster_nodes[$_].fqdn -eq $TargetNode
} | Select-Object -First 1

if ($matchedKey) {
    $nodeHostname = $cfg.compute.cluster_nodes[$matchedKey].hostname          # compute.cluster_nodes.<key>.hostname
    $nodeIp       = $cfg.compute.cluster_nodes[$matchedKey].management_ip     # compute.cluster_nodes.<key>.management_ip
    Write-Log "Node resolved  : $nodeHostname ($nodeIp)"
} else {
    Write-Log "Node '$TargetNode' not found in config — using as-is (hostname/IP passthrough)" 'WARN'
}

# ── Credential resolution ─────────────────────────────────────────────────────
function Resolve-KeyVaultRef {
    param([string]$KvUri)
    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { Write-Log "  Not a Key Vault URI: $KvUri" 'WARN'; return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]
    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Write-Log "  Retrieving '$secretName' from '$vaultName' (Az.KeyVault)..."
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { Write-Log "  Secret retrieved."; return $secret }
            Write-Log "  Az.KeyVault returned no secret." 'WARN'
        } catch { Write-Log "  Az.KeyVault failed: $_" 'WARN' }
        Write-Log "  Falling back to Azure CLI..." 'WARN'
    } else { Write-Log "  Az.KeyVault not found — trying Azure CLI..." 'WARN' }
    try {
        $azCmd = Get-Command az -ErrorAction SilentlyContinue
        if (-not $azCmd) { Write-Log "  Azure CLI not found." 'WARN'; return $null }
        Write-Log "  Retrieving '$secretName' from '$vaultName' (az CLI)..."
        $tmpErr = [System.IO.Path]::GetTempFileName()
        $val    = (& az keyvault secret show --vault-name $vaultName --name $secretName --query value --output tsv --only-show-errors 2>$tmpErr)
        $azErr  = (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue).Trim()
        Remove-Item $tmpErr -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($val)) {
            Write-Log "  az CLI failed$(if ($azErr) { ": $azErr" } else { " (exit $LASTEXITCODE)" })." 'WARN'
            return $null
        }
        Write-Log "  Secret retrieved (az CLI)."
        return $val
    } catch { Write-Log "  az CLI failed: $_" 'WARN'; return $null }
}

if (-not $Credential) {
    $adminUser    = $cfg.identity.accounts.account_local_admin_username          # identity.accounts.account_local_admin_username
    $adminPassUri = $cfg.identity.accounts.account_local_admin_password          # identity.accounts.account_local_admin_password
    $lcmUser      = $cfg.identity.accounts.account_lcm_username                  # identity.accounts.account_lcm_username
    $lcmPassUri   = $cfg.identity.accounts.account_lcm_password                  # identity.accounts.account_lcm_password
    $netbiosName  = $cfg.identity.active_directory.ad_netbios_name               # identity.active_directory.ad_netbios_name

    Write-Log "Resolving local admin credentials from Key Vault..."
    $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
    $adminUserFull = if ($adminUser -notmatch '\\|@') { ".\$adminUser" } else { $adminUser }
    if ($adminPass) {
        $localAdminCred = New-Object PSCredential($adminUserFull, (ConvertTo-SecureString $adminPass -AsPlainText -Force))
        Write-Log "  Local admin resolved: '$adminUserFull'"
    } else {
        Write-Log "  Key Vault unavailable — prompting for local admin credentials." 'WARN'
        $localAdminCred = Get-Credential -Message "Enter local Administrator credentials" -UserName $adminUserFull
    }

    Write-Log "Resolving LCM credentials from Key Vault..."
    $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
    $lcmUserFull = if ($lcmUser -notmatch '\\|@') { "$netbiosName\$lcmUser" } else { $lcmUser }
    if ($lcmPass) {
        $lcmCred = New-Object PSCredential($lcmUserFull, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
        Write-Log "  LCM resolved: '$lcmUserFull'"
    } else {
        Write-Log "  LCM secret unavailable — LCM fallback will not be available." 'WARN'
        $lcmCred = $null
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
if ($WhatIf) {
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
