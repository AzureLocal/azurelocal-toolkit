#Requires -Version 7.0
<#
.SYNOPSIS
    Idempotent OS configuration of Azure Local nodes from infrastructure.yml (schema 5): read each node's state, change only
    what differs, report what it would change (plan) or what it did (-Execute).

.DESCRIPTION
    Get-AzlSbeBundle        The OEM's SBE package from hardware.sbe.bundle_path: the three files, the SHA-256 checked against
                            the OEM's manifest, and the SBE values the ARM deployment takes.
    Get-AzlNodeSpec         What one node should look like, from infrastructure.yml and the ZTP handoff.
    Compare-AzlNodeState    The spec against a node's state (what the Read script returned): one item per thing, each Ok,
                            Change, Blocked, Info or Skipped. Pure; no node is touched.
    Invoke-AzlNodeConfiguration  The loop: read, compare, and with -Execute apply, restart if needed, read again.
    Format-AzlPlan          A plan as a table.

    Nothing runs on a node that the comparison didn't ask for: a node that matches its spec gets one Read and no Apply.
    Ports are found by MAC, never by name (the installed OS names them Port0 to Port6).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
Import-Module (Join-Path (Join-Path $here '..') (Join-Path 'infrastructure' 'AzlInfrastructure.psm1'))
Import-Module (Join-Path (Join-Path $here '..') (Join-Path 'azure-local' 'AzlAzure.psm1'))
Import-Module (Join-Path $here 'AzlNodePayload.psm1')
Import-Module (Join-Path $here 'AzlNodeTransport.psm1')

$script:ConfigRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($here, '..', '..', '..', 'config'))
# The order the steps run in. Sbe is last on purpose: delivering a 900 MB package is the step most likely to fail (it needs a
# route to the node that the other steps do not), and it must not stop the others. Drivers install from the package, so they
# run in the pass after it has landed (or at once when the node already holds it).
$script:AllSteps = @('RemoteManagement', 'Drivers', 'Network', 'Dns', 'Time', 'Hostname', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe')

function ConvertTo-MacKey([AllowNull()][object]$Mac) {
    if ($null -eq $Mac) { return '' }
    return (([string]$Mac) -replace '[-:\.\s]', '').ToLowerInvariant()
}

function ConvertTo-WwpnKey([AllowNull()][object]$Wwpn) {
    if ($null -eq $Wwpn) { return '' }
    return (([string]$Wwpn) -replace '[-:\s]', '').ToLowerInvariant()
}

function ConvertTo-List([AllowNull()][object]$Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) { return @($Value) }
    return @($Value)
}

# ---------------------------------------------------------------------------------------------------------------------
# The OEM's SBE package
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlOemConfig {
    <#
    .SYNOPSIS
        config/oem/<vendor>.json: the discovery manifest URL and the folders inside the SBE zip that hold network drivers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Vendor, [string]$ConfigRoot = $script:ConfigRoot)
    $path = Join-Path (Join-Path $ConfigRoot 'oem') "$($Vendor.ToLowerInvariant()).json"
    if (-not (Test-Path -LiteralPath $path)) {
        $known = @(Get-ChildItem -LiteralPath (Join-Path $ConfigRoot 'oem') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object BaseName)
        throw "No OEM definition $path. Known: $($known -join ', '). Copy config/oem/dell.json to add one."
    }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 10
}

function Read-AzlSbeManifestText {
    # Pure: the ApplicableUpdate of an SBE discovery manifest (XML text) whose UpdateName is $Name.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Name)
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $xml = [xml]::new()
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Text), $settings)
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    $root = $xml.SelectSingleNode('/SBEUpdatesManifest')
    if (-not $root) { throw 'Not an SBE discovery manifest (no SBEUpdatesManifest root).' }
    $created = $root.SelectSingleNode('ManifestInfo')?.Attributes['CreationDate']?.Value
    foreach ($node in $root.SelectNodes('ApplicableUpdate')) {
        $updateName = $node.SelectSingleNode('UpdateInfo/UpdateName')?.InnerText
        if ($updateName -ne $Name) { continue }
        return [pscustomobject]@{
            Version      = $node.Attributes['Version']?.Value
            Family       = $node.Attributes['Family']?.Value
            Publisher    = $node.SelectSingleNode('UpdateInfo/Publisher')?.InnerText
            PackageHash  = ([string]$node.SelectSingleNode('UpdateInfo/PackageHash')?.InnerText).Trim().ToUpperInvariant()
            CreationDate = $created
        }
    }
    return $null
}

function Get-AzlSbeBundle {
    <#
    .SYNOPSIS
        Finds the OEM's SBE files in a folder, checks the package against the OEM's published SHA-256, and returns what the
        node and the ARM deployment need.
    .DESCRIPTION
        The folder holds one SBE_*.zip, its <name>.xml and SBE_Discovery_*.xml, as downloaded. The expected hash comes from
        the OEM's discovery manifest when -ManifestUrl is given and reachable, else from the SBE_Discovery_*.xml in the
        folder. A mismatch throws. Nothing is written.
    .OUTPUTS
        Name, ZipName, Files (Name, Path, Size, Sha256), HashSource, Deployment (sbeVersion, sbeFamily, sbePublisher,
        sbeManifestSource, sbeManifestCreationDate).
    .EXAMPLE
        Get-AzlSbeBundle -Path 'D:\sbe\dell' -ManifestUrl 'https://aka.ms/AzureStackSBEUpdate/DellEMC'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$ManifestUrl, [switch]$OfflineManifest)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "SBE folder $Path doesn't exist (hardware.sbe.bundle_path)." }
    $zips = @(Get-ChildItem -LiteralPath $Path -File -Filter 'SBE_*.zip')
    if ($zips.Count -ne 1) { throw "Expected one SBE_*.zip in $Path, found $($zips.Count)." }
    $zip = $zips[0]
    $name = [IO.Path]::GetFileNameWithoutExtension($zip.Name)
    $xml = @(Get-ChildItem -LiteralPath $Path -File -Filter "$name.xml")
    $discovery = @(Get-ChildItem -LiteralPath $Path -File -Filter 'SBE_Discovery_*.xml')
    if (-not $xml -or -not $discovery) { throw "$Path needs $($zip.Name), $name.xml and an SBE_Discovery_*.xml file." }

    $entry = $null
    $source = ''
    if ($ManifestUrl -and -not $OfflineManifest) {
        try { $entry = Read-AzlSbeManifestText -Text ((Invoke-WebRequest -Uri $ManifestUrl -TimeoutSec 60).Content) -Name $name; if ($entry) { $source = $ManifestUrl } }
        catch { Write-Warning "Couldn't read $ManifestUrl ($($_.Exception.Message)); using the package's own $($discovery[0].Name)." }
    }
    if (-not $entry) {
        $entry = Read-AzlSbeManifestText -Text (Get-Content -LiteralPath $discovery[0].FullName -Raw) -Name $name
        $source = $discovery[0].Name
    }
    if (-not $entry) { throw "$name isn't listed in $source." }
    $actual = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash
    if ($actual -ne $entry.PackageHash) { throw "$($zip.Name) has SHA-256 $actual; $source says $($entry.PackageHash)." }

    $files = foreach ($f in @($zip, $xml[0], $discovery[0])) {
        [pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Size = [int64]$f.Length; Sha256 = $(if ($f.FullName -eq $zip.FullName) { $actual } else { (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }) }
    }
    [pscustomobject]@{
        Name       = $name
        ZipName    = $zip.Name
        Files      = @($files)
        HashSource = $source
        Deployment = [ordered]@{
            sbeVersion              = [string]$entry.Version
            sbeFamily               = [string]$entry.Family
            sbePublisher            = [string]$entry.Publisher
            sbeManifestSource       = $(if ($source -like 'http*') { $source } elseif ($ManifestUrl) { $ManifestUrl } else { '' })
            sbeManifestCreationDate = [string]$entry.CreationDate
        }
    }
}

