#Requires -Version 7.0
<#
.SYNOPSIS
    Dell iDRAC Redfish helpers: read-only hardware discovery for infrastructure.yml, and the iDRAC VNC setting.

.DESCRIPTION
    Hardware discovery is the first stage of the flow: it runs before azurelocal-ztp and before the OS configuration, and
    its output is what fills infrastructure.yml (service tag, the MAC of every network port, which port is the management
    port, the BOSS boot device). ZTP then finds the maintenance environment by the management MAC and maps the ownership
    vouchers by the serial number; the OS configuration finds every port by MAC.

    Invoke-AzlRedfish                One Redfish call (GET or PATCH). Every other function goes through it, so a test
                                     replaces this one function and no test needs an iDRAC.
    Resolve-AzlBmcCredential         The BMC login: -Credential, then the Key Vault references in infrastructure.yml, then a prompt.
    Get-AzlDellNodeDiscovery         Reads one iDRAC (GET only) and returns identity, BMC MAC, one entry per network port,
                                     storage and the BOSS card. Section failures are recorded in Warnings, never hidden.
    Get-AzlDellPortLabel             Redfish adapter and port IDs into the port name and slot infrastructure.yml uses.
    Select-AzlManagementPort         Which port is the management port, and why.
    ConvertTo-AzlDiscoveryProposal   The infrastructure.yml fragment (YAML text) for the operator to review.
    Set-AzlDellIdracVnc              Enables or disables the iDRAC VNC server (the only function that writes to an iDRAC).

    Nothing here stores or logs a password. Secrets come from Key Vault (keyvault://vault/secret) or a prompt.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ManagerPath = '/redfish/v1/Managers/iDRAC.Embedded.1'
$script:SystemPath = '/redfish/v1/Systems/System.Embedded.1'
$script:ChassisPath = '/redfish/v1/Chassis/System.Embedded.1'

function Get-RfProp {
    # Reads a property from a parsed object or a dictionary; $default when it is missing (safe under strict mode).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default } }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function ConvertTo-AzlMacAddress {
    <#
    .SYNOPSIS
        A MAC in any common notation into AA:BB:CC:DD:EE:FF. $null when it is not 12 hexadecimal digits.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12 -or $hex -ne ($Mac -replace '[:\-\.\s]', '').ToUpperInvariant()) { return $null }
    return (($hex -split '(?<=\G.{2})(?=.)') -join ':')
}

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

function Get-AzlBmcKeyVaultSecret {
    # One Key Vault read. A wrapper so a test replaces it and no vault is needed. The password stays a SecureString.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference, [switch]$AsPlainText)
    if ($Reference -notmatch '^keyvault://(?<vault>[^/]+)/(?<secret>[^/]+)$') { throw "'$Reference' isn't a keyvault://<vault>/<secret> reference." }
    if (-not (Get-Command Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) { throw 'Az.KeyVault is not installed (Install-Module Az.KeyVault), or run Connect-AzAccount first.' }
    if ($AsPlainText) { return [string](Get-AzKeyVaultSecret -VaultName $Matches['vault'] -Name $Matches['secret'] -AsPlainText) }
    return (Get-AzKeyVaultSecret -VaultName $Matches['vault'] -Name $Matches['secret']).SecretValue
}

function Resolve-AzlBmcCredential {
    <#
    .SYNOPSIS
        The BMC login. Order: -Credential, then Key Vault references in infrastructure.yml, then a prompt.
    .DESCRIPTION
        The file holds references only (schema 5: hardware.bmc, or nodes[].bmc, username and password as keyvault://vault/secret;
        a username may also be the plain user name). A node's bmc block wins over hardware.bmc. When Key Vault cannot be read,
        it warns (without the secret) and prompts, unless -NoPrompt.
    .PARAMETER Infrastructure
        The parsed infrastructure.yml (ordered dictionary), optional.
    .PARAMETER Node
        A nodes[] entry, optional.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [System.Collections.IDictionary]$Infrastructure,
        [System.Collections.IDictionary]$Node,
        [switch]$NoPrompt
    )
    if ($Credential) { return $Credential }
    $block = $null
    $nodeBmc = Get-RfProp $Node 'bmc'
    if ($nodeBmc -is [System.Collections.IDictionary] -and $nodeBmc.Contains('username') -and $nodeBmc.Contains('password')) { $block = $nodeBmc }
    if (-not $block) {
        $hardwareBmc = Get-RfProp (Get-RfProp $Infrastructure 'hardware') 'bmc'
        if ($hardwareBmc -is [System.Collections.IDictionary] -and $hardwareBmc.Contains('username') -and $hardwareBmc.Contains('password')) { $block = $hardwareBmc }
    }
    $userHint = $null
    if ($block) {
        try {
            $user = [string]$block['username']
            if ($user -like 'keyvault://*') { $user = Get-AzlBmcKeyVaultSecret -Reference $user -AsPlainText }
            $userHint = $user
            $password = Get-AzlBmcKeyVaultSecret -Reference ([string]$block['password'])
            return [System.Management.Automation.PSCredential]::new($user, $password)
        }
        catch {
            Write-Warning "The BMC credential could not be read from Key Vault: $($_.Exception.Message)"
        }
    }
    if ($NoPrompt) { throw 'No BMC credential: pass -Credential, or put hardware.bmc username and password (keyvault:// references) in infrastructure.yml.' }
    $prompt = @{ Message = 'iDRAC administrator credentials' }
    if ($userHint) { $prompt.UserName = $userHint }
    return (Get-Credential @prompt)
}

