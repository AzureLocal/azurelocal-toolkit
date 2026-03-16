#Requires -Version 7.0
<#
.SYNOPSIS
    Invoke-ConfigureStaticIP-Orchestrated.ps1
    Configures static IP addresses on all Azure Local nodes from the management server.

.DESCRIPTION
    Runs from the management server. Reads all IP configuration from infrastructure.yml
    (management IP, prefix, gateway, DNS, NIC name) and pushes the configuration to
    each node via PSRemoting.

    Session-loss handling:
    When the static IP is applied, the node
    session WILL drop — this is expected. The orchestrator catches that disconnect,
    waits for the node to stabilise on its new IP, then opens a fresh session to the
    new static IP and runs a verification query to confirm all settings took.

    Infrastructure.yml paths used per node:
      nodes.<name>.management_ip              -> static IP to assign
      network.management.prefix_length        -> subnet prefix (e.g. 24)
      network.management.gateway              -> default gateway
      dns.primary                             -> primary DNS
      dns.secondary                           -> secondary DNS
      cluster.management_nic_name             -> exact NIC adapter name

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-detected from .\configs\ if not specified.

.PARAMETER NodeNames
    Specific node names to target. Default: all nodes in infrastructure.yml.

.PARAMETER Credential
    PSCredential for PSRemoting. Prompted if not provided.

.PARAMETER RetryCount
    Validation retry attempts on the node. Default: 3.

.PARAMETER ReconnectTimeoutSec
    Seconds to wait for node to come up on new static IP. Default: 60.

.PARAMETER ReconnectRetrySec
    Seconds between reconnect attempts. Default: 10.

.EXAMPLE
    .\Invoke-ConfigureStaticIP-Orchestrated.ps1

.EXAMPLE
    .\Invoke-ConfigureStaticIP-Orchestrated.ps1 -NodeNames "AZL-NODE01","AZL-NODE02"

.EXAMPLE
    .\Invoke-ConfigureStaticIP-Orchestrated.ps1 -ConfigPath ".\configs\infrastructure-poc.yml"

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      2.0.0
    Phase:        03-os-configuration
    Task:         task-03-configure-static-ip-address
    Prerequisites: PowerShell 7+, powershell-yaml module, PSRemoting enabled on nodes (Task 01)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string[]]$NodeNames,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 3,

    [Parameter(Mandatory = $false)]
    [int]$ReconnectTimeoutSec = 60,

    [Parameter(Mandatory = $false)]
    [int]$ReconnectRetrySec = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# FUNCTIONS
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

function Resolve-ConfigPath {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "Config not found: $ExplicitPath" }
        Write-Log "Using specified config: $ExplicitPath"
        return $ExplicitPath
    }

    $candidates = Get-ChildItem -Path ".\configs\" -Filter "infrastructure*.yml" -ErrorAction SilentlyContinue
    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No infrastructure*.yml found in .\configs\. Use -ConfigPath."
    }
    if ($candidates.Count -eq 1) {
        Write-Log "Auto-detected config: $($candidates[0].FullName)"
        return $candidates[0].FullName
    }

    Write-Host "`nMultiple config files found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $default = if ($candidates[$i].Name -eq "infrastructure.yml") { " [DEFAULT]" } else { "" }
        Write-Host "  [$($i+1)] $($candidates[$i].Name)$default"
    }
    $defaultIdx = ($candidates | ForEach-Object { $_.Name }).IndexOf("infrastructure.yml")
    if ($defaultIdx -lt 0) { $defaultIdx = 0 }
    $sel = Read-Host "`nSelect config (Enter for default [$($candidates[$defaultIdx].Name)])"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $candidates[$defaultIdx].FullName }
    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $candidates.Count) { throw "Invalid selection: $sel" }
    return $candidates[$idx].FullName
}

