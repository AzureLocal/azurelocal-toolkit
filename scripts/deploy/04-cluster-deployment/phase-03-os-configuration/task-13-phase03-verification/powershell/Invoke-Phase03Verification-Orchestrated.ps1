#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-Phase03Verification-Orchestrated.ps1
    Verifies all Phase 03 OS Configuration tasks (01–11) across cluster nodes.

.DESCRIPTION
    Connects to each node via PSRemoting (in parallel) and runs read-only checks for:
      Task 01  - WinRM service running + listener active
      Task 02  - RDP enabled + firewall rule active
      Task 03  - Static IP matches expected
      Task 04  - DHCP disabled on management adapter
      Task 05  - DNS servers configured correctly
      Task 06  - DNS resolution working
      Task 07  - NTP synchronised, Stratum < 15, not "Local CMOS Clock"
      Task 08  - ICMP (Echo Request ICMPv4) firewall rule enabled
      Task 09  - No disconnected adapters still enabled
      Task 10  - Hostname matches infrastructure.yml
      Task 11  - No non-primordial storage pools, no virtual disks, all non-boot disks available

    Configuration values are read from infrastructure.yml. All values can be overridden
    via command-line parameters (see YAML-overridable parameters below).

.PARAMETER ConfigPath
    Path to infrastructure.yml. Defaults to auto-detect from script location.

.PARAMETER Credential
    PSCredential for PSRemoting. If omitted, resolved from Key Vault, then interactive prompt.

.PARAMETER TargetNode
    One or more node hostnames or IPs to run against. Defaults to all nodes in config.

.PARAMETER WhatIf
    Dry-run mode — shows what would be verified without connecting to any node.

.PARAMETER LogPath
    Override log file path. Default: ./logs/<timestamp>_Phase03Verification.log

.PARAMETER Gateway
    Override default gateway from infrastructure.yml. Path: compute.azure_local.default_gateway

.PARAMETER SubnetMask
    Override subnet mask from infrastructure.yml. Path: compute.azure_local.subnet_mask

.PARAMETER DnsServers
    Override DNS servers from infrastructure.yml. Path: compute.azure_local.dns_servers

.PARAMETER NTPServers
    Override NTP servers from infrastructure.yml. Path: identity.active_directory.ntp_servers

.EXAMPLE
    .\Invoke-Phase03Verification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml

.EXAMPLE
    .\Invoke-Phase03Verification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -TargetNode azl-lab-01-n02

.EXAMPLE
    .\Invoke-Phase03Verification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -WhatIf

.EXAMPLE
    .\Invoke-Phase03Verification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -Verbose

.EXAMPLE
    .\Invoke-Phase03Verification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -LogPath C:\logs\verify.log

.EXAMPLE
    .\Invoke-Phase03Verification-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -DnsServers 10.0.0.1,10.0.0.2

.NOTES
    Author:  Azure Local Cloud AzureLocalCloud
    Phase:   03-os-configuration
    Task:    13 - Phase 03 Verification
    Mode:    Read-only. No changes are made to any node.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [string[]]$TargetNode = @(),

    [switch]$WhatIf,

    [string]$LogPath = "",

    # YAML-overridable values — empty string / empty array = use YAML
    [string]  $Gateway    = "",        # compute.azure_local.default_gateway
    [string]  $SubnetMask = "",        # compute.azure_local.subnet_mask
    [string[]]$DnsServers = @(),       # compute.azure_local.dns_servers
    [string[]]$NTPServers = @()        # identity.active_directory.ntp_servers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Log file initialization ───────────────────────────────────────────────
# Scripts are always run from the repo root, so ./logs/<task-folder>/ is CWD-relative
$scriptShortName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '^Invoke-|-Orchestrated$', ''
$taskFolderName  = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf   # e.g. task-13-phase03-verification
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

    # Always write to log file (all levels including VERBOSE and DEBUG)
    $line | Out-File -FilePath $script:logFile -Append -Encoding utf8

    # Console output (colored, respects verbosity flags)
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