function Get-AzlSbePullUrl {
    # Pure: the address a node pulls one SBE file from. Base is hardware.sbe.node_pull_url: an https:// (or http://) folder
    # address, or a UNC folder (\\server\share\sbe).
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Name)
    if ($Base.StartsWith('\\')) { return ($Base.TrimEnd('\') + '\' + $Name) }
    return ($Base.TrimEnd('/') + '/' + [Uri]::EscapeDataString($Name))
}

function Get-AzlSanVendor {
    <#
    .SYNOPSIS
        The MSDSM hardware IDs, load balance policy and MPIO settings for a SAN array, from config/san/msdsm-vendors.json
        (Microsoft Learn: Connect an external storage array to Azure Local, step 2). $null for a vendor not in the table.
    #>
    [CmdletBinding()]
    param([string]$Vendor, [string]$Model, [string]$ConfigRoot = $script:ConfigRoot)
    $table = Get-Content -LiteralPath (Join-Path (Join-Path $ConfigRoot 'san') 'msdsm-vendors.json') -Raw | ConvertFrom-Json -Depth 10
    foreach ($v in $table.vendors) {
        if ($Vendor -notmatch "(?i)^($($v.match))") { continue }
        if ($v.model -and $Model -notmatch "(?i)($($v.model))") { continue }
        return [pscustomobject]@{ Hardware = @($v.hardware); MpioSettings = $v.mpioSettings; LoadBalancePolicy = [string]$table.loadBalancePolicy }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------------
# The spec: what one node should be
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlNodeSpec {
    <#
    .SYNOPSIS
        What one node should look like, from infrastructure.yml (schema 5) and, when given, the ZTP handoff.
    .DESCRIPTION
        Ports come from nodes[].network_adapters (or the one management port made from nodes[].management). The management
        port is the one Get-AzlManagementAdapter names, and it is found on the node by its MAC.
        The handoff adds the Arc machine's resource ID, the installed build and managementAddressVerified.
    .PARAMETER SbeBundle
        The result of Get-AzlSbeBundle. Without it the SBE and driver steps are reported as not configured.
    .EXAMPLE
        Get-AzlNodeSpec -Infrastructure $infra -Node $infra.nodes[0] -Handoff (Read-AzlHandoff ./ztp-handoff.json)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Node,
        [object]$Handoff,
        [object]$SbeBundle,
        [string]$ConfigRoot = $script:ConfigRoot
    )
    $name = [string]$Node['name']
    $arcName = Get-AzlArcMachineName -Node $Node
    $handoffNode = Get-AzlHandoffNode -Handoff $Handoff -Name $name -ArcMachineName $arcName
    $mgmt = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $Node
    if (-not $mgmt) { throw "Node $name has no single management port (role management with an address). Check nodes[].network_adapters." }
    if (-not $mgmt.MacAddress) { throw "Node $name's management port has no mac_address. Ports are found by MAC, so it is required." }
    $modeLabel = (Get-AzlManagementMode -Infrastructure $Infrastructure -Node $Node).Label

    $ports = foreach ($p in @(Get-AzlNodeNetworkAdapter -Infrastructure $Infrastructure -Node $Node)) {
        $roles = @(ConvertTo-List $p['roles'] | ForEach-Object { [string]$_ })
        $isMgmt = (ConvertTo-MacKey $p['mac_address']) -eq (ConvertTo-MacKey $mgmt.MacAddress)
        [pscustomobject]@{
            Name         = [string]$p['name']
            Mac          = ConvertTo-MacKey $p['mac_address']
            Roles        = $roles
            IpAssignment = [string]$p['ip_assignment']
            IpAddress    = $(if ($p.Contains('ip_address')) { [string]$p['ip_address'] } else { $null })
            PrefixLength = $(if ($p.Contains('prefix_length')) { [int]$p['prefix_length'] } elseif ($isMgmt) { $mgmt.PrefixLength } else { $null })
            Gateway      = $(if ($isMgmt) { $mgmt.Gateway } else { $null })
            IsManagement = $isMgmt
        }
    }

    $local = Get-AzlProp $Infrastructure 'identity.local_admin'
    $architecture = [string](Get-AzlProp $Infrastructure 'scenario.storage_architecture' 's2d')
    $san = $null
    if ($architecture -in 'san', 'hybrid') {
        $array = Get-AzlProp $Infrastructure 'storage.san.array'
        $vendor = [string](Get-AzlProp $array 'vendor' '')
        $model = [string](Get-AzlProp $array 'model' '')
        $wwpns = @(foreach ($hba in ConvertTo-List (Get-AzlProp $Node 'san.hbas')) { foreach ($port in ConvertTo-List (Get-AzlProp $hba 'ports')) { ConvertTo-WwpnKey (Get-AzlProp $port 'wwpn') } })
        $san = [pscustomobject]@{
            Architecture = $architecture
            Type         = [string](Get-AzlProp $Infrastructure 'storage.san.type' '')
            Vendor       = $vendor
            Model        = $model
            Msdsm        = $(if ($vendor) { Get-AzlSanVendor -Vendor $vendor -Model $model -ConfigRoot $ConfigRoot } else { $null })
            ExpectedWwpn = $wwpns
            InfraLunId   = [string](Get-AzlProp $Infrastructure 'storage.san.infra_volume_lun_id' '')
            PerfLunId    = [string](Get-AzlProp $Infrastructure 'storage.san.performance_history_lun_id' '')
            CheckLuns    = ($architecture -eq 'san')
        }
    }

    $sbe = $null
    if ($SbeBundle) {
        $oem = Get-AzlOemConfig -Vendor ([string](Get-AzlProp $Infrastructure 'hardware.vendor' 'Dell')) -ConfigRoot $ConfigRoot
        $delivery = [string](Get-AzlProp $Infrastructure 'hardware.sbe.delivery' 'skip')
        if (-not $delivery) { $delivery = 'skip' }
        $sbe = [pscustomobject]@{ Name = $SbeBundle.Name; ZipName = $SbeBundle.ZipName; Dir = 'C:\SBE'; Files = @($SbeBundle.Files); DriverPaths = @($oem.sbe.driverPaths)
            Delivery = $delivery; PullUrl = [string](Get-AzlProp $Infrastructure 'hardware.sbe.node_pull_url' '') }
    }

    [pscustomobject]@{
        Name           = $name
        ArcMachineName = $arcName
        ArcResourceId  = [string](Get-AzlProp $handoffNode 'arcMachineResourceId' '')
        Hostname       = $name
        Management     = [pscustomobject]@{ Mac = ConvertTo-MacKey $mgmt.MacAddress; Name = $mgmt.Name; Ip = $mgmt.IpAddress; Prefix = $mgmt.PrefixLength; Gateway = $mgmt.Gateway; Dns = @($mgmt.DnsServers); Vlan = $mgmt.VlanId; Mode = $mgmt.IpAssignment; ModeLabel = $modeLabel }
        Ports          = @($ports)
        Ntp            = @(ConvertTo-List (Get-AzlProp $Infrastructure 'networking.ntp_servers') | ForEach-Object { [string]$_ })
        LocalAdmin     = $(if ($local) { [pscustomobject]@{ Username = [string](Get-AzlProp $local 'username' ''); PasswordRef = [string](Get-AzlProp $local 'password' '') } } else { $null })
        Sbe            = $sbe
        San            = $san
        Architecture   = $architecture
        Handoff        = [pscustomobject]@{
            Present                   = [bool]$handoffNode
            ManagementAddressVerified = $(if ($handoffNode) { [bool](Get-AzlProp $handoffNode 'managementAddressVerified' $false) } else { $null })
            Reason                    = [string](Get-AzlProp $handoffNode 'managementAddressReason' '')
            ManagementMode            = [string](Get-AzlProp $handoffNode 'managementMode.mode' '')
            InstalledBuild            = $(if ($Handoff) { $Handoff.VsrVersion } else { '' })
        }
        ExpectedBuild  = [string](Get-AzlProp $Infrastructure 'provisioning.os_version' '')
    }
}

function Get-AzlNodeReadParameter {
    # What the Read script needs to know about the spec; never a secret.
    param([Parameter(Mandatory)][object]$Spec)
    $p = @{ mgmtMac = $Spec.Management.Mac; san = [bool]$Spec.San; sanDisks = [bool]($Spec.San -and $Spec.San.CheckLuns); sanType = $(if ($Spec.San) { $Spec.San.Type } else { '' }) }
    if ($Spec.Sbe) {
        $p.sbeDir = $Spec.Sbe.Dir
        $p.sbeZip = $Spec.Sbe.ZipName
        $p.driverPaths = @($Spec.Sbe.DriverPaths)
        $p.sbeFiles = @($Spec.Sbe.Files | ForEach-Object { @{ name = $_.Name; size = $_.Size; sha256 = $_.Sha256 } })
    }
    if ($Spec.LocalAdmin -and $Spec.LocalAdmin.Username) { $p.adminUser = $Spec.LocalAdmin.Username }
    return $p
}

# ---------------------------------------------------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlPlanItem {
    param(
        [string]$Node, [string]$Step, [string]$Item, [string]$Current, [string]$Desired,
        [ValidateSet('Ok', 'Change', 'Blocked', 'Info', 'Skipped')][string]$Action,
        [string]$Note = '', [hashtable]$Apply
    )
    [pscustomobject]@{ Node = $Node; Step = $Step; Item = $Item; Current = $Current; Desired = $Desired; Action = $Action; Note = $Note; Apply = $Apply }
}

function Get-DhcpStatePeer([string]$Peers) {
    @($Peers -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -replace ',0x[0-9a-fA-F]+$', '').ToLowerInvariant() } | Sort-Object -Unique)
}

