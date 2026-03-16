#Requires -Version 7.0

<#
.SYNOPSIS
    Monitor-Validation.ps1
    Real-time dashboard for Azure Local cluster validation monitoring with log file streaming.

.DESCRIPTION
    Provides a full-screen dashboard view during portal validation (Task 9):
    - Validation step progress and status from Azure API (deploymentSettings/default)
    - Real-time tail of EnvironmentValidatorFull log from cluster nodes via PSRemoting
    - Per-step duration tracking
    - Node connectivity status (handles reboots gracefully)
    - Auto-exits on validation completion (success or failure)

    Run after clicking "Start validation" in the Azure Portal.
    Press Ctrl+C to exit at any time.

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
    Azure subscription ID for the cluster. (azure_platform.azure_tenants[*].aztenant_subscription_id)

.PARAMETER NodeIPs
    Array of node management IP addresses for PSRemoting log access. (compute.cluster_nodes[*].management_ip)

.PARAMETER LocalAdminUsername
    Local admin username for PSRemoting. If omitted, resolved from Key Vault or prompted.
    (identity.accounts.account_local_admin_username)

.PARAMETER LocalAdminPassword
    Local admin password as SecureString. If omitted, resolved from Key Vault or prompted.
    (identity.accounts.account_local_admin_password)

.PARAMETER KeyVaultName
    Key Vault name for credential resolution. Set to empty string "" to skip KV lookup.
    (security.keyvault.kv_azl.kv_azl_name)

.PARAMETER KeyVaultSubscriptionId
    Subscription ID where the Key Vault resides. Defaults to SubscriptionId if not set.

.PARAMETER TenantId
    Azure AD tenant ID for SPN authentication. (azure_platform.azure_tenants[*].aztenant_id)

.PARAMETER SPNClientId
    Service Principal app/client ID. If omitted, retrieved from Key Vault.

.PARAMETER SPNClientSecret
    Service Principal client secret (SecureString). If omitted, retrieved from Key Vault.

.PARAMETER SPNClientIdSecretName
    Key Vault secret name for the SPN client ID (default: sp-azurelocal-client-id).

.PARAMETER SPNClientSecretSecretName
    Key Vault secret name for the SPN client secret (default: sp-azurelocal-client-secret).

.PARAMETER LocalAdminUsernameSecretName
    Key Vault secret name for the local admin username (default: local-admin-username).

.PARAMETER LocalAdminPasswordSecretName
    Key Vault secret name for the local admin password (default: local-admin-password).

.PARAMETER DeploymentName
    ARM deployment name (e.g., azl-validate-20260309170721). When provided, the monitor polls
    ARM deployment operations for real-time status — essential for ARM-driven validation where
    deploymentSettings/default reportedProperties may remain empty.
    If omitted, the monitor auto-discovers the latest azl-validate-* deployment in the RG.

.PARAMETER LogBasePath
    Base path where CloudDeployment logs are stored on nodes (default: C:\CloudDeployment\Logs).

.PARAMETER RefreshInterval
    Seconds between dashboard refreshes (default: 10).

.PARAMETER LogTailLines
    Number of recent log lines to display (default: 15).

.EXAMPLE
    .\Monitor-Validation.ps1 `
        -ResourceGroupName "rg-iic-azurelocal-prod" `
        -ClusterName "iic-clus01" `
        -SubscriptionId "<SUBSCRIPTION_ID>" `
        -NodeIPs @("10.10.1.11","10.10.1.12","10.10.1.13") `
        -KeyVaultName "kv-iic-platform"

.EXAMPLE
    $pwd = Read-Host -AsSecureString 'Password'
    .\Monitor-Validation.ps1 `
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
    Task:         Task 9 — Validation (run concurrently with portal validation)
    Execution:    Run from any machine with PS 7+, Az module, and network access to node IPs
    Requires:     PowerShell 7+, Az module, Azure CLI
    Run after:    Clicking "Start validation" in Azure Portal
    Source:       temp/Monitor-Validation-Enhanced.ps1
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
    [string]$KeyVaultSubscriptionId = "", # defaults to SubscriptionId

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

    # --- ARM Deployment ---
    [Parameter(Mandatory = $false)]
    [string]$DeploymentName = "",     # ARM deployment name (azl-validate-*); auto-discovered if empty

    # --- Display ---
    [Parameter(Mandatory = $false)]
    [string]$LogBasePath = "C:\CloudDeployment\Logs",

    [Parameter(Mandatory = $false)]
    [int]$RefreshInterval = 10,

    [Parameter(Mandatory = $false)]
    [int]$LogTailLines = 15
)

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
                    Get-ChildItem -Path $Path -Filter "EnvironmentValidatorFull.*.log" -ErrorAction SilentlyContinue |
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
    param([hashtable]$LogFileInfo, [int]$Lines = 15, [System.Management.Automation.PSCredential]$Credential)
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

