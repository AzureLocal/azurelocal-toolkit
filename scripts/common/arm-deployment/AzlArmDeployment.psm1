#Requires -Version 7.0
<#
.SYNOPSIS
    ARM Validate and Deploy of an Azure Local instance from infrastructure.yml (schema 5).

.DESCRIPTION
    Select-AzlArmTemplate        Which of Microsoft's quickstart templates fits the design (identity, storage, topology).
    New-AzlArmParameterSet       Every parameter of that template, from infrastructure.yml, the ZTP handoff, the OS
                                 configuration report and the SBE folder. The SBE parameters only when an SBE is
                                 configured. Secrets stay references.
    Test-AzlArmParameterSet      Checks the parameters against the template's own parameter list: none unknown, none
                                 missing, types and allowed values right.
    ConvertTo-AzlArmParameterFile  The parameter file (deploymentParameters.json), with no secret value in it.
    Invoke-AzlArmDeployment      Validate (deploymentMode Validate) or Deploy, waits, and reports the validation steps.

    Microsoft's notes the code enforces:
      - Don't run Validate again after a failed deployment: it resets the system properties and can break license sync.
      - Deploy only after a Validate that succeeded.
      - The deployment's local administrator is not the built-in Administrator.
    The template's deploymentSettings api-version is part of Microsoft's template. As of 2026-11 their quickstart for S2D
    and for Fibre Channel still uses 2025-09-15-preview and 2026-04-01-preview; only the iSCSI one uses 2026-10-01.
    -DeploymentSettingsApiVersion patches it when you want 2026-10-01 or a newer one.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'azure-local', 'AzlAzure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'secrets', 'AzlSecret.psm1'))

# The catalog of Microsoft's quickstart templates (name, address and parameters of each). Fixed by Microsoft, not a choice of the deployment: the templates are
# Microsoft's (Learn: Deploy Azure Local via Azure Resource Manager deployment template and its siblings). The file is regenerated from them; -TemplateFile of the run
# uses a local copy of one template instead.
$script:CatalogPath = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'config', 'azure', 'arm-templates', 'template-parameters.json')
# The api-version of the Azure Resource Manager deployments call (Microsoft.Resources/deployments), where this module submits the template. Fixed by the Azure API
# (a version Microsoft publishes at Learn: Microsoft.Resources deployments); it changes with a release of the toolkit, not with a site.
$script:DeploymentsApiVersion = '2024-03-01'
# The api-version of the Microsoft.AzureStackHCI resources this module reads (clusters, deploymentSettings). Fixed by the Azure API (Learn: Microsoft.AzureStackHCI
# clusters/deploymentSettings, 2026-10-01 is in the 2610 view). The version of the template's own deploymentSettings resource is the run setting deploymentSettingsApiVersion.
$script:HciApiVersion = '2026-10-01'
$script:SecretParameters = @('localAdminPassword', 'AzureStackLCMAdminPassword', 'chapCredential')
# Parameters that are lists of objects with a secret inside each entry: the ARM parameter -> the field that holds the secret. Microsoft's template
# takes the SBE partner credentials as a plain array of { secretName, secretValue } and writes secretValue into the cluster's Key Vault under
# secretName (azuredeploy.json: variable answerfileSBESecrets and the resource of type Microsoft.KeyVault/vaults/secrets). In the parameter set the
# field holds a secret reference ({ KeyVault = <reference> }), like a top-level secret; the value is read only when the deployment is submitted.
$script:NestedSecretFields = @{ partnerCredentiallist = 'secretValue' }
$script:SecretMask = '***'

function ConvertTo-List([AllowNull()][object]$Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) { return @($Value) }
    return @($Value)
}

function Get-AzlArmNestedSecret {
    <#
    .SYNOPSIS
        The secret slots inside list parameters (the SBE partner credentials): one object per entry with Parameter, Index, Field, Label
        (for example partnerCredentiallist[0].secretValue), SecretName, Value and IsReference. Value is whatever the entry holds;
        it is never written anywhere by this function.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Parameters)
    foreach ($name in @($script:NestedSecretFields.Keys)) {
        if (-not $Parameters.Contains($name)) { continue }
        $field = [string]$script:NestedSecretFields[$name]
        $index = 0
        foreach ($entry in @(ConvertTo-List $Parameters[$name])) {
            $isEntry = $entry -is [System.Collections.IDictionary]
            $value = if ($isEntry -and $entry.Contains($field)) { $entry[$field] } else { $null }
            [pscustomobject]@{
                Parameter   = $name
                Index       = $index
                Field       = $field
                Label       = "$name[$index].$field"
                SecretName  = $(if ($isEntry -and $entry.Contains('secretName')) { [string]$entry['secretName'] } else { '' })
                Value       = $value
                IsReference = [bool]($value -is [System.Collections.IDictionary] -and $value.Contains('KeyVault'))
            }
            $index++
        }
    }
}

function Get-AzlArmDisplayParameter {
    <#
    .SYNOPSIS
        A copy of the parameters that is safe to print, hash or log: a secret that is a reference stays the reference; a secret that holds a
        value (a top-level secret parameter, or the field inside a list entry) is replaced by ***. Nothing else changes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Parameters)
    $copy = [ordered]@{}
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]
        if ($k -in $script:SecretParameters -and $v -is [string] -and $v) { $copy[$k] = $script:SecretMask }
        elseif ($script:NestedSecretFields.ContainsKey($k) -and $null -ne $v) {
            $field = [string]$script:NestedSecretFields[$k]
            $entries = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in @(ConvertTo-List $v)) {
                if ($entry -isnot [System.Collections.IDictionary]) { $entries.Add($script:SecretMask); continue }
                $item = [ordered]@{}
                foreach ($f in $entry.Keys) {
                    $held = $entry[$f]
                    $item[$f] = if ($f -eq $field -and $null -ne $held -and -not ($held -is [System.Collections.IDictionary] -and $held.Contains('KeyVault'))) { $script:SecretMask } else { $held }
                }
                $entries.Add($item)
            }
            $copy[$k] = $entries.ToArray()
        }
        else { $copy[$k] = $v }
    }
    return $copy
}

function ConvertTo-MacKey([AllowNull()][object]$Mac) {
    if ($null -eq $Mac) { return '' }
    return (([string]$Mac) -replace '[-:\.\s]', '').ToLowerInvariant()
}

function ConvertTo-SubnetMask([int]$PrefixLength) {
    $all = [uint64]4294967295
    $bits = if ($PrefixLength -le 0) { [uint64]0 } else { ([uint64]($all -shl (32 - $PrefixLength))) -band $all }
    return (3, 2, 1, 0 | ForEach-Object { ($bits -shr (8 * $_)) -band 255 }) -join '.'
}

function Get-AzlArmTemplateCatalog {
    <#
    .SYNOPSIS
        config/azure/arm-templates/template-parameters.json: each Microsoft quickstart template's parameters.
    #>
    [CmdletBinding()]
    param([string]$Path = $script:CatalogPath)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
}

