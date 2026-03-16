#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-ClearStorage-Orchestrated.ps1
    Runs Clear-StorageConfiguration on each node via PSRemoting from the management server.

.PARAMETER ConfigPath
    Path to infrastructure.yml.

.PARAMETER Credential
    PSCredential for PSRemoting. If omitted, resolved from Key Vault.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\Invoke-ClearStorage-Orchestrated.ps1 -ConfigPath .\configs\infrastructure-azl-lab.yml -Force

.NOTES
    Author:  Azure Local Cloud AzureLocalCloud
    Phase:   03-os-configuration
    Task:    11 - Clear Previous Storage Configuration (Conditional)
    WARNING: DESTRUCTIVE. Wipes all non-boot disks on every node.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [PSCredential]$Credential,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-Config {
    param([string]$Path)
    if ($Path -eq "" -or -not (Test-Path $Path)) {
        foreach ($c in @(
            (Join-Path $PSScriptRoot "..\..\..\..\configs\infrastructure.yml"),
            (Join-Path $PSScriptRoot "..\..\..\..\..\configs\infrastructure.yml")
        )) { if (Test-Path $c) { $Path = (Resolve-Path $c).Path; break } }
    } else {
        $Path = (Resolve-Path $Path).Path
    }
    if (-not (Test-Path $Path)) { throw "infrastructure.yml not found. Use -ConfigPath." }
    Import-Module powershell-yaml -ErrorAction Stop
    $cfg = Get-Content $Path -Raw | ConvertFrom-Yaml
    $nodes = $cfg.compute.cluster_nodes.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{ hostname = $_.Key; ip = $_.Value.management_ip }
    }
    return [PSCustomObject]@{
        Nodes        = @($nodes)
        AdminUser    = $cfg.identity.accounts.account_local_admin_username
        AdminPassUri = $cfg.identity.accounts.account_local_admin_password
    }
}

function Resolve-KvSecret {
    param([string]$Uri)
    if ($Uri -notmatch '^keyvault://([^/]+)/(.+)$') { return $null }
    $vault = $Matches[1]; $secret = $Matches[2]
    Write-Log "  Fetching '$secret' from Key Vault '$vault'..."
    try {
        $s = Get-AzKeyVaultSecret -VaultName $vault -Name $secret -AsPlainText -ErrorAction Stop
        if ($s) { return $s }
    } catch {}
    try {
        $s = & az keyvault secret show --vault-name $vault --name $secret --query value -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $s) { return ($s | Out-String).Trim() }
    } catch {}
    return $null
}

# ── scriptblock that runs ON each node ──────────────────────────────────────

$NodeScript = {
    Update-StorageProviderCache -ErrorAction SilentlyContinue
    Get-StoragePool | Where-Object IsPrimordial -eq $false |
        Set-StoragePool -IsReadOnly:$false -ErrorAction SilentlyContinue
    Get-StoragePool | Where-Object IsPrimordial -eq $false |
        Get-VirtualDisk |
        Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
    Get-StoragePool | Where-Object IsPrimordial -eq $false |
        Remove-StoragePool -Confirm:$false -ErrorAction SilentlyContinue
    Get-PhysicalDisk | Reset-PhysicalDisk -ErrorAction SilentlyContinue
    Get-Disk | Where-Object Number -ne $null |
               Where-Object IsBoot -ne $true |
               Where-Object IsSystem -ne $true |
               Where-Object PartitionStyle -ne RAW |
               Where-Object BusType -ne USB | ForEach-Object {
        $_ | Set-Disk -IsOffline:$false  -ErrorAction SilentlyContinue
        $_ | Set-Disk -IsReadOnly:$false -ErrorAction SilentlyContinue
        $_ | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
        $_ | Set-Disk -IsReadOnly:$true  -ErrorAction SilentlyContinue
        $_ | Set-Disk -IsOffline:$true   -ErrorAction SilentlyContinue
    }
    $raw = Get-Disk | Where-Object Number -ne $null |
                      Where-Object IsBoot -ne $true |
                      Where-Object IsSystem -ne $true |
                      Where-Object PartitionStyle -eq RAW |
                      Group-Object -NoElement -Property FriendlyName |
                      Select-Object -ExpandProperty Name
    "DONE. RAW disks remaining: $(if ($raw) { $raw -join ', ' } else { 'none' })"
}

# ── main ─────────────────────────────────────────────────────────────────────

Write-Log "=== Task 11 - Clear Previous Storage Configuration ===" HEADER
Write-Log "WARNING: Wipes all non-boot disks on all nodes." WARN

$cfg = Get-Config -Path $ConfigPath
Write-Log "Nodes: $($cfg.Nodes.Count)"
$cfg.Nodes | ForEach-Object { Write-Log "  $($_.hostname)  ($($_.ip))" }

if (-not $Force) {
    Write-Host ""
    Write-Host "DESTRUCTIVE: All non-boot disk data will be erased." -ForegroundColor Red
    Write-Host -NoNewline "Type YES to continue: "
    if ((Read-Host) -ne "YES") { Write-Log "Cancelled." WARN; exit 0 }
}

if (-not $Credential) {
    $pass = Resolve-KvSecret -Uri $cfg.AdminPassUri
    if ($pass) {
        $Credential = New-Object PSCredential(
            $cfg.AdminUser.Trim(),
            (ConvertTo-SecureString $pass -AsPlainText -Force)
        )
        Write-Log "Credential resolved for '$($cfg.AdminUser.Trim())'." SUCCESS
    } else {
        Write-Log "Key Vault unavailable - prompting." WARN
        $Credential = Get-Credential -Message "Local admin on nodes" -UserName $cfg.AdminUser.Trim()
    }
}

$results = @()
foreach ($node in $cfg.Nodes) {
    Write-Log "[$($node.hostname)] Connecting to $($node.ip)..." HEADER
    try {
        $out = Invoke-Command -ComputerName $node.ip -Credential $Credential -ScriptBlock $NodeScript
        Write-Log "[$($node.hostname)] $out" SUCCESS
        $results += [PSCustomObject]@{ Node = $node.hostname; Status = "OK"; Detail = $out }
    } catch {
        Write-Log "[$($node.hostname)] FAILED: $_" ERROR
        $results += [PSCustomObject]@{ Node = $node.hostname; Status = "FAIL"; Detail = $_.ToString() }
    }
}

Write-Log "=== Summary ===" HEADER
$results | Format-Table -AutoSize

$failed = @($results | Where-Object Status -ne "OK")
if ($failed.Count -gt 0) {
    Write-Log "$($failed.Count) node(s) failed." ERROR
    exit 1
}
Write-Log "All nodes completed." SUCCESS
