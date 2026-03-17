#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-Phase03OsConfiguration-Orchestrated.ps1
    Runs all Phase 03 OS configuration tasks (02–10) against every Azure Local node
    from the management server in a single execution.

.DESCRIPTION
    Combined orchestrated script that sequentially runs the following tasks on every
    node defined in infrastructure.yml:

      Task 02 - Enable RDP
      Task 03 - Configure static IP address
      Task 04 - Disable DHCP on management adapter
      Task 05 - Configure DNS servers
      Task 06 - Verify DNS client configuration
      Task 07 - Configure NTP (time synchronization)
      Task 08 - Enable ICMP (ping)
      Task 09 - Disable unused network adapters
      Task 10 - Configure hostname (rename + restart + verify)

    *** Task 01 (Enable WinRM) MUST be completed on each node manually BEFORE this script.
    *** Task 11 (Clear Previous Storage) is conditional — NOT included. Run separately if needed.

    infrastructure.yml paths used:
      compute.cluster_nodes.<name>.management_ip  - PSRemoting connection IP per node
      compute.cluster_nodes.<name>.hostname       - Target hostname per node
      compute.azure_local.default_gateway         - Default gateway
      compute.azure_local.subnet_mask             - Subnet mask (converted to prefix length)
      compute.azure_local.dns_servers             - DNS server list (index 0=primary, 1=secondary)
      identity.accounts.account_local_admin_username - Admin username
      identity.accounts.account_local_admin_password - KV reference for admin password

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-detected from standard locations if not specified.

.PARAMETER Credential
    PSCredential for PSRemoting. If omitted, resolved from Key Vault or prompted.

.PARAMETER NTPServer
    NTP server(s) to configure (space-separated for multiple). Defaults to "time.windows.com".

.PARAMETER ReconnectTimeoutSec
    Seconds to wait for each node after hostname rename + restart. Default: 120.

.PARAMETER ReconnectRetrySec
    Seconds between reconnect attempts. Default: 10.

.EXAMPLE
    .\Invoke-Phase03OsConfiguration-Orchestrated.ps1

.EXAMPLE
    .\Invoke-Phase03OsConfiguration-Orchestrated.ps1 -ConfigPath "C:\configs\infrastructure-azl-lab.yml"

.EXAMPLE
    .\Invoke-Phase03OsConfiguration-Orchestrated.ps1 -NTPServer "10.250.1.1 time.windows.com"

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-12-complete-combined-script-all-steps
    Execution:    Run from management server (PSRemoting outbound to nodes)
    Prerequisites: WinRM enabled on all nodes (Task 01), admin credentials accessible
    Excludes:     Task 01 (WinRM — manual via console/SConfig)
                  Task 11 (Clear Storage — conditional, run separately if needed)
    Run after:    Task 01 - WinRM enabled on all nodes
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [string]$NTPServer = "",

    [switch]$SkipHostnameRename,

    [string[]]$TargetNode = @(),

    [int]$ReconnectTimeoutSec = 300,
    [int]$ReconnectRetrySec   = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region HELPERS

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "SUCCESS" { "[PASS]" }
        "ERROR"   { "[FAIL]" }
        "WARN"    { "[WARN]" }
        "HEADER"  { "[----]" }
        default   { "[INFO]" }
    }
    $line = "[$ts] $prefix $Message"
    try {
        $color = switch ($Level) {
            "SUCCESS" { "Green" }
            "ERROR"   { "Red" }
            "WARN"    { "Yellow" }
            "HEADER"  { "Cyan" }
            default   { "White" }
        }
        Write-Host $line -ForegroundColor $color
    } catch {
        [Console]::WriteLine($line)
    }
}

