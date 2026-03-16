<#
.SYNOPSIS
    Test-ADDomainStatus.ps1
    Verifies Active Directory domain join and trust status on all cluster nodes
    after ARM template deployment.

.DESCRIPTION
    Config-driven script (Option 2). Reads infrastructure.yml to determine node IPs,
    domain FQDN, and OU path, then verifies:
      - Each node is joined to the expected domain
      - Secure channel trust is healthy on each node
      - Cluster computer objects exist in the correct OU
      - LCM service account delegation is intact

    infrastructure.yml paths used:
      compute.cluster_nodes[*].ipv4_address                    - Node IPs
      cluster_arm_deployment.domain_fqdn                       - Expected domain FQDN
      cluster_arm_deployment.domain_ou_path                    - Expected OU
      accounts.lcm_admin.username                              - LCM service account
      cluster_arm_deployment.cluster_name                      - Cluster name

    Requires:
      - ActiveDirectory module
      - PSRemoting access to cluster nodes
      - Credential with domain read access

.PARAMETER ConfigPath
    Path to infrastructure.yml.

.PARAMETER Credential
    PSCredential for PSRemoting to nodes. If omitted, uses current session credentials.

.PARAMETER LogPath
    Override log file path.

.EXAMPLE
    .\Test-ADDomainStatus.ps1 -ConfigPath .\configs\infrastructure.yml

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        05-cluster-deployment
    Task:         task-02-verify-deployment-completion (AD domain status)
    Execution:    Run from management/jump box with AD module and PSRemoting access
    Script Type:  Config-driven (Option 2)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ""
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
        (Join-Path $PSScriptRoot "..\..\..\..\..\..\..\..\configs")
    )
    $found = @()
    foreach ($dir in $searchPaths) {
        if (Test-Path $dir) {
            $found += Get-ChildItem -Path $dir -Filter "infrastructure*.yml" -File -ErrorAction SilentlyContinue
        }
    }
    $found = @($found | Sort-Object FullName -Unique)
    if ($found.Count -eq 0) { throw "No infrastructure*.yml found." }
    if ($found.Count -eq 1) { return $found[0].FullName }
    Write-Log "Multiple config files found:" "WARN"
    for ($i = 0; $i -lt $found.Count; $i++) { Write-Host "  [$($i+1)] $($found[$i].FullName)" -ForegroundColor Yellow }
    $choice = Read-Host "Select config [1-$($found.Count)]"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $found.Count) { throw "Invalid selection." }
    return $found[$idx].FullName
}

#endregion HELPERS

#region LOGGING

$taskFolderName = "task-02-verify-deployment-completion"
if ($LogPath -ne "") { $script:LogFile = $LogPath }
else {
    $logDir = Join-Path (Get-Location).Path "logs\$taskFolderName"
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $script:LogFile = Join-Path $logDir "$(Get-Date -Format 'yyyy-MM-dd')_$(Get-Date -Format 'HHmmss')_Test-ADDomainStatus.log"
}

#endregion LOGGING

#region MAIN

Write-Log "========================================" "HEADER"
Write-Log " AD Domain Status Verification"          "HEADER"
Write-Log "========================================" "HEADER"

# --- Load config ---
$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Using config: $configFile"

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "Module 'powershell-yaml' is required. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -ErrorAction Stop

$yaml = Get-Content -Path $configFile -Raw | ConvertFrom-Yaml

# --- Extract values ---
$nodeIPs     = @($yaml.compute.cluster_nodes | ForEach-Object { $_.ipv4_address })   # compute.cluster_nodes[*].ipv4_address
$domainFqdn  = $yaml.cluster_arm_deployment.domain_fqdn                               # cluster_arm_deployment.domain_fqdn
$ouPath      = $yaml.cluster_arm_deployment.domain_ou_path                             # cluster_arm_deployment.domain_ou_path
$lcmUser     = $yaml.accounts.lcm_admin.username                                      # accounts.lcm_admin.username
$clusterName = $yaml.cluster_arm_deployment.cluster_name                               # cluster_arm_deployment.cluster_name

