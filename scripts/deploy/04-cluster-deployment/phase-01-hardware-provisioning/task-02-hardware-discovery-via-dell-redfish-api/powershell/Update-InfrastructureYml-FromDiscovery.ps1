#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the serial numbers and port MACs found by hardware discovery into infrastructure.yml.

.DESCRIPTION
    Reads the <ServiceTag>.json files of Invoke-HardwareDiscovery.ps1 and shows what would change in infrastructure.yml:

      nodes[].serial_number                       from the service tag
      nodes[].network_adapters[].mac_address      for the entry with the same name as the discovered port
      nodes[].management.mac_address              for a node described with management only, when the management
                                                  port is confirmed (-ManagementPort, or the MAC already in the file)

    Nothing is written without -Apply. With -Apply it saves a backup (<file>.bak.<time>), asks for confirmation (unless
    -Force) and edits only those lines: comments, order and quoting stay. A key that is not in the file is inserted under its
    existing parent; a parent that is missing is reported, never created. Roles, IP assignment and addresses are never written:
    discovery cannot read them from hardware. Ports the file does not list are shown as notes; the proposal file lists them.

.PARAMETER ConfigPath
    infrastructure.yml. Default: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml, then .\config\infrastructure.yml.

.PARAMETER DiscoveryPath
    Folder with the discovery JSON files. Default: .\discovery

.PARAMETER ManagementPort
    The management port by suggested name or MAC (see Invoke-HardwareDiscovery.ps1).

.PARAMETER Apply
    Write the changes. Without it this is a preview.

.PARAMETER Force
    With -Apply: no confirmation prompt.

.EXAMPLE
    .\Update-InfrastructureYml-FromDiscovery.ps1 -ConfigPath .\infrastructure.yml

.EXAMPLE
    .\Update-InfrastructureYml-FromDiscovery.ps1 -ConfigPath .\infrastructure.yml -ManagementPort 'Slot 3 Port 1' -Apply

.NOTES
    Phase: 04-cluster-deployment / phase-01-hardware-provisioning / task-02-hardware-discovery-via-dell-redfish-api
    Requires PowerShell 7 and the powershell-yaml module.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath,
    [string]$DiscoveryPath = (Join-Path '.' 'discovery'),
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
$root = Get-ToolkitRoot
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([System.IO.Path]::Combine($root, 'scripts', 'common', 'infrastructure', 'AzlInfrastructureEdit.psm1'))

$resolved = $ConfigPath
if (-not $resolved) {
    $resolved = @($env:AZL_INFRASTRUCTURE_FILE, (Join-Path '.' 'infrastructure.yml'), (Join-Path (Join-Path '.' 'config') 'infrastructure.yml')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $resolved) { throw 'No infrastructure file found: pass -ConfigPath.' }
}
$infrastructure = Import-AzlInfrastructure -Path $resolved -SkipValidation

$files = @(Get-ChildItem -LiteralPath $DiscoveryPath -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object Name -NotIn @('discovery-summary.json', 'idrac-inventory.json'))
if ($files.Count -eq 0) { throw "No discovery files in $DiscoveryPath. Run Invoke-HardwareDiscovery.ps1 first." }
$items = foreach ($f in $files) {
    $d = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -Depth 50
    if (-not $d.PSObject.Properties['NodeName'] -or -not $d.PSObject.Properties['Identity']) { Write-Warning "$($f.Name) is not a discovery file of Invoke-HardwareDiscovery.ps1: skipped."; continue }
    [pscustomobject]@{ NodeName = [string]$d.NodeName; Discovery = $d; ManagementPort = $ManagementPort }
}

$plan = Get-AzlDiscoveryChange -Infrastructure $infrastructure -Item @($items)
foreach ($n in $plan.Notes) { Write-Warning $n }
if ($plan.Changes.Count -eq 0) { Write-Information "infrastructure.yml already matches the discovery ($resolved)."; return }

Write-Information "Changes to $resolved :"
foreach ($c in $plan.Changes) { Write-Information "  $($c.Display): $(if ($c.Old) { $c.Old } else { '(not set)' }) -> $($c.New)" }
if (-not $Apply) { Write-Information 'Preview only. Add -Apply to write these values (a backup is saved first).'; return }

if ($Force) { $ConfirmPreference = 'None' }
if ($PSCmdlet.ShouldProcess($resolved, "Write $($plan.Changes.Count) discovered value(s)")) {
    $edit = Invoke-AzlYamlEdit -Path $resolved -Change $plan.Changes -Confirm:$false
    foreach ($r in $edit.Results) { Write-Information "  $($r.Result): $($r.Display)" }
    Write-Information "Backup: $($edit.Backup)"
    $notDone = @($edit.Results | Where-Object { $_.Result -in 'NotFound', 'NotScalar' })
    if ($notDone.Count -gt 0) { Write-Warning "$($notDone.Count) value(s) could not be placed (the key or its parent is not in the file): copy them from the proposal file." }
}
