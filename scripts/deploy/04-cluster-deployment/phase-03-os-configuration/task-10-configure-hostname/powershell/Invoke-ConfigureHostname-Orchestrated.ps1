#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-ConfigureHostname-Orchestrated.ps1
    Configures hostnames on all Azure Local nodes via PSRemoting.

.DESCRIPTION
    Runs from the management server. Reads target hostnames and management IPs from
    infrastructure.yml, renames each node if needed, restarts it, waits for it to
    come back online, then verifies the new hostname.

    The `hostname` value under each node in `compute.cluster_nodes` is used as the target hostname.
    Falls back to the key name if `hostname` is not set.

    infrastructure.yml paths used:
      compute.cluster_nodes                           - Node names and management IPs
      identity.accounts.account_local_admin_username  - Credential username
      identity.accounts.account_local_admin_password  - KV reference for password

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-detected from .\configs\ if not specified.

.PARAMETER Credential
    PSCredential for PSRemoting. If omitted, resolved from Key Vault.

.PARAMETER ReconnectTimeoutSec
    Seconds to wait for each node after restart before giving up. Default: 120.

.PARAMETER ReconnectRetrySec
    Seconds between reconnect attempts. Default: 10.

.EXAMPLE
    .\Invoke-ConfigureHostname-Orchestrated.ps1 -ConfigPath ".\configs\infrastructure-azl-lab.yml"
    .\Invoke-ConfigureHostname-Orchestrated.ps1

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      2.0.0
    Phase:        03-os-configuration
    Task:         task-10-configure-hostname
    Execution:    Run from management server (PSRemoting outbound to nodes)
    Prerequisites: WinRM enabled on all nodes, static IP configured (Task 03)
    Run after:    Task 09 - unused adapters disabled
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [int]$ReconnectTimeoutSec = 300,
    [int]$ReconnectRetrySec   = 10
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

    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        $h = if ($_.Value.hostname) { $_.Value.hostname } else { $_.Key }
        Write-Log "  Node: $h  ($($_.Key))  IP: $($_.Value.management_ip)"
        [PSCustomObject]@{ hostname = $h; nodename = $_.Key; management_ip = $_.Value.management_ip }
    }

    if (-not $nodes) { throw "No nodes found under compute.cluster_nodes in $ConfigPath." }

    $adminUser    = $cfg.identity.accounts.account_local_admin_username
    $adminPassUri = $cfg.identity.accounts.account_local_admin_password

    return [PSCustomObject]@{
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

function Wait-NodeOnline {
    param(
        [string]$IP,
        [PSCredential]$Cred,
        [int]$TimeoutSec,
        [int]$RetrySec
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Log "  Waiting up to ${TimeoutSec}s for node to come back online..."
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $RetrySec
        try {
            $result = Invoke-Command -ComputerName $IP -Credential $Cred `
                -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            return $result
        } catch {
            Write-Log "  Not yet reachable — retrying..." INFO
        }
    }
    return $null
}

#endregion HELPERS

#region MAIN

Write-Log "=== Task 10 - Configure Hostname ===" "HEADER"

$configFile = Resolve-ConfigPath -Provided $ConfigPath
Write-Log "Config: $configFile"

$clusterCfg = Get-ClusterConfig -ConfigPath $configFile
$nodes      = $clusterCfg.Nodes

Write-Log "Nodes : $($nodes.Count) found"
$nodes | ForEach-Object { Write-Log "  $($_.hostname)  ->  $($_.management_ip)" }

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

# Kick off all nodes in parallel
Write-Log "Starting parallel hostname rename on $($nodes.Count) node(s)..." HEADER

$jobs = @()
foreach ($node in $nodes) {
    $ip         = $node.management_ip
    $targetName = $node.hostname

    if (-not $ip) {
        Write-Log "[$targetName] management_ip missing — skipping" WARN
        continue
    }

    Write-Log "[$targetName] Starting job..."

    $jobs += Start-Job -Name $targetName -ArgumentList $ip, $targetName, $cred, $ReconnectTimeoutSec, $ReconnectRetrySec -ScriptBlock {
        param([string]$IP, [string]$TargetName, [PSCredential]$Cred, [int]$TimeoutSec, [int]$RetrySec)

        function Wait-Online {
            param([string]$IP, [PSCredential]$Cred, [int]$TimeoutSec, [int]$RetrySec)
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            Start-Sleep -Seconds 30
            while ((Get-Date) -lt $deadline) {
                if (Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                    try {
                        $n = Invoke-Command -ComputerName $IP -Credential $Cred `
                            -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
                        return $n
                    } catch { }
                }
                Start-Sleep -Seconds $RetrySec
            }
            return $null
        }

        try {
            $currentName = Invoke-Command -ComputerName $IP -Credential $Cred `
                -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop

            if ($currentName -ieq $TargetName) {
                return [PSCustomObject]@{
                    Node      = $TargetName
                    IP        = $IP
                    Result    = "AlreadyConfigured"
                    FinalName = $currentName
                    Detail    = "Hostname already '$TargetName'"
                }
            }

            Invoke-Command -ComputerName $IP -Credential $Cred `
                -ArgumentList $TargetName -ScriptBlock {
                    param([string]$Name)
                    Rename-Computer -NewName $Name -Force -ErrorAction Stop
                } -ErrorAction Stop

            try {
                Restart-Computer -ComputerName $IP -Credential $Cred -Force -ErrorAction Stop
            } catch {
                if ($_.Exception.Message -notmatch 'closed|broken|disconnect|pipe') {
                    Write-Warning "[$TargetName] Restart-Computer: $($_.Exception.Message)"
                }
            }

            $reportedName = Wait-Online -IP $IP -Cred $Cred -TimeoutSec $TimeoutSec -RetrySec $RetrySec

            if ($null -eq $reportedName) {
                return [PSCustomObject]@{
                    Node      = $TargetName
                    IP        = $IP
                    Result    = "Error"
                    FinalName = "Unknown"
                    Detail    = "Node did not respond after restart (timeout ${TimeoutSec}s)"
                }
            } elseif ($reportedName -ieq $TargetName) {
                return [PSCustomObject]@{
                    Node      = $TargetName
                    IP        = $IP
                    Result    = "OK"
                    FinalName = $reportedName
                    Detail    = "Renamed from '$currentName'"
                }
            } else {
                return [PSCustomObject]@{
                    Node      = $TargetName
                    IP        = $IP
                    Result    = "Error"
                    FinalName = $reportedName
                    Detail    = "Expected '$TargetName', got '$reportedName'"
                }
            }
        } catch {
            return [PSCustomObject]@{
                Node      = $TargetName
                IP        = $IP
                Result    = "Error"
                FinalName = "Unknown"
                Detail    = $_.ToString()
            }
        }
    }
}

