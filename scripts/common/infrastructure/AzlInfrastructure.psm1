#Requires -Version 7.0
<#
.SYNOPSIS
    Reads and checks infrastructure.yml, the one environment file for an Azure Local instance (schema 5).

.DESCRIPTION
    Every toolkit script reads the environment through this module, so no script parses keys its own way.

    Import-AzlInfrastructure  Read the file, check it, and return it as a hashtable. Stops when the file has errors.
    Test-AzlInfrastructure    Check the file and return every finding: schema errors first, then the checks that a
                              JSON schema can't express (addresses inside subnets, the infrastructure pool, node counts,
                              Key Vault references). Each finding has an ID, a severity, the key path, a message and,
                              for rules from Microsoft's documentation, the Learn page.
    Get-AzlInfrastructureValue  Read one value by its dotted path, for example networking.management.gateway.

    Needs the powershell-yaml module. The schema is infrastructure.schema.json in config/infrastructure.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultSchemaPath = Join-Path $PSScriptRoot '..\..\..\config\infrastructure\infrastructure.schema.json'
$script:SupportedMajor = 5

$script:Learn = @{
    Decision8   = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-8-determine-management-ips-and-infrastructure-network'
    Decision4   = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-4-determine-cluster-size'
    Topologies  = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-introduction#validated-network-topologies'
    RackAware   = 'https://learn.microsoft.com/azure/azure-local/concepts/rack-aware-cluster-requirements'
    Witness     = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites'
    Quorum      = 'https://learn.microsoft.com/windows-server/storage/storage-spaces/quorum#cluster-quorum-overview'
    Intents     = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#decision-7-determine-network-traffic-intents'
    CustomIp    = 'https://learn.microsoft.com/azure/azure-local/plan/cloud-deployment-network-considerations#custom-ips-for-storage'
    Simplified  = 'https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning'
    Arm         = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template#arm-template-parameters-reference'
}

# ---------------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------------

function New-Finding {
    param([string]$Id, [ValidateSet('error', 'warning', 'info')][string]$Severity, [string]$Path, [string]$Message, [string]$LearnUrl = '')
    [pscustomobject]@{ Id = $Id; Severity = $Severity; Path = $Path; Message = $Message; LearnUrl = $LearnUrl }
}

function Get-AzlInfrastructureValue {
    <#
    .SYNOPSIS
        Reads one value from a loaded infrastructure file by its dotted path. Returns $null when any part is missing.
    .EXAMPLE
        Get-AzlInfrastructureValue -Infrastructure $infra -Path 'networking.management.gateway'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][string]$Path)
    $node = $Infrastructure
    foreach ($part in $Path.Split('.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] } else { return $null }
    }
    return , $node
}

function ConvertTo-UInt32Address([string]$Address) {
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    return [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + [uint64]$bytes[3]
}

function Get-SubnetRange([string]$Cidr) {
    $address, $bits = $Cidr.Split('/')
    # Unsigned arithmetic only: a 0xFFFFFFFF literal is Int32 -1 in PowerShell.
    $size = [uint64]1 -shl (32 - [int]$bits)
    $value = [uint64](ConvertTo-UInt32Address $address)
    $network = $value - ($value % $size)
    [pscustomobject]@{ First = [uint64]$network; Last = [uint64]($network + $size - 1) }
}

function Test-AddressInSubnet([string]$Address, [string]$Cidr) {
    $range = Get-SubnetRange $Cidr
    $value = [uint64](ConvertTo-UInt32Address $Address)
    return ($value -ge $range.First -and $value -le $range.Last)
}

function Test-IsIPv4([object]$Value) {
    return ($Value -is [string] -and $Value -match '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$')
}

function Test-IsCidr([object]$Value) {
    return ($Value -is [string] -and $Value -match '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)/([0-9]|[12][0-9]|3[0-2])$')
}

function Get-List([object]$Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IList]) { return @($Value) }
    return @($Value)
}

