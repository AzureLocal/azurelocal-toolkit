<#
.SYNOPSIS
    Invoke-VerifyADPrerequisites-Orchestrated.ps1
    Verifies Active Directory prerequisites on cluster nodes before ARM template deployment.

.DESCRIPTION
    Runs from the management/jump box. Reads AD configuration from infrastructure.yml,
    connects to each node over PSRemoting, and verifies:
      - Domain connectivity (Test-ComputerSecureChannel)
      - OU existence (Get-ADOrganizationalUnit)
      - LCM service account has GenericAll delegation on OU

    infrastructure.yml paths used:
      cluster_arm_deployment.domain_fqdn               - AD domain FQDN
      cluster_arm_deployment.domain_ou_path             - OU distinguished name
      accounts.lcm_admin.username                       - LCM service account name
      compute.cluster_nodes[].management_ip             - Node PSRemoting targets
      compute.cluster_nodes[] (key name)                - Node hostname (display only)
      identity.accounts.account_local_admin_username    - For credential resolution
      identity.accounts.account_local_admin_password    - For credential resolution (KV ref)

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-discovers infrastructure*.yml if not provided.

.PARAMETER Credential
    Override credential for PSRemoting to nodes. If not provided, resolved via
    Key Vault then interactive prompt.

.PARAMETER TargetNode
    Limit execution to one or more specific nodes by hostname. Empty = run all nodes.

.PARAMETER WhatIf
    Dry-run mode — logs what would happen without making connections.

.PARAMETER LogPath
    Override log file path. Default: .\logs\task-01-initiate-deployment-via-arm-template\<timestamp>.log

.PARAMETER DomainFqdn
    Override domain FQDN. Takes precedence over cluster_arm_deployment.domain_fqdn.

.PARAMETER DomainOuPath
    Override OU path. Takes precedence over cluster_arm_deployment.domain_ou_path.

.PARAMETER LcmUsername
    Override LCM service account name. Takes precedence over accounts.lcm_admin.username.

.EXAMPLE
    .\Invoke-VerifyADPrerequisites-Orchestrated.ps1 -ConfigPath .\configs\infrastructure.yml

.EXAMPLE
    .\Invoke-VerifyADPrerequisites-Orchestrated.ps1 -TargetNode iic-01-n01 -WhatIf

.EXAMPLE
    .\Invoke-VerifyADPrerequisites-Orchestrated.ps1 -ConfigPath .\configs\infrastructure.yml -Credential (Get-Credential)

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-01-initiate-deployment-via-arm-template (AD prerequisite verification)
    Execution:    Run from management/jump box (PSRemoting outbound to cluster nodes)
    Script Type:  Orchestrated (Invoke-* pattern with PSRemoting)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetNode = @(),

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "",

    # YAML-overridable parameters
    [Parameter(Mandatory = $false)]
    [string]$DomainFqdn = "",

    [Parameter(Mandatory = $false)]
    [string]$DomainOuPath = "",

    [Parameter(Mandatory = $false)]
    [string]$LcmUsername = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region HELPERS

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "SUCCESS" { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }

    if ($script:LogFile) {
        "[$ts] [$Level] $Message" | Add-Content -Path $script:LogFile -ErrorAction SilentlyContinue
    }
}

function Resolve-ConfigPath {
    param([string]$Provided)

    if ($Provided -ne "" -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }

    $searchPaths = @(
        (Join-Path (Get-Location).Path "configs"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\..\configs"),
        "C:\configs",
        "C:\AzureLocal\configs"
    )

    $found = @()
    foreach ($dir in $searchPaths) {
        if (Test-Path $dir) {
            $found += Get-ChildItem -Path $dir -Filter "infrastructure*.yml" -File -ErrorAction SilentlyContinue
        }
    }

    $found = @($found | Sort-Object FullName -Unique)

    if ($found.Count -eq 0) {
        throw "No infrastructure*.yml found. Pass -ConfigPath or place it in a standard location."
    }

    if ($found.Count -eq 1) {
        Write-Log "Config: $($found[0].FullName)"
        return $found[0].FullName
    }

    Write-Log "Multiple config files found:" "WARN"
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host "  [$($i+1)] $($found[$i].FullName)" -ForegroundColor Yellow
    }
    $choice = Read-Host "Select config [1-$($found.Count)]"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $found.Count) { throw "Invalid selection." }
    return $found[$idx].FullName
}

