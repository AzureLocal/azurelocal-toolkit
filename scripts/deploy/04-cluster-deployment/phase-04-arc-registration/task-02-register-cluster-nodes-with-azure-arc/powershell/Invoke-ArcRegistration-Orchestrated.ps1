#Requires -Version 7.0
<#
.SYNOPSIS
    Invoke-ArcRegistration-Orchestrated.ps1
    Registers Azure Local cluster nodes with Azure Arc.

.DESCRIPTION
    Authenticates with a service principal (SPN secret resolved from Key Vault or
    prompted securely), obtains an ARM access token, and runs
    Invoke-AzStackHciArcInitialization on each cluster node via PSRemoting.

    AZURE AUTHENTICATION:
      - Default: SPN — secret resolved from Key Vault (identity.service_principal.secret)
      - Override: -SpnAppId / -SpnSecret to bypass Key Vault lookup
      - Fallback: secure prompt for SPN secret if Key Vault is unavailable

    NODE ACCESS (standard credential resolution order):
      1. -Credential parameter (explicit override)
      2. Key Vault lookup via identity.local_admin.password
      3. Interactive Get-Credential prompt

    Configuration values are read from infrastructure.yml. All Azure values can be
    overridden via command-line parameters (see YAML-overridable parameters below).

    Arc registration is a mandatory prerequisite for Azure Local cloud deployment.
    Without it, the deployment orchestrator cannot communicate with the cluster.

    EXECUTION MODEL:
    Uses synchronous Invoke-Command with all node IPs in a single call:
      Invoke-Command -ComputerName ($ServerList) -ScriptBlock { ... }
    PowerShell fans out PSRemoting sessions to all nodes in parallel. Each
    session stays alive through OEM bootstrap reboots — the cmdlet
    Invoke-AzStackHciArcInitialization manages its own reboot/resume cycle
    internally. This is the same pattern used in manual deployments and
    Microsoft's own documentation.

    OEM IMAGE BOOTSTRAP:
    When nodes ship with a preinstalled or outdated Azure Stack HCI OS image (Dell,
    HPE, Lenovo, etc.), the Invoke-AzStackHciArcInitialization command triggers an
    automatic OS update cycle:
      1. Scan   — detect the current OS version vs. latest baseline
      2. Download — download the update package (~40-60 min depending on network)
      3. Install  — apply the update
      4. REBOOT   — node reboots to complete the update
      5. Resume   — after reboot, the bootstrap service resumes Arc registration
                     using the cached SPN token (no manual intervention required)

    The synchronous Invoke-Command session survives reboots because the cmdlet
    handles them internally. Follow the progress in Sonar (azurelocal-sonar).

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to auto-detect from script location.

.PARAMETER Credential
    PSCredential for PSRemoting to cluster nodes. If omitted, resolved from
    Key Vault using identity.local_admin.password, then
    falls back to interactive Get-Credential prompt. Use -SpnAppId / -SpnSecret
    to override Azure SPN credentials (separate from node credentials).

.PARAMETER TargetNode
    One or more node hostnames or IPs. Defaults to all nodes in config.

.PARAMETER WhatIf
    Dry-run mode — shows what would be registered without connecting.

.PARAMETER LogPath
    Override log file path. Default: ./logs/<task-folder>/<timestamp>_ArcRegistration.log

.PARAMETER TenantId
    Override Azure tenant ID. YAML path: azure.tenant_id

.PARAMETER SubscriptionId
    Override Azure subscription ID. YAML path: azure.subscription_id

.PARAMETER Region
    Override Azure region. YAML path: azure.location

.PARAMETER ResourceGroup
    Override Arc resource group. YAML path: azure.resource_group

.PARAMETER ArcGatewayId
    Override Arc gateway resource ID. Default: built from scenario.outbound_path and networking.outbound.arc_gateway (name, resource_group)
    Pass empty string to disable Arc Gateway.