function Select-AzlArmTemplate {
    <#
    .SYNOPSIS
        The quickstart template for the design, and why.
    .DESCRIPTION
        Active Directory with Storage Spaces Direct: create-cluster (rack aware: create-cluster-rac-enabled). Local identity:
        create-adless-cluster-external-dns-public-preview. A Fibre Channel SAN (disaggregated): create-cluster-san, or
        create-cluster-adless-san with local identity. An iSCSI SAN (disaggregated): create-cluster-san-iscsi. A hybrid design deploys with Storage Spaces Direct and the SAN is
        connected afterwards (Learn: Connect an external storage array), so it uses the S2D template. Not generated yet:
        an iSCSI SAN with local identity (Microsoft has no template), disconnected operations, Azure Government with local identity or a SAN.
    .OUTPUTS
        Name, Uri, Warnings.
    .EXAMPLE
        Select-AzlArmTemplate -Infrastructure $infra
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [hashtable]$Catalog = (Get-AzlArmTemplateCatalog))
    $identity = [string](Get-AzlProp $Infrastructure 'scenario.identity')
    $storage = [string](Get-AzlProp $Infrastructure 'scenario.storage_architecture')
    $topology = [string](Get-AzlProp $Infrastructure 'scenario.topology' 'standard')
    $cloud = [string](Get-AzlProp $Infrastructure 'scenario.cloud' 'public')
    $connectivity = [string](Get-AzlProp $Infrastructure 'scenario.connectivity' 'connected')
    $sanType = [string](Get-AzlProp $Infrastructure 'storage.san.type')
    $warnings = @()
    if ($connectivity -eq 'disconnected') { throw 'Disconnected operations aren''t generated yet (Microsoft''s create-cluster-rac-enabled-disconnected template).' }
    $name = $null
    if ($cloud -eq 'government') {
        if ($identity -ne 'active_directory' -or $storage -ne 's2d') { throw 'Azure Government is generated for Active Directory with Storage Spaces Direct only (create-cluster-for-usgov).' }
        $name = 'create-cluster-for-usgov'
    }
    elseif ($storage -eq 'san') {
        if ($topology -eq 'rack_aware') { throw 'Rack aware with a SAN isn''t generated: Microsoft has no quickstart template for it.' }
        if ($sanType -eq 'iscsi') {
            if ($identity -eq 'local_identity') { throw 'An iSCSI SAN with local identity isn''t generated: Microsoft has no quickstart template for it.' }
            $name = 'create-cluster-san-iscsi'
        }
        else { $name = if ($identity -eq 'local_identity') { 'create-cluster-adless-san' } else { 'create-cluster-san' } }
    }
    else {
        if ($storage -eq 'hybrid') { $warnings += 'Hybrid: the cluster is deployed with Storage Spaces Direct. Connect the SAN afterwards (Learn: enable-external-storage); the SAN parameters are not part of this deployment.' }
        if ($topology -eq 'rack_aware') {
            if ($identity -eq 'local_identity') { throw 'Rack aware with local identity isn''t generated: Microsoft has no quickstart template for it.' }
            $name = 'create-cluster-rac-enabled'
        }
        else { $name = if ($identity -eq 'local_identity') { 'create-adless-cluster-external-dns-public-preview' } else { 'create-cluster' } }
    }
    if (-not $Catalog.templates.ContainsKey($name)) { throw "Template $name isn't in the catalog. Regenerate config/azure/arm-templates/template-parameters.json." }
    [pscustomobject]@{ Name = $name; Uri = [string]$Catalog.templates[$name].uri; Warnings = $warnings }
}

# ---------------------------------------------------------------------------------------------------------------------
# Pieces of the parameter set
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlOsAdapterName {
    # The name the deployment sends for a port of the file. The port is found on the node by its MAC (never by a name): the name is what the node calls that adapter, read
    # from the OS configuration report's MAC -> name map, or the user's os_name_override (opt-in; the NicNames step renames the adapter to it). Nothing is assumed: without a
    # map the override is used when the file has one, else the file's name is sent as it is and the run says so (a warning), because the OS name was not read.
    param([string]$FileName, [System.Collections.IDictionary]$PortByName, [System.Collections.IDictionary]$OsNameByMac, [string]$Node, [System.Collections.Generic.List[string]]$Warnings)
    if (-not $PortByName.Contains($FileName)) { return $FileName }
    $port = $PortByName[$FileName]
    $override = if ($port.Contains('os_name_override') -and "$($port['os_name_override'])" -ne '') { [string]$port['os_name_override'] } else { '' }
    $mac = ConvertTo-MacKey $port['mac_address']
    if (-not $OsNameByMac -or $OsNameByMac.Count -eq 0) {
        if ($override) { return $override }
        $text = "Node ${Node}: no OS configuration report, so the OS name of port '$FileName' was not read from the node; the file's name '$FileName' is sent as it is. Give the OS configuration report (-NodeReportPath) so the name is read by MAC."
        if (-not $Warnings.Contains($text)) { $Warnings.Add($text) }
        return $FileName
    }
    if (-not $mac) {
        if ($override) { return $override }
        $Warnings.Add("Port $FileName on $Node has no MAC in the file, so its OS name can't be looked up; using $FileName.")
        return $FileName
    }
    if (-not $OsNameByMac.Contains($mac)) { throw "Port $FileName on $Node has MAC $mac, but the node's report has no port with that MAC." }
    $actual = [string]$OsNameByMac[$mac]
    if ($override -and $actual -cne $override) {
        throw "Port $FileName on ${Node}: the file's os_name_override is '$override', but the node calls the adapter (MAC $mac) '$actual'. Run the OS configuration (the NicNames step renames the adapter to the override; renaming is opt-in) and take a new report, or remove os_name_override to use the node's name."
    }
    return $actual
}

function Resolve-AzlAdapterName {
    <#
    .SYNOPSIS
        The name the deployment sends for a port that infrastructure.yml calls $FileName (nodes[].network_adapters[].name), the same on every node, found by MAC.
    .DESCRIPTION
        Network ATC takes the adapter names from the deployment, so they must be the names the OS gives the adapters (whatever the installed OS called them: Port0, SLOT 3 Port 1, NIC1).
        -AdapterMap is node -> (MAC -> OS name), from the OS configuration report or the Arc machines' network reports; each port of the file is found on its node by MAC. A port
        with os_name_override sends that name (the OS configuration renames the adapter to it, opt-in, and the name is checked against the node). Without a map and without an
        override the file's name is sent as it is, with a warning. The same file port must come out as one name on every node, or this throws and says the two ways out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [Parameter(Mandatory)][string]$FileName,
        [hashtable]$AdapterMap,
        [System.Collections.Generic.List[string]]$Warnings = ([System.Collections.Generic.List[string]]::new())
    )
    $names = [ordered]@{}
    foreach ($node in ConvertTo-List $Infrastructure['nodes']) {
        $byName = @{}
        foreach ($p in Get-AzlNodeNetworkAdapter -Infrastructure $Infrastructure -Node $node) { $byName[[string]$p['name']] = $p }
        $map = if ($AdapterMap -and $AdapterMap.ContainsKey($node['name'])) { $AdapterMap[$node['name']] } else { $null }
        $names[[string]$node['name']] = ConvertTo-AzlOsAdapterName -FileName $FileName -PortByName $byName -OsNameByMac $map -Node ([string]$node['name']) -Warnings $Warnings
    }
    $distinct = @($names.Values | Select-Object -Unique)
    if ($distinct.Count -gt 1) {
        $detail = (@($names.GetEnumerator() | ForEach-Object { "'$($_.Value)' on $($_.Key)" })) -join ', '
        throw "Port $FileName is $detail. Network ATC needs the same adapter name on every node. Either install the nodes consistently so the OS names the adapter alike everywhere, or set nodes[].network_adapters[].os_name_override for this port (the same value on every node) and run the OS configuration NicNames step, which renames the adapters (opt-in)."
    }
    return $distinct[0]
}

function ConvertTo-AzlArmIntent {
    # One networking.intents[] entry in the shape of the template's intentList.
    param([System.Collections.IDictionary]$Intent, [scriptblock]$Resolve)
    $overrides = $Intent['overrides']
    $qos = Get-AzlProp $overrides 'qos'
    $adapter = Get-AzlProp $overrides 'adapter'
    $vswitch = Get-AzlProp $overrides 'virtual_switch'
    $tech = @{ iwarp = 'iWARP'; roce = 'RoCE'; roce_v2 = 'RoCEv2' }
    $balancing = @{ dynamic = 'Dynamic'; hyper_v_port = 'HyperVPort' }
    # Microsoft's host network doc: RDMA and jumbo frames belong to the storage traffic. A management or compute intent without
    # storage traffic (the LOM management intent, a compute intent) gets RDMA off and the default 1514 packet. The deployment
    # is told so explicitly (overrideAdapterProperty true), because Azure's network validation checks RDMA on every adapter
    # whose intent says networkDirect Enabled. The file's overrides.adapter values win over these defaults.
    # overrideAdapterProperty is always true: Microsoft's quickstart parameters file sets it true on every intent and sends the adapter values with it (jumboPacket,
    # networkDirect, networkDirectTechnology). overrideVirtualSwitchConfiguration and overrideQosPolicy are not a choice: they are true exactly when the file gives that
    # block (overrides.virtual_switch, overrides.qos), so the file's blocks decide them.
    $traffic = @(ConvertTo-List $Intent['traffic'] | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $hasStorage = $traffic -contains 'storage'
    $defaultDirect = if ($hasStorage) { 'Enabled' } else { 'Disabled' }
    $defaultJumbo = if ($hasStorage) { 9014 } else { 1514 }
    $directFromFile = Get-AzlProp $adapter 'network_direct'
    $networkDirect = if ($null -ne $directFromFile) { $(if ([bool]$directFromFile) { 'Enabled' } else { 'Disabled' }) } else { $defaultDirect }
    $directTech = ''
    if ($networkDirect -eq 'Enabled') { $directTech = if (Get-AzlProp $adapter 'network_direct_technology') { $tech[[string](Get-AzlProp $adapter 'network_direct_technology')] } else { 'RoCEv2' } }
    [ordered]@{
        name                               = [string]$Intent['name']
        trafficType                        = @(ConvertTo-List $Intent['traffic'] | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase([string]$_) })
        adapter                            = @(ConvertTo-List $Intent['adapters'] | ForEach-Object { & $Resolve ([string]$_) })
        overrideVirtualSwitchConfiguration = [bool]$vswitch
        virtualSwitchConfigurationOverrides = [ordered]@{
            enableIov              = $(if ($vswitch -and $null -ne (Get-AzlProp $vswitch 'enable_iov')) { ([string][bool](Get-AzlProp $vswitch 'enable_iov')).ToLowerInvariant() } else { '' })
            loadBalancingAlgorithm = $(if ($vswitch -and (Get-AzlProp $vswitch 'load_balancing_algorithm')) { $balancing[[string](Get-AzlProp $vswitch 'load_balancing_algorithm')] } else { '' })
        }
        overrideQosPolicy                  = [bool]$qos
        qosPolicyOverrides                 = [ordered]@{
            priorityValue8021Action_Cluster = [string](Get-AzlProp $qos 'cluster_priority' 7)
            priorityValue8021Action_SMB     = [string](Get-AzlProp $qos 'smb_priority' 3)
            bandwidthPercentage_SMB         = [string](Get-AzlProp $qos 'smb_bandwidth_percent' 50)
        }
        overrideAdapterProperty            = $true
        adapterPropertyOverrides           = [ordered]@{
            jumboPacket             = [string](Get-AzlProp $adapter 'jumbo_packet' $defaultJumbo)
            networkDirect           = $networkDirect
            networkDirectTechnology = $directTech
        }
    }
}

