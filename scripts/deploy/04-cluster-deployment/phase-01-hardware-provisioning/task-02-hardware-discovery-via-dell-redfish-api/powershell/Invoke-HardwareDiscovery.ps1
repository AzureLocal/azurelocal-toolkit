#Requires -Version 7.0
<#
.SYNOPSIS
    Invoke-HardwareDiscovery.ps1
    Full hardware discovery via Dell iDRAC Redfish API.

.DESCRIPTION
    Runs from the management server. Reads node list and iDRAC IPs from
    infrastructure.yml, connects to each iDRAC via Redfish API, and collects:

    SYSTEM
      - Manufacturer, Model, SKU (service tag), SerialNumber, UUID, HostName
      - BiosVersion, PowerState, IndicatorLED, Status
      - ProcessorSummary, MemorySummary

    CHASSIS
      - Model, SerialNumber, AssetTag, ChassisType, Manufacturer

    PROCESSORS
      - Per-socket: Model, Manufacturer, Socket, TotalCores, TotalThreads,
        MaxSpeedMHz, ProcessorType, ProcessorArchitecture, InstructionSet,
        Microcode, Status

    MEMORY DIMMs
      - Per-slot: Name, MemoryDeviceType, CapacityMiB, OperatingSpeedMhz,
        Manufacturer, PartNumber, SerialNumber, DataWidthBits, RankCount,
        Status, DeviceLocator

    NETWORK ADAPTERS
      - Per-adapter: Manufacturer, Model, PartNumber, SerialNumber, Id
      - Per-port: MAC address, LinkStatus, SpeedMbps, PhysicalPortNumber

    NETWORK INTERFACES
      - Per-interface: Id, MACAddress, SpeedMbps, Status

    iDRAC ETHERNET INTERFACES
      - All interfaces: MACAddress, SpeedMbps, FQDN, IPv4, IPv6, VLAN

    STORAGE
      - Per-controller: Model, Manufacturer, FirmwareVersion, Status, SupportedDeviceProtocols
      - Per-physical-disk: Name, Model, Manufacturer, SerialNumber, CapacityBytes,
        RotationSpeedRPM, Protocol, MediaType, CapableSpeedGbs, Status
      - Per-volume: Name, VolumeType, RAIDType, CapacityBytes, Status, Drives

    PCIe DEVICES
      - Per-device: Id, Name, Manufacturer, DeviceType, PCIeInterface (speed/lanes/version)

    FIRMWARE INVENTORY
      - All components: Name, Id, Version, Updateable, SoftwareId

    POWER
      - PowerControl: PowerCapacityWatts, PowerConsumedWatts
      - Per-PSU: Name, Model, Manufacturer, SerialNumber, FirmwareVersion,
        LastPowerOutputWatts, StatusHealth, InputVoltage, PowerSupplyType

    THERMAL
      - Per-fan: Name, ReadingRPM, LowerThresholdCritical, Status
      - Per-temperature: Name, ReadingCelsius, UpperThresholdCritical, PhysicalContext

    BIOS ATTRIBUTES
      - Full dump of all BIOS settings

    iDRAC ATTRIBUTES
      - Full dump of all iDRAC settings

    Output JSON files saved to config/network-devices/bmc/<ServiceTag>.json.
    Optionally calls Update-InfrastructureYml-FromDiscovery.ps1 on completion.

    CREDENTIAL RESOLUTION ORDER
    ---------------------------
    1. -iDRACUsername / -iDRACPassword parameters (if both supplied)
    2. Key Vault reference in infrastructure.yml
           username: security.infrastructure_credentials.idrac.username
           password: security.infrastructure_credentials.idrac.password_secret (keyvault://<vault>/<secret>)
    3. Interactive prompt (fallback)

.PARAMETER ConfigPath
    Path to infrastructure.yml. If not specified, auto-detected from .\configs\.

.PARAMETER OutputPath
    Path to save discovery JSON files. Default: .\configs\network-devices\bmc

.PARAMETER iDRACUsername
    iDRAC admin username.

.PARAMETER iDRACPassword
    iDRAC admin password as a SecureString.

.PARAMETER SkipYmlUpdate
    Skip the automatic infrastructure.yml update step after discovery.

.PARAMETER Force
    Skip the confirmation prompt in the yml update step.

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 2.0.0
    Phase: 01-hardware-provisioning
    Task: task-02-hardware-discovery-via-dell-redfish-api
    Prerequisites: PowerShell 7+, powershell-yaml module, iDRAC network access (port 443)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string]$ConfigPath,
    [Parameter(Mandatory = $false)] [string]$OutputPath = ".\configs\network-devices\bmc",
    [Parameter(Mandatory = $false)] [string]$iDRACUsername,
    [Parameter(Mandatory = $false)] [SecureString]$iDRACPassword,
    [Parameter(Mandatory = $false)] [switch]$SkipYmlUpdate,
    [Parameter(Mandatory = $false)] [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER"  { "Cyan" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Resolve-ConfigPath {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "Config file not found: $ExplicitPath" }
        Write-Log "Using specified config: $ExplicitPath"
        return $ExplicitPath
    }

    $candidates = Get-ChildItem -Path ".\configs\" -Filter "infrastructure*.yml" -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No infrastructure*.yml files found in .\configs\. Specify -ConfigPath explicitly."
    }
    if ($candidates.Count -eq 1) {
        Write-Log "Auto-detected config: $($candidates[0].FullName)"
        return $candidates[0].FullName
    }

    Write-Host "`nMultiple infrastructure config files found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $label = if ($candidates[$i].Name -eq "infrastructure.yml") { " [DEFAULT]" } else { "" }
        Write-Host "  [$($i + 1)] $($candidates[$i].Name)$label" -ForegroundColor White
    }
    $defIdx = [array]::IndexOf(($candidates | ForEach-Object { $_.Name }), "infrastructure.yml")
    if ($defIdx -lt 0) { $defIdx = 0 }
    $selection = Read-Host "`nSelect config file number (Enter = $($candidates[$defIdx].Name))"
    if ([string]::IsNullOrWhiteSpace($selection)) { return $candidates[$defIdx].FullName }
    $idx = [int]$selection - 1
    if ($idx -lt 0 -or $idx -ge $candidates.Count) { throw "Invalid selection '$selection'." }
    return $candidates[$idx].FullName
}

