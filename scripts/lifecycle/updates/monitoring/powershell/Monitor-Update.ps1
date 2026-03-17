#Requires -Version 7.0

<#
.SYNOPSIS
    Monitor-Update.ps1
    Real-time dashboard for Azure Local cluster update monitoring with hierarchical step
    tree, progress percentage, and live log file streaming.

.DESCRIPTION
    Provides a full-screen dashboard view while an Azure Local cluster update is running:
    - Update summary (current state, available version, applied version) from updateSummaries API
    - Active update run progress from updateRuns API — hierarchical step tree with durations
    - Overall percent complete from the update run
    - Real-time tail of SolutionUpdate / OrchestratorFull / CAU logs from nodes via PSRemoting
    - Node connectivity status with graceful reconnect on reboots
    - Auto-exits on update completion (success or failure)

    Run after triggering an update from the Azure Portal or via PowerShell.
    Press Ctrl+C to exit at any time.

    Credential Resolution Order (node access):
      1. -LocalAdminUsername + -LocalAdminPassword parameters
      2. Key Vault: -KeyVaultName with username/password secret names
      3. Interactive Read-Host prompt

    Azure Authentication Order:
      1. -SPNClientId + -SPNClientSecret parameters
      2. Key Vault: SPN credentials via -SPNClientIdSecretName / -SPNClientSecretSecretName
      3. Existing Connect-AzAccount / Get-AzContext

.PARAMETER ConfigPath
    Path to the infrastructure YAML config file (e.g. config/infrastructure-azl-lab.yml).
    When supplied, ResourceGroupName, ClusterName, SubscriptionId, TenantId, NodeIPs,
    KeyVaultName, and credentials are all resolved automatically from the config.
    Any explicitly supplied parameters override the config values.

.PARAMETER ResourceGroupName
    Resource group containing the cluster. (azure_platform.resource_group_name)
    Auto-resolved from ConfigPath if not supplied.

.PARAMETER ClusterName
    Name of the Azure Local cluster. (compute.azure_local.cluster_name)
    Auto-resolved from ConfigPath if not supplied.

.PARAMETER SubscriptionId
    Azure subscription ID. (azure_platform.azure_identity.azure_subscription_id)
    Auto-resolved from ConfigPath if not supplied.

.PARAMETER NodeIPs
    Node management IPs for PSRemoting log access. (compute.cluster_nodes[*].management_ip)
    Auto-resolved from ConfigPath if not supplied.

.PARAMETER LocalAdminUsername
    Local admin username for PSRemoting. (identity.accounts.account_local_admin_username)
    Auto-resolved from ConfigPath if not supplied.

.PARAMETER LocalAdminPassword
    Local admin password as SecureString. (identity.accounts.account_local_admin_password)
    Auto-resolved from ConfigPath if not supplied.

.PARAMETER KeyVaultName
    Key Vault name for credential resolution. (security.keyvault.platform_keyvault_name)
    Auto-resolved from ConfigPath if not supplied.

.PARAMETER KeyVaultSubscriptionId
    Subscription ID where Key Vault resides. Defaults to SubscriptionId if not set.

.PARAMETER TenantId
    Azure AD tenant ID for SPN authentication. (azure_platform.azure_tenants[*].aztenant_id)

.PARAMETER SPNClientId
    Service Principal app/client ID. If omitted, retrieved from Key Vault.

.PARAMETER SPNClientSecret
    Service Principal client secret (SecureString). If omitted, retrieved from Key Vault.

.PARAMETER SPNClientIdSecretName
    Key Vault secret name for SPN client ID (default: sp-azurelocal-client-id).

.PARAMETER SPNClientSecretSecretName
    Key Vault secret name for SPN client secret (default: sp-azurelocal-client-secret).

.PARAMETER LocalAdminUsernameSecretName
    Key Vault secret name for local admin username (default: local-admin-username).

.PARAMETER LocalAdminPasswordSecretName
    Key Vault secret name for local admin password (default: local-admin-password).

.PARAMETER UpdateName
    Specific update package name to monitor (e.g., SBE4.2.2512.1616). When omitted, the
    monitor auto-discovers the currently Installing update in the cluster.

.PARAMETER UpdateRunName
    Specific update run GUID to monitor within the update. When omitted, the monitor
    auto-discovers the latest InProgress or most-recent run under the active update.

.PARAMETER LogBasePath
    Base path for update logs on nodes (default: C:\CloudDeployment\Logs).

.PARAMETER RefreshInterval
    Seconds between dashboard refreshes (default: 30).

.PARAMETER LogTailLines
    Number of recent log lines to display (default: 10).

.EXAMPLE
    # Simplest — supply config path only; everything resolved automatically
    .\Monitor-Update.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml

.EXAMPLE
    # Config-driven but override the refresh rate
    .\Monitor-Update.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -RefreshInterval 60

.EXAMPLE
    # Monitor a specific update run by name
    .\Monitor-Update.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -UpdateRunName "<run-guid>"