function Get-AzlNetworkingPattern {
    <#
    .SYNOPSIS
        The template's networkingPattern from the intents: hyperConverged (one intent with everything),
        convertedManagementCompute (management and compute together, storage apart), convergedComputeStorage, or custom.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Intents)
    $sets = @($Intents | ForEach-Object { , @(ConvertTo-List $_['traffic'] | ForEach-Object { [string]$_ } | Sort-Object) })
    $key = @($sets | ForEach-Object { $_ -join '+' } | Sort-Object)
    if ($sets.Count -eq 1) { return 'hyperConverged' }
    if ($key.Count -eq 2 -and $key -contains 'compute+management' -and $key -contains 'storage') { return 'convergedManagementCompute' }
    if ($key.Count -eq 2 -and $key -contains 'management' -and $key -contains 'compute+storage') { return 'convergedComputeStorage' }
    return 'custom'
}

function Resolve-AzlSanLunId {
    <#
    .SYNOPSIS
        The value for infraVolLunId / infraPerfLunId. A short LUN number in the file ("0") is translated to the disk's
        UniqueId (or SerialNumber) from the OS configuration report; a longer value is taken as it is.
    .DESCRIPTION
        The ARM parameter takes the LUN's serial number or unique ID, not its LUN number. The report lists the disks each node
        sees with their LUN number. Every node must show the same identifier for the LUN.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LunId, [object[]]$NodeReport, [ValidateSet('UniqueId', 'SerialNumber')][string]$Source = 'UniqueId')
    if ($LunId -notmatch '^\d{1,4}$') { return $LunId }
    $found = @()
    foreach ($node in @($NodeReport | Where-Object { $_ })) {
        $disk = @(Get-AzlProp $node 'sanDisks' @()) | Where-Object { $null -ne $_.lun -and [string]$_.lun -eq $LunId } | Select-Object -First 1
        if (-not $disk) { throw "LUN $LunId isn't visible on $($node.name) in the OS configuration report." }
        $found += [string]$(if ($Source -eq 'UniqueId') { $disk.uid } else { $disk.sn })
    }
    if (-not $found) { throw "LUN $LunId is a LUN number, but no OS configuration report was given to translate it. Pass -NodeReportPath (the OS configuration report), or write the disk's UniqueId or SerialNumber in storage.san." }
    if (@($found | Select-Object -Unique).Count -ne 1) { throw "LUN $LunId has different $Source values on different nodes ($($found -join ', ')). Fix the LUN masking so every node sees the same LUN." }
    return $found[0]
}

