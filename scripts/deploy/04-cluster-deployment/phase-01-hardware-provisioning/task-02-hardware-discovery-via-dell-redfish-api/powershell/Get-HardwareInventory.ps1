<#
.SYNOPSIS
    Reads the hardware of every node from its baseboard management controller (BMC) over the standard Redfish API and writes one inventory file.

.DESCRIPTION
    Phase 01 (hardware provisioning), Task 02 (hardware discovery). It runs before the operating system is installed. For every node of
    nodes[] that has a BMC address, the script reads the BMC (read only) and writes one inventory file for the whole run.

    The same script works for Dell, DataON, Lenovo, HPE and any other BMC that offers the DMTF Redfish standard. It reads standard
    resources only: Systems, Processors, Memory, Storage and Drives, NetworkAdapters and Ports, Chassis, Managers, UpdateService
    FirmwareInventory, TrustedModules (and TrustedComponents). It does not use a vendor (OEM) extension for any field. A fact that a
    vendor shows only under an OEM path is written as "not reported". See docs/hardware-discovery.md.

    Per node the file holds: manufacturer, model, serial number, SKU; processors (sockets, cores, threads, model); memory (total, ECC,
    modules); every drive with media type (NVMe, SSD, HDD), size, firmware and role (cache or capacity); the network adapters with
    their ports, MAC addresses, port order and link speed; GPUs; TPM and Secure Boot; BIOS version; BMC model and firmware version; the
    firmware inventory; and the list of fields the BMC did not report. Across the nodes it holds the symmetry checks (same model,
    processors, adapters and drives, as Microsoft requires) and, for each hardware key that infrastructure.yml sets, what the plan says
    against what the BMC reported. The drive role rule is written into the file.

    Read only. The script sends GET requests only. It never changes a BMC, a node, a cluster or Azure. A BMC that cannot be read is
    recorded as failed in the file, and the other nodes are still read.

    The BMC login is a secret reference (hardware.bmc, or the node's own bmc block), resolved by the toolkit secret resolver
    (scripts/common/secrets/AzlSecret.psm1). The password is never asked for, written or logged. The file holds serial numbers and MAC
    addresses: keep the output folder out of git.

    -WhatIf lists the nodes and the file it would write, and contacts no BMC.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure):
        nodes[]: name, bmc.ip_address, bmc.type, bmc.username, bmc.password, serial_number
        hardware.bmc: username, password, verify_certificate
        hardware.inventory: output_directory, file_name_prefix, format, timeout_seconds
        hardware.vendor, hardware.model, hardware.cpu_cores, hardware.memory_gib, hardware.gpu (enabled, model, count_per_node),
        hardware.drives (capacity and cache: media, count, size_tb): compared with what the BMC reports
        secrets, key_vaults: read by the secret resolver for the references above

    Exit codes: 0 the inventory was written and every node was read (or planned under -WhatIf); 1 a precondition failed, a secret could
    not be read, or at least one BMC could not be read (the file is still written); 2 a value in the file is missing or not usable
    (nothing was sent to any BMC).

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Only the keys above are read; the whole file is not validated here.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Get-HardwareInventory.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Shows which nodes would be read and which file would be written. Nothing is contacted.

.EXAMPLE
    ./Get-HardwareInventory.ps1 -InfrastructureFile ./infrastructure.yml

    Reads every BMC and writes hardware-inventory-<time>.json (or .yml) in hardware.inventory.output_directory.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([IO.Path]::Combine($common, 'secrets', 'AzlSecret.psm1'))
Import-Module ([IO.Path]::Combine($common, 'redfish', 'AzlRedfishCore.psm1'))
Import-Module ([IO.Path]::Combine($common, 'redfish', 'AzlRedfishInventory.psm1'))

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Value([string]$Path) { Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path }
function Get-Text([string]$Path) { $v = Get-Value $Path; if ($null -eq $v) { '' } else { ([string]$v).Trim() } }