function Resolve-KeyVaultRef {
    param([string]$Uri, [string]$Label = "secret")

    if ($Uri -notmatch '^keyvault://([^/]+)/(.+)$') {
        Write-Log "Not a Key Vault URI: $Uri" "WARN"
        return $null
    }

    $vaultName  = $Matches[1]
    $secretName = $Matches[2]

    # Try Az.KeyVault module
    try {
        $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -ErrorAction Stop
        Write-Log "Resolved $Label from Key Vault ($vaultName/$secretName) via Az.KeyVault" "SUCCESS"
        return $secret.SecretValue
    }
    catch {
        Write-Log "Az.KeyVault failed for $Label, trying az CLI..." "WARN"
    }

    # Fallback: az CLI
    try {
        $value = az keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $value) {
            $secure = ConvertTo-SecureString $value -AsPlainText -Force
            Write-Log "Resolved $Label from Key Vault ($vaultName/$secretName) via az CLI" "SUCCESS"
            return $secure
        }
    }
    catch { }

    Write-Log "Could not resolve $Label from Key Vault ($vaultName/$secretName)" "WARN"
    return $null
}

function Get-ClusterConfig {
    param([hashtable]$Yaml)

    $nodes = @()
    foreach ($node in $Yaml.compute.cluster_nodes) {
        $nodes += [pscustomobject]@{
            Name        = $node.name                       # compute.cluster_nodes[].name
            ManagementIP = $node.management_ip             # compute.cluster_nodes[].management_ip
        }
    }
    return $nodes
}

#endregion HELPERS

#region LOGGING

$taskFolderName = "task-01-initiate-deployment-via-arm-template"
if ($LogPath -ne "") {
    $script:LogFile = $LogPath
}
else {
    $logDir = Join-Path (Get-Location).Path "logs\$taskFolderName"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $script:LogFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd')_$(Get-Date -Format 'HHmmss')_Verify-ADPrerequisites.log"
}

#endregion LOGGING

#region MAIN

Write-Log "========================================" "HEADER"
Write-Log " Verify Active Directory Prerequisites" "HEADER"
Write-Log "========================================" "HEADER"

# --- Resolve config ---
$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Using config: $configFile"

# --- Load YAML ---
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "Module 'powershell-yaml' is required. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop
$yaml = Get-Content -Path $configFile -Raw | ConvertFrom-Yaml

# --- Resolve values (parameter override > YAML) ---
$domainFqdn = if ($DomainFqdn -ne "") { $DomainFqdn }
              else { $yaml.cluster_arm_deployment.domain_fqdn }                 # cluster_arm_deployment.domain_fqdn

$ouPath     = if ($DomainOuPath -ne "") { $DomainOuPath }
              else { $yaml.cluster_arm_deployment.domain_ou_path }              # cluster_arm_deployment.domain_ou_path

$lcmUser    = if ($LcmUsername -ne "") { $LcmUsername }
              else { $yaml.accounts.lcm_admin.username }                        # accounts.lcm_admin.username

Write-Log "Domain FQDN: $domainFqdn"
Write-Log "OU Path:     $ouPath"
Write-Log "LCM Account: $lcmUser"

# --- Get cluster nodes ---
$allNodes = Get-ClusterConfig -Yaml $yaml

if ($TargetNode.Count -gt 0) {
    $nodes = $allNodes | Where-Object { $_.Name -in $TargetNode }
    if ($nodes.Count -eq 0) { throw "No matching nodes found for: $($TargetNode -join ', ')" }
}
else {
    $nodes = $allNodes
}

Write-Log "Target nodes: $($nodes.Name -join ', ') ($($nodes.Count) node(s))"