function Get-RfMember {
    # The detail object of every member of a collection. A failure is recorded as a warning, never swallowed.
    param($Context, [string]$Path, [string]$Section)
    $result = [System.Collections.Generic.List[object]]::new()
    try { $collection = Invoke-AzlRedfish -BmcAddress $Context.BmcAddress -Path $Path -Credential $Context.Credential -VerifyCertificate:$Context.VerifyCertificate }
    catch { $Context.Warnings.Add("${Section}: collection $Path failed: $($_.Exception.Message)"); return $result }
    foreach ($m in @(Get-RfProp $collection 'Members' @())) {
        $link = [string](Get-RfProp $m '@odata.id' '')
        if (-not $link) { continue }
        try { $result.Add((Invoke-AzlRedfish -BmcAddress $Context.BmcAddress -Path $link -Credential $Context.Credential -VerifyCertificate:$Context.VerifyCertificate)) }
        catch { $Context.Warnings.Add("${Section}: $link failed: $($_.Exception.Message)") }
    }
    return $result
}

function Get-RfOptional {
    param($Context, [string]$Path, [string]$Section)
    try { return Invoke-AzlRedfish -BmcAddress $Context.BmcAddress -Path $Path -Credential $Context.Credential -VerifyCertificate:$Context.VerifyCertificate }
    catch { $Context.Warnings.Add("${Section}: $Path failed: $($_.Exception.Message)"); return $null }
}

function Get-AzlDellPortLabel {
    <#
    .SYNOPSIS
        The port name and slot infrastructure.yml uses, from the Redfish adapter ID and port ID.
    .DESCRIPTION
        NIC.Slot.3 + port 1 is 'Slot 3 Port 1' (slot 'Slot 3'); NIC.Embedded.2 is 'Embedded NIC 2' (slot 'Embedded', the
        value azurelocal-ztp reads to enable the embedded NICs); NIC.Integrated.1 + port 2 is 'Integrated NIC 1 Port 2'.
        The names are a suggestion: networking intents name ports by them, so keep one name per port on every node.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$AdapterId, [string]$PortId = '')
    $portNumber = 1
    if ($PortId -match '-(\d+)(-\d+)?$') { $portNumber = [int]$Matches[1] }
    if ($AdapterId -match '^NIC\.Slot\.(\d+)') { return [pscustomobject]@{ Name = "Slot $($Matches[1]) Port $portNumber"; Slot = "Slot $($Matches[1])" } }
    if ($AdapterId -match '^NIC\.Embedded\.(\d+)') { return [pscustomobject]@{ Name = "Embedded NIC $($Matches[1])"; Slot = 'Embedded' } }
    if ($AdapterId -match '^NIC\.Integrated\.(\d+)') { return [pscustomobject]@{ Name = "Integrated NIC $($Matches[1]) Port $portNumber"; Slot = "Integrated $($Matches[1])" } }
    $fallback = if ($PortId) { $PortId } else { $AdapterId }
    return [pscustomobject]@{ Name = $fallback; Slot = $AdapterId }
}

function Get-RfPortMac {
    param($Port, $Function)
    foreach ($candidate in @(Get-RfProp $Port 'AssociatedNetworkAddresses' @()) + @(Get-RfProp $Port 'MACAddress')) {
        $mac = ConvertTo-AzlMacAddress ([string]$candidate)
        if ($mac) { return [pscustomobject]@{ Mac = $mac; Source = 'Port' } }
    }
    $ethernet = Get-RfProp $Function 'Ethernet'
    foreach ($name in 'MACAddress', 'PermanentMACAddress') {
        $mac = ConvertTo-AzlMacAddress ([string](Get-RfProp $ethernet $name ''))
        if ($mac) { return [pscustomobject]@{ Mac = $mac; Source = 'Function' } }
    }
    return $null
}