function Resolve-ConfigPath {
    param([string]$Provided)
    if ($Provided -ne "" -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }
    $candidates = @(
        (Join-Path $PSScriptRoot "..\..\..\..\configs\infrastructure.yml"),
        (Join-Path $PSScriptRoot "..\..\..\..\..\configs\infrastructure.yml"),
        "$env:USERPROFILE\infrastructure.yml",
        "C:\configs\infrastructure.yml"
    )
    foreach ($c in $candidates) {
        try {
            $r = [System.IO.Path]::GetFullPath($c)
            if (Test-Path $r) { return $r }
        } catch {}
    }
    # Attempt to find any infrastructure*.yml in a config/ subdirectory
    foreach ($dir in @((Join-Path $PSScriptRoot "configs"), ".\configs")) {
        if (Test-Path $dir) {
            $found = @(Get-ChildItem -Path $dir -Filter "infrastructure*.yml" -File -ErrorAction SilentlyContinue)
            if ($found.Count -eq 1) { return $found[0].FullName }
            if ($found.Count -gt 1) {
                Write-Log "Multiple configs found in ${dir}:" "WARN"
                for ($i = 0; $i -lt $found.Count; $i++) {
                    Write-Host "  [$($i+1)] $($found[$i].Name)" -ForegroundColor Yellow
                }
                $sel = [int](Read-Host "Select config [1-$($found.Count)]") - 1
                if ($sel -ge 0 -and $sel -lt $found.Count) { return $found[$sel].FullName }
            }
        }
    }
    throw "infrastructure.yml not found. Pass -ConfigPath or place it in a standard location."
}