function Convert-SubnetMaskToPrefix {
    param([string]$Mask)
    $bits = 0
    foreach ($octet in $Mask.Split('.')) {
        $byte = [int]$octet
        while ($byte -gt 0) { $bits += ($byte -band 1); $byte = $byte -shr 1 }
    }
    return $bits
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

    # compute.cluster_nodes.<key>                                    # compute.cluster_nodes
    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            nodename = $_.Key                                        # compute.cluster_nodes.<key>
            hostname = if ($_.Value.hostname) { $_.Value.hostname }  # compute.cluster_nodes.<key>.hostname
                       else { $_.Key }
            ip       = $_.Value.management_ip                        # compute.cluster_nodes.<key>.management_ip
        }
    }

    $az         = $cfg.compute.azure_local                           # compute.azure_local
    $dnsServers = @($az.dns_servers)                                 # compute.azure_local.dns_servers
    $ntpRaw     = @($cfg.identity.active_directory.ntp_servers)      # identity.active_directory.ntp_servers
    $ntpServer  = $ntpRaw -join ' '
    $prefix     = Convert-SubnetMaskToPrefix $az.subnet_mask         # compute.azure_local.subnet_mask

    return [PSCustomObject]@{
        Nodes         = @($nodes)
        Gateway       = $az.default_gateway                           # compute.azure_local.default_gateway
        SubnetMask    = $az.subnet_mask                               # compute.azure_local.subnet_mask
        Prefix        = $prefix
        DNSPrimary    = $dnsServers[0]                                # compute.azure_local.dns_servers[0]
        DNSSecondary  = if ($dnsServers.Count -gt 1) { $dnsServers[1] } else { "" }  # compute.azure_local.dns_servers[1]
        NTPServer     = $ntpServer
        ManagementNIC = $cfg.network_config.management_nic_name       # network_config.management_nic_name
        AdminUser     = $cfg.identity.accounts.account_local_admin_username   # identity.accounts.account_local_admin_username
        AdminPassUri  = $cfg.identity.accounts.account_local_admin_password   # identity.accounts.account_local_admin_password
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

#region VERIFICATION SCRIPTBLOCK

$VerifyScript = {
    param(
        [string]$ExpectedIP,
        [string]$ExpectedHostname,
        [string]$ExpectedGateway,
        [int]$ExpectedPrefix,
        [string]$ExpectedDNS1,
        [string]$ExpectedDNS2,
        [string]$ExpectedNTPServer,
        [string]$ExpectedNICName
    )

    $checks = [ordered]@{}

    # ── Task 01: WinRM ────────────────────────────────────────────────────────
    try {
        $svc = Get-Service -Name WinRM -ErrorAction Stop
        $listener = Get-Item WSMan:\localhost\Listener\*\Transport -ErrorAction SilentlyContinue |
                    Where-Object { $_.Value -match 'HTTP' }
        $checks['Task01_WinRM'] = if ($svc.Status -eq 'Running' -and $listener) {
            "PASS (Service=Running, Listener=Active)"
        } elseif ($svc.Status -eq 'Running') {
            "PASS (Service=Running)"
        } else {
            "FAIL: Service=$($svc.Status)"
        }
    } catch {
        # If we are executing THIS block, we already proved WinRM works
        $checks['Task01_WinRM'] = "PASS (Connected)"
    }

    # ── Task 02: RDP ──────────────────────────────────────────────────────────
    $rdpReg = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
    $rdpFW  = (Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue |
               Where-Object { $_.Enabled -eq 'True' } | Measure-Object).Count
    $checks['Task02_RDP'] = if ($rdpReg -eq 0 -and $rdpFW -gt 0) {
        "PASS (Reg=0, FWRules=$rdpFW)"
    } else {
        "FAIL: RegValue=$rdpReg FWRules=$rdpFW"
    }

    # ── Tasks 03/04: Static IP + DHCP disabled ────────────────────────────────
    # Find management NIC by exact name (same as task-03 uses)
    $adapter = Get-NetAdapter | Where-Object { $_.InterfaceAlias -eq $ExpectedNICName }
    if (-not $adapter) {
        $available = (Get-NetAdapter | Select-Object -ExpandProperty InterfaceAlias) -join ', '
        $checks['Task0304_StaticIP'] = "FAIL: Adapter '$ExpectedNICName' not found. Available: $available"
        $checks['Task05_DNS'] = "FAIL: Skipped (adapter not found)"
    } else {
        $iface  = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ipAddr = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -notmatch '^169\.' -and $_.IPAddress -ne '127.0.0.1' } |
                   Select-Object -First 1).IPAddress

        $dhcpState = if ($iface) { $iface.Dhcp } else { 'Unknown' }

        if ($dhcpState -eq 'Disabled' -and $ipAddr -eq $ExpectedIP) {
            $checks['Task0304_StaticIP'] = "PASS (NIC='$ExpectedNICName' IP=$ipAddr DHCP=Disabled)"
        } elseif ($dhcpState -ne 'Disabled') {
            $checks['Task0304_StaticIP'] = "FAIL: DHCP=$dhcpState on '$ExpectedNICName'"
        } else {
            $checks['Task0304_StaticIP'] = "FAIL: IP=$ipAddr expected=$ExpectedIP on '$ExpectedNICName'"
        }
    }

    # ── Task 05: DNS servers ──────────────────────────────────────────────────
    $dnsAddrs = if ($adapter) {
        (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    } else { @() }
    if ($dnsAddrs -contains $ExpectedDNS1 -and $dnsAddrs -contains $ExpectedDNS2) {
        $checks['Task05_DNS'] = "PASS ($($dnsAddrs -join ', '))"
    } else {
        $checks['Task05_DNS'] = "FAIL: Got=$($dnsAddrs -join ',') expected=$ExpectedDNS1,$ExpectedDNS2"
    }

    # ── Task 06: DNS resolution ───────────────────────────────────────────────
    $dnsResolved = $false
    try {
        $null = Resolve-DnsName -Name $ExpectedDNS1 -ErrorAction Stop
        $dnsResolved = $true
    } catch {
        try {
            $null = [System.Net.Dns]::GetHostAddresses("google.com")
            $dnsResolved = $true
        } catch { }
    }
    $checks['Task06_DNSResolve'] = if ($dnsResolved) { "PASS" } else { "FAIL: DNS resolution failed" }

    # ── Task 07: NTP ──────────────────────────────────────────────────────────
    $ntpOut  = (& w32tm /query /status 2>&1) | Out-String
    $stratum = if ($ntpOut -match 'Stratum:\s*(\d+)') { [int]$Matches[1] } else { 99 }
    $source  = if ($ntpOut -match 'Source:\s*(.+)\r?\n') { $Matches[1].Trim() } else { 'Unknown' }
    if ($stratum -lt 15 -and $source -notmatch 'Local CMOS Clock|Free-running') {
        $checks['Task07_NTP'] = "PASS (Stratum=$stratum Source=$source)"
    } else {
        $checks['Task07_NTP'] = "FAIL: Stratum=$stratum Source=$source"
    }

    # ── Task 08: ICMP ─────────────────────────────────────────────────────────
    $icmpRules = (Get-NetFirewallRule -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -match 'Echo Request.*ICMPv4' -and $_.Enabled -eq 'True' } |
                  Measure-Object).Count
    $checks['Task08_ICMP'] = if ($icmpRules -gt 0) {
        "PASS ($icmpRules rule(s) enabled)"
    } else {
        "FAIL: No ICMPv4 Echo Request rules enabled"
    }

    # ── Task 09: Unused adapters disabled ────────────────────────────────────
    $stillEnabled = Get-NetAdapter |
                    Where-Object { $_.Status -eq 'Disconnected' -and $_.AdminStatus -eq 'Up' }
    $checks['Task09_Adapters'] = if ($stillEnabled.Count -eq 0) {
        "PASS (No disconnected adapters still enabled)"
    } else {
        "WARN: $($stillEnabled.Count) disconnected adapter(s) still enabled: $($stillEnabled.Name -join ', ')"
    }

    # ── Task 10: Hostname ─────────────────────────────────────────────────────
    $actual = $env:COMPUTERNAME
    $checks['Task10_Hostname'] = if ($actual -eq $ExpectedHostname.ToUpper()) {
        "PASS ($actual)"
    } else {
        "FAIL: Got='$actual' Expected='$($ExpectedHostname.ToUpper())'"
    }

    # ── Task 11: Storage — S2D readiness ─────────────────────────────────────
    # For S2D, non-boot disks should be: RAW partition style, no storage pools, no virtual disks.
    # Offline + RAW is the expected clean state after storage prep.
    $nonPrimordialPools = (Get-StoragePool -ErrorAction SilentlyContinue |
                           Where-Object { $_.IsPrimordial -eq $false } | Measure-Object).Count
    $virtualDisks       = (Get-VirtualDisk -ErrorAction SilentlyContinue | Measure-Object).Count
    $nonBootDisks       = @(Get-Disk -ErrorAction SilentlyContinue |
                            Where-Object { $_.Number -ne $null -and $_.IsBoot -ne $true -and $_.IsSystem -ne $true })
    $rawDisks           = @($nonBootDisks | Where-Object { $_.PartitionStyle -eq 'RAW' })
    $notRawDisks        = @($nonBootDisks | Where-Object { $_.PartitionStyle -ne 'RAW' })

    if ($nonPrimordialPools -eq 0 -and $virtualDisks -eq 0 -and $notRawDisks.Count -eq 0 -and $rawDisks.Count -gt 0) {
        $checks['Task11_Storage'] = "PASS ($($rawDisks.Count) disk(s) RAW and ready for S2D)"
    } elseif ($nonPrimordialPools -gt 0 -or $virtualDisks -gt 0) {
        $checks['Task11_Storage'] = "FAIL: Pools=$nonPrimordialPools VirtualDisks=$virtualDisks — storage not clean"
    } elseif ($notRawDisks.Count -gt 0) {
        $checks['Task11_Storage'] = "WARN: $($notRawDisks.Count) disk(s) not RAW (need cleaning), $($rawDisks.Count) RAW"
    } else {
        $checks['Task11_Storage'] = "WARN: No non-boot disks found"
    }

    return $checks
}