function Get-ValidationStatus {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.azurestackhci/clusters/$ClusterName/deploymentSettings/default?api-version=2024-04-01"
    try { return (az rest --method get --uri $uri 2>$null | ConvertFrom-Json).properties.reportedProperties.validationStatus }
    catch { return $null }
}

function Find-LatestDeploymentName {
    param([string]$ResourceGroupName, [string]$Prefix = "azl-validate")
    try {
        $deps = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
            Where-Object { $_.DeploymentName -like "$Prefix*" } |
            Sort-Object Timestamp -Descending |
            Select-Object -First 1
        return $deps.DeploymentName
    } catch { return $null }
}

function Get-ArmDeploymentStatus {
    param([string]$ResourceGroupName, [string]$DeploymentName)
    if (-not $DeploymentName) { return $null }
    try {
        $dep = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $DeploymentName -ErrorAction Stop
        $ops = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $ResourceGroupName -DeploymentName $DeploymentName -ErrorAction SilentlyContinue
        $opList = @()
        foreach ($op in $ops) {
            $resName = if ($op.TargetResource) { ($op.TargetResource -split '/')[-1] } else { "Unknown" }
            $resType = if ($op.TargetResource) { ($op.TargetResource -split '/providers/')[-1] -replace '/[^/]+$','' } else { "" }
            $shortType = ($resType -split '/')[-1]
            $opList += [PSCustomObject]@{
                Name   = if ($shortType) { "$shortType/$resName" } else { $resName }
                Status = $op.ProvisioningState
                Error  = if ($op.StatusMessage -and $op.StatusMessage.error) { $op.StatusMessage.error.message } else { $null }
            }
        }
        return @{
            DeploymentName = $DeploymentName
            State          = $dep.ProvisioningState
            Operations     = $opList
            Timestamp      = $dep.Timestamp
        }
    } catch { return $null }
}

function Get-EdgeDeviceStatus {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string[]]$ArcNodeResourceIds)
    $results = @()
    foreach ($arcId in $ArcNodeResourceIds) {
        $nodeName = ($arcId -split '/')[-1]
        $uri = "https://management.azure.com${arcId}/providers/Microsoft.AzureStackHCI/edgeDevices/default?api-version=2024-04-01"
        try {
            $ed = az rest --method get --uri $uri 2>$null | ConvertFrom-Json
            $nics = @()
            if ($ed.properties.deviceConfiguration.nicDetails) {
                $nics = $ed.properties.deviceConfiguration.nicDetails | ForEach-Object { $_.adapterName }
            }
            $results += [PSCustomObject]@{
                NodeName          = $nodeName
                ProvisioningState = $ed.properties.provisioningState
                DeviceState       = $ed.properties.reportedProperties.deviceState
                NICs              = ($nics -join ', ')
                NICCount          = $nics.Count
            }
        } catch {
            $results += [PSCustomObject]@{
                NodeName          = $nodeName
                ProvisioningState = "Error"
                DeviceState       = "Unknown"
                NICs              = ""
                NICCount          = 0
            }
        }
    }
    return $results
}

function Get-ClusterStatus {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$ClusterName)
    try {
        $cluster = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.AzureStackHCI/clusters" -Name $ClusterName -ExpandProperties -ErrorAction SilentlyContinue
        return $cluster.Properties.status
    } catch { return "Unknown" }
}

