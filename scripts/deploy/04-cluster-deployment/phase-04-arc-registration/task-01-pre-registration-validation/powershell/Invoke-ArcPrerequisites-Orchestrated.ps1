#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-ArcPrerequisites-Orchestrated.ps1
    Validates Azure Arc registration prerequisites across all cluster nodes.

.DESCRIPTION
    Performs two categories of pre-registration validation:

    1. Identity & Permissions (runs locally on management server):
       - Verifies the service principal exists in Entra ID
       - Checks RBAC role assignments on the Arc resource group
       - Verifies the SPN secret is accessible in Key Vault

    2. Connectivity (runs on each node via PSRemoting in parallel):
       - Runs AzStackHci.EnvironmentChecker on every cluster node
       - Validates end-to-end connectivity to all required Azure endpoints

    Both checks run by default. Use -SkipIdentity or -SkipConnectivity to
    run only one category.

    Requires the AzStackHci.EnvironmentChecker module to be pre-installed on each
    node. Requires Az.Accounts, Az.Resources, and Az.KeyVault on the management
    machine for identity checks.

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to auto-detect from script location.

.PARAMETER Credential
    PSCredential for PSRemoting. If omitted, resolved from Key Vault, then interactive prompt.
    Only required when connectivity checks are enabled.

.PARAMETER TargetNode
    One or more node hostnames or IPs to validate. Defaults to all nodes in config.
    Applies to connectivity checks only.

.PARAMETER NoArcGateway
    Skip Arc Gateway validation and registration. By default, the script requires
    an Arc Gateway to be configured in infrastructure.yml (compute.azure_local.arc_gateway_enabled
    and arc_gateway_id). Set this switch only if you are not using an Arc Gateway.
    If omitted and no gateway is configured, the script blocks with an error.

.PARAMETER SkipIdentity
    Skip identity and permission checks (SPN, RBAC, Key Vault). Run connectivity only.

.PARAMETER SkipConnectivity
    Skip connectivity validation on nodes. Run identity checks only.
    Node credentials are not required when this switch is set.

.PARAMETER WhatIf
    Dry-run mode — shows what would be validated without connecting to any node or Azure.

.PARAMETER LogPath
    Override log file path. Default: ./logs/<task-folder>/<timestamp>_ArcPrerequisites.log

.EXAMPLE
    .\Invoke-ArcPrerequisites-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml

.EXAMPLE
    .\Invoke-ArcPrerequisites-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -WhatIf

.EXAMPLE
    .\Invoke-ArcPrerequisites-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -TargetNode azl-lab-01-n01

.EXAMPLE
    .\Invoke-ArcPrerequisites-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -SkipConnectivity
    Runs identity and permission checks only (SPN, RBAC, Key Vault secret).

.EXAMPLE
    .\Invoke-ArcPrerequisites-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -SkipIdentity
    Runs connectivity checks on nodes only (Environment Checker).

.NOTES
    Author:  Azure Local Cloud AzureLocalCloud
    Phase:   04-arc-registration
    Task:    01 - Pre-Registration Environment Validation
    Mode:    Read-only. No system changes.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [string[]]$TargetNode = @(),

    [switch]$NoArcGateway,

    [switch]$SkipIdentity,

    [switch]$SkipConnectivity,

    [switch]$WhatIf,

    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Log file initialization ───────────────────────────────────────────────