.EXAMPLE
    # Manual parameter mode (no config file)
    .\Monitor-Update.ps1 `
        -ResourceGroupName "rg-iic-azurelocal-prod" `
        -ClusterName "iic-clus01" `
        -SubscriptionId "<SUBSCRIPTION_ID>" `
        -NodeIPs @("10.10.1.11","10.10.1.12","10.10.1.13") `
        -KeyVaultName "kv-iic-platform"

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        lifecycle/updates
    Task:         Monitor — run while update is in progress (portal or PowerShell triggered)
    Execution:    Run from any machine with PS 7+, Az module, and network access to node IPs
    Requires:     PowerShell 7+, Az module, Azure CLI
    Run after:    Triggering an update via Azure Portal (Cluster > Updates > Apply) or
                  via Invoke-AzureStackHCIUpdate / Start-AzureStackHCIUpdate
    API:          microsoft.azurestackhci/clusters/updateRuns       (2024-04-01)
                  microsoft.azurestackhci/clusters/updateSummaries  (2024-04-01)
#>

[CmdletBinding()]
param(
    # --- Config file (drives all values below) ---
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",      # Path to infrastructure.yml; all other params auto-resolved from this

    # --- Cluster / Environment (auto-resolved from config; override here if needed) ---
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "",   # azure_platform.resource_group_name

    [Parameter(Mandatory = $false)]
    [string]$ClusterName = "",         # compute.azure_local.cluster_name

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "",      # azure_platform.azure_identity.azure_subscription_id

    [Parameter(Mandatory = $false)]
    [string[]]$NodeIPs = @(),          # compute.cluster_nodes[*].management_ip

    # --- Node credentials (direct — tier 1, override; tier 2 = KV from config) ---
    [Parameter(Mandatory = $false)]
    [string]$LocalAdminUsername,       # identity.accounts.account_local_admin_username

    [Parameter(Mandatory = $false)]
    [securestring]$LocalAdminPassword,

    # --- Key Vault (auto-resolved from config; override here if needed) ---
    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName = "",        # security.keyvault.platform_keyvault_name

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultSubscriptionId = "",

    [Parameter(Mandatory = $false)]
    [string]$LocalAdminUsernameSecretName = "local-admin-username",

    [Parameter(Mandatory = $false)]
    [string]$LocalAdminPasswordSecretName = "local-admin-password",

    # --- SPN Authentication ---
    [Parameter(Mandatory = $false)]
    [string]$TenantId = "",        # azure_platform.azure_tenants[*].aztenant_id

    [Parameter(Mandatory = $false)]
    [string]$SPNClientId,

    [Parameter(Mandatory = $false)]
    [securestring]$SPNClientSecret,

    [Parameter(Mandatory = $false)]
    [string]$SPNClientIdSecretName = "sp-azurelocal-client-id",

    [Parameter(Mandatory = $false)]
    [string]$SPNClientSecretSecretName = "sp-azurelocal-client-secret",

    # --- Update ---
    [Parameter(Mandatory = $false)]
    [string]$UpdateName = "",      # Specific update package name (e.g. SBE4.2.2512.1616); auto-discovered if empty

    [Parameter(Mandatory = $false)]
    [string]$UpdateRunName = "",   # Specific run GUID within the update; auto-discovered if empty

    # --- Display ---
    [Parameter(Mandatory = $false)]
    [string]$LogBasePath = "C:\CloudDeployment\Logs",

    [Parameter(Mandatory = $false)]
    [int]$RefreshInterval = 30,

    [Parameter(Mandatory = $false)]
    [int]$LogTailLines = 10
)

$ErrorActionPreference = 'SilentlyContinue'

# =============================================================================
# CONFIG LOADING (infrastructure.yml -> auto-resolve all required values)
# =============================================================================
if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "  [ERROR] Config file not found: $ConfigPath" -ForegroundColor Red; exit 1
    }
    Write-Host "`n  Loading config: $ConfigPath" -ForegroundColor Gray
    if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
        Write-Host "  [ERROR] powershell-yaml module required. Install with: Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Red; exit 1
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

    # Cluster identity — override only if param not explicitly provided
    if (-not $ResourceGroupName) { $ResourceGroupName = $cfg.azure_platform.resource_group_name }                                      # azure_platform.resource_group_name
    if (-not $ClusterName)       { $ClusterName       = $cfg.compute.azure_local.cluster_name }                                        # compute.azure_local.cluster_name
    if (-not $SubscriptionId)    { $SubscriptionId    = $cfg.azure_platform.subscriptions.lab.id }                                    # azure_platform.subscriptions.lab.id
    if (-not $TenantId)          { $TenantId          = $cfg.azure_platform.tenant.id }                                                # azure_platform.tenant.id

    # Key Vault — resolve from security section
    if (-not $KeyVaultName)      { $KeyVaultName      = $cfg.security.keyvault.platform_keyvault_name }                                # security.keyvault.platform_keyvault_name

    # Node IPs — collect all management_ip values from compute.cluster_nodes[*]
    if ($NodeIPs.Count -eq 0 -and $cfg.compute.cluster_nodes) {
        $NodeIPs = @(
            $cfg.compute.cluster_nodes.Keys | Sort-Object | ForEach-Object {
                $ip = $cfg.compute.cluster_nodes[$_].management_ip                                                                     # compute.cluster_nodes.<key>.management_ip
                if ($ip -and $ip -notmatch 'None|N/A') { $ip }
            }
        )
    }

    # Local admin credentials — resolve from identity section
    if (-not $LocalAdminUsername) {
        $LocalAdminUsername = $cfg.identity.accounts.account_local_admin_username                                                      # identity.accounts.account_local_admin_username
    }
    # If password is a keyvault:// URI, extract vault name + secret name for KV lookup
    if (-not $LocalAdminPassword) {
        $rawPwd = $cfg.identity.accounts.account_local_admin_password                                                                  # identity.accounts.account_local_admin_password
        if ($rawPwd -match '^keyvault://([^/]+)/(.+)$') {
            if (-not $KeyVaultName) { $KeyVaultName = $Matches[1] }
            $LocalAdminPasswordSecretName = $Matches[2]   # e.g. local-admin-password
        } elseif ($rawPwd) {
            $LocalAdminPassword = ConvertTo-SecureString $rawPwd -AsPlainText -Force
        }
    }

    # LCM domain credentials (primary for domain-joined nodes)
    $script:LcmUsername       = $cfg.identity.accounts.account_lcm_username                                                           # identity.accounts.account_lcm_username
    $script:LcmPasswordUri    = $cfg.identity.accounts.account_lcm_password                                                           # identity.accounts.account_lcm_password
    $script:NetbiosName       = $cfg.identity.active_directory.ad_netbios_name                                                        # identity.active_directory.ad_netbios_name
    # Parse the KV URI for the LCM secret name
    if ($script:LcmPasswordUri -match '^keyvault://([^/]+)/(.+)$') {
        $script:LcmKvName         = $Matches[1]
        $script:LcmPasswordSecret = $Matches[2]   # e.g. lcm-deployment-password
    }

    Write-Host "  [OK] Config loaded" -ForegroundColor Green
    Write-Host "       RG           : $ResourceGroupName" -ForegroundColor Gray
    Write-Host "       Cluster      : $ClusterName"       -ForegroundColor Gray
    Write-Host "       Subscription : $SubscriptionId"    -ForegroundColor Gray
    Write-Host "       KeyVault     : $KeyVaultName"      -ForegroundColor Gray
    Write-Host "       NodeIPs      : $($NodeIPs -join ', ')" -ForegroundColor Gray
}