# ---- the values, from infrastructure.yml only
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$outputDirectory = Get-Text 'hardware.inventory.output_directory'
if (-not $outputDirectory) { $outputDirectory = 'hardware-inventory' }
$prefix = Get-Text 'hardware.inventory.file_name_prefix'
if (-not $prefix) { $prefix = 'hardware-inventory' }
$format = (Get-Text 'hardware.inventory.format').ToLowerInvariant()
if (-not $format) { $format = 'json' }
$timeoutText = Get-Text 'hardware.inventory.timeout_seconds'
$timeoutSeconds = 60
if ($timeoutText) {
    if ($timeoutText -notmatch '^\d{1,3}$' -or [int]$timeoutText -lt 5 -or [int]$timeoutText -gt 600) { Exit-InputProblem "hardware.inventory.timeout_seconds '$timeoutText' is not a whole number from 5 to 600." }
    $timeoutSeconds = [int]$timeoutText
}
if ($format -notin 'json', 'yaml') { Exit-InputProblem "hardware.inventory.format must be json or yaml; found '$format'." }
if ($prefix -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { Exit-InputProblem "hardware.inventory.file_name_prefix '$prefix' is not usable: 1 to 64 letters, digits, dot, underscore or hyphen, starting with a letter or digit." }
$verifyValue = Get-Value 'hardware.bmc.verify_certificate'
$verifyCertificate = ($null -ne $verifyValue -and ([string]$verifyValue).Trim().ToLowerInvariant() -in 'true', '1', 'yes')

$sharedBmc = Get-Value 'hardware.bmc'
$nodeList = Get-Value 'nodes'
$nodeEntries = @(@($nodeList) | Where-Object { $_ -is [System.Collections.IDictionary] })
if ($nodeEntries.Count -eq 0) { Exit-InputProblem 'The file lists no nodes. Add nodes[] with name and bmc.ip_address.' }

$plans = [System.Collections.Generic.List[object]]::new()
$seenNames = @{}
$index = -1
foreach ($entry in $nodeEntries) {
    $index++
    $at = "nodes[$index]"
    $name = if ($entry.Contains('name')) { ([string]$entry['name']).Trim() } else { '' }
    if (-not $name) { Exit-InputProblem "$at.name is missing." }
    if ($seenNames.ContainsKey($name.ToLowerInvariant())) { Exit-InputProblem "$at.name '$name' is listed twice." }
    $seenNames[$name.ToLowerInvariant()] = $true
    $bmc = if ($entry.Contains('bmc')) { $entry['bmc'] } else { $null }
    $address = if ($bmc -is [System.Collections.IDictionary] -and $bmc.Contains('ip_address')) { ([string]$bmc['ip_address']).Trim() } else { '' }
    if (-not $address) { Write-Line "[skip]    $name has no bmc.ip_address: not read."; $plans.Add([pscustomobject]@{ Name = $name; Address = ''; Entry = $entry; LoginBlock = $null; LoginFrom = ''; Skipped = $true }); continue }
    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($address, [ref]$parsedAddress) -or $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or $address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        Exit-InputProblem "$at.bmc.ip_address '$address' is not an IPv4 address."
    }
    $loginBlock = $null
    $loginFrom = ''
    if ($bmc -is [System.Collections.IDictionary] -and $bmc.Contains('username') -and $bmc.Contains('password')) { $loginBlock = $bmc; $loginFrom = "$at.bmc" }
    elseif ($sharedBmc -is [System.Collections.IDictionary] -and $sharedBmc.Contains('username') -and $sharedBmc.Contains('password')) { $loginBlock = $sharedBmc; $loginFrom = 'hardware.bmc' }
    if (-not $loginBlock) { Exit-InputProblem "Node '$name' has no BMC login: set $at.bmc.username and password, or hardware.bmc." }
    $reference = ([string]$loginBlock['password']).Trim()
    if (-not (Get-AzlSecretProvider $reference)) {
        Exit-InputProblem "The BMC password in $loginFrom is not a secret reference ($($reference.Length) characters). Use keyvault://<vault>/<secret>, env://<VARIABLE>, file://<name> or command://<name>. A password must never be written in the file."
    }
    $plans.Add([pscustomobject]@{ Name = $name; Address = $address; Entry = $entry; LoginBlock = $loginBlock; LoginFrom = $loginFrom; Skipped = $false })
}
$toRead = @($plans | Where-Object { -not $_.Skipped })
if ($toRead.Count -eq 0) { Exit-InputProblem 'No node has bmc.ip_address, so there is nothing to read.' }

$stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$extension = if ($format -eq 'yaml') { 'yml' } else { 'json' }
$outputFile = [IO.Path]::Combine($outputDirectory, "$prefix-$stamp.$extension")

# ---- -WhatIf: the plan, no BMC is contacted
if (-not $PSCmdlet.ShouldProcess($outputFile, "Read $($toRead.Count) BMC(s) over Redfish (read only) and write the hardware inventory")) {
    foreach ($p in $plans) {
        $row = [ordered]@{ Node = $p.Name; BmcAddress = $p.Address; Result = $(if ($p.Skipped) { 'Skipped' } else { 'WouldRead' }); Detail = $(if ($p.Skipped) { 'No bmc.ip_address.' } else { "Login from $($p.LoginFrom)." }) }
        [pscustomobject]$row
    }
    Write-Line "The inventory would be written to $outputFile ($format)."
    exit 0
}

