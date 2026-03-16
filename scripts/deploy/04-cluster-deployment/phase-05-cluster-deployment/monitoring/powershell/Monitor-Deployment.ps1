#Requires -Version 7.0

<#
.SYNOPSIS
    Monitor-Deployment.ps1
    Real-time dashboard for Azure Local cluster deployment monitoring with hierarchical step
    tree and live log file streaming.

.DESCRIPTION
    Provides a full-screen dashboard view after clicking Create in the portal (Task 10+):
    - Hierarchical deployment step tree from Azure API (deploymentSettings/default)
    - Per-step depth rendering with parent/child indentation
    - Real-time tail of OrchestratorFull / CloudDeployment logs from nodes
    - Progress bar (90-wide) showing completed/total steps
    - Node connectivity status with graceful reconnect on reboots

    Does NOT auto-exit — runs until Ctrl+C.

    Credential Resolution Order (node access):
      1. -LocalAdminUsername + -LocalAdminPassword parameters
      2. Key Vault: -KeyVaultName with username/password secret names
      3. Interactive Read-Host prompt

    Azure Authentication Order:
      1. -SPNClientId + -SPNClientSecret parameters
      2. Key Vault: SPN credentials via -SPNClientIdSecretName / -SPNClientSecretSecretName
      3. Existing Connect-AzAccount / Get-AzContext

.PARAMETER ResourceGroupName
    Resource group containing the cluster. (compute.arm_deployment.cluster_resource_group)

.PARAMETER ClusterName
    Name of the Azure Local cluster. (compute.arm_deployment.cluster_name)

.PARAMETER SubscriptionId
    Azure subscription ID. (azure_platform.azure_tenants[*].aztenant_subscription_id)

.PARAMETER NodeIPs
    Node management IPs for PSRemoting log access. (compute.cluster_nodes[*].management_ip)

.PARAMETER LocalAdminUsername
    Local admin username for PSRemoting. (identity.accounts.account_local_admin_username)

.PARAMETER LocalAdminPassword
    Local admin password as SecureString. (identity.accounts.account_local_admin_password)

.PARAMETER KeyVaultName
    Key Vault name for credential resolution. (security.keyvault.kv_azl.kv_azl_name)

.PARAMETER KeyVaultSubscriptionId
    Subscription ID where Key Vault resides. Defaults to SubscriptionId.

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

.PARAMETER LogBasePath
    Base path for CloudDeployment logs on nodes (default: C:\CloudDeployment\Logs).

.PARAMETER RefreshInterval
    Seconds between dashboard refreshes (default: 20).

.PARAMETER LogTailLines
    Number of recent log lines to display (default: 5).

.EXAMPLE
    .\Monitor-Deployment.ps1 `
        -ResourceGroupName "rg-iic-azurelocal-prod" `
        -ClusterName "iic-clus01" `
        -SubscriptionId "<SUBSCRIPTION_ID>" `
        -NodeIPs @("10.10.1.11","10.10.1.12","10.10.1.13") `
        -KeyVaultName "kv-iic-platform"

.EXAMPLE
    $pwd = Read-Host -AsSecureString 'Password'
    .\Monitor-Deployment.ps1 `
        -ResourceGroupName "rg-iic-azurelocal-prod" `
        -ClusterName "iic-clus01" `
        -SubscriptionId "<SUBSCRIPTION_ID>" `
        -NodeIPs @("10.10.1.11","10.10.1.12") `
        -LocalAdminUsername "iic-localadmin" `
        -LocalAdminPassword $pwd `
        -KeyVaultName ""

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         Task 10+ — Deployment (run after clicking Create in the portal)
    Execution:    Run from any machine with PS 7+, Az module, and network access to node IPs
    Requires:     PowerShell 7+, Az module, Azure CLI
    Run after:    Clicking "Create" in Azure Portal — runs for 2-3 hours
    Source:       temp/Monitor-Deployment-Enhanced.ps1
#>