# Validate required values are now set (either from config or params)
if (-not $ResourceGroupName) { Write-Host "  [ERROR] ResourceGroupName required (supply -ConfigPath or -ResourceGroupName)" -ForegroundColor Red; exit 1 }
if (-not $ClusterName)       { Write-Host "  [ERROR] ClusterName required (supply -ConfigPath or -ClusterName)"           -ForegroundColor Red; exit 1 }
if (-not $SubscriptionId)    { Write-Host "  [ERROR] SubscriptionId required (supply -ConfigPath or -SubscriptionId)"     -ForegroundColor Red; exit 1 }

# --- NodeIPs validation: filter empty strings, warn if none provided ---
$NodeIPs = @($NodeIPs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($NodeIPs.Count -eq 0) {
    Write-Host "`n  [WARN] No valid NodeIPs resolved — log monitoring will be disabled." -ForegroundColor Yellow
    Write-Host "  Dashboard will show Azure API status only (no live log tailing).`n" -ForegroundColor Yellow
}

if (-not $KeyVaultSubscriptionId) { $KeyVaultSubscriptionId = $SubscriptionId }

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Test-NodeConnectivity {
    param([string]$NodeIP, [int]$TimeoutSeconds = 5)
    try { return Test-Connection -ComputerName $NodeIP -Count 1 -Quiet -TimeoutSeconds $TimeoutSeconds -ErrorAction Stop }
    catch { return $false }
}

function Get-NodeCredential {
    param(
        [string]$Username, [securestring]$Password,
        [string]$KeyVaultName, [string]$KeyVaultSubscriptionId,
        [string]$UsernameSecret, [string]$PasswordSecret
    )
    # Tier 1: Direct parameters
    if ($Username -and $Password) {
        Write-Host "  [INFO] Using credentials supplied via parameters" -ForegroundColor Cyan
        return New-Object System.Management.Automation.PSCredential($Username, $Password)
    }
    # Tier 2: Key Vault
    if ($KeyVaultName) {
        try {
            Write-Host "  [INFO] Retrieving credentials from Key Vault '$KeyVaultName'..." -ForegroundColor Cyan
            $ctx = Get-AzContext
            if ($ctx.Subscription.Id -ne $KeyVaultSubscriptionId) {
                Set-AzContext -SubscriptionId $KeyVaultSubscriptionId -ErrorAction Stop | Out-Null
            }
            $kvUser = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $UsernameSecret -AsPlainText -ErrorAction SilentlyContinue
            if (-not $kvUser) {
                $kvUser = "Administrator"
                Write-Host "  [INFO] Username secret '$UsernameSecret' not found in KV — defaulting to '$kvUser'" -ForegroundColor Yellow
            }
            $kvPass = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $PasswordSecret -AsPlainText -ErrorAction Stop
            if ($ctx.Subscription.Id -ne $KeyVaultSubscriptionId) {
                Set-AzContext -SubscriptionId $ctx.Subscription.Id -ErrorAction SilentlyContinue | Out-Null
            }
            if ($kvPass) {
                Write-Host "  [OK] Credentials resolved (user: $kvUser, password: from Key Vault)" -ForegroundColor Green
                return New-Object System.Management.Automation.PSCredential($kvUser, (ConvertTo-SecureString $kvPass -AsPlainText -Force))
            }
        } catch {
            Write-Host "  [WARN] Key Vault credential lookup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    # Tier 3: Interactive
    Write-Host "  Please enter local admin credentials for node access:" -ForegroundColor Yellow
    $promptUser = Read-Host -Prompt "  Local Admin Username"
    $promptPass = Read-Host -Prompt "  Local Admin Password" -AsSecureString
    if (-not $promptUser -or -not $promptPass) {
        Write-Warning "No credentials provided. Log monitoring will be disabled."
        return $null
    }
    return New-Object System.Management.Automation.PSCredential($promptUser, $promptPass)
}

function Invoke-NodeCommand {
    # Try primary credential, fall back to secondary on access denied
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$PrimaryCred,
        [System.Management.Automation.PSCredential]$FallbackCred,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    $creds = @()
    if ($PrimaryCred)  { $creds += $PrimaryCred  }
    if ($FallbackCred) { $creds += $FallbackCred }
    $lastErr = $null
    foreach ($cred in $creds) {
        try {
            return Invoke-Command -ComputerName $ComputerName -Credential $cred -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        } catch {
            $lastErr = $_
            if ($_.Exception.Message -notmatch 'Access is denied|Access denied|AuthenticationException|LogonFailure') { throw }
        }
    }
    if ($lastErr) { throw $lastErr }
}

function Get-LatestLogFile {
    param(
        [string]$BasePath,
        [string[]]$NodeIPs,
        [System.Management.Automation.PSCredential]$Credential,
        [System.Management.Automation.PSCredential]$FallbackCredential,
        [ref]$NodeStatus
    )
    $allLogs = @()
    foreach ($nodeIP in $NodeIPs) {
        if (-not (Test-NodeConnectivity -NodeIP $nodeIP -TimeoutSeconds 3)) {
            if ($NodeStatus) { $NodeStatus.Value[$nodeIP] = "Offline (may be rebooting)" }
            continue
        }
        try {
            $logFiles = Invoke-NodeCommand -ComputerName $nodeIP -PrimaryCred $Credential -FallbackCred $FallbackCredential -ScriptBlock {
                param($Path)
                if (Test-Path $Path) {
                    Get-ChildItem -Path $Path -Filter "*.log" -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match 'SolutionUpdate|OrchestratorFull|UpdateArbAndExtensions|CAU|NuGetPackage' } |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                }
            } -ArgumentList $BasePath
            if ($NodeStatus) { $NodeStatus.Value[$nodeIP] = "Online" }
            if ($logFiles) {
                $allLogs += @{ NodeIP = $nodeIP; FullName = $logFiles.FullName; LastWriteTime = $logFiles.LastWriteTime; Length = $logFiles.Length }
            }
        } catch {
            if ($NodeStatus) {
                $NodeStatus.Value[$nodeIP] = if ($_.Exception.Message -match "WinRM|cannot be contacted|not respond") { "WinRM unavailable (rebooting?)" } else { "Error: $($_.Exception.Message)" }
            }
        }
    }
    if ($allLogs.Count -gt 0) { return $allLogs | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    return $null
}

function Get-LogTail {
    param(
        [hashtable]$LogFileInfo,
        [int]$Lines = 10,
        [System.Management.Automation.PSCredential]$Credential,
        [System.Management.Automation.PSCredential]$FallbackCredential
    )
    if (-not $LogFileInfo) { return @() }
    try {
        return Invoke-NodeCommand -ComputerName $LogFileInfo.NodeIP -PrimaryCred $Credential -FallbackCred $FallbackCredential -ScriptBlock {
            param($LogPath, $NumLines)
            if (Test-Path $LogPath) { Get-Content -Path $LogPath -Tail $NumLines -ErrorAction SilentlyContinue }
        } -ArgumentList @($LogFileInfo.FullName, $Lines)
    } catch { return @() }
}

function Get-LogSummary {
    param(
        [hashtable]$LogFileInfo,
        [System.Management.Automation.PSCredential]$Credential,
        [System.Management.Automation.PSCredential]$FallbackCredential
    )
    if (-not $LogFileInfo) { return @{ Errors = 0; Warnings = 0; Info = 0; LastModified = "N/A"; Size = "N/A" } }
    try {
        return Invoke-NodeCommand -ComputerName $LogFileInfo.NodeIP -PrimaryCred $Credential -FallbackCred $FallbackCredential -ScriptBlock {
            param($Path)
            if (Test-Path $Path) {
                $content = Get-Content -Path $Path -ErrorAction Stop
                $fi = Get-Item $Path
                @{
                    Errors       = ($content | Select-String -Pattern "\[Error\]|\[ERR\]|ERROR:" -AllMatches).Count
                    Warnings     = ($content | Select-String -Pattern "\[Warning\]|\[WARN\]|WARNING:" -AllMatches).Count
                    Info         = ($content | Select-String -Pattern "\[Info\]|\[INF\]|INFO:" -AllMatches).Count
                    LastModified = $fi.LastWriteTime.ToString("HH:mm:ss")
                    Size         = "{0:N2} MB" -f ($fi.Length / 1MB)
                }
            }
        } -ArgumentList @($LogFileInfo.FullName)
    } catch { return @{ Errors = 0; Warnings = 0; Info = 0; LastModified = "N/A"; Size = "N/A" } }
}

function Get-UpdateSummary {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.azurestackhci/clusters/$ClusterName/updateSummaries/default?api-version=2024-04-01"
    try {
        $result = az rest --method get --uri $uri 2>$null | ConvertFrom-Json
        if (-not $result) { return $null }
        return [PSCustomObject]@{
            State                  = $result.properties.state
            CurrentVersion         = $result.properties.currentVersion
            LastUpdated            = $result.properties.lastUpdated
            LastUpdateRunState     = $result.properties.lastUpdateRunProperties.state
            LastUpdateRunStartTime = $result.properties.lastUpdateRunProperties.timeStarted
            PackageVersions        = $result.properties.packageVersions
        }
    } catch { return $null }
}

function Get-ActiveUpdate {
    # Returns the update package currently Installing (or most recently attempted)
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName, [string]$UpdateName = "")
    $baseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.azurestackhci/clusters/$ClusterName"
    if ($UpdateName) {
        $uri = "$baseUri/updates/${UpdateName}?api-version=2024-04-01"
        try {
            $u = az rest --method get --uri $uri 2>$null | ConvertFrom-Json
            if ($u) { return [PSCustomObject]@{ Name = $u.name; State = $u.properties.state; DisplayName = $u.properties.displayName; Description = $u.properties.description } }
        } catch {}
    }
    # List all updates — prefer Installing, then most recent
    try {
        $updates = (az rest --method get --uri "$baseUri/updates?api-version=2024-04-01" 2>$null | ConvertFrom-Json).value
        if (-not $updates -or $updates.Count -eq 0) { return $null }
        $active = $updates | Where-Object { $_.properties.state -eq 'Installing' } | Select-Object -First 1
        $target = if ($active) { $active } else {
            $updates | Where-Object { $_.properties.state -in @('Failed','Succeeded') } |
                Sort-Object { $_.properties.notifyMessage } -Descending | Select-Object -First 1
        }
        if (-not $target) { return $null }
        return [PSCustomObject]@{ Name = $target.name; State = $target.properties.state; DisplayName = $target.properties.displayName; Description = $target.properties.description }
    } catch { return $null }
}

function Get-UpdateRun {
    # updateRuns are nested: /clusters/{cluster}/updates/{updateName}/updateRuns/{runId}
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName, [string]$UpdateName, [string]$RunName = "")
    if (-not $UpdateName) { return $null }
    $baseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.azurestackhci/clusters/$ClusterName/updates/$UpdateName"

    # If specific run GUID given, fetch it directly
    if ($RunName) {
        try {
            $run = az rest --method get --uri "$baseUri/updateRuns/${RunName}?api-version=2024-04-01" 2>$null | ConvertFrom-Json
            if (-not $run) { return $null }
            return [PSCustomObject]@{
                Name            = $run.name
                State           = $run.properties.state
                PercentComplete = $run.properties.progress.percentComplete
                TimeStarted     = $run.properties.timeStarted
                Duration        = $run.properties.duration
                Steps           = $run.properties.progress.steps
            }
        } catch { return $null }
    }

    # Auto-discover: list all runs under this update, prefer InProgress, then most recent
    try {
        $runs = (az rest --method get --uri "$baseUri/updateRuns?api-version=2024-04-01" 2>$null | ConvertFrom-Json).value
        if (-not $runs -or $runs.Count -eq 0) { return $null }
        $active = $runs | Where-Object { $_.properties.state -eq 'InProgress' } | Select-Object -First 1
        $target = if ($active) { $active } else {
            $runs | Sort-Object { [DateTime]$_.properties.timeStarted } -Descending | Select-Object -First 1
        }
        if (-not $target) { return $null }
        return [PSCustomObject]@{
            Name            = $target.name
            State           = $target.properties.state
            PercentComplete = $target.properties.progress.percentComplete
            TimeStarted     = $target.properties.timeStarted
            Duration        = $target.properties.duration
            Steps           = $target.properties.progress.steps
        }
    } catch { return $null }
}

function Get-ClusterStatus {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName)
    try {
        $cluster = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.AzureStackHCI/clusters" -Name $ClusterName -ExpandProperties -ErrorAction SilentlyContinue
        return $cluster.Properties.status
    } catch { return "Unknown" }
}

