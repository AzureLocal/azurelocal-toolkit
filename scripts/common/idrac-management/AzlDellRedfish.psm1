#Requires -Version 7.0
<#
.SYNOPSIS
    Dell iDRAC management helpers: the proposal for infrastructure.yml, management-port selection, and the iDRAC VNC setting.

.DESCRIPTION
    Hardware discovery itself moved to the multi-vendor Redfish core (scripts/common/redfish): AzlRedfishCore.psm1 reads the
    standard resources and AzlRedfishDell.psm1 is the Dell adapter. This module keeps what is Dell management and what works on
    the flat view of a discovery (ConvertTo-AzlDiscoveryLegacyView): the proposal text and the management-port choice.

    Invoke-AzlRedfish                One Redfish call (GET or PATCH) used by Set-AzlDellIdracVnc. A test replaces this one function.
    Select-AzlManagementPort         Which port is the management port, and why.
    ConvertTo-AzlDiscoveryProposal   The infrastructure.yml fragment (YAML text) for the operator to review.
    Set-AzlDellIdracVnc              Enables or disables the iDRAC VNC server (the only function that writes to an iDRAC).

    ConvertTo-AzlMacAddress, Resolve-AzlBmcCredential and Get-AzlBmcKeyVaultSecret now live in the core and are re-exported here,
    so existing callers keep working.

    Nothing here stores or logs a password. Secrets come from Key Vault (keyvault://vault/secret) or a prompt.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'redfish', 'AzlRedfishCore.psm1'))

$script:ManagerPath = '/redfish/v1/Managers/iDRAC.Embedded.1'
function Invoke-AzlRedfish {
    <#
    .SYNOPSIS
        One Redfish request to a BMC over HTTPS. GET by default.
    .DESCRIPTION
        Uses HTTP Basic over TLS with the credential object, so the password never becomes a string in this code. BMCs ship
        a self-signed certificate, so the certificate is not checked unless -VerifyCertificate is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BmcAddress,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [ValidateSet('Get', 'Patch')][string]$Method = 'Get',
        [System.Collections.IDictionary]$Body,
        [switch]$VerifyCertificate,
        [int]$TimeoutSeconds = 60
    )
    $uri = if ($Path -match '^https://') { $Path } else { "https://$BmcAddress$Path" }
    $request = @{
        Uri                  = $uri
        Method               = $Method
        Credential           = $Credential
        Authentication       = 'Basic'
        Headers              = @{ Accept = 'application/json' }
        SkipCertificateCheck = (-not $VerifyCertificate)
        TimeoutSec           = $TimeoutSeconds
        ErrorAction          = 'Stop'
    }
    if ($Method -eq 'Patch') {
        $request.Body = $Body | ConvertTo-Json -Depth 10
        $request.ContentType = 'application/json'
    }
    return Invoke-RestMethod @request
}

function Select-AzlManagementPort {
    <#
    .SYNOPSIS
        Which discovered port is the management port, and why. Always a suggestion for the operator to confirm.
    .DESCRIPTION
        Order: -Name (a port name or MAC given by the operator), then -ExistingMac (the MAC already in infrastructure.yml),
        then the first embedded port with link, then the first port with link. Returns Port ($null when none), Reason and
        Confirmed (true only for the first two).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Ports, [string]$Name, [string]$ExistingMac)
    $byMac = { param($mac) $key = ConvertTo-AzlMacAddress $mac; if ($key) { $Ports | Where-Object { $_.MacAddress -eq $key } | Select-Object -First 1 } }
    if ($Name) {
        $hit = $Ports | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $hit) { $hit = & $byMac $Name }
        if (-not $hit) { throw "No discovered port is named or has the MAC '$Name'. Ports: $((@($Ports) | ForEach-Object { $_.Name }) -join ', ')." }
        return [pscustomobject]@{ Port = $hit; Reason = 'given with -ManagementPort'; Confirmed = $true }
    }
    if ($ExistingMac) {
        $hit = & $byMac $ExistingMac
        if ($hit) { return [pscustomobject]@{ Port = $hit; Reason = 'its MAC is already the management MAC in infrastructure.yml'; Confirmed = $true } }
    }
    $hit = $Ports | Where-Object { $_.LinkUp -and $_.Slot -eq 'Embedded' } | Select-Object -First 1
    if ($hit) { return [pscustomobject]@{ Port = $hit; Reason = 'first embedded port with link up (a guess: confirm it)'; Confirmed = $false } }
    $hit = $Ports | Where-Object { $_.LinkUp } | Select-Object -First 1
    if ($hit) { return [pscustomobject]@{ Port = $hit; Reason = 'first port with link up (a guess: confirm it)'; Confirmed = $false } }
    return [pscustomobject]@{ Port = $null; Reason = 'no port reports link up; choose it from the switch cabling'; Confirmed = $false }
}

