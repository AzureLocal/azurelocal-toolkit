#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 01, Task 02: hardware discovery of every node through the Dell iDRAC Redfish API (read only).

.DESCRIPTION
    The first stage of the flow. It runs before azurelocal-ztp and before the OS configuration, from the management server.
    For each nodes[] entry of infrastructure.yml that has bmc.ip_address it reads the iDRAC and collects:

      identity       service tag (the serial number ZTP maps vouchers by), model, BIOS version, UUID
      BMC            the iDRAC MAC
      network ports  one entry per physical port: suggested name and slot, MAC, link, speed, adapter model
      storage        controllers, drives, volumes, and the BOSS card (drives, whether its virtual disk exists)
      with -Detail Full (default): chassis, power, thermal, PCIe, processors, memory, firmware, and every BIOS and iDRAC
      attribute (the input of the BIOS and iDRAC settings tasks)

    Output, in -OutputPath (default .\discovery; keep it out of git, it holds serials and MACs):
      <ServiceTag>.json             one file per node
      discovery-summary.json        one line per node, with the suggested management port and why
      infrastructure.discovered.yml the nodes: fragment to review and copy into infrastructure.yml (roles are yours to set)

    With -UpdateInfrastructure it then runs Update-InfrastructureYml-FromDiscovery.ps1 -Apply, which edits only the
    serial_number and MAC lines (with a backup and a confirmation). ZTP then finds the maintenance environment by the
    management MAC; the OS configuration finds every port by MAC.

    The iDRAC login: -Credential, then the Key Vault references in infrastructure.yml (nodes[].bmc or hardware.bmc), then a
    prompt. No password is read from a file or logged.

.PARAMETER ConfigPath
    infrastructure.yml. Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml, then .\config\infrastructure.yml.

.PARAMETER OutputPath
    Folder for the output. Default: .\discovery

.PARAMETER Credential
    The iDRAC login.

.PARAMETER TargetNode
    Node names to limit the run to.

.PARAMETER ManagementPort
    The management port of every node, by suggested name (for example 'Slot 3 Port 1') or by MAC. Without it, the MAC already
    in the file is used, and otherwise a guess that is shown but never written.

.PARAMETER Detail
    Summary or Full (default).

.PARAMETER UpdateInfrastructure
    Also write the serial numbers and MACs into infrastructure.yml (with a backup and a confirmation).

.PARAMETER Force
    With -UpdateInfrastructure: no confirmation prompt.

.PARAMETER VerifyCertificate
    Check the iDRAC TLS certificate. Default: not checked (self-signed).

.EXAMPLE
    .\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml

.EXAMPLE
    .\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml -ManagementPort 'Slot 3 Port 1' -UpdateInfrastructure

.NOTES
    Phase: 04-cluster-deployment / phase-01-hardware-provisioning / task-02-hardware-discovery-via-dell-redfish-api
    Requires PowerShell 7, the powershell-yaml module, TCP 443 to the iDRACs. Nothing is changed on any iDRAC.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputPath = (Join-Path '.' 'discovery'),
    [System.Management.Automation.PSCredential]$Credential,
    [string[]]$TargetNode = @(),
    [string]$ManagementPort,
    [ValidateSet('Summary', 'Full')][string]$Detail = 'Full',
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
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, 'scripts', 'common', 'idrac-management', 'AzlDellRedfish.psm1'))) { return $dir }
        $dir = Split-Path -Parent $dir
    }
    throw "The toolkit root (scripts/common/idrac-management) was not found above $PSScriptRoot."
}
$root = Get-ToolkitRoot
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
$shared = $Credential
$items = [System.Collections.Generic.List[object]]::new()
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($node in $nodes) {
    $name = [string]$node['name']
    $address = [string]$node['bmc']['ip_address']
    Write-Information "=== $name ($Detail) ==="
    try {
        $hasOwnLogin = $node['bmc'].Contains('username') -and $node['bmc'].Contains('password')
        $cred = if ($hasOwnLogin) { Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $infrastructure -Node $node }
        else {
            if (-not $shared) { $shared = Resolve-AzlBmcCredential -Infrastructure $infrastructure }
            $shared
        }
        $d = Get-AzlDellNodeDiscovery -BmcAddress $address -Credential $cred -Detail $Detail -VerifyCertificate:$VerifyCertificate
        $d['NodeName'] = $name
        $tag = if ($d.Identity.ServiceTag) { $d.Identity.ServiceTag } else { $name }
        $d | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputPath "$tag.json") -Encoding utf8
        foreach ($w in $d.Warnings) { Write-Warning "${name}: $w" }
        $items.Add([pscustomobject]@{ NodeName = $name; Discovery = $d; ManagementPort = $ManagementPort; ExistingManagementMac = (Get-ExistingManagementMac $node) })
        Write-Information "  $tag, $($d.Identity.Model): $(@($d.NetworkPorts).Count) port(s), BOSS $(if ($d.Boss.Present) { if ($d.Boss.HasVirtualDisk) { 'with a virtual disk' } else { 'WITHOUT a virtual disk' } } else { 'not found' })."
    }
    catch {
        $failed.Add($name)
        Write-Error "${name}: $($_.Exception.Message)" -ErrorAction Continue
    }
}

if ($items.Count -gt 0) {
    $summary = foreach ($i in $items) {
        $choice = Select-AzlManagementPort -Ports @($i.Discovery.NetworkPorts) -Name $i.ManagementPort -ExistingMac $i.ExistingManagementMac
        [ordered]@{
            NodeName = $i.NodeName; ServiceTag = $i.Discovery.Identity.ServiceTag; Model = $i.Discovery.Identity.Model
            BmcMac = $i.Discovery.Bmc.MacAddress; Ports = @($i.Discovery.NetworkPorts | ForEach-Object { [ordered]@{ Name = $_.Name; Mac = $_.MacAddress; LinkUp = $_.LinkUp } })
            ManagementPort = $(if ($choice.Port) { $choice.Port.Name } else { $null }); ManagementMac = $(if ($choice.Port) { $choice.Port.MacAddress } else { $null })
            ManagementPortConfirmed = $choice.Confirmed; ManagementPortReason = $choice.Reason
            Boss = [ordered]@{ Present = $i.Discovery.Boss.Present; DriveCount = $i.Discovery.Boss.DriveCount; HasVirtualDisk = $i.Discovery.Boss.HasVirtualDisk; NeedsVirtualDisk = $i.Discovery.Boss.NeedsVirtualDisk }
            Warnings = @($i.Discovery.Warnings).Count
        }
    }
    @($summary) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputPath 'discovery-summary.json') -Encoding utf8
    $proposalPath = Join-Path $OutputPath 'infrastructure.discovered.yml'
    ConvertTo-AzlDiscoveryProposal -Item $items.ToArray() | Set-Content -LiteralPath $proposalPath -Encoding utf8
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
