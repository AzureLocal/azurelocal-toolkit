#Requires -Version 7.0
<#
.SYNOPSIS
    Update-InfrastructureYml-FromDiscovery.ps1
    Writes hardware discovery data back into infrastructure.yml.

.DESCRIPTION
    Reads JSON discovery files produced by Invoke-HardwareDiscovery.ps1 and
    updates the following fields per-node (matched by iDRAC IP):

      service_tag           <- System.SKU
      serial_number         <- System.SerialNumber
      bios_version          <- System.BiosVersion
      macs.idrac            <- iDRAC NIC MAC address
      cpu.model             <- ProcessorSummary.Model
      cpu.count             <- ProcessorSummary.Count
      cpu.logical_processors <- ProcessorSummary.LogicalProcessorCount
      memory.total_gb       <- MemorySummary.TotalSystemMemoryGiB
      macs.slot3_port1/2    <- NetworkAdapters port MACs (if available)
      macs.slot6_port1/2    <- NetworkAdapters port MACs (if available)
      macs.onboard_port1/2  <- NetworkAdapters port MACs (if available)

    Safety:
      - Backs up config to <file>.bak.<timestamp> before any write
      - Edits only the specific YAML lines that changed — does NOT reformat
        the file via ConvertTo-Yaml (preserves comments, formatting, order)
      - Shows a diff and prompts Y/N before writing (bypass with -Force)
      - Skips nodes with no matching discovery file (warns)

.PARAMETER ConfigPath
    Path to infrastructure.yml. Auto-detected from .\configs\ if not specified.

.PARAMETER DiscoveryPath
    Path to discovery JSON files. Default: .\configs\network-devices\bmc

.PARAMETER Force
    Skip the confirmation prompt.

.NOTES
    Author: Azure Local Cloud AzureLocalCloud
    Version: 2.0.0
    Phase: 01-hardware-provisioning
    Task: task-02-hardware-discovery-via-dell-redfish-api
    Prerequisites: PowerShell 7+, powershell-yaml module
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string]$ConfigPath,
    [Parameter(Mandatory = $false)] [string]$DiscoveryPath = ".\configs\network-devices\bmc",
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

    $candidates = Get-ChildItem -Path ".\configs\" -Filter "infrastructure*.yml" -ErrorAction SilentlyContinue |
                  Sort-Object Name

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
    if ([string]::IsNullOrWhiteSpace($selection)) {
        Write-Log "Using default: $($candidates[$defIdx].FullName)"
        return $candidates[$defIdx].FullName
    }
    $idx = [int]$selection - 1
    if ($idx -lt 0 -or $idx -ge $candidates.Count) {
        throw "Invalid selection '$selection'. Must be 1-$($candidates.Count)."
    }
    Write-Log "Using: $($candidates[$idx].FullName)"
    return $candidates[$idx].FullName
}

function Backup-ConfigFile {
    param([string]$ConfigPath)
    $timestamp  = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$ConfigPath.bak.$timestamp"
    Copy-Item -Path $ConfigPath -Destination $backupPath -Force
    Write-Log "Backup created: $backupPath" "SUCCESS"
    return $backupPath
}

function Get-iDRACMac {
    param([object]$DiscoveryData)
    # v1.2+: top-level iDRAC_MAC field (most reliable)
    if ($DiscoveryData.iDRAC_MAC) { return $DiscoveryData.iDRAC_MAC }
    # v1.2+: iDRACNicDetail fetched during discovery
    if ($DiscoveryData.iDRACNicDetail -and
        ($DiscoveryData.iDRACNicDetail.PSObject.Properties.Name -contains "MACAddress")) {
        return $DiscoveryData.iDRACNicDetail.MACAddress
    }
    # Legacy: collection Members (only if Redfish embedded full detail in members)
    if ($DiscoveryData.iDRACInterfaces -and $DiscoveryData.iDRACInterfaces.Members) {
        $first = $DiscoveryData.iDRACInterfaces.Members[0]
        if ($first -and ($first.PSObject.Properties.Name -contains "MACAddress")) {
            return $first.MACAddress
        }
    }
    return $null
}