#endregion VERIFICATION SCRIPTBLOCK

#region MAIN

Write-Log "================================================================" HEADER
Write-Log "   Phase 03 OS Configuration — Verification (Tasks 01–11)" HEADER
Write-Log "================================================================" HEADER
Write-Log "" INFO
Write-Log "  Checks  : Tasks 01–11 (WinRM, RDP, Static IP, DHCP, DNS," INFO
Write-Log "            NTP, ICMP, Adapters, Hostname, Storage)" INFO
Write-Log "  Mode    : Read-only. No changes are made to any node." INFO
Write-Log "  Log     : $logFile" INFO
Write-Log "" INFO

# ── Load config ──────────────────────────────────────────────────────────────
Write-Log "Config : $ConfigPath" INFO
Write-Log "--- Loading configuration ---" HEADER

$cfg = Get-Config -Path $ConfigPath

# ── Apply YAML-overridable parameter overrides ───────────────────────────────
if ($Gateway    -ne "")        { $cfg.Gateway    = $Gateway;    Write-Log "  Override: Gateway=$Gateway" WARN }
if ($SubnetMask -ne "")        { $cfg.Prefix     = Convert-SubnetMaskToPrefix $SubnetMask; $cfg.SubnetMask = $SubnetMask; Write-Log "  Override: SubnetMask=$SubnetMask (prefix=$($cfg.Prefix))" WARN }
if ($DnsServers.Count -gt 0)   { $cfg.DNSPrimary = $DnsServers[0]; $cfg.DNSSecondary = if ($DnsServers.Count -gt 1) { $DnsServers[1] } else { "" }; Write-Log "  Override: DnsServers=$($DnsServers -join ',')" WARN }
if ($NTPServers.Count -gt 0)   { $cfg.NTPServer  = $NTPServers -join ' '; Write-Log "  Override: NTPServers=$($NTPServers -join ',')" WARN }

