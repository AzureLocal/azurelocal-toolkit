#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 01, Task 02: hardware discovery of every node through the Redfish API of its BMC (read only). This version: Dell iDRAC.

.DESCRIPTION
    The first stage of the flow. It runs before azurelocal-ztp and before the OS configuration, from the management server.
    For each nodes[] entry of infrastructure.yml that has bmc.ip_address it reads the BMC with the Redfish core
    (scripts/common/redfish/AzlRedfishCore.psm1) and the adapter for the detected vendor (AzlRedfishDell.psm1), and writes one
    JSON file per node (schemaVersion 2.0) with everything the BMC offers:

      identity       service tag (the serial number ZTP maps vouchers by), model, UUID, every serial a voucher might use
      BMC            the iDRAC MAC, interfaces, protocols, certificate
      system         BIOS version, Secure Boot, TPM, boot order, virtualization switches
      processors, memory modules, PCIe devices and GPUs
      network        adapters and ports: name, slot, MAC, link, speed, model
      storage        controllers, drives, volumes, the BOSS card and the boot device
      firmware       the firmware inventory
      settings       every BIOS attribute and every iDRAC attribute (secret-looking values redacted)
      health         sensors, power, thermal; events: a summary of the logs
      capabilities   what could and could not be read, and why (ok / partial / notSupported / denied / error / skipped)
      readErrors     every request that failed

    Vendor: detected from the Oem namespace, Manufacturer and Model. This version supports Dell iDRAC only; any other BMC is
    reported as "Unsupported vendor in this version" for that node and the others carry on. -Vendor Dell forces the Dell adapter.

    Output, in -OutputPath (default .\discovery; keep it out of git, it holds serials and MACs):
      <ServiceTag>.json             one file per node
      discovery-summary.json        one line per node, with the suggested management port and why
      infrastructure.discovered.yml the nodes: fragment to review and copy into infrastructure.yml (roles are yours to set)

    With -UpdateInfrastructure it then runs Update-InfrastructureYml-FromDiscovery.ps1 -Apply, which edits only the
    serial_number and MAC lines (with a backup and a confirmation). ZTP then finds the maintenance environment by the
    management MAC; the OS configuration finds every port by MAC. New infrastructure.yml fields are added through the master
    variable registry first, so nothing else is written.

    The BMC login: -Credential, then the Key Vault references in infrastructure.yml (nodes[].bmc or hardware.bmc), then a
    prompt. No password is read from a file or logged. Only GET requests are sent (with -UseSession also one session POST and
    its DELETE).

.PARAMETER ConfigPath
    infrastructure.yml. Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml, then .\config\infrastructure.yml.

.PARAMETER OutputPath
    Folder for the output. Default: .\discovery

.PARAMETER Credential
    The BMC login.

.PARAMETER TargetNode
    Node names to limit the run to.

.PARAMETER ManagementPort
    The management port of every node, by suggested name (for example 'Slot 3 Port 1') or by MAC. Without it, the MAC already
    in the file is used, and otherwise a guess that is shown but never written.

.PARAMETER Detail
    Summary or Full (default).

.PARAMETER Vendor
    Auto (default) detects the vendor; Dell forces the Dell adapter.

.PARAMETER ThrottleLimit
    Nodes read at the same time (1 to 16, default 4). Requests to one node are always one after another.

.PARAMETER UseSession
    Log in with a Redfish session (X-Auth-Token) instead of Basic on every request.

.PARAMETER UpdateInfrastructure
    Also write the serial numbers and MACs into infrastructure.yml (with a backup and a confirmation).

.PARAMETER Force
    With -UpdateInfrastructure: no confirmation prompt.

.PARAMETER VerifyCertificate
    Check the BMC TLS certificate. Default: not checked (self-signed).

.EXAMPLE
    .\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml

.EXAMPLE
    .\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml -ManagementPort 'Slot 3 Port 1' -UpdateInfrastructure