function Test-VersionLess([string]$Have, [string]$Want) {
    $a = $null; $b = $null
    if ([version]::TryParse($Have, [ref]$a) -and [version]::TryParse($Want, [ref]$b)) { return $a -lt $b }
    return $Have -ne $Want
}

function Compare-AzlNodeState {
    <#
    .SYNOPSIS
        Compares a node's spec with its state and returns one plan item per thing checked.
    .DESCRIPTION
        Pure. Actions: Ok (matches), Change (will be changed; Apply holds the node action), Blocked (wrong, and this tool
        can't or shouldn't fix it), Info (worth knowing), Skipped (waits for an earlier step or isn't relevant).
        -Step limits the comparison. -ClearStorage lets leftover storage be a Change instead of a Blocked item.
    .EXAMPLE
        Compare-AzlNodeState -Spec $spec -State $state | Where-Object Action -eq Change
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$State,
        [string[]]$Step = $script:AllSteps,
        [switch]$ClearStorage
    )
    $n = $Spec.Name
    # JSON turns an empty array into null; drop the nulls so an empty list counts as empty.
    $nics = @(Get-AzlProp $State 'nics' @() | ForEach-Object {
            $copy = $_.PSObject.Copy()
            foreach ($list in 'ips', 'gw', 'dns') { $copy.$list = @($copy.$list | Where-Object { $_ }) }
            $copy
        })
    $items =[System.Collections.Generic.List[object]]::new()
    $add = { param($i) $items.Add($i) }

    # ---- remote management, ping
    if ('RemoteManagement' -in $Step) {
        $r = Get-AzlProp $State 'remote'
        if (-not $r) { & $add (New-AzlPlanItem $n 'RemoteManagement' 'state' 'unreadable' 'readable' Info (Get-AzlProp $State 'err.remote' '')) }
        else {
            $ok = $r.winrm -eq 'Running' -and $r.winrmStart -eq 'Automatic' -and $r.listeners -gt 0
            & $add (New-AzlPlanItem $n 'RemoteManagement' 'WinRM' "$($r.winrm)/$($r.winrmStart), $($r.listeners) listener(s)" 'Running/Automatic with a listener' $(if ($ok) { 'Ok' } else { 'Change' }) '' $(if (-not $ok) { @{ id = 'RemoteManagement/WinRM'; kind = 'winrm' } }))
            $ok = $r.rdpDeny -eq 0 -and $r.rdpRules -gt 0
            & $add (New-AzlPlanItem $n 'RemoteManagement' 'RDP' "deny=$($r.rdpDeny), $($r.rdpRules) rule(s)" 'allowed, firewall group on' $(if ($ok) { 'Ok' } else { 'Change' }) '' $(if (-not $ok) { @{ id = 'RemoteManagement/RDP'; kind = 'rdp' } }))
            $ok = $r.icmp4 -gt 0 -and $r.icmp6 -gt 0
            & $add (New-AzlPlanItem $n 'RemoteManagement' 'ICMP' "v4=$($r.icmp4) v6=$($r.icmp6)" 'echo rules on' $(if ($ok) { 'Ok' } else { 'Change' }) '' $(if (-not $ok) { @{ id = 'RemoteManagement/ICMP'; kind = 'icmp' } }))
        }
    }

    # ---- the SBE package in C:\SBE. Worked out here (the drivers need to know whether the package is on the node) but listed
    # last, where the step runs. How a missing file reaches the node is hardware.sbe.delivery: winrm_copy, node_pull or skip.
    $sbeReady = $false
    $sbeItems = [System.Collections.Generic.List[object]]::new()
    if ($Spec.Sbe) {
        $sbeState = @(Get-AzlProp $State 'sbe' @())
        $missing = 0
        $delivery = [string]$Spec.Sbe.Delivery
        foreach ($f in $Spec.Sbe.Files) {
            $have = $sbeState | Where-Object { $_.n -eq $f.Name } | Select-Object -First 1
            $ok = $have -and $have.ok
            if (-not $ok) { $missing++ }
            if ('Sbe' -in $Step) {
                $current = if (-not $have -or $have.len -eq 0) { 'absent' } elseif (-not $have.ok) { "$($have.len) bytes, hash differs" } else { 'present, hash matches' }
                $path = "$($Spec.Sbe.Dir)\$($f.Name)"
                $wanted = 'present, SHA-256 matches'
                if ($ok) { $sbeItems.Add((New-AzlPlanItem $n 'Sbe' $path $current $wanted Ok)); continue }
                switch ($delivery) {
                    'node_pull' {
                        if (-not $Spec.Sbe.PullUrl) { $sbeItems.Add((New-AzlPlanItem $n 'Sbe' $path $current $wanted Blocked 'hardware.sbe.delivery is node_pull but hardware.sbe.node_pull_url is empty.')) }
                        else {
                            $url = Get-AzlSbePullUrl -Base $Spec.Sbe.PullUrl -Name $f.Name
                            $sbeItems.Add((New-AzlPlanItem $n 'Sbe' $path $current $wanted Change "node_pull: the node downloads it from $url and checks the SHA-256." @{ id = "Sbe/$($f.Name)"; kind = 'sbe-file'; route = 'node_pull'; name = $f.Name; sha256 = $f.Sha256; size = $f.Size; url = $url }))
                        }
                    }
                    'winrm_copy' { $sbeItems.Add((New-AzlPlanItem $n 'Sbe' $path $current $wanted Change 'winrm_copy: copied over WinRM from the host running this script (it must reach the node on TCP 5985), then the SHA-256 is checked on the node.' @{ id = "Sbe/$($f.Name)"; kind = 'sbe-file'; route = 'winrm_copy'; name = $f.Name; sha256 = $f.Sha256; localPath = $f.Path; size = $f.Size })) }
                    default { $sbeItems.Add((New-AzlPlanItem $n 'Sbe' $path $current $wanted Info 'NOT DELIVERED: hardware.sbe.delivery is skip (nothing configured), so the toolkit leaves the package alone and installs no OEM driver. Put the files in C:\SBE yourself, or set hardware.sbe.delivery to node_pull or winrm_copy.')) }
                }
            }
        }
        $sbeReady = ($missing -eq 0)
    }
    elseif ('Sbe' -in $Step) { $sbeItems.Add((New-AzlPlanItem $n 'Sbe' 'package' 'not configured' 'hardware.sbe.bundle_path' Info 'No SBE folder given, so no package is delivered and no OEM driver is installed.')) }

    # ---- OEM network drivers
    if ('Drivers' -in $Step -and $Spec.Sbe) {
        if (-not $sbeReady) { & $add (New-AzlPlanItem $n 'Drivers' 'network drivers' 'unknown' 'SBE versions' Skipped 'Decided after the SBE is on the node.') }
        else {
            $drv = @(Get-AzlProp $State 'drv' @())
            $planned = @{}
            foreach ($nic in $nics) {
                if (-not $nic.pci) { continue }
                $match = @($drv | Where-Object { @($_.ids) -contains $nic.pci }) | Sort-Object { $v = $null; if ([version]::TryParse($_.ver, [ref]$v)) { $v } else { [version]'0.0' } } -Descending | Select-Object -First 1
                if (-not $match) {
                    if ($nic.pci) { & $add (New-AzlPlanItem $n 'Drivers' $nic.n $nic.drv "none in the SBE for $($nic.pci)" Info 'The inbox driver stays.') }
                    continue
                }
                if ($nic.drv -eq $match.ver) { & $add (New-AzlPlanItem $n 'Drivers' $nic.n $nic.drv $match.ver Ok); continue }
                if (-not (Test-VersionLess $nic.drv $match.ver)) { & $add (New-AzlPlanItem $n 'Drivers' $nic.n $nic.drv $match.ver Info 'Newer than the SBE; left alone.'); continue }
                if ($planned.ContainsKey($match.inf)) { & $add (New-AzlPlanItem $n 'Drivers' $nic.n $nic.drv $match.ver Change "Same driver as $($planned[$match.inf])."); continue }
                $planned[$match.inf] = $nic.n
                $folder = ($match.entry -replace '[\\/]', '_') -replace '[^A-Za-z0-9_.-]', ''
                & $add (New-AzlPlanItem $n 'Drivers' $nic.n $nic.drv $match.ver Change $match.inf @{ id = "Drivers/$($match.inf)"; kind = 'driver'; zip = $Spec.Sbe.ZipName; entry = $match.entry; inf = $match.inf; ver = $match.ver; folder = "$($Spec.Sbe.Name)_$folder" })
            }
        }
    }

    # ---- ports: DHCP off where the file says none, the management address, the other static ports
    if ('Network' -in $Step) {
        $mgmt = $Spec.Management
        $known = @{}
        foreach ($p in $Spec.Ports) { if ($p.Mac) { $known[$p.Mac] = $p } }
        $gatewayHolders = [System.Collections.Generic.List[string]]::new()
        # The management port first: its static address (Modes B and C) is applied before any other port loses DHCP and its
        # gateway, so a node reached over Arc through another port (Mode C: the provisioning port) keeps a way out.
        foreach ($nic in @($nics | Sort-Object -Stable { $_.mac -ne $mgmt.Mac })) {
            $port = $known[$nic.mac]
            $routable = @($nic.ips | Where-Object { $_ -notlike '169.254.*' })
            $hasGw = @($nic.gw).Count -gt 0
            $label = "$($nic.n) ($($nic.mac))"
            if (-not $port) {
                if ($hasGw) { $gatewayHolders.Add($nic.n); & $add (New-AzlPlanItem $n 'Network' $label "gateway $(@($nic.gw) -join ',')" 'not in the file' Blocked 'A port the file doesn''t list holds a default gateway. List it in nodes[].network_adapters with ip_assignment none.') }
                elseif ($routable.Count) { & $add (New-AzlPlanItem $n 'Network' $label ($routable -join ',') 'not in the file' Info 'A port the file doesn''t list has an address; left alone.') }
                continue
            }
            if ($port.IsManagement) {
                $want = "$($mgmt.Ip)/$($mgmt.Prefix)"
                if ($mgmt.Mode -eq 'static') {
                    $addressOk = @($nic.ips | Where-Object { $_ -eq "$want/Manual" }).Count -gt 0
                    $gwOk = @($nic.gw) -contains $mgmt.Gateway
                    $ok = $addressOk -and $gwOk -and $nic.dhcp -eq 'Disabled'
                    $current = "$(@($routable) -join ',') gw $(@($nic.gw) -join ',') dhcp $($nic.dhcp)"
                    $note = if ($ok) { '' } elseif ($Spec.Handoff.Present -and $Spec.Handoff.ManagementAddressVerified -eq $false) { "ZTP didn't verify it: $($Spec.Handoff.Reason)" } else { "$($mgmt.ModeLabel): set by MAC (Microsoft's OS install resets every port to DHCP)." }
                    & $add (New-AzlPlanItem $n 'Network' "management $label" $current "static $want gw $($mgmt.Gateway)" $(if ($ok) { 'Ok' } else { 'Change' }) $note $(if (-not $ok) { @{ id = "Network/$($nic.mac)"; kind = 'nic-static'; mac = $nic.mac; ip = $mgmt.Ip; prefix = $mgmt.Prefix; gateway = $mgmt.Gateway } }))
                }
                else {
                    # Never changed: dhcp_reservation (Mode A) keeps DHCP and is verified; dhcp and preconfigured are left alone.
                    $current = if ($routable.Count) { "$(@($routable) -join ',') dhcp $($nic.dhcp)" } else { "no address, dhcp $($nic.dhcp)" }
                    switch ($mgmt.Mode) {
                        'dhcp_reservation' {
                            $has = if ($mgmt.Ip) { @($nic.ips | Where-Object { $_ -like "$($mgmt.Ip)/*" }).Count -gt 0 } else { $routable.Count -gt 0 }
                            $note = if (-not $has -and $mgmt.Ip) { "Mode A (Reserved): expected the reserved $($mgmt.Ip) from DHCP; check the reservation for MAC $($nic.mac)." }
                            elseif (-not $has) { "Mode A (Reserved): no DHCP address; check that the DHCP server answers and holds the reservation for MAC $($nic.mac)." }
                            elseif (-not $mgmt.Ip) { 'Mode A (Reserved): has a DHCP address; the file gives no ip_address, so the reserved address can''t be compared.' }
                            elseif ($nic.dhcp -eq 'Disabled') { 'Mode A (Reserved): the address is there, but DHCP is off on the port; the reservation no longer applies. Left as it is.' }
                            else { '' }
                            & $add (New-AzlPlanItem $n 'Network' "management $label" $current "dhcp_reservation$(if ($mgmt.Ip) { " ($($mgmt.Ip))" })" $(if ($has) { 'Ok' } else { 'Info' }) $note)
                        }
                        'dhcp' { & $add (New-AzlPlanItem $n 'Network' "management $label" $current 'dhcp' $(if ($routable.Count) { 'Ok' } else { 'Info' }) 'Left as it is: dhcp without a reservation, so the address can change. Use dhcp_reservation (Mode A) or static.') }
                        default { & $add (New-AzlPlanItem $n 'Network' "management $label" $current $mgmt.Mode Ok 'Left as it is.') }
                    }
                }
                if ($mgmt.Vlan -gt 0 -and $nic.vlan -ne $mgmt.Vlan) { & $add (New-AzlPlanItem $n 'Network' "management VLAN" "$($nic.vlan)" "$($mgmt.Vlan)" Info 'The host should tag this VLAN (vlan_mode tagged). This tool does not set it; set it on the port or the switch.') }
                if ($hasGw -or $mgmt.Mode -eq 'static') { $gatewayHolders.Add($nic.n) }
                continue
            }
            switch ($port.IpAssignment) {
                'none' {
                    $dirty = $nic.dhcp -eq 'Enabled' -or $routable.Count -gt 0 -or $hasGw
                    $current = "dhcp $($nic.dhcp), $(if ($routable.Count) { $routable -join ',' } else { 'no address' }), $(if ($hasGw) { 'gateway' } else { 'no gateway' })"
                    & $add (New-AzlPlanItem $n 'Network' $label $current 'dhcp off, no address, no gateway' $(if ($dirty) { 'Change' } else { 'Ok' }) '' $(if ($dirty) { @{ id = "Network/$($nic.mac)"; kind = 'nic-clean'; mac = $nic.mac } }))
                }
                'static' {
                    $want = "$($port.IpAddress)/$($port.PrefixLength)"
                    $ok = @($nic.ips | Where-Object { $_ -eq "$want/Manual" }).Count -gt 0 -and -not $hasGw
                    & $add (New-AzlPlanItem $n 'Network' $label (@($routable) -join ',') "static $want, no gateway" $(if ($ok) { 'Ok' } else { 'Change' }) '' $(if (-not $ok) { @{ id = "Network/$($nic.mac)"; kind = 'nic-static'; mac = $nic.mac; ip = $port.IpAddress; prefix = $port.PrefixLength } }))
                }
                default {
                    if ($hasGw) { $gatewayHolders.Add($nic.n); & $add (New-AzlPlanItem $n 'Network' $label "gateway $(@($nic.gw) -join ',')" 'no gateway' Blocked "ip_assignment $($port.IpAssignment) holds a second default gateway; validation fails with more than one.") }
                    else { & $add (New-AzlPlanItem $n 'Network' $label (@($routable) -join ',') $port.IpAssignment Ok 'Left as it is.') }
                }
            }
        }
        $wantNic = $nics | Where-Object { $_.mac -eq $mgmt.Mac } | Select-Object -First 1
        if (-not $wantNic) { & $add (New-AzlPlanItem $n 'Network' "management MAC $($mgmt.Mac)" 'no port has it' 'one port' Blocked 'No adapter on the node has the management MAC from the file.') }
    }

    # ---- DNS on the management port
    if ('Dns' -in $Step -and $Spec.Management.Mode -eq 'static' -and @($Spec.Management.Dns).Count) {
        $nic = $nics | Where-Object { $_.mac -eq $Spec.Management.Mac } | Select-Object -First 1
        if ($nic) {
            $ok = (@($nic.dns) -join ',') -eq (@($Spec.Management.Dns) -join ',')
            & $add (New-AzlPlanItem $n 'Dns' $nic.n (@($nic.dns) -join ',') (@($Spec.Management.Dns) -join ',') $(if ($ok) { 'Ok' } else { 'Change' }) 'DNS servers can''t change after deployment.' $(if (-not $ok) { @{ id = 'Dns/management'; kind = 'nic-dns'; mac = $nic.mac; servers = @($Spec.Management.Dns) } }))
        }
    }

    # ---- time
    if ('Time' -in $Step -and @($Spec.Ntp).Count) {
        $t = Get-AzlProp $State 'time'
        if ($t) {
            $have = Get-DhcpStatePeer ([string]$t.peers)
            $want = @($Spec.Ntp | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
            $ok = ($t.type -like 'NTP*') -and (($have -join ',') -eq ($want -join ','))
            $note = if ($ok -and $t.src -match 'Local CMOS|Free-running') { "Configured, but the source is still '$($t.src)'." } else { '' }
            & $add (New-AzlPlanItem $n 'Time' 'NTP peers' "$($t.type): $($have -join ',') (source $($t.src))" ($want -join ',') $(if ($ok) { 'Ok' } else { 'Change' }) $note $(if (-not $ok) { @{ id = 'Time/ntp'; kind = 'ntp'; servers = @($Spec.Ntp) } }))
        }
    }

    # ---- host name
    if ('Hostname' -in $Step) {
        $host_ = [string](Get-AzlProp $State 'host' '')
        $ok = $host_ -ieq $Spec.Hostname
        & $add (New-AzlPlanItem $n 'Hostname' 'computer name' $host_ $Spec.Hostname $(if ($ok) { 'Ok' } else { 'Change' }) $(if (-not $ok) { 'Needs a restart.' } else { '' }) $(if (-not $ok) { @{ id = 'Hostname/name'; kind = 'hostname'; name = $Spec.Hostname } }))
    }

    # ---- ports the file marks unused
    if ('UnusedAdapters' -in $Step) {
        foreach ($p in $Spec.Ports | Where-Object { @($_.Roles).Count -eq 1 -and $_.Roles[0] -eq 'unused' }) {
            $nic = $nics | Where-Object { $_.mac -eq $p.Mac } | Select-Object -First 1
            if (-not $nic) { & $add (New-AzlPlanItem $n 'UnusedAdapters' $p.Name 'not found' 'disabled' Info "No port with MAC $($p.Mac)."); continue }
            $ok = $nic.st -eq 'Disabled'
            & $add (New-AzlPlanItem $n 'UnusedAdapters' "$($nic.n) ($($nic.mac))" $nic.st 'Disabled' $(if ($ok) { 'Ok' } else { 'Change' }) '' $(if (-not $ok) { @{ id = "UnusedAdapters/$($nic.mac)"; kind = 'nic-disable'; mac = $nic.mac } }))
        }
    }

    # ---- the deployment's local administrator
    if ('LocalAdmin' -in $Step -and $Spec.LocalAdmin -and $Spec.LocalAdmin.Username) {
        $user = $Spec.LocalAdmin.Username
        if ($user -in 'Administrator', 'Guest') { & $add (New-AzlPlanItem $n 'LocalAdmin' $user 'built-in account' 'a named account' Blocked 'The deployment can''t use the built-in Administrator. Set identity.local_admin.username to another name.') }
        else {
            $a = Get-AzlProp $State 'admin'
            if (-not $a) { & $add (New-AzlPlanItem $n 'LocalAdmin' $user 'unreadable' 'present' Info (Get-AzlProp $State 'err.admin' '')) }
            else {
                $problems = @()
                if (-not $a.ex) { $problems += 'missing' } else {
                    if (-not $a.en) { $problems += 'disabled' }
                    if (-not $a.adm) { $problems += 'not in Administrators' }
                    if ($a.pw -eq $false) { $problems += 'password differs' }
                }
                $current = if ($problems) { $problems -join ', ' } elseif ($null -eq $a.pw) { 'present (password not checked)' } else { 'present, password valid' }
                & $add (New-AzlPlanItem $n 'LocalAdmin' $user $current 'present, enabled, in Administrators, password from Key Vault' $(if ($problems) { 'Change' } else { 'Ok' }) '' $(if ($problems) { @{ id = 'LocalAdmin/user'; kind = 'admin'; user = $user; setPassword = ($a.pw -eq $false -or -not $a.ex) } }))
            }
        }
    }

    # ---- SAN: MPIO, MSDSM, iSCSI
    $sanState = Get-AzlProp $State 'san'
    if ('Mpio' -in $Step -and $Spec.San) {
        if (-not $sanState) { & $add (New-AzlPlanItem $n 'Mpio' 'state' 'unreadable' 'readable' Info (Get-AzlProp $State 'err.san' '')) }
        else {
            $featureOn = [string]$sanState.feature -eq 'Enabled'
            & $add (New-AzlPlanItem $n 'Mpio' 'MultipathIO feature' $sanState.feature 'Enabled' $(if ($featureOn) { 'Ok' } else { 'Change' }) $(if (-not $featureOn) { 'Needs a restart. Azure Local 2604 and later enable it by default.' } else { '' }) $(if (-not $featureOn) { @{ id = 'Mpio/feature'; kind = 'mpio-feature' } }))
            if (-not $featureOn) { & $add (New-AzlPlanItem $n 'Mpio' 'MSDSM' 'unknown' 'registered' Skipped 'Checked after MPIO is enabled and the node has restarted.') }
            elseif ($Spec.San.Msdsm) {
                foreach ($hw in $Spec.San.Msdsm.Hardware) {
                    $key = "$($hw.vendorId)|$($hw.productId)"
                    $have = @($sanState.hw | Where-Object { $_ -ieq $key }).Count -gt 0
                    $apply = @{ id = "Mpio/hw-$($hw.productId)"; kind = 'msdsm-hw'; vendor = $hw.vendorId; product = $hw.productId }
                    if ($hw.PSObject.Properties['mpclaim']) { $apply.mpclaim = $hw.mpclaim }
                    & $add (New-AzlPlanItem $n 'Mpio' "MSDSM $key" $(if ($have) { 'registered' } else { 'absent' }) 'registered' $(if ($have) { 'Ok' } else { 'Change' }) $(if (-not $have) { 'Needs a restart before MPIO claims the LUNs.' } else { '' }) $(if (-not $have) { $apply }))
                }
                $lbWant = $Spec.San.Msdsm.LoadBalancePolicy
                $lbOk = [string]$sanState.lb -ieq $lbWant
                & $add (New-AzlPlanItem $n 'Mpio' 'load balance policy' $sanState.lb $lbWant $(if ($lbOk) { 'Ok' } else { 'Change' }) '' $(if (-not $lbOk) { @{ id = 'Mpio/lb'; kind = 'msdsm-lb'; policy = $lbWant } }))
                $candidates = @{ RetryCount = @('RetryCount'); CustomPathRecovery = @('UseCustomPathRecoveryTime', 'CustomPathRecovery'); PathRecoveryInterval = @('CustomPathRecoveryTime', 'PathRecoveryInterval'); DiskTimeout = @('DiskTimeoutValue', 'DiskTimeout'); PDORemovePeriod = @('PDORemovePeriod'); PathVerificationState = @('PathVerificationState') }
                $differ = [ordered]@{}
                foreach ($prop in $Spec.San.Msdsm.MpioSettings.PSObject.Properties) {
                    $names = $candidates[$prop.Name]
                    $current = $null
                    foreach ($c in $names) { if ($sanState.set.PSObject.Properties[$c]) { $current = [string]$sanState.set.PSObject.Properties[$c].Value; break } }
                    if ($null -eq $current) { & $add (New-AzlPlanItem $n 'Mpio' "MPIO $($prop.Name)" 'not readable' ([string]$prop.Value) Info 'The node didn''t report this MPIO setting.'); continue }
                    if ($current -ine [string]$prop.Value) { $differ[$prop.Name] = $prop.Value; & $add (New-AzlPlanItem $n 'Mpio' "MPIO $($prop.Name)" $current ([string]$prop.Value) Change $(if ($differ.Count -gt 1) { 'Set together with the other MPIO settings.' })) }
                    else { & $add (New-AzlPlanItem $n 'Mpio' "MPIO $($prop.Name)" $current ([string]$prop.Value) Ok) }
                }
                if ($differ.Count) {
                    $first = $items | Where-Object { $_.Step -eq 'Mpio' -and $_.Action -eq 'Change' -and $_.Item -like 'MPIO *' } | Select-Object -First 1
                    $first.Apply = @{ id = 'Mpio/settings'; kind = 'mpio-setting'; settings = $differ }
                }
            }
            else { & $add (New-AzlPlanItem $n 'Mpio' 'MSDSM vendor' "$($Spec.San.Vendor) $($Spec.San.Model)" 'a row in config/san/msdsm-vendors.json' Info 'No MSDSM hardware ID is known for this array; add it to config/san/msdsm-vendors.json (Learn: enable-external-storage, step 2).') }
            if ($Spec.San.Type -eq 'iscsi') {
                $svcOk = [string]$sanState.iscsiSvc -eq 'Running/Automatic'
                & $add (New-AzlPlanItem $n 'Mpio' 'MSiSCSI service' $sanState.iscsiSvc 'Running/Automatic' $(if ($svcOk) { 'Ok' } else { 'Change' }) '' $(if (-not $svcOk) { @{ id = 'Mpio/iscsi-service'; kind = 'iscsi-service' } }))
                $claimOk = [string]$sanState.iscsiClaim -eq 'True'
                & $add (New-AzlPlanItem $n 'Mpio' 'iSCSI auto-claim' $sanState.iscsiClaim 'True' $(if ($claimOk) { 'Ok' } else { 'Change' }) 'Restart the node if LUNs are already visible.' $(if (-not $claimOk) { @{ id = 'Mpio/iscsi-claim'; kind = 'iscsi-claim' } }))
            }
        }
    }

    # ---- SAN: what the node sees (read only; nothing here changes the node)
    if ('SanVerify' -in $Step -and $Spec.San -and $sanState) {
        if ($Spec.San.Type -ne 'iscsi') {
            $found = @($sanState.fc | Where-Object { $_ } | ForEach-Object { $_.wwpn })
            $expected = @($Spec.San.ExpectedWwpn)
            if (-not $expected.Count) { & $add (New-AzlPlanItem $n 'SanVerify' 'FC initiator ports' ($found -join ', ') 'nodes[].san.hbas' Info 'The file lists no WWPN for this node. Give these to the fabric administrator for zoning, and record them in nodes[].san.') }
            else {
                foreach ($w in $expected) {
                    $seen = $found -contains $w
                    & $add (New-AzlPlanItem $n 'SanVerify' "WWPN $w" $(if ($seen) { 'seen' } else { 'not seen' }) 'seen' $(if ($seen) { 'Ok' } else { 'Blocked' }) $(if (-not $seen) { 'No FC initiator port reports this WWPN: HBA driver missing, the port is down, or the file is wrong.' } else { '' }))
                }
                foreach ($w in $found | Where-Object { $_ -notin $expected }) { & $add (New-AzlPlanItem $n 'SanVerify' "WWPN $w" 'seen' 'not in the file' Info 'Add it to nodes[].san.hbas[].ports.') }
            }
        }
        if ($Spec.San.CheckLuns) {
            $disks = @($sanState.disks | Where-Object { $_ })
            foreach ($lun in @(@{ Name = 'infrastructure volume'; Id = $Spec.San.InfraLunId; MinGb = 250 }, @{ Name = 'performance history volume'; Id = $Spec.San.PerfLunId; MinGb = 20 })) {
                if (-not $lun.Id) { continue }
                $disk = $disks | Where-Object { [string]$_.lun -eq $lun.Id -or $_.sn -ieq $lun.Id -or $_.uid -ieq $lun.Id } | Select-Object -First 1
                if (-not $disk) { & $add (New-AzlPlanItem $n 'SanVerify' "$($lun.Name) (LUN $($lun.Id))" 'not visible' "visible, RAW, >= $($lun.MinGb) GB" Blocked 'Zone this node''s WWPNs to the array and present the LUN to it (FC zoning and LUN masking are done on the fabric and the array, not here).'); continue }
                $bad = @()
                if ($disk.gb -lt $lun.MinGb) { $bad += "$($disk.gb) GB < $($lun.MinGb) GB" }
                if ($disk.ps -ne 'RAW') { $bad += "partition style $($disk.ps), must stay RAW until the deployment" }
                $note = "UniqueId $($disk.uid), serial $($disk.sn), $($disk.paths) path(s)"
                if ($disk.paths -lt 2) { $note += '; fewer than 2 MPIO paths' }
                & $add (New-AzlPlanItem $n 'SanVerify' "$($lun.Name) (LUN $($lun.Id))" "disk $($disk.n) $($disk.gb) GB $($disk.ps)" "RAW, >= $($lun.MinGb) GB" $(if ($bad) { 'Blocked' } else { 'Ok' }) $(if ($bad) { ($bad -join '; ') + '. ' + $note } else { $note }))
            }
        }
    }
    elseif ('SanVerify' -in $Step -and $Spec.San -and -not $sanState) { & $add (New-AzlPlanItem $n 'SanVerify' 'SAN state' 'unreadable' 'readable' Info (Get-AzlProp $State 'err.san' '')) }

    # ---- storage left over from an earlier deployment
    if ('ClearStorage' -in $Step) {
        $s = Get-AzlProp $State 'stor'
        if ($s) {
            $dirtyDisks = @($s.dirty | Where-Object { $_ })
            $dirty = [int]$s.pools -gt 0 -or [int]$s.vdisks -gt 0 -or $dirtyDisks.Count -gt 0
            $current = if ($dirty) { "$($s.pools) pool(s), $($s.vdisks) virtual disk(s), disks: $($dirtyDisks -join ' ')" } else { 'clean' }
            if (-not $dirty) { & $add (New-AzlPlanItem $n 'ClearStorage' 'local storage' $current 'clean' Ok) }
            elseif ($ClearStorage) { & $add (New-AzlPlanItem $n 'ClearStorage' 'local storage' $current 'clean' Change 'DESTROYS the data on these local disks. SAN LUNs, USB and boot disks are never touched.' @{ id = 'ClearStorage/local'; kind = 'storage-clear' }) }
            else { & $add (New-AzlPlanItem $n 'ClearStorage' 'local storage' $current 'clean' $(if ($Spec.Architecture -eq 'san') { 'Info' } else { 'Blocked' }) 'Left over from an earlier deployment; Validate rejects disks that are not clean. Run with -ClearStorage to wipe them (destroys data).') }
        }
    }

    # ---- the SBE package, last (see $script:AllSteps)
    foreach ($i in $sbeItems) { & $add $i }

    # ---- build
    $installed = $Spec.Handoff.InstalledBuild
    if ($installed -and $Spec.ExpectedBuild -and $Spec.ExpectedBuild -notin 'latest', 'latest-preview' -and $installed -ne $Spec.ExpectedBuild) {
        & $add (New-AzlPlanItem $n 'Build' 'installed OS build' $installed $Spec.ExpectedBuild Info 'The handoff reports a different build than provisioning.os_version.')
    }
    return $items.ToArray()
}

function Format-AzlPlan {
    <#
    .SYNOPSIS
        A plan (from Compare-AzlNodeState) as a table, with a count line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan)
    $Plan | Format-Table Node, Step, Item, Current, Desired, Action, Note -Wrap -AutoSize | Out-String -Width 220
}