function Get-RfNetworkPort {
    param($Context)
    $ports = [System.Collections.Generic.List[object]]::new()
    foreach ($adapter in (Get-RfMember $Context "$script:SystemPath/NetworkAdapters" 'NetworkAdapters')) {
        $adapterId = [string](Get-RfProp $adapter 'Id' '')
        $portLink = [string](Get-RfProp (Get-RfProp $adapter 'NetworkPorts') '@odata.id' (Get-RfProp (Get-RfProp $adapter 'Ports') '@odata.id' ''))
        $functionLink = [string](Get-RfProp (Get-RfProp $adapter 'NetworkDeviceFunctions') '@odata.id' '')
        $portDetails = if ($portLink) { @(Get-RfMember $Context $portLink "NetworkAdapters/$adapterId ports") } else { @() }
        $functions = if ($functionLink) { @(Get-RfMember $Context $functionLink "NetworkAdapters/$adapterId functions") } else { @() }
        $controller = @(Get-RfProp $adapter 'Controllers' @()) | Select-Object -First 1
        if ($portDetails.Count -eq 0) {
            # Some firmware lists only functions (one per port): build the ports from them.
            $portDetails = @($functions | ForEach-Object { [pscustomobject]@{ Id = (Get-RfProp $_ 'Id' ''); LinkStatus = $null; CurrentLinkSpeedMbps = $null; PhysicalPortNumber = $null } })
        }
        foreach ($port in $portDetails) {
            $portId = [string](Get-RfProp $port 'Id' '')
            $function = $functions | Where-Object { $id = [string](Get-RfProp $_ 'Id' ''); $portId -and ($id -eq $portId -or $id -like "$portId-*") } | Select-Object -First 1
            $mac = Get-RfPortMac -Port $port -Function $function
            if (-not $mac) { $Context.Warnings.Add("NetworkAdapters: port $portId of $adapterId has no MAC in Redfish."); continue }
            $label = Get-AzlDellPortLabel -AdapterId $adapterId -PortId $portId
            $link = [string](Get-RfProp $port 'LinkStatus' '')
            $ports.Add([ordered]@{
                    Name               = $label.Name
                    Slot               = $label.Slot
                    MacAddress         = $mac.Mac
                    MacSource          = $mac.Source
                    AdapterId          = $adapterId
                    PortId             = $portId
                    AdapterModel       = [string](Get-RfProp $adapter 'Model' '')
                    AdapterManufacturer = [string](Get-RfProp $adapter 'Manufacturer' '')
                    FirmwarePackage    = [string](Get-RfProp $controller 'FirmwarePackageVersion' '')
                    LinkStatus         = $link
                    LinkUp             = ($link -in @('Up', 'LinkUp'))
                    LinkSpeedMbps      = Get-RfProp $port 'CurrentLinkSpeedMbps'
                    PhysicalPortNumber = Get-RfProp $port 'PhysicalPortNumber'
                })
        }
    }
    # Port names must be unique on a machine.
    $seen = @{}
    foreach ($p in $ports) {
        $key = $p.Name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $seen[$key]++; $p.Name = "$($p.Name) ($($seen[$key]))" } else { $seen[$key] = 1 }
    }
    return , @($ports | Sort-Object { $_.AdapterId }, { $_.PortId })
}