Write-Log "Domain FQDN:  $domainFqdn"
Write-Log "OU Path:      $ouPath"
Write-Log "LCM Account:  $lcmUser"
Write-Log "Cluster:      $clusterName"
Write-Log "Nodes:        $($nodeIPs -join ', ')"
Write-Log ""

$allPassed = $true
$results = @()

# --- Test 1: Domain membership and secure channel per node ---
Write-Log "--- Test 1: Domain Membership & Secure Channel ---" "HEADER"

$remoteParams = @{}
if ($Credential) { $remoteParams["Credential"] = $Credential }

foreach ($nodeIP in $nodeIPs) {
    Write-Log "Testing node: $nodeIP"

    try {
        $result = Invoke-Command -ComputerName $nodeIP @remoteParams -ScriptBlock {
            param($expectedDomain)
            $cs = Get-WmiObject Win32_ComputerSystem
            $secureChannel = Test-ComputerSecureChannel -ErrorAction SilentlyContinue
            [pscustomobject]@{
                NodeName      = $cs.Name
                Domain        = $cs.Domain
                ExpectedDomain = $expectedDomain
                DomainMatch   = ($cs.Domain -eq $expectedDomain)
                SecureChannel = $secureChannel
            }
        } -ArgumentList $domainFqdn -ErrorAction Stop

        $status = if ($result.DomainMatch -and $result.SecureChannel) { "SUCCESS" } else { "ERROR"; $allPassed = $false }
        Write-Log "  $($result.NodeName): Domain=$($result.Domain) Match=$($result.DomainMatch) SecureChannel=$($result.SecureChannel)" $status
        $results += $result
    }
    catch {
        Write-Log "  $nodeIP : Failed to connect — $($_.Exception.Message)" "ERROR"
        $allPassed = $false
    }
}

# --- Test 2: OU exists ---
Write-Log ""
Write-Log "--- Test 2: OU Verification ---" "HEADER"

try {
    $ou = Get-ADOrganizationalUnit -Identity $ouPath -ErrorAction Stop
    Write-Log "OU exists: $($ou.DistinguishedName)" "SUCCESS"
}
catch {
    Write-Log "OU not found: $ouPath — $($_.Exception.Message)" "ERROR"
    $allPassed = $false
}

# --- Test 3: LCM account delegation ---
Write-Log ""
Write-Log "--- Test 3: LCM Account OU Delegation ---" "HEADER"

try {
    $acl = Get-Acl "AD:\$ouPath" -ErrorAction Stop
    $delegation = $acl.Access | Where-Object {
        $_.IdentityReference -like "*$lcmUser*" -and
        $_.ActiveDirectoryRights -match "GenericAll"
    }
    if ($delegation) {
        Write-Log "LCM account '$lcmUser' has GenericAll on OU" "SUCCESS"
    }
    else {
        Write-Log "LCM account '$lcmUser' does NOT have GenericAll on OU" "ERROR"
        $allPassed = $false
    }
}
catch {
    Write-Log "Failed to check OU ACL — $($_.Exception.Message)" "ERROR"
    $allPassed = $false
}

# --- Test 4: Cluster computer object in OU ---
Write-Log ""
Write-Log "--- Test 4: Cluster Computer Object ---" "HEADER"

try {
    $clusterObj = Get-ADComputer -Identity $clusterName -ErrorAction Stop
    if ($clusterObj.DistinguishedName -like "*$ouPath") {
        Write-Log "Cluster object '$clusterName' found in correct OU" "SUCCESS"
    }
    else {
        Write-Log "Cluster object '$clusterName' exists but in wrong OU: $($clusterObj.DistinguishedName)" "WARN"
    }
}
catch {
    Write-Log "Cluster computer object '$clusterName' not found in AD (may be expected pre-deployment)" "WARN"
}

# --- Summary ---
Write-Log ""
Write-Log "========================================" "HEADER"
if ($allPassed) {
    Write-Log " All AD domain checks PASSED" "SUCCESS"
}
else {
    Write-Log " Some AD domain checks FAILED — review above" "ERROR"
}
Write-Log "========================================" "HEADER"
Write-Log "Log: $($script:LogFile)"

#endregion MAIN