.PARAMETER NoArcGateway
    Skip Arc Gateway usage. By default, the script requires an Arc Gateway to be
    configured in infrastructure.yml (scenario.outbound_path arc_gateway or proxy_arc_gateway,
    and networking.outbound.arc_gateway.name). Set this switch only if you are not using an Arc Gateway.
    If omitted and no gateway is configured, the script blocks with an error.

.PARAMETER SpnAppId
    Override service principal application (client) ID. YAML path: azure.automation_identity.client_id

.PARAMETER SpnSecret
    SPN secret (plaintext). If omitted, resolved from Key Vault via identity.service_principal.secret.

.PARAMETER Cloud
    Azure cloud environment. Default: AzureCloud

.EXAMPLE
    .\Invoke-ArcRegistration-Orchestrated.ps1 -ConfigPath .\configs\infrastructure.yml

.EXAMPLE
    .\Invoke-ArcRegistration-Orchestrated.ps1 -ConfigPath .\configs\infrastructure.yml -WhatIf

.EXAMPLE
    .\Invoke-ArcRegistration-Orchestrated.ps1 -ConfigPath .\configs\infrastructure.yml -TargetNode iic-azl-n01

.EXAMPLE
    .\Invoke-ArcRegistration-Orchestrated.ps1 -ConfigPath .\configs\infrastructure.yml -SpnSecret "<service-principal-secret>"


.NOTES
    Author:  Azure Local Cloud AzureLocalCloud
    Phase:   04-arc-registration
    Task:    02 - Register Cluster Nodes with Azure Arc
    Mode:    DESTRUCTIVE. Arc deregistration requires OS reinstallation.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [string[]]$TargetNode = @(),

    [switch]$WhatIf,

    [string]$LogPath = "",

    # YAML-overridable Azure parameters
    [string]$TenantId       = "",        # azure.tenant_id
    [string]$SubscriptionId = "",        # azure.subscription_id
    [string]$Region         = "",        # azure.location
    [string]$ResourceGroup  = "",        # azure.resource_group
    [string]$ArcGatewayId   = "",        # networking.outbound.arc_gateway
    [switch]$NoArcGateway,                 # Skip Arc Gateway — not recommended
    [string]$SpnAppId       = "",        # azure.automation_identity.client_id
    [string]$SpnSecret      = "",        # identity.service_principal.secret (resolved from KV)
    [string]$Cloud          = ""         # AzureCloud (default)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1'))) -Force

# ── Log file initialization ───────────────────────────────────────────────
# Scripts are always run from the repo root, so ./logs/<task-folder>/ is CWD-relative
$scriptShortName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^Invoke-|-Orchestrated$', ''
$taskFolderName  = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf   # e.g. task-02-register-cluster-nodes-with-azure-arc
$logDir  = Join-Path (Get-Location).Path "logs\$taskFolderName"
if ($LogPath -ne "") {
    $logDir  = Split-Path $LogPath -Parent
    $logFile = $LogPath
} else {
    $logFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd_HHmmss')_${scriptShortName}.log"
}
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