function New-AzlArmParameterSet {
    <#
    .SYNOPSIS
        All parameters of the right quickstart template, from infrastructure.yml.
    .PARAMETER ArcResourceId
        node name -> the Arc machine's resource ID (the handoff has them). A node without one gets the ID the Arc machine would
        have in azure.resource_group under its Arc machine name; Invoke-AzlArmDeployment checks that it exists.
    .PARAMETER AdapterMap
        node name -> (MAC -> OS adapter name), from the OS configuration report. Each port of the file is found on its node by MAC and the deployment sends the name the node
        calls it (or the port's os_name_override). Without a map the file's names are sent as they are, with a warning.
    .PARAMETER NodeReport
        The OS configuration report's nodes (for the SAN disks, to translate LUN numbers).
    .PARAMETER SbeDeployment
        The SBE values from Get-AzlSbeBundle (Deployment), used where hardware.sbe leaves them empty. Without a version from either, no SBE parameter is passed.
    .PARAMETER Mode
        Validate or Deploy. Default: cluster.deployment_mode.
    .OUTPUTS
        Template (Name, Uri), Parameters (ordered name -> value; a secret is @{ KeyVault = 'keyvault://...' }), Warnings,
        DeploymentSettingsApiVersion.
    .EXAMPLE
        New-AzlArmParameterSet -Infrastructure $infra -Handoff $handoff -Mode Validate
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory parameter set; changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [object]$Handoff,
        [hashtable]$ArcResourceId = @{},
        [hashtable]$AdapterMap,
        [object[]]$NodeReport,
        [System.Collections.IDictionary]$SbeDeployment,
        [string]$HciResourceProviderObjectId,
        [ValidateSet('Validate', 'Deploy')][string]$Mode,
        [ValidateSet('UniqueId', 'SerialNumber')][string]$SanLunIdSource = 'UniqueId',
        [switch]$AllowUnresolvedSanLun,
        [hashtable]$Catalog = (Get-AzlArmTemplateCatalog)
    )
    $warnings = [System.Collections.Generic.List[string]]::new()
    $template = Select-AzlArmTemplate -Infrastructure $Infrastructure -Catalog $Catalog
    foreach ($w in $template.Warnings) { $warnings.Add($w) }
    $g = { param($path, $default) Get-AzlProp $Infrastructure $path $default }
    $identity = & $g 'scenario.identity' ''
    $storage = & $g 'scenario.storage_architecture' 's2d'
    $nodes = @(ConvertTo-List $Infrastructure['nodes'])
    $clusterName = [string](& $g 'cluster.name' '')
    if (-not $clusterName) { throw 'cluster.name is empty.' }
    $nodeNames = @($nodes | ForEach-Object { [string]$_['name'] })
    if ($clusterName -in $nodeNames) { throw "cluster.name '$clusterName' is also a node name; the cluster name must differ from every node." }

    $local = & $g 'identity.local_admin' $null
    $localUser = [string](Get-AzlProp $local 'username' '')
    if ($localUser -in 'Administrator', 'Guest') { throw "identity.local_admin.username is the built-in $localUser. The deployment can't use it; the deployment renames the account you give." }
    if (-not $localUser) { throw 'identity.local_admin.username is empty.' }

    # ---- the nodes
    $arcIds = @()
    $physical = @()
    $subscription = [string](& $g 'azure.subscription_id' '')
    $resourceGroup = [string](& $g 'azure.resource_group' '')
    foreach ($n in $nodes) {
        $name = [string]$n['name']
        $mgmt = Get-AzlManagementAdapter -Infrastructure $Infrastructure -Node $n
        if (-not $mgmt) { throw "Node $name has no single management port." }
        $physical += [ordered]@{ name = $name; ipv4Address = [string]$mgmt.IpAddress }
        $handoffNode = Get-AzlHandoffNode -Handoff $Handoff -Name $name -ArcMachineName (Get-AzlArcMachineName -Node $n)
        $id = if ($ArcResourceId.ContainsKey($name)) { $ArcResourceId[$name] }
        elseif ($handoffNode -and (Get-AzlProp $handoffNode 'arcMachineResourceId')) { [string](Get-AzlProp $handoffNode 'arcMachineResourceId') }
        else {
            $warnings.Add("Node ${name}: no Arc machine resource ID in the handoff; assuming the machine is named $(Get-AzlArcMachineName -Node $n) in $resourceGroup.")
            "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$(Get-AzlArcMachineName -Node $n)"
        }
        $arcIds += $id
    }

    $resolveLog = $warnings
    $resolveMap = $AdapterMap   # read inside the script block below, which the analyzer does not follow
    $resolve = { param($fileName) Resolve-AzlAdapterName -Infrastructure $Infrastructure -FileName $fileName -AdapterMap $resolveMap -Warnings $resolveLog }
    $intents = @(ConvertTo-List (& $g 'networking.intents' @()) | ForEach-Object { ConvertTo-AzlArmIntent -Intent $_ -Resolve $resolve })
    if (-not $intents) { throw 'networking.intents is empty.' }

    # ---- the management network
    $subnet = [string](& $g 'networking.management.subnet' '')
    $prefix = [int]($subnet.Split('/')[1])
    $mask = ConvertTo-SubnetMask -PrefixLength $prefix
    $useDhcp = [bool](& $g 'networking.management.use_dhcp' $false)

    $deploymentMode = if ($Mode) { $Mode } else { (Get-Culture).TextInfo.ToTitleCase([string](& $g 'cluster.deployment_mode' 'validate')) }
    $witnessType = [string](& $g 'cluster.witness.type' 'none')
    if ($witnessType -eq 'file_share') { throw 'A file share witness is for disconnected operations; Microsoft''s quickstart templates take a cloud witness or none.' }
    $modeMap = @{ express = 'Express'; infra_only = 'InfraOnly'; keep_storage = 'KeepStorage' }
    $configurationMode = $modeMap[[string](& $g 'storage.configuration_mode' $(if ($storage -eq 'san') { 'infra_only' } else { 'express' }))]
    $switchless = ([string](& $g 'scenario.storage_connectivity' 'switched')) -eq 'switchless'
    $networkingType = if ($nodes.Count -eq 1) { 'singleServerDeployment' } elseif ($switchless) { 'switchlessMultiServerDeployment' } else { 'switchedMultiServerDeployment' }

    $sbeFile = & $g 'hardware.sbe' $null
    $sbe = @{}
    foreach ($pair in @(@('sbeVersion', 'version', 'sbeVersion'), @('sbeFamily', 'family', 'sbeFamily'), @('sbePublisher', 'publisher', 'sbePublisher'), @('sbeManifestSource', 'manifest_source', 'sbeManifestSource'), @('sbeManifestCreationDate', 'manifest_creation_date', 'sbeManifestCreationDate'))) {
        $value = [string](Get-AzlProp $sbeFile $pair[1] '')
        if (-not $value -and $SbeDeployment -and $SbeDeployment.Contains($pair[2])) { $value = [string]$SbeDeployment[$pair[2]] }
        $sbe[$pair[0]] = $value
    }
    # The Solution Builder Extension is opt-in. A deployment without one passes none of the seven SBE parameters (the quickstart
    # template defaults them to empty strings and empty lists, so an omitted parameter is the same as an empty one).
    # An SBE is configured when it has a version.
    $sbeConfigured = [bool]$sbe.sbeVersion
    if (-not $sbeConfigured) {
        $leftover = @($sbe.Keys | Where-Object { $sbe[$_] } | Sort-Object)
        if ($leftover) { $warnings.Add("hardware.sbe gives $($leftover -join ', ') but no version, so no SBE is configured and none of the SBE parameters is passed. Set hardware.sbe.version to deploy with an SBE.") }
    }

    $kvRef = { param($ref) if ($ref) { [ordered]@{ KeyVault = [string]$ref } } else { $null } }
    $p = [ordered]@{}
    $p.deploymentMode = $deploymentMode
    $p.keyVaultName = [string](& $g 'cluster.key_vault.name' '')
    $p.createNewKeyVault = [bool](& $g 'cluster.key_vault.create_new' $true)
    $p.softDeleteRetentionDays = [int](& $g 'cluster.key_vault.soft_delete_retention_days' 30)
    $p.diagnosticStorageAccountName = [string](& $g 'cluster.diagnostics.storage_account' '')
    $p.logsRetentionInDays = [int](& $g 'cluster.diagnostics.logs_retention_days' 30)
    $p.storageAccountType = [string](& $g 'cluster.diagnostics.storage_account_type' 'Standard_LRS')
    $p.clusterName = $clusterName
    $p.location = [string](& $g 'azure.location' '')
    $p.tenantId = [string](& $g 'azure.tenant_id' '')
    $p.witnessType = if ($witnessType -eq 'cloud') { 'Cloud' } else { 'No Witness' }
    $p.clusterWitnessStorageAccountName = if ($witnessType -eq 'cloud') { [string](& $g 'cluster.witness.storage_account' '') } else { '' }
    $p.localAdminUserName = $localUser
    $p.localAdminPassword = & $kvRef (Get-AzlProp $local 'password')
    $hciOid = if ($HciResourceProviderObjectId) { $HciResourceProviderObjectId } else { [string](& $g 'azure.hci_resource_provider_object_id' '') }
    if (-not $hciOid) { $warnings.Add('azure.hci_resource_provider_object_id is not set: it is looked up in the directory when the deployment runs (needs permission to read the Azure Local resource provider''s service principal).') }
    $p.hciResourceProviderObjectID = $hciOid
    $p.arcNodeResourceIds = $arcIds
    $p.namingPrefix = [string](& $g 'cluster.naming_prefix' 'hci')
    $p.securityLevel = (Get-Culture).TextInfo.ToTitleCase([string](& $g 'security.level' 'recommended'))
    foreach ($m in @(@('driftControlEnforced', 'drift_control', $true), @('credentialGuardEnforced', 'credential_guard', $true), @('smbSigningEnforced', 'smb_signing', $true), @('smbClusterEncryption', 'smb_cluster_encryption', $false), @('bitlockerBootVolume', 'bitlocker_boot_volume', $true), @('bitlockerDataVolumes', 'bitlocker_data_volumes', $true), @('wdacEnforced', 'wdac', $true))) {
        $p[$m[0]] = [bool](& $g "security.$($m[1])" $m[2])
    }
    $p.streamingDataClient = [bool](& $g 'security.telemetry.streaming_data' $true)
    $p.euLocation = [bool](& $g 'security.telemetry.eu_location' $false)
    $p.episodicDataUpload = [bool](& $g 'security.telemetry.episodic_data_upload' $true)
    $p.configurationMode = $configurationMode
    $p.subnetMask = $mask
    $p.defaultGateway = [string](& $g 'networking.management.gateway' '')
    $p.startingIPAddress = [string](& $g 'networking.management.infrastructure_pool.start' '')
    $p.endingIPAddress = [string](& $g 'networking.management.infrastructure_pool.end' '')
    $p.dnsServers = @(ConvertTo-List (& $g 'networking.management.dns_servers' @()) | ForEach-Object { [string]$_ })
    $p.useDhcp = $useDhcp
    $p.physicalNodesSettings = $physical
    $p.networkingType = $networkingType
    $p.networkingPattern = Get-AzlNetworkingPattern -Intents @(ConvertTo-List (& $g 'networking.intents' @()))
    $p.intentList = $intents
    $p.storageConnectivitySwitchless = $switchless
    $p.customLocation = [string](& $g 'azure.custom_location' "$clusterName-cl")
    if ($sbeConfigured) {
        foreach ($k in $sbe.Keys) { $p[$k] = $sbe[$k] }
        # Properties and secrets that the hardware vendor's SBE asks for (hardware.sbe.partner_properties and partner_credentials); empty lists when the file names none.
        # Microsoft's template takes each credential as { secretName, secretValue }, writes the value into the cluster's Key Vault (cluster.key_vault.name) under secretName
        # and gives the SBE the address. The file holds a secret reference; here it stays a reference (like localAdminPassword) and is read when the deployment is submitted.
        $partnerProperties = [System.Collections.Generic.List[object]]::new()
        foreach ($property in @(ConvertTo-List (& $g 'hardware.sbe.partner_properties' @()))) {
            $propertyName = ([string](Get-AzlProp $property 'name' '')).Trim()
            if (-not $propertyName) { throw 'hardware.sbe.partner_properties has an entry with no name.' }
            $partnerProperties.Add([ordered]@{ name = $propertyName; value = [string](Get-AzlProp $property 'value' '') })
        }
        $partnerCredentials = [System.Collections.Generic.List[object]]::new()
        foreach ($credential in @(ConvertTo-List (& $g 'hardware.sbe.partner_credentials' @()))) {
            $secretName = ([string](Get-AzlProp $credential 'secret_name' '')).Trim()
            if (-not $secretName) { throw 'hardware.sbe.partner_credentials has an entry with no secret_name.' }
            $secretReference = ([string](Get-AzlProp $credential 'secret' '')).Trim()
            if (-not $secretReference) { throw "hardware.sbe.partner_credentials entry '$secretName' has no secret. Give a secret reference (keyvault://, env://, file:// or command://): the deployment template writes its value into the cluster Key Vault as '$secretName'." }
            if (-not (Get-AzlSecretProvider -Reference $secretReference)) { throw "hardware.sbe.partner_credentials entry '$secretName' holds a value ($($secretReference.Length) characters), not a secret reference. Use keyvault://<vault>/<secret>, env://<name>, file://<name> or command://<name>; a secret value is never written in the file." }
            $partnerCredentials.Add([ordered]@{ secretName = $secretName; secretValue = (& $kvRef $secretReference) })
        }
        $p.partnerProperties = $partnerProperties.ToArray()
        $p.partnerCredentiallist = $partnerCredentials.ToArray()
    }

    # ---- Active Directory or local identity
    if ($identity -eq 'active_directory') {
        $ad = & $g 'identity.active_directory' $null
        $p.domainFqdn = [string](Get-AzlProp $ad 'domain_fqdn' '')
        $p.adouPath = [string](Get-AzlProp $ad 'ou_path' '')
        $lcmName = [string](Get-AzlProp $ad 'lcm_user.username' '')
        if ($lcmName.Length -gt 20) { throw "identity.active_directory.lcm_user.username is $($lcmName.Length) characters; the limit is 20." }
        $p.AzureStackLCMAdminUsername = $lcmName
        $p.AzureStackLCMAdminPassword = & $kvRef (Get-AzlProp $ad 'lcm_user.password')
    }
    else {
        $li = & $g 'identity.local_identity' $null
        $p.identityProvider = 'LocalIdentity'
        $p.dnsServerConfig = if ([string](Get-AzlProp $li 'dns_server_config' 'use_dns_server') -eq 'use_forwarder') { 'UseForwarder' } else { 'UseDnsServer' }
        $p.dnsZones = @([ordered]@{ dnsZoneName = [string](Get-AzlProp $li 'dns_zone' ''); dnsForwarder = @(ConvertTo-List (Get-AzlProp $li 'dns_forwarders' @()) | ForEach-Object { [string]$_ }) })
    }

    # ---- storage networks (S2D) or cluster networks (SAN)
    if ($template.Name -in 'create-cluster-san', 'create-cluster-adless-san', 'create-cluster-san-iscsi') {
        foreach ($pair in @(@('infraVolLunId', 'storage.san.infra_volume_lun_id'), @('infraPerfLunId', 'storage.san.performance_history_lun_id'))) {
            try { $p[$pair[0]] = Resolve-AzlSanLunId -LunId ([string](& $g $pair[1] '')) -NodeReport $NodeReport -Source $SanLunIdSource }
            catch {
                if (-not $AllowUnresolvedSanLun) { throw }
                $warnings.Add("$($pair[0]) is empty: $($_.Exception.Message)")
                $p[$pair[0]] = ''
            }
        }
        $cluster = @(ConvertTo-List (& $g 'networking.cluster_networks' @()))
        if (-not $cluster) { throw 'A SAN deployment needs networking.cluster_networks (ARM sanNetworkList).' }
        # The adapter properties of the cluster networks: networking.cluster_network_properties; the registry defaults are the values of Microsoft's template.
        $clusterProperties = & $g 'networking.cluster_network_properties' $null
        $p.sanNetworkList = [ordered]@{
            clusterNetworkConfig = [ordered]@{
                adapterProperties = [ordered]@{
                    bandwidthPercentageSmb         = [int](Get-AzlProp $clusterProperties 'bandwidth_percentage_smb' 50)
                    jumboPacket                    = [int](Get-AzlProp $clusterProperties 'jumbo_packet' 9014)
                    priorityValue8021ActionCluster = [int](Get-AzlProp $clusterProperties 'priority_cluster' 7)
                    priorityValue8021ActionSmb     = [int](Get-AzlProp $clusterProperties 'priority_smb' 3)
                }
                adapterIPConfig   = @($cluster | ForEach-Object { [ordered]@{ name = [string]$_['name']; networkAdapterName = (& $resolve ([string]$_['adapter'])); vlanId = [int]$_['vlan_id']; addressPrefix = [string]$_['subnet'] } })
            }
        }
        # ---- iSCSI: the template takes one object per node (Arc ID, name, address, initiator name, iSCSI ports) and the CHAP type.
        # The iSCSI ports are dedicated physical ports outside Network ATC (Learn: Connect an external storage array to Azure Local).
        if ($template.Name -eq 'create-cluster-san-iscsi') {
            $iscsi = & $g 'storage.san.iscsi' $null
            $chapOn = [bool](Get-AzlProp $iscsi 'chap.enabled' $false)
            $p.chapType = if (-not $chapOn) { 'None' } elseif ([bool](Get-AzlProp $iscsi 'chap.mutual' $false)) { 'Mutual' } else { 'OneWay' }
            if ($chapOn) {
                $p.chapUsername = [string](Get-AzlProp $iscsi 'chap.username' '')
                $p.chapCredential = & $kvRef (Get-AzlProp $iscsi 'chap.secret')
                if (-not $p.chapUsername -or -not $p.chapCredential) { throw 'storage.san.iscsi.chap.enabled is true: storage.san.iscsi.chap.username and chap.secret (a secret reference) are needed.' }
            }
            $iscsiNetworks = @{}
            foreach ($iscsiNet in ConvertTo-List (Get-AzlProp $iscsi 'networks' @())) { $iscsiNetworks[([string]$iscsiNet['fabric']).ToLowerInvariant()] = $iscsiNet }
            if (-not $iscsiNetworks.Count) { throw 'An iSCSI SAN deployment needs storage.san.iscsi.networks: the subnet and VLAN of each iSCSI path (fabric A and B).' }
            $targets = @(ConvertTo-List (Get-AzlProp $iscsi 'targets' @()))
            $jumbo = [int](Get-AzlProp $iscsi 'jumbo_packet' 1514)
            $p.nodes = @(for ($i = 0; $i -lt $nodes.Count; $i++) {
                    $n = $nodes[$i]
                    $iqn = [string](Get-AzlProp $n 'san.initiator_iqn' '')
                    if (-not $iqn) { throw "Node $($n['name']) has no san.initiator_iqn. The iSCSI deployment needs the initiator name of every machine." }
                    $ports = @(foreach ($port in Get-AzlNodeNetworkAdapter -Infrastructure $Infrastructure -Node $n) {
                            foreach ($role in ConvertTo-List $port['roles']) { if ("$role" -in 'iscsi:a', 'iscsi:b') { [pscustomobject]@{ Name = [string]$port['name']; Fabric = "$role".Split(':')[1] } } }
                        }) | Sort-Object Fabric, Name
                    if (-not $ports) { throw "Node $($n['name']) has no port with the role iscsi:a or iscsi:b (nodes[].network_adapters[].roles)." }
                    $config = @(foreach ($port in $ports) {
                            $iscsiNet = $iscsiNetworks[$port.Fabric]
                            if (-not $iscsiNet) { throw "Port $($port.Name) of node $($n['name']) has the role iscsi:$($port.Fabric), but storage.san.iscsi.networks has no entry for fabric $($port.Fabric.ToUpperInvariant())." }
                            $entry = [ordered]@{ networkAdapterName = (& $resolve $port.Name); vlanId = [int](Get-AzlProp $iscsiNet 'vlan_id' 0); addressPrefix = [string]$iscsiNet['subnet'] }
                            $nextHop = [string](Get-AzlProp $iscsiNet 'next_hop' '')
                            # The target portals of this path, each with its next hop. A portal in the subnet of the port is its own next hop, as in
                            # Microsoft's sample; with networks[].next_hop the portals are reached through that router.
                            $portals = @($targets | Where-Object { -not $_['fabric'] -or ([string]$_['fabric']).ToLowerInvariant() -eq $port.Fabric } | ForEach-Object { ConvertTo-List $_['portals'] } | ForEach-Object { ([string]$_).Split(':')[0] } | Select-Object -Unique)
                            if (-not $portals) { throw "storage.san.iscsi.targets lists no portal for fabric $($port.Fabric.ToUpperInvariant()). The iSCSI deployment needs the target portals of every path." }
                            $entry.targetPortalAddresses = @($portals | ForEach-Object { [ordered]@{ ipAddress = $_; nextHop = $(if ($nextHop) { $nextHop } else { $_ }) } })
                            $entry
                        })
                    [ordered]@{ arcNodeResourceId = $arcIds[$i]; name = [string]$n['name']; ipv4Address = [string]$physical[$i].ipv4Address; initiatorIqn = $iqn; iScsiNetworkConfig = [ordered]@{ adapterProperties = [ordered]@{ jumboPacket = $jumbo }; adapterIPConfig = $config } }
                })
            # This template takes the nodes as one list and has no networking type, pattern or security level parameter.
            foreach ($k in 'arcNodeResourceIds', 'physicalNodesSettings', 'networkingType', 'networkingPattern', 'securityLevel') { $p.Remove($k) }
        }
    }
    else {
        $autoIp = [bool](& $g 'networking.storage.auto_ip' $true)
        $p.enableStorageAutoIp = $autoIp
        $networks = @(ConvertTo-List (& $g 'networking.storage.networks' @()))
        $list = for ($i = 0; $i -lt $networks.Count; $i++) {
            $net = $networks[$i]
            $entry = [ordered]@{ name = [string]$net['name']; networkAdapterName = (& $resolve ([string]$net['adapter'])); vlanId = [string]$net['vlan_id'] }
            if (-not $autoIp) {
                $maskBits = [int]([string]$net['subnet']).Split('/')[1]
                $networkMask = ConvertTo-SubnetMask -PrefixLength $maskBits
                $entry.storageAdapterIPInfo = @($nodes | ForEach-Object { [ordered]@{ physicalNode = [string]$_['name']; ipv4Address = [string](ConvertTo-List $_['storage_ips'])[$i]; subnetMask = $networkMask } })
            }
            $entry
        }
        $p.storageNetworkList = @($list)
        if ($switchless) { $warnings.Add('Switchless storage: check each storage network''s per-node addresses (nodes[].storage_ips); Microsoft''s switchless samples give every pair of machines its own subnet.') }
    }

    # ---- rack aware
    if ($template.Name -eq 'create-cluster-rac-enabled') {
        $p.clusterPattern = 'RackAware'
        $zones = @{}
        foreach ($n in $nodes) {
            $z = [string]$n['zone']
            if (-not $z) { throw "Node $($n['name']) has no zone; a rack aware cluster needs one on every node." }
            if (-not $zones.ContainsKey($z)) { $zones[$z] = @() }
            $zones[$z] += [string]$n['name']
        }
        $p.localAvailabilityZones = @($zones.Keys | Sort-Object | ForEach-Object { [ordered]@{ localAvailabilityZoneName = $_; nodes = @($zones[$_]) } })
    }

    # ---- keep only what the template declares (the catalog is the authority)
    $declared = $Catalog.templates[$template.Name].parameters
    $final = [ordered]@{}
    foreach ($k in $p.Keys) {
        if ($declared.ContainsKey($k)) { $final[$k] = $p[$k] }
        elseif ($null -ne $p[$k] -and "$($p[$k])" -ne '' ) { $warnings.Add("Dropped ${k}: template $($template.Name) has no such parameter.") }
    }
    [pscustomobject]@{
        Template                     = $template
        Parameters                   = $final
        Warnings                     = $warnings.ToArray()
        DeploymentSettingsApiVersion = [string]$Catalog.templates[$template.Name].deploymentSettingsApiVersion
    }
}