# ---------------------------------------------------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------------------------------------------------

function Wait-AzlNodeRestart {
    param([object]$Transport, [string]$Node, [string]$PreviousBoot, [hashtable]$ReadParameters, [hashtable]$Secrets, [int]$TimeoutMinutes = 30)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Start-Sleep -Seconds 30
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-AzlNodeScript -Transport $Transport -Node $Node -Script (Get-AzlNodePayload -Name Read) -Parameters $ReadParameters -Secrets $Secrets -TimeoutSeconds 600 -Tries 1
            if ($state.boot -ne $PreviousBoot) { return $state }
        }
        catch { Write-Verbose "$Node isn't back yet: $($_.Exception.Message)" }
        Start-Sleep -Seconds 20
    }
    throw "$Node didn't come back with a new boot time within $TimeoutMinutes minutes."
}

function Send-AzlSbePackage {
    <#
    .SYNOPSIS
        Delivers the SBE files the plan marked Change to one node, by the route in hardware.sbe.delivery. Never throws: a
        failure comes back as a result with Status 'failed', so the other steps of the run are not stopped by it.
    .DESCRIPTION
        node_pull   one Apply call; the node downloads each file from the address in the action and checks its SHA-256.
        winrm_copy  Copy-Item over a WinRM session (the transport, or -SbeTransport when the nodes are otherwise reached over
                    Arc), into a .part file whose SHA-256 is checked on the node before it takes its name.
    .OUTPUTS
        One object per file: Name, Id, Status (changed or failed), Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$Transport,
        [object]$SbeTransport,
        [Parameter(Mandatory)][object[]]$Item,
        [hashtable]$Secrets = @{}
    )
    $node = $Spec.Name
    $out = [System.Collections.Generic.List[object]]::new()
    $new = { param($a, $status, $detail) [pscustomobject]@{ Name = [string]$a.name; Id = [string]$a.id; Status = $status; Detail = $detail } }

    $pull = @($Item | ForEach-Object { $_.Apply } | Where-Object { $_.route -eq 'node_pull' })
    if ($pull.Count) {
        try {
            $actions = @($pull | ForEach-Object { $_.Clone() })
            $result = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name Apply) -Parameters @{ actions = $actions; sbeDir = $Spec.Sbe.Dir } -Secrets $Secrets -TimeoutSeconds 3600
            foreach ($a in $pull) {
                $r = @($result.results | Where-Object { $_.id -eq $a.id }) | Select-Object -First 1
                if ($r) { $out.Add((& $new $a $r.status $r.detail)) } else { $out.Add((& $new $a 'failed' 'The node reported no result for this file.')) }
            }
        }
        catch { foreach ($a in $pull) { $out.Add((& $new $a 'failed' "node_pull failed: $($_.Exception.Message)")) } }
    }

    $copy = @($Item | ForEach-Object { $_.Apply } | Where-Object { $_.route -eq 'winrm_copy' })
    if ($copy.Count) {
        $via = if ($SbeTransport) { $SbeTransport } elseif ($Transport.Kind -eq 'WinRM') { $Transport } else { $null }
        $stop = $null
        if (-not $via) { $stop = "winrm_copy needs a WinRM path to $node, and the nodes are reached through $($Transport.Kind). Run this script with -Credential (the nodes' local administrator) from a host that reaches $node on TCP 5985, or set hardware.sbe.delivery to node_pull." }
        foreach ($a in $copy) {
            if ($stop) { $out.Add((& $new $a 'failed' $stop)); continue }
            try {
                $null = Send-AzlNodeFile -Transport $via -Node $node -LocalPath $a.localPath -RemotePath ("$($Spec.Sbe.Dir.TrimEnd('\'))\$($a.name)") -Sha256 $a.sha256
                $out.Add((& $new $a 'changed' "$($a.name) copied over WinRM and SHA-256 verified"))
            }
            catch {
                $stop = "winrm_copy failed: $($_.Exception.Message)"
                $out.Add((& $new $a 'failed' $stop))
            }
        }
    }
    return $out.ToArray()
}