# Every string value in the file with its path, for the Key Vault reference check.
function Get-StringLeaf([object]$Node, [string]$Path) {
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) { Get-StringLeaf $Node[$key] $(if ($Path) { "$Path.$key" } else { "$key" }) }
    } elseif ($Node -is [System.Collections.IList] -and $Node -isnot [string]) {
        for ($i = 0; $i -lt $Node.Count; $i++) { Get-StringLeaf $Node[$i] "$Path[$i]" }
    } elseif ($Node -is [string]) {
        [pscustomobject]@{ Path = $Path; Value = $Node }
    }
}

function Read-InfrastructureFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Infrastructure file not found: $Path" }
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw 'The powershell-yaml module is required: Install-Module powershell-yaml -Scope CurrentUser'
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $text = Get-Content -LiteralPath $Path -Raw
    $data = ConvertFrom-Yaml -Yaml $text -Ordered
    if ($data -isnot [System.Collections.IDictionary]) { throw "The infrastructure file must be a YAML mapping: $Path" }
    return $data
}

# ---------------------------------------------------------------------------------------------------------------------
# Schema check
# ---------------------------------------------------------------------------------------------------------------------

# Test-Json reports only top-level errors, so the schema is evaluated with JsonSchema.Net (shipped with PowerShell 7.4+)
# in list output, which returns every node. An error counts only when every schema node above it failed too: that drops
# the expected failures inside if conditions, not, and the anyOf alternatives that didn't need to match.
function Get-SchemaFinding {
    param([string]$Json, [string]$SchemaText)
    if (-not ('Json.Schema.JsonSchema' -as [type])) { '{}' | Test-Json -Schema '{}' | Out-Null }
    $schema = [Json.Schema.JsonSchema]::FromText($SchemaText)
    $options = [Json.Schema.EvaluationOptions]::new()
    $options.OutputFormat = [Json.Schema.OutputFormat]::List
    $result = $schema.Evaluate([System.Text.Json.Nodes.JsonNode]::Parse($Json), $options)
    if ($result.IsValid) { return }

    $validity = @{}
    foreach ($d in $result.Details) { $validity[$d.EvaluationPath.ToString()] = $d.IsValid }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $invalidPaths = @($validity.Keys | Where-Object { -not $validity[$_] })
    foreach ($d in $result.Details) {
        $evalPath = $d.EvaluationPath.ToString()
        # A failed node with no message of its own (for example a failing not) counts when no node below it failed.
        $silentFailure = (-not $d.IsValid) -and (-not $d.HasErrors) -and
            -not ($invalidPaths | Where-Object { $_.StartsWith("$evalPath/") } | Select-Object -First 1)
        if (-not $d.HasErrors -and -not $silentFailure) { continue }
        $parts = $evalPath.Split('/')
        $masked = $false
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $prefix = ($parts[0..($i - 1)] -join '/')
            if ($validity.ContainsKey($prefix) -and $validity[$prefix]) { $masked = $true; break }
        }
        if ($masked) { continue }
        $at = ($d.InstanceLocation.ToString().TrimStart('/') -replace '/(\d+)(?=/|$)', '[$1]' -replace '/', '.')
        if ($silentFailure) {
            if ($seen.Add("$at|not")) { New-Finding 'SCHEMA' error $at "This value isn't allowed here; see the key's description in infrastructure.schema.json." }
            continue
        }
        foreach ($keyword in $d.Errors.Keys) {
            $message = switch ($keyword) {
                '' { 'Unknown key. Check the spelling, or put it under extensions.' }
                'required' { $d.Errors[$keyword] -replace '^Required properties \[(.*)\] are not present$', 'Missing required key(s): $1' -replace '"', '' }
                default { "$($d.Errors[$keyword]) ($keyword)" }
            }
            if ($seen.Add("$at|$message")) { New-Finding 'SCHEMA' error $at $message }
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Checks a JSON schema can't express
# ---------------------------------------------------------------------------------------------------------------------

function Get-SemanticFinding {
    param([System.Collections.IDictionary]$Infra)

    $v = { param($p) Get-AzlInfrastructureValue -Infrastructure $Infra -Path $p }
    $scenario = & $v 'scenario'
    if ($scenario -isnot [System.Collections.IDictionary]) { return }
    $nodes = @(Get-List (& $v 'nodes') | Where-Object { $_ -is [System.Collections.IDictionary] })
    $nodeCount = $nodes.Count
    $storageArch = $scenario['storage_architecture']
    $usesS2d = $storageArch -in @('s2d', 'hybrid')

    # Key Vault references name a listed vault.
    $vaults = @(Get-List (& $v 'key_vaults') | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['name'] } })
    foreach ($leaf in (Get-StringLeaf $Infra '')) {
        if ($leaf.Value -match '^keyvault://([^/]+)/') {
            if ($Matches[1] -notin $vaults) {
                New-Finding 'AZL-001' error $leaf.Path "References vault '$($Matches[1])', which isn't listed in key_vaults."
            }
        }
    }

    # Node names and management addresses are unique.
    foreach ($group in ($nodes | Group-Object { $_['name'] } | Where-Object Count -gt 1)) {
        New-Finding 'AZL-002' error 'nodes' "Node name '$($group.Name)' is used $($group.Count) times."
    }
    $nodeIps = @($nodes | ForEach-Object { if ($_['management'] -is [System.Collections.IDictionary]) { $_['management']['ip_address'] } } | Where-Object { Test-IsIPv4 $_ })
    foreach ($group in ($nodeIps | Group-Object | Where-Object Count -gt 1)) {
        New-Finding 'AZL-003' error 'nodes' "Management address $($group.Name) is used by $($group.Count) nodes."
    }

    # Management network: node addresses and the gateway inside the subnet, and the infrastructure pool.
    $mgmt = & $v 'networking.management'
    if ($mgmt -is [System.Collections.IDictionary] -and (Test-IsCidr $mgmt['subnet'])) {
        $subnet = $mgmt['subnet']
        for ($i = 0; $i -lt $nodeCount; $i++) {
            $ip = if ($nodes[$i]['management'] -is [System.Collections.IDictionary]) { $nodes[$i]['management']['ip_address'] }
            if ((Test-IsIPv4 $ip) -and -not (Test-AddressInSubnet $ip $subnet)) {
                New-Finding 'AZL-004' error "nodes[$i].management.ip_address" "$ip isn't in the management subnet $subnet. Node addresses must be on the same subnet as the infrastructure pool." $script:Learn.Decision8
            }
        }
        if ((Test-IsIPv4 $mgmt['gateway']) -and -not (Test-AddressInSubnet $mgmt['gateway'] $subnet)) {
            New-Finding 'AZL-004' error 'networking.management.gateway' "The gateway $($mgmt['gateway']) isn't in the management subnet $subnet." $script:Learn.Decision8
        }
        $pool = $mgmt['infrastructure_pool']
        if ($pool -is [System.Collections.IDictionary] -and (Test-IsIPv4 $pool['start']) -and (Test-IsIPv4 $pool['end'])) {
            $start = ConvertTo-UInt32Address $pool['start']
            $end = ConvertTo-UInt32Address $pool['end']
            if ($start -gt $end) {
                New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool starts at $($pool['start']), after its end $($pool['end'])." $script:Learn.Decision8
            } else {
                if (-not ((Test-AddressInSubnet $pool['start'] $subnet) -and (Test-AddressInSubnet $pool['end'] $subnet))) {
                    New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool $($pool['start'])-$($pool['end']) isn't inside the management subnet $subnet." $script:Learn.Decision8
                }
                if (($end - $start + 1) -lt 6) {
                    New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool has $($end - $start + 1) addresses; Azure Local needs at least six consecutive addresses." $script:Learn.Decision8
                }
                $inPool = @($nodeIps + @($mgmt['gateway']) | Where-Object { (Test-IsIPv4 $_) -and ((ConvertTo-UInt32Address $_) -ge $start) -and ((ConvertTo-UInt32Address $_) -le $end) })
                foreach ($ip in $inPool) {
                    New-Finding 'AZL-005' error 'networking.management.infrastructure_pool' "The pool includes $ip, which is a node or gateway address. The pool must not include node addresses." $script:Learn.Decision8
                }
            }
        }
    }

    # Reserved Arc resource bridge and AKS ranges.
    $checked = [System.Collections.Generic.List[object]]::new()
    foreach ($ip in $nodeIps) { $checked.Add(@('nodes[].management.ip_address', $ip)) }
    if ($mgmt -is [System.Collections.IDictionary]) {
        if (Test-IsIPv4 $mgmt['gateway']) { $checked.Add(@('networking.management.gateway', $mgmt['gateway'])) }
        foreach ($dns in (Get-List $mgmt['dns_servers'])) { if (Test-IsIPv4 $dns) { $checked.Add(@('networking.management.dns_servers', $dns)) } }
        if ($mgmt['infrastructure_pool'] -is [System.Collections.IDictionary]) {
            foreach ($k in 'start', 'end') { if (Test-IsIPv4 $mgmt['infrastructure_pool'][$k]) { $checked.Add(@("networking.management.infrastructure_pool.$k", $mgmt['infrastructure_pool'][$k])) } }
        }
    }
    foreach ($lnet in (Get-List (& $v 'networking.logical_networks'))) {
        if ($lnet -is [System.Collections.IDictionary] -and (Test-IsCidr $lnet['address_prefix'])) { $checked.Add(@('networking.logical_networks[].address_prefix', ($lnet['address_prefix'].Split('/')[0]))) }
    }
    foreach ($item in $checked) {
        if ((Test-AddressInSubnet $item[1] '10.244.0.0/16') -or (Test-AddressInSubnet $item[1] '10.96.0.0/24')) {
            New-Finding 'AZL-006' error $item[0] "$($item[1]) is in a range the Arc resource bridge reserves (10.244.0.0/16, 10.96.0.0/24)." "$($script:Learn.Decision8)"
        } elseif (Test-AddressInSubnet $item[1] '10.96.0.0/12') {
            New-Finding 'AZL-006' warning $item[0] "$($item[1]) is in 10.96.0.0/12, which AKS on Azure Local and deployments created before 2610 reserve." "$($script:Learn.Decision8)"
        }
    }

    # Public DNS servers aren't supported.
    foreach ($dns in (Get-List (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'networking.management.dns_servers'))) {
        if ($dns -in @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220')) {
            New-Finding 'AZL-014' error 'networking.management.dns_servers' "$dns is a public DNS server. The DNS servers must resolve the on-premises domains; public DNS servers aren't supported." $script:Learn.Decision8
        }
    }

    # Node counts per architecture and storage connectivity.
    if ($usesS2d -and $nodeCount -gt 16) {
        New-Finding 'AZL-007' error 'nodes' "$nodeCount nodes: a cluster with Storage Spaces Direct supports up to 16." $script:Learn.Decision4
    }
    if ($scenario['storage_connectivity'] -eq 'switchless' -and $nodeCount -gt 4) {
        New-Finding 'AZL-007' error 'nodes' "$nodeCount nodes: switchless storage supports 1 to 4 machines." $script:Learn.Topologies
    }
    if ($scenario['topology'] -eq 'rack_aware') {
        $perZoneMax = if ($usesS2d) { 4 } else { 8 }
        $zones = @($nodes | Group-Object { $_['zone'] })
        if ($zones.Count -ne 2) {
            New-Finding 'AZL-007' error 'nodes[].zone' "A rack aware cluster has exactly two local availability zones; this file has $($zones.Count)." $script:Learn.RackAware
        } elseif ($zones[0].Count -ne $zones[1].Count) {
            New-Finding 'AZL-007' error 'nodes[].zone' "The two zones must hold the same number of machines ($($zones[0].Name): $($zones[0].Count), $($zones[1].Name): $($zones[1].Count))." $script:Learn.RackAware
        } elseif ($zones[0].Count -gt $perZoneMax) {
            New-Finding 'AZL-007' error 'nodes[].zone' "$($zones[0].Count) machines per zone: the maximum is $perZoneMax." $script:Learn.RackAware
        }
        foreach ($vol in (Get-List (& $v 'storage.volumes'))) {
            if ($vol -is [System.Collections.IDictionary] -and $vol['resiliency'] -eq 'three_way') {
                New-Finding 'AZL-012' error 'storage.volumes' "Volume '$($vol['name'])': a rack aware cluster supports two-way or four-way mirror volumes, not three-way." $script:Learn.RackAware
            }
        }
    }

    # Witness.
    $witness = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'cluster.witness.type'
    if ($witness -eq 'none' -and ($nodeCount -eq 2 -or $scenario['topology'] -eq 'rack_aware')) {
        New-Finding 'AZL-008' error 'cluster.witness.type' 'A two-machine or rack aware cluster needs a witness.' $script:Learn.Quorum
    }
    if ($witness -eq 'file_share' -and $scenario['connectivity'] -eq 'connected') {
        New-Finding 'AZL-008' error 'cluster.witness.type' 'A connected deployment uses a cloud witness. A file share witness is for disconnected operations.' $script:Learn.Arm
    }
    if ($witness -eq 'cloud' -and $scenario['connectivity'] -eq 'disconnected') {
        New-Finding 'AZL-008' error 'cluster.witness.type' 'Disconnected operations use a file share witness, not a cloud witness.' $script:Learn.Arm
    }

    # Intents.
    $intents = @(Get-List (& $v 'networking.intents') | Where-Object { $_ -is [System.Collections.IDictionary] })
    if ($intents.Count -gt 0) {
        $mgmtIntents = @($intents | Where-Object { 'management' -in (Get-List $_['traffic']) })
        if ($mgmtIntents.Count -ne 1) {
            New-Finding 'AZL-009' error 'networking.intents' "Exactly one intent carries management traffic; this file has $($mgmtIntents.Count)." $script:Learn.Intents
        }
        $storageIntents = @($intents | Where-Object { 'storage' -in (Get-List $_['traffic']) })
        if ($usesS2d -and $nodeCount -gt 1 -and $storageIntents.Count -eq 0) {
            New-Finding 'AZL-009' error 'networking.intents' 'A multi-machine Storage Spaces Direct cluster needs an intent with storage traffic.' $script:Learn.Intents
        }
        if ($scenario['storage_connectivity'] -eq 'switchless') {
            foreach ($si in $storageIntents) {
                if (@(Get-List $si['traffic']).Count -gt 1) {
                    New-Finding 'AZL-009' error 'networking.intents' "Intent '$($si['name'])': switchless storage needs storage in its own intent, apart from management and compute." $script:Learn.Intents
                }
            }
        }
        foreach ($group in ($intents | ForEach-Object { Get-List $_['adapters'] } | Group-Object | Where-Object Count -gt 1)) {
            New-Finding 'AZL-009' error 'networking.intents' "Adapter '$($group.Name)' is in more than one intent." $script:Learn.Intents
        }
        foreach ($group in ($intents | Group-Object { $_['name'] } | Where-Object Count -gt 1)) {
            New-Finding 'AZL-009' error 'networking.intents' "Intent name '$($group.Name)' is used more than once."
        }

        # Adapters exist on the cards, when the cards are described.
        $ports = @(Get-List (& $v 'hardware.network_cards') | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { Get-List $_['ports'] } } | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['name'] } })
        if ($ports.Count -gt 0) {
            foreach ($adapter in ($intents | ForEach-Object { Get-List $_['adapters'] })) {
                if ($adapter -notin $ports) {
                    New-Finding 'AZL-011' error 'networking.intents' "Adapter '$adapter' isn't a port in hardware.network_cards."
                }
            }
        }

        # Storage networks sit on storage-intent adapters; custom storage addresses are complete.
        $storageAdapters = @($storageIntents | ForEach-Object { Get-List $_['adapters'] })
        $storageNets = @(Get-List (& $v 'networking.storage.networks') | Where-Object { $_ -is [System.Collections.IDictionary] })
        foreach ($net in $storageNets) {
            if ($net['adapter'] -notin $storageAdapters) {
                New-Finding 'AZL-010' error 'networking.storage.networks' "Storage network '$($net['name'])' uses adapter '$($net['adapter'])', which isn't in an intent with storage traffic."
            }
        }
        if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'networking.storage.auto_ip') -eq $false) {
            foreach ($net in $storageNets) {
                if (-not $net.Contains('subnet')) { New-Finding 'AZL-010' error 'networking.storage.networks' "Storage network '$($net['name'])' needs a subnet when auto_ip is false." $script:Learn.CustomIp }
            }
            for ($i = 0; $i -lt $nodeCount; $i++) {
                $count = @(Get-List $nodes[$i]['storage_ips']).Count
                if ($count -ne $storageNets.Count) {
                    New-Finding 'AZL-010' error "nodes[$i].storage_ips" "Node '$($nodes[$i]['name'])' lists $count storage addresses; auto_ip is false, so it needs one per storage network ($($storageNets.Count))." $script:Learn.CustomIp
                }
            }
        }
    }

    # Provisioning.
    $osVersion = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'provisioning.os_version'
    if ($osVersion -in @('latest', 'latest-preview')) {
        New-Finding 'AZL-013' warning 'provisioning.os_version' "os_version is '$osVersion'. Pin a version so every run installs the same OS and the SBE can be checked against it."
    }
    if ((Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.sbe.allow_unvalidated') -eq $true) {
        New-Finding 'AZL-013' warning 'hardware.sbe.allow_unvalidated' 'allow_unvalidated is true: the SBE is used even though the OEM has not validated it with os_version. Test only.'
    }
    # Arc gateway (and the private path, which uses it): not with simplified provisioning, and only in the public cloud.
    if ($scenario['outbound_path'] -in @('arc_gateway', 'proxy_arc_gateway', 'private_path')) {
        if ($scenario['os_install'] -eq 'simplified') {
            New-Finding 'AZL-016' error 'scenario.outbound_path' "Arc gateway isn't supported with simplified machine provisioning; use direct or proxy." $script:Learn.Simplified
        }
        if ($scenario['cloud'] -eq 'government') {
            New-Finding 'AZL-016' error 'scenario.outbound_path' 'Arc gateway is available only in the Azure public cloud.' 'https://learn.microsoft.com/azure/azure-arc/servers/arc-gateway#current-limitations'
        }
    }
    if ($scenario['os_install'] -eq 'simplified') {
        $defaultBmc = Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.bmc'
        for ($i = 0; $i -lt $nodeCount; $i++) {
            $bmc = $nodes[$i]['bmc']
            $own = $bmc -is [System.Collections.IDictionary] -and $bmc.Contains('password')
            if (-not $own -and $defaultBmc -isnot [System.Collections.IDictionary]) {
                New-Finding 'AZL-015' error "nodes[$i].bmc" "Node '$($nodes[$i]['name'])' has no BMC login: set nodes[].bmc.username and password, or hardware.bmc. Simplified provisioning mounts the image through the BMC." $script:Learn.Simplified
            }
        }
        if (-not (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'hardware.sbe.bundle_path')) {
            New-Finding 'AZL-015' error 'hardware.sbe.bundle_path' 'Simplified provisioning prepares each machine with the OEM SBE before Validate: set the folder holding the SBE files.'
        }
    }
    if ($scenario['os_install'] -eq 'simplified' -and (Get-AzlInfrastructureValue -Infrastructure $Infra -Path 'azure.location') -ne 'eastus') {
        New-Finding 'AZL-013' warning 'azure.location' 'Simplified machine provisioning works only in eastus in the preview.' $script:Learn.Simplified
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------------------------------------------------

function Test-AzlInfrastructure {
    <#
    .SYNOPSIS
        Checks an infrastructure.yml file and returns every finding.
    .PARAMETER Path
        The infrastructure file.
    .PARAMETER SchemaPath
        The JSON schema. Defaults to config/infrastructure/infrastructure.schema.json in this toolkit.
    .OUTPUTS
        One object per finding: Id, Severity (error, warning, info), Path, Message, LearnUrl. Nothing when the file is clean.
    .EXAMPLE
        Test-AzlInfrastructure -Path .\infrastructure.yml | Format-Table Severity, Id, Path, Message -Wrap
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SchemaPath = $script:DefaultSchemaPath
    )
    $infra = Read-InfrastructureFile $Path

    $version = Get-AzlInfrastructureValue -Infrastructure $infra -Path '_metadata.schema_version'
    if ($version -isnot [string] -or $version -notmatch "^$script:SupportedMajor\.") {
        New-Finding 'AZL-000' error '_metadata.schema_version' "schema_version is '$version'. This toolkit reads schema $script:SupportedMajor.x; see config/infrastructure/MIGRATION.md."
        return
    }

    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) { throw "Schema not found: $SchemaPath" }
    $json = $infra | ConvertTo-Json -Depth 100
    Get-SchemaFinding -Json $json -SchemaText (Get-Content -LiteralPath $SchemaPath -Raw)

    Get-SemanticFinding -Infra $infra
}