.NOTES
    Phase: 04-cluster-deployment / phase-01-hardware-provisioning / task-02-hardware-discovery-via-dell-redfish-api
    Requires PowerShell 7, the powershell-yaml module, TCP 443 to the BMCs. Nothing is changed on any BMC.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputPath = (Join-Path '.' 'discovery'),
    [System.Management.Automation.PSCredential]$Credential,
    [string[]]$TargetNode = @(),
    [string]$ManagementPort,
    [ValidateSet('Summary', 'Full')][string]$Detail = 'Full',
    [ValidateSet('Auto', 'Dell')][string]$Vendor = 'Auto',
    [ValidateRange(1, 16)][int]$ThrottleLimit = 4,
    [switch]$UseSession,
    [switch]$UpdateInfrastructure,
    [switch]$Force,
    [switch]$VerifyCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Get-ToolkitRoot {
    $dir = $PSScriptRoot
    while ($dir) {
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1'))) { return $dir }
        $dir = Split-Path -Parent $dir
    }
    throw "The toolkit root (scripts/common/redfish) was not found above $PSScriptRoot."
}
$root = Get-ToolkitRoot
$corePath = [System.IO.Path]::Combine($root, 'scripts', 'common', 'redfish', 'AzlRedfishCore.psm1')
$dellPath = [System.IO.Path]::Combine($root, 'scripts', 'common', 'redfish', 'AzlRedfishDell.psm1')
Import-Module $corePath
Import-Module $dellPath
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'idrac-management', 'AzlDellRedfish.psm1'))
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))

function Get-ExistingManagementMac([System.Collections.IDictionary]$Node) {
    $adapters = @($(if ($Node.Contains('network_adapters')) { $Node['network_adapters'] }))
    $owner = $adapters | Where-Object { $_ -is [System.Collections.IDictionary] -and @($_['roles']) -contains 'management' -and $_['mac_address'] } | Select-Object -First 1
    if ($owner) { return [string]$owner['mac_address'] }
    $m = $Node['management']
    if ($m -is [System.Collections.IDictionary] -and $m['mac_address']) { return [string]$m['mac_address'] }
    return ''
}

