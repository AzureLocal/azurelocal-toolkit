#Requires -Version 7.0
<#
.SYNOPSIS
    Collects a full hardware inventory from Dell iDRACs through Redfish (read only).

.DESCRIPTION
    Reads each iDRAC and keeps one consolidated file, idrac-inventory.json, with the nodes keyed by service tag and updated in
    place on every run. Per node (schemaVersion 2.0 report of the Redfish core): identity (service tag, model, BIOS), the BMC MAC, every network port with its MAC, storage
    and the BOSS card, and with the default -Detail Full also chassis, power, thermal, PCIe, processors, memory, firmware and
    every BIOS and iDRAC attribute.

    This is the first stage of the flow: discovery runs before azurelocal-ztp and before the OS configuration. To fill
    infrastructure.yml from the result, use Invoke-HardwareDiscovery.ps1 (Phase 01, Task 02), which reads the BMC addresses
    from the file and writes a reviewable proposal.

    The BMC login comes from -Credential, then the Key Vault references in infrastructure.yml (hardware.bmc), then a prompt.
    No password is read from a file, written to a file or logged. The output holds serial numbers and MACs: keep it out of git.

.PARAMETER BmcAddress
    One or more iDRAC addresses. Optional when -ConfigPath is given (nodes[].bmc.ip_address is used).

.PARAMETER ConfigPath
    infrastructure.yml. Gives the BMC addresses and the Key Vault references for the login.

.PARAMETER Credential
    The iDRAC login. Overrides Key Vault and the prompt.

.PARAMETER OutputPath
    Folder for the output. Default: .\discovery

.PARAMETER Detail
    Summary or Full (default).

.PARAMETER KeepTimestampedFiles
    Also save one timestamped file per node.

.PARAMETER VerifyCertificate
    Check the iDRAC TLS certificate. Default: not checked, because iDRACs ship a self-signed certificate.

.EXAMPLE
    .\Get-DellServerInventory-FromiDRAC.ps1 -BmcAddress '<idrac-address-1>', '<idrac-address-2>'

.EXAMPLE
    .\Get-DellServerInventory-FromiDRAC.ps1 -ConfigPath .\infrastructure.yml -Detail Summary

.NOTES
    Requires PowerShell 7, network access to the iDRACs on TCP 443, and an iDRAC 9 with Redfish.
    Reads only: nothing is changed on any iDRAC.
#>
[CmdletBinding()]
param(
    [string[]]$BmcAddress,
    [string]$ConfigPath,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$OutputPath = (Join-Path '.' 'discovery'),
    [ValidateSet('Summary', 'Full')][string]$Detail = 'Full',
    [switch]$KeepTimestampedFiles,
    [switch]$VerifyCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'redfish', 'AzlRedfishCore.psm1'))
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'redfish', 'AzlRedfishDell.psm1'))

$infrastructure = $null
$targets = [System.Collections.Generic.List[object]]::new()
if ($ConfigPath) {
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))
    $infrastructure = Import-AzlInfrastructure -Path $ConfigPath -SkipValidation
    foreach ($n in @($infrastructure['nodes'])) {
        $bmc = if ($n -is [System.Collections.IDictionary]) { $n['bmc'] } else { $null }
        if ($bmc -is [System.Collections.IDictionary] -and $bmc['ip_address'] -and -not $BmcAddress) { $targets.Add([pscustomobject]@{ Address = [string]$bmc['ip_address']; Node = $n }) }
    }
}
foreach ($a in @($BmcAddress)) { if ($a) { $targets.Add([pscustomobject]@{ Address = $a; Node = $null }) } }
if ($targets.Count -eq 0) { throw 'No iDRAC to read: pass -BmcAddress, or -ConfigPath with nodes[].bmc.ip_address.' }

$cred = Resolve-AzlBmcCredential -Credential $Credential -Infrastructure $infrastructure -Node ($targets[0].Node)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$consolidatedPath = Join-Path $OutputPath 'idrac-inventory.json'
$consolidated = [ordered]@{ Metadata = [ordered]@{ ScriptVersion = '4.0.0'; Created = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }; Nodes = [ordered]@{} }
if (Test-Path -LiteralPath $consolidatedPath) {
    try {
        $existing = Get-Content -LiteralPath $consolidatedPath -Raw | ConvertFrom-Json -AsHashtable -Depth 50
        if ($existing -is [System.Collections.IDictionary] -and $existing.Contains('Nodes')) { $consolidated = $existing }
    }
    catch { Write-Warning "The existing $consolidatedPath could not be read and is replaced: $($_.Exception.Message)" }
}

$failed = [System.Collections.Generic.List[string]]::new()
$summary = [System.Collections.Generic.List[object]]::new()
foreach ($t in $targets) {
    Write-Information "Reading iDRAC $($t.Address) ($Detail)..."
    try {
        $d = Invoke-AzlRedfishDiscovery -BmcAddress $t.Address -Credential $cred -Detail $Detail -VerifyCertificate:$VerifyCertificate
        $tag = if ($d.identity.serviceTag) { $d.identity.serviceTag } elseif ($d.identity.serialNumber) { $d.identity.serialNumber } else { "UNKNOWN-$($t.Address)" }
        $state = if ($consolidated.Nodes.Contains($tag)) { 'updated' } else { 'new' }
        $consolidated.Nodes[$tag] = $d
        if ($KeepTimestampedFiles) {
            $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
            $d | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputPath "idrac-inventory-$tag-$stamp.json") -Encoding utf8
        }
        foreach ($w in $d.warnings) { Write-Warning "$tag : $w" }
        $portCount = 0
        foreach ($adapter in @($d.network.adapters)) { $portCount += @($adapter.ports).Count }
        $hasBoss = ($d.storage.bootDevice.kind -eq 'boss')
        Write-Information "  $tag ($($d.identity.model)): $portCount port(s), BOSS: $(if ($hasBoss) { 'yes' } else { 'no' }), $state."
        $summary.Add([pscustomobject]@{ ServiceTag = $tag; Model = $d.identity.model; Ports = $portCount; Boss = $hasBoss; Warnings = @($d.warnings).Count; State = $state })
    }
    catch {
        $failed.Add($t.Address)
        Write-Error "iDRAC $($t.Address) failed: $($_.Exception.Message)" -ErrorAction Continue
    }
}

$consolidated.Metadata.LastUpdated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$consolidated.Metadata.NodeCount = $consolidated.Nodes.Count
$consolidated | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $consolidatedPath -Encoding utf8
Write-Information "Inventory: $consolidatedPath ($($consolidated.Nodes.Count) node(s))."
Write-Information 'Next: run Invoke-HardwareDiscovery.ps1 to propose the infrastructure.yml values, then ZTP.'
$summary
if ($failed.Count -gt 0) { throw "$($failed.Count) iDRAC(s) could not be read: $($failed -join ', ')." }
