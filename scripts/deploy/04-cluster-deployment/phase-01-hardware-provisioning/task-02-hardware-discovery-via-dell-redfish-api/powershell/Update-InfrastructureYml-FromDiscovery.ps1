#Requires -Version 7.0
<#
.SYNOPSIS
    Writes what hardware discovery found (serial numbers, MACs, BMC MACs and the hardware facts the automation needs) into
    infrastructure.yml.

.DESCRIPTION
    Reads the discovery output and shows what would change in infrastructure.yml. Two kinds of input are read, from one
    folder or one file:

      Invoke-HardwareDiscovery.ps1   one <ServiceTag>.json per node (schemaVersion 2.0; the older 1.0 files are still read)
      Get-HardwareInventory.ps1      hardware-inventory-<time>.json or .yml (kind hardware-inventory, any maker); when the
                                     folder holds several, the newest is read

    A node that has both is written from its Invoke-HardwareDiscovery file; the inventory still gives the hardware.* keys.

    Per node (owner decision O7: a discovered fact the automation needs is a key):
      nodes[].serial_number                     the service tag (the inventory: the system serial number)
      nodes[].bmc.mac_address                   the MAC of the BMC port (the DHCP reservation of the BMC address)
      nodes[].bmc.type                          from an inventory, when the file has none
      nodes[].network_adapters[].mac_address    for the entry paired with a discovered port: by MAC, then by the same name,
                                                then by slot and port_index, then as the only free port of its slot
      nodes[].network_adapters[]: port_index, vendor, model, pci_location (and speed_gbps, rdma and slot when missing)
      nodes[].management.mac_address            for a node described with management only, when the management port is
                                                confirmed (-ManagementPort, or the MAC already in the file); a management MAC
                                                that is on no port of the machine is replaced only with -ManagementPort
    From an inventory, when every node agrees: hardware.vendor (when missing), model, cpu_cores, memory_gib, the drives
    (media, count, size_tb, model of the capacity and the cache drives), hardware.boot_drives and hardware.gpu.

    Evidence, never written: firmware, BIOS and BMC versions, the TPM and Secure Boot state, and the serial number, firmware
    and bay of each drive. They stay in the discovery files and the inventory.

    Nothing is written without -Apply. The preview places every change on a copy in memory and lists any it cannot place.
    With -Apply it saves a backup (<file>.bak.<time>), asks for confirmation (unless -Force) and edits only those lines:
    comments, order and quoting stay, and a flow-style entry ({ name: ..., mac_address: ... }) is edited inside its braces. A
    key that is not in the file is inserted under its existing parent (the hardware.* parents are created when missing); a
    missing node or list entry is never created. Roles, IP assignment and addresses are never written: discovery cannot read
    them from hardware.

    Ports the file does not list are notes. They are in the proposal file infrastructure.discovered.yml of the discovery
    folder: Invoke-HardwareDiscovery.ps1 writes it, and this script writes it from the input when the folder has none.

    Exit codes: 0 every value is placed and every MAC in the file is on its machine; 1 at least one value cannot be placed
    (the key or its parent is not in the file), or an entry keeps a MAC that is on no port of its machine (a placeholder), or a
    wrong management MAC needs -ManagementPort (the values that can be placed are still written with -Apply); 2 the file
    cannot be read, or the discovery folder holds no discovery file.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5). Required. The file is edited in place when -Apply is given.

.PARAMETER DiscoveryPath
    The discovery folder, or one discovery or inventory file. Default: hardware.discovery.output_directory, else
    <provisioning.simplified.evidence_path>\discovery, else (simplified provisioning) %ProgramData%\AzureLocalZtp\<site_name>\
    evidence\discovery, else .\discovery (Resolve-AzlDiscoveryDirectory; the folder Invoke-HardwareDiscovery.ps1 writes to and
    Sonar reads).

.PARAMETER ManagementPort
    The management port by suggested name or MAC (see Invoke-HardwareDiscovery.ps1).

.PARAMETER Apply
    Write the changes. Without it this is a preview.

.PARAMETER Force
    With -Apply: no confirmation prompt.

.EXAMPLE
    .\Update-InfrastructureYml-FromDiscovery.ps1 -InfrastructureFile .\infrastructure.yml

.EXAMPLE
    .\Update-InfrastructureYml-FromDiscovery.ps1 -InfrastructureFile .\infrastructure.yml -ManagementPort 'Slot 3 Port 1' -Apply

.EXAMPLE
    .\Update-InfrastructureYml-FromDiscovery.ps1 -InfrastructureFile .\infrastructure.yml -DiscoveryPath .\hardware-inventory -Apply -Force