function Test-AzlArmParameterSet {
    <#
    .SYNOPSIS
        Checks a parameter set against the template's parameter list. Returns the problems; nothing when it is clean.
    .PARAMETER TemplateParameters
        Name -> @{ type; required; allowed } from the catalog, or built from a template file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ParameterSet, [Parameter(Mandatory)][System.Collections.IDictionary]$TemplateParameters)
    $problems = [System.Collections.Generic.List[string]]::new()
    $values = $ParameterSet.Parameters
    foreach ($k in $values.Keys) { if (-not $TemplateParameters.Contains($k)) { $problems.Add("$k isn't a parameter of the template.") } }
    foreach ($k in $TemplateParameters.Keys) {
        $def = $TemplateParameters[$k]
        $has = $values.Contains($k) -and $null -ne $values[$k] -and -not ($values[$k] -is [string] -and $values[$k] -eq '' -and $k -notin 'clusterWitnessStorageAccountName')
        if ($def['required'] -and -not $has) { $problems.Add("$k is required by the template and has no value.") }
        if (-not $values.Contains($k)) { continue }
        $v = $values[$k]
        $type = [string]$def['type']
        $bad = switch ($type) {
            'bool' { $v -isnot [bool] }
            'int' { $v -isnot [int] }
            'array' { $v -is [string] -or $v -is [System.Collections.IDictionary] }
            'object' { $v -isnot [System.Collections.IDictionary] }
            { $_ -in 'string', 'securestring' } { $v -isnot [string] -and -not ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) -and $null -ne $v }
            default { $false }
        }
        if ($bad) { $problems.Add("$k should be $type, not $($v.GetType().Name).") }
        if ($def.Contains('allowed') -and $v -is [string] -and $v -and @($def['allowed'] | Where-Object { $_ -ieq $v }).Count -eq 0) { $problems.Add("$k is '$v'; the template allows $($def['allowed'] -join ', ').") }
    }
    foreach ($s in $script:SecretParameters) { if ($values.Contains($s) -and $values[$s] -is [string]) { $problems.Add("$s holds a value; a secret must be a secret reference (keyvault://, env://, file:// or command://).") } }
    # The secrets inside list parameters (the SBE partner credentials): each must be a reference, never a value. The message does not repeat the value.
    foreach ($slot in @(Get-AzlArmNestedSecret -Parameters $values)) {
        if (-not $slot.SecretName.Trim()) { $problems.Add("$($slot.Parameter)[$($slot.Index)] has no secretName; the template needs the name the secret gets in the cluster Key Vault.") }
        if ($slot.IsReference) { continue }
        if ($slot.Value -is [string] -and $slot.Value) { $problems.Add("$($slot.Label) holds a value ($($slot.Value.Length) characters); a secret must be a secret reference (keyvault://, env://, file:// or command://).") }
        else { $problems.Add("$($slot.Label) has no secret reference; the template writes the value into the cluster Key Vault, so every partner credential needs one.") }
    }
    return $problems.ToArray()
}

