# ==============================================================================
# Script : Invoke-DeploySDN-Orchestrated.ps1
# Purpose: Enable SDN integration on Azure Local by deploying Network Controller
#          as a Failover Cluster service (SDN enabled by Arc)
# Run    : From management server — reads infrastructure.yml, uses PSRemoting
# Prereqs: FailoverClusters module accessible; Azure Stack HCI Admin role on node
# WARNING: SDN enablement is IRREVERSIBLE. Once enabled, it cannot be disabled.
# ==============================================================================

[CmdletBinding()]
param(
    [string]$ConfigPath      = "",           # Path to infrastructure.yml; CWD-relative default
    [PSCredential]$Credential,               # Override credential resolution
    [string[]]$TargetNode    = @(),          # Specific node to run Add-EceFeature on; empty = first node
    [switch]$WhatIf,                         # Dry-run — validate only, no changes
    [string]$LogPath         = "",           # Override log file path

    # YAML-overridable parameters
    [string]$SdnPrefix       = $null,        # Override: networking.azure.sdn.sdn_prefix
    [string]$SdnDnsMode      = $null,        # Override: networking.azure.sdn.sdn_dns_mode (dynamic|static)
    [string]$SdnNcReservedIp = $null,        # Override: networking.azure.sdn.sdn_nc_reserved_ip
    [int]$SdnIntentPattern   = 0,            # Override: networking.azure.sdn.sdn_intent_pattern (1|2|3)
    [string]$VirtualSwitchName = "",         # Override: compute.azure_local.vm_switch_name
    [switch]$AcknowledgeDNSRecordCreation    # Skip DNS record creation confirmation (dynamic DNS)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ───────────────────────────────────────────────────────────────────
$taskFolderName = "task-01-deploy-sdn"
if (-not $LogPath) {
    $logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
    $logFile = Join-Path $logDir ("{0}_{1}_DeploySDN.log" -f (Get-Date -Format 'yyyy-MM-dd'), (Get-Date -Format 'HHmmss'))
} else {
    $logDir  = Split-Path $LogPath
    $logFile = $LogPath
}
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } })
    Add-Content -Path $logFile -Value $line
}

Write-Log "Invoke-DeploySDN-Orchestrated started"
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

# ── SDN enabled check ─────────────────────────────────────────────────────────
$sdnEnabled = $cfg.networking.azure.sdn.sdn_enabled                              # networking.azure.sdn.sdn_enabled
if (-not $sdnEnabled) {
    Write-Log "networking.azure.sdn.sdn_enabled is false — SDN deployment skipped" 'WARN'
    Write-Log "Set sdn_enabled: true in infrastructure.yml to enable SDN"
    return
}

# ── Extract values from config (with parameter overrides) ─────────────────────
$sdnPrefix     = if ($SdnPrefix)            { $SdnPrefix }       else { $cfg.networking.azure.sdn.sdn_prefix }         # networking.azure.sdn.sdn_prefix
$sdnDnsMode    = if ($SdnDnsMode)           { $SdnDnsMode }      else { $cfg.networking.azure.sdn.sdn_dns_mode }        # networking.azure.sdn.sdn_dns_mode
$sdnNcIp       = if ($SdnNcReservedIp)      { $SdnNcReservedIp } else { $cfg.networking.azure.sdn.sdn_nc_reserved_ip } # networking.azure.sdn.sdn_nc_reserved_ip
$intentPattern = if ($SdnIntentPattern -gt 0) { $SdnIntentPattern } else { [int]$cfg.networking.azure.sdn.sdn_intent_pattern } # networking.azure.sdn.sdn_intent_pattern
$vmSwitchName  = if ($VirtualSwitchName -ne "") { $VirtualSwitchName } else { $cfg.compute.azure_local.vm_switch_name }          # compute.azure_local.vm_switch_name