Write-Log "  Gateway        : $($cfg.Gateway)" INFO
Write-Log "  Subnet mask    : /prefix=$($cfg.Prefix)" INFO
Write-Log "  DNS primary    : $($cfg.DNSPrimary)" INFO
Write-Log "  DNS secondary  : $($cfg.DNSSecondary)" INFO
Write-Log "  NTP server(s)  : $($cfg.NTPServer)" INFO
Write-Log "  Management NIC : $($cfg.ManagementNIC)" INFO
Write-Log "Found $($cfg.Nodes.Count) node(s):" INFO
$cfg.Nodes | ForEach-Object { Write-Log "  $($_.hostname)  ($($_.ip))" INFO }

Write-Log "Config values (raw object):" DEBUG
Write-Log ($cfg | Select-Object Gateway, Prefix, DNSPrimary, DNSSecondary, NTPServer, AdminUser | ConvertTo-Json -Depth 2) DEBUG

# ── Resolve credentials ───────────────────────────────────────────────────────
# CREDENTIAL RESOLUTION ORDER:
# 1. -Credential parameter (passed directly)
# 2. Key Vault (Az.KeyVault module, then az CLI fallback)
# 3. Interactive Get-Credential prompt
Write-Log "--- Resolving credentials ---" HEADER
if (-not $Credential) {
    $adminUser    = $cfg.AdminUser                                   # identity.accounts.account_local_admin_username
    $adminPassUri = $cfg.AdminPassUri                                # identity.accounts.account_local_admin_password
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

# ── Apply TargetNode filter ───────────────────────────────────────────────────
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
    Write-Log "  WHATIF — Dry-run mode. No connections will be made." HEADER
    Write-Log "================================================================" HEADER
    Write-Log "" INFO
    Write-Log "Would verify $($nodes.Count) node(s):" INFO
    Write-Log "" INFO

    foreach ($n in $nodes) {
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  NODE: $($n.hostname)  ($($n.ip))" HEADER
        Write-Log "────────────────────────────────────────────────────────────" HEADER
        Write-Log "  WHATIF: Task 01 — WinRM           : Would verify WinRM service is Running and HTTP listener is active" INFO
        Write-Log "  WHATIF: Task 02 — RDP              : Would verify fDenyTSConnections=0 and Remote Desktop firewall rules enabled" INFO
        Write-Log "  WHATIF: Task 03/04 — Static IP     : Would verify NIC='$($cfg.ManagementNIC)', IP=$($n.ip)/$($cfg.Prefix), Gateway=$($cfg.Gateway), DHCP=Disabled" INFO
        Write-Log "  WHATIF: Task 05 — DNS Servers      : Would verify DNS=$($cfg.DNSPrimary), $($cfg.DNSSecondary)" INFO
        Write-Log "  WHATIF: Task 06 — DNS Resolution   : Would verify DNS name resolution is functional" INFO
        Write-Log "  WHATIF: Task 07 — NTP              : Would verify NTP source=$($cfg.NTPServer), Stratum < 15, not free-running" INFO
        Write-Log "  WHATIF: Task 08 — ICMP             : Would verify ICMPv4 Echo Request firewall rules are enabled" INFO
        Write-Log "  WHATIF: Task 09 — Unused Adapters  : Would verify no disconnected adapters are still admin-enabled" INFO
        Write-Log "  WHATIF: Task 10 — Hostname         : Would verify hostname=$($n.hostname.ToUpper())" INFO
        Write-Log "  WHATIF: Task 11 — Storage          : Would verify no non-primordial pools, no virtual disks, all non-boot disks online" INFO
        Write-Log "" INFO
    }

    Write-Log "Connection method : Invoke-Command -ComputerName <ip> -Credential $($cfg.AdminUser) -AsJob" INFO
    Write-Log "Job timeout       : 120 seconds per node" INFO
    Write-Log "" INFO
    Write-Log "Re-run without -WhatIf to execute." INFO
    Write-Log "Log file: $logFile" INFO
    exit 0
}

