#Requires -Version 7.0
<#
.SYNOPSIS
    Standalone hardware discovery of Dell iDRACs through Redfish: no module, no infrastructure.yml (read only).

.DESCRIPTION
    Fully self-contained, for a laptop or a jump host that has only this one file. For each iDRAC address it reads the system
    (service tag, model, BIOS), the iDRAC network interfaces, every network adapter port with its MAC, the BIOS and iDRAC
    attributes and the storage controllers, saves <ServiceTag>.json, and prints a table of service tag and MAC per port.

    Copy the service tag into nodes[].serial_number and the MAC of each port into nodes[].network_adapters[].mac_address of
    infrastructure.yml by hand. To have the toolkit do it with a proposal and a diff, use Invoke-HardwareDiscovery.ps1.

    The login is prompted for (a PSCredential, never a plain-text password in a file). Nothing is changed on any iDRAC.

.PARAMETER BmcAddress
    One or more iDRAC addresses.

.PARAMETER Credential
    The iDRAC login. Prompted for when omitted.

.PARAMETER OutputPath
    Folder for the JSON files. Default: .\discovery (keep it out of git: it holds serials and MACs).

.PARAMETER VerifyCertificate
    Check the iDRAC TLS certificate. Default: not checked (self-signed).

.EXAMPLE
    .\Get-HardwareDiscovery-Standalone.ps1 -BmcAddress '<idrac-address-1>', '<idrac-address-2>'

.NOTES
    Phase: 04-cluster-deployment / phase-01-hardware-provisioning / task-02-hardware-discovery-via-dell-redfish-api
    Requires PowerShell 7 and TCP 443 to the iDRACs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$BmcAddress,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$OutputPath = (Join-Path '.' 'discovery'),
    [switch]$VerifyCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$script:Verify = $VerifyCertificate.IsPresent

function Get-Redfish([string]$Address, [string]$Path, [System.Management.Automation.PSCredential]$Login) {
    $uri = if ($Path -match '^https://') { $Path } else { "https://$Address$Path" }
    Invoke-RestMethod -Uri $uri -Credential $Login -Authentication Basic -Headers @{ Accept = 'application/json' } -SkipCertificateCheck:(-not $script:Verify) -TimeoutSec 60
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-RedfishMember([string]$Address, [string]$Path, $Login) {
    $collection = Get-Redfish $Address $Path $Login
    foreach ($m in @(Get-Prop $collection 'Members')) { Get-Redfish $Address (Get-Prop $m '@odata.id') $Login }
}

if (-not $Credential) { $Credential = Get-Credential -Message 'iDRAC administrator credentials' }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$system = '/redfish/v1/Systems/System.Embedded.1'
$manager = '/redfish/v1/Managers/iDRAC.Embedded.1'

$table = [System.Collections.Generic.List[object]]::new()
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($address in $BmcAddress) {
    Write-Information "=== $address ==="
    try {
        $sys = Get-Redfish $address $system $Credential
        $tag = [string](Get-Prop $sys 'SKU')
        $ports = foreach ($adapter in (Get-RedfishMember $address "$system/NetworkAdapters" $Credential)) {
            $portsLink = Get-Prop (Get-Prop $adapter 'NetworkPorts') '@odata.id'
            if (-not $portsLink) { $portsLink = Get-Prop (Get-Prop $adapter 'Ports') '@odata.id' }
            if (-not $portsLink) { continue }
            foreach ($port in (Get-RedfishMember $address $portsLink $Credential)) {
                $mac = @(Get-Prop $port 'AssociatedNetworkAddresses') | Where-Object { $_ } | Select-Object -First 1
                if (-not $mac) { $mac = Get-Prop $port 'MACAddress' }
                [pscustomobject]@{ ServiceTag = $tag; Adapter = (Get-Prop $adapter 'Id'); Port = (Get-Prop $port 'Id'); Mac = $mac; Link = (Get-Prop $port 'LinkStatus'); SpeedMbps = (Get-Prop $port 'CurrentLinkSpeedMbps') }
            }
        }
        $inventory = [ordered]@{
            CollectedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); BmcAddress = $address; System = $sys
            BmcInterfaces = @(Get-RedfishMember $address "$manager/EthernetInterfaces" $Credential); NetworkPorts = @($ports)
            BiosAttributes = Get-Redfish $address "$system/Bios" $Credential; BmcAttributes = Get-Redfish $address "$manager/Attributes" $Credential
            Storage = @(Get-RedfishMember $address "$system/Storage" $Credential)
        }
        $file = Join-Path $OutputPath "$tag.json"
        $inventory | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $file -Encoding utf8
        Write-Information "  Service tag $tag, saved $file"
        foreach ($p in @($ports)) { $table.Add($p) }
    }
    catch {
        $failed.Add($address)
        Write-Error "${address}: $($_.Exception.Message)" -ErrorAction Continue
    }
}
$table
if ($failed.Count -gt 0) { throw "$($failed.Count) iDRAC(s) failed: $($failed -join ', ')." }
Write-Information 'Copy the service tag and each port MAC into infrastructure.yml, or run Invoke-HardwareDiscovery.ps1 for a proposal.'