function Get-NestedValue {
    # Safely reads a nested hashtable value by key path array; returns $null if any key missing
    param([hashtable]$Dict, [string[]]$Keys)
    $current = $Dict
    foreach ($key in $Keys) {
        if ($null -eq $current -or -not ($current -is [hashtable]) -or -not $current.ContainsKey($key)) {
            return $null
        }
        $current = $current[$key]
    }
    return $current
}

function Get-JsonProp {
    # Safely reads a nested PSCustomObject property path (from ConvertFrom-Json);
    # returns $null if any level is missing — avoids StrictMode 'property not found' errors
    param($Object, [string[]]$Keys)
    $cur = $Object
    foreach ($key in $Keys) {
        if ($null -eq $cur) { return $null }
        $prop = $cur.PSObject.Properties[$key]
        if ($null -eq $prop) { return $null }
        $cur = $prop.Value
    }
    return $cur
}

function New-Change {
    # Creates a standardised change object
    param([string]$NodeName, [string[]]$Keys, $OldValue, $NewValue)
    return [PSCustomObject]@{
        NodeName = $NodeName
        Path     = "nodes.$NodeName.$($Keys -join '.')"
        Keys     = $Keys
        OldValue = $OldValue
        NewValue = $NewValue
    }
}

function Get-MacYmlKey {
    # Maps Redfish adapter/port ID pair to yml macs.* key name
    # Dell port IDs: NIC.Integrated.1-1-1, NIC.Integrated.1-2-1
    #   format: <Type>.<Slot>-<PortNum>-<SubPort>  — port number is second-to-last segment
    # NIC.Slot.3   / NIC.Slot.3-1-1     -> slot3_port1
    # NIC.Slot.3   / NIC.Slot.3-2-1     -> slot3_port2
    # NIC.Embedded / NIC.Integrated.1-1-1 -> onboard_port1
    # NIC.Embedded / NIC.Integrated.1-2-1 -> onboard_port2
    param([string]$AdapterId, [string]$PortId)
    # Extract port number: prefer second-to-last numeric segment (Dell format X-PortNum-SubPort)
    $portNum = 1
    if ($PortId -match '-(\d+)-\d+$') {
        $portNum = [int]$Matches[1]
    } elseif ($PortId -match '(\d+)$') {
        $portNum = [int]$Matches[1]
    }
    if ($AdapterId -match '^NIC\.Slot\.(\d+)$')   { return "slot$([int]$Matches[1])_port${portNum}" }
    if ($AdapterId -match '^NIC\.(Embedded|Integrated)\.') { return "onboard_port${portNum}" }
    return $null
}