function Get-NodeConfigs {
    param([hashtable]$Config)

    $azureLocal = $Config.compute.azure_local
    $clusterNIC = $Config.network_config.management_nic_name

    if (-not $azureLocal.default_gateway) { throw "compute.azure_local.default_gateway not set in infrastructure.yml" }
    if (-not $azureLocal.subnet_mask)     { throw "compute.azure_local.subnet_mask not set in infrastructure.yml" }
    if (-not $azureLocal.dns_servers -or $azureLocal.dns_servers.Count -lt 2) { throw "compute.azure_local.dns_servers must have at least 2 entries in infrastructure.yml" }
    if (-not $clusterNIC)                 { throw "network_config.management_nic_name not set in infrastructure.yml" }

    # Convert subnet mask to prefix length
    $maskBytes = $azureLocal.subnet_mask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8,'0') }
    $prefixLength = ($maskBytes -join '').ToCharArray() | Where-Object { $_ -eq '1' } | Measure-Object | Select-Object -ExpandProperty Count

    $gateway    = $azureLocal.default_gateway
    $dnsPrimary = $azureLocal.dns_servers[0]
    $dnsSecondary = $azureLocal.dns_servers[1]

    $nodeConfigs = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in $Config.compute.cluster_nodes.GetEnumerator()) {
        $nodeName = $entry.Key
        $nodeData = $entry.Value

        if (-not $nodeData.management_ip) {
            Write-Log "Node $nodeName has no management_ip in infrastructure.yml — skipping" "WARN"
            continue
        }

        $nodeConfigs.Add(@{
            NodeName      = $nodeName
            CurrentIP     = $nodeData.management_ip  # DHCP-reserved = current IP = target IP
            TargetIP      = $nodeData.management_ip
            PrefixLength  = [int]$prefixLength
            Gateway       = $gateway
            DNSPrimary    = $dnsPrimary
            DNSSecondary  = $dnsSecondary
            ManagementNIC = $clusterNIC
        })
    }

    return $nodeConfigs
}

