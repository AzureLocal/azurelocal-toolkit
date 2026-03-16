<#
.SYNOPSIS
    Invoke-ConfigureNazl-Orchestrated.ps1
    Configures NTP on all Azure Local nodes via PSRemoting.

.DESCRIPTION
    Runs from the management server. Reads NTP server list and node IPs from
    infrastructure.yml, connects to each node over PSRemoting, and configures
    the Windows Time service.

    infrastructure.yml paths used:
      active_directory.ntp_servers    - List of NTP servers (joined for manualpeerlist)
      cluster_nodes[].management_ip   - PSRemoting connection target per node
      cluster_nodes[].hostname        - Node hostname (display only)

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-07-configure-time-synchronization-ntp
    Execution:    Run from management server (PSRemoting outbound to nodes)
    Prerequisites: WinRM enabled on all nodes, admin credentials
    Run after:    Task 06 - DNS verified

.EXAMPLE
    .\Invoke-ConfigureNazl-Orchestrated.ps1
    .\Invoke-ConfigureNazl-Orchestrated.ps1 -ConfigPath "C:\configs\infrastructure.yml"
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
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
}

function Resolve-ConfigPath {
    param([string]$Provided)

    if ($Provided -ne "" -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }

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

function Get-ClusterConfig {
    [CmdletBinding()]
    param([string]$ConfigPath)

    if (-not (Get-Module -Name powershell-yaml -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Log "Installing powershell-yaml module..." "WARN"
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

    $ntpServers = $cfg.identity.active_directory.ntp_servers
    if (-not $ntpServers -or $ntpServers.Count -eq 0) {
        throw "identity.active_directory.ntp_servers not found or empty in $ConfigPath."
    }

    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        Write-Log "  Node: $($_.Key)  IP: $($_.Value.management_ip)"
        [PSCustomObject]@{ hostname = $_.Key; management_ip = $_.Value.management_ip }
    }

    if (-not $nodes) { throw "No nodes found under compute.cluster_nodes in $ConfigPath." }

    $adminUser    = $cfg.identity.accounts.account_local_admin_username
    $adminPassUri = $cfg.identity.accounts.account_local_admin_password

    return [PSCustomObject]@{
        NTPServers   = @($ntpServers)
        Nodes        = @($nodes)
        AdminUser    = $adminUser
        AdminPassUri = $adminPassUri
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

#endregion HELPERS

#region MAIN

Write-Log "=== Task 07 - Configure Time Synchronization (NTP) ===" "HEADER"

$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Config: $configFile"

$clusterCfg  = Get-ClusterConfig -ConfigPath $configFile
$ntpList     = $clusterCfg.NTPServers
$nodes       = $clusterCfg.Nodes
$ntpPeerList = $ntpList -join " "

Write-Log "NTP servers  : $ntpPeerList"
Write-Log "Nodes        : $($nodes.Count) found"

if (-not $Credential) {
    Write-Log "Resolving credentials from Key Vault..."
    $adminPass = Resolve-KeyVaultRef -KvUri $clusterCfg.AdminPassUri
    if ($adminPass) {
        $Credential = New-Object PSCredential($clusterCfg.AdminUser.Trim(), (ConvertTo-SecureString $adminPass -AsPlainText -Force))
        Write-Log "Credentials resolved for '$($clusterCfg.AdminUser.Trim())'." SUCCESS
    } else {
        Write-Log "Key Vault unavailable — prompting for credentials." WARN
        $Credential = Get-Credential -Message "Enter local Administrator credentials for cluster nodes" -UserName $clusterCfg.AdminUser.Trim()
    }
}
$cred = $Credential

$results = @()

foreach ($node in $nodes) {
    $ip       = $node.management_ip
    $hostname = $node.hostname
    if (-not $ip) {
        Write-Log "[$hostname] management_ip missing -- skipping" "WARN"
        continue
    }

    Write-Log "[$hostname] Connecting to $ip..."

    try {
        $r = Invoke-Command -ComputerName $ip -Credential $cred -ArgumentList $ntpPeerList -ScriptBlock {
            param($peerList)

            # Pre-flight: verify at least one NTP peer is reachable from this node
            $peers = $peerList -split '\s+' | Where-Object { $_ -ne '' }
            $reachable = @()
            foreach ($peer in $peers) {
                if (Test-Connection -ComputerName $peer -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                    $reachable += $peer
                }
            }
            if ($reachable.Count -eq 0) {
                throw "NTP peers not reachable from $env:COMPUTERNAME: $($peers -join ', '). Deploy DCs first."
            }

            w32tm /config /manualpeerlist:$peerList /syncfromflags:manual /reliable:YES /update | Out-Null
            Restart-Service w32time -Force
            Start-Sleep -Seconds 3
            w32tm /resync /force | Out-Null

            $status  = w32tm /query /status
            $stratum = ($status | Select-String "Stratum:") -replace ".*Stratum:\s*(\d+).*", '$1'
            $source  = ($status | Select-String "Source:")  -replace ".*Source:\s*(.+)",    '$1'
            $sourceTrimmed = $source.Trim()

            $ok = [int]$stratum -lt 16 -and $sourceTrimmed -notmatch 'Local CMOS Clock|Free-running'
            if (-not $ok -and $sourceTrimmed -match 'Local CMOS Clock|Free-running') {
                throw "NTP not syncing — source is '$sourceTrimmed' despite peers being reachable."
            }

            [PSCustomObject]@{
                Hostname = $env:COMPUTERNAME
                Stratum  = $stratum.Trim()
                Source   = $sourceTrimmed
                Status   = if ($ok) { "PASS" } else { "WARN" }
            }
        }

        $color = if ($r.Status -eq "PASS") { "SUCCESS" } else { "WARN" }
        Write-Log "[$hostname] $($r.Status)  Stratum: $($r.Stratum)  Source: $($r.Source)" $color

        $results += [PSCustomObject]@{
            Node     = $hostname
            IP       = $ip
            Stratum  = $r.Stratum
            Source   = $r.Source
            Status   = $r.Status
        }
    } catch {
        Write-Log "[$hostname] PSRemoting failed: $_" "ERROR"
        $results += [PSCustomObject]@{
            Node    = $hostname
            IP      = $ip
            Stratum = ""
            Source  = ""
            Status  = "ERROR"
        }
    }
}

Write-Log ""
Write-Log "=== NTP Configuration Summary ===" "HEADER"
$results | Format-Table Node, IP, Stratum, Source, Status -AutoSize

$failCount = @($results | Where-Object { $_.Status -eq "ERROR" }).Count
if ($failCount -eq 0) {
    Write-Log "All $($results.Count) node(s) NTP configured successfully." "SUCCESS"
} else {
    Write-Log "$failCount node(s) failed. Review output above." "ERROR"
    exit 1
}

#endregion MAIN