# Scripts are always run from the repo root, so ./logs/<task-folder>/ is CWD-relative
$scriptShortName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^Invoke-|-Orchestrated$', ''
$taskFolderName  = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf   # e.g. task-01-pre-registration-validation
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

    # compute.cluster_nodes                                          # compute.cluster_nodes
    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            nodename = $_.Key                                        # compute.cluster_nodes.<key>
            hostname = if ($_.Value.hostname) { $_.Value.hostname }  # compute.cluster_nodes.<key>.hostname
                       else { $_.Key }
            ip       = $_.Value.management_ip                        # compute.cluster_nodes.<key>.management_ip
        }
    }

    $az = $cfg.compute.azure_local                                   # compute.azure_local

    return [PSCustomObject]@{
        Nodes             = @($nodes)
        AdminUser         = $cfg.identity.accounts.account_local_admin_username   # identity.accounts.account_local_admin_username
        AdminPassUri      = $cfg.identity.accounts.account_local_admin_password   # identity.accounts.account_local_admin_password
        TenantId          = $cfg.identity.azure_identity.azure_tenant_id         # identity.azure_identity.azure_tenant_id
        SubscriptionId    = $cfg.identity.azure_identity.azure_subscription_id   # identity.azure_identity.azure_subscription_id
        SpnAppId          = $cfg.identity.service_principal.client_id             # identity.service_principal.client_id
        SpnSecretUri      = $cfg.identity.service_principal.secret               # identity.service_principal.secret
        ResourceGroup     = $az.arc_resource_group                               # compute.azure_local.arc_resource_group
        ArcGatewayEnabled = [bool]$az.arc_gateway_enabled                        # compute.azure_local.arc_gateway_enabled
        ArcGatewayId      = if ($az.arc_gateway_id) { "$($az.arc_gateway_id)" } else { "" }  # compute.azure_local.arc_gateway_id
        ArcGatewayName    = if ($az.arc_gateway_name) { "$($az.arc_gateway_name)" } else { "" }  # compute.azure_local.arc_gateway_name
    }
}

function Resolve-KeyVaultRef {
    param([string]$KvUri)
    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { Write-Log "  Not a Key Vault URI: $KvUri" "WARN"; return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]

    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Write-Log "  Retrieving '$secretName' from '$vaultName' (Az.KeyVault)..."
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { Write-Log "  Secret retrieved." "SUCCESS"; return $secret }
            Write-Log "  Az.KeyVault returned no secret." "WARN"
        } catch { Write-Log "  Az.KeyVault failed: $_" "WARN" }
        Write-Log "  Falling back to Azure CLI..." "WARN"
    } else {
        Write-Log "  Az.KeyVault module not found — trying Azure CLI..." "WARN"
    }

    try {
        $azCmd = Get-Command az -ErrorAction SilentlyContinue
        if (-not $azCmd) { Write-Log "  Azure CLI (az) not found." "WARN"; return $null }
        Write-Log "  Retrieving '$secretName' from '$vaultName' (az CLI)..."
        $tmpErr = [System.IO.Path]::GetTempFileName()
        $val    = (& az keyvault secret show --vault-name $vaultName --name $secretName --query value --output tsv --only-show-errors 2>$tmpErr)
        $azErr  = (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue).Trim()
        Remove-Item $tmpErr -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($val)) {
            $errDetail = if ($azErr) { ": $azErr" } else { " (exit $LASTEXITCODE)" }
            Write-Log "  az CLI failed$errDetail." "WARN"
            return $null
        }
        Write-Log "  Secret retrieved (az CLI)." "SUCCESS"
        return $val
    } catch { Write-Log "  az CLI failed: $_" "WARN"; return $null }
}

#endregion HELPERS

#region VALIDATION SCRIPTBLOCK

$ValidateScript = {
    # Require Environment Checker — do not install
    $mod = Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker -ErrorAction SilentlyContinue
    if (-not $mod) {
        throw "AzStackHci.EnvironmentChecker module is not installed on $env:COMPUTERNAME. Install it manually before running this validation."
    }
    Import-Module AzStackHci.EnvironmentChecker -ErrorAction Stop

    # Run connectivity validation — -Passthru returns PSObjects; without it the module only writes to console
    $results = @(Invoke-AzStackHciConnectivityValidation -Passthru -ErrorAction SilentlyContinue)

    # Serialize all useful fields — PSCustomObject survives the remoting boundary
    # Skip blank-name entries (hidden/informational records the checker emits internally)
    $summary = @()
    foreach ($r in $results) {
        if ([string]::IsNullOrWhiteSpace($r.Name)) { continue }
        $summary += [PSCustomObject]@{
            Name               = "$($r.Name)"
            Title              = "$($r.Title)"
            Status             = "$($r.Status)"
            Severity           = "$($r.Severity)"
            Service            = "$($r.Service)"
            EndPoint           = "$($r.EndPoint)"
            Description        = if ($r.Description)        { "$($r.Description)" }        else { "" }
            Remediation        = if ($r.Remediation)        { "$($r.Remediation)" }        else { "" }
            TargetResourceName = if ($r.TargetResourceName) { "$($r.TargetResourceName)" } else { "" }
            AdditionalData     = if ($r.AdditionalData)     { ($r.AdditionalData | Out-String).Trim() } else { "" }
        }
    }
    return $summary
}