function Resolve-KeyVaultRef {
    param([string]$KvUri, [string]$SubscriptionId)

    if ($KvUri -notmatch '^keyvault://([^/]+)/(.+)$') {
        Write-Log "  Not a Key Vault URI: $KvUri" "WARN"; return $null
    }
    $vaultName  = $Matches[1]
    $secretName = $Matches[2]

    if (Get-Module -Name Az.KeyVault -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Write-Log "  Retrieving secret '$secretName' from Key Vault '$vaultName' (Az.KeyVault)..."
            $kvArgs = @{ VaultName = $vaultName; Name = $secretName; ErrorAction = 'Stop' }
            if ($SubscriptionId) { $kvArgs.SubscriptionId = $SubscriptionId }
            $secret = Get-AzKeyVaultSecret @kvArgs
            if ($secret) { Write-Log "  Key Vault secret retrieved." "SUCCESS"; return $secret.SecretValue }
            Write-Log "  Az.KeyVault returned no secret." "WARN"
        } catch { Write-Log "  Az.KeyVault failed: $_" "WARN" }
        Write-Log "  Falling back to Azure CLI..." "WARN"
    } else {
        Write-Log "  Az.KeyVault module not found — trying Azure CLI..." "WARN"
    }

    try {
        $azCmd = Get-Command az -ErrorAction SilentlyContinue
        if (-not $azCmd) { Write-Log "  Azure CLI (az) not found." "WARN"; return $null }
        Write-Log "  Retrieving secret '$secretName' from Key Vault '$vaultName' (az CLI)..."
        $azArgs = @("keyvault","secret","show","--vault-name",$vaultName,"--name",$secretName,"--query","value","--output","tsv","--only-show-errors")
        if ($SubscriptionId) { $azArgs += @("--subscription", $SubscriptionId) }
        $tmpErr      = [System.IO.Path]::GetTempFileName()
        $secretValue = (& az @azArgs 2>$tmpErr)
        $azError     = (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue)
        if ($azError) { $azError = $azError.Trim() }
        Remove-Item $tmpErr -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretValue)) {
            if (-not [string]::IsNullOrWhiteSpace($azError)) { Write-Log "  az CLI KV error: $azError" "WARN" }
            else { Write-Log "  az CLI KV returned no value (exit $LASTEXITCODE)." "WARN" }
            return $null
        }
        Write-Log "  Key Vault secret retrieved (az CLI)." "SUCCESS"
        return ConvertTo-SecureString $secretValue -AsPlainText -Force
    } catch { Write-Log "  az CLI KV failed: $_" "WARN"; return $null }
}