function ConvertTo-AzlArmParameterFile {
    <#
    .SYNOPSIS
        The ARM parameter file as JSON. A secret is a Key Vault reference (with -SecretMode KeyVaultReference) or null; never a value.
    .PARAMETER SecretMode
        Placeholder (default): secrets are null and the deployment fills them from Key Vault in memory.
        KeyVaultReference: secrets are { reference: { keyVault: { id }, secretName } }; ARM reads them itself. The vault needs
        "Azure Resource Manager for template deployment" access enabled. Only a keyvault:// reference can be handed to ARM
        like this. With env://, file:// or command:// this mode refuses, because ARM cannot read those providers; use
        Placeholder and let Invoke-AzlArmDeployment read the value on this machine.
        The SBE partner credentials (partnerCredentiallist) are a list of { secretName, secretValue }; ARM cannot read a reference
        inside an array. Placeholder writes secretValue as null (the deployment reads it on this machine and sends it); KeyVaultReference
        refuses when the list has an entry. No value is ever written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$ParameterSet,
        [System.Collections.IDictionary]$Infrastructure,
        [ValidateSet('Placeholder', 'KeyVaultReference')][string]$SecretMode = 'Placeholder'
    )
    if ($SecretMode -eq 'KeyVaultReference') {
        $first = @(Get-AzlArmNestedSecret -Parameters $ParameterSet.Parameters) | Select-Object -First 1
        if ($first) { throw "Parameter $($first.Parameter) holds partner credentials (hardware.sbe.partner_credentials), and ARM cannot read a Key Vault reference inside an array, so -SecretMode KeyVaultReference refuses it. Use -SecretMode Placeholder and run the deployment from the toolkit, which reads the value on this machine." }
    }
    $out = [ordered]@{}
    foreach ($k in $ParameterSet.Parameters.Keys) {
        $v = $ParameterSet.Parameters[$k]
        if ($script:NestedSecretFields.ContainsKey($k) -and $null -ne $v) {
            # The secret field of every entry is null in the file, whatever it holds.
            $field = [string]$script:NestedSecretFields[$k]
            $entries = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in @(ConvertTo-List $v)) {
                if ($entry -isnot [System.Collections.IDictionary]) { throw "Parameter $k should be a list of entries with a secretName and a $field." }
                $item = [ordered]@{}
                foreach ($f in $entry.Keys) { $item[$f] = if ($f -eq $field) { $null } else { $entry[$f] } }
                $entries.Add($item)
            }
            $out[$k] = [ordered]@{ value = $entries.ToArray() }
            continue
        }
        if ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) {
            if ($SecretMode -eq 'Placeholder' -or -not $Infrastructure) { $out[$k] = [ordered]@{ value = $null }; continue }
            $ref = ConvertFrom-AzlKeyVaultRef -Reference $v.KeyVault
            # ARM reads only Key Vault. A secret from env, file or command cannot be handed over as a reference.
            if (-not $ref) { throw "Parameter $k is not a keyvault:// reference (provider: $(Get-AzlSecretProvider $v.KeyVault)). ARM can read only a keyvault:// reference, so -SecretMode KeyVaultReference refuses it. Use -SecretMode Placeholder: the deployment then reads the secret on this machine and sends it as a secure parameter." }
            $vault = @(ConvertTo-List $Infrastructure['key_vaults']) | Where-Object { $_['name'] -eq $ref.Vault } | Select-Object -First 1
            if (-not $vault) { throw "Vault $($ref.Vault) isn't listed under key_vaults." }
            $out[$k] = [ordered]@{ reference = [ordered]@{ keyVault = [ordered]@{ id = "/subscriptions/$($vault['subscription_id'])/resourceGroups/$($vault['resource_group'])/providers/Microsoft.KeyVault/vaults/$($vault['name'])" }; secretName = $ref.Secret } }
        }
        else { $out[$k] = [ordered]@{ value = $v } }
    }
    [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $out } | ConvertTo-Json -Depth 30
}