[CmdletBinding()]
param(
    # --- Cluster / Environment ---
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,    # compute.arm_deployment.cluster_resource_group

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,          # compute.arm_deployment.cluster_name

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,       # azure_platform.azure_tenants[*].aztenant_subscription_id

    [Parameter(Mandatory = $false)]
    [string[]]$NodeIPs = @(),       # compute.cluster_nodes[*].management_ip

    # --- Node credentials (direct — tier 1) ---
    [Parameter(Mandatory = $false)]
    [string]$LocalAdminUsername,   # identity.accounts.account_local_admin_username

    [Parameter(Mandatory = $false)]
    [securestring]$LocalAdminPassword,

    # --- Key Vault (tier 2) ---
    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName = "",    # security.keyvault.kv_azl.kv_azl_name

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

    # --- Display ---
    [Parameter(Mandatory = $false)]
    [string]$LogBasePath = "C:\CloudDeployment\Logs",

    [Parameter(Mandatory = $false)]
    [int]$RefreshInterval = 20,

    [Parameter(Mandatory = $false)]
    [int]$LogTailLines = 5
)

# --- NodeIPs validation: filter empty strings, warn if none provided ---
$NodeIPs = @($NodeIPs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($NodeIPs.Count -eq 0) {
    Write-Host "`n  [WARN] No valid NodeIPs supplied — log monitoring will be disabled." -ForegroundColor Yellow
    Write-Host "  Dashboard will show Azure API status only (no live log tailing).`n" -ForegroundColor Yellow
}

$ErrorActionPreference = 'SilentlyContinue'
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
    if ($Username -and $Password) {
        Write-Host "  [INFO] Using credentials from parameters" -ForegroundColor Cyan
        return New-Object System.Management.Automation.PSCredential($Username, $Password)
    }
    if ($KeyVaultName) {
        try {
            Write-Host "  [INFO] Retrieving credentials from Key Vault '$KeyVaultName'..." -ForegroundColor Cyan
            $ctx = Get-AzContext
            if ($ctx.Subscription.Id -ne $KeyVaultSubscriptionId) {
                Set-AzContext -SubscriptionId $KeyVaultSubscriptionId -ErrorAction Stop | Out-Null
            }
            # Username secret is optional — many environments store it as plain text in YAML
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
    Write-Host "  Please enter local admin credentials for node access:" -ForegroundColor Yellow
    $promptUser = Read-Host -Prompt "  Local Admin Username"
    $promptPass = Read-Host -Prompt "  Local Admin Password" -AsSecureString
    if (-not $promptUser -or -not $promptPass) {
        Write-Warning "No credentials provided. Log monitoring will be disabled."
        return $null
    }
    return New-Object System.Management.Automation.PSCredential($promptUser, $promptPass)
}

function Get-LatestLogFile {
    param([string]$BasePath, [string[]]$NodeIPs, [System.Management.Automation.PSCredential]$Credential, [ref]$NodeStatus)
    $allLogs = @()
    foreach ($nodeIP in $NodeIPs) {
        if (-not (Test-NodeConnectivity -NodeIP $nodeIP -TimeoutSeconds 3)) {
            if ($NodeStatus) { $NodeStatus.Value[$nodeIP] = "Offline (may be rebooting)" }
            continue
        }
        try {
            $logFiles = Invoke-Command -ComputerName $nodeIP -Credential $Credential -ScriptBlock {
                param($Path)
                if (Test-Path $Path) {
                    Get-ChildItem -Path $Path -Filter "*.log" -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match 'OrchestratorFull|CloudDeployment' } |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                }
            } -ArgumentList $BasePath -ErrorAction Stop
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
    param([hashtable]$LogFileInfo, [int]$Lines = 5, [System.Management.Automation.PSCredential]$Credential)
    if (-not $LogFileInfo) { return @() }
    try {
        return Invoke-Command -ComputerName $LogFileInfo.NodeIP -Credential $Credential -ScriptBlock {
            param($LogPath, $NumLines)
            if (Test-Path $LogPath) { Get-Content -Path $LogPath -Tail $NumLines -ErrorAction SilentlyContinue }
        } -ArgumentList $LogFileInfo.FullName, $Lines -ErrorAction Stop
    } catch { return @() }
}

function Get-LogSummary {
    param([hashtable]$LogFileInfo, [System.Management.Automation.PSCredential]$Credential)
    if (-not $LogFileInfo) { return @{ Errors = 0; Warnings = 0; Info = 0; LastModified = "N/A"; Size = "N/A" } }
    try {
        return Invoke-Command -ComputerName $LogFileInfo.NodeIP -Credential $Credential -ScriptBlock {
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
        } -ArgumentList $LogFileInfo.FullName -ErrorAction Stop
    } catch { return @{ Errors = 0; Warnings = 0; Info = 0; LastModified = "N/A"; Size = "N/A" } }
}

function Get-DeploymentStatus {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.azurestackhci/clusters/$ClusterName/deploymentSettings/default?api-version=2024-04-01"
    try {
        $result = az rest --method get --uri $uri 2>$null | ConvertFrom-Json
        return @{
            DeploymentStatus = $result.properties.reportedProperties.deploymentStatus
            ValidationStatus = $result.properties.reportedProperties.validationStatus
        }
    } catch { return @{ DeploymentStatus = $null; ValidationStatus = $null } }
}

function Get-ClusterStatus {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName)
    try {
        $cluster = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.AzureStackHCI/clusters" -Name $ClusterName -ExpandProperties -ErrorAction SilentlyContinue
        return $cluster.Properties.status
    } catch { return "Unknown" }
}

function Write-ProgressBar {
    param([int]$Completed, [int]$Total, [int]$Width = 90)
    $percent = if ($Total -gt 0) { [math]::Round(($Completed / $Total) * 100) } else { 0 }
    $filled  = [math]::Round(($percent / 100) * $Width)
    $empty   = $Width - $filled
    Write-Host "  [" -NoNewline -ForegroundColor Gray
    Write-Host ("█" * $filled) -NoNewline -ForegroundColor Magenta
    Write-Host ("░" * $empty)  -NoNewline -ForegroundColor DarkGray
    Write-Host "] "            -NoNewline -ForegroundColor Gray
    Write-Host "$percent%"     -NoNewline -ForegroundColor Cyan
    Write-Host " ($Completed/$Total steps)" -ForegroundColor Gray
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

# =============================================================================
# AZURE AUTHENTICATION (Parameters -> Key Vault -> Current Context)
# =============================================================================
Write-Host "`n  Starting Azure Local Deployment Monitor..." -ForegroundColor Magenta
Write-Host "  Monitoring: $ClusterName in $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Log nodes:  $($NodeIPs -join ', ')" -ForegroundColor Gray
Write-Host ""

Write-Host "  Authenticating to Azure..." -ForegroundColor Yellow
$authenticated = $false

if ($SPNClientId -and $SPNClientSecret) {
    try {
        $spnCred = New-Object System.Management.Automation.PSCredential($SPNClientId, $SPNClientSecret)
        Connect-AzAccount -ServicePrincipal -Credential $spnCred -Tenant $TenantId -Subscription $KeyVaultSubscriptionId -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Authenticated via SPN (parameters)" -ForegroundColor Green
        $authenticated = $true
    } catch { Write-Host "  [WARN] SPN parameter auth failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

if (-not $authenticated -and $KeyVaultName) {
    try {
        $currentCtx = Get-AzContext -ErrorAction SilentlyContinue
        if ($currentCtx) {
            $spnAppId     = az keyvault secret show --vault-name $KeyVaultName --name $SPNClientIdSecretName     --query "value" -o tsv --subscription $KeyVaultSubscriptionId 2>$null
            $spnSecretVal = az keyvault secret show --vault-name $KeyVaultName --name $SPNClientSecretSecretName --query "value" -o tsv --subscription $KeyVaultSubscriptionId 2>$null
            if ($spnAppId -and $spnSecretVal) {
                $spnCred = New-Object System.Management.Automation.PSCredential($spnAppId, (ConvertTo-SecureString $spnSecretVal -AsPlainText -Force))
                Connect-AzAccount -ServicePrincipal -Credential $spnCred -Tenant $TenantId -Subscription $KeyVaultSubscriptionId -ErrorAction Stop | Out-Null
                Write-Host "  [OK] Authenticated via SPN (Key Vault)" -ForegroundColor Green
                $authenticated = $true
            }
        }
    } catch { Write-Host "  [WARN] SPN Key Vault auth failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

if (-not $authenticated) {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx) { Write-Host "  [INFO] Using existing Azure context: $($ctx.Account.Id)" -ForegroundColor Green }
    else { Write-Host "  [ERROR] Not authenticated to Azure. Run Connect-AzAccount first." -ForegroundColor Red; exit 1 }
}

Write-Host "  Resolving node credentials..." -ForegroundColor Yellow
$nodeCredential = Get-NodeCredential `
    -Username $LocalAdminUsername -Password $LocalAdminPassword `
    -KeyVaultName $KeyVaultName -KeyVaultSubscriptionId $KeyVaultSubscriptionId `
    -UsernameSecret $LocalAdminUsernameSecretName -PasswordSecret $LocalAdminPasswordSecretName

if (-not $nodeCredential) {
    Write-Host "  [WARN] No node credentials — log monitoring will be disabled." -ForegroundColor Yellow
} else {
    Write-Host "  [OK] Node credentials resolved" -ForegroundColor Green
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
    $statusData    = Get-DeploymentStatus -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName
    $deployment    = $statusData.DeploymentStatus
    $clusterStatus = Get-ClusterStatus    -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName
    $logFileInfo   = $null
    if ($nodeCredential) {
        $logFileInfo = Get-LatestLogFile -BasePath $LogBasePath -NodeIPs $NodeIPs -Credential $nodeCredential -NodeStatus ([ref]$nodeStatus)
    }

    Clear-Host
    $elapsed    = (Get-Date) - $startTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    # Header
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║                             AZURE LOCAL DEPLOYMENT DASHBOARD                                                             ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""

    $statusColor = switch ($clusterStatus) {
        "DeploymentInProgress" { "Yellow" }; "Succeeded" { "Green" }
        "Failed"               { "Red"    }; default      { "White" }
    }
    Write-Host "  Cluster: " -NoNewline -ForegroundColor Gray
    Write-Host "$ClusterName" -NoNewline -ForegroundColor White
    Write-Host "  |  Status: " -NoNewline -ForegroundColor Gray
    Write-Host "$clusterStatus" -NoNewline -ForegroundColor $statusColor
    Write-Host "  |  Elapsed: " -NoNewline -ForegroundColor Gray
    Write-Host "$elapsedStr" -ForegroundColor Yellow
    Write-Host ""

    # Deployment steps (hierarchical)
    if ($deployment -and $deployment.steps) {
        $flatSteps      = Get-FlattenedSteps -Steps $deployment.steps
        $successCount   = ($flatSteps | Where-Object { $_.status -eq "Success"    }).Count
        $skippedCount   = ($flatSteps | Where-Object { $_.status -eq "Skipped"    }).Count
        $failedCount    = ($flatSteps | Where-Object { $_.status -eq "Error"      }).Count
        $inProgCount    = ($flatSteps | Where-Object { $_.status -eq "InProgress" }).Count
        $totalSteps     = $flatSteps.Count
        $completedCount = $successCount + $skippedCount

        Write-ProgressBar -Completed $completedCount -Total $totalSteps
        Write-Host ""

        Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  DEPLOYMENT STEPS                                                                                                       │" -ForegroundColor DarkGray
        Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray

        foreach ($step in $flatSteps) {
            $iconChar = switch ($step.status) {
                "Success"    { "[OK]"; $color = "Green"    }
                "Skipped"    { "[--]"; $color = "DarkCyan" }
                "Error"      { "[XX]"; $color = "Red"      }
                "InProgress" { "[..]"; $color = "Yellow"   }
                default      { "[  ]"; $color = "DarkGray" }
            }
            $indent    = "  " * $step.depth
            $nameWidth = [math]::Max(47 - ($step.depth * 2), 20)
            $name      = ($step.name -replace "Azure Stack HCI |Azure Stack ", "")
            if ($name.Length -gt $nameWidth) { $name = $name.Substring(0, $nameWidth - 3) + "..." }
            $name = $name.PadRight($nameWidth)

            $duration = ""
            if ($step.startTimeUtc -and $step.startTimeUtc -ne "NA") {
                if ($step.endTimeUtc -and $step.endTimeUtc -ne "NA") {
                    $duration = "{0:mm\:ss}" -f ([DateTime]::Parse($step.endTimeUtc) - [DateTime]::Parse($step.startTimeUtc))
                } elseif ($step.status -eq "InProgress") {
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
        if ($skippedCount -gt 0) { Write-Host " | $skippedCount Skipped"   -NoNewline -ForegroundColor DarkCyan }
        if ($failedCount  -gt 0) { Write-Host " | $failedCount Failed"     -NoNewline -ForegroundColor Red      }
        if ($inProgCount  -gt 0) { Write-Host " | $inProgCount Running"    -NoNewline -ForegroundColor Yellow   }
        Write-Host ""
        Write-Host ""

        if ($clusterStatus -eq "Succeeded" -or $deployment.status -eq "Succeeded") {
            Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "  ║         [OK] DEPLOYMENT COMPLETED SUCCESSFULLY                           ║" -ForegroundColor Green
            Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
            Write-Host ""
        } elseif ($deployment.status -eq "Failed" -or $failedCount -gt 0) {
            Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "  ║                    [XX] DEPLOYMENT FAILED                                ║" -ForegroundColor Red
            Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
        }
    } else {
        Write-Host "  Waiting for deployment data from Azure API..." -ForegroundColor Yellow
        Write-Host ""
    }

    # Log section
    Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
    Write-Host "  │  DEPLOYMENT LOG — OrchestratorFull / CloudDeployment                                                                    │" -ForegroundColor Magenta
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
        $summary = Get-LogSummary -LogFileInfo $logFileInfo -Credential $nodeCredential
        $logName = Split-Path $logFileInfo.FullName -Leaf
        Write-Host "  │  $($logFileInfo.NodeIP) | $logName" -ForegroundColor DarkGray
        Write-Host "  │  Size: $($summary.Size)  Modified: $($summary.LastModified)  " -NoNewline -ForegroundColor DarkGray
        if ($summary.Errors   -gt 0) { Write-Host "E:$($summary.Errors) "   -NoNewline -ForegroundColor Red    }
        if ($summary.Warnings -gt 0) { Write-Host "W:$($summary.Warnings) " -NoNewline -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor Magenta

        $logLines = Get-LogTail -LogFileInfo $logFileInfo -Lines $LogTailLines -Credential $nodeCredential
        if (-not $logLines -or $logLines.Count -eq 0) {
            Write-Host "  │  No log content available" -ForegroundColor Yellow
        } else {
            foreach ($line in $logLines) {
                if ([string]::IsNullOrWhiteSpace($line)) { Write-Host "  │"; continue }
                if ($line -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ') { $line = $line -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ','' }
                if ($line.Length -gt 120) { $line = $line.Substring(0,117) + "..." }
                $lineColor = if ($line -match "\[Error\]|\[ERR\]|ERROR:|Failed|Exception") { "Red" }
                             elseif ($line -match "\[Warning\]|\[WARN\]|WARNING:|Retry")   { "Yellow" }
                             elseif ($line -match "\[Info\]|\[INF\]|INFO:")                { "Cyan" }
                             elseif ($line -match "Success|Succeeded|Complete|Passed")     { "Green" }
                             elseif ($line -match "Verbose")                               { "DarkGray" }
                             else                                                           { "Gray" }
                Write-Host "  │ $line" -ForegroundColor $lineColor
            }
        }
    } elseif (-not $nodeCredential) {
        Write-Host "  │  Log monitoring disabled — no credentials available" -ForegroundColor Yellow
    } else {
        Write-Host "  │  No OrchestratorFull/CloudDeployment log found on: $($NodeIPs -join ', ')" -ForegroundColor Yellow
    }

    Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Last refresh: $(Get-Date -Format 'HH:mm:ss')  |  Refresh: ${RefreshInterval}s  |  Ctrl+C to exit" -ForegroundColor DarkGray

    Start-Sleep -Seconds $RefreshInterval
}