function Resolve-iDRACCredential {
    param([string]$ParamUsername, [SecureString]$ParamPassword, [hashtable]$Config)

    $resolvedUsername = $null
    $resolvedPassword = $null

    if (-not [string]::IsNullOrWhiteSpace($ParamUsername) -and $null -ne $ParamPassword) {
        Write-Log "Credential source: command-line parameters" "SUCCESS"
        return New-Object System.Management.Automation.PSCredential($ParamUsername, $ParamPassword)
    }
    if (-not [string]::IsNullOrWhiteSpace($ParamUsername)) { $resolvedUsername = $ParamUsername }
    if ($null -ne $ParamPassword)                          { $resolvedPassword = $ParamPassword }

    if (-not $resolvedUsername -or -not $resolvedPassword) {
        Write-Log "Resolving credentials from infrastructure.yml / Key Vault..."
        if (-not $resolvedUsername) {
            try {
                $cfgUsername = $Config.security.infrastructure_credentials.idrac.username
                if (-not [string]::IsNullOrWhiteSpace($cfgUsername)) { $resolvedUsername = $cfgUsername; Write-Log "  Username from config: $resolvedUsername" }
            } catch { Write-Log "  Could not read idrac.username: $_" "WARN" }
        }
        if (-not $resolvedPassword) {
            try {
                $kvRef = $Config.security.infrastructure_credentials.idrac.password_secret
                if (-not [string]::IsNullOrWhiteSpace($kvRef)) {
                    Write-Log "  KV ref: $kvRef"
                    $secureVal = Resolve-KeyVaultRef -KvUri $kvRef -SubscriptionId $Config.azure_platform.subscriptions.lab.id
                    if ($secureVal) {
                        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureVal)
                        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                        $idx = $plain.IndexOf(":")
                        if ($idx -gt 0) {
                            if (-not $resolvedUsername) { $resolvedUsername = $plain.Substring(0, $idx); Write-Log "  Username from KV: $resolvedUsername" }
                            $resolvedPassword = ConvertTo-SecureString $plain.Substring($idx + 1) -AsPlainText -Force
                        } else {
                            $resolvedPassword = $secureVal
                        }
                        Write-Log "  Credentials retrieved from Key Vault." "SUCCESS"
                    }
                } else { Write-Log "  idrac.password_secret not set in config." "WARN" }
            } catch { Write-Log "  KV credential resolution failed: $_" "WARN" }
        }
    }

    if (-not $resolvedUsername) {
        Write-Log "Prompting for iDRAC username..." "WARN"
        $resolvedUsername = Read-Host "Enter iDRAC username"
        if ([string]::IsNullOrWhiteSpace($resolvedUsername)) { throw "iDRAC username is required." }
    }
    if (-not $resolvedPassword) {
        Write-Log "Prompting for iDRAC password..." "WARN"
        $resolvedPassword = Read-Host "Enter iDRAC password for '$resolvedUsername'" -AsSecureString
    }

    return New-Object System.Management.Automation.PSCredential($resolvedUsername, $resolvedPassword)
}