function Get-AzlTemplateParameterDefinition {
    <#
    .SYNOPSIS
        The parameters a template (parsed JSON, from a file or a download) declares, in the catalog's shape:
        name -> @{ type; required; allowed }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Template)
    $json = $Template | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -AsHashtable
    $defs = [ordered]@{}
    foreach ($k in $json['parameters'].Keys) {
        $p = $json['parameters'][$k]
        $e = [ordered]@{ type = ([string]$p['type']).ToLowerInvariant(); required = (-not $p.ContainsKey('defaultValue')) }
        if ($p.ContainsKey('allowedValues')) { $e['allowed'] = @($p['allowedValues']) }
        $defs[$k] = $e
    }
    return $defs
}

function Get-AzlAdapterMapFromReport {
    <#
    .SYNOPSIS
        node -> (MAC -> OS adapter name) from the OS configuration report (Set-AzureLocalNodeConfiguration -ReportPath).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Report)
    $map = @{}
    foreach ($n in @(Get-AzlProp $Report 'nodes' @())) {
        $byMac = @{}
        foreach ($port in @(Get-AzlProp $n 'ports' @())) { if ($port.mac) { $byMac[(ConvertTo-MacKey $port.mac)] = [string]$port.osName } }
        $map[[string]$n.name] = $byMac
    }
    return $map
}

# ---------------------------------------------------------------------------------------------------------------------
# Validate and Deploy
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlHciResourceProviderObjectId {
    # The object ID of the Azure Local resource provider's service principal in the tenant (application 1412d89f-...). Reads the directory.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $sp = Get-AzADServicePrincipal -ApplicationId '1412d89f-b8a8-4111-b4fd-e82905cbd85d'
    if (-not $sp) { throw 'The Azure Local resource provider''s service principal (1412d89f-b8a8-4111-b4fd-e82905cbd85d) isn''t in this tenant. Register Microsoft.AzureStackHCI, or set azure.hci_resource_provider_object_id.' }
    return [string]$sp.Id
}

function Get-AzlDeploymentState {
    <#
    .SYNOPSIS
        The cluster's deploymentSettings/default as the deployment tool sees it: provisioning state, the validation status and
        its steps, the deployment status. $null when the cluster resource doesn't exist yet. Reads only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ClusterName)
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/clusters/$ClusterName/deploymentSettings/default"
    $r = Invoke-AzlArm -Method GET -Path $path -ApiVersion $script:HciApiVersion -AllowNotFound
    if (-not $r) { return $null }
    # FullStepIndex is the number the portal shows ("0.41"): the step's own fullStepIndex, else its position path.
    $flatten = {
        param($steps, $depth, $prefix)
        $position = 0
        foreach ($s in @($steps)) {
            if (-not $s) { continue }
            $path = if ($prefix) { "$prefix.$position" } else { [string]$position }
            $position++
            # Errors: the full text of every exception, never cut. ErrorJson: an exception that is an object is also kept whole as JSON,
            # because its other members (EnvironmentValidator Results with Description, Remediation, AdditionalData.Detail) carry the reason.
            $exceptions = @(Get-AzlProp $s 'exception' @())
            $errors = foreach ($e in $exceptions) {
                $text = if ($e -is [string]) { $e } elseif (Get-AzlProp $e 'message') { [string](Get-AzlProp $e 'message') } else { ConvertTo-Json -InputObject $e -Depth 20 -Compress }
                if ($text) { $text }
            }
            $errorJson = foreach ($e in $exceptions) { if ($e -and $e -isnot [string]) { ConvertTo-Json -InputObject $e -Depth 20 -Compress } }
            [pscustomobject]@{
                Depth = $depth; Name = [string](Get-AzlProp $s 'name' ''); Status = [string](Get-AzlProp $s 'status' ''); Description = [string](Get-AzlProp $s 'description' '')
                FullStepIndex = [string](Get-AzlProp $s 'fullStepIndex' $path)
                StartTime = [string](Get-AzlProp $s 'startTimeUtc' ''); EndTime = [string](Get-AzlProp $s 'endTimeUtc' '')
                Errors = @($errors); ErrorJson = @($errorJson)
            }
            & $flatten (Get-AzlProp $s 'steps' @()) ($depth + 1) $path
        }
    }
    $validation = Get-AzlProp $r 'properties.reportedProperties.validationStatus'
    $deployment = Get-AzlProp $r 'properties.reportedProperties.deploymentStatus'
    [pscustomobject]@{
        ProvisioningState = [string](Get-AzlProp $r 'properties.provisioningState' '')
        ValidationStatus  = [string](Get-AzlProp $validation 'status' '')
        ValidationSteps   = @(& $flatten (Get-AzlProp $validation 'steps' @()) 0)
        DeploymentStatus  = [string](Get-AzlProp $deployment 'status' '')
        DeploymentSteps   = @(& $flatten (Get-AzlProp $deployment 'steps' @()) 0)
    }
}