#endregion VALIDATION SCRIPTBLOCK

#region MAIN

Write-Log "================================================================" HEADER
Write-Log "   Phase 04 Arc Registration — Task 01: Prerequisites Check" HEADER
Write-Log "================================================================" HEADER
Write-Log "" INFO
$checksMsg = @()
if (-not $SkipIdentity)     { $checksMsg += "Identity & Permissions" }
if (-not $SkipConnectivity) { $checksMsg += "Connectivity (Environment Checker)" }
Write-Log "  Checks  : $($checksMsg -join ' + ')" INFO
Write-Log "  Mode    : Read-only. No system changes." INFO
Write-Log "  Log     : $logFile" INFO
Write-Log "" INFO

# ── Load config ──────────────────────────────────────────────────────────────
Write-Log "Config : $ConfigPath" INFO
Write-Log "--- Loading configuration ---" HEADER

$cfg = Get-Config -Path $ConfigPath

Write-Log "Found $($cfg.Nodes.Count) node(s):" INFO
$cfg.Nodes | ForEach-Object { Write-Log "  $($_.hostname)  ($($_.ip))" INFO }

# ── Arc Gateway gate ──────────────────────────────────────────────────────────
$useArcGateway = $true
if ($NoArcGateway) {
    $useArcGateway = $false
    Write-Log "Arc Gateway : DISABLED (-NoArcGateway specified)" WARN
} elseif (-not $cfg.ArcGatewayEnabled) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  ARC GATEWAY NOT CONFIGURED" FAIL
    Write-Log "================================================================" HEADER
    Write-Log "" INFO
    Write-Log "Arc Gateway is required by default. Your infrastructure YAML has:" FAIL
    Write-Log "  arc_gateway_enabled: false (or missing)" FAIL
    Write-Log "" INFO
    Write-Log "To proceed, you must either:" INFO
    Write-Log "  1. Deploy an Arc Gateway and update infrastructure.yml:" INFO
    Write-Log "       compute.azure_local.arc_gateway_enabled: true" INFO
    Write-Log "       compute.azure_local.arc_gateway_id: /subscriptions/.../gateways/<name>" INFO
    Write-Log "  2. Run with -NoArcGateway if you do not want to use a gateway" INFO
    Write-Log "" INFO
    Write-Log "Log file: $logFile" INFO
    exit 1
} elseif ([string]::IsNullOrWhiteSpace($cfg.ArcGatewayId)) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  ARC GATEWAY ID MISSING" FAIL
    Write-Log "================================================================" HEADER
    Write-Log "" INFO
    Write-Log "arc_gateway_enabled is true but arc_gateway_id is empty." FAIL
    Write-Log "Update infrastructure.yml with the full resource ID:" INFO
    Write-Log "  compute.azure_local.arc_gateway_id: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.HybridCompute/gateways/<name>" INFO
    Write-Log "" INFO
    Write-Log "Or run with -NoArcGateway to skip gateway usage." INFO
    Write-Log "Log file: $logFile" INFO
    exit 1
} else {
    Write-Log "Arc Gateway : $($cfg.ArcGatewayName) (enabled)" INFO
    Write-Log "  Gateway ID : $($cfg.ArcGatewayId)" INFO
}

# ── Apply TargetNode filter (for connectivity checks) ─────────────────────────
$nodes = $cfg.Nodes
if ($TargetNode.Count -gt 0) {
    $nodes = @($nodes | Where-Object { $TargetNode -contains $_.hostname -or $TargetNode -contains $_.nodename -or $TargetNode -contains $_.ip })
    if ($nodes.Count -eq 0) { throw "No nodes matched filter: $($TargetNode -join ', ')" }
    Write-Log "Node filter applied — running against: $($nodes.hostname -join ', ')" WARN
}