$infrastructure = if ($ConfigPath) { Import-AzlInfrastructure -Path $ConfigPath -SkipValidation } else { Import-AzlInfrastructure -SkipValidation }
$nodes = @(@($infrastructure['nodes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['bmc'] -is [System.Collections.IDictionary] -and $_['bmc']['ip_address'] })
if ($TargetNode.Count -gt 0) { $nodes = @($nodes | Where-Object { [string]$_['name'] -in $TargetNode }) }
if ($nodes.Count -eq 0) { throw 'No node with a bmc.ip_address to discover. Check nodes[].bmc.ip_address and -TargetNode.' }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Credentials are resolved here, one node at a time, because a prompt cannot happen inside a parallel runspace.
$shared = $Credential
$work = foreach ($node in $nodes) {
    $hasOwnLogin = $node['bmc'].Contains('username') -and $node['bmc'].Contains('password')
    $cred = if ($hasOwnLogin) { Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $infrastructure -Node $node }
    else {
        if (-not $shared) { $shared = Resolve-AzlBmcCredential -Infrastructure $infrastructure }
        $shared
    }
    [pscustomobject]@{ Name = [string]$node['name']; Address = [string]$node['bmc']['ip_address']; Credential = $cred; ExistingManagementMac = (Get-ExistingManagementMac $node) }
}

Write-Information "Reading $(@($work).Count) BMC(s), $ThrottleLimit at a time ($Detail, vendor $Vendor)."
$options = [pscustomobject]@{ Detail = $Detail; Vendor = $Vendor; UseSession = $UseSession.IsPresent; VerifyCertificate = $VerifyCertificate.IsPresent; CorePath = $corePath; DellPath = $dellPath }
$scan = {
    param($Item, $Shared)
    Import-Module $Shared.CorePath
    Import-Module $Shared.DellPath
    Invoke-AzlRedfishDiscovery -BmcAddress $Item.Address -Credential $Item.Credential -Vendor $Shared.Vendor -Detail $Shared.Detail -UseSession:$Shared.UseSession -VerifyCertificate:$Shared.VerifyCertificate
}
$results = Invoke-AzlRedfishBatch -Item @($work) -ScriptBlock $scan -Shared $options -ThrottleLimit $ThrottleLimit

$items = [System.Collections.Generic.List[object]]::new()
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($r in @($results | Sort-Object { $_.Item.Name })) {
    $name = $r.Item.Name
    if ($r.Error) {
        $failed.Add($name)
        Write-Error "${name}: $($r.Error)" -ErrorAction Continue
        continue
    }
    $report = $r.Result
    $report['nodeName'] = $name
    $tag = if ($report.identity.serviceTag) { $report.identity.serviceTag } elseif ($report.identity.serialNumber) { $report.identity.serialNumber } else { $name }
    $safeTag = $tag -replace '[^A-Za-z0-9._-]', '_'
    $report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $OutputPath "$safeTag.json") -Encoding utf8
    $view = ConvertTo-AzlDiscoveryLegacyView -Report $report
    $view['NodeName'] = $name
    foreach ($w in @($report.warnings)) { Write-Warning "${name}: $w" }
    foreach ($a in $report.capabilities.areas.Keys) {
        $c = $report.capabilities.areas[$a]
        if ($c.status -in 'partial', 'denied', 'error') { Write-Warning "${name}: $a is $($c.status): $($c.reason)" }
        foreach ($n in @($c.notes)) { Write-Warning "${name}: $a note: $n" }
    }
    $items.Add([pscustomobject]@{ NodeName = $name; Discovery = $view; Report = $report; ManagementPort = $ManagementPort; ExistingManagementMac = $r.Item.ExistingManagementMac })
    $boot = $report.storage.bootDevice
    Write-Information "$name : $tag, $($report.identity.model): $(@($view.NetworkPorts).Count) port(s), $($report.capabilities.summary.ok)/$(@($report.capabilities.areas.Keys).Count) areas ok, BOSS $(if ($boot.kind -eq 'boss') { if ($boot.hasVirtualDisk) { 'with a virtual disk' } else { 'WITHOUT a virtual disk' } } else { 'not found' })."
}

if ($items.Count -gt 0) {
    $summary = foreach ($i in $items) {
        $d = $i.Discovery
        $choice = Select-AzlManagementPort -Ports @($d.NetworkPorts) -Name $i.ManagementPort -ExistingMac $i.ExistingManagementMac
        [ordered]@{
            NodeName = $i.NodeName; ServiceTag = $d.Identity.ServiceTag; Model = $d.Identity.Model; Vendor = $i.Report.vendor.name; VendorConfidence = $i.Report.vendor.confidence
            BmcMac = $d.Bmc.MacAddress; Ports = @($d.NetworkPorts | ForEach-Object { [ordered]@{ Name = $_.Name; Mac = $_.MacAddress; LinkUp = $_.LinkUp } })
            ManagementPort = $(if ($choice.Port) { $choice.Port.Name } else { $null }); ManagementMac = $(if ($choice.Port) { $choice.Port.MacAddress } else { $null })
            ManagementPortConfirmed = $choice.Confirmed; ManagementPortReason = $choice.Reason
            Boss = [ordered]@{ Present = $d.Boss.Present; DriveCount = $d.Boss.DriveCount; HasVirtualDisk = $d.Boss.HasVirtualDisk; NeedsVirtualDisk = $d.Boss.NeedsVirtualDisk }
            Capabilities = $i.Report.capabilities.summary; Complete = $i.Report.capabilities.complete; ReadErrors = @($i.Report.readErrors).Count
            Warnings = @($d.Warnings).Count
        }
    }
    @($summary) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputPath 'discovery-summary.json') -Encoding utf8
    $proposalPath = Join-Path $OutputPath 'infrastructure.discovered.yml'
    ConvertTo-AzlDiscoveryProposal -Item @($items | ForEach-Object { [pscustomobject]@{ NodeName = $_.NodeName; Discovery = $_.Discovery; ManagementPort = $_.ManagementPort; ExistingManagementMac = $_.ExistingManagementMac } }) | Set-Content -LiteralPath $proposalPath -Encoding utf8
    Write-Information "Proposal: $proposalPath (review it; roles and ip_assignment are yours to set)."
    foreach ($s in $summary) {
        Write-Information "  $($s.NodeName): management port $(if ($s.ManagementPort) { "'$($s.ManagementPort)' $($s.ManagementMac)" } else { 'not suggested' }) ($($s.ManagementPortReason))."
        if ($s.Boss.NeedsVirtualDisk) { Write-Information "  $($s.NodeName): the BOSS card has no virtual disk. Phase 02 Task 01 creates it before the OS install." }
    }
}

if ($UpdateInfrastructure -and $items.Count -gt 0) {
    $updater = Join-Path $PSScriptRoot 'Update-InfrastructureYml-FromDiscovery.ps1'
    $arguments = @{ DiscoveryPath = $OutputPath; Apply = $true }
    if ($ConfigPath) { $arguments.ConfigPath = $ConfigPath }
    if ($ManagementPort) { $arguments.ManagementPort = $ManagementPort }
    if ($Force) { $arguments.Force = $true }
    & $updater @arguments
}
elseif ($items.Count -gt 0) { Write-Information 'infrastructure.yml was not changed. Run Update-InfrastructureYml-FromDiscovery.ps1 -Apply, or copy the proposal.' }

if ($failed.Count -gt 0) { throw "$($failed.Count) node(s) could not be discovered: $($failed -join ', ')." }
Write-Information 'Discovery complete. Next: ZTP (azurelocal-ztp) reads serial_number and the management MAC from infrastructure.yml.'
