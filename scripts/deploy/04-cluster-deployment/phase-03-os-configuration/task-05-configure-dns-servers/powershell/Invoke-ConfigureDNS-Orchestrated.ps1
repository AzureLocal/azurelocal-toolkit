#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-ConfigureDNS-Orchestrated.ps1
    Configures DNS servers on the management NIC of every Azure Local node using PSRemoting.

.DESCRIPTION
    Runs from the management server. Reads DNS and node IP values from infrastructure.yml,
    connects to each node over PSRemoting, and sets the DNS server addresses on the
    management NIC.

    infrastructure.yml paths used:
      nodes.<name>.management_ip    - PSRemoting connection target
      cluster.management_nic_name   - Adapter name to configure DNS on
      dns.primary                   - Primary DNS server IP
      dns.secondary                 - Secondary DNS server IP

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-05-configure-dns-servers
    Execution:    Run from management server (PSRemoting outbound to nodes)
    Prerequisites: PowerShell 5.1+, WinRM enabled on all nodes, admin credentials
    Run after:    Task 04 — DHCP disabled on all adapters

.EXAMPLE
    .\Invoke-ConfigureDNS-Orchestrated.ps1
    .\Invoke-ConfigureDNS-Orchestrated.ps1 -ConfigPath "C:\configs\infrastructure.yml"
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
#  LOGGING
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER"  { "Cyan" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# ============================================================================
#  CONFIGURATION RESOLVER
# ============================================================================