# ── WhatIf — dry-run mode ────────────────────────────────────────────────────
if ($WhatIf) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  WHATIF — Dry-run mode. No changes will be made." HEADER
    Write-Log "================================================================" HEADER
    Write-Log "" INFO

    if (-not $SkipIdentity) {
        Write-Log "IDENTITY & PERMISSION CHECKS (runs locally):" HEADER
        Write-Log "  WHATIF: Would verify SPN exists in Entra ID (AppId: $($cfg.SpnAppId))" INFO
        Write-Log "  WHATIF: Would check RBAC roles on resource group '$($cfg.ResourceGroup)'" INFO
        if ($cfg.SpnSecretUri -match '^keyvault://([^/]+)/(.+)$') {
            Write-Log "  WHATIF: Would verify KV secret '$($Matches[2])' in vault '$($Matches[1])'" INFO
        }
        if ($useArcGateway) {
            Write-Log "  WHATIF: Would verify Arc Gateway exists: $($cfg.ArcGatewayId)" INFO
        } else {
            Write-Log "  WHATIF: Arc Gateway check SKIPPED (-NoArcGateway)" WARN
        }
        Write-Log "  Requires: Active Azure session (Connect-AzAccount)" INFO
        Write-Log "  Requires: Az.Accounts, Az.Resources, Az.KeyVault modules" INFO
        Write-Log "" INFO
    }

    if (-not $SkipConnectivity) {
        Write-Log "CONNECTIVITY VALIDATION — $($nodes.Count) node(s):" HEADER
        Write-Log "" INFO

        foreach ($n in $nodes) {
            Write-Log "────────────────────────────────────────────────────────────" HEADER
            Write-Log "  NODE: $($n.hostname)  ($($n.ip))" HEADER
            Write-Log "────────────────────────────────────────────────────────────" HEADER
            Write-Log "  WHATIF: Requires AzStackHci.EnvironmentChecker module (pre-installed)" INFO
            Write-Log "  WHATIF: Would run Invoke-AzStackHciConnectivityValidation" INFO
            Write-Log "  WHATIF: Validates connectivity to:" INFO
            Write-Log "    - Azure Resource Manager (ARM) endpoint" INFO
            Write-Log "    - Azure Active Directory (Entra ID) endpoint" INFO
            Write-Log "    - Azure Arc endpoints" INFO
            Write-Log "    - Microsoft Graph API endpoints" INFO
            Write-Log "    - Azure Storage endpoints" INFO
            Write-Log "    - Windows Update endpoints" INFO
            Write-Log "" INFO
        }

        Write-Log "Connection method : Invoke-Command -ComputerName <ip> -Credential $($cfg.AdminUser) -AsJob" INFO
        Write-Log "Job timeout       : 300 seconds per node" INFO
    }

    Write-Log "" INFO
    Write-Log "Re-run without -WhatIf to execute." INFO
    Write-Log "Log file: $logFile" INFO
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# IDENTITY & PERMISSION CHECKS (local — Azure-side prerequisites)
# ══════════════════════════════════════════════════════════════════════════════
$identityPassed = 0
$identityFailed = 0
$identityWarned = 0