function Format-YamlScalar {
    # Formats a value for YAML: numbers unquoted, strings double-quoted
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return "$Value"
    }
    $escaped = "$Value" -replace '"', '\"'
    return "`"$escaped`""
}

function Set-YamlNodeField {
    <#
    In-place update of a single field within a named node block.
    Finds the exact line and replaces only the value — nothing else changes.
    Returns $true on success, $false if the key path was not found.
    #>
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$NodeName,
        [string[]]$Keys,
        $NewValue
    )

    # Find the node line at any indent level
    $nodeLineIdx = -1
    $nodeIndent  = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^(\s+)${NodeName}\s*:") {
            $nodeLineIdx = $i
            $nodeIndent  = $Matches[1].Length
            break
        }
    }
    if ($nodeLineIdx -lt 0) {
        Write-Log "  YAML edit: node '$NodeName' not found in file" "WARN"
        return $false
    }

    # Walk the key hierarchy
    $searchFrom  = $nodeLineIdx + 1
    $childIndent = $nodeIndent + 2

    for ($ki = 0; $ki -lt $Keys.Count; $ki++) {
        $key    = $Keys[$ki]
        $indent = $childIndent + ($ki * 2)
        $spaces = ' ' * $indent
        $isLast = ($ki -eq $Keys.Count - 1)

        $foundIdx = -1
        for ($i = $searchFrom; $i -lt $Lines.Count; $i++) {
            $line    = $Lines[$i]
            $trimmed = $line.TrimStart()

            # Skip blank lines and YAML comments
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

            $lineIndent = $line.Length - $trimmed.Length

            # Left scope: hit content at lower indent than expected
            if ($lineIndent -lt $indent) { break }

            # Found: correct indent + correct key name
            if ($lineIndent -eq $indent -and $trimmed -match "^${key}\s*:") {
                $foundIdx = $i
                break
            }
        }

        if ($foundIdx -lt 0) {
            Write-Log "  YAML edit: '$($Keys -join '.')' not found in node '$NodeName'" "WARN"
            return $false
        }

        if ($isLast) {
            $formatted      = Format-YamlScalar $NewValue
            $Lines[$foundIdx] = "${spaces}${key}: $formatted"
            return $true
        } else {
            $searchFrom = $foundIdx + 1
        }
    }

    return $false
}

function Set-YamlNodePath {
    <#
    Generalized in-place YAML field updater supporting regular key navigation
    and YAML array item matching via '[key=value]' segment syntax.
    Example path: @('hardware_platform','pcie_network_adapters','[slot=3]','vendor')
    Returns $true on success, $false if path not found.
    #>
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$NodeName,
        [string[]]$Path,
        $NewValue
    )

    $nodeLineIdx = -1
    $nodeIndent  = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^(\s+)${NodeName}\s*:") {
            $nodeLineIdx = $i
            $nodeIndent  = $Matches[1].Length
            break
        }
    }
    if ($nodeLineIdx -lt 0) {
        Write-Log "  YAML path: node '$NodeName' not found" "WARN"
        return $false
    }

    $searchFrom     = $nodeLineIdx + 1
    $expectedIndent = $nodeIndent + 2

    for ($pi = 0; $pi -lt $Path.Count; $pi++) {
        $segment = $Path[$pi]
        $isLast  = ($pi -eq $Path.Count - 1)

        if ($segment -match '^\[(.+?)=(.+)\]$') {
            # Array item matcher: find '- matchKey: matchVal' at expectedIndent
            $matchKey = $Matches[1]
            $matchVal = $Matches[2].Trim('"').Trim("'")

            $foundItemIdx = -1
            for ($i = $searchFrom; $i -lt $Lines.Count; $i++) {
                $line    = $Lines[$i]
                $trimmed = $line.TrimStart()
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
                $lineIndent = $line.Length - $trimmed.Length
                if ($lineIndent -lt $expectedIndent - 2) { break }
                # Match:  '- matchKey: value'  or  '- matchKey: "value"'
                if ($lineIndent -eq $expectedIndent -and $trimmed -match "^-\s+${matchKey}\s*:\s*`"?([^`"]+?)`"?\s*`$") {
                    if ($Matches[1].Trim() -eq $matchVal) {
                        $foundItemIdx = $i
                        break
                    }
                }
            }
            if ($foundItemIdx -lt 0) {
                Write-Log "  YAML path: array item '[${matchKey}=${matchVal}]' not found in node '$NodeName'" "WARN"
                return $false
            }
            $searchFrom     = $foundItemIdx + 1
            $expectedIndent = $expectedIndent + 2
        } else {
            # Regular key
            $foundIdx = -1
            for ($i = $searchFrom; $i -lt $Lines.Count; $i++) {
                $line    = $Lines[$i]
                $trimmed = $line.TrimStart()
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
                $lineIndent = $line.Length - $trimmed.Length
                if ($lineIndent -lt $expectedIndent) { break }
                if ($lineIndent -eq $expectedIndent -and $trimmed -match "^${segment}\s*:") {
                    $foundIdx = $i
                    break
                }
            }
            if ($foundIdx -lt 0) {
                Write-Log "  YAML path: key '$segment' not found in node '$NodeName'" "WARN"
                return $false
            }
            if ($isLast) {
                $spaces           = ' ' * $expectedIndent
                $formatted        = Format-YamlScalar $NewValue
                $Lines[$foundIdx] = "${spaces}${segment}: $formatted"
                return $true
            } else {
                $searchFrom     = $foundIdx + 1
                $expectedIndent = $expectedIndent + 2
            }
        }
    }
    return $false
}