# The script block that runs INSIDE the PSRemoting session on the node.
# Receives all config values explicitly — never reads DHCP or auto-detects IP.
$NodeConfigScriptBlock = {
    param(
        [string]$ManagementNIC,
        [string]$TargetIP,
        [int]$PrefixLength,
        [string]$Gateway,
        [string]$DNSPrimary,
        [string]$DNSSecondary,
        [int]$RetryCount,
        [int]$RetryDelaySec
    )

    function Write-NLog {
        param([string]$M, [string]$L = "INFO")
        $ts = Get-Date -Format "HH:mm:ss"
        Write-Output "  [$ts][$L] $M"
    }

    try {
        Write-NLog "Node: $($env:COMPUTERNAME)"

        # Find adapter — exact name only
        $adapter = Get-NetAdapter | Where-Object { $_.InterfaceAlias -eq $ManagementNIC }
        if (-not $adapter) {
            $available = (Get-NetAdapter | Select-Object -ExpandProperty InterfaceAlias) -join ", "
            throw "Adapter '$ManagementNIC' not found on $($env:COMPUTERNAME). Available: $available"
        }
        Write-NLog "Adapter: $($adapter.InterfaceAlias)  MAC: $($adapter.MacAddress)"

        # Check if already fully configured (idempotent)
        $existingIP    = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $existingIface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
        $existingGW    = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                           Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }
        $existingDNS   = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses

        if ($existingIP -and
            $existingIP.IPAddress   -eq $TargetIP         -and
            $existingIP.PrefixLength -eq $PrefixLength     -and
            $existingIP.PrefixOrigin -eq "Manual"          -and
            $existingIface.Dhcp      -eq "Disabled"        -and
            $existingGW -and $existingGW.NextHop -eq $Gateway -and
            ($existingDNS -contains $DNSPrimary)           -and
            ($existingDNS -contains $DNSSecondary)) {
            Write-NLog "Already correctly configured as static. No changes needed." "INFO"
            return @{ Result = "AlreadyConfigured"; IP = $TargetIP }
        }

        if ($existingIP.IPAddress -eq $TargetIP -and $existingIP.PrefixOrigin -eq "Dhcp") {
            Write-NLog "Target IP ($TargetIP) currently assigned via DHCP — locking in as static." "WARN"
        }

        # Apply static configuration
        Write-NLog "Disabling DHCP..."
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled

        Write-NLog "Removing existing IP addresses..."
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        Write-NLog "Removing existing default routes..."
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        Write-NLog "Setting static IP: $TargetIP/$PrefixLength  GW: $Gateway"
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
            -IPAddress $TargetIP -PrefixLength $PrefixLength `
            -DefaultGateway $Gateway -ErrorAction Stop | Out-Null

        Write-NLog "Setting DNS: $DNSPrimary, $DNSSecondary"
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
            -ServerAddresses @($DNSPrimary, $DNSSecondary)

        # Commands submitted — session will likely drop here as IP changes.
        # Return a sentinel so the orchestrator knows commands were sent.
        return @{ Result = "CommandsSubmitted"; IP = $TargetIP }

    } catch {
        return @{ Result = "Error"; Error = $_.Exception.Message }
    }
}

# Verification script block — runs on the node AFTER reconnecting to the new static IP
$VerifyScriptBlock = {
    param([string]$ManagementNIC, [string]$TargetIP, [int]$PrefixLength,
          [string]$Gateway, [string]$DNSPrimary, [string]$DNSSecondary)

    $issues = [System.Collections.Generic.List[string]]::new()
    $adapter = Get-NetAdapter | Where-Object { $_.InterfaceAlias -eq $ManagementNIC }
    if (-not $adapter) { return @{ Valid = $false; Issues = @("Adapter not found") } }

    $ip    = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $iface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $gw    = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }
    $dns   = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses

    if (-not $ip -or $ip.IPAddress -ne $TargetIP)           { $issues.Add("IP: expected $TargetIP got $($ip.IPAddress)") }
    if ($ip -and $ip.PrefixLength -ne $PrefixLength)        { $issues.Add("Prefix: expected $PrefixLength got $($ip.PrefixLength)") }
    if ($ip -and $ip.PrefixOrigin -ne "Manual")             { $issues.Add("PrefixOrigin: $($ip.PrefixOrigin) (expected Manual)") }
    if ($iface.Dhcp -ne "Disabled")                         { $issues.Add("DHCP: $($iface.Dhcp) (expected Disabled)") }
    if (-not $gw -or $gw.NextHop -ne $Gateway)              { $issues.Add("Gateway: expected $Gateway got $($gw.NextHop)") }
    if ($dns -notcontains $DNSPrimary)                      { $issues.Add("DNS primary $DNSPrimary missing") }
    if ($dns -notcontains $DNSSecondary)                    { $issues.Add("DNS secondary $DNSSecondary missing") }

    return @{ Valid = ($issues.Count -eq 0); Issues = $issues; IP = $ip.IPAddress }
}

function Invoke-NodeConfiguration {
    param([hashtable]$NodeConfig, [PSCredential]$Cred)

    $nodeName    = $NodeConfig.NodeName
    $currentIP   = $NodeConfig.CurrentIP
    $targetIP    = $NodeConfig.TargetIP
    $nic         = $NodeConfig.ManagementNIC

    Write-Log "--- $nodeName ---" "HEADER"
    Write-Log "  Connecting to: $currentIP"
    Write-Log "  Target static IP: $targetIP/$($NodeConfig.PrefixLength)  GW: $($NodeConfig.Gateway)"

    # ---- Phase 1: Send configuration commands ----
    $phase1Result = $null
    try {
        Write-Log "  Opening PSRemoting session to $currentIP..."
        $phase1Result = Invoke-Command `
            -ComputerName $currentIP `
            -Credential $Cred `
            -ScriptBlock $NodeConfigScriptBlock `
            -ArgumentList $nic, $targetIP, $NodeConfig.PrefixLength, $NodeConfig.Gateway,
                          $NodeConfig.DNSPrimary, $NodeConfig.DNSSecondary, $RetryCount, 5 `
            -ErrorAction Stop

    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        # Session loss after IP change — this is the expected path
        Write-Log "  Session dropped (expected — IP change applied on node)." "WARN"
        $phase1Result = @{ Result = "CommandsSubmitted"; IP = $targetIP }

    } catch {
        Write-Log "  Phase 1 failed: $_" "ERROR"
        return @{ NodeName = $nodeName; Success = $false; Error = $_.Exception.Message }
    }

    # Write-NLog uses Write-Output, so Invoke-Command bundles log strings + the return hashtable
    # into an array. Forward any log lines and extract the final hashtable.
    if ($phase1Result -is [array]) {
        $phase1Result[0..($phase1Result.Count - 2)] | ForEach-Object { Write-Log "  [node] $_" }
        $phase1Result = $phase1Result[-1]
    }

    if ($phase1Result.Result -eq "Error") {
        Write-Log "  Node reported error: $($phase1Result.Error)" "ERROR"
        return @{ NodeName = $nodeName; Success = $false; Error = $phase1Result.Error }
    }

    if ($phase1Result.Result -eq "AlreadyConfigured") {
        Write-Log "  Already correctly configured." "SUCCESS"
        return @{ NodeName = $nodeName; Success = $true; IP = $targetIP; AlreadyDone = $true }
    }

    # ---- Phase 2: Reconnect to new static IP and verify ----
    Write-Log "  Waiting for node to come up on new IP $targetIP (timeout: ${ReconnectTimeoutSec}s)..." "WARN"
    $deadline    = (Get-Date).AddSeconds($ReconnectTimeoutSec)
    $verifyResult = $null

    while ((Get-Date) -lt $deadline) {
        try {
            Start-Sleep -Seconds $ReconnectRetrySec
            Write-Log "  Attempting reconnect to $targetIP..."

            $verifyResult = Invoke-Command `
                -ComputerName $targetIP `
                -Credential $Cred `
                -ScriptBlock $VerifyScriptBlock `
                -ArgumentList $nic, $targetIP, $NodeConfig.PrefixLength,
                              $NodeConfig.Gateway, $NodeConfig.DNSPrimary, $NodeConfig.DNSSecondary `
                -ErrorAction Stop

            # Unwrap log lines from verify result array
            if ($verifyResult -is [array]) { $verifyResult = $verifyResult[-1] }
            break   # connected
        } catch {
            Write-Log "  Reconnect attempt failed: $_ — retrying in ${ReconnectRetrySec}s..." "WARN"
        }
    }

    if (-not $verifyResult) {
        Write-Log "  Could not reconnect to $targetIP within ${ReconnectTimeoutSec}s." "ERROR"
        return @{ NodeName = $nodeName; Success = $false; Error = "Reconnect to $targetIP timed out" }
    }

    # ---- Phase 3: Evaluate verification result ----
    if ($verifyResult.Valid) {
        Write-Log "  All configuration checks passed on $targetIP." "SUCCESS"
        return @{ NodeName = $nodeName; Success = $true; IP = $targetIP }
    } else {
        Write-Log "  Verification failed:" "ERROR"
        foreach ($issue in $verifyResult.Issues) { Write-Log "    - $issue" "ERROR" }
        return @{ NodeName = $nodeName; Success = $false; Error = ($verifyResult.Issues -join "; ") }
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
# MAIN
# ============================================================================

try {
    Write-Log "=== Invoke-ConfigureStaticIP-Orchestrated.ps1 ===" "HEADER"

    # Resolve config file
    $resolvedConfig = Resolve-ConfigPath -ExplicitPath $ConfigPath

    # Load config
    Import-Module powershell-yaml -ErrorAction Stop
    $config = Get-Content $resolvedConfig -Raw | ConvertFrom-Yaml

    # Build per-node config objects
    $allNodeConfigs = Get-NodeConfigs -Config $config

    # Filter to requested nodes if specified
    if ($NodeNames -and $NodeNames.Count -gt 0) {
        $allNodeConfigs = $allNodeConfigs | Where-Object { $NodeNames -contains $_.NodeName }
        if ($allNodeConfigs.Count -eq 0) {
            throw "None of the specified NodeNames found in infrastructure.yml: $($NodeNames -join ', ')"
        }
    }

    Write-Log "Nodes to configure: $($allNodeConfigs.Count)"
    foreach ($nc in $allNodeConfigs) {
        Write-Log "  $($nc.NodeName)  current: $($nc.CurrentIP)  target: $($nc.TargetIP)/$($nc.PrefixLength)"
    }

    # Get credentials
    if (-not $Credential) {
        $adminUser    = $config.identity.accounts.account_local_admin_username
        $adminPassUri = $config.identity.accounts.account_local_admin_password
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

    # Process each node sequentially (IP change causes connectivity disruption — serial is safer)
    $results = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($nc in $allNodeConfigs) {
        $result = Invoke-NodeConfiguration -NodeConfig $nc -Cred $Credential
        $results.Add($result)
    }

    # Summary
    Write-Log "=== SUMMARY ===" "HEADER"
    $ok   = @($results | Where-Object { $_.Success })
    $fail = @($results | Where-Object { -not $_.Success })

    foreach ($r in $ok)   { Write-Log "  OK   $($r.NodeName)  $($r.IP)" "SUCCESS" }
    foreach ($r in $fail) { Write-Log "  FAIL $($r.NodeName)  $($r.Error)" "ERROR" }
    Write-Log "Configured: $($ok.Count) / $($results.Count)"

    if ($fail.Count -gt 0) { exit 1 }
    Write-Log "ALL NODES CONFIGURED SUCCESSFULLY" "SUCCESS"

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}