function Invoke-AzlNodeConfiguration {
    <#
    .SYNOPSIS
        Reads a node, compares it with its spec and, with -Execute, changes only what differs, until it matches.
    .DESCRIPTION
        Plan (no -Execute): one Read, the comparison, nothing changed. Execute: Read, compare, Apply the Change items of every
        step except Sbe, restart once if an action asked (and not -NoRestart), deliver the SBE package last (by
        hardware.sbe.delivery), Read again, repeat up to -MaxPasses (a step can wait for an earlier one: the drivers wait for
        the SBE), and finish with the comparison of a last Read. A node that matches its spec gets one Read and no Apply. A
        package that can't be delivered is reported (Sbe step not done) and does not stop the other steps.
    .PARAMETER SbeTransport
        A WinRM transport used only to copy the SBE package (hardware.sbe.delivery winrm_copy) when the nodes are otherwise
        reached over Arc Run Command. Default: -Transport when that is WinRM.
    .PARAMETER SecretResolver
        Scriptblock that turns a keyvault:// reference into its value. Default Get-AzlSecret.
    .OUTPUTS
        One object per node: Node, Transport, Plan (the final comparison), Changes (what the Apply calls did), Blocked,
        Restarted, Converged, State (the last Read), Passes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$Transport,
        [object]$SbeTransport,
        [switch]$Execute,
        [string[]]$Step = $script:AllSteps,
        [switch]$ClearStorage,
        [switch]$NoRestart,
        [int]$MaxPasses = 3,
        [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecret -Reference $Ref }
    )
    $node = $Spec.Name
    $readParameters = Get-AzlNodeReadParameter -Spec $Spec
    $secrets = @{}
    if ($Spec.LocalAdmin -and $Spec.LocalAdmin.PasswordRef -and 'LocalAdmin' -in $Step -and $Spec.LocalAdmin.Username -notin 'Administrator', 'Guest') {
        try { $secrets.adminPassword = [string](& $SecretResolver $Spec.LocalAdmin.PasswordRef) }
        catch {
            if ($Execute) { throw "Can't read the local administrator's password ($($Spec.LocalAdmin.PasswordRef)): $($_.Exception.Message)" }
            Write-Warning "$node`: can't read the local administrator's password, so it isn't checked in this plan: $($_.Exception.Message)"
        }
    }
    $passes = [System.Collections.Generic.List[object]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $restarted = $false
    $sbeTried = @{}
    $state = $null
    $plan = @()
    for ($pass = 1; $pass -le $MaxPasses + 1; $pass++) {
        $state = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name Read) -Parameters $readParameters -Secrets $secrets -TimeoutSeconds 900
        $plan = @(Compare-AzlNodeState -Spec $Spec -State $state -Step $Step -ClearStorage:$ClearStorage)
        $todo = @($plan | Where-Object { $_.Action -eq 'Change' -and $_.Apply })
        # A package file the toolkit already delivered once and that is still wrong is not delivered again: the failure stays
        # in the report (the Sbe step is not done) and the other steps carry on.
        $todo = @($todo | Where-Object { $_.Apply.kind -ne 'sbe-file' -or -not $sbeTried.ContainsKey([string]$_.Apply.name) })
        $passes.Add([pscustomobject]@{ Pass = $pass; Changes = $todo.Count })
        if (-not $Execute -or $todo.Count -eq 0 -or $pass -gt $MaxPasses) { break }

        # Every step except Sbe first, in one Apply call; then, if one asked, the restart; the package last.
        $actions = @($todo | Where-Object { $_.Apply.kind -ne 'sbe-file' } | ForEach-Object { $_.Apply.Clone() })
        $sbeTodo = @($todo | Where-Object { $_.Apply.kind -eq 'sbe-file' })
        $failed = @()
        if ($actions.Count) {
            try { $result = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name Apply) -Parameters @{ actions = $actions; sbeDir = $(if ($Spec.Sbe) { $Spec.Sbe.Dir } else { 'C:\SBE' }) } -Secrets $secrets -TimeoutSeconds 3600 }
            catch {
                # The run ended in state Unknown after every retry: we don't know what happened. Read the node again and decide from that.
                if ($_.Exception.Data['AzlState'] -ne 'Unknown') { throw }
                $changes.Add([pscustomobject]@{ Node = $node; Pass = $pass; Id = 'apply'; Status = 'unknown'; Detail = $_.Exception.Message })
                continue
            }
            foreach ($r in @($result.results)) { $changes.Add([pscustomobject]@{ Node = $node; Pass = $pass; Id = $r.id; Status = $r.status; Detail = $r.detail }) }
            $failed = @($result.results | Where-Object { $_.status -eq 'failed' })
            if (-not $failed -and $result.reboot -and -not $NoRestart) {
                # The node goes away on purpose: a restart that ends in state Unknown is not a failure, the wait below checks the boot time.
                try { $null = Invoke-AzlNodeScript -Transport $Transport -Node $node -Script (Get-AzlNodePayload -Name Restart) -TimeoutSeconds 300 -Tries 1 }
                catch { if ($_.Exception.Data['AzlState'] -ne 'Unknown') { throw } }
                $state = Wait-AzlNodeRestart -Transport $Transport -Node $node -PreviousBoot $state.boot -ReadParameters $readParameters -Secrets $secrets
                $restarted = $true
            }
        }
        if ($sbeTodo.Count) {
            foreach ($r in @(Send-AzlSbePackage -Spec $Spec -Transport $Transport -SbeTransport $SbeTransport -Item $sbeTodo -Secrets $secrets)) {
                $sbeTried[[string]$r.Name] = $true
                $changes.Add([pscustomobject]@{ Node = $node; Pass = $pass; Id = $r.Id; Status = $r.Status; Detail = $r.Detail })
            }
        }
        if ($failed) { $plan = @(Compare-AzlNodeState -Spec $Spec -State $state -Step $Step -ClearStorage:$ClearStorage); break }
    }
    $blocked = @($plan | Where-Object Action -eq 'Blocked')
    $pending = @($plan | Where-Object { $_.Action -eq 'Change' })
    [pscustomobject]@{
        Node      = $node
        Transport = $Transport.Kind
        Plan      = $plan
        Changes   = $changes.ToArray()
        Blocked   = $blocked
        Restarted = $restarted
        Converged = ($pending.Count -eq 0 -and $blocked.Count -eq 0)
        State     = $state
        Passes    = $passes.ToArray()
        Executed  = [bool]$Execute
    }
}

Export-ModuleMember -Function Get-AzlOemConfig, Get-AzlSbeBundle, Get-AzlSbePullUrl, Send-AzlSbePackage, Get-AzlSanVendor, Get-AzlNodeSpec, Get-AzlNodeReadParameter, Compare-AzlNodeState, Format-AzlPlan, Invoke-AzlNodeConfiguration