function Invoke-RedfishGet {
    param([string]$Uri, [PSCredential]$Credential)
    return Invoke-RestMethod -Uri $Uri -Credential $Credential -SkipCertificateCheck `
        -ContentType "application/json" -ErrorAction Stop
}

function Invoke-RedfishDrillCollection {
    <#
    Fetches every member of a Redfish collection and returns an array of
    the drilled detail objects.  Failures per-member are logged as WARN,
    not fatal.
    #>
    param(
        [string]$CollectionUri,
        [string]$iDRACIP,
        [PSCredential]$Credential,
        [string]$Label = "item"
    )
    $results = @()
    try {
        $col = Invoke-RedfishGet $CollectionUri $Credential
        if (-not $col.Members) { return $results }
        foreach ($member in $col.Members) {
            $memberPath = $member.'@odata.id'
            if (-not $memberPath) { continue }
            $memberUri = if ($memberPath -match '^https?://') { $memberPath } else { "https://$iDRACIP$memberPath" }
            try {
                $detail = Invoke-RedfishGet $memberUri $Credential
                $results += $detail
            } catch {
                Write-Log "    $Label $(($memberPath -split '/')[-1]) detail failed: $_" "WARN"
            }
        }
    } catch {
        Write-Log "  Collection $Label failed: $_" "WARN"
    }
    return $results
}

function Get-NodeInventory {
    param([string]$NodeName, [string]$iDRACIP, [PSCredential]$Credential)

    Write-Log "=== Discovering: $NodeName ($iDRACIP) ===" "HEADER"
    $base     = "https://$iDRACIP/redfish/v1"
    $chassis  = "https://$iDRACIP/redfish/v1/Chassis/System.Embedded.1"
    $systems  = "https://$iDRACIP/redfish/v1/Systems/System.Embedded.1"
    $managers = "https://$iDRACIP/redfish/v1/Managers/iDRAC.Embedded.1"

    $inventory = @{
        NodeName    = $NodeName
        iDRACIP     = $iDRACIP
        CollectedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }

    # ----------------------------------------------------------
    # SYSTEM
    # ----------------------------------------------------------
    try {
        Write-Log "  [System] Collecting system info..."
        $inventory.System = Invoke-RedfishGet $systems $Credential
        Write-Log "  [System] Service Tag: $($inventory.System.SKU)" "SUCCESS"
    } catch { Write-Log "  [System] FAILED: $_" "ERROR"; return $null }

    # ----------------------------------------------------------
    # CHASSIS
    # ----------------------------------------------------------
    try {
        Write-Log "  [Chassis] Collecting chassis info..."
        $inventory.Chassis = Invoke-RedfishGet $chassis $Credential
        Write-Log "  [Chassis] Model: $($inventory.Chassis.Model)"
    } catch { Write-Log "  [Chassis] Failed: $_" "WARN" }

    # ----------------------------------------------------------
    # PROCESSORS
    # ----------------------------------------------------------
    Write-Log "  [Processors] Collecting per-socket processor details..."
    $inventory.Processors = @(Invoke-RedfishDrillCollection "$systems/Processors" $iDRACIP $Credential "processor")
    Write-Log "  [Processors] Found: $($inventory.Processors.Count) socket(s)"

    # ----------------------------------------------------------
    # MEMORY DIMMs
    # ----------------------------------------------------------
    Write-Log "  [Memory] Collecting per-DIMM memory details..."
    $inventory.MemoryDIMMs = @(Invoke-RedfishDrillCollection "$systems/Memory" $iDRACIP $Credential "dimm")
    $populated = @($inventory.MemoryDIMMs | Where-Object { $_.Status.State -ne 'Absent' -and $_.CapacityMiB -gt 0 })
    Write-Log "  [Memory] Found: $($populated.Count) populated DIMM(s) of $($inventory.MemoryDIMMs.Count) slot(s)"

    # ----------------------------------------------------------
    # NETWORK ADAPTERS (MACs + adapter detail)
    # ----------------------------------------------------------
    Write-Log "  [NetworkAdapters] Collecting adapter and port details..."
    $networkAdapters = @{}
    try {
        $adaptersCol = Invoke-RedfishGet "$systems/NetworkAdapters" $Credential
        foreach ($adMember in $adaptersCol.Members) {
            $adPath    = $adMember.'@odata.id'
            $adapterId = ($adPath -split '/')[-1]
            $adUri     = if ($adPath -match '^https?://') { $adPath } else { "https://$iDRACIP$adPath" }
            try {
                $adDetail = Invoke-RedfishGet $adUri $Credential

                $adInfo = @{
                    Id           = $adDetail.Id
                    Manufacturer = $adDetail.Manufacturer
                    Model        = $adDetail.Model
                    PartNumber   = $adDetail.PartNumber
                    SerialNumber = $adDetail.SerialNumber
                    Ports        = @{}
                }

                # Ports / NetworkPorts
                $portsLink = $null
                if ($adDetail.NetworkPorts) { $portsLink = $adDetail.NetworkPorts.'@odata.id' }
                if (-not $portsLink -and $adDetail.Ports) { $portsLink = $adDetail.Ports.'@odata.id' }
                if ($portsLink) {
                    $portsUri = if ($portsLink -match '^https?://') { $portsLink } else { "https://$iDRACIP$portsLink" }
                    $portsCol = Invoke-RedfishGet $portsUri $Credential
                    foreach ($pMember in $portsCol.Members) {
                        $pPath  = $pMember.'@odata.id'
                        $portId = ($pPath -split '/')[-1]
                        $pUri   = if ($pPath -match '^https?://') { $pPath } else { "https://$iDRACIP$pPath" }
                        try {
                            $pDetail = Invoke-RedfishGet $pUri $Credential
                            $mac     = $null
                            if ($pDetail.AssociatedNetworkAddresses) { $mac = $pDetail.AssociatedNetworkAddresses[0] }
                            elseif ($pDetail.MACAddress)             { $mac = $pDetail.MACAddress }
                            $adInfo.Ports[$portId] = @{
                                MAC                 = $mac
                                LinkStatus          = $pDetail.LinkStatus
                                SpeedMbps           = $pDetail.CurrentLinkSpeedMbps
                                PhysicalPortNumber  = $pDetail.PhysicalPortNumber
                            }
                            Write-Log "    $adapterId / $portId : $mac  ($($pDetail.LinkStatus))"
                        } catch { Write-Log "    Port $adapterId/$portId failed: $_" "WARN" }
                    }
                }

                Write-Log "    Adapter $adapterId : $($adDetail.Manufacturer) $($adDetail.Model)"
                $networkAdapters[$adapterId] = $adInfo
            } catch { Write-Log "    Adapter $adapterId failed: $_" "WARN" }
        }
    } catch { Write-Log "  [NetworkAdapters] Collection failed: $_" "WARN" }
    $inventory.NetworkAdapters = $networkAdapters

    # ----------------------------------------------------------
    # NETWORK INTERFACES
    # ----------------------------------------------------------
    Write-Log "  [NetworkInterfaces] Collecting network interface details..."
    $inventory.NetworkInterfaces = @(Invoke-RedfishDrillCollection "$systems/NetworkInterfaces" $iDRACIP $Credential "network-interface")
    Write-Log "  [NetworkInterfaces] Found: $($inventory.NetworkInterfaces.Count)"

    # ----------------------------------------------------------
    # iDRAC ETHERNET INTERFACES (all ports)
    # ----------------------------------------------------------
    Write-Log "  [iDRAC Ethernet] Collecting all iDRAC ethernet interfaces..."
    $idracEthInterfaces = @(Invoke-RedfishDrillCollection "$managers/EthernetInterfaces" $iDRACIP $Credential "idrac-eth")
    $inventory.iDRACEthernetInterfaces = $idracEthInterfaces
    # Legacy fields for backwards compat with updater
    $inventory.iDRAC_MAC = if ($idracEthInterfaces.Count -gt 0) { $idracEthInterfaces[0].MACAddress } else { $null }
    Write-Log "  [iDRAC Ethernet] Found: $($idracEthInterfaces.Count) interface(s)"

    # ----------------------------------------------------------
    # STORAGE (controllers -> drives -> volumes)
    # ----------------------------------------------------------
    Write-Log "  [Storage] Collecting storage controllers, drives, and volumes..."
    $storageInventory = @{}
    try {
        $storageCol = Invoke-RedfishGet "$systems/Storage" $Credential
        foreach ($ctrlMember in $storageCol.Members) {
            $ctrlPath = $ctrlMember.'@odata.id'
            $ctrlId   = ($ctrlPath -split '/')[-1]
            $ctrlUri  = if ($ctrlPath -match '^https?://') { $ctrlPath } else { "https://$iDRACIP$ctrlPath" }
            try {
                $ctrl = Invoke-RedfishGet $ctrlUri $Credential
                $sc = if ($ctrl.StorageControllers -and $ctrl.StorageControllers.Count -gt 0) { $ctrl.StorageControllers[0] } else { $null }
                $ctrlInfo = @{
                    Id                       = $ctrl.Id
                    Name                     = $ctrl.Name
                    Model                    = if ($sc) { $sc.Model } else { $ctrl.Name }
                    Manufacturer             = if ($sc) { $sc.Manufacturer } else { $null }
                    FirmwareVersion          = if ($sc) { $sc.FirmwareVersion } else { $null }
                    Status                   = $ctrl.Status
                    SupportedDeviceProtocols = if ($sc) { $sc.SupportedDeviceProtocols } else { @() }
                    Drives                   = @()
                    Volumes                  = @()
                }

                # Physical drives
                if ($ctrl.Drives -and $ctrl.Drives.Count -gt 0) {
                    foreach ($driveMember in $ctrl.Drives) {
                        $drivePath = $driveMember.'@odata.id'
                        $driveUri  = if ($drivePath -match '^https?://') { $drivePath } else { "https://$iDRACIP$drivePath" }
                        try {
                            $drv = Invoke-RedfishGet $driveUri $Credential
                            $ctrlInfo.Drives += @{
                                Id               = $drv.Id
                                Name             = $drv.Name
                                Model            = $drv.Model
                                Manufacturer     = $drv.Manufacturer
                                SerialNumber     = $drv.SerialNumber
                                CapacityBytes    = $drv.CapacityBytes
                                RotationSpeedRPM = $drv.RotationSpeedRPM
                                Protocol         = $drv.Protocol
                                MediaType        = $drv.MediaType
                                CapableSpeedGbs  = $drv.CapableSpeedGbs
                                Status           = $drv.Status
                            }
                            $gbStr = if ($drv.CapacityBytes) { "$([math]::Round($drv.CapacityBytes/1GB, 0)) GB" } else { "unknown" }
                            Write-Log "    Drive $($drv.Id): $($drv.Model) $gbStr $($drv.MediaType)"
                        } catch { Write-Log "    Drive $drivePath failed: $_" "WARN" }
                    }
                }

                # Volumes
                if ($ctrl.Volumes -and $ctrl.Volumes.'@odata.id') {
                    $volsUri = if ($ctrl.Volumes.'@odata.id' -match '^https?://') { $ctrl.Volumes.'@odata.id' } else { "https://$iDRACIP$($ctrl.Volumes.'@odata.id')" }
                    try {
                        $volsCol = Invoke-RedfishGet $volsUri $Credential
                        foreach ($volMember in $volsCol.Members) {
                            $volPath = $volMember.'@odata.id'
                            $volUri  = if ($volPath -match '^https?://') { $volPath } else { "https://$iDRACIP$volPath" }
                            try {
                                $vol = Invoke-RedfishGet $volUri $Credential
                                $ctrlInfo.Volumes += @{
                                    Id            = $vol.Id
                                    Name          = $vol.Name
                                    VolumeType    = $vol.VolumeType
                                    RAIDType      = $vol.RAIDType
                                    CapacityBytes = $vol.CapacityBytes
                                    Status        = $vol.Status
                                    Drives        = @(if ($vol.Links -and $vol.Links.Drives) { $vol.Links.Drives | ForEach-Object { $oid = $_.'@odata.id'; if ($oid) { ($oid -split '/')[-1] } } })
                                }
                                Write-Log "    Volume $($vol.Name): $($vol.RAIDType)"
                            } catch { Write-Log "    Volume $volPath failed: $_" "WARN" }
                        }
                    } catch { Write-Log "    Volumes collection for $ctrlId failed: $_" "WARN" }
                }

                $storageInventory[$ctrlId] = $ctrlInfo
                Write-Log "    Controller ${ctrlId}: $($ctrlInfo.Model) — $($ctrlInfo.Drives.Count) drive(s), $($ctrlInfo.Volumes.Count) volume(s)"
            } catch { Write-Log "    Controller $ctrlId failed: $_" "WARN" }
        }
    } catch { Write-Log "  [Storage] Collection failed: $_" "WARN" }
    $inventory.Storage = $storageInventory

    # ----------------------------------------------------------
    # PCIe DEVICES (includes GPUs, HBAs, NICs)
    # ----------------------------------------------------------
    Write-Log "  [PCIe] Collecting PCIe device inventory..."
    $inventory.PCIeDevices = @(Invoke-RedfishDrillCollection "$systems/PCIeDevices" $iDRACIP $Credential "pcie-device")
    Write-Log "  [PCIe] Found: $($inventory.PCIeDevices.Count) PCIe device(s)"
    $gpus = @($inventory.PCIeDevices | Where-Object { $_.Name -match 'GPU|NVIDIA|AMD|Radeon' -or $_.DeviceType -match 'GPU' })
    if ($gpus.Count -gt 0) { Write-Log "  [PCIe] GPUs detected: $($gpus.Count)" "SUCCESS" }

    # ----------------------------------------------------------
    # FIRMWARE INVENTORY
    # ----------------------------------------------------------
    Write-Log "  [Firmware] Collecting firmware inventory..."
    $inventory.FirmwareInventory = @(Invoke-RedfishDrillCollection "$base/UpdateService/FirmwareInventory" $iDRACIP $Credential "firmware")
    Write-Log "  [Firmware] Found: $($inventory.FirmwareInventory.Count) firmware component(s)"

    # ----------------------------------------------------------
    # POWER
    # ----------------------------------------------------------
    Write-Log "  [Power] Collecting power supply data..."
    try {
        $inventory.Power = Invoke-RedfishGet "$chassis/Power" $Credential
        $psuCount = if ($inventory.Power.PowerSupplies) { $inventory.Power.PowerSupplies.Count } else { 0 }
        Write-Log "  [Power] Found: $psuCount PSU(s)"
    } catch { Write-Log "  [Power] Failed: $_" "WARN" }

    # ----------------------------------------------------------
    # THERMAL
    # ----------------------------------------------------------
    Write-Log "  [Thermal] Collecting thermal/fan data..."
    try {
        $inventory.Thermal = Invoke-RedfishGet "$chassis/Thermal" $Credential
        $fanCount  = if ($inventory.Thermal.Fans)         { $inventory.Thermal.Fans.Count }         else { 0 }
        $tempCount = if ($inventory.Thermal.Temperatures) { $inventory.Thermal.Temperatures.Count } else { 0 }
        Write-Log "  [Thermal] Found: $fanCount fan(s), $tempCount temperature sensor(s)"
    } catch { Write-Log "  [Thermal] Failed: $_" "WARN" }

    # ----------------------------------------------------------
    # BIOS ATTRIBUTES
    # ----------------------------------------------------------
    Write-Log "  [BIOS] Collecting BIOS attributes..."
    try {
        $inventory.BIOSAttributes = Invoke-RedfishGet "$systems/Bios" $Credential
        Write-Log "  [BIOS] Attributes collected."
    } catch { Write-Log "  [BIOS] Failed: $_" "WARN" }

    # ----------------------------------------------------------
    # iDRAC ATTRIBUTES
    # ----------------------------------------------------------
    Write-Log "  [iDRAC Attributes] Collecting iDRAC attribute dump..."
    try {
        $inventory.iDRACAttributes = Invoke-RedfishGet "$managers/Attributes" $Credential
        Write-Log "  [iDRAC Attributes] Collected."
    } catch { Write-Log "  [iDRAC Attributes] Failed: $_" "WARN" }

    Write-Log "  === $NodeName discovery complete ===" "SUCCESS"
    return $inventory
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Hardware Discovery via Dell Redfish API ===" "HEADER"

    $resolvedConfig = Resolve-ConfigPath -ExplicitPath $ConfigPath

    Import-Module powershell-yaml -ErrorAction Stop
    $config = Get-Content $resolvedConfig -Raw | ConvertFrom-Yaml

    $nodes = @()
    foreach ($entry in $config.compute.cluster_nodes.GetEnumerator()) {
        $nodes += [PSCustomObject]@{ Name = $entry.Key; iDRACIP = $entry.Value.idrac_ip }
    }
    if ($nodes.Count -eq 0) { throw "No nodes found in config under 'compute.cluster_nodes'." }

    Write-Log "Nodes to discover: $($nodes.Count)"
    $nodes | ForEach-Object { Write-Log "  $($_.Name) - $($_.iDRACIP)" }

    Write-Log ""
    Write-Log "=== Resolving iDRAC Credentials ===" "HEADER"
    $cred = Resolve-iDRACCredential -ParamUsername $iDRACUsername -ParamPassword $iDRACPassword -Config $config
    Write-Log "Credentials resolved: $($cred.UserName)" "SUCCESS"

    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Log "Output directory: $OutputPath"

    $results = @()
    foreach ($node in $nodes) {
        $inv = Get-NodeInventory -NodeName $node.Name -iDRACIP $node.iDRACIP -Credential $cred
        if ($inv) {
            $serviceTag = $inv.System.SKU
            $outFile = Join-Path $OutputPath "$serviceTag.json"
            $inv | ConvertTo-Json -Depth 20 | Set-Content $outFile -Encoding UTF8
            Write-Log "  Saved: $outFile" "SUCCESS"
            $results += [PSCustomObject]@{ NodeName = $node.Name; ServiceTag = $serviceTag; File = $outFile; Success = $true }
        } else {
            $results += [PSCustomObject]@{ NodeName = $node.Name; ServiceTag = $null; File = $null; Success = $false }
        }
    }

    Write-Log ""
    Write-Log "=== DISCOVERY SUMMARY ===" "HEADER"
    $succeeded = @($results | Where-Object { $_.Success })
    $failed    = @($results | Where-Object { -not $_.Success })
    foreach ($r in $succeeded) { Write-Log "  OK   $($r.NodeName) — $($r.ServiceTag)" "SUCCESS" }
    foreach ($r in $failed)    { Write-Log "  FAIL $($r.NodeName)" "ERROR" }
    Write-Log "Discovered: $($succeeded.Count) / $($results.Count) nodes"
    if ($failed.Count -gt 0) { Write-Log "Some nodes failed. Review errors above." "WARN" }

    if (-not $SkipYmlUpdate) {
        Write-Log ""
        Write-Log "=== Updating infrastructure.yml ===" "HEADER"
        $updaterScript = Join-Path $PSScriptRoot "Update-InfrastructureYml-FromDiscovery.ps1"
        if (-not (Test-Path $updaterScript)) {
            Write-Log "Updater script not found at: $updaterScript" "WARN"
        } else {
            $updaterArgs = @{ ConfigPath = $resolvedConfig; DiscoveryPath = $OutputPath }
            if ($Force) { $updaterArgs.Force = $true }
            & $updaterScript @updaterArgs
        }
    } else {
        Write-Log "Skipping yml update (-SkipYmlUpdate specified)."
    }

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}