# ---- preconditions
if ($format -eq 'yaml' -and -not (Get-Command -Name ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
    try { Import-Module powershell-yaml -ErrorAction Stop } catch { Exit-Failed 'hardware.inventory.format is yaml, and the powershell-yaml module is not installed. Install-Module powershell-yaml -Scope CurrentUser.' }
}

# ---- the BMC logins (secret references resolved by the toolkit resolver)
$credentials = @{}
foreach ($p in $toRead) {
    if ($credentials.ContainsKey($p.LoginFrom)) { continue }
    try {
        $user = ([string]$p.LoginBlock['username']).Trim()
        if (Get-AzlSecretProvider $user) { $user = Get-AzlSecretPlainText -Reference $user -Infrastructure $infra }
        if (-not $user) { Exit-InputProblem "The BMC user name in $($p.LoginFrom) is empty." }
        $secure = Get-AzlSecretValue -Reference ([string]$p.LoginBlock['password']) -Infrastructure $infra
        $credentials[$p.LoginFrom] = [pscredential]::new($user, $secure)
    }
    catch {
        $code = if ($_.Exception.Data.Contains('AzlExit')) { [int]$_.Exception.Data['AzlExit'] } else { 1 }
        if ($code -eq 2) { Exit-InputProblem "The BMC login in $($p.LoginFrom) cannot be used: $($_.Exception.Message)" }
        Exit-Failed "The BMC login in $($p.LoginFrom) could not be read: $($_.Exception.Message)"
    }
}

# ---- read the BMCs, one after another (a BMC is a small computer: no parallel load)
Write-Line "Reading $($toRead.Count) BMC(s) over Redfish, read only (certificate check: $(if ($verifyCertificate) { 'on' } else { 'off' }), timeout $timeoutSeconds s)."
$started = [datetime]::UtcNow
$nodes = [System.Collections.Generic.List[object]]::new()
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($p in $plans) {
    if ($p.Skipped) { $rows.Add([pscustomobject][ordered]@{ Node = $p.Name; BmcAddress = ''; Result = 'Skipped'; Model = ''; Serial = ''; Detail = 'No bmc.ip_address.' }); continue }
    try {
        $report = Invoke-AzlRedfishDiscovery -BmcAddress $p.Address -Credential $credentials[$p.LoginFrom] -Vendor None -Detail Inventory -VerifyCertificate:$verifyCertificate -TimeoutSeconds $timeoutSeconds
        $node = ConvertTo-AzlHardwareInventoryNode -Report $report -Name $p.Name
        $nodes.Add($node)
        $detail = "$($node.cpu.sockets) CPU, $($node.memory.totalGiB) GiB, $(@($node.drives).Count) drive(s), $($node.network.portCount) port(s); $(@($node.notReported).Count) field(s) not reported."
        $rows.Add([pscustomobject][ordered]@{ Node = $p.Name; BmcAddress = $p.Address; Result = 'Read'; Model = "$($node.identity.manufacturer) $($node.identity.model)"; Serial = $node.identity.serialNumber; Detail = $detail })
        Write-Line "[read]    $($p.Name): $detail"
    }
    catch {
        $message = $_.Exception.Message
        $nodes.Add([ordered]@{ name = $p.Name; bmcAddress = $p.Address; status = 'failed'; error = $message })
        $rows.Add([pscustomobject][ordered]@{ Node = $p.Name; BmcAddress = $p.Address; Result = 'Failed'; Model = ''; Serial = ''; Detail = $message })
        Write-Line "[failed]  $($p.Name): $message"
    }
}

# ---- the checks across nodes and against the plan
$readNodes = @($nodes | Where-Object { $_['status'] -eq 'read' })
$symmetry = @(Get-AzlHardwareSymmetry -Node $readNodes)
$comparison = [System.Collections.Generic.List[object]]::new()
foreach ($n in $readNodes) {
    $entry = ($plans | Where-Object { $_.Name -eq $n['name'] } | Select-Object -First 1).Entry
    foreach ($c in @(Compare-AzlHardwarePlan -Node ([pscustomobject]$n) -Infrastructure $infra -NodeEntry $entry)) { $comparison.Add($c) }
}

$inventory = [ordered]@{
    schemaVersion = '1.0'
    kind          = 'hardware-inventory'
    collectedAt   = $started.ToString('yyyy-MM-ddTHH:mm:ssZ')
    source        = [ordered]@{ api = 'DMTF Redfish (standard resources only)'; readOnly = $true; certificateCheck = $verifyCertificate; timeoutSeconds = $timeoutSeconds; nodesRequested = $toRead.Count; nodesRead = $readNodes.Count }
    rules         = Get-AzlHardwareInventoryRule
    nodes         = $nodes.ToArray()
    symmetry      = $symmetry
    planComparison = $comparison.ToArray()
}

# ---- write the one file of this run
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$suffix = 1
while (Test-Path -LiteralPath $outputFile) { $suffix++; $outputFile = [IO.Path]::Combine($outputDirectory, "$prefix-$stamp-$suffix.$extension") }
$json = $inventory | ConvertTo-Json -Depth 30
if ($format -eq 'yaml') { $content = ($json | ConvertFrom-Json -Depth 30 | ConvertTo-Yaml) } else { $content = $json }
Set-Content -LiteralPath $outputFile -Value $content -Encoding utf8 -WhatIf:$false
Write-Line "Inventory written: $outputFile (keep it out of git: it holds serial numbers and MAC addresses)."
$differs = @($comparison | Where-Object { $_['result'] -eq 'differs' }).Count
$symmetryDiffers = @($symmetry | Where-Object { $_['result'] -eq 'differs' -and $_['requirement'] -eq 'required' }).Count
Write-Line "Plan against found: $differs key(s) differ. Symmetry: $symmetryDiffers required check(s) differ."

$rows
if (@($rows | Where-Object Result -EQ 'Failed').Count -gt 0) { exit 1 }
exit 0