function ConvertTo-YamlString([string]$Value) { return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"' }

function ConvertTo-AzlDiscoveryProposal {
    <#
    .SYNOPSIS
        The nodes: fragment of infrastructure.yml for the discovered machines, as YAML text with comments.
    .DESCRIPTION
        serial_number (the service tag) and every port's name, slot, model and MAC come from the machine. roles and
        ip_assignment are required by the schema and cannot be read from hardware, so every port is written as unused / none
        and the suggested management port as management / dhcp_reservation, each with a comment to confirm. Nothing is applied.
    .PARAMETER Item
        Objects with NodeName, Discovery (from Get-AzlDellNodeDiscovery) and optional ExistingManagementMac and ManagementPort.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Item)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Proposed by Invoke-HardwareDiscovery.ps1 at $([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')). Nothing is applied.")
    $lines.Add('# Review it, set roles and ip_assignment from your design, then copy it into infrastructure.yml.')
    $lines.Add('nodes:')
    foreach ($i in $Item) {
        $d = $i.Discovery
        $choice = Select-AzlManagementPort -Ports @($d.NetworkPorts) -Name ([string](Get-RfProp $i 'ManagementPort' '')) -ExistingMac ([string](Get-RfProp $i 'ExistingManagementMac' ''))
        $lines.Add("  - name: $(ConvertTo-YamlString $i.NodeName)")
        $lines.Add("    serial_number: $(ConvertTo-YamlString $d.Identity.ServiceTag) # Dell service tag; the chassis serial is $($d.Identity.SerialNumber)")
        if ($d.Boss.Present) {
            $disk = if ($d.Boss.HasVirtualDisk) { 'a virtual disk exists' } else { 'no virtual disk yet: run Phase 02 Task 01' }
            $lines.Add("    # BOSS: controller $($d.Boss.ControllerId), $($d.Boss.DriveCount) drive(s), $disk")
        }
        $lines.Add('    network_adapters:')
        foreach ($p in @($d.NetworkPorts)) {
            $isMgmt = $choice.Port -and $choice.Port.MacAddress -eq $p.MacAddress
            # The name is the key of the file (intents and storage networks refer to it): derived from the slot and the port, never from an OS name. The physical adapter is
            # found on a node by its MAC, so the OS may call it anything. Every hardware fact discovery reports is written; a fact the BMC did not report is left out.
            $lines.Add("      - name: $(ConvertTo-YamlString $p.Name) # key of this port in the file; the OS adapter name is found by MAC")
            $lines.Add("        mac_address: $(ConvertTo-YamlString $p.MacAddress)$(if ($p.LinkUp) { ' # link up' } else { '' })")
            $lines.Add("        slot: $(ConvertTo-YamlString $p.Slot)")
            $portIndex = Get-RfProp $p 'PortIndex'
            if ($null -ne $portIndex -and "$portIndex" -match '^\d+$') { $lines.Add("        port_index: $portIndex") }
            $pci = Get-RfProp $p 'PciLocation'
            if ($pci -and $null -ne (Get-RfProp $pci 'bus') -and $null -ne (Get-RfProp $pci 'device') -and $null -ne (Get-RfProp $pci 'function')) {
                $lines.Add("        pci_location: { bus: $((Get-RfProp $pci 'bus')), device: $((Get-RfProp $pci 'device')), function: $((Get-RfProp $pci 'function')) }")
            }
            $vendor = [string](Get-RfProp $p 'AdapterManufacturer' '')
            if ($vendor) { $lines.Add("        vendor: $(ConvertTo-YamlString $vendor)") }
            if ($p.AdapterModel) { $lines.Add("        model: $(ConvertTo-YamlString $p.AdapterModel)") }
            $linkMbps = Get-RfProp $p 'LinkSpeedMbps'
            $maxMbps = Get-RfProp $p 'MaxSpeedMbps'
            $speedMbps = if ($p.LinkUp -and $linkMbps) { $linkMbps } elseif ($maxMbps) { $maxMbps } else { $linkMbps }
            if ($speedMbps -and [double]$speedMbps -gt 0) {
                $speedSource = if ($p.LinkUp -and $linkMbps) { 'link speed now' } elseif ($maxMbps) { 'highest speed the port supports (no link now)' } else { 'last link speed reported' }
                $lines.Add("        speed_gbps: $(([double]$speedMbps / 1000).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)) # $speedSource, as the BMC reports it")
            }
            $rdma = [string](Get-RfProp $p 'Rdma' '')
            if ($rdma -in 'none', 'iwarp', 'roce', 'roce_v2') { $lines.Add("        rdma: $rdma") }
            if ($isMgmt) {
                $lines.Add("        roles: [management] # $($choice.Reason)$(if (-not $choice.Confirmed) { '; confirm' })")
                $lines.Add('        ip_assignment: dhcp_reservation # or static: set it from your management address mode')
            }
            else {
                $lines.Add('        roles: [unused] # set the real roles (compute, storage, provisioning)')
                $lines.Add('        ip_assignment: none')
            }
        }
        if (-not $choice.Port) { $lines.Add("    # No management port was suggested: $($choice.Reason).") }
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Set-AzlDellIdracVnc {
    <#
    .SYNOPSIS
        Enables or disables the iDRAC VNC server (VNCServer.1.* attributes). The only function here that writes to an iDRAC.
    .PARAMETER Password
        The VNC password (4 to 8 characters), only for third-party VNC clients. Left unchanged when omitted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$BmcAddress,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [ValidateSet('Enabled', 'Disabled')][string]$State = 'Enabled',
        [ValidateRange(1, 65535)][int]$Port = 5901,
        [ValidateRange(60, 10800)][int]$TimeoutSeconds = 1800,
        [SecureString]$Password,
        [switch]$VerifyCertificate
    )
    $path = "$script:ManagerPath/Attributes"
    $current = Invoke-AzlRedfish -BmcAddress $BmcAddress -Path $path -Credential $Credential -VerifyCertificate:$VerifyCertificate
    $attributes = Get-RfProp $current 'Attributes'
    $before = "$(Get-RfProp $attributes 'VNCServer.1.Enable' '?') port $(Get-RfProp $attributes 'VNCServer.1.Port' '?') timeout $(Get-RfProp $attributes 'VNCServer.1.Timeout' '?')s"
    $body = [ordered]@{ 'VNCServer.1.Enable' = $State; 'VNCServer.1.Port' = $Port; 'VNCServer.1.Timeout' = $TimeoutSeconds; 'VirtualConsole.1.AccessPrivilege' = 'Administrator' }
    if ($Password) {
        $plain = [System.Net.NetworkCredential]::new('', $Password).Password
        if ($plain.Length -lt 4 -or $plain.Length -gt 8) { throw 'The VNC password must be 4 to 8 characters (an iDRAC limit).' }
        $body['VNCServer.1.Password'] = $plain
    }
    $status = 'WhatIf'
    $note = ''
    if ($PSCmdlet.ShouldProcess($BmcAddress, "Set VNC $State on port $Port (timeout ${TimeoutSeconds}s)")) {
        $response = Invoke-AzlRedfish -BmcAddress $BmcAddress -Path $path -Credential $Credential -Method Patch -Body @{ Attributes = $body } -VerifyCertificate:$VerifyCertificate
        $status = 'Applied'
        $info = @(Get-RfProp $response '@Message.ExtendedInfo' @())
        if ($info.Count -gt 0) { $note = ($info | ForEach-Object { Get-RfProp $_ 'Message' '' }) -join ' ' }
    }
    return [pscustomobject]@{ BmcAddress = $BmcAddress; Status = $status; Before = $before; After = "$State port $Port timeout ${TimeoutSeconds}s"; PasswordSet = [bool]$Password; Note = $note }
}

Export-ModuleMember -Function ConvertTo-AzlMacAddress, Get-AzlBmcKeyVaultSecret, Resolve-AzlBmcCredential, Invoke-AzlRedfish, Select-AzlManagementPort, ConvertTo-AzlDiscoveryProposal, Set-AzlDellIdracVnc
