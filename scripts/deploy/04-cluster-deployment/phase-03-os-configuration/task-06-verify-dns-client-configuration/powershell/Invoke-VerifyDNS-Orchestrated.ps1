<#
.SYNOPSIS
    Invoke-VerifyDNS-Orchestrated.ps1
    Verifies DNS client configuration on all Azure Local nodes via PSRemoting.

.DESCRIPTION
    Runs from the management server. Reads DNS and node IP values from
    infrastructure.yml, connects to each node over PSRemoting, and validates
    the DNS server configuration and Azure endpoint resolution.

    infrastructure.yml paths used:
      cluster.management_nic_name  - Management adapter name to check
      dns.primary                  - Expected primary DNS server IP
      dns.secondary                - Expected secondary DNS server IP
      nodes.<name>.management_ip   - PSRemoting connection target per node

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-06-verify-dns-client-configuration
    Execution:    Run from management server (PSRemoting outbound to nodes)
    Prerequisites: PowerShell 5.1+, WinRM enabled on all nodes, admin credentials
    Run after:    Task 05 - DNS servers configured

.EXAMPLE
    .\Invoke-VerifyDNS-Orchestrated.ps1
    .\Invoke-VerifyDNS-Orchestrated.ps1 -ConfigPath "C:\configs\infrastructure.yml"
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

#region HELPERS

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "SUCCESS" { Write-Host "[$ts] [PASS] $Message" -ForegroundColor Green }
        "ERROR"   { Write-Host "[$ts] [FAIL] $Message" -ForegroundColor Red }
        "WARN"    { Write-Host "[$ts] [WARN] $Message" -ForegroundColor Yellow }
        "HEADER"  { Write-Host "[$ts] [----] $Message" -ForegroundColor Cyan }
        default   { Write-Host "[$ts] [INFO] $Message" }
    }
}

function Resolve-ConfigPath {
    param([string]$Provided)
    if ($Provided -ne "" -and (Test-Path $Provided)) { return $Provided }
    $candidates = @(
        "$env:USERPROFILE\infrastructure.yml",
        "C:\configs\infrastructure.yml",
        "$PSScriptRoot\..\..\..\..\..\configs\infrastructure.yml"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    throw "infrastructure.yml not found. Pass -ConfigPath or place it in a standard location."
}

function Get-YamlValue {
    param(
        [string]$FilePath,
        [string[]]$KeyPath
    )
    $lines    = Get-Content -Path $FilePath -Encoding UTF8
    $depth    = 0
    $inTarget = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }

        $indent = $line.Length - $line.TrimStart().Length

        $key = $null
        if ($line -match '^\s*([\w][\w_-]*):\s*(.*)$') { $key = $Matches[1] }
        $val = $null
        if ($line -match '^\s*[\w][\w_-]*:\s*(.+)$') {
            $val = $Matches[1].Trim().Trim('"').Trim("'")
        }

        if ($depth -eq 0 -and $key -eq $KeyPath[0]) {
            if ($KeyPath.Count -eq 1 -and $val) { return $val }
            $depth    = $indent
            $inTarget = $true
            continue
        }

        if ($inTarget -and $KeyPath.Count -gt 1 -and $key -eq $KeyPath[1]) {
            if ($KeyPath.Count -eq 2 -and $val) { return $val }
            $depth    = $indent
            continue
        }

        if ($inTarget -and $KeyPath.Count -gt 2 -and $key -eq $KeyPath[2]) {
            if ($val) { return $val }
        }

        if ($inTarget -and $indent -le $depth -and $key -ne $KeyPath[-1]) {
            $inTarget = $false
            $depth    = 0
        }
    }
    return $null
}

function Get-YamlNodes {
    param([string]$FilePath)
    $lines   = Get-Content -Path $FilePath -Encoding UTF8
    $inNodes = $false
    $nodes   = @()

    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
        if ($line -match '^nodes:') { $inNodes = $true; continue }
        if ($inNodes) {
            if ($line -match '^  ([\w][\w_-]*):') { $nodes += $Matches[1] }
            elseif ($line -match '^[^\s]') { break }
        }
    }
    return $nodes
}

function Resolve-KeyVaultRef {
    param([Parameter(Mandatory)][string]$KvUri)
    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') { return $null }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]
    Write-Log "  Fetching '$secretName' from Key Vault '$vaultName'..."
    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText -ErrorAction Stop
            if ($secret) { return $secret }
            Write-Log "  Az.KeyVault returned no secret." WARN
        } catch {
            Write-Log "  Az.KeyVault failed: $($_.Exception.Message)" WARN
        }
    }
    try {
        $azOut = & az keyvault secret show --vault-name $vaultName --name $secretName --query value -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $azOut) { return ($azOut | Out-String).Trim() }
        $errDetail = if ($azOut) { ": $azOut" } else { " (exit $LASTEXITCODE)" }
        Write-Log "  az CLI failed$errDetail." WARN
        return $null
    } catch {
        return $null
    }
}

#endregion HELPERS

#region MAIN

Write-Log "=== Task 06 - Verify DNS Client Configuration (Orchestrated) ===" "HEADER"
Write-Log "Reading configuration from infrastructure.yml..."

$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Config: $configFile"

Import-Module powershell-yaml -ErrorAction Stop
$cfg = Get-Content $configFile -Raw | ConvertFrom-Yaml