if (-not $SkipIdentity) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  IDENTITY & PERMISSION CHECKS" HEADER
    Write-Log "================================================================" HEADER
    Write-Log "" INFO

    # Verify Azure context exists
    $azCtx = $null
    try {
        $azCtx = Get-AzContext -ErrorAction Stop
    } catch {
        Write-Log "Az module not available. Install Az.Accounts, Az.Resources, Az.KeyVault for identity checks." FAIL
        $identityFailed++
    }

    if ($azCtx -and $azCtx.Account) {
        Write-Log "Azure context : $($azCtx.Account.Id)" INFO
        Write-Log "Tenant        : $($azCtx.Tenant.Id)" INFO
        Write-Log "Subscription  : $($azCtx.Subscription.Id)" INFO
        Write-Log "" INFO

        $spnAppId     = $cfg.SpnAppId          # identity.service_principal.client_id
        $arcRg        = $cfg.ResourceGroup      # compute.azure_local.arc_resource_group
        $spnSecretUri = $cfg.SpnSecretUri       # identity.service_principal.secret

        # --- Check 1: Verify SPN exists in Entra ID ---
        Write-Log "--- Check 1: Service Principal ---" HEADER
        $spn = $null
        try {
            $spn = Get-AzADServicePrincipal -ApplicationId $spnAppId -ErrorAction Stop
        } catch {
            Write-Log "  Error querying Entra ID: $($_.Exception.Message)" FAIL
        }
        if ($spn) {
            Write-Log "  [PASS] SPN exists: $($spn.DisplayName) (AppId: $spnAppId)" PASS
            $identityPassed++
        } elseif ($identityFailed -eq 0) {
            Write-Log "  [FAIL] SPN not found for AppId: $spnAppId" FAIL
            $identityFailed++
        }

        # --- Check 2: Verify RBAC roles on the Arc resource group ---
        Write-Log "--- Check 2: RBAC Roles on '$arcRg' ---" HEADER
        if ($spn) {
            $roles = @()
            try {
                $roles = @(Get-AzRoleAssignment -ObjectId $spn.Id -ResourceGroupName $arcRg -ErrorAction Stop)
            } catch {
                Write-Log "  Error querying RBAC: $($_.Exception.Message)" FAIL
            }
            $acceptedRoles = @(
                'Contributor',
                'Azure Connected Machine Onboarding',
                'Azure Connected Machine Resource Administrator',
                'Azure Stack HCI Administrator'
            )
            $matched = @($roles | Where-Object { $_.RoleDefinitionName -in $acceptedRoles })
            if ($matched.Count -gt 0) {
                $matched | ForEach-Object { Write-Log "  [PASS] Role: $($_.RoleDefinitionName)" PASS }
                $identityPassed++
            } else {
                Write-Log "  [FAIL] No recognized Arc role found on '$arcRg'" FAIL
                Write-Log "         Required: Azure Connected Machine Onboarding (minimum)" WARN
                if ($roles.Count -gt 0) {
                    $roles | ForEach-Object { Write-Log "         Found: $($_.RoleDefinitionName)" INFO }
                }
                $identityFailed++
            }
        } else {
            Write-Log "  [SKIP] Cannot check RBAC — SPN not found" WARN
            $identityWarned++
        }

        # --- Check 3: Verify Key Vault secret accessible ---
        Write-Log "--- Check 3: Key Vault Secret ---" HEADER
        if ($spnSecretUri -match '^keyvault://([^/]+)/(.+)$') {
            $kvVault  = $Matches[1]
            $kvSecret = $Matches[2]
            try {
                $secret = Get-AzKeyVaultSecret -VaultName $kvVault -Name $kvSecret -ErrorAction Stop
                if ($secret -and $secret.Enabled) {
                    Write-Log "  [PASS] KV secret '$kvSecret' accessible in '$kvVault'" PASS
                    if ($secret.Expires -and $secret.Expires -lt (Get-Date).AddDays(30)) {
                        Write-Log "  [WARN] Secret expires $($secret.Expires) — renew soon" WARN
                        $identityWarned++
                    }
                    $identityPassed++
                } elseif ($secret) {
                    Write-Log "  [WARN] KV secret '$kvSecret' exists but is DISABLED" WARN
                    $identityWarned++
                } else {
                    Write-Log "  [FAIL] KV secret '$kvSecret' not found in '$kvVault'" FAIL
                    $identityFailed++
                }
            } catch {
                Write-Log "  [FAIL] Cannot access KV secret: $($_.Exception.Message)" FAIL
                $identityFailed++
            }
        } else {
            Write-Log "  [WARN] No keyvault:// URI configured for SPN secret" WARN
            $identityWarned++
        }

        # --- Check 4: Verify Arc Gateway exists in Azure ---
        Write-Log "--- Check 4: Arc Gateway ---" HEADER
        if (-not $useArcGateway) {
            Write-Log "  [SKIP] Arc Gateway check skipped (-NoArcGateway)" WARN
            $identityWarned++
        } elseif ([string]::IsNullOrWhiteSpace($cfg.ArcGatewayId)) {
            Write-Log "  [FAIL] Arc Gateway ID is empty in infrastructure.yml" FAIL
            Write-Log "         Set compute.azure_local.arc_gateway_id or use -NoArcGateway" WARN
            $identityFailed++
        } else {
            try {
                $gwResource = Get-AzResource -ResourceId $cfg.ArcGatewayId -ErrorAction Stop
                if ($gwResource) {
                    Write-Log "  [PASS] Arc Gateway exists: $($gwResource.Name) ($($gwResource.ResourceType))" PASS
                    # Check gateway provisioning state if available
                    if ($gwResource.Properties -and $gwResource.Properties.provisioningState) {
                        $gwState = "$($gwResource.Properties.provisioningState)"
                        if ($gwState -eq 'Succeeded') {
                            Write-Log "  [PASS] Gateway provisioning state: $gwState" PASS
                        } else {
                            Write-Log "  [WARN] Gateway provisioning state: $gwState (expected: Succeeded)" WARN
                            $identityWarned++
                        }
                    }
                    $identityPassed++
                } else {
                    Write-Log "  [FAIL] Arc Gateway not found: $($cfg.ArcGatewayId)" FAIL
                    Write-Log "         Deploy the gateway first, or run with -NoArcGateway" WARN
                    $identityFailed++
                }
            } catch {
                $gwErr = $_.Exception.Message
                if ($gwErr -match 'ResourceNotFound|NotFound|does not exist') {
                    Write-Log "  [FAIL] Arc Gateway does not exist: $($cfg.ArcGatewayId)" FAIL
                    Write-Log "         Deploy the gateway first, or run with -NoArcGateway" WARN
                    $identityFailed++
                } else {
                    Write-Log "  [FAIL] Cannot verify Arc Gateway: $gwErr" FAIL
                    $identityFailed++
                }
            }
        }
    } elseif ($identityFailed -eq 0) {
        Write-Log "No active Azure session. Run Connect-AzAccount first, or use -SkipIdentity." FAIL
        $identityFailed++
    }

    # Identity section summary
    Write-Log "" INFO
    $idTotal = $identityPassed + $identityFailed + $identityWarned
    if ($identityFailed -gt 0) {
        Write-Log "Identity: $identityFailed FAILED, $identityPassed passed, $identityWarned warnings (of $idTotal)" FAIL
    } elseif ($identityWarned -gt 0) {
        Write-Log "Identity: $identityPassed passed, $identityWarned warnings (of $idTotal)" WARN
    } else {
        Write-Log "Identity: All $identityPassed checks passed" PASS
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# CONNECTIVITY VALIDATION (remote — per-node Environment Checker)
# ══════════════════════════════════════════════════════════════════════════════
$connectivitySummary = @()

if (-not $SkipConnectivity) {
    Write-Log "" INFO
    Write-Log "================================================================" HEADER
    Write-Log "  CONNECTIVITY VALIDATION" HEADER
    Write-Log "================================================================" HEADER
    Write-Log "" INFO

    # ── Resolve credentials ───────────────────────────────────────────────────
    # CREDENTIAL RESOLUTION ORDER:
    # 1. -Credential parameter (passed directly)
    # 2. Key Vault (Az.KeyVault module, then az CLI fallback)
    # 3. Interactive Get-Credential prompt
    Write-Log "--- Resolving credentials ---" HEADER
    if (-not $Credential) {
        $adminUser    = $cfg.AdminUser                               # identity.accounts.account_local_admin_username
        $adminPassUri = $cfg.AdminPassUri                            # identity.accounts.account_local_admin_password
        Write-Log "Resolving credentials from Key Vault..."
        $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
        if ($adminPass) {
            $Credential = [PSCredential]::new($adminUser, (ConvertTo-SecureString $adminPass -AsPlainText -Force))
            Write-Log "Credentials resolved for '$adminUser'." SUCCESS
        } else {
            Write-Log "Key Vault unavailable — prompting for credentials." WARN
            $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $adminUser
        }
    } else {
        Write-Log "Credentials provided via -Credential parameter." SUCCESS
    }

    Write-Log "" INFO
    Write-Log "Ready. Validating $($nodes.Count) node(s) in parallel..." HEADER
    Write-Log "================================================================" HEADER

    # ── Launch parallel validation jobs ──────────────────────────────────────
    $jobTimeout = 300   # 5 minutes per node
    $jobs       = [ordered]@{}

    Write-Log "Launching validation jobs in parallel..." HEADER
    foreach ($node in $nodes) {
        try {
            $job = Invoke-Command `
                -ComputerName $node.ip `
                -Credential $Credential `
                -ScriptBlock $ValidateScript `
                -AsJob `
                -JobName "ArcPreReq-$($node.hostname)" `
                -ErrorAction Stop
            $jobs[$node.hostname] = @{ Job = $job; Node = $node; Error = $null }
            Write-Log "  [$($node.hostname)] Job submitted ($($node.ip))" INFO
        } catch {
            $errMsg = $_.Exception.Message -replace '^.*\] ', ''
            $jobs[$node.hostname] = @{ Job = $null; Node = $node; Error = $errMsg }
            Write-Log "  [$($node.hostname)] Failed to submit: $errMsg" FAIL
        }
    }

    # ── Wait for all jobs ─────────────────────────────────────────────────────
    $activeJobs = @($jobs.Values | Where-Object { $_.Job } | ForEach-Object { $_.Job })
    if ($activeJobs.Count -gt 0) {
        Write-Log "Waiting for $($activeJobs.Count) job(s) to complete (timeout=${jobTimeout}s)..." INFO
        $null = $activeJobs | Wait-Job -Timeout $jobTimeout
    }

    # ── Collect and display results per node ──────────────────────────────────
    Write-Log "" INFO
    foreach ($entry in $jobs.GetEnumerator()) {
        $nodeName = $entry.Key
        $node     = $entry.Value.Node
        $job      = $entry.Value.Job
        $jobError = $entry.Value.Error

        Write-Log "================================================================" HEADER
        Write-Log "  NODE: $nodeName  ($($node.ip))" HEADER
        Write-Log "================================================================" HEADER

        $nodeChecksPassed = 0
        $nodeChecksFailed = 0
        $nodeChecksWarned = 0
        $nodeError        = $jobError
        $rawResults       = $null

        if ($job) {
            if ($job.State -eq 'Running') {
                $job | Stop-Job -ErrorAction SilentlyContinue
                $nodeError = "Job timed out after ${jobTimeout}s"
                Write-Log "[$nodeName] $nodeError" FAIL
            } elseif ($job.State -eq 'Failed') {
                $nodeError = ($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message }) -join '; '
                if (-not $nodeError) { $nodeError = "Remote job failed (unknown reason)" }
                Write-Log "[$nodeName] Job failed: $nodeError" FAIL
            } else {
                try {
                    $rawResults = Receive-Job -Job $job -ErrorAction Stop
                } catch {
                    $nodeError = $_.Exception.Message -replace '^.*\] ', ''
                    Write-Log "[$nodeName] Error receiving results: $nodeError" FAIL
                }
            }
        } elseif (-not $nodeError) {
            $nodeError = "No job was created"
            Write-Log "[$nodeName] $nodeError" FAIL
        } else {
            Write-Log "[$nodeName] Connection failed: $nodeError" FAIL
        }

        if ($rawResults) {
            # ── Write raw checker console output to log ──────────────────────────
            # Background jobs capture Write-Host in the Information stream
            $checkerRawOutput = $job.ChildJobs[0].Information | ForEach-Object { $_.MessageData.ToString() }
            if ($checkerRawOutput) {
                "" | Out-File -FilePath $logFile -Append -Encoding utf8
                "  --- Environment Checker Output ---" | Out-File -FilePath $logFile -Append -Encoding utf8
                $checkerRawOutput | ForEach-Object { "  $_" | Out-File -FilePath $logFile -Append -Encoding utf8 }
                "  --- End Checker Output ---" | Out-File -FilePath $logFile -Append -Encoding utf8
                "" | Out-File -FilePath $logFile -Append -Encoding utf8
            }

            # ── Structured per-check results ──────────────────────────────────────
            foreach ($r in $rawResults) {
                # Skip blank/hidden entries the checker emits with no name (informational/internal records)
                if ([string]::IsNullOrWhiteSpace($r.Name)) { continue }
                $label   = "$($r.Name)".PadRight(60)
                $ep      = if ($r.EndPoint)        { "  Endpoint : $($r.EndPoint)" }        else { "" }
                $desc    = if ($r.Description)    { "  Detail   : $($r.Description)" }    else { "" }
                $remed   = if ($r.Remediation)    { "  Fix      : $($r.Remediation)" }    else { "" }
                $addl    = if ($r.AdditionalData) { "  Data     : $($r.AdditionalData)" } else { "" }
                switch -Regex ("$($r.Status)") {
                    'Succeeded|Pass|SUCCESS|Healthy' {
                        Write-Host "  [PASS] $label $($r.Status)" -ForegroundColor Green
                        "  [PASS] $label $($r.Status)" | Out-File -FilePath $logFile -Append -Encoding utf8
                        if ($ep)    { "$ep"    | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        if ($desc)  { "$desc"  | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        $nodeChecksPassed++
                    }
                    'Warn' {
                        Write-Host "  [WARN] $label $($r.Status)" -ForegroundColor Yellow
                        "  [WARN] $label $($r.Status)" | Out-File -FilePath $logFile -Append -Encoding utf8
                        if ($ep)    { "$ep"    | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        if ($desc)  { "$desc"  | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        if ($addl)  { "$addl"  | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        if ($remed) { "$remed" | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        $nodeChecksWarned++
                    }
                    default {
                        Write-Host "  [FAIL] $label $($r.Status)" -ForegroundColor Red
                        "  [FAIL] $label $($r.Status)" | Out-File -FilePath $logFile -Append -Encoding utf8
                        if ($ep)    { "$ep"    | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        if ($desc)  { "$desc"  | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        if ($addl)  { "$addl"  | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        if ($remed) { "$remed" | Out-File -FilePath $logFile -Append -Encoding utf8 }
                        $nodeChecksFailed++
                    }
                }
            }
        }

        $total  = $nodeChecksPassed + $nodeChecksFailed + $nodeChecksWarned
        $status = if ($nodeError) { "Error" }
                  elseif ($nodeChecksFailed -gt 0) { "Failed ($nodeChecksFailed/$total)" }
                  elseif ($nodeChecksWarned -gt 0) { "Warnings ($nodeChecksWarned/$total)" }
                  else { "All PASS ($nodeChecksPassed/$total)" }

        Write-Log "[$nodeName] $status" $(if ($nodeError -or $nodeChecksFailed -gt 0) { 'FAIL' } elseif ($nodeChecksWarned) { 'WARN' } else { 'PASS' })

        $connectivitySummary += [PSCustomObject]@{
            Node     = $nodeName
            IP       = $node.ip
            Passed   = $nodeChecksPassed
            Warned   = $nodeChecksWarned
            Failed   = $nodeChecksFailed
            Status   = $status
            Error    = $nodeError
        }
    }

    # ── Cleanup jobs ──────────────────────────────────────────────────────────
    $activeJobs | Remove-Job -Force -ErrorAction SilentlyContinue
}

# ══════════════════════════════════════════════════════════════════════════════
# COMBINED SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
Write-Log "" INFO
Write-Log "================================================================" HEADER
Write-Log "  SUMMARY" HEADER
Write-Log "================================================================" HEADER

$exitCode = 0

# Identity summary
if (-not $SkipIdentity) {
    $idTotal = $identityPassed + $identityFailed + $identityWarned
    if ($identityFailed -gt 0) {
        Write-Log "Identity & Permissions : $identityFailed FAILED, $identityPassed passed, $identityWarned warnings (of $idTotal)" FAIL
        $exitCode = 1
    } elseif ($identityWarned -gt 0) {
        Write-Log "Identity & Permissions : $identityPassed passed, $identityWarned warnings (of $idTotal)" WARN
    } else {
        Write-Log "Identity & Permissions : All $identityPassed checks passed" PASS
    }
}

# Connectivity summary
if (-not $SkipConnectivity) {
    if ($connectivitySummary.Count -gt 0) {
        $tableStr = ($connectivitySummary | Format-Table Node, IP, Passed, Warned, Failed, Status -AutoSize | Out-String).Trim()
        Write-Host $tableStr
        $tableStr | Out-File -FilePath $logFile -Append -Encoding utf8
    }

    $totalConnFailed = @($connectivitySummary | Where-Object { $_.Failed -gt 0 -or $_.Error }).Count
    if ($totalConnFailed -eq 0 -and @($connectivitySummary | Where-Object { $_.Warned -gt 0 }).Count -eq 0) {
        Write-Log "Connectivity           : All $($nodes.Count) node(s) passed" PASS
    } elseif ($totalConnFailed -eq 0) {
        Write-Log "Connectivity           : All $($nodes.Count) node(s) passed with warnings" WARN
    } else {
        Write-Log "Connectivity           : $totalConnFailed node(s) had failures" FAIL
        $exitCode = 1
    }
}

Write-Log "" INFO
if ($exitCode -eq 0) {
    Write-Log "All checks passed. Proceed to Task 02: Register Nodes with Azure Arc." PASS
} else {
    Write-Log "Some checks failed. Resolve issues before proceeding to Task 02." FAIL
}
Write-Log "Log file: $logFile" INFO

exit $exitCode

#endregion MAIN