function Write-ProgressBar {
    param([int]$Completed, [int]$Total, [int]$Width = 40)
    $percent = if ($Total -gt 0) { [math]::Round(($Completed / $Total) * 100) } else { 0 }
    $filled  = [math]::Round(($percent / 100) * $Width)
    $empty   = $Width - $filled
    Write-Host "  [" -NoNewline -ForegroundColor Gray
    Write-Host ("█" * $filled) -NoNewline -ForegroundColor Green
    Write-Host ("░" * $empty)  -NoNewline -ForegroundColor DarkGray
    Write-Host "] "            -NoNewline -ForegroundColor Gray
    Write-Host "$percent%"     -NoNewline -ForegroundColor Cyan
    Write-Host " ($Completed/$Total steps)" -ForegroundColor Gray
}

# =============================================================================
# VALIDATE NodeIPs — filter empty strings, require at least one valid IP
# =============================================================================
$NodeIPs = @($NodeIPs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($NodeIPs.Count -eq 0) {
    Write-Host "  [ERROR] -NodeIPs is required and must contain at least one valid IP address." -ForegroundColor Red
    Write-Host "  Example: -NodeIPs @('192.168.211.11','192.168.211.12')" -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# AZURE AUTHENTICATION (Parameters -> Key Vault -> Current Context)
# =============================================================================
Write-Host "`n  Starting Azure Local Validation Monitor..." -ForegroundColor Cyan
Write-Host "  Monitoring: $ClusterName in $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Log nodes:  $($NodeIPs -join ', ')" -ForegroundColor Gray
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
        $spnAppId      = az keyvault secret show --vault-name $KeyVaultName --name $SPNClientIdSecretName     --query "value" -o tsv --subscription $KeyVaultSubscriptionId 2>$null
        $spnSecretVal  = az keyvault secret show --vault-name $KeyVaultName --name $SPNClientSecretSecretName --query "value" -o tsv --subscription $KeyVaultSubscriptionId 2>$null
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
Write-Host ""; Start-Sleep -Seconds 2

# --- Auto-discover deployment name if not provided ---
if (-not $DeploymentName) {
    Write-Host "  [INFO] DeploymentName not provided — auto-discovering latest azl-validate-* deployment..." -ForegroundColor Yellow
    $DeploymentName = Find-LatestDeploymentName -ResourceGroupName $ResourceGroupName -Prefix "azl-validate"
    if ($DeploymentName) {
        Write-Host "  [OK] Found deployment: $DeploymentName" -ForegroundColor Green
    } else {
        Write-Host "  [INFO] No existing deployment found — will re-check each cycle" -ForegroundColor Yellow
    }
}

# --- Resolve Arc node resource IDs for edge device queries ---
$arcNodeResourceIds = @()
try {
    $arcNodes = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.HybridCompute/machines" -ErrorAction SilentlyContinue
    if ($arcNodes) { $arcNodeResourceIds = $arcNodes | ForEach-Object { $_.ResourceId } }
} catch {}

$startTime  = Get-Date
$nodeStatus = @{}

# =============================================================================
# DASHBOARD LOOP
# =============================================================================
while ($true) {
    $validation    = Get-ValidationStatus -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName
    $clusterStatus = Get-ClusterStatus    -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName

    # --- ARM deployment operations (primary data source for ARM-driven validation) ---
    if (-not $DeploymentName) {
        $DeploymentName = Find-LatestDeploymentName -ResourceGroupName $ResourceGroupName -Prefix "azl-validate"
    }
    $armStatus = Get-ArmDeploymentStatus -ResourceGroupName $ResourceGroupName -DeploymentName $DeploymentName

    # --- Edge device status (NIC inventory per node) ---
    $edgeDeviceInfo = @()
    if ($arcNodeResourceIds.Count -gt 0) {
        $edgeDeviceInfo = Get-EdgeDeviceStatus -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ArcNodeResourceIds $arcNodeResourceIds
    }

    $logFileInfo = $null
    if ($nodeCredential -and $NodeIPs.Count -gt 0) {
        $logFileInfo = Get-LatestLogFile -BasePath $LogBasePath -NodeIPs $NodeIPs -Credential $nodeCredential -NodeStatus ([ref]$nodeStatus)
    }

    # --- Determine data source for dashboard ---
    $useArmFallback = (-not $validation -or -not $validation.steps) -and $armStatus

    Clear-Host
    $elapsed    = (Get-Date) - $startTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    # Header
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║      AZURE LOCAL VALIDATION DASHBOARD + LOGS                            ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    $statusColor = switch ($clusterStatus) {
        "ValidationInProgress" { "Yellow" }; "DeploymentInProgress" { "Cyan" }
        "Succeeded"            { "Green"  }; "Failed"               { "Red"  }
        default                { "White"  }
    }
    Write-Host "  Cluster: " -NoNewline -ForegroundColor Gray
    Write-Host "$ClusterName" -NoNewline -ForegroundColor White
    Write-Host "  |  Status: " -NoNewline -ForegroundColor Gray
    Write-Host "$clusterStatus" -NoNewline -ForegroundColor $statusColor
    Write-Host "  |  Elapsed: " -NoNewline -ForegroundColor Gray
    Write-Host "$elapsedStr" -ForegroundColor Yellow
    if ($DeploymentName) {
        Write-Host "  Deployment: " -NoNewline -ForegroundColor Gray
        Write-Host "$DeploymentName" -NoNewline -ForegroundColor White
        if ($armStatus) {
            $armColor = switch ($armStatus.State) { "Succeeded" { "Green" }; "Failed" { "Red" }; "Running" { "Yellow" }; default { "White" } }
            Write-Host "  |  ARM State: " -NoNewline -ForegroundColor Gray
            Write-Host "$($armStatus.State)" -ForegroundColor $armColor
        } else { Write-Host "" }
    } else { Write-Host "" }
    Write-Host ""

    # ─── DATA SOURCE 1: deploymentSettings validationStatus (populated by portal/LCM) ───
    if ($validation -and $validation.steps) {
        $steps         = $validation.steps
        $successCount  = ($steps | Where-Object { $_.status -eq "Success"    }).Count
        $skippedCount  = ($steps | Where-Object { $_.status -eq "Skipped"    }).Count
        $failedCount   = ($steps | Where-Object { $_.status -eq "Error"      }).Count
        $inProgCount   = ($steps | Where-Object { $_.status -eq "InProgress" }).Count
        $pendingCount  = ($steps | Where-Object { -not $_.status -or $_.status -notin @("Success","Error","InProgress","Skipped") }).Count
        $totalSteps    = $steps.Count
        $completedCount = $successCount + $skippedCount

        Write-ProgressBar -Completed $completedCount -Total $totalSteps
        Write-Host ""

        Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  VALIDATION STEPS (from deploymentSettings API)                                                                         │" -ForegroundColor DarkGray
        Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray

        foreach ($step in $steps) {
            $iconChar = switch ($step.status) {
                "Success"    { "[OK]"; $color = "Green"    }
                "Skipped"    { "[--]"; $color = "DarkCyan" }
                "Error"      { "[XX]"; $color = "Red"      }
                "InProgress" { "[..]"; $color = "Yellow"   }
                default      { "[  ]"; $color = "DarkGray" }
            }
            $name = ($step.name -replace "Azure Stack HCI |Azure Stack ","")
            if ($name.Length -gt 55) { $name = $name.Substring(0,52) + "..." }
            $name = $name.PadRight(55)
            $duration = ""
            if ($step.startTimeUtc -and $step.startTimeUtc -ne "NA") {
                if ($step.endTimeUtc -and $step.endTimeUtc -ne "NA") {
                    $duration = "{0:mm\:ss}" -f ([DateTime]::Parse($step.endTimeUtc) - [DateTime]::Parse($step.startTimeUtc))
                } elseif ($step.status -eq "InProgress") {
                    $duration = "{0:mm\:ss}" -f ((Get-Date).ToUniversalTime() - [DateTime]::Parse($step.startTimeUtc))
                }
            }
            Write-Host "  │  " -NoNewline -ForegroundColor DarkGray
            Write-Host $iconChar -NoNewline -ForegroundColor $color
            Write-Host " $name $($duration.PadLeft(6))" -NoNewline -ForegroundColor White
            Write-Host "  │" -ForegroundColor DarkGray
        }

        Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "  Summary: $successCount Success" -NoNewline -ForegroundColor Green
        if ($skippedCount  -gt 0) { Write-Host " | $skippedCount Skipped"  -NoNewline -ForegroundColor DarkCyan }
        if ($failedCount   -gt 0) { Write-Host " | $failedCount Failed"    -NoNewline -ForegroundColor Red      }
        if ($inProgCount   -gt 0) { Write-Host " | $inProgCount Running"   -NoNewline -ForegroundColor Yellow   }
        if ($pendingCount  -gt 0) { Write-Host " | $pendingCount Pending"  -NoNewline -ForegroundColor DarkGray }
        Write-Host ""
        Write-Host ""

    # ─── DATA SOURCE 2: ARM Deployment Operations (fallback for ARM-driven validation) ───
    } elseif ($useArmFallback) {
        $ops = $armStatus.Operations
        $opsSucceeded = @($ops | Where-Object { $_.Status -eq "Succeeded" })
        $opsFailed    = @($ops | Where-Object { $_.Status -eq "Failed"    })
        $opsRunning   = @($ops | Where-Object { $_.Status -eq "Running"   })
        $opsAccepted  = @($ops | Where-Object { $_.Status -eq "Accepted" -or -not $_.Status })
        $totalOps     = $ops.Count

        Write-ProgressBar -Completed $opsSucceeded.Count -Total $totalOps
        Write-Host ""

        Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  ARM DEPLOYMENT OPERATIONS                                                                                              │" -ForegroundColor DarkGray
        Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkGray

        foreach ($op in $ops) {
            $iconChar = switch ($op.Status) {
                "Succeeded" { "[OK]"; $color = "Green"    }
                "Failed"    { "[XX]"; $color = "Red"      }
                "Running"   { "[..]"; $color = "Yellow"   }
                "Accepted"  { "[>>]"; $color = "Cyan"     }
                default     { "[  ]"; $color = "DarkGray" }
            }
            $name = $op.Name
            if ($name.Length -gt 75) { $name = $name.Substring(0,72) + "..." }
            $name = $name.PadRight(75)
            Write-Host "  │  " -NoNewline -ForegroundColor DarkGray
            Write-Host $iconChar -NoNewline -ForegroundColor $color
            Write-Host " $name" -NoNewline -ForegroundColor White
            Write-Host "  │" -ForegroundColor DarkGray
        }

        Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "  Summary: $($opsSucceeded.Count) Succeeded" -NoNewline -ForegroundColor Green
        if ($opsFailed.Count  -gt 0) { Write-Host " | $($opsFailed.Count) Failed"  -NoNewline -ForegroundColor Red    }
        if ($opsRunning.Count -gt 0) { Write-Host " | $($opsRunning.Count) Running" -NoNewline -ForegroundColor Yellow }
        if ($opsAccepted.Count -gt 0) { Write-Host " | $($opsAccepted.Count) Pending" -NoNewline -ForegroundColor Cyan }
        Write-Host ""

        # Show error details for any failed operations
        if ($opsFailed.Count -gt 0) {
            Write-Host ""
            Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor Red
            Write-Host "  │  ERRORS                                                                                                                 │" -ForegroundColor Red
            Write-Host "  ├────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor Red
            foreach ($failedOp in $opsFailed) {
                Write-Host "  │  [XX] $($failedOp.Name)" -ForegroundColor Red
                if ($failedOp.Error) {
                    $errMsg = $failedOp.Error
                    # Word-wrap long error messages
                    $wrapWidth = 110
                    while ($errMsg.Length -gt 0) {
                        $chunk = if ($errMsg.Length -gt $wrapWidth) { $errMsg.Substring(0, $wrapWidth) } else { $errMsg }
                        Write-Host "  │    $chunk" -ForegroundColor Yellow
                        $errMsg = if ($errMsg.Length -gt $wrapWidth) { $errMsg.Substring($wrapWidth) } else { "" }
                    }
                }
            }
            Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Red
        }
        Write-Host ""

    } else {
        Write-Host "  Waiting for validation data..." -ForegroundColor Yellow
        if (-not $DeploymentName) {
            Write-Host "  (No ARM deployment found yet — will auto-discover when deployment starts)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # ─── Edge Device Status ───
    if ($edgeDeviceInfo.Count -gt 0) {
        $bw = 76  # box inner width
        Write-Host "  ┌$('─' * $bw)┐" -ForegroundColor DarkCyan
        Write-Host "  │  EDGE DEVICE STATUS$(' ' * ($bw - 22))│" -ForegroundColor DarkCyan
        Write-Host "  ├$('─' * $bw)┤" -ForegroundColor DarkCyan
        foreach ($ed in $edgeDeviceInfo) {
            $edIcon = switch ($ed.ProvisioningState) { "Succeeded" { "[OK]"; $edColor = "Green" }; "Failed" { "[XX]"; $edColor = "Red" }; default { "[..]"; $edColor = "Yellow" } }
            $expectedNICs = 7
            $nicStatus = if ($ed.NICCount -ge $expectedNICs) { "$($ed.NICCount)/$expectedNICs NICs" } elseif ($ed.NICCount -gt 0) { "$($ed.NICCount)/$expectedNICs NICs" } else { "No NICs" }
            $provState = if ($ed.ProvisioningState) { $ed.ProvisioningState } else { "Pending" }
            # Build the line:  "  [OK] azl-lab-01-n01   7/7 NICs  │  Provisioned  "
            $lineContent = "  $edIcon $($ed.NodeName.PadRight(18)) $($nicStatus.PadRight(12))│  $provState"
            $padding = $bw - $lineContent.Length
            if ($padding -lt 0) { $padding = 0 }
            Write-Host "  │" -NoNewline -ForegroundColor DarkCyan
            Write-Host "  $edIcon " -NoNewline -ForegroundColor $edColor
            Write-Host "$($ed.NodeName.PadRight(18))" -NoNewline -ForegroundColor White
            Write-Host " $($nicStatus.PadRight(12))" -NoNewline -ForegroundColor Gray
            Write-Host "│  " -NoNewline -ForegroundColor DarkCyan
            Write-Host "$($provState.PadRight($bw - $lineContent.Length - 2))" -NoNewline -ForegroundColor Gray
            Write-Host "  │" -ForegroundColor DarkCyan
        }
        Write-Host "  └$('─' * $bw)┘" -ForegroundColor DarkCyan
        Write-Host ""
    }

    # ─── Validation result banners ───
    $validationDone = $false
    $validationFailed = $false

    if ($validation -and $validation.steps) {
        $steps = $validation.steps
        $successCount  = ($steps | Where-Object { $_.status -eq "Success" }).Count
        $skippedCount  = ($steps | Where-Object { $_.status -eq "Skipped" }).Count
        $failedCount   = ($steps | Where-Object { $_.status -eq "Error"   }).Count
        $completedCount = $successCount + $skippedCount
        if ($validation.status -eq "Succeeded" -or ($completedCount -eq $steps.Count -and $failedCount -eq 0)) { $validationDone = $true }
        if ($validation.status -eq "Failed" -or $failedCount -gt 0) { $validationFailed = $true }
    } elseif ($armStatus) {
        if ($armStatus.State -eq "Succeeded") { $validationDone = $true }
        if ($armStatus.State -eq "Failed")    { $validationFailed = $true }
    }

    if ($validationDone) {
        Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "  ║            [OK] VALIDATION COMPLETED SUCCESSFULLY                        ║" -ForegroundColor Green
        Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
    } elseif ($validationFailed) {
        Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "  ║                    [XX] VALIDATION FAILED                                ║" -ForegroundColor Red
        Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""
    }

    # Log section
    Write-Host "  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
    Write-Host "  │  VALIDATION LOG — EnvironmentValidatorFull                                                                              │" -ForegroundColor Magenta
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
        Write-Host "  │  No EnvironmentValidatorFull log found on: $($NodeIPs -join ', ')" -ForegroundColor Yellow
    }

    Write-Host "  └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Last refresh: $(Get-Date -Format 'HH:mm:ss')  |  Refresh: ${RefreshInterval}s  |  Ctrl+C to exit" -ForegroundColor DarkGray

    # Auto-exit on completion
    if ($validationDone) {
        Write-Host ""
        Write-Host "  Validation complete. Proceed to Task 10: Review + Create." -ForegroundColor Green
        break
    } elseif ($validationFailed) {
        Write-Host ""
        Write-Host "  Validation failed. Review errors above and fix before re-running." -ForegroundColor Red
        break
    }

    Start-Sleep -Seconds $RefreshInterval
}
