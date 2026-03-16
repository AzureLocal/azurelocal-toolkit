# ==============================================================================
# Script : Get-VirtualSwitchName.ps1
# Purpose: Discover the external vSwitch name on the first cluster node and
#          write it back to infrastructure.yml at compute.azure_local.vm_switch_name
# Run    : From the repo root before running Invoke-DeploySDN-Orchestrated.ps1
# ==============================================================================

[CmdletBinding()]
param(
    [string]$ConfigPath  = "",    # Path to infrastructure.yml; CWD-relative default
    [PSCredential]$Credential,    # Override credential resolution
    [switch]$WhatIf               # Show what would be written — no config changes made
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ───────────────────────────────────────────────────────────────────
$taskFolderName = "task-01-deploy-sdn"
$logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
$logFile = Join-Path $logDir ("{0}_{1}_GetVirtualSwitchName.log" -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HHmmss'))
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } })
    Add-Content -Path $logFile -Value $line
}

Write-Log "Get-VirtualSwitchName started"
Write-Log "Log: $logFile"

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

# ── Check if already populated ────────────────────────────────────────────────
$existing = $cfg.compute.azure_local.vm_switch_name    # compute.azure_local.vm_switch_name
if ($existing -and $existing -ne "") {
    Write-Log "vm_switch_name is already set: '$existing'"
    Write-Host "`n  vm_switch_name: `"$existing`"`n" -ForegroundColor Green
    Write-Log "Nothing to do — use -WhatIf to preview or update config manually to override"
    return
}

# ── Determine target node ─────────────────────────────────────────────────────
$nodeKey  = $cfg.compute.cluster_nodes.Keys | Sort-Object | Select-Object -First 1   # compute.cluster_nodes
$nodeObj  = $cfg.compute.cluster_nodes[$nodeKey]
$hostname = $nodeObj.hostname                                                          # compute.cluster_nodes.<key>.hostname (display only)
$ip       = $nodeObj.management_ip                                                     # compute.cluster_nodes.<key>.management_ip

if (-not $ip) {
    Write-Log "management_ip missing for first cluster node — cannot PSRemote" 'ERROR'
    throw "compute.cluster_nodes.$nodeKey.management_ip is required"
}
Write-Log "Target node: $hostname ($ip)"

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

# Resolve both credentials upfront.
# Azure Local deployment renames the built-in local admin — after deployment
# the LCM account becomes the active local administrator. Try local admin first
# and fall back to LCM automatically on access denied.
if ($Credential) {
    $localAdminCred = $Credential
    $lcmCred        = $null
    Write-Log "Using supplied -Credential: $($Credential.UserName)"
} else {
    $adminUser    = $cfg.identity.accounts.account_local_admin_username          # identity.accounts.account_local_admin_username
    $adminPassUri = $cfg.identity.accounts.account_local_admin_password          # identity.accounts.account_local_admin_password
    $lcmUser      = $cfg.identity.accounts.account_lcm_username                  # identity.accounts.account_lcm_username
    $lcmPassUri   = $cfg.identity.accounts.account_lcm_password                  # identity.accounts.account_lcm_password
    $netbiosName  = $cfg.identity.active_directory.ad_netbios_name               # identity.active_directory.ad_netbios_name

    Write-Log "Resolving local admin credentials from Key Vault..."
    $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
    # Local admin: prefix with .\ for WinRM NTLM auth over IP (local account)
    $adminUserFull = if ($adminUser -notmatch '\\|@') { ".\$adminUser" } else { $adminUser }
    if ($adminPass) {
        $localAdminCred = New-Object PSCredential($adminUserFull, (ConvertTo-SecureString $adminPass -AsPlainText -Force))
        Write-Log "  Local admin resolved for '$adminUserFull'."
    } else {
        Write-Log "  Key Vault unavailable — prompting for local admin credentials." 'WARN'
        $localAdminCred = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $adminUserFull
    }

    Write-Log "Resolving LCM credentials from Key Vault..."
    $lcmPass = Resolve-KeyVaultRef -KvUri $lcmPassUri
    # LCM account is a domain account — prefix with NETBIOS\ for Kerberos/NTLM auth
    $lcmUserFull = if ($lcmUser -notmatch '\\|@') { "$netbiosName\$lcmUser" } else { $lcmUser }
    if ($lcmPass) {
        $lcmCred = New-Object PSCredential($lcmUserFull, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
        Write-Log "  LCM resolved for '$lcmUserFull'."
    } else {
        Write-Log "  LCM secret unavailable — LCM fallback will not be available." 'WARN'
        $lcmCred = $null
    }
}

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
        Write-Log "  Trying local admin ($($LocalAdminCred.UserName))..."
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

# ── Discover vSwitch via PSRemoting ───────────────────────────────────────────
Write-Log "PSRemoting to '$hostname' ($ip) to discover external vSwitch..."

try {
    $discoveredName = Invoke-NodeCommand -ComputerName $ip -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
        $sw = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' } | Select-Object -First 1
        if (-not $sw) { throw "No external vSwitch found on this node" }
        $sw.Name
    }
} catch {
    Write-Log "Failed to discover vSwitch on '$hostname' ($ip): $_" 'ERROR'
    throw
}

if (-not $discoveredName -or $discoveredName -eq "") {
    Write-Log "No external vSwitch returned from '$hostname' ($ip)" 'ERROR'
    throw "vSwitch discovery returned empty result"
}

Write-Log "Discovered vSwitch: '$discoveredName'"
Write-Host "`n  vm_switch_name: `"$discoveredName`"`n" -ForegroundColor Green

# ── Write back to config ──────────────────────────────────────────────────────
if ($WhatIf) {
    Write-Log "[WhatIf] Would write vm_switch_name: `"$discoveredName`" to $ConfigPath"
    Write-Host "[WhatIf] No changes made." -ForegroundColor Yellow
    return
}

Write-Log "Writing vm_switch_name back to config: $ConfigPath"
$raw = Get-Content $ConfigPath -Raw

if ($raw -match 'vm_switch_name:\s*""') {
    $updated = $raw -replace 'vm_switch_name:\s*""', "vm_switch_name: `"$discoveredName`""
    Set-Content -Path $ConfigPath -Value $updated -NoNewline
    Write-Log "Config updated successfully: vm_switch_name = `"$discoveredName`""
    Write-Host "Config updated: $ConfigPath" -ForegroundColor Green
} else {
    Write-Log "Could not find 'vm_switch_name: `"`"' in config — update manually" 'WARN'
    Write-Host "[WARN] Could not auto-update config. Set this manually:" -ForegroundColor Yellow
    Write-Host "  vm_switch_name: `"$discoveredName`"" -ForegroundColor Yellow
}

Write-Log "Get-VirtualSwitchName completed"