# --- Resolve credentials ---
if (-not $Credential) {
    $kvUsername = $yaml.identity.accounts.account_local_admin_username           # identity.accounts.account_local_admin_username
    $kvPassword = $yaml.identity.accounts.account_local_admin_password          # identity.accounts.account_local_admin_password

    $securePwd = $null
    if ($kvPassword -match '^keyvault://') {
        $securePwd = Resolve-KeyVaultRef -Uri $kvPassword -Label "local admin password"
    }

    if ($securePwd) {
        $Credential = New-Object PSCredential($kvUsername, $securePwd)
        Write-Log "Credential resolved from Key Vault for: $kvUsername" "SUCCESS"
    }
    else {
        Write-Log "Key Vault unavailable — prompting for credentials" "WARN"
        $Credential = Get-Credential -UserName $kvUsername -Message "Enter local admin credentials for node access"
    }
}

# --- WhatIf check ---
if ($WhatIf) {
    Write-Log "[WhatIf] Would verify AD prerequisites:" "WARN"
    Write-Log "  Domain:   $domainFqdn" "WARN"
    Write-Log "  OU:       $ouPath" "WARN"
    Write-Log "  LCM User: $lcmUser" "WARN"
    foreach ($node in $nodes) {
        Write-Log "  Node:     $($node.Name) ($($node.ManagementIP))" "WARN"
    }
    Write-Log "========================================" "HEADER"
    Write-Log " WhatIf — No changes made" "HEADER"
    Write-Log "========================================" "HEADER"
    return
}

# --- Verify domain connectivity from each node ---
Write-Log "" "INFO"
Write-Log "--- Step 1: Domain Connectivity ---" "HEADER"
$allPassed = $true

foreach ($node in $nodes) {
    Write-Log "Testing domain connectivity on $($node.Name) ($($node.ManagementIP))..."

    try {
        $result = Invoke-Command -ComputerName $node.ManagementIP -Credential $Credential -ScriptBlock {
            Test-ComputerSecureChannel -ErrorAction SilentlyContinue
        }

        if ($result) {
            Write-Log "  $($node.Name): Domain secure channel OK" "SUCCESS"
        }
        else {
            Write-Log "  $($node.Name): Domain secure channel FAILED" "ERROR"
            $allPassed = $false
        }
    }
    catch {
        Write-Log "  $($node.Name): Connection failed — $($_.Exception.Message)" "ERROR"
        $allPassed = $false
    }
}

# --- Verify OU exists ---
Write-Log "" "INFO"
Write-Log "--- Step 2: OU Verification ---" "HEADER"

try {
    $ou = Get-ADOrganizationalUnit -Identity $ouPath -ErrorAction Stop
    Write-Log "OU exists: $ouPath" "SUCCESS"
}
catch {
    Write-Log "OU not found: $ouPath — $($_.Exception.Message)" "ERROR"
    $allPassed = $false
}

# --- Verify LCM account delegation ---
Write-Log "" "INFO"
Write-Log "--- Step 3: LCM Account Delegation ---" "HEADER"

try {
    $acl = Get-Acl "AD:\$ouPath" -ErrorAction Stop
    $delegation = $acl.Access | Where-Object {
        $_.IdentityReference -like "*$lcmUser*" -and
        $_.ActiveDirectoryRights -match "GenericAll"
    }

    if ($delegation) {
        Write-Log "LCM account ($lcmUser) has GenericAll on OU" "SUCCESS"
        $delegation | ForEach-Object {
            Write-Log "  Identity: $($_.IdentityReference) | Rights: $($_.ActiveDirectoryRights)"
        }
    }
    else {
        Write-Log "LCM account ($lcmUser) does NOT have GenericAll on OU: $ouPath" "ERROR"
        Write-Log "  Delegate 'Full Control' to $lcmUser on $ouPath" "WARN"
        $allPassed = $false
    }
}
catch {
    Write-Log "Could not read ACL on OU: $($_.Exception.Message)" "ERROR"
    $allPassed = $false
}

# --- Summary ---
Write-Log "" "INFO"
Write-Log "========================================" "HEADER"
if ($allPassed) {
    Write-Log " AD Prerequisites: ALL PASSED" "SUCCESS"
}
else {
    Write-Log " AD Prerequisites: FAILED — fix issues above before deploying" "ERROR"
}
Write-Log "========================================" "HEADER"
Write-Log "Log: $($script:LogFile)"

#endregion MAIN