function Import-AzlInfrastructure {
    <#
    .SYNOPSIS
        Reads infrastructure.yml, checks it, and returns it as an ordered hashtable. Stops when the file has errors.
    .PARAMETER Path
        The infrastructure file. When omitted: $env:AZL_INFRASTRUCTURE_FILE, then .\infrastructure.yml, then .\config\infrastructure.yml.
    .PARAMETER SkipValidation
        Return the file without checking it. For tools that only display it.
    .EXAMPLE
        $infra = Import-AzlInfrastructure -Path .\infrastructure.yml
        $infra.networking.management.gateway
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [string]$Path,
        [string]$SchemaPath = $script:DefaultSchemaPath,
        [switch]$SkipValidation
    )
    if (-not $Path) {
        $candidates = @($env:AZL_INFRASTRUCTURE_FILE, '.\infrastructure.yml', '.\config\infrastructure.yml') | Where-Object { $_ }
        $Path = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $Path) { throw 'No infrastructure file given, and none found at $env:AZL_INFRASTRUCTURE_FILE, .\infrastructure.yml or .\config\infrastructure.yml.' }
    }
    if (-not $SkipValidation) {
        $findings = @(Test-AzlInfrastructure -Path $Path -SchemaPath $SchemaPath)
        foreach ($w in ($findings | Where-Object Severity -eq 'warning')) { Write-Warning "$($w.Id) $($w.Path): $($w.Message)" }
        $errors = @($findings | Where-Object Severity -eq 'error')
        if ($errors.Count -gt 0) {
            $list = ($errors | ForEach-Object { "  $($_.Id) $($_.Path): $($_.Message)" }) -join [Environment]::NewLine
            throw "$Path has $($errors.Count) error(s):$([Environment]::NewLine)$list"
        }
    }
    return Read-InfrastructureFile $Path
}

Export-ModuleMember -Function Import-AzlInfrastructure, Test-AzlInfrastructure, Get-AzlInfrastructureValue
