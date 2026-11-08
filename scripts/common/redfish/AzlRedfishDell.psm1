#Requires -Version 7.0
<#
.SYNOPSIS
    Dell iDRAC adapter for the Redfish discovery core (AzlRedfishCore.psm1).

.DESCRIPTION
    The core reads every standard DMTF resource. This adapter adds only what is Dell specific:

      * port names and slots from the Port resource (Slot 3 Port 1, Embedded NIC 2, Integrated NIC 1 Port 2)
      * the model of a card whose NetworkAdapter has no Model (the embedded LOM): the Dell NIC product name, then the PCIe device
      * the service tag (Redfish System SKU, the serial Dell uses for Azure ownership vouchers)
      * the BOSS card, its drives, whether its virtual disk exists, and the boot device
      * the iDRAC attributes (Managers/iDRAC.Embedded.1/Attributes) and the virtualization switches from the BIOS attributes
      * Installed / Previous firmware entries
      * the raw Oem.Dell blocks

    Every OEM path used is registered in the capability report with its basis:
      lab-observed  seen in the first lab scan of Dell AX-760 nodes (iDRAC9)
      documented    named in Dell's iDRAC9 Redfish API Guide / BIOS attribute registry (not re-read for this module)
      inferred      not confirmed anywhere above; needs a scan on real hardware before it is relied on
    Dell sources: Dell iDRAC9 Redfish API Guide (dell.com/support, "iDRAC9 Redfish API Guide"), DellNIC / DellSystem classes in the
    iDRAC REST API documentation, and github.com/dell/iDRAC-Redfish-Scripting.

    Read only: this module sends no request of its own; it reads through the core.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, 'AzlRedfishCore.psm1'))

function Get-AzlDellPortLabel {
    <#
    .SYNOPSIS
        The port name and slot infrastructure.yml uses, from the Port resource's ID and PhysicalPortNumber.
    .DESCRIPTION
        NIC.Slot.3-1 is 'Slot 3 Port 1' (slot 'Slot 3'); NIC.Embedded.2-1 is 'Embedded NIC 2' (slot 'Embedded', the value
        azurelocal-ztp reads to enable the embedded NICs); NIC.Integrated.1-2 is 'Integrated NIC 1 Port 2'.
        The name comes from the port, not from the adapter ID: the LOM lists NIC.Embedded.2-1 under the adapter
        NIC.Embedded.1, and naming it from the adapter produced 'Embedded NIC 1 (2)'. The adapter ID is used only when the
        port ID has no recognisable shape. The names are a suggestion: networking intents name ports by them, so keep one name
        per port on every node.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$AdapterId, [string]$PortId = '', $PhysicalPortNumber = $null, [int]$Ordinal = 1)
    $physical = if ($null -ne $PhysicalPortNumber -and "$PhysicalPortNumber" -match '^\d+$') { [int]$PhysicalPortNumber } else { $null }
    $m = [regex]::Match($PortId, '^NIC\.Slot\.(?<s>\d+)-(?<p>\d+)')
    if ($m.Success) {
        $port = if ($physical) { $physical } else { [int]$m.Groups['p'].Value }
        return [pscustomobject]@{ Name = "Slot $($m.Groups['s'].Value) Port $port"; Slot = "Slot $($m.Groups['s'].Value)"; PortNumber = "$port" }
    }
    $m = [regex]::Match($PortId, '^NIC\.Embedded\.(?<n>\d+)-(?<p>\d+)')
    if ($m.Success) { return [pscustomobject]@{ Name = "Embedded NIC $($m.Groups['n'].Value)"; Slot = 'Embedded'; PortNumber = $(if ($physical) { "$physical" } else { $m.Groups['n'].Value }) } }
    $m = [regex]::Match($PortId, '^NIC\.Integrated\.(?<n>\d+)-(?<p>\d+)')
    if ($m.Success) {
        $port = if ($physical) { $physical } else { [int]$m.Groups['p'].Value }
        return [pscustomobject]@{ Name = "Integrated NIC $($m.Groups['n'].Value) Port $port"; Slot = "Integrated $($m.Groups['n'].Value)"; PortNumber = "$port" }
    }
    # The port ID has no known shape: fall back to the adapter ID and the port number.
    $number = if ($physical) { $physical } else { $Ordinal }
    $a = [regex]::Match($AdapterId, '^NIC\.Slot\.(?<s>\d+)')
    if ($a.Success) { return [pscustomobject]@{ Name = "Slot $($a.Groups['s'].Value) Port $number"; Slot = "Slot $($a.Groups['s'].Value)"; PortNumber = "$number" } }
    $a = [regex]::Match($AdapterId, '^NIC\.Embedded\.(?<n>\d+)')
    if ($a.Success) { return [pscustomobject]@{ Name = "Embedded NIC $number"; Slot = 'Embedded'; PortNumber = "$number" } }
    $a = [regex]::Match($AdapterId, '^NIC\.Integrated\.(?<n>\d+)')
    if ($a.Success) { return [pscustomobject]@{ Name = "Integrated NIC $($a.Groups['n'].Value) Port $number"; Slot = "Integrated $($a.Groups['n'].Value)"; PortNumber = "$number" } }
    $fallback = if ($PortId) { $PortId } else { "$AdapterId Port $number" }
    return [pscustomobject]@{ Name = $fallback; Slot = $AdapterId; PortNumber = "$number" }
}