# ── Determine target node ─────────────────────────────────────────────────────
if ($TargetNode.Count) {
    # TargetNode supplied — look up its management_ip from config
    $matchedKey = $cfg.compute.cluster_nodes.Keys | Where-Object {
        $cfg.compute.cluster_nodes[$_].hostname -eq $TargetNode[0]
    } | Select-Object -First 1
    if ($matchedKey) {
        $nodeHostname = $cfg.compute.cluster_nodes[$matchedKey].hostname          # compute.cluster_nodes.<key>.hostname (display only)
        $nodeIp       = $cfg.compute.cluster_nodes[$matchedKey].management_ip     # compute.cluster_nodes.<key>.management_ip
    } else {
        # Accept raw IP/name if not found in config (passthrough)
        $nodeHostname = $TargetNode[0]
        $nodeIp       = $TargetNode[0]
    }
} else {
    $firstKey     = $cfg.compute.cluster_nodes.Keys | Sort-Object | Select-Object -First 1  # compute.cluster_nodes.<first-key>
    $nodeHostname = $cfg.compute.cluster_nodes[$firstKey].hostname                          # compute.cluster_nodes.<key>.hostname (display only)
    $nodeIp       = $cfg.compute.cluster_nodes[$firstKey].management_ip                     # compute.cluster_nodes.<key>.management_ip
}
if (-not $nodeIp) {
    Write-Log "management_ip missing for node '$nodeHostname' — cannot PSRemote" 'ERROR'
    throw "compute.cluster_nodes.<key>.management_ip is required for PSRemoting"
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
    # Post-deployment: nodes are domain-joined and local admin is renamed by Azure Local.
    # Try local admin first; fall back to LCM domain account on access denied.
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
} else {
    # -Credential supplied directly — use as local admin, no LCM fallback
    $localAdminCred = $Credential
    $lcmCred        = $null
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

# ── Auto-discover vSwitch if not in config ────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($vmSwitchName)) {
    Write-Log "vm_switch_name not set in config — auto-discovering from node '$node' via PSRemoting..."
    try {
        $discovered = Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
            Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' } | Select-Object -First 1 -ExpandProperty Name
        }
        if ([string]::IsNullOrWhiteSpace($discovered)) {
            Write-Log "No external vSwitch found on '$nodeHostname' ($nodeIp) — cannot proceed" 'ERROR'
            throw "No external VMSwitch found on node '$nodeHostname'. Verify the cluster networking is configured."
        }
        $vmSwitchName = $discovered
        Write-Log "Discovered vSwitch: '$vmSwitchName'"

        # Write back to config so it is populated for future runs
        if (-not $WhatIf) {
            Write-Log "Writing vm_switch_name back to config: $ConfigPath"
            $raw = Get-Content $ConfigPath -Raw
            if ($raw -match 'vm_switch_name:\s*""') {
                $raw = $raw -replace 'vm_switch_name:\s*""', "vm_switch_name: `"$vmSwitchName`""
                Set-Content $ConfigPath -Value $raw -NoNewline
                Write-Log "Config updated: vm_switch_name set to '$vmSwitchName'"
            } else {
                Write-Log "vm_switch_name entry not in expected format — skipping config write" 'WARN'
            }
        } else {
            Write-Log "[WhatIf] Would write vm_switch_name '$vmSwitchName' back to config" 'WARN'
        }
    } catch {
        Write-Log "vSwitch auto-discovery failed: $($_.Exception.Message)" 'ERROR'
        throw
    }
} else {
    Write-Log "vSwitch from config: '$vmSwitchName'"
}

Write-Log "SDN Prefix      : $sdnPrefix"
Write-Log "DNS Mode        : $sdnDnsMode"
Write-Log "Intent Pattern  : $intentPattern"
Write-Log "vSwitch Name    : $vmSwitchName"
Write-Log "Target Node     : $nodeHostname ($nodeIp)"

# ── Validate SDN prefix format ────────────────────────────────────────────────
Write-Log "Validating SDN prefix..."
if ([string]::IsNullOrWhiteSpace($sdnPrefix)) {
    Write-Log "sdn_prefix is null or empty" 'ERROR'
    throw "SDN prefix is required"
}
if ($sdnPrefix.Length -gt 8) {
    Write-Log "sdn_prefix '$sdnPrefix' exceeds 8 characters (length: $($sdnPrefix.Length))" 'ERROR'
    throw "SDN prefix must be 8 characters or fewer"
}
if ($sdnPrefix -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$' -or $sdnPrefix -match '--') {
    Write-Log "sdn_prefix '$sdnPrefix' contains invalid characters or consecutive hyphens" 'ERROR'
    throw "SDN prefix must contain only alphanumeric characters and hyphens (no consecutive hyphens, no trailing hyphen)"
}
Write-Log "SDN prefix validation passed: '$sdnPrefix'"

# ── Validate intent pattern ───────────────────────────────────────────────────
if ($intentPattern -notin 1, 2, 3) {
    Write-Log "sdn_intent_pattern must be 1, 2, or 3 (got: $intentPattern)" 'ERROR'
    throw "Invalid sdn_intent_pattern: $intentPattern"
}
Write-Log "Intent pattern: $intentPattern"

# ── DNS validation (static environments) ─────────────────────────────────────
$ncRecordName = "$sdnPrefix-NC"
if ($sdnDnsMode -eq 'static') {
    Write-Log "Static DNS mode — validating DNS record: $ncRecordName"
    if (-not $sdnNcIp) {
        Write-Log "sdn_nc_reserved_ip is required for static DNS mode" 'ERROR'
        throw "sdn_nc_reserved_ip must be set when sdn_dns_mode is 'static'"
    }
    try {
        $resolved   = Resolve-DnsName $ncRecordName -ErrorAction Stop
        $resolvedIp = ($resolved | Where-Object QueryType -eq 'A' | Select-Object -First 1).IPAddress
        if ($resolvedIp -ne $sdnNcIp) {
            Write-Log "DNS record '$ncRecordName' resolves to '$resolvedIp' but expected '$sdnNcIp'" 'WARN'
        } else {
            Write-Log "DNS record '$ncRecordName' resolves correctly to '$resolvedIp'"
        }
    } catch {
        Write-Log "DNS record '$ncRecordName' does not resolve — create the A record before proceeding" 'ERROR'
        throw "DNS A record '$ncRecordName' not found. Create it pointing to '$sdnNcIp' before enabling SDN."
    }
} else {
    Write-Log "Dynamic DNS mode — no pre-created DNS record required"
}

# ── WhatIf guard ──────────────────────────────────────────────────────────────
if ($WhatIf) {
    Write-Log "[WhatIf] Would run: Add-EceFeature -Name NC -SDNPrefix '$sdnPrefix' -VirtualSwitchName '$vmSwitchName' on node '$nodeHostname' ($nodeIp)" 'WARN'
    Write-Log "[WhatIf] DNS mode   : $sdnDnsMode"
    Write-Log "[WhatIf] NC record  : $ncRecordName"
    Write-Log "[WhatIf] Intent     : $intentPattern"
    Write-Log "[WhatIf] vSwitch    : $vmSwitchName"
    Write-Log "WhatIf complete — no changes made" 'WARN'
    return
}

# ── IRREVERSIBILITY WARNING ───────────────────────────────────────────────────
Write-Log "-------------------------------------------------------------------" 'WARN'
Write-Log "WARNING: SDN enablement is IRREVERSIBLE. Network Controller cannot" 'WARN'
Write-Log "         be removed after this operation completes." 'WARN'
Write-Log "         This will also cause a brief network disruption on all"    'WARN'
Write-Log "         existing workloads while VFP policies are applied."        'WARN'
Write-Log "-------------------------------------------------------------------" 'WARN'

# ── Run Add-EceFeature via PSRemoting ─────────────────────────────────────────
Write-Log "Enabling SDN on node '$nodeHostname' ($nodeIp) — this may take up to 20 minutes..."

$featureParams = @{
    Name                         = 'NC'
    SDNPrefix                    = $sdnPrefix
    AcknowledgeMaintenanceWindow = $true  # Always pass — running this script is the acknowledgment
    AcknowledgeDNSRecordCreation = $true  # Always pass — PSRemoting has no interactive console
}

$result = Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
    param($FeatureParams)
    try {
        $outcome = Add-EceFeature @FeatureParams
        return [PSCustomObject]@{ Success = $true; Outcome = $outcome }
    } catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
} -ArgumentList $featureParams

# ── Results ───────────────────────────────────────────────────────────────────
if ($result.Success) {
    Write-Log "Add-EceFeature completed successfully"
    Write-Log "Validating Network Controller cluster group..."

    $ncGroup = Invoke-NodeCommand -ComputerName $nodeIp -LocalAdminCred $localAdminCred -LcmCred $lcmCred -ScriptBlock {
        Get-ClusterGroup | Where-Object { $_.Name -match 'Network Controller' }
    }

    if ($ncGroup) {
        Write-Log "  NC Cluster Group : $($ncGroup.Name)"
        Write-Log "  State            : $($ncGroup.State)"
        if ($ncGroup.State -ne 'Online') {
            Write-Log "  NC group state is '$($ncGroup.State)' — expected Online" 'WARN'
        }
    } else {
        Write-Log "  Network Controller cluster group not found — review Add-EceFeature output" 'WARN'
    }

    Write-Log "SDN deployment complete"
} else {
    Write-Log "Add-EceFeature failed: $($result.Error)" 'ERROR'
    throw $result.Error
}

Write-Log "Invoke-DeploySDN-Orchestrated complete"

return [PSCustomObject]@{
    Node      = $nodeHostname
    NodeIp    = $nodeIp
    SdnPrefix = $sdnPrefix
    NcRecord  = $ncRecordName
    Success   = $result.Success
}