function Get-FlattenedSteps {
    param([array]$Steps, [int]$Depth = 0)
    $result = @()
    foreach ($step in $Steps) {
        $result += [PSCustomObject]@{
            name         = $step.name
            description  = $step.description
            status       = $step.status
            startTimeUtc = $step.startTimeUtc
            endTimeUtc   = $step.endTimeUtc
            depth        = $Depth
            hasChildren  = ($step.steps -and $step.steps.Count -gt 0)
        }
        if ($step.steps -and $step.steps.Count -gt 0) {
            $result += Get-FlattenedSteps -Steps $step.steps -Depth ($Depth + 1)
        }
    }
    return $result
}

function Write-ProgressBar {
    param([float]$Percent, [int]$Completed = -1, [int]$Total = -1, [int]$Width = 90)
    $pct    = [math]::Round([math]::Max(0, [math]::Min(100, $Percent)))
    $filled = [math]::Round(($pct / 100) * $Width)
    $empty  = $Width - $filled
    Write-Host "  [" -NoNewline -ForegroundColor Gray
    Write-Host ("█" * $filled) -NoNewline -ForegroundColor Cyan
    Write-Host ("░" * $empty)  -NoNewline -ForegroundColor DarkGray
    Write-Host "] "            -NoNewline -ForegroundColor Gray
    Write-Host "$pct%"         -NoNewline -ForegroundColor Cyan
    if ($Completed -ge 0 -and $Total -gt 0) {
        Write-Host " ($Completed/$Total steps)" -ForegroundColor Gray
    } else {
        Write-Host "" -ForegroundColor Gray
    }
}