function Test-AzlDellGenericLabel {
    <#
    .SYNOPSIS
        True when a text is a generic Dell label that names no hardware model.
    .DESCRIPTION
        Dell fills Name and Description fields with view labels: 'Network Adapter View' (seen in the lab scan as the NetworkAdapter
        Name of the embedded LOM), 'Network Adapter', 'NIC in Slot 3', 'Embedded NIC 1', 'Integrated NIC 1', a bare FQDN such as
        NIC.Embedded.1, and 'Network Adapter - NIC.Embedded.1'. None of these is a model, so none is ever reported as one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $t = $Text.Trim()
    $patterns = @(
        '^Network Adapter( View)?$'
        '^Network (Adapter|Port|Device Function)( View)?\s*-\s*NIC\..*$'
        '^NIC in Slot\b.*$'
        '^(Embedded|Integrated) NIC \d+( Port \d+)?$'
        '^NIC\.[A-Za-z]+\.\d+(-\d+)*$'
        '^NIC Slot \d+( Port \d+)?$'
    )
    foreach ($pattern in $patterns) { if ($t -match "(?i)$pattern") { return $true } }
    return $false
}

function Get-DellOemBlock {
    param($Resource)
    $dell = Get-RfProp (Get-RfProp $Resource 'Oem') 'Dell'
    return $dell
}