function Get-ClusterConfig {
    param([string]$ConfigPath)

    if (-not (Get-Module -Name powershell-yaml -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

    $az         = $cfg.compute.azure_local
    $ntpServers = @($cfg.identity.active_directory.ntp_servers)

    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            nodename      = $_.Key
            hostname      = $_.Value.hostname
            management_ip = $_.Value.management_ip
        }
    }

    return [PSCustomObject]@{
        Gateway      = $az.default_gateway
        SubnetMask   = $az.subnet_mask
        DnsServers   = @($az.dns_servers)
        NtpServers   = $ntpServers
        Nodes        = @($nodes)
        AdminUser    = $cfg.identity.accounts.account_local_admin_username
        AdminPassUri = $cfg.identity.accounts.account_local_admin_password
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

function Wait-NodeOnline {
    param([string]$IP, [PSCredential]$Cred, [int]$TimeoutSec, [int]$RetrySec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Log "  Waiting up to ${TimeoutSec}s for node to come back online..."
    Start-Sleep -Seconds 30
    while ((Get-Date) -lt $deadline) {
        if (Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            try {
                $name = Invoke-Command -ComputerName $IP -Credential $Cred `
                    -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
                return $name
            } catch { }
        }
        Start-Sleep -Seconds $RetrySec
        Write-Log "  Not yet reachable — retrying..." INFO
    }
    return $null
}

#endregion HELPERS

#region MAIN

Write-Log "================================================================" HEADER
Write-Log "   Phase 03 OS Configuration — Combined Execution (Tasks 02–10)" HEADER
Write-Log "================================================================" HEADER
Write-Log ""
Write-Log "  Includes : Tasks 02–10 (RDP, Static IP, DHCP, DNS, Verify DNS,"
Write-Log "             NTP, ICMP, Disable Adapters, Hostname)"
Write-Log "  Excludes : Task 01 (WinRM — must be done manually first)"
Write-Log "             Task 11 (Clear Storage — conditional, run separately)"
Write-Log ""

# ---------------------------------------------------------------------------
# 1. Load configuration
# ---------------------------------------------------------------------------
$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Config : $configFile"

Write-Log "--- Loading configuration ---" HEADER
$cfg = Get-ClusterConfig -ConfigPath $configFile

$gateway      = $cfg.Gateway
$subnetMask   = $cfg.SubnetMask
$dnsServers   = $cfg.DnsServers
$nodes        = $cfg.Nodes
$adminUser    = $cfg.AdminUser
$adminPassUri = $cfg.AdminPassUri

if (-not $gateway)           { throw "compute.azure_local.default_gateway not found in config." }
if (-not $subnetMask)        { throw "compute.azure_local.subnet_mask not found in config." }
if ($dnsServers.Count -lt 1) { throw "compute.azure_local.dns_servers not found or empty in config." }
if ($nodes.Count -eq 0)      { throw "No nodes found under compute.cluster_nodes in config." }

$prefixLength = Convert-SubnetMaskToPrefix -Mask $subnetMask
$dnsPrimary   = $dnsServers[0]
$dnsSecondary = if ($dnsServers.Count -ge 2) { $dnsServers[1] } else { $dnsPrimary }
$ntpPeer      = if ($NTPServer -ne "") { $NTPServer } elseif ($cfg.NtpServers.Count -gt 0) { $cfg.NtpServers -join " " } else { "time.windows.com" }

Write-Log "  Gateway        : $gateway"
Write-Log "  Subnet mask    : $subnetMask (/$prefixLength)"
Write-Log "  DNS primary    : $dnsPrimary"
Write-Log "  DNS secondary  : $dnsSecondary"
Write-Log "  NTP server(s)  : $ntpPeer"

Write-Log "Found $($nodes.Count) node(s):"
foreach ($n in $nodes) {
    $displayName = if ($n.hostname -ne "") { $n.hostname } else { $n.nodename }
    Write-Log "  $displayName  ($($n.management_ip))"
}

# ---------------------------------------------------------------------------
# 2. Resolve credentials
# ---------------------------------------------------------------------------
Write-Log "--- Resolving credentials ---" HEADER

if (-not $adminUser)    { $adminUser    = "Administrator" }
if (-not $adminPassUri) { $adminPassUri = "" }

if (-not $Credential) {
    $adminPass = $null
    if ($adminPassUri -ne "") {
        $adminPass = Resolve-KeyVaultRef -KvUri $adminPassUri
    }
    if ($adminPass) {
        $Credential = New-Object PSCredential(
            $adminUser,
            (ConvertTo-SecureString $adminPass -AsPlainText -Force)
        )
        Write-Log "Credentials resolved for '$adminUser'." SUCCESS
    } else {
        Write-Log "Key Vault unavailable — prompting for credentials." WARN
        $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" `
            -UserName $adminUser
    }
}
$cred = $Credential

if ($TargetNode.Count -gt 0) {
    $nodes = @($nodes | Where-Object { $TargetNode -contains $_.hostname -or $TargetNode -contains $_.nodename })
    if ($nodes.Count -eq 0) { throw "No nodes matched filter: $($TargetNode -join ', ')" }
    Write-Log "Node filter applied — running against: $($nodes.hostname -join ', ')" WARN
}

Write-Log ""
Write-Log "Ready. Processing $($nodes.Count) node(s)..." HEADER

# ---------------------------------------------------------------------------
# 5. Per-node execution — Tasks 02–09
# ---------------------------------------------------------------------------
$nodeResults = @()

foreach ($node in $nodes) {
    $ip          = $node.management_ip
    $targetName  = if ($node.hostname -ne "") { $node.hostname } else { $node.nodename }

    Write-Log "================================================================" HEADER
    Write-Log "  NODE: $targetName  ($ip)" HEADER
    Write-Log "================================================================" HEADER

    $taskStatus = "OK"     # Will be set to Warn or Error if issues arise
    $taskErrors = @()

    try {
        # ------------------------------------------------------------------
        # Tasks 02–09: Run as a single remote session (with WinRM-blip retry)
        # ------------------------------------------------------------------
        # During Task 03/04 (DHCP disable + static IP), the network briefly
        # drops. WinRM auto-reconnects but may lose the remote runspace state,
        # throwing a NullReferenceException at the transport layer. We detect
        # this and retry once — the scriptblock is idempotent so it is safe.
        # ------------------------------------------------------------------
        $remoteResult  = $null
        $icAttempt     = 0
        $icMaxAttempts = 2

        while ($icAttempt -lt $icMaxAttempts -and $null -eq $remoteResult) {
            $icAttempt++
            if ($icAttempt -eq 1) {
                Write-Log "[$targetName] Connecting for Tasks 02–09..."
            } else {
                Write-Log "[$targetName] WinRM session lost during network-sensitive task — waiting 20s before retry (attempt $icAttempt/$icMaxAttempts)..." WARN
                Start-Sleep -Seconds 20
                Write-Log "[$targetName] Retrying Tasks 02–09..." WARN
            }

            try {
                $remoteResult = Invoke-Command `
                    -ComputerName $ip `
                    -Credential $cred `
                    -ArgumentList $ip, $gateway, $prefixLength, $dnsPrimary, $dnsSecondary, $ntpPeer `
                    -ErrorAction SilentlyContinue `
                    -ScriptBlock {
                param(
                    [string]$StaticIP,
                    [string]$Gateway,
                    [int]   $PrefixLength,
                    [string]$DNS1,
                    [string]$DNS2,
                    [string]$NTPServer
                )

                $stepLog    = [System.Collections.Generic.List[string]]::new()
                $stepErrors = [System.Collections.Generic.List[string]]::new()

                function Step {
                    param([string]$Name, [scriptblock]$Action)
                    try {
                        $out = & $Action
                        $stepLog.Add("  [PASS] $Name")
                        if ($out) {
                            foreach ($line in @($out)) {
                                if ($line -is [string] -and $line.Trim() -ne "") {
                                    $stepLog.Add("         $($line.Trim())")
                                }
                            }
                        }
                    } catch {
                        $stepLog.Add("  [FAIL] $Name : $($_.Exception.Message)")
                        $stepErrors.Add("$Name : $($_.Exception.Message)")
                    }
                }

                # ---- Task 02: Enable RDP ----
                Step "Task 02 - Enable RDP" {
                    Set-ItemProperty `
                        -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                        -Name fDenyTSConnections -Value 0 -ErrorAction Stop
                    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
                }

                # ---- Task 03/04: Disable DHCP + Set Static IP ----
                Step "Task 03/04 - Disable DHCP + Configure Static IP" {
                    # Find the management adapter — prefer the one that currently holds the target IP
                    $adapter = Get-NetAdapter -ErrorAction Stop |
                        Where-Object { $_.Status -eq "Up" } |
                        Sort-Object {
                            $ip4 = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
                                        -ErrorAction SilentlyContinue).IPAddress
                            if ($ip4 -contains $StaticIP) { 0 } else { 1 }
                        } |
                        Select-Object -First 1

                    if (-not $adapter) { throw "No active network adapter found." }

                    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex `
                        -Dhcp Disabled -ErrorAction Stop

                    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue |
                        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                    Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue |
                        Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
                        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

                    New-NetIPAddress `
                        -InterfaceIndex $adapter.ifIndex `
                        -IPAddress $StaticIP `
                        -PrefixLength $PrefixLength `
                        -DefaultGateway $Gateway `
                        -ErrorAction Stop | Out-Null

                    "Adapter: $($adapter.Name)  IP: $StaticIP/$PrefixLength  GW: $Gateway"
                }

                # ---- Task 05: Configure DNS ----
                Step "Task 05 - Configure DNS Servers" {
                    # Use the adapter that now has the static IP
                    $adapter = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" } |
                        Sort-Object {
                            $ip4 = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 `
                                        -ErrorAction SilentlyContinue).IPAddress
                            if ($ip4 -contains $StaticIP) { 0 } else { 1 }
                        } |
                        Select-Object -First 1

                    if (-not $adapter) { throw "No active network adapter found." }

                    Set-DnsClientServerAddress `
                        -InterfaceIndex $adapter.ifIndex `
                        -ServerAddresses @($DNS1, $DNS2) `
                        -ErrorAction Stop

                    "DNS set on '$($adapter.Name)': primary=$DNS1, secondary=$DNS2"
                }

                # ---- Task 06: Verify DNS Configuration ----
                Step "Task 06 - Verify DNS Configuration" {
                    $configured = Get-DnsClientServerAddress -AddressFamily IPv4 |
                        Where-Object { $_.ServerAddresses.Count -gt 0 }

                    $allServers = $configured | ForEach-Object { $_.ServerAddresses } |
                        Select-Object -Unique

                    if ($allServers -notcontains $DNS1) {
                        throw "Primary DNS $DNS1 not found in configured servers: $($allServers -join ', ')"
                    }
                    "Configured DNS: $($allServers -join ', ')"
                }

                # ---- Task 07: Configure NTP ----
                Step "Task 07 - Configure NTP" {
                    & w32tm /config /manualpeerlist:"$NTPServer" /syncfromflags:manual /reliable:YES /update 2>&1 | Out-Null
                    Restart-Service w32time -Force
                    Start-Sleep -Seconds 5
                    & w32tm /resync /force 2>&1 | Out-Null
                    Start-Sleep -Seconds 3

                    $ntpStatus = & w32tm /query /status 2>&1
                    $stratum   = ($ntpStatus | Select-String 'Stratum:')  -replace '.*Stratum:\s*(\d+).*', '$1'
                    $source    = ($ntpStatus | Select-String 'Source:')   -replace '.*Source:\s*(.+)',     '$1'
                    $source    = $source.Trim()
                    $stratum   = $stratum.Trim()

                    if ($source -match 'Local CMOS Clock|Free-running') {
                        throw "NTP not syncing — source is '$source'. Peers: $NTPServer"
                    }
                    "NTP Stratum: $stratum  Source: $source"
                }

                # ---- Task 08: Enable ICMP (ping) ----
                Step "Task 08 - Enable ICMP" {
                    $icmpRules = @(
                        "File and Printer Sharing (Echo Request - ICMPv4-In)",
                        "Core Networking Diagnostics - ICMP Echo Request (ICMPv4-In)"
                    )
                    $enabled = 0
                    foreach ($ruleName in $icmpRules) {
                        try {
                            Enable-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
                            $enabled++
                        } catch {}
                    }
                    if ($enabled -eq 0) {
                        # Try by group as a last resort
                        Enable-NetFirewallRule -Group "File and Printer Sharing" -ErrorAction SilentlyContinue
                    }
                    "ICMP enabled ($enabled rule(s) matched by exact name)"
                }

                # ---- Task 09: Disable unused adapters ----
                Step "Task 09 - Disable Unused Adapters" {
                    $disconnected = Get-NetAdapter | Where-Object { $_.Status -eq "Disconnected" }
                    if ($disconnected.Count -eq 0) {
                        "No disconnected adapters found"
                    } else {
                        $names = @()
                        foreach ($a in $disconnected) {
                            Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
                            $names += $a.Name
                        }
                        "Disabled $($names.Count) adapter(s): $($names -join ', ')"
                    }
                }

                return [PSCustomObject]@{
                    Output = @($stepLog)
                    Errors = @($stepErrors)
                }
            }
            } catch {
                # Detect WinRM transport errors caused by the expected network blip
                # during Task 03/04 (DHCP disable + static IP). WinRM reconnects
                # automatically but the remote runspace state is lost, surfacing as
                # a NullReferenceException at the deserialization layer.
                $blipMsg = $_.Exception.Message
                $isBlip  = $blipMsg -match 'Object reference not set|NullReference|network connection|interrupted|reconnect|broken pipe'
                if ($isBlip -and $icAttempt -lt $icMaxAttempts) {
                    Write-Log "[$targetName] WinRM session dropped (network-sensitive task) — will retry in 20s..." WARN
                    # Fall through to top of while loop for retry
                } else {
                    throw   # Non-blip error or retries exhausted — propagate to outer catch
                }
            }
        }  # end retry while

        # Print remote output
        if ($null -eq $remoteResult) {
            # Invoke-Command returned nothing after all attempts
            $icErr = try { if ($Error.Count -gt 0) { $Error[0].ToString() } else { "Connection failed after $icMaxAttempts attempt(s)" } } catch { "WinRM connection failed" }
            throw $icErr
        }

        # Print remote output
        foreach ($line in $remoteResult.Output) {
            $color = if ($line -match '\[PASS\]') { "Green" }
                     elseif ($line -match '\[FAIL\]') { "Red" }
                     else { "White" }
            Write-Host $line -ForegroundColor $color
        }

        if ($remoteResult.Errors.Count -gt 0) {
            $taskStatus = "Warn($($remoteResult.Errors.Count) error(s))"
            $taskErrors = $remoteResult.Errors
            Write-Log "[$targetName] Tasks 02–09 completed with $($remoteResult.Errors.Count) error(s)." WARN
        } else {
            Write-Log "[$targetName] Tasks 02–09 completed successfully." SUCCESS
        }

        # ------------------------------------------------------------------
        # Task 10: Configure hostname (rename + restart + verify)
        # ------------------------------------------------------------------
        if ($SkipHostnameRename) {
            Write-Log "[$targetName] Task 10 - SKIPPED (-SkipHostnameRename)" WARN
            $nodeResults += [PSCustomObject]@{
                Node      = $targetName
                IP        = $ip
                Tasks0209 = $taskStatus
                Task10    = "Skipped"
                FinalName = "N/A"
                Errors    = ($taskErrors -join "; ")
            }
            continue
        }
        Write-Log "[$targetName] Task 10 - Configure hostname..."

        $currentName = Invoke-Command -ComputerName $ip -Credential $cred `
            -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop

        if ($currentName -eq $targetName) {
            Write-Log "[$targetName] Hostname already '$targetName' — skipping rename." SUCCESS
            $nodeResults += [PSCustomObject]@{
                Node      = $targetName
                IP        = $ip
                Tasks0209 = $taskStatus
                Task10    = "AlreadyConfigured"
                FinalName = $currentName
                Errors    = ($taskErrors -join "; ")
            }
        } else {
            Write-Log "[$targetName] Current hostname: '$currentName' — renaming to '$targetName'..."

            Invoke-Command -ComputerName $ip -Credential $cred `
                -ArgumentList $targetName `
                -ScriptBlock {
                    param([string]$Name)
                    Rename-Computer -NewName $Name -Force -ErrorAction Stop
                } -ErrorAction Stop

            Write-Log "[$targetName] Renamed. Restarting..."
            try {
                Restart-Computer -ComputerName $ip -Credential $cred -Force -ErrorAction Stop
            } catch {
                # Disconnect is expected when the session drops during restart
                if ($_.Exception.Message -notmatch 'closed|broken|disconnect|pipe') {
                    Write-Log "  Restart note: $($_.Exception.Message)" WARN
                }
            }

            $reportedName = Wait-NodeOnline `
                -IP $ip -Cred $cred `
                -TimeoutSec $ReconnectTimeoutSec `
                -RetrySec $ReconnectRetrySec

            if ($null -eq $reportedName) {
                Write-Log "[$targetName] Node did not respond within ${ReconnectTimeoutSec}s." ERROR
                $nodeResults += [PSCustomObject]@{
                    Node      = $targetName
                    IP        = $ip
                    Tasks0209 = $taskStatus
                    Task10    = "Error - Timeout"
                    FinalName = "Unknown"
                    Errors    = ($taskErrors -join "; ")
                }
            } elseif ($reportedName -eq $targetName) {
                Write-Log "[$targetName] Verified — hostname is now '$reportedName'." SUCCESS
                $nodeResults += [PSCustomObject]@{
                    Node      = $targetName
                    IP        = $ip
                    Tasks0209 = $taskStatus
                    Task10    = "OK"
                    FinalName = $reportedName
                    Errors    = ($taskErrors -join "; ")
                }
            } else {
                Write-Log "[$targetName] Mismatch: expected '$targetName', got '$reportedName'." ERROR
                $nodeResults += [PSCustomObject]@{
                    Node      = $targetName
                    IP        = $ip
                    Tasks0209 = $taskStatus
                    Task10    = "Error - NameMismatch"
                    FinalName = $reportedName
                    Errors    = ($taskErrors -join "; ")
                }
            }
        }

    } catch {
        $errMsg = try { $_.Exception.Message } catch { $null }
        if (-not $errMsg) { $errMsg = try { "$_" } catch { "Unhandled error (see output)" } }
        Write-Log "[$targetName] Unhandled error: $errMsg" ERROR
        $nodeResults += [PSCustomObject]@{
            Node      = $targetName
            IP        = $ip
            Tasks0209 = "Error"
            Task10    = "Skipped"
            FinalName = "Unknown"
            Errors    = $errMsg
        }
    }
}

#endregion MAIN

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
Write-Log ""
Write-Log "================================================================" HEADER
Write-Log "  SUMMARY" HEADER
Write-Log "================================================================" HEADER

$nodeResults | Format-Table Node, IP, Tasks0209, Task10, FinalName -AutoSize

$failed = @($nodeResults | Where-Object {
    $_.Tasks0209 -match "Error" -or $_.Task10 -match "Error"
})

if ($failed.Count -gt 0) {
    Write-Log "$($failed.Count) node(s) had errors. Review output above." ERROR
    if ($nodeResults | Where-Object { $_.Errors -ne "" }) {
        Write-Log "Error details:" ERROR
        $nodeResults | Where-Object { $_.Errors -ne "" } |
            ForEach-Object { Write-Log "  [$($_.Node)]: $($_.Errors)" ERROR }
    }
    exit 1
} else {
    Write-Log "All $($nodeResults.Count) node(s) completed Phase 03 OS configuration successfully." SUCCESS
    Write-Log ""
    Write-Log "Next step  : Task 11 (Clear Previous Storage) if needed, then proceed to Phase 04."
}