# =============================================================================
# AZURE AUTHENTICATION (Parameters -> Key Vault -> Current Context)
# =============================================================================
Write-Host "`n  Starting Azure Local Update Monitor..." -ForegroundColor Cyan
Write-Host "  Monitoring: $ClusterName in $ResourceGroupName" -ForegroundColor Gray
if ($NodeIPs.Count -gt 0) {
    Write-Host "  Log nodes:  $($NodeIPs -join ', ')" -ForegroundColor Gray
}
Write-Host ""

Write-Host "  Authenticating to Azure..." -ForegroundColor Yellow
$spnAuthenticated = $false

if ($SPNClientId -and $SPNClientSecret) {
    try {
        $spnCred = New-Object System.Management.Automation.PSCredential($SPNClientId, $SPNClientSecret)
        Connect-AzAccount -ServicePrincipal -Credential $spnCred -Tenant $TenantId -Subscription $KeyVaultSubscriptionId -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Authenticated via SPN (parameters)" -ForegroundColor Green
        $spnAuthenticated = $true
    } catch { Write-Host "  [WARN] SPN parameter auth failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

if (-not $spnAuthenticated -and $KeyVaultName) {
    try {
        $spnAppId     = az keyvault secret show --vault-name $KeyVaultName --name $SPNClientIdSecretName     --query "value" -o tsv --subscription $KeyVaultSubscriptionId 2>$null
        $spnSecretVal = az keyvault secret show --vault-name $KeyVaultName --name $SPNClientSecretSecretName --query "value" -o tsv --subscription $KeyVaultSubscriptionId 2>$null
        if ($spnAppId -and $spnSecretVal) {
            $spnCred = New-Object System.Management.Automation.PSCredential($spnAppId, (ConvertTo-SecureString $spnSecretVal -AsPlainText -Force))
            Connect-AzAccount -ServicePrincipal -Credential $spnCred -Tenant $TenantId -Subscription $KeyVaultSubscriptionId -ErrorAction Stop | Out-Null
            Write-Host "  [OK] Authenticated via SPN (Key Vault)" -ForegroundColor Green
            $spnAuthenticated = $true
        }
    } catch { Write-Host "  [WARN] SPN Key Vault auth failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

if (-not $spnAuthenticated) {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx) { Write-Host "  [INFO] Using existing Azure context: $($ctx.Account.Id)" -ForegroundColor Green }
    else { Write-Host "  [ERROR] Not authenticated to Azure. Run Connect-AzAccount first." -ForegroundColor Red; exit 1 }
}

Write-Host "  Resolving LCM (domain) credentials..." -ForegroundColor Yellow
$lcmCredential = $null
$lcmKv   = if ($script:LcmKvName) { $script:LcmKvName } else { $KeyVaultName }
$lcmPass = $null
if ($lcmKv -and $script:LcmPasswordSecret) {
    try {
        $lcmPass = Get-AzKeyVaultSecret -VaultName $lcmKv -Name $script:LcmPasswordSecret -AsPlainText -ErrorAction Stop
    } catch {
        Write-Host "  [WARN] LCM KV lookup failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if ($lcmPass -and $script:LcmUsername) {
    $lcmUserFull = if ($script:LcmUsername -notmatch '\\|@') { "$($script:NetbiosName)\$($script:LcmUsername)" } else { $script:LcmUsername }
    $lcmCredential = New-Object System.Management.Automation.PSCredential($lcmUserFull, (ConvertTo-SecureString $lcmPass -AsPlainText -Force))
    Write-Host "  [OK] LCM credential resolved: $lcmUserFull" -ForegroundColor Green
} else {
    Write-Host "  [WARN] LCM credentials unavailable — falling back to local admin" -ForegroundColor Yellow
}

Write-Host "  Resolving local admin credentials..." -ForegroundColor Yellow
$nodeCredential = Get-NodeCredential `
    -Username $LocalAdminUsername -Password $LocalAdminPassword `
    -KeyVaultName $KeyVaultName -KeyVaultSubscriptionId $KeyVaultSubscriptionId `
    -UsernameSecret $LocalAdminUsernameSecretName -PasswordSecret $LocalAdminPasswordSecretName

if (-not $nodeCredential -and -not $lcmCredential) {
    Write-Host "  [WARN] No node credentials — log monitoring will be disabled." -ForegroundColor Yellow
} else {
    Write-Host "  [OK] Node credentials ready (LCM primary, local admin fallback)" -ForegroundColor Green
}

Set-AzContext -Subscription $SubscriptionId -ErrorAction SilentlyContinue | Out-Null
az account set --subscription $SubscriptionId 2>$null
Write-Host ""; Start-Sleep -Seconds 2

$startTime  = Get-Date
$nodeStatus = @{}

# =============================================================================
# DASHBOARD LOOP
# =============================================================================
while ($true) {
    # Discover active update package first, then its runs
    $activeUpdate  = Get-ActiveUpdate   -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName -UpdateName $UpdateName
    if ($activeUpdate -and -not $UpdateName) { $UpdateName = $activeUpdate.Name }

    $updateSummary = Get-UpdateSummary  -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName
    $updateRun     = Get-UpdateRun      -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName -UpdateName $UpdateName -RunName $UpdateRunName
    $clusterStatus = Get-ClusterStatus  -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName

    # Pin run name once discovered so we stop cycling through the list
    if ($updateRun -and -not $UpdateRunName) { $UpdateRunName = $updateRun.Name }

    $logFileInfo = $null
    $primaryCred  = if ($lcmCredential)  { $lcmCredential  } else { $nodeCredential }
    $fallbackCred = if ($lcmCredential)  { $nodeCredential } else { $null           }
    if ($primaryCred -and $NodeIPs.Count -gt 0) {
        $logFileInfo = Get-LatestLogFile -BasePath $LogBasePath -NodeIPs $NodeIPs -Credential $primaryCred -FallbackCredential $fallbackCred -NodeStatus ([ref]$nodeStatus)
    }

    Clear-Host
    $elapsed    = (Get-Date) - $startTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    # ─── Header ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                               AZURE LOCAL UPDATE DASHBOARD                                                               ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    $statusColor = switch ($clusterStatus) {
        "UpdateInProgress"  { "Yellow" }
        "Succeeded"         { "Green"  }
        "Failed"            { "Red"    }
        default             { "White"  }
    }
    Write-Host "  Cluster: "  -NoNewline -ForegroundColor Gray
    Write-Host "$ClusterName" -NoNewline -ForegroundColor White
    Write-Host "  |  Status: " -NoNewline -ForegroundColor Gray
    Write-Host "$clusterStatus" -NoNewline -ForegroundColor $statusColor
    Write-Host "  |  Elapsed: " -NoNewline -ForegroundColor Gray
    Write-Host "$elapsedStr"   -ForegroundColor Yellow
    Write-Host ""

    # ─── Update Summary bar ──────────────────────────────────────────────────
    if ($updateSummary) {
        Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
        Write-Host "  │  UPDATE SUMMARY                                                                                                         │" -ForegroundColor DarkCyan
        Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan

        $sumStateColor = switch ($updateSummary.State) {
            "UpdateAvailable"   { "Yellow" }; "UpdateInProgress" { "Cyan"   }
            "UpdateFailed"      { "Red"    }; "UpToDate"         { "Green"  }
            default             { "White"  }
        }
        $lastUpdatedStr = if ($updateSummary.LastUpdated -and $updateSummary.LastUpdated -ne "NA") {
            [DateTime]::Parse($updateSummary.LastUpdated).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
        } else { "N/A" }

        Write-Host "  │  Current Version: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($updateSummary.CurrentVersion)".PadRight(20) -NoNewline -ForegroundColor White
        Write-Host "  |  Update State: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($updateSummary.State)".PadRight(20) -NoNewline -ForegroundColor $sumStateColor
        Write-Host "  |  Last Updated: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$lastUpdatedStr" -ForegroundColor Gray
        Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
        Write-Host ""
    }

    # ─── Active Update Run ────────────────────────────────────────────────────
    if ($updateRun) {
        $runStateColor = switch ($updateRun.State) {
            "Succeeded" { "Green"  }; "Failed"    { "Red"    }
            "InProgress"{ "Yellow" }; "Paused"    { "Cyan"   }
            default     { "White"  }
        }
        $runStartStr = if ($updateRun.TimeStarted -and $updateRun.TimeStarted -ne "NA") {
            [DateTime]::Parse($updateRun.TimeStarted).ToLocalTime().ToString("HH:mm:ss")
        } else { "N/A" }

        Write-Host "  Update:     " -NoNewline -ForegroundColor Gray
        Write-Host ($activeUpdate ? "$($activeUpdate.DisplayName) ($($activeUpdate.Name))" : $UpdateName) -NoNewline -ForegroundColor White
        Write-Host "  |  State: " -NoNewline -ForegroundColor Gray
        Write-Host "$($activeUpdate.State)" -ForegroundColor ($activeUpdate.State -eq 'Installing' ? 'Yellow' : ($activeUpdate.State -eq 'Failed' ? 'Red' : 'Green'))
        Write-Host "  Run:        " -NoNewline -ForegroundColor Gray
        Write-Host "$($updateRun.Name)" -NoNewline -ForegroundColor White
        Write-Host "  |  Run State: " -NoNewline -ForegroundColor Gray
        Write-Host "$($updateRun.State)" -NoNewline -ForegroundColor $runStateColor
        Write-Host "  |  Started: " -NoNewline -ForegroundColor Gray
        Write-Host "$runStartStr" -ForegroundColor Gray
        Write-Host ""

        # Percent complete progress bar (from API, not derived from step count)
        $pct = if ($updateRun.PercentComplete) { [float]$updateRun.PercentComplete } else { 0 }

        if ($updateRun.Steps -and $updateRun.Steps.Count -gt 0) {
            $flatSteps      = Get-FlattenedSteps -Steps $updateRun.Steps
            $successCount   = ($flatSteps | Where-Object { $_.status -eq "Success"    -or $_.status -eq "Succeeded" }).Count
            $skippedCount   = ($flatSteps | Where-Object { $_.status -eq "Skipped"  }).Count
            $failedCount    = ($flatSteps | Where-Object { $_.status -eq "Error"     -or $_.status -eq "Failed"   }).Count
            $inProgCount    = ($flatSteps | Where-Object { $_.status -eq "InProgress"-or $_.status -eq "Running"  }).Count
            $totalSteps     = $flatSteps.Count
            $completedCount = $successCount + $skippedCount

            # Prefer API percent; fall back to step-count ratio if 0
            if ($pct -le 0 -and $totalSteps -gt 0) { $pct = ($completedCount / $totalSteps) * 100 }
            Write-ProgressBar -Percent $pct -Completed $completedCount -Total $totalSteps
            Write-Host ""

            Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
            Write-Host "  │  UPDATE STEPS                                                                                                           │" -ForegroundColor DarkGray
            Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray

            foreach ($step in $flatSteps) {
                $iconChar = switch -Regex ($step.status) {
                    "^(Success|Succeeded)$" { "[OK]"; $color = "Green"    }
                    "^Skipped$"             { "[--]"; $color = "DarkCyan" }
                    "^(Error|Failed)$"      { "[XX]"; $color = "Red"      }
                    "^(InProgress|Running)$"{ "[..]"; $color = "Yellow"   }
                    default                 { "[  ]"; $color = "DarkGray" }
                }
                $indent    = "  " * $step.depth
                $nameWidth = [math]::Max(47 - ($step.depth * 2), 20)
                $name      = $step.name
                if ($name.Length -gt $nameWidth) { $name = $name.Substring(0, $nameWidth - 3) + "..." }
                $name = $name.PadRight($nameWidth)

                $duration = ""
                if ($step.startTimeUtc -and $step.startTimeUtc -ne "NA") {
                    if ($step.endTimeUtc -and $step.endTimeUtc -ne "NA") {
                        $duration = "{0:mm\:ss}" -f ([DateTime]::Parse($step.endTimeUtc) - [DateTime]::Parse($step.startTimeUtc))
                    } elseif ($step.status -match "InProgress|Running") {
                        $duration = "{0:mm\:ss}" -f ((Get-Date).ToUniversalTime() - [DateTime]::Parse($step.startTimeUtc))
                    }
                }
                Write-Host "  │  $indent" -NoNewline -ForegroundColor DarkGray
                Write-Host $iconChar -NoNewline -ForegroundColor $color
                Write-Host " $name $($duration.PadLeft(6))" -NoNewline -ForegroundColor White
                Write-Host "  │" -ForegroundColor DarkGray
            }

            Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
            Write-Host ""

            Write-Host "  Summary: $successCount Success" -NoNewline -ForegroundColor Green
            if ($skippedCount -gt 0) { Write-Host " | $skippedCount Skipped"  -NoNewline -ForegroundColor DarkCyan }
            if ($failedCount  -gt 0) { Write-Host " | $failedCount Failed"    -NoNewline -ForegroundColor Red      }
            if ($inProgCount  -gt 0) { Write-Host " | $inProgCount Running"   -NoNewline -ForegroundColor Yellow   }
            Write-Host ""
            Write-Host ""

        } else {
            Write-ProgressBar -Percent $pct
            Write-Host ""
            Write-Host "  Waiting for update step data from API..." -ForegroundColor Yellow
            Write-Host ""
        }

        # ─── Completion banners ───────────────────────────────────────────────
        if ($updateRun.State -eq "Succeeded") {
            Write-Host "  ╔══════════════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "  ║              [OK] UPDATE COMPLETED SUCCESSFULLY                                              ║" -ForegroundColor Green
            Write-Host "  ╚══════════════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
            Write-Host ""
        } elseif ($updateRun.State -eq "Failed") {
            Write-Host "  ╔══════════════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║                        [XX] UPDATE FAILED                                                    ║" -ForegroundColor Red
            Write-Host "  ╚══════════════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
        } elseif ($updateRun.State -eq "Paused") {
            Write-Host "  ╔══════════════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "  ║              [--] UPDATE PAUSED — resume from Azure Portal or PowerShell                     ║" -ForegroundColor Cyan
            Write-Host "  ╚══════════════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host ""
        }

    } else {
        Write-Host "  Waiting for update run data from Azure API..." -ForegroundColor Yellow
        if (-not $UpdateRunName) {
            Write-Host "  (No active update run found — will re-check each cycle)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # ─── Log section ─────────────────────────────────────────────────────────
    Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
    Write-Host "  │  UPDATE LOG — SolutionUpdate / OrchestratorFull / CAU                                                                   │" -ForegroundColor Magenta
    Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor Magenta

    if ($nodeCredential -and $nodeStatus.Count -gt 0) {
        foreach ($ip in $NodeIPs) {
            $st = if ($nodeStatus.ContainsKey($ip)) { $nodeStatus[$ip] } else { "Unknown" }
            $activeLog = ($logFileInfo -and $logFileInfo.NodeIP -eq $ip)
            $display   = if ($activeLog) { "$st (live logs)" } else { $st }
            $stColor   = if ($st -eq "Online") { "Green" } elseif ($st -match "Offline|unavailable|rebooting") { "Yellow" } else { "Red" }
            Write-Host "  │    $ip - " -NoNewline -ForegroundColor DarkGray
            Write-Host $display -ForegroundColor $stColor
        }
        Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor Magenta
    }

    if ($logFileInfo) {
        $summary = Get-LogSummary -LogFileInfo $logFileInfo -Credential $primaryCred -FallbackCredential $fallbackCred
        $logName = Split-Path $logFileInfo.FullName -Leaf
        Write-Host "  │  $($logFileInfo.NodeIP) | $logName" -ForegroundColor DarkGray
        Write-Host "  │  Size: $($summary.Size)  Modified: $($summary.LastModified)  " -NoNewline -ForegroundColor DarkGray
        if ($summary.Errors   -gt 0) { Write-Host "E:$($summary.Errors) "   -NoNewline -ForegroundColor Red    }
        if ($summary.Warnings -gt 0) { Write-Host "W:$($summary.Warnings) " -NoNewline -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor Magenta

        $logLines = Get-LogTail -LogFileInfo $logFileInfo -Lines $LogTailLines -Credential $primaryCred -FallbackCredential $fallbackCred
        if (-not $logLines -or $logLines.Count -eq 0) {
            Write-Host "  │  No log content available" -ForegroundColor Yellow
        } else {
            foreach ($line in $logLines) {
                if ([string]::IsNullOrWhiteSpace($line)) { Write-Host "  │"; continue }
                if ($line -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ') { $line = $line -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ','' }
                if ($line.Length -gt 120) { $line = $line.Substring(0,117) + "..." }
                $lineColor = if ($line -match "\[Error\]|\[ERR\]|ERROR:|Failed|Exception") { "Red"      }
                             elseif ($line -match "\[Warning\]|\[WARN\]|WARNING:|Retry")   { "Yellow"   }
                             elseif ($line -match "\[Info\]|\[INF\]|INFO:")                { "Cyan"     }
                             elseif ($line -match "Success|Succeeded|Complete|Passed")     { "Green"    }
                             elseif ($line -match "Verbose")                               { "DarkGray" }
                             else                                                           { "Gray"     }
                Write-Host "  │ $line" -ForegroundColor $lineColor
            }
        }
    } elseif (-not $primaryCred -or $NodeIPs.Count -eq 0) {
        Write-Host "  │  Log monitoring disabled — no credentials or NodeIPs available" -ForegroundColor Yellow
    } else {
        Write-Host "  │  No update log matching SolutionUpdate/OrchestratorFull/CAU found on: $($NodeIPs -join ', ')" -ForegroundColor Yellow
    }

    Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Last refresh: $(Get-Date -Format 'HH:mm:ss')  |  Refresh: ${RefreshInterval}s  |  Ctrl+C to exit" -ForegroundColor DarkGray

    # Auto-exit on terminal state
    if ($updateRun) {
        if ($updateRun.State -eq "Succeeded") {
            Write-Host ""
            Write-Host "  Update complete. Review cluster health in the Azure Portal." -ForegroundColor Green
            break
        } elseif ($updateRun.State -eq "Failed") {
            Write-Host ""
            Write-Host "  Update failed. Review errors above and check the Azure Portal for remediation steps." -ForegroundColor Red
            break
        }
    }

    Start-Sleep -Seconds $RefreshInterval
}