.NOTES
    Phase: 04-cluster-deployment / phase-01-hardware-provisioning / task-02-hardware-discovery-via-dell-redfish-api
    Requires PowerShell 7 and the powershell-yaml module.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$DiscoveryPath,
    [string]$ManagementPort,
    [switch]$Apply,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Get-ToolkitRoot {
    $dir = $PSScriptRoot
    while ($dir) {
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, 'scripts', 'common', 'infrastructure', 'AzlInfrastructureEdit.psm1'))) { return $dir }
        $dir = Split-Path -Parent $dir
    }
    throw "The toolkit root was not found above $PSScriptRoot."
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }

$root = Get-ToolkitRoot
Import-Module powershell-yaml
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1'))
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'idrac-management', 'AzlDellRedfish.psm1'))
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'infrastructure', 'AzlInfrastructureEdit.psm1'))

$resolved = $InfrastructureFile
try { $infrastructure = Import-AzlInfrastructure -Path $resolved -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

if (-not $DiscoveryPath) { $DiscoveryPath = Resolve-AzlDiscoveryDirectory -Infrastructure $infrastructure -InfrastructureFile $resolved }
$folder = if (Test-Path -LiteralPath $DiscoveryPath -PathType Leaf) { Split-Path -Parent ([IO.Path]::GetFullPath($DiscoveryPath)) } else { $DiscoveryPath }
$candidates = @(if (Test-Path -LiteralPath $DiscoveryPath -PathType Leaf) { @(Get-Item -LiteralPath $DiscoveryPath) }
else { @(Get-ChildItem -LiteralPath $DiscoveryPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.json', '.yml', '.yaml' -and $_.Name -notin @('discovery-summary.json', 'idrac-inventory.json', 'infrastructure.discovered.yml') }) })

# Read every candidate; classify it as a node file of Invoke-HardwareDiscovery.ps1 or an inventory of Get-HardwareInventory.ps1.
$nodeItems = [ordered]@{}
$inventories = [System.Collections.Generic.List[object]]::new()
foreach ($f in $candidates) {
    try {
        $d = Read-AzlDiscoveryFile -Path $f.FullName
    }
    catch { Write-Warning "$($f.Name) cannot be read ($($_.Exception.Message)): skipped."; continue }
    if ($null -eq $d) { continue }
    if ([string](Get-RfProp $d 'kind') -eq 'hardware-inventory' -and $null -ne (Get-RfProp $d 'nodes')) {
        $inventories.Add([pscustomobject]@{ File = $f; Report = $d; CollectedAt = [string](Get-RfProp $d 'collectedAt' '') })
        continue
    }
    if ((Get-RfProp $d 'schemaVersion') -and (Get-RfProp $d 'nodeName') -and (Get-RfProp $d 'identity')) {
        # schema 2.0: the flat view of the report is what the infrastructure.yml edit reads
        $view = ConvertTo-AzlDiscoveryLegacyView -Report $d
        $view['NodeName'] = [string]$d.nodeName
        $nodeItems[[string]$d.nodeName] = [pscustomobject]@{ NodeName = [string]$d.nodeName; Discovery = [pscustomobject]$view; ManagementPort = $ManagementPort; Source = $f.Name }
        continue
    }
    if ((Get-RfProp $d 'NodeName') -and (Get-RfProp $d 'Identity')) {
        $nodeItems[[string]$d.NodeName] = [pscustomobject]@{ NodeName = [string]$d.NodeName; Discovery = $d; ManagementPort = $ManagementPort; Source = $f.Name }
        continue
    }
    if ($f.Extension -eq '.json') { Write-Warning "$($f.Name) is not a file of Invoke-HardwareDiscovery.ps1 or Get-HardwareInventory.ps1: skipped." }
}

$inventoryViews = @()
if ($inventories.Count -gt 0) {
    $newest = @($inventories | Sort-Object -Property @{ Expression = { $_.CollectedAt } }, @{ Expression = { $_.File.LastWriteTimeUtc } } -Descending)[0]
    foreach ($other in @($inventories | Where-Object { $_ -ne $newest })) { Write-Information "Note: $($other.File.Name) is an older inventory than $($newest.File.Name): not read." }
    foreach ($n in @(Get-RfProp $newest.Report 'nodes' @())) {
        $view = ConvertTo-AzlInventoryDiscoveryView -InventoryNode $n
        if (-not $view) { Write-Warning "$($newest.File.Name): node '$(Get-RfProp $n 'name')' was not read by the inventory ($(Get-RfProp $n 'error')): skipped."; continue }
        $inventoryViews += , $view
        if (-not $nodeItems.Contains($view.NodeName)) {
            $nodeItems[$view.NodeName] = [pscustomobject]@{ NodeName = $view.NodeName; Discovery = [pscustomobject]$view; ManagementPort = $ManagementPort; Source = $newest.File.Name }
        }
    }
}
if ($nodeItems.Count -eq 0) {
    Exit-InputProblem "No usable discovery file in '$DiscoveryPath': it needs the <ServiceTag>.json files of Invoke-HardwareDiscovery.ps1 or a hardware-inventory file of Get-HardwareInventory.ps1 ($($candidates.Count) candidate file(s) found). Run one of them first, or pass -DiscoveryPath."
}
Write-Information "Discovery: $DiscoveryPath ($($nodeItems.Count) node(s)$(if ($inventoryViews.Count -gt 0) { ', with a hardware inventory' }))."

$plan = Get-AzlDiscoveryChange -Infrastructure $infrastructure -Item @($nodeItems.Values)
$hardwarePlan = Get-AzlHardwareFactChange -Infrastructure $infrastructure -View @($inventoryViews)
$changes = @(@($plan.Changes) + @($hardwarePlan.Changes))
$problems = [System.Collections.Generic.List[string]]::new()
foreach ($p in @($plan.Problems)) { $problems.Add($p) }
foreach ($n in @(@($plan.Notes) + @($hardwarePlan.Notes))) { Write-Information "Note: $n" }

# The proposal file lists the ports the file does not have. Name it, or write it when the discovery folder has none.
if (@($plan.Notes | Where-Object { $_ -like '*is not in network_adapters*' }).Count -gt 0) {
    $proposal = Join-Path $folder 'infrastructure.discovered.yml'
    if (-not (Test-Path -LiteralPath $proposal -PathType Leaf)) {
        $existingMac = { param($name) $node = @($infrastructure['nodes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -eq $name } | Select-Object -First 1; if ($node -and $node['management'] -is [System.Collections.IDictionary]) { [string]$node['management']['mac_address'] } else { '' } }
        $text = ConvertTo-AzlDiscoveryProposal -Item @($nodeItems.Values | ForEach-Object { [pscustomobject]@{ NodeName = $_.NodeName; Discovery = $_.Discovery; ManagementPort = $ManagementPort; ExistingManagementMac = (& $existingMac $_.NodeName) } })
        Set-Content -LiteralPath $proposal -Value $text -Encoding utf8 -WhatIf:$false
    }
    Write-Information "Proposal (every discovered port, to copy from): $proposal"
}

if ($changes.Count -eq 0 -and $problems.Count -eq 0) { Write-Information "infrastructure.yml already matches the discovery ($resolved)."; return }

$preview = @(Test-AzlYamlEdit -Path $resolved -Change $changes)
$cannot = @($preview | Where-Object { $_.Result -in 'NotFound', 'NotScalar' })
if ($changes.Count -gt 0) {
    Write-Information "Changes to $resolved :"
    for ($k = 0; $k -lt $changes.Count; $k++) {
        $c = $changes[$k]
        $flag = if ($preview[$k].Result -in 'NotFound', 'NotScalar') { "   << cannot be placed ($($preview[$k].Result)): the key or its parent is not in the file" } else { '' }
        Write-Information "  $($c.Display): $(if ($null -ne $c.Old -and "$($c.Old)" -ne '') { $c.Old } else { '(not set)' }) -> $($c.New)$flag"
    }
}
foreach ($c in $cannot) { $problems.Add("$($c.Display) = $($c.New) cannot be placed ($($c.Result)): add the entry or its parent to the file, or copy it from the proposal file.") }

if ($Apply -and $changes.Count -gt 0) {
    if ($Force) { $ConfirmPreference = 'None' }
    if ($PSCmdlet.ShouldProcess($resolved, "Write $($changes.Count) discovered value(s)")) {
        $edit = Invoke-AzlYamlEdit -Path $resolved -Change $changes -Confirm:$false
        foreach ($r in $edit.Results) { Write-Information "  $($r.Result): $($r.Display)" }
        Write-Information "Backup: $($edit.Backup)"
    }
}
elseif ($changes.Count -gt 0) { Write-Information 'Preview only. Add -Apply to write these values (a backup is saved first).' }

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Warning "Not settled: $p" }
    Write-Warning "$($problems.Count) value(s) are not settled: infrastructure.yml still holds a value discovery could not confirm or place."
    exit 1
}