#region HELPERS

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $line | Out-File -FilePath $script:logFile -Append -Encoding utf8
    switch ($Level) {
        "PASS"    { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "FAIL"    { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        "SUCCESS" { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "VERBOSE" { Write-Verbose "[$ts] $Message" }
        "DEBUG"   { Write-Debug  "[$ts] $Message" }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }
}

function Get-Config {
    param([string]$Path)
    if ($Path -eq "" -or -not (Test-Path $Path)) {
        foreach ($c in @(
            (Join-Path $PSScriptRoot "..\..\..\..\..\..\configs\infrastructure.yml"),
            (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\configs\infrastructure.yml")
        )) { if (Test-Path $c) { $Path = (Resolve-Path $c).Path; break } }
    } else {
        $Path = (Resolve-Path $Path).Path
    }
    if (-not (Test-Path $Path)) { throw "infrastructure.yml not found. Use -ConfigPath." }

    Write-Log "Loading config from: $Path"
    Write-Log "Resolved config path: $Path" VERBOSE

    Import-Module powershell-yaml -ErrorAction Stop
    $cfg = Get-Content $Path -Raw | ConvertFrom-Yaml
    $script:SecretInfrastructure = $cfg

    # nodes[]
    $nodes = Get-AzlInfrastructureNode -Infrastructure $cfg | ForEach-Object {
        [PSCustomObject]@{
            nodename = $_.Name                                       # nodes[].name
            hostname = $_.Name                                       # nodes[].name
            ip       = $_.ManagementIp                               # nodes[].management.ip_address
        }
    }

    $gw = Get-AzlArcGateway -Infrastructure $cfg                     # scenario.outbound_path, networking.outbound.arc_gateway

    return [PSCustomObject]@{
        Nodes          = @($nodes)
        TenantId       = $cfg.azure.tenant_id               # azure.tenant_id
        SubscriptionId = $cfg.azure.subscription_id    # azure.subscription_id
        Region         = $cfg.azure.location                  # azure.location
        ResourceGroup  = $cfg.azure.resource_group                   # azure.resource_group
        ArcGatewayId   = $gw.Id                                      # networking.outbound.arc_gateway (empty unless scenario.outbound_path uses a gateway)
        SpnAppId       = $cfg['azure']?['automation_identity']?['client_id']      # azure.automation_identity.client_id
        SpnSecretUri   = $cfg['identity']?['service_principal']?['secret']      # identity.service_principal.secret
        AdminUser      = $cfg.identity.local_admin.username   # identity.local_admin.username
        AdminPassUri   = $cfg.identity.local_admin.password   # identity.local_admin.password
        Cloud          = "AzureCloud"
    }
}

function Resolve-KeyVaultRef {
    # Reads a secret reference through the toolkit's one secret resolver (AzlSecret.psm1): any provider, no Azure CLI.
    # Returns the text, or $null when it cannot be read; the caller then falls back as before. No value is logged.
    param([string]$KvUri)
    if (-not (Get-AzlSecretProvider -Reference $KvUri)) { Write-Log "  The value is not a secret reference." "WARN"; return $null }
    try {
        $value = Get-AzlSecretPlainText -Reference $KvUri -Infrastructure $script:SecretInfrastructure
        Write-Log "  Secret retrieved." "SUCCESS"
        return $value
    }
    catch { Write-Log "  The secret could not be read: $($_.Exception.Message)" "WARN"; return $null }
}

#endregion HELPERS

#region MAIN

Write-Log "================================================================" HEADER
Write-Log "   Phase 04 Arc Registration — Task 02: Register Nodes with Arc" HEADER
Write-Log "================================================================" HEADER
Write-Log "" INFO
Write-Log "  Action  : Register cluster nodes with Azure Arc" INFO
Write-Log "  WARNING : Arc deregistration requires OS reinstallation!" INFO
Write-Log "  Log     : $logFile" INFO
Write-Log "" INFO

# ── Load config ──────────────────────────────────────────────────────────────
Write-Log "Config : $ConfigPath" INFO
Write-Log "--- Loading configuration ---" HEADER

$cfg = Get-Config -Path $ConfigPath

# ── Apply YAML-overridable parameter overrides ───────────────────────────────
if ($TenantId       -ne "") { $cfg.TenantId       = $TenantId;       Write-Log "  Override: TenantId=$TenantId" WARN }
if ($SubscriptionId -ne "") { $cfg.SubscriptionId = $SubscriptionId; Write-Log "  Override: SubscriptionId=$SubscriptionId" WARN }
if ($Region         -ne "") { $cfg.Region         = $Region;         Write-Log "  Override: Region=$Region" WARN }
if ($ResourceGroup  -ne "") { $cfg.ResourceGroup  = $ResourceGroup;  Write-Log "  Override: ResourceGroup=$ResourceGroup" WARN }
if ($ArcGatewayId   -ne "") { $cfg.ArcGatewayId   = $ArcGatewayId;  Write-Log "  Override: ArcGatewayId=$ArcGatewayId" WARN }
if ($SpnAppId       -ne "") { $cfg.SpnAppId       = $SpnAppId;      Write-Log "  Override: SpnAppId=$SpnAppId" WARN }
if ($Cloud          -ne "") { $cfg.Cloud           = $Cloud;         Write-Log "  Override: Cloud=$Cloud" WARN }

Write-Log "  Tenant ID      : $($cfg.TenantId)" INFO
Write-Log "  Subscription   : $($cfg.SubscriptionId)" INFO
Write-Log "  Region         : $($cfg.Region)" INFO
Write-Log "  Resource Group : $($cfg.ResourceGroup)" INFO
Write-Log "  Arc Gateway    : $(if ($cfg.ArcGatewayId) { $cfg.ArcGatewayId } else { '(none)' })" INFO
Write-Log "  SPN App ID     : $($cfg.SpnAppId)" INFO
Write-Log "  Cloud          : $($cfg.Cloud)" INFO
Write-Log "Found $($cfg.Nodes.Count) node(s):" INFO
$cfg.Nodes | ForEach-Object { Write-Log "  $($_.hostname)  ($($_.ip))" INFO }

# ── Arc Gateway gate ──────────────────────────────────────────────────────────
if ($NoArcGateway) {
    $cfg.ArcGatewayId = ""
    Write-Log "Arc Gateway : DISABLED (-NoArcGateway specified)" WARN
    Write-Log "  Registration will proceed WITHOUT Arc Gateway. This is not recommended." WARN
} elseif ([string]::IsNullOrWhiteSpace($cfg.ArcGatewayId)) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  ARC GATEWAY NOT CONFIGURED" FAIL
    Write-Log "================================================================" HEADER
    Write-Log "" INFO
    Write-Log "Arc Gateway is required by default. Your infrastructure YAML has:" FAIL
    Write-Log "  scenario.outbound_path is not arc_gateway or proxy_arc_gateway, or networking.outbound.arc_gateway.name is empty" FAIL
    Write-Log "" INFO
    Write-Log "To proceed, you must either:" INFO
    Write-Log "  1. Deploy an Arc Gateway and update infrastructure.yml:" INFO
    Write-Log "       scenario.outbound_path: arc_gateway (or proxy_arc_gateway)" INFO
    Write-Log "       networking.outbound.arc_gateway.name: <name>" INFO
    Write-Log "  2. Run with -NoArcGateway if you do not want to use a gateway" INFO
    Write-Log "" INFO
    Write-Log "Log file: $logFile" INFO
    exit 1
}

# ── Resolve SPN secret (the only credential context for Arc registration) ─────
Write-Log "--- Resolving SPN credentials ---" HEADER
if ($SpnSecret -eq "") {
    Write-Log "Resolving SPN secret from Key Vault..."
    $SpnSecret = Resolve-KeyVaultRef -KvUri $cfg.SpnSecretUri
    if (-not $SpnSecret) {
        Write-Log "Key Vault unavailable — prompting for SPN secret." WARN
        $secureInput = Read-Host "Enter SPN secret for $($cfg.SpnAppId)" -AsSecureString
        $SpnSecret = [System.Net.NetworkCredential]::new('', $secureInput).Password
    }
}
Write-Log "SPN secret resolved." SUCCESS

# ── Resolve node credentials (standard credential resolution) ─────────────────
Write-Log "--- Resolving node credentials ---" HEADER
if (-not $Credential) {
    $adminUser    = $cfg.AdminUser                                   # identity.local_admin.username
    $adminPassUri = $cfg.AdminPassUri                                # identity.local_admin.password
    Write-Log "Resolving credentials from Key Vault..."
    $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
    if ($adminPass) {
        $securePwd  = ConvertTo-SecureString $adminPass -AsPlainText -Force
        $Credential = [PSCredential]::new($adminUser, $securePwd)
        Write-Log "Credentials resolved for '$adminUser'." SUCCESS
    } else {
        Write-Log "Key Vault unavailable — prompting for node credentials." WARN
        $Credential = Get-Credential -Message "Enter credentials for cluster node access"
    }
} else {
    Write-Log "Using explicit -Credential parameter: $($Credential.UserName)" INFO
}

# ── Apply TargetNode filter ───────────────────────────────────────────────────
$nodes = $cfg.Nodes
if ($TargetNode.Count -gt 0) {
    $nodes = @($nodes | Where-Object { $TargetNode -contains $_.hostname -or $TargetNode -contains $_.nodename -or $TargetNode -contains $_.ip })
    if ($nodes.Count -eq 0) { throw "No nodes matched filter: $($TargetNode -join ', ')" }
    Write-Log "Node filter applied — running against: $($nodes.hostname -join ', ')" WARN
}

# ── Build server list (IP addresses for Invoke-Command) ──────────────────────
$serverList = @($nodes | ForEach-Object { $_.ip })

# ── WhatIf — dry-run mode ────────────────────────────────────────────────────
if ($WhatIf) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  WHATIF — Dry-run mode. No registration will occur." HEADER
    Write-Log "================================================================" HEADER
    Write-Log "" INFO
    Write-Log "Would authenticate as SPN: $($cfg.SpnAppId)" INFO
    Write-Log "Would obtain ARM access token from Azure" INFO
    Write-Log "Would register $($nodes.Count) node(s) with Azure Arc:" INFO
    Write-Log "" INFO

    foreach ($n in $nodes) {
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  NODE: $($n.hostname)  ($($n.ip))" HEADER
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  WHATIF: Would run Invoke-AzStackHciArcInitialization with:" INFO
        Write-Log "    -SubscriptionID $($cfg.SubscriptionId)" INFO
        Write-Log "    -ResourceGroup  $($cfg.ResourceGroup)" INFO
        Write-Log "    -TenantID       $($cfg.TenantId)" INFO
        Write-Log "    -Region         $($cfg.Region)" INFO
        Write-Log "    -Cloud          $($cfg.Cloud)" INFO
        Write-Log "    -ArcGatewayID   $(if ($cfg.ArcGatewayId) { $cfg.ArcGatewayId } else { '(none — gateway disabled)' })" INFO
        Write-Log "    -ArmAccessToken <from SPN auth>" INFO
        Write-Log "    -AccountID      $($cfg.SpnAppId)" INFO
        Write-Log "" INFO
    }

    Write-Log "Execution model  : Synchronous Invoke-Command to all $($nodes.Count) node(s)" INFO
    Write-Log "  Server list    : $($serverList -join ', ')" INFO
    Write-Log "  Node credential : $($Credential.UserName) (from Key Vault)" INFO
    Write-Log "" INFO
    Write-Log "Invoke-Command fans out to all nodes in parallel. Each session" INFO
    Write-Log "stays alive through OEM bootstrap reboots — the cmdlet handles" INFO
    Write-Log "reboot/resume internally. No -AsJob, no manual reboot recovery." INFO
    Write-Log "" INFO
    Write-Log "OEM IMAGE BOOTSTRAP:" INFO
    Write-Log "  Nodes may reboot during OEM OS updates. The cmdlet manages the" INFO
    Write-Log "  full update + reboot + registration cycle internally. This can" INFO
    Write-Log "  take 40-90 minutes per node depending on OEM image age." INFO
    Write-Log "" INFO
    Write-Log "Re-run without -WhatIf to execute." INFO
    Write-Log "Log file: $logFile" INFO
    exit 0
}

# ── Authenticate SPN ──────────────────────────────────────────────────────────
Write-Log "" INFO
Write-Log "--- Authenticating with Azure (SPN) ---" HEADER
$secureSpnSecret = ConvertTo-SecureString $SpnSecret -AsPlainText -Force
$spnCredential   = [PSCredential]::new($cfg.SpnAppId, $secureSpnSecret)
Connect-AzAccount -ServicePrincipal -TenantId $cfg.TenantId -Credential $spnCredential -SubscriptionId $cfg.SubscriptionId | Out-Null
Write-Log "Authenticated as SPN: $($cfg.SpnAppId)" SUCCESS

# Az.Accounts 3.0+ returns .Token as SecureString; older versions return plaintext.
# Handle both so the script works regardless of module version.
$tokenResult = (Get-AzAccessToken).Token
if ($tokenResult -is [System.Security.SecureString]) {
    $armToken = $tokenResult | ConvertFrom-SecureString -AsPlainText
} else {
    $armToken = $tokenResult
}
$accountId = $cfg.SpnAppId
Write-Log "ARM access token obtained." SUCCESS

# ── Register all nodes (synchronous, parallel fan-out) ────────────────────────
Write-Log "" INFO
Write-Log "Registering $($nodes.Count) node(s) with Azure Arc..." HEADER
Write-Log "================================================================" HEADER
Write-Log "" INFO
Write-Log "Executing synchronous Invoke-Command against $($nodes.Count) node(s):" INFO
Write-Log "  Server list  : $($serverList -join ', ')" INFO
Write-Log "  Credential   : $($Credential.UserName)" INFO
Write-Log "" INFO
Write-Log "This process may take 40-90 minutes if OEM updates are required." INFO
Write-Log "The cmdlet handles reboots internally — do NOT interrupt." WARN
Write-Log "Follow the progress in Sonar (azurelocal-sonar)." INFO
Write-Log "" INFO

$startTime = Get-Date
$regError  = $null
$results   = $null

try {
    $results = Invoke-Command -ComputerName $serverList -Credential $Credential -ScriptBlock {
        param($Sub, $RG, $Tenant, $Reg, $Cld, $Token, $Acct, $GwId)
        $params = @{
            SubscriptionID = $Sub
            ResourceGroup  = $RG
            TenantID       = $Tenant
            Region         = $Reg
            Cloud          = $Cld
            ArmAccessToken = $Token
            AccountID      = $Acct
        }
        if ($GwId -ne "") { $params['ArcGatewayID'] = $GwId }
        Invoke-AzStackHciArcInitialization @params
    } -ArgumentList $cfg.SubscriptionId, $cfg.ResourceGroup, $cfg.TenantId, $cfg.Region, $cfg.Cloud, $armToken, $accountId, $cfg.ArcGatewayId |
        Sort-Object -Property PSComputerName
} catch {
    $regError = $_.Exception.Message
    Write-Log "Invoke-Command error: $regError" FAIL
}

$elapsed = (Get-Date) - $startTime
Write-Log "" INFO
Write-Log "Registration command completed in $([math]::Round($elapsed.TotalMinutes, 1)) minutes." INFO

# ── Process results & build summary ──────────────────────────────────────────
Write-Log "" INFO
Write-Log "================================================================" HEADER
Write-Log "  RESULTS" HEADER
Write-Log "================================================================" HEADER

# Build a lookup from IP → node metadata
$ipToNode = @{}
foreach ($n in $nodes) { $ipToNode[$n.ip] = $n }

$summary = @()

if ($results) {
    # Display raw output from each node
    foreach ($r in $results) {
        $nodeIP   = $r.PSComputerName
        $nodeMeta = $ipToNode[$nodeIP]
        $nodeName = if ($nodeMeta) { $nodeMeta.hostname } else { $nodeIP }
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  NODE: $nodeName  ($nodeIP)" HEADER
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        $outputStr = ($r | Out-String).Trim()
        if ($outputStr) {
            $outputStr -split "`n" | ForEach-Object { Write-Log "  $_" INFO }
        }
    }
}

# Check bootstrap status on each node to build definitive summary
Write-Log "" INFO
Write-Log "--- Checking bootstrap status on each node ---" HEADER
foreach ($node in $nodes) {
    $nodeName = $node.hostname
    $nodeIP   = $node.ip
    $status   = "Unknown"
    $errMsg   = $null

    try {
        $bsResult = Invoke-Command -ComputerName $nodeIP -Credential $Credential -ScriptBlock {
            try {
                $bs = Get-ArcBootstrapStatus -ErrorAction SilentlyContinue
                if ($bs -and $bs.Response) {
                    return [PSCustomObject]@{
                        Status  = "$($bs.Response.Status)"
                        Message = "$($bs.Response.Message)"
                    }
                }
            } catch {}
            return [PSCustomObject]@{ Status = "Unknown"; Message = "" }
        } -ErrorAction Stop

        switch ($bsResult.Status) {
            "Succeeded"  { $status = "Completed"; Write-Log "[$nodeName] Arc registration succeeded." PASS }
            "Failed"     { $status = "Failed"; $errMsg = $bsResult.Message; Write-Log "[$nodeName] Bootstrap reports Failed: $errMsg" FAIL }
            "InProgress" { $status = "InProgress"; Write-Log "[$nodeName] Bootstrap still running." WARN }
            default      { $status = $bsResult.Status; Write-Log "[$nodeName] Bootstrap status: $($bsResult.Status)" INFO }
        }
    } catch {
        $errMsg = $_.Exception.Message -replace '^.*\] ', ''
        Write-Log "[$nodeName] Could not reach node for status check: $errMsg" WARN
        $status = "Unreachable"
    }

    $summary += [PSCustomObject]@{
        Node   = $nodeName
        IP     = $nodeIP
        Status = $status
        Error  = $errMsg
    }
}

# ── Summary table ──────────────────────────────────────────────────────────
Write-Log "" INFO
Write-Log "================================================================" HEADER
Write-Log "  SUMMARY" HEADER
Write-Log "================================================================" HEADER

$tableStr = ($summary | Format-Table Node, IP, Status -AutoSize | Out-String).Trim()
Write-Host $tableStr
$tableStr | Out-File -FilePath $logFile -Append -Encoding utf8

$failCount   = @($summary | Where-Object { $_.Status -in 'Failed', 'Error', 'Unreachable' }).Count
$inProgress  = @($summary | Where-Object { $_.Status -eq 'InProgress' }).Count
$completed   = @($summary | Where-Object { $_.Status -eq 'Completed' }).Count

if ($completed -eq $nodes.Count) {
    Write-Log "" INFO
    Write-Log "All $($nodes.Count) node(s) registered with Azure Arc." PASS
    Write-Log "" INFO
    Write-Log "Proceed to Task 04: Verify Arc Registration and Connectivity." INFO
} elseif ($inProgress -gt 0 -and $failCount -eq 0) {
    Write-Log "" INFO
    Write-Log "$completed node(s) completed, $inProgress node(s) still bootstrapping." WARN
    Write-Log "Bootstrap service will complete Arc registration in the background." INFO
    Write-Log "" INFO
    Write-Log "Follow the progress in Sonar (azurelocal-sonar)." WARN
} elseif ($failCount -gt 0) {
    Write-Log "" INFO
    Write-Log "$failCount node(s) failed registration. Review output above." FAIL
    if ($completed -gt 0) { Write-Log "$completed node(s) completed successfully." INFO }
    if ($inProgress -gt 0) { Write-Log "$inProgress node(s) still bootstrapping — run Task 03 to monitor." WARN }
    Write-Log "" INFO
    Write-Log "For failed nodes, check bootstrap status:" INFO
    Write-Log '  Invoke-Command -ComputerName <ip> -Credential $cred -ScriptBlock { Get-ArcBootstrapStatus }' INFO
    Write-Log "" INFO
    Write-Log "To re-run registration on specific nodes:" INFO
    Write-Log "  .\Invoke-ArcRegistration-Orchestrated.ps1 -ConfigPath <config> -TargetNode <hostname>" INFO
    Write-Log "Log file: $logFile" INFO
    exit 1
}

Write-Log "Elapsed: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" INFO
Write-Log "Log file: $logFile" INFO

#endregion MAIN