function Resolve-ConfigPath {
    [CmdletBinding()]
    param([string]$Provided)

    if ($Provided -and (Test-Path $Provided)) {
        Write-Log "Config: $Provided"
        return $Provided
    }

    $searchPaths = @(
        (Join-Path $PSScriptRoot "..\..\..\..\configs"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\configs"),
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
        Write-Log "No infrastructure*.yml found. Provide -ConfigPath manually." "ERROR"
        throw "Config file not found."
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

# ============================================================================
#  YAML PARSER (PowerShell 5.1 compatible)
# ============================================================================

function Get-YamlValue {
    param([string[]]$Lines, [string[]]$KeyPath)

    $current = $Lines

    foreach ($key in $KeyPath) {
        $pattern = "^\s*${key}\s*:"
        $lineIdx  = -1
        for ($i = 0; $i -lt $current.Count; $i++) {
            if ($current[$i] -match $pattern) { $lineIdx = $i; break }
        }
        if ($lineIdx -eq -1) { return $null }

        if ($current[$lineIdx] -match "^\s*${key}\s*:\s*(.+)$") {
            $val = $Matches[1].Trim().Trim('"').Trim("'")
            if ($KeyPath[-1] -eq $key) { return $val }
            return $null
        }

        $keyIndent  = ($current[$lineIdx] -replace "^(\s*).*", '$1').Length
        $blockLines = @()
        for ($j = $lineIdx + 1; $j -lt $current.Count; $j++) {
            $line = $current[$j]
            if ($line -match "^\s*$") { continue }
            $thisIndent = ($line -replace "^(\s*).*", '$1').Length
            if ($thisIndent -le $keyIndent) { break }
            $blockLines += $line
        }
        $current = $blockLines
    }
    return $null
}

function Get-NodeNames {
    param([string[]]$Lines)
    $inNodes = $false
    $names   = @()
    foreach ($line in $Lines) {
        if ($line -match "^\s*nodes\s*:") { $inNodes = $true; continue }
        if ($inNodes) {
            if ($line -match "^\s*(\w[\w\-_]*):\s*$") { $names += $Matches[1] }
            elseif ($line -match "^\S" -and $line -notmatch "^\s*#") { break }
        }
    }
    return $names
}

# ============================================================================
#  GET CLUSTER CONFIG
# ============================================================================

function Get-ClusterConfig {
    [CmdletBinding()]
    param([string]$ConfigPath)

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

    $mgmtNIC      = $cfg.network_config.management_nic_name
    $dnsServers   = $cfg.compute.azure_local.dns_servers
    $dnsPrimary   = $dnsServers[0]
    $dnsSecondary = $dnsServers[1]

    if (-not $mgmtNIC)      { throw "network_config.management_nic_name not found in $ConfigPath." }
    if (-not $dnsPrimary)   { throw "compute.azure_local.dns_servers[0] not found in $ConfigPath." }
    if (-not $dnsSecondary) { throw "compute.azure_local.dns_servers[1] not found in $ConfigPath." }

    Write-Log "  management_nic_name : $mgmtNIC"
    Write-Log "  dns.primary         : $dnsPrimary"
    Write-Log "  dns.secondary       : $dnsSecondary"

    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        Write-Log "  Node: $($_.Key)  IP: $($_.Value.management_ip)"
        [PSCustomObject]@{ NodeName = $_.Key; IP = $_.Value.management_ip }
    }

    if (-not $nodes) { throw "No nodes found under compute.cluster_nodes in $ConfigPath." }

    return [PSCustomObject]@{
        ManagementNIC = $mgmtNIC
        DNSPrimary    = $dnsPrimary
        DNSSecondary  = $dnsSecondary
        Nodes         = @($nodes)
        _cfg          = $cfg
    }
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

# ============================================================================
#  REMOTE SCRIPTBLOCK
# ============================================================================

$RemoteScriptBlock = {
    param([string]$ManagementNIC, [string]$DNSPrimary, [string]$DNSSecondary)

    Set-StrictMode -Version Latest

    # Find adapter by exact name
    $adapter = Get-NetAdapter | Where-Object { $_.Name -eq $ManagementNIC }
    if (-not $adapter) {
        $available = (Get-NetAdapter | Sort-Object Name | ForEach-Object { $_.Name }) -join ", "
        return [PSCustomObject]@{
            Result      = "Error"
            Detail      = "Adapter '$ManagementNIC' not found. Available: $available"
            DNSAfter    = ""
        }
    }

    # Idempotency check
    $current = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    if ($current -and $current.Count -ge 2 -and $current[0] -eq $DNSPrimary -and $current[1] -eq $DNSSecondary) {
        return [PSCustomObject]@{
            Result   = "AlreadyConfigured"
            Detail   = "DNS already set to $DNSPrimary, $DNSSecondary"
            DNSAfter = "$DNSPrimary, $DNSSecondary"
        }
    }

    # Set DNS
    try {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
            -ServerAddresses @($DNSPrimary, $DNSSecondary) -ErrorAction Stop

        $after = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $ok    = ($after -and $after.Count -ge 2 -and $after[0] -eq $DNSPrimary -and $after[1] -eq $DNSSecondary)

        return [PSCustomObject]@{
            Result   = if ($ok) { "Changed" } else { "Failed" }
            Detail   = if ($ok) { "DNS set successfully" } else { "Post-set DNS mismatch: $($after -join ', ')" }
            DNSAfter = $after -join ", "
        }
    } catch {
        return [PSCustomObject]@{
            Result   = "Error"
            Detail   = $_.ToString()
            DNSAfter = ""
        }
    }
}

# ============================================================================
#  MAIN
# ============================================================================

try {
    Write-Log "=== Invoke-ConfigureDNS-Orchestrated.ps1 ===" "HEADER"

    Import-Module powershell-yaml -ErrorAction Stop

    $resolvedConfig = Resolve-ConfigPath -Provided $ConfigPath
    Write-Log "Loading configuration from: $resolvedConfig"
    $config = Get-ClusterConfig -ConfigPath $resolvedConfig
    Write-Log "Nodes to process: $($config.Nodes.Count)"

    $adminUser    = $config._cfg.identity.accounts.account_local_admin_username
    $adminPassUri = $config._cfg.identity.accounts.account_local_admin_password
    if (-not $Credential) {
        Write-Log "Resolving credentials from Key Vault..."
        $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
        if ($adminPass) {
            $Credential = New-Object PSCredential($adminUser, (ConvertTo-SecureString $adminPass -AsPlainText -Force))
            Write-Log "Credentials resolved for '$adminUser'." SUCCESS
        } else {
            Write-Log "Key Vault unavailable — prompting for credentials." WARN
            $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $adminUser
        }
    }
    $credential = $Credential

    $nodeResults = @()

    foreach ($node in $config.Nodes) {
        Write-Log "--- $($node.NodeName) ($($node.IP)) ---" "HEADER"

        try {
            $session = New-PSSession -ComputerName $node.IP -Credential $credential -ErrorAction Stop
            Write-Log "  Connected to $($node.IP)"

            $result = Invoke-Command -Session $session -ScriptBlock $RemoteScriptBlock `
                -ArgumentList $config.ManagementNIC, $config.DNSPrimary, $config.DNSSecondary

            $level = switch ($result.Result) {
                "Changed"          { "SUCCESS" }
                "AlreadyConfigured"{ "SUCCESS" }
                default            { "WARN" }
            }
            Write-Log "  $($node.NodeName): $($result.Result) — $($result.Detail)" $level
            if ($result.DNSAfter) {
                Write-Log "  DNS after: $($result.DNSAfter)"
            }

            $nodeResults += [PSCustomObject]@{
                Node    = $node.NodeName
                IP      = $node.IP
                Result  = $result.Result
                DNSAfter = $result.DNSAfter
                Detail  = $result.Detail
            }

            Remove-PSSession -Session $session -ErrorAction SilentlyContinue

        } catch {
            Write-Log "  ERROR connecting to $($node.NodeName) ($($node.IP)): $_" "ERROR"
            $nodeResults += [PSCustomObject]@{
                Node    = $node.NodeName
                IP      = $node.IP
                Result  = "ConnectionFailed"
                DNSAfter = ""
                Detail  = $_.ToString()
            }
        }
    }

    Write-Log "=== ORCHESTRATION SUMMARY ===" "HEADER"
    $nodeResults | Format-Table -AutoSize | Out-String | Write-Host

    $failed = @($nodeResults | Where-Object { $_.Result -notin @("Changed","AlreadyConfigured") })
    if ($failed.Count -gt 0) {
        Write-Log "$($failed.Count) node(s) had issues. Review above." "WARN"
        exit 1
    }

    Write-Log "All nodes: DNS configuration complete." "SUCCESS"
    exit 0

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