$mgmtNIC           = $cfg.network_config.management_nic_name
$expectedPrimary   = $cfg.compute.azure_local.dns_servers[0]
$expectedSecondary = $cfg.compute.azure_local.dns_servers[1]
$nodeNames         = @($cfg.compute.cluster_nodes.Keys)

Write-Log "Management NIC         : $mgmtNIC"
Write-Log "Expected Primary DNS   : $expectedPrimary"
Write-Log "Expected Secondary DNS : $expectedSecondary"
Write-Log "Nodes                  : $($nodeNames -join ', ')"

if (-not $mgmtNIC)          { throw "network_config.management_nic_name not found in config" }
if (-not $expectedPrimary)  { throw "compute.azure_local.dns_servers[0] not found in config" }
if (-not $expectedSecondary){ throw "compute.azure_local.dns_servers[1] not found in config" }
if ($nodeNames.Count -eq 0) { throw "No nodes found under compute.cluster_nodes" }

$adminUser    = $cfg.identity.accounts.account_local_admin_username
$adminPassUri = $cfg.identity.accounts.account_local_admin_password
if (-not $Credential) {
    Write-Log "Resolving credentials from Key Vault..."
    $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
    if ($adminPass) {
        $Credential = New-Object PSCredential($adminUser.Trim(), (ConvertTo-SecureString $adminPass -AsPlainText -Force))
        Write-Log "Credentials resolved for '$($adminUser.Trim())'." SUCCESS
    } else {
        Write-Log "Key Vault unavailable — prompting for credentials." WARN
        $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $adminUser.Trim()
    }
}
$cred = $Credential

$endpoints = @(
    "management.azure.com",
    "login.microsoftonline.com",
    "dp.stackhci.azure.com",
    "azurewatsonanalysis-prod.core.windows.net",
    "dc.services.visualstudio.com"
)

$nodeResults = @()

foreach ($nodeName in $nodeNames) {
    $mgmtIP = $cfg.compute.cluster_nodes[$nodeName].management_ip
    if (-not $mgmtIP) {
        Write-Log "[$nodeName] management_ip not found in config - skipping" "WARN"
        continue
    }

    Write-Log "[$nodeName] Connecting to $mgmtIP..."

    try {
        $result = Invoke-Command -ComputerName $mgmtIP -Credential $cred -ScriptBlock {
            param($nic, $primary, $secondary, $eps)

            $out = @{
                Hostname        = $env:COMPUTERNAME
                PrimaryDNS      = ""
                SecondaryDNS    = ""
                DNSMatch        = $false
                EndpointsFailed = 0
                Errors          = @()
            }

            $adapter = Get-NetAdapter -Name $nic -ErrorAction SilentlyContinue
            if (-not $adapter) {
                $out.Errors += "Adapter '$nic' not found"
                return $out
            }

            $dnsServers      = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses
            if ($dnsServers.Count -ge 1) { $out.PrimaryDNS   = $dnsServers[0] }
            if ($dnsServers.Count -ge 2) { $out.SecondaryDNS = $dnsServers[1] }
            $out.DNSMatch = ($out.PrimaryDNS -eq $primary -and $out.SecondaryDNS -eq $secondary)

            foreach ($ep in $eps) {
                $r = Resolve-DnsName -Name $ep -ErrorAction SilentlyContinue
                if (-not $r) {
                    $out.EndpointsFailed++
                    $out.Errors += "Cannot resolve: $ep"
                }
            }
            return $out
        } -ArgumentList $mgmtNIC, $expectedPrimary, $expectedSecondary, $endpoints

        $dnsStatus = if ($result.DNSMatch) { "OK" } else { "MISMATCH" }
        $status    = if ($result.DNSMatch -and $result.EndpointsFailed -eq 0) { "PASS" } else { "FAIL" }

        foreach ($e in $result.Errors) { Write-Log "[$nodeName] $e" "WARN" }

        $nodeResults += [PSCustomObject]@{
            Node            = $nodeName
            Hostname        = $result.Hostname
            PrimaryDNS      = $result.PrimaryDNS
            SecondaryDNS    = $result.SecondaryDNS
            DNSStatus       = $dnsStatus
            EndpointsFailed = $result.EndpointsFailed
            Status          = $status
        }
    }
    catch {
        Write-Log "[$nodeName] PSRemoting failed: $_" "ERROR"
        $nodeResults += [PSCustomObject]@{
            Node            = $nodeName
            Hostname        = "UNREACHABLE"
            PrimaryDNS      = ""
            SecondaryDNS    = ""
            DNSStatus       = "ERROR"
            EndpointsFailed = 0
            Status          = "ERROR"
        }
    }
}

Write-Log ""
Write-Log "=== DNS Verification Summary ===" "HEADER"
$nodeResults | Format-Table Node, Hostname, PrimaryDNS, SecondaryDNS, DNSStatus, EndpointsFailed, Status -AutoSize

$failCount = @($nodeResults | Where-Object { $_.Status -ne "PASS" }).Count
if ($failCount -eq 0) {
    Write-Log "All $($nodeResults.Count) node(s) passed DNS verification." "SUCCESS"
} else {
    Write-Log "$failCount node(s) failed DNS verification. Review output above." "ERROR"
    exit 1
}

#endregion MAIN