function Get-RfStorage {
    param($Context)
    $controllers = [System.Collections.Generic.List[object]]::new()
    foreach ($storage in (Get-RfMember $Context "$script:SystemPath/Storage" 'Storage')) {
        $id = [string](Get-RfProp $storage 'Id' '')
        $sc = @(Get-RfProp $storage 'StorageControllers' @()) | Select-Object -First 1
        $drives = @(foreach ($d in @(Get-RfProp $storage 'Drives' @())) {
            $link = [string](Get-RfProp $d '@odata.id' '')
            if (-not $link) { continue }
            $detail = Get-RfOptional $Context $link "Storage/$id drive"
            if ($detail) {
                [ordered]@{
                    Id = [string](Get-RfProp $detail 'Id' ''); Name = [string](Get-RfProp $detail 'Name' ''); Model = [string](Get-RfProp $detail 'Model' '')
                    Manufacturer = [string](Get-RfProp $detail 'Manufacturer' ''); SerialNumber = [string](Get-RfProp $detail 'SerialNumber' '')
                    CapacityBytes = Get-RfProp $detail 'CapacityBytes'; MediaType = [string](Get-RfProp $detail 'MediaType' ''); Protocol = [string](Get-RfProp $detail 'Protocol' '')
                    Health = [string](Get-RfProp (Get-RfProp $detail 'Status') 'Health' '')
                }
            }
        })
        $volumeLink = [string](Get-RfProp (Get-RfProp $storage 'Volumes') '@odata.id' '')
        $volumes = @(if ($volumeLink) {
            foreach ($v in (Get-RfMember $Context $volumeLink "Storage/$id volumes")) {
                [ordered]@{
                    Id = [string](Get-RfProp $v 'Id' ''); Name = [string](Get-RfProp $v 'Name' ''); RaidType = [string](Get-RfProp $v 'RAIDType' '')
                    VolumeType = [string](Get-RfProp $v 'VolumeType' ''); CapacityBytes = Get-RfProp $v 'CapacityBytes'
                    Health = [string](Get-RfProp (Get-RfProp $v 'Status') 'Health' '')
                }
            }
        })
        $controllers.Add([ordered]@{
                Id = $id; Name = [string](Get-RfProp $storage 'Name' ''); Model = [string](Get-RfProp $sc 'Model' '')
                Manufacturer = [string](Get-RfProp $sc 'Manufacturer' ''); FirmwareVersion = [string](Get-RfProp $sc 'FirmwareVersion' '')
                Drives = @($drives); Volumes = @($volumes)
            })
    }
    return , @($controllers)
}

function Get-RfBoss {
    # The BOSS (Boot Optimized Storage Solution) card: its M.2 drives and whether a virtual disk exists on it.
    param($Controllers)
    $match = $Controllers | Where-Object { "$($_.Id) $($_.Name) $($_.Model)" -match 'BOSS' } | Select-Object -First 1
    $how = 'name'
    if (-not $match) { $match = $Controllers | Where-Object { $_.Id -match '^AHCI\.' } | Select-Object -First 1; $how = 'controller-id' }
    if (-not $match) { return [ordered]@{ Present = $false; ControllerId = $null; ControllerName = $null; Detection = $null; DriveCount = 0; Drives = @(); Volumes = @(); HasVirtualDisk = $false; NeedsVirtualDisk = $false } }
    return [ordered]@{
        Present          = $true
        ControllerId     = $match.Id
        ControllerName   = $match.Name
        Detection        = $how
        DriveCount       = @($match.Drives).Count
        Drives           = @($match.Drives)
        Volumes          = @($match.Volumes)
        HasVirtualDisk   = (@($match.Volumes).Count -gt 0)
        NeedsVirtualDisk = (@($match.Volumes).Count -eq 0)
    }
}