function Resolve-NicVendor {
    param([string]$Manufacturer)
    if (-not $Manufacturer) { return $null }
    if ($Manufacturer -match 'Mellanox|NVIDIA ConnectX')  { return 'Mellanox' }
    if ($Manufacturer -match 'NVIDIA')                    { return 'NVIDIA'   }
    if ($Manufacturer -match 'Intel')                     { return 'Intel'    }
    if ($Manufacturer -match 'Broadcom|Qlogic|Emulex')   { return 'Broadcom' }
    return ($Manufacturer -replace '\s*,.*$','').Trim()
}

function Show-Diff {
    param([array]$Changes)

    if ($Changes.Count -eq 0) {
        Write-Log "No changes detected — infrastructure.yml is already up to date." "SUCCESS"
        return
    }

    Write-Host ""
    Write-Host "Fields to be updated in infrastructure.yml:" -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor DarkGray

    foreach ($change in $Changes) {
        Write-Host "  $($change.Path)" -ForegroundColor White
        if ($change.OldValue) {
            Write-Host "    OLD: $($change.OldValue)" -ForegroundColor DarkGray
        } else {
            Write-Host "    OLD: (not set)" -ForegroundColor DarkGray
        }
        Write-Host "    NEW: $($change.NewValue)" -ForegroundColor Green
    }

    Write-Host ("-" * 70) -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

try {
    Write-Log "=== Update infrastructure.yml from Hardware Discovery ===" "HEADER"

    $resolvedConfig = Resolve-ConfigPath -ExplicitPath $ConfigPath

    # Load YAML for node matching and old-value comparison ONLY
    Import-Module powershell-yaml -ErrorAction Stop
    $config = Get-Content $resolvedConfig -Raw | ConvertFrom-Yaml

    # Load raw lines for in-place editing — never written back via ConvertTo-Yaml
    $rawLines = [System.Collections.Generic.List[string]](Get-Content $resolvedConfig)

    # Load discovery JSON files
    $jsonFiles = Get-ChildItem -Path $DiscoveryPath -Filter "*.json" -ErrorAction SilentlyContinue
    if (-not $jsonFiles -or $jsonFiles.Count -eq 0) {
        throw "No discovery JSON files found in: $DiscoveryPath`nRun Invoke-HardwareDiscovery.ps1 first."
    }
    Write-Log "Found $($jsonFiles.Count) discovery file(s) in $DiscoveryPath"

    # Build iDRAC IP -> discovery data map
    $discoveryMap = @{}
    foreach ($file in $jsonFiles) {
        $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
        if ($data.iDRACIP) {
            $discoveryMap[$data.iDRACIP] = $data
            Write-Log "  Loaded: $($file.Name) (iDRAC: $($data.iDRACIP), ServiceTag: $($data.System.SKU))"
        } else {
            Write-Log "  Skipping $($file.Name) — no iDRACIP field" "WARN"
        }
    }

    # Build change list
    $changes   = @()
    $matched   = @()
    $unmatched = @()

    foreach ($nodeEntry in $config.compute.cluster_nodes.GetEnumerator()) {
        $nodeName = $nodeEntry.Key
        $nodeData = $nodeEntry.Value
        $iDRACIP  = $nodeData.idrac_ip

        if (-not $iDRACIP) {
            Write-Log "Node '$nodeName' has no idrac_ip in config — skipping" "WARN"
            $unmatched += $nodeName; continue
        }
        if (-not $discoveryMap.ContainsKey($iDRACIP)) {
            Write-Log "No discovery data for node '$nodeName' (iDRAC: $iDRACIP) — skipping" "WARN"
            $unmatched += $nodeName; continue
        }

        $disc = $discoveryMap[$iDRACIP]
        $matched += $nodeName

        # ---- system identity ----
        $newVal = Get-JsonProp $disc @('System','SKU')
        $oldVal = Get-NestedValue $nodeData @('service_tag')
        if ($newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('service_tag') $oldVal $newVal }

        $newVal = Get-JsonProp $disc @('System','SerialNumber')
        $oldVal = Get-NestedValue $nodeData @('serial_number')
        if ($newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('serial_number') $oldVal $newVal }

        $newVal = Get-JsonProp $disc @('System','BiosVersion')
        $oldVal = Get-NestedValue $nodeData @('bios_version')
        if ($newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('bios_version') $oldVal $newVal }

        # ---- macs.idrac ----
        $newVal = Get-iDRACMac -DiscoveryData $disc
        $oldVal = Get-NestedValue $nodeData @('macs', 'idrac')
        if ($newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('macs', 'idrac') $oldVal $newVal }

        # ---- cpu ----
        $newVal = Get-JsonProp $disc @('System','ProcessorSummary','Model')
        $oldVal = Get-NestedValue $nodeData @('cpu', 'model')
        if ($newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('cpu', 'model') $oldVal $newVal }

        $newVal = Get-JsonProp $disc @('System','ProcessorSummary','Count')
        $oldVal = Get-NestedValue $nodeData @('cpu', 'count')
        if ($null -ne $newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('cpu', 'count') $oldVal $newVal }

        $newVal = Get-JsonProp $disc @('System','ProcessorSummary','LogicalProcessorCount')
        $oldVal = Get-NestedValue $nodeData @('cpu', 'logical_processors')
        if ($null -ne $newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('cpu', 'logical_processors') $oldVal $newVal }

        # ---- memory ----
        $newVal = Get-JsonProp $disc @('System','MemorySummary','TotalSystemMemoryGiB')
        $oldVal = Get-NestedValue $nodeData @('memory', 'total_gb')
        if ($null -ne $newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('memory', 'total_gb') $oldVal $newVal }

        # ---- macs.* per port from NetworkAdapters ----
        if ($disc.PSObject.Properties.Name -contains 'NetworkAdapters' -and $disc.NetworkAdapters) {
            foreach ($adEntry in $disc.NetworkAdapters.PSObject.Properties) {
                $adapterId = $adEntry.Name
                if ($adEntry.Value.Ports) {
                    foreach ($portEntry in $adEntry.Value.Ports.PSObject.Properties) {
                        $ymlKey = Get-MacYmlKey -AdapterId $adapterId -PortId $portEntry.Name
                        if ($ymlKey -and $portEntry.Value.MAC) {
                            $oldMac = Get-NestedValue $nodeData @('macs', $ymlKey)
                            if ($portEntry.Value.MAC -ne $oldMac) {
                                $changes += New-Change $nodeName @('macs', $ymlKey) $oldMac $portEntry.Value.MAC
                            }
                        }
                    }
                }
            }
        }

        # ---- model ----
        $newVal = Get-JsonProp $disc @('System','Model')
        $oldVal = Get-NestedValue $nodeData @('model')
        if ($newVal -and $newVal -ne $oldVal) { $changes += New-Change $nodeName @('model') $oldVal $newVal }

        # ---- cpu.cores, cpu.max_clock_mhz (from per-socket Processors array) ----
        if ($disc.PSObject.Properties.Name -contains 'Processors' -and $disc.Processors) {
            $procs = @($disc.Processors)
            $totalCores = ($procs | Measure-Object -Property TotalCores -Sum).Sum
            if ($totalCores -gt 0) {
                $oldVal = Get-NestedValue $nodeData @('cpu', 'cores')
                if ($totalCores -ne $oldVal) { $changes += New-Change $nodeName @('cpu', 'cores') $oldVal $totalCores }
            }
            $maxMhz = ($procs | Measure-Object -Property MaxSpeedMHz -Maximum).Maximum
            if ($maxMhz -gt 0) {
                $oldVal = Get-NestedValue $nodeData @('cpu', 'max_clock_mhz')
                if ($maxMhz -ne $oldVal) { $changes += New-Change $nodeName @('cpu', 'max_clock_mhz') $oldVal $maxMhz }
            }
        }

        # ---- memory: dimm_count, dimm_size_gb, speed_mhz, type (from MemoryDIMMs array) ----
        if ($disc.PSObject.Properties.Name -contains 'MemoryDIMMs' -and $disc.MemoryDIMMs) {
            $populated = @($disc.MemoryDIMMs | Where-Object { $_.CapacityMiB -gt 0 -and $_.Status.State -ne 'Absent' })
            if ($populated.Count -gt 0) {
                $oldVal = Get-NestedValue $nodeData @('memory', 'dimm_count')
                if ($populated.Count -ne $oldVal) { $changes += New-Change $nodeName @('memory', 'dimm_count') $oldVal $populated.Count }

                $dimmSizeGb = [math]::Round($populated[0].CapacityMiB / 1024, 0)
                $oldVal = Get-NestedValue $nodeData @('memory', 'dimm_size_gb')
                if ($dimmSizeGb -gt 0 -and $dimmSizeGb -ne $oldVal) { $changes += New-Change $nodeName @('memory', 'dimm_size_gb') $oldVal $dimmSizeGb }

                $speedMhz = $populated[0].OperatingSpeedMhz
                $oldVal   = Get-NestedValue $nodeData @('memory', 'speed_mhz')
                if ($speedMhz -and $speedMhz -ne $oldVal) { $changes += New-Change $nodeName @('memory', 'speed_mhz') $oldVal $speedMhz }

                $dimmType = $populated[0].MemoryDeviceType
                $oldVal   = Get-NestedValue $nodeData @('memory', 'type')
                if ($dimmType -and $dimmType -ne $oldVal) { $changes += New-Change $nodeName @('memory', 'type') $oldVal $dimmType }
            }
        }

        # ---- storage: boot drive + data drives (from Storage controller drives) ----
        if ($disc.PSObject.Properties.Name -contains 'Storage' -and $disc.Storage) {
            $allDrives = @()
            foreach ($ctrl in $disc.Storage.PSObject.Properties) {
                if ($ctrl.Value.Drives) { $allDrives += @($ctrl.Value.Drives) }
            }
            if ($allDrives.Count -gt 0) {
                # Boot drive: drive belongs to a BOSS or SATADOM controller
                $bossCtrlIds = @($disc.Storage.PSObject.Properties | Where-Object {
                    $_.Name -match 'BOSS|SATADOM|AHCI'
                } | ForEach-Object { $_.Name })
                $bootDrives = @($allDrives | Where-Object {
                    $drv = $_
                    $fromBoss = @($bossCtrlIds | Where-Object {
                        $disc.Storage.$_.Drives | Where-Object { $_.Id -eq $drv.Id }
                    })
                    $fromBoss.Count -gt 0 -or $drv.Model -match 'BOSS|SATADOM'
                })
                if ($bootDrives.Count -gt 0) {
                    $bd = $bootDrives[0]
                    $bdModel = $bd.Model
                    $oldVal  = Get-NestedValue $nodeData @('storage', 'boot_drive', 'model')
                    if ($bdModel -and $bdModel -ne $oldVal) { $changes += New-Change $nodeName @('storage', 'boot_drive', 'model') $oldVal $bdModel }

                    $bdSizeGb = [math]::Round($bd.CapacityBytes / 1GB, 0)
                    $oldVal   = Get-NestedValue $nodeData @('storage', 'boot_drive', 'size_gb')
                    if ($bdSizeGb -gt 0 -and $bdSizeGb -ne $oldVal) { $changes += New-Change $nodeName @('storage', 'boot_drive', 'size_gb') $oldVal $bdSizeGb }
                }

                # Data drives: NVMe drives NOT on a BOSS/AHCI controller
                $dataDrives = @($allDrives | Where-Object {
                    $drv = $_
                    $fromBoss = @($bossCtrlIds | Where-Object {
                        $disc.Storage.$_.Drives | Where-Object { $_.Id -eq $drv.Id }
                    })
                    $fromBoss.Count -eq 0
                } | Where-Object { $_.Protocol -eq 'NVMe' -or $_.MediaType -match 'SSD|NVMe' })
                if ($dataDrives.Count -gt 0) {
                    $oldVal = Get-NestedValue $nodeData @('storage', 'data_drives', 'count')
                    if ($dataDrives.Count -ne $oldVal) { $changes += New-Change $nodeName @('storage', 'data_drives', 'count') $oldVal $dataDrives.Count }

                    $ddModel = $dataDrives[0].Model
                    $oldVal  = Get-NestedValue $nodeData @('storage', 'data_drives', 'model')
                    if ($ddModel -and $ddModel -ne $oldVal) { $changes += New-Change $nodeName @('storage', 'data_drives', 'model') $oldVal $ddModel }

                    $ddSizeGb = [math]::Round($dataDrives[0].CapacityBytes / 1GB, 0)
                    $oldVal   = Get-NestedValue $nodeData @('storage', 'data_drives', 'size_gb')
                    if ($ddSizeGb -gt 0 -and $ddSizeGb -ne $oldVal) { $changes += New-Change $nodeName @('storage', 'data_drives', 'size_gb') $oldVal $ddSizeGb }

                    $totalCap = [math]::Round(($dataDrives | Measure-Object -Property CapacityBytes -Sum).Sum / 1GB, 0)
                    $oldVal   = Get-NestedValue $nodeData @('storage', 'data_drives', 'total_capacity_gb')
                    if ($totalCap -gt 0 -and $totalCap -ne $oldVal) { $changes += New-Change $nodeName @('storage', 'data_drives', 'total_capacity_gb') $oldVal $totalCap }
                }
            }
        }

        # ---- gpu.enabled, gpu.model (from PCIeDevices) ----
        if ($disc.PSObject.Properties.Name -contains 'PCIeDevices' -and $disc.PCIeDevices) {
            $gpus = @($disc.PCIeDevices | Where-Object { $_.Name -match 'GPU|NVIDIA|AMD|Radeon' -or $_.DeviceType -match 'GPU' })
            $gpuEnabled = $gpus.Count -gt 0
            $oldVal = Get-NestedValue $nodeData @('gpu', 'enabled')
            if ($gpuEnabled -ne $oldVal) { $changes += New-Change $nodeName @('gpu', 'enabled') $oldVal $gpuEnabled }

            if ($gpus.Count -gt 0) {
                $gpuModel = $gpus[0].Name
                $oldVal   = Get-NestedValue $nodeData @('gpu', 'model')
                if ($gpuModel -and $gpuModel -ne $oldVal) { $changes += New-Change $nodeName @('gpu', 'model') $oldVal $gpuModel }
            }
        }

        # ---- hardware_platform.pcie_network_adapters (vendor, model, port MACs) ----
        if ($disc.PSObject.Properties.Name -contains 'NetworkAdapters' -and $disc.NetworkAdapters) {
            foreach ($adEntry in $disc.NetworkAdapters.PSObject.Properties) {
                $adapterId = $adEntry.Name
                $adData    = $adEntry.Value

                # PCIe slot adapters only
                if ($adapterId -notmatch '^NIC\.Slot\.(\d+)') { continue }
                $slotNum = [int]$Matches[1]
                $slotKey = "[slot=$slotNum]"

                $vendor = Resolve-NicVendor $adData.Manufacturer
                if ($vendor) {
                    $changes += New-Change $nodeName @('hardware_platform','pcie_network_adapters',$slotKey,'vendor') $null $vendor
                }
                if ($adData.Model) {
                    $changes += New-Change $nodeName @('hardware_platform','pcie_network_adapters',$slotKey,'model') $null $adData.Model
                }

                # Port MACs
                if ($adData.Ports) {
                    foreach ($portEntry in $adData.Ports.PSObject.Properties) {
                        $portMac = $portEntry.Value.MAC
                        if (-not $portMac) { continue }
                        $portNum = 1
                        if ($portEntry.Name -match '-(\d+)-\d+$') { $portNum = [int]$Matches[1] }
                        $nameKey = "[name=Slot $slotNum Port $portNum]"
                        $changes += New-Change $nodeName @('hardware_platform','pcie_network_adapters',$slotKey,'ports',$nameKey,'mac_address') $null $portMac
                    }
                }
            }
        }

        # ---- hardware_platform.onboard_nics adapter MACs ----
        if ($disc.PSObject.Properties.Name -contains 'NetworkAdapters' -and $disc.NetworkAdapters) {
            foreach ($adEntry in $disc.NetworkAdapters.PSObject.Properties) {
                $adapterId = $adEntry.Name
                $adData    = $adEntry.Value
                if ($adapterId -notmatch '^NIC\.(Embedded|Integrated)\.') { continue }
                if ($adData.Ports) {
                    foreach ($portEntry in $adData.Ports.PSObject.Properties) {
                        $portMac = $portEntry.Value.MAC
                        if (-not $portMac) { continue }
                        $portNum = 1
                        if ($portEntry.Name -match '-(\d+)-\d+$') { $portNum = [int]$Matches[1] }
                        $nameKey = "[name=Embedded LOM $portNum]"
                        $changes += New-Change $nodeName @('hardware_platform','onboard_nics','adapters',$nameKey,'mac_address') $null $portMac
                    }
                }
            }
        }
    }

    Write-Log ""
    if ($matched.Count -gt 0)   { Write-Log "Matched nodes: $($matched -join ', ')" "SUCCESS" }
    if ($unmatched.Count -gt 0) { Write-Log "Unmatched nodes (skipped): $($unmatched -join ', ')" "WARN" }

    Show-Diff -Changes $changes

    if ($changes.Count -eq 0) {
        Write-Log "Nothing to update. Exiting." "SUCCESS"
        exit 0
    }

    if (-not $Force) {
        $confirm = Read-Host "Apply $($changes.Count) change(s) to $($resolvedConfig)? [Y/n]"
        if ($confirm -ne '' -and $confirm -notmatch '^[Yy]$') {
            Write-Log "Aborted by user — no changes written." "WARN"
            exit 0
        }
    }

    $backupPath = Backup-ConfigFile -ConfigPath $resolvedConfig

    # Apply all changes directly to raw lines — no ConvertTo-Yaml, no reformatting
    $applied = 0
    $skipped = 0
    foreach ($change in $changes) {
        if (Set-YamlNodePath -Lines $rawLines -NodeName $change.NodeName -Path $change.Keys -NewValue $change.NewValue) {
            $applied++
        } else {
            Write-Log "  SKIPPED (key not found in YAML): $($change.Path)" "WARN"
            $skipped++
        }
    }

    # Write back only edited lines — UTF-8, no BOM, preserves all formatting
    [System.IO.File]::WriteAllLines($resolvedConfig, $rawLines, [System.Text.Encoding]::UTF8)

    Write-Log "$applied field(s) written to: $resolvedConfig" "SUCCESS"
    if ($skipped -gt 0) { Write-Log "$skipped field(s) skipped — key not present in file" "WARN" }
    Write-Log "Backup at: $backupPath"

    Write-Log ""
    Write-Log "=== COMPLETE ===" "HEADER"
    foreach ($c in $changes) {
        Write-Log "  $($c.Path): $($c.NewValue)" "SUCCESS"
    }

} catch {
    Write-Log "CRITICAL ERROR: $_" "ERROR"
    exit 1
}