function Invoke-AzlArmDeployment {
    <#
    .SYNOPSIS
        Submits the parameter set to the quickstart template at the resource group, waits, and reports the result.
    .DESCRIPTION
        Mode Validate creates the Azure resources and runs the validation (deploymentMode Validate). Mode Deploy runs the
        real deployment and needs a Validate that succeeded. Refuses Validate when the instance is in a failed deployment
        state (Microsoft: another Validate resets the system's properties and can break license sync); -AllowRevalidate
        overrides that and is for support-guided recovery only.
        The secret parameters are read into memory and sent to ARM as secure parameters; they are never written. They are read
        with the toolkit's secret resolver (AzlSecret.psm1), so a reference can use any provider: keyvault://, env://, file:// or
        command://. This is why every provider works here: the value is read on this machine and sent in the request body of a
        securestring template parameter. Only the parameter FILE with -SecretMode KeyVaultReference hands ARM a Key Vault
        reference to read, and that works with Key Vault alone (see ConvertTo-AzlArmParameterFile).
    .PARAMETER Infrastructure
        The loaded infrastructure file. Needed by the default -SecretResolver (the vault must be listed under key_vaults; the
        secrets section holds the file directory and the command).
    .OUTPUTS
        Mode, DeploymentName, ProvisioningState, ValidationStatus, ValidationSteps, FailedSteps, Error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ParameterSet,
        [Parameter(Mandatory)][object]$Template,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Mode,
        [string]$DeploymentSettingsApiVersion,
        [int]$TimeoutMinutes,
        [int]$PollSeconds = 30,
        # The ARM deployment's name. Default: <prefix>-<mode>-<time stamp>. AzlArmDeploymentRun passes <prefix>-<mode>-<parameter hash>,
        # so the same parameters are the same deployment and a re-run can attach to it.
        [string]$DeploymentName,
        # The first part of the default name (the run setting deploymentNamePrefix, azl by default, is what the run uses).
        [ValidatePattern('^[a-z][a-z0-9-]{0,29}$')][string]$DeploymentNamePrefix = 'azl',
        [switch]$NoWait,
        [switch]$AllowRevalidate,
        [switch]$SkipValidationCheck,
        # The loaded infrastructure file: the default resolver needs it (key_vaults and the secrets section).
        [System.Collections.IDictionary]$Infrastructure,
        # Reads a secret reference to its value (plain text, for the request body). Default: the toolkit resolver, any provider.
        [scriptblock]$SecretResolver = { param($Ref) Get-AzlSecretPlainText -Reference $Ref -Infrastructure $Infrastructure }
    )
    $clusterName = [string]$ParameterSet.Parameters['clusterName']
    foreach ($lun in 'infraVolLunId', 'infraPerfLunId') { if ($ParameterSet.Parameters.Contains($lun) -and -not $ParameterSet.Parameters[$lun]) { throw "$lun is empty. Run the OS configuration first (its report maps the LUN numbers to the disks' UniqueIds), or write the UniqueId in storage.san." } }
    $before = Get-AzlDeploymentState -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ClusterName $clusterName
    if ($Mode -eq 'Validate' -and $before -and ($before.ProvisioningState -eq 'Failed' -or $before.DeploymentStatus -in 'Failed', 'Error') -and -not $AllowRevalidate) {
        throw "The instance $clusterName is in a failed deployment state ($($before.ProvisioningState), deployment $($before.DeploymentStatus)). Microsoft: don't run Validate again after a failed deployment; it resets the system properties and can break license sync. Fix the cause and redeploy with Mode Deploy, or get support's guidance (-AllowRevalidate)."
    }
    if ($Mode -eq 'Deploy' -and -not $SkipValidationCheck) {
        # Azure reports a green validation as 'Success' (2610) or 'Succeeded' (older builds); both mean the same.
        if (-not $before -or ([string]$before.ValidationStatus -replace '[\s_\-]', '') -notin 'Success', 'Succeeded', 'ValidationSuccess') { throw "No successful validation to deploy from (validation status '$(if ($before) { $before.ValidationStatus } else { 'no cluster resource' })'). Run Mode Validate first and let it succeed." }
    }

    # ---- secrets into memory, then the request
    $parameters = [ordered]@{}
    foreach ($k in $ParameterSet.Parameters.Keys) {
        $v = $ParameterSet.Parameters[$k]
        if ($v -is [System.Collections.IDictionary] -and $v.Contains('KeyVault')) { $parameters[$k] = @{ value = [string](& $SecretResolver $v.KeyVault) } }
        elseif ($script:NestedSecretFields.ContainsKey($k) -and $null -ne $v) {
            # The SBE partner credentials: the secret inside each entry is read now and sent as the plain array Microsoft's template declares (the template writes it
            # into the cluster's Key Vault). It is in the request body only; the message of a refusal does not repeat it.
            $field = [string]$script:NestedSecretFields[$k]
            $entries = [System.Collections.Generic.List[object]]::new()
            $index = 0
            foreach ($entry in @(ConvertTo-List $v)) {
                if ($entry -isnot [System.Collections.IDictionary]) { throw "Parameter $k[$index] is not an entry with a secretName and a $field. Nothing was sent." }
                $held = if ($entry.Contains($field)) { $entry[$field] } else { $null }
                if (-not ($held -is [System.Collections.IDictionary] -and $held.Contains('KeyVault'))) { throw "$k[$index].$field is not a secret reference. Nothing was sent." }
                $resolved = [string](& $SecretResolver $held.KeyVault)
                if (-not $resolved) { throw "$k[$index].$field resolved to an empty value (secret name $($entry['secretName'])); the template cannot write an empty secret to the cluster Key Vault. Nothing was sent." }
                $item = [ordered]@{}
                foreach ($f in $entry.Keys) { $item[$f] = if ($f -eq $field) { $resolved } else { $entry[$f] } }
                $entries.Add($item)
                $index++
            }
            $parameters[$k] = @{ value = $entries.ToArray() }
        }
        else { $parameters[$k] = @{ value = $v } }
    }
    $parameters['deploymentMode'] = @{ value = $Mode }
    $templateBody = $Template | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -AsHashtable
    if ($DeploymentSettingsApiVersion) {
        $patched = 0
        $resources = $templateBody['resources']
        $list = if ($resources -is [System.Collections.IDictionary]) { @($resources.Values) } else { @($resources) }
        foreach ($r in $list) { if ([string]$r['type'] -ieq 'microsoft.azurestackhci/clusters/deploymentSettings') { $r['apiVersion'] = $DeploymentSettingsApiVersion; $patched++ } }
        if (-not $patched) { Write-Warning 'No deploymentSettings resource found to patch the api-version on.' }
    }
    $name = if ($DeploymentName) { $DeploymentName } else { '{0}-{1}-{2:yyyyMMddHHmmss}' -f $DeploymentNamePrefix, $Mode.ToLowerInvariant(), (Get-Date) }
    $path = "/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$name"
    $null = Invoke-AzlArm -Method PUT -Path $path -ApiVersion $script:DeploymentsApiVersion -Body @{ properties = @{ mode = 'Incremental'; template = $templateBody; parameters = $parameters } }
    if ($NoWait) { return [pscustomobject]@{ Mode = $Mode; DeploymentName = $name; ProvisioningState = 'Submitted'; ValidationStatus = ''; ValidationSteps = @(); FailedSteps = @(); Error = '' } }

    $limit = if ($TimeoutMinutes) { $TimeoutMinutes } elseif ($Mode -eq 'Validate') { 90 } else { 360 }
    $deadline = (Get-Date).AddMinutes($limit)
    $terminal = @('Succeeded', 'Failed', 'Canceled')
    do {
        Start-Sleep -Seconds $PollSeconds
        $deployment = Invoke-AzlArm -Method GET -Path $path -ApiVersion $script:DeploymentsApiVersion
        $state = [string](Get-AzlProp $deployment 'properties.provisioningState' '')
        if ($state -in $terminal -and $Mode -eq 'Validate') {
            $now = Get-AzlDeploymentState -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ClusterName $clusterName
            if ($state -eq 'Succeeded' -and $now -and $now.ValidationStatus -in '', 'InProgress', 'NotStarted') { $state = 'Running' }
        }
    } while ($state -notin $terminal -and (Get-Date) -lt $deadline)
    if ($state -notin $terminal) { throw "Deployment $name is still $state after $limit minutes. Check it in the portal; this tool stops waiting." }

    $after = Get-AzlDeploymentState -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ClusterName $clusterName
    $steps = if ($after) { if ($Mode -eq 'Validate') { $after.ValidationSteps } else { $after.DeploymentSteps } } else { @() }
    $error_ = [string](Get-AzlProp $deployment 'properties.error.message' '')
    [pscustomobject]@{
        Mode              = $Mode
        DeploymentName    = $name
        ProvisioningState = $state
        ValidationStatus  = $(if ($after) { $after.ValidationStatus } else { '' })
        ValidationSteps   = @($steps)
        FailedSteps       = @($steps | Where-Object { $_.Status -in 'Error', 'Failed' })
        Error             = $error_
    }
}

Export-ModuleMember -Function Get-AzlArmNestedSecret, Get-AzlArmDisplayParameter, Get-AzlArmTemplateCatalog, Select-AzlArmTemplate, Resolve-AzlAdapterName, Get-AzlNetworkingPattern, Resolve-AzlSanLunId, New-AzlArmParameterSet, Test-AzlArmParameterSet, ConvertTo-AzlArmParameterFile, Get-AzlAdapterMapFromReport, Get-AzlTemplateParameterDefinition, Get-AzlHciResourceProviderObjectId, Get-AzlDeploymentState, Invoke-AzlArmDeployment
