#Requires -Version 7.0
<#
.SYNOPSIS
    Invoke-DisableDHCP-Orchestrated.ps1
    Disables DHCP on all physical adapters on every Azure Local node using PSRemoting.

.DESCRIPTION
    Runs from the management server. Reads node management IPs from infrastructure.yml,
    connects to each node over PSRemoting, and runs the DHCP-disable logic remotely.

    No session loss expected: disabling DHCP on non-management adapters, and the
    management NIC already has a static IP from Task 03 — this operation does not
    change the management IP.

    Adapter exclusion pattern applied on each node:
      NDIS | Hyper-V Virtual | WAN Miniport | Bluetooth | Wi-Fi Direct |
      Microsoft Kernel Debug | Multiplexor

.NOTES
    Author:       Azure Local Cloud AzureLocalCloud
    Version:      1.0.0
    Phase:        03-os-configuration
    Task:         task-04-disable-dhcp-on-management-adapter
    Execution:    Run from management server (PSRemoting outbound to nodes)
    Prerequisites: PowerShell 7+, WinRM enabled on all nodes, admin credentials
    Run after:    Task 03 — static IP configured on management NIC of all nodes

.EXAMPLE
    .\Invoke-DisableDHCP-Orchestrated.ps1
    .\Invoke-DisableDHCP-Orchestrated.ps1 -ConfigPath "C:\configs\infrastructure.yml"
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force

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
        "SKIP"    { "DarkGray" }
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

    # Search common locations
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

    $current  = $Lines
    $indent   = -1
    $inBlock  = $false
    $blockLines = @()

    foreach ($key in $KeyPath) {
        $pattern = "^\s*${key}\s*:"
        $lineIdx  = -1
        for ($i = 0; $i -lt $current.Count; $i++) {
            if ($current[$i] -match $pattern) {
                $lineIdx = $i
                break
            }
        }
        if ($lineIdx -eq -1) { return $null }

        # Inline value?
        if ($current[$lineIdx] -match "^\s*${key}\s*:\s*(.+)$") {
            $val = $Matches[1].Trim().Trim('"').Trim("'")
            if ($KeyPath[-1] -eq $key) { return $val }
            # Descend into next key path — value was inline, no block to descend into
            return $null
        }

        # Block — collect indented children
        $keyIndent = ($current[$lineIdx] -replace "^(\s*).*", '$1').Length
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
    param([string]$ExcludePattern)

    Set-StrictMode -Version Latest
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $adapters = Get-NetAdapter | Sort-Object Name

    foreach ($adapter in $adapters) {
        $desc = $adapter.InterfaceDescription
        $name = $adapter.Name

        if ($desc -match $ExcludePattern) {
            $results.Add([PSCustomObject]@{
                Name   = $name
                Desc   = $desc
                Result = "Skipped"
                DHCP   = "Excluded"
            })
            continue
        }

        $ipIface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $ipIface) {
            $results.Add([PSCustomObject]@{
                Name   = $name
                Desc   = $desc
                Result = "Skipped"
                DHCP   = "No IPv4"
            })
            continue
        }

        if ($ipIface.Dhcp -eq "Disabled") {
            $results.Add([PSCustomObject]@{
                Name   = $name
                Desc   = $desc
                Result = "AlreadyDisabled"
                DHCP   = "Disabled"
            })
            continue
        }

        try {
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            $after = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
            $results.Add([PSCustomObject]@{
                Name   = $name
                Desc   = $desc
                Result = if ($after -eq "Disabled") { "Changed" } else { "Failed" }
                DHCP   = $after
            })
        } catch {
            $results.Add([PSCustomObject]@{
                Name   = $name
                Desc   = $desc
                Result = "Error"
                DHCP   = "Error: $_"
            })
        }
    }

    return $results
}

# ============================================================================
#  MAIN
# ============================================================================

try {
    Write-Log "=== Invoke-DisableDHCP-Orchestrated.ps1 ===" "HEADER"

    Import-Module powershell-yaml -ErrorAction Stop

    $resolvedConfig = Resolve-ConfigPath -Provided $ConfigPath
    Write-Log "Loading node configurations from: $resolvedConfig"

    $config = Get-Content $resolvedConfig -Raw | ConvertFrom-Yaml

    $nodes = Get-AzlInfrastructureNode -Infrastructure $config | ForEach-Object {
        [PSCustomObject]@{
            NodeName = $_.Name
            IP       = $_.ManagementIp
        }
    }

    if (-not $nodes) { throw "No nodes found under nodes in $resolvedConfig" }
    Write-Log "Nodes to process: $($nodes.Count)"

    $excludePattern = "NDIS|Hyper-V Virtual|WAN Miniport|Bluetooth|Wi-Fi Direct|Microsoft Kernel Debug|Multiplexor"

    $adminUser    = $config.identity.local_admin.username
    $adminPassUri = $config.identity.local_admin.password
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

    foreach ($node in $nodes) {
        Write-Log "--- $($node.NodeName) ($($node.IP)) ---" "HEADER"

        try {
            $session = New-PSSession -ComputerName $node.IP -Credential $credential -ErrorAction Stop
            Write-Log "  Connected to $($node.IP)"

            $remoteResults = Invoke-Command -Session $session -ScriptBlock $RemoteScriptBlock -ArgumentList $excludePattern

            $failed  = @($remoteResults | Where-Object { $_.Result -notin @("Changed","AlreadyDisabled","Skipped") })
            $changed = @($remoteResults | Where-Object { $_.Result -eq "Changed" }).Count
            $already = @($remoteResults | Where-Object { $_.Result -eq "AlreadyDisabled" }).Count
            $skipped = @($remoteResults | Where-Object { $_.Result -eq "Skipped" }).Count

            $remoteResults | Format-Table -AutoSize | Out-String | Write-Host

            if ($failed.Count -gt 0) {
                Write-Log "  $($node.NodeName): $($failed.Count) adapter(s) FAILED" "WARN"
            } else {
                Write-Log "  $($node.NodeName): Changed=$changed  AlreadyDisabled=$already  Skipped=$skipped" "SUCCESS"
            }

            $nodeResults += [PSCustomObject]@{
                Node    = $node.NodeName
                IP      = $node.IP
                Status  = if ($failed.Count -gt 0) { "Partial" } else { "OK" }
                Changed = $changed
                Already = $already
                Skipped = $skipped
                Errors  = $failed.Count
            }

            Remove-PSSession -Session $session -ErrorAction SilentlyContinue

        } catch {
            Write-Log "  ERROR connecting to $($node.NodeName) ($($node.IP)): $_" "ERROR"
            $nodeResults += [PSCustomObject]@{
                Node    = $node.NodeName
                IP      = $node.IP
                Status  = "ConnectionFailed"
                Changed = 0
                Already = 0
                Skipped = 0
                Errors  = 1
            }
        }
    }

    Write-Log "=== ORCHESTRATION SUMMARY ===" "HEADER"
    $nodeResults | Format-Table -AutoSize | Out-String | Write-Host

    $anyFailed = @($nodeResults | Where-Object { $_.Status -notin @("OK") })
    if ($anyFailed.Count -gt 0) {
        Write-Log "$($anyFailed.Count) node(s) had issues. Review above." "WARN"
        exit 1
    }

    Write-Log "All nodes: DHCP disable complete." "SUCCESS"
    exit 0

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