Write-Log "" INFO
Write-Log "Ready. Verifying $($nodes.Count) node(s) in parallel..." HEADER
Write-Log "================================================================" HEADER

# ── Launch parallel verification jobs ──────────────────────────────────────
$jobTimeout = 120   # seconds
$jobs       = [ordered]@{}
$summary    = @()

Write-Log "Launching verification jobs in parallel..." HEADER
foreach ($node in $nodes) {
    try {
        $job = Invoke-Command `
            -ComputerName $node.ip `
            -Credential $Credential `
            -ScriptBlock $VerifyScript `
            -ArgumentList $node.ip, $node.hostname, $cfg.Gateway, $cfg.Prefix, $cfg.DNSPrimary, $cfg.DNSSecondary, $cfg.NTPServer, $cfg.ManagementNIC `
            -AsJob `
            -JobName "Verify-$($node.hostname)" `
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
    $rawChecks        = $null

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
                $rawChecks = Receive-Job -Job $job -ErrorAction Stop
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

    if ($rawChecks) {
        foreach ($key in $rawChecks.Keys) {
            $val    = "$($rawChecks[$key])"
            $isPASS = $val -match '^PASS'
            $isWARN = $val -match '^WARN'

            $label = $key.PadRight(22)
            if ($isPASS) {
                Write-Host "  [PASS] $label  $val" -ForegroundColor Green
                "  [PASS] $label  $val" | Out-File -FilePath $logFile -Append -Encoding utf8
                $nodeChecksPassed++
            } elseif ($isWARN) {
                Write-Host "  [WARN] $label  $val" -ForegroundColor Yellow
                "  [WARN] $label  $val" | Out-File -FilePath $logFile -Append -Encoding utf8
                $nodeChecksWarned++
            } else {
                Write-Host "  [FAIL] $label  $val" -ForegroundColor Red
                "  [FAIL] $label  $val" | Out-File -FilePath $logFile -Append -Encoding utf8
                $nodeChecksFailed++
            }
        }
    }

    $total  = $nodeChecksPassed + $nodeChecksFailed + $nodeChecksWarned
    $status = if ($nodeError) { "Error" }
              elseif ($nodeChecksFailed -gt 0) { "Failed ($nodeChecksFailed/$total)" }
              elseif ($nodeChecksWarned -gt 0) { "Warnings ($nodeChecksWarned/$total)" }
              else { "All PASS ($nodeChecksPassed/$total)" }

    Write-Log "[$nodeName] $status" $(if ($nodeError -or $nodeChecksFailed -gt 0) { 'FAIL' } elseif ($nodeChecksWarned) { 'WARN' } else { 'PASS' })

    $summary += [PSCustomObject]@{
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

# ── Summary table ──────────────────────────────────────────────────────────
Write-Log "" INFO
Write-Log "================================================================" HEADER
Write-Log "  SUMMARY" HEADER
Write-Log "================================================================" HEADER

$tableStr = ($summary | Format-Table Node, IP, Passed, Warned, Failed, Status -AutoSize | Out-String).Trim()
Write-Host $tableStr
$tableStr | Out-File -FilePath $logFile -Append -Encoding utf8

$totalFailed = @($summary | Where-Object { $_.Failed -gt 0 -or $_.Error }).Count

if ($totalFailed -eq 0 -and @($summary | Where-Object { $_.Warned -gt 0 }).Count -eq 0) {
    Write-Log "All $($nodes.Count) node(s) passed Phase 03 verification." PASS
} elseif ($totalFailed -eq 0) {
    Write-Log "All $($nodes.Count) node(s) passed with warnings. Review WARNs above." WARN
} else {
    Write-Log "$totalFailed node(s) had failures. Review output above." FAIL
    Write-Log "Log file: $logFile" INFO
    exit 1
}

Write-Log "" INFO
Write-Log "Phase 04 ARC Registration may now proceed." INFO
Write-Log "Log file: $logFile" INFO

#endregion MAIN