function Get-AzlDellNodeDiscovery {
    <#
    .SYNOPSIS
        Reads one Dell iDRAC (GET only) and returns what infrastructure.yml needs.
    .DESCRIPTION
        Identity (service tag = Redfish SKU, the value Dell uses as the serial for Azure ownership vouchers), the BMC's MAC, one
        entry in NetworkPorts per physical port (name, slot, MAC, link, speed), storage and Boss. With -Detail Full it also
        reads chassis, power, thermal, PCIe, processors, memory, firmware and every BIOS and iDRAC attribute (the input of the
        BIOS and iDRAC settings tasks). A failed optional section is added to Warnings; a system that cannot be read throws.
    .PARAMETER BmcAddress
        The iDRAC address.
    .EXAMPLE
        $cred = Get-Credential
        Get-AzlDellNodeDiscovery -BmcAddress '<idrac-address>' -Credential $cred | ConvertTo-Json -Depth 10
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$BmcAddress,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [ValidateSet('Summary', 'Full')][string]$Detail = 'Full',
        [switch]$VerifyCertificate
    )
    $context = @{ BmcAddress = $BmcAddress; Credential = $Credential; VerifyCertificate = $VerifyCertificate.IsPresent; Warnings = [System.Collections.Generic.List[string]]::new() }
    $system = Invoke-AzlRedfish -BmcAddress $BmcAddress -Path $script:SystemPath -Credential $Credential -VerifyCertificate:$VerifyCertificate
    $serviceTag = [string](Get-RfProp $system 'SKU' '')
    if (-not $serviceTag) { $context.Warnings.Add('System: SKU (the service tag) is empty.') }

    $bmcInterfaces = @(foreach ($e in (Get-RfMember $context "$script:ManagerPath/EthernetInterfaces" 'BMC interfaces')) {
        $mac = ConvertTo-AzlMacAddress ([string](Get-RfProp $e 'MACAddress' (Get-RfProp $e 'PermanentMACAddress' '')))
        [ordered]@{ Id = [string](Get-RfProp $e 'Id' ''); MacAddress = $mac; SpeedMbps = Get-RfProp $e 'SpeedMbps' }
    })
    $ports = Get-RfNetworkPort $context
    $controllers = Get-RfStorage $context
    $result = [ordered]@{
        SchemaVersion = '1.0'
        CollectedAt   = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        BmcAddress    = $BmcAddress
        Identity      = [ordered]@{
            ServiceTag   = $serviceTag
            SerialNumber = [string](Get-RfProp $system 'SerialNumber' '')
            Model        = [string](Get-RfProp $system 'Model' '')
            Manufacturer = [string](Get-RfProp $system 'Manufacturer' '')
            Uuid         = [string](Get-RfProp $system 'UUID' '')
            HostName     = [string](Get-RfProp $system 'HostName' '')
            BiosVersion  = [string](Get-RfProp $system 'BiosVersion' '')
            PowerState   = [string](Get-RfProp $system 'PowerState' '')
        }
        Bmc           = [ordered]@{ Address = $BmcAddress; MacAddress = (@($bmcInterfaces) | Select-Object -First 1 | ForEach-Object { $_.MacAddress }); Interfaces = @($bmcInterfaces) }
        Processors    = [ordered]@{ Count = Get-RfProp (Get-RfProp $system 'ProcessorSummary') 'Count'; Model = [string](Get-RfProp (Get-RfProp $system 'ProcessorSummary') 'Model' '') }
        MemoryGiB     = Get-RfProp (Get-RfProp $system 'MemorySummary') 'TotalSystemMemoryGiB'
        NetworkPorts  = @($ports)
        Storage       = [ordered]@{ Controllers = @($controllers) }
        Boss          = Get-RfBoss $controllers
    }
    if ($Detail -eq 'Full') {
        $chassis = Get-RfOptional $context $script:ChassisPath 'Chassis'
        $result.Chassis = [ordered]@{ Model = [string](Get-RfProp $chassis 'Model' ''); SerialNumber = [string](Get-RfProp $chassis 'SerialNumber' ''); AssetTag = [string](Get-RfProp $chassis 'AssetTag' '') }
        $result.Power = Get-RfOptional $context "$script:ChassisPath/Power" 'Power'
        $result.Thermal = Get-RfOptional $context "$script:ChassisPath/Thermal" 'Thermal'
        $result.ProcessorDetails = @(Get-RfMember $context "$script:SystemPath/Processors" 'Processors')
        $result.MemoryModules = @(Get-RfMember $context "$script:SystemPath/Memory" 'Memory')
        $result.PcieDevices = @(Get-RfMember $context "$script:SystemPath/PCIeDevices" 'PCIeDevices')
        $result.Firmware = @(Get-RfMember $context '/redfish/v1/UpdateService/FirmwareInventory' 'Firmware')
        $result.BiosAttributes = Get-RfProp (Get-RfOptional $context "$script:SystemPath/Bios" 'BIOS') 'Attributes'
        $result.BmcAttributes = Get-RfProp (Get-RfOptional $context "$script:ManagerPath/Attributes" 'iDRAC attributes') 'Attributes'
    }
    $result.Warnings = @($context.Warnings)
    return $result
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
            $lines.Add("      - name: $(ConvertTo-YamlString $p.Name)")
            $lines.Add("        slot: $(ConvertTo-YamlString $p.Slot)")
            $lines.Add("        mac_address: $(ConvertTo-YamlString $p.MacAddress)$(if ($p.LinkUp) { ' # link up' } else { '' })")
            if ($p.AdapterModel) { $lines.Add("        model: $(ConvertTo-YamlString $p.AdapterModel)") }
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

Export-ModuleMember -Function ConvertTo-AzlMacAddress, Invoke-AzlRedfish, Get-AzlBmcKeyVaultSecret, Resolve-AzlBmcCredential, Get-AzlDellPortLabel, Get-AzlDellNodeDiscovery, Select-AzlManagementPort, ConvertTo-AzlDiscoveryProposal, Set-AzlDellIdracVnc