function Get-AzlRedfishDellAdapter {
    <#
    .SYNOPSIS
        The Dell adapter definition the core calls: fallback paths, port labeler, NIC model hint and the OEM hooks.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $hooks = [ordered]@{}

    # Port naming from the Port resource (documented Dell FQDD shapes: NIC.Slot.n-p, NIC.Embedded.n-p, NIC.Integrated.n-p).
    $labeler = { param($Adapter, $Port, $Ordinal) Get-AzlDellPortLabel -AdapterId ([string](Get-RfProp $Adapter 'Id' '')) -PortId ([string](Get-RfProp $Port 'Id' '')) -PhysicalPortNumber (Get-RfProp $Port 'PhysicalPortNumber') -Ordinal $Ordinal }

    # The model of an adapter whose Model is empty (the lab's embedded Broadcom LOM). Source: the function's Oem.Dell.DellNIC.ProductName
    # (Dell DellNIC class; INFERRED: not seen in the lab scan, which was summary level). The PCIe device (a standard link) is tried next
    # by the core.
    $hooks.NicModelHint = {
        param($Context, $Functions)
        foreach ($f in @($Functions)) {
            $name = Get-RfText (Get-RfProp (Get-DellOemBlock $f) 'DellNIC') 'ProductName'
            $clean = if ($name) { ($name -replace '\s+-\s+([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\s*$', '').Trim() } else { $null }
            if ($clean -and -not (Test-AzlDellGenericLabel -Text $clean)) {
                Add-AzlRedfishOemPath -Context $Context -Area network -Path "$([string](Get-RfProp $f '@odata.id' ''))#Oem.Dell.DellNIC.ProductName" -Basis inferred -Source 'Dell DellNIC class (iDRAC REST API documentation); not seen in the lab scan'
                return [pscustomobject]@{ Model = $clean; Source = 'dell-nic-oem' }
            }
        }
        return $null
    }

    # Identity: the service tag is the Redfish System SKU (lab-observed). DellSystem carries the express service code (documented).
    $hooks.OemSystem = {
        param($Context, $Report, $Paths)
        $sys = Read-AzlRedfishResource -Context $Context -Path $Paths.System
        $chassis = if ($Paths.Chassis) { Read-AzlRedfishResource -Context $Context -Path $Paths.Chassis } else { $null }
        $tag = Get-RfText $sys 'SKU'
        $Report.identity.serviceTag = $tag
        if (-not $tag) { $Context.Warnings.Add('System: SKU (the service tag) is empty.') }
        Add-AzlRedfishOemPath -Context $Context -Area identity -Path "$($Paths.System)#SKU" -Basis lab-observed -Source 'First lab scan: the service tag is the System SKU'
        $dellSystem = Get-RfProp (Get-DellOemBlock $sys) 'DellSystem'
        $Report.identity.expressServiceCode = Get-RfText $dellSystem 'ExpressServiceCode'
        if ($dellSystem) { Add-AzlRedfishOemPath -Context $Context -Area identity -Path "$($Paths.System)#Oem.Dell.DellSystem" -Basis documented -Source 'Dell iDRAC9 Redfish API Guide, DellSystem' }
        $Report.raw['dell'] = [ordered]@{
            system  = Limit-AzlRedfishRaw (Get-DellOemBlock $sys)
            chassis = Limit-AzlRedfishRaw (Get-DellOemBlock $chassis)
            manager = $null
        }
    }

    # BMC: the iDRAC attributes (Full only). Link from the Manager when present, else the documented path.
    $hooks.OemBmc = {
        param($Context, $Report, $Paths, $Detail)
        if (-not $Paths.Manager) { return }
        $manager = Read-AzlRedfishResource -Context $Context -Path $Paths.Manager
        if ($Report.raw.Contains('dell')) { $Report.raw['dell'].manager = Limit-AzlRedfishRaw (Get-DellOemBlock $manager) }
        if ($Detail -ne 'Full') { return }
        $link = Get-RfLink $manager 'Attributes'
        $viaLink = [bool]$link
        if (-not $link) { $link = "$($Paths.Manager)/Attributes" }
        $attr = Read-AzlRedfishResource -Context $Context -Path $link
        Add-AzlRedfishOemPath -Context $Context -Area bmc -Path $link -Basis documented -Source "Dell iDRAC9 Redfish API Guide, Managers/iDRAC.Embedded.1/Attributes$(if (-not $viaLink) { ' (well-known path; the Manager did not link it)' })" -Status $(if ($attr) { 'ok' } else { 'error' })
        if ($attr) { $Report.settings.bmc = [ordered]@{ attributes = (Remove-AzlRedfishSecret -InputObject (Get-RfProp $attr 'Attributes')); source = 'Dell Managers/iDRAC.Embedded.1/Attributes' } }
    }

    # Storage: the BOSS card and the boot device. BOSS is a Storage controller named BOSS-* (lab-observed: BOSS.SL.12-1, 'BOSS-N1 Monolithic').
    $hooks.OemStorage = {
        param($Context, $Report, $Paths)
        $controllers = @($Report.storage.controllers)
        $boss = $controllers | Where-Object { "$($_.id) $($_.name) $($_.model)" -match 'BOSS' } | Select-Object -First 1
        $how = 'name'
        # BOSS-S1/S2 can show as AHCI.Slot.n-1; the onboard SATA controller is AHCI.Embedded.n and is never taken as BOSS.
        if (-not $boss) { $boss = $controllers | Where-Object { $_.id -match '^AHCI\.Slot\.' } | Select-Object -First 1; $how = 'controller-id' }
        if (-not $boss) {
            $Report.storage.bootDevice = [ordered]@{ kind = $null; controllerId = $null; driveIds = @(); volumeId = $null; capacityGiB = $null; hasVirtualDisk = $false; needsVirtualDisk = $false; detection = 'no-boss-found' }
            return
        }
        $boss.isBootController = $true
        foreach ($d in @($boss.drives)) { $d.isBoot = $true }
        $volume = @($boss.volumes) | Select-Object -First 1
        $capacity = if ($volume) { $volume.capacityGiB } else { (@($boss.drives) | Select-Object -First 1 | ForEach-Object { $_.capacityGiB }) }
        $Report.storage.bootDevice = [ordered]@{
            kind = 'boss'; controllerId = $boss.id; driveIds = @($boss.drives | ForEach-Object { $_.id }); volumeId = $(if ($volume) { $volume.id } else { $null })
            capacityGiB = $capacity; hasVirtualDisk = (@($boss.volumes).Count -gt 0); needsVirtualDisk = (@($boss.volumes).Count -eq 0); detection = $how
        }
        Add-AzlRedfishOemPath -Context $Context -Area storage -Path "$($Paths.System)/Storage/$($boss.id)" -Basis lab-observed -Source 'First lab scan: BOSS-N1 as Storage controller BOSS.SL.12-1 with a RAID1 volume'
    }

    # Firmware: Dell lists 'Installed-...' and 'Previous-...' (rollback) entries (INFERRED from the ID prefix; not re-read).
    $hooks.OemFirmware = {
        param($Context, $Report)
        $any = $false
        foreach ($f in @($Report.firmware)) {
            $state = if ("$($f.id)" -like 'Installed-*') { 'installed' } elseif ("$($f.id)" -like 'Current-*') { 'current' } elseif ("$($f.id)" -like 'Previous-*') { 'previous' } else { $null }
            $f['entryState'] = $state
            if ($state) { $any = $true }
        }
        if ($any) { Add-AzlRedfishOemPath -Context $Context -Area firmware -Path '/redfish/v1/UpdateService/FirmwareInventory/{Installed|Current|Previous}-*' -Basis lab-observed -Source 'Evidence scan of three lab AX-760 nodes: entries are named Installed-, Current- and Previous-<n>-<version>__<FQDD>' }
        # A card whose network resources name no model (the embedded LOM) is named by the firmware inventory:
        # 'Broadcom NetXtreme Gigabit Ethernet (BCM5720) - <MAC>' on entries whose id ends in the function FQDD (NIC.Embedded.1-1-1).
        foreach ($a in @($Report.network.adapters | Where-Object { -not $_.model })) {
            foreach ($fn in @($a.functions)) {
                $entry = @($Report.firmware | Where-Object { $_.id -like "*__$($fn.id)" -and $_.component -and -not (Test-AzlDellGenericLabel -Text $_.component) } | Sort-Object { $_.entryState -ne 'installed' }) | Select-Object -First 1
                if (-not $entry) { continue }
                $name = ($entry.component -replace '\s+-\s+([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\s*$', '').Trim()
                if ($name -and -not (Test-AzlDellGenericLabel -Text $name)) {
                    $a.model = $name
                    $a.modelSource = 'firmware-inventory'
                    Add-AzlRedfishOemPath -Context $Context -Area network -Path "/redfish/v1/UpdateService/FirmwareInventory/$($entry.id)#Name" -Basis lab-observed -Source 'Evidence scan of three lab AX-760 nodes: the firmware inventory names the embedded card (Broadcom NetXtreme Gigabit Ethernet (BCM5720) - <MAC>)'
                    break
                }
            }
        }
    }

    # Settings: virtualization switches from the BIOS attributes (Dell BIOS attribute registry: ProcVirtualization, SriovGlobalEnable;
    # IommuSupport is INFERRED and read only when present).
    $hooks.OemSettings = {
        param($Context, $Report)
        $attr = Get-RfProp $Report.settings.bios 'attributes'
        if (-not $attr) { return }
        $on = { param($v) if ($null -eq $v) { $null } else { [string]$v -eq 'Enabled' } }
        $Report.system.virtualization = [ordered]@{
            vtx = (& $on (Get-RfProp $attr 'ProcVirtualization')); sriov = (& $on (Get-RfProp $attr 'SriovGlobalEnable')); iommu = (& $on (Get-RfProp $attr 'IommuSupport')); source = 'bios-attributes'
        }
        Add-AzlRedfishOemPath -Context $Context -Area bios -Path 'Bios.Attributes.ProcVirtualization, SriovGlobalEnable' -Basis documented -Source 'Dell BIOS attribute registry'
        if ($null -ne (Get-RfProp $attr 'IommuSupport')) { Add-AzlRedfishOemPath -Context $Context -Area bios -Path 'Bios.Attributes.IommuSupport' -Basis inferred -Source 'attribute name not confirmed in a Dell document read here' }
    }

    return [pscustomobject]@{
        Vendor        = 'Dell'
        Name          = 'Dell iDRAC'
        FallbackPaths = @{ System = '/redfish/v1/Systems/System.Embedded.1'; Chassis = '/redfish/v1/Chassis/System.Embedded.1'; Manager = '/redfish/v1/Managers/iDRAC.Embedded.1' }
        PortLabel     = $labeler
        IsGenericModel = { param($t) Test-AzlDellGenericLabel -Text $t }
        Hooks         = $hooks
    }
}

Export-ModuleMember -Function Get-AzlDellPortLabel, Test-AzlDellGenericLabel, Get-AzlRedfishDellAdapter