# Wait for all jobs and collect results
Write-Log "All jobs started — waiting for completion (up to ${ReconnectTimeoutSec}s)..."
$jobs | Wait-Job -Timeout ($ReconnectTimeoutSec + 60) | Out-Null

foreach ($job in $jobs) {
    $r = Receive-Job -Job $job -ErrorAction SilentlyContinue
    $jobWarnings = @($job.ChildJobs | ForEach-Object { $_.Warning })

    if ($job.State -eq 'Failed' -or $null -eq $r) {
        $errMsg = if ($job.ChildJobs[0].JobStateInfo.Reason) { $job.ChildJobs[0].JobStateInfo.Reason.Message } else { "Job failed" }
        $results += [PSCustomObject]@{
            Node      = $job.Name
            IP        = ""
            Result    = "Error"
            FinalName = "Unknown"
            Detail    = $errMsg
        }
        Write-Log "[$($job.Name)] FAIL — $errMsg" ERROR
    } else {
        $results += $r
        $color = if ($r.Result -in @("OK","AlreadyConfigured")) { "SUCCESS" } else { "ERROR" }
        Write-Log "[$($r.Node)] $($r.Result) — $($r.Detail)" $color
    }

    foreach ($w in $jobWarnings) { Write-Log "[$($job.Name)] WARN: $w" WARN }
    Remove-Job -Job $job -Force
}

#endregion MAIN

Write-Log ""
Write-Log "=== Summary ===" "HEADER"
$results | Format-Table Node, IP, Result, FinalName, Detail -AutoSize

$failCount = @($results | Where-Object { $_.Result -notin @("OK", "AlreadyConfigured") }).Count
if ($failCount -eq 0) {
    Write-Log "All $($results.Count) node(s) completed successfully." "SUCCESS"
} else {
    Write-Log "$failCount node(s) had errors. Review output above." "ERROR"
    exit 1
}