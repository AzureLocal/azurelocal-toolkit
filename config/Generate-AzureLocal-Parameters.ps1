<#
.SYNOPSIS
    Generates an Azure Local ARM template parameters file from infrastructure.yml.

.DESCRIPTION
    Reads the infrastructure YAML configuration file and produces a fully populated
    ARM template parameters JSON file suitable for submitting to Azure via
    az deployment group create, New-AzResourceGroupDeployment, or CI/CD pipelines.

    This is a utility script (not an Invoke-Orchestrated script). It does not
    execute any deployment - it only generates the parameters file.

    Supports all 54 parameters from the Microsoft Azure Local ARM template
    (azuredeploy.json, apiVersion 2025-09-15-preview).

    Handles complex array parameters dynamically:
      - physicalNodesSettings  (from cluster_nodes)
      - arcNodeResourceIds     (from cluster_arm_deployment.arc_node_resource_ids)
      - intentList             (from network_intents)
      - storageNetworkList     (from network_intents with storage_networks)

.PARAMETER ConfigPath
    Path to the infrastructure YAML file. Defaults to config/infrastructure.yml
    relative to the repository root.

.PARAMETER AuthType
    Authentication type: 'AD' for Active Directory or 'LocalIdentity' for
    local identity (no domain join). Affects domainFqdn and adouPath values.

.PARAMETER OutputPath
    Path for the generated parameters JSON file. Defaults to
    azuredeploy.parameters.<authtype>.generated.json in the current directory.

.PARAMETER WhatIf
    Show what would be generated without writing the file.

.EXAMPLE
    .\Generate-AzureLocal-Parameters.ps1 -ConfigPath "config/infrastructure-azl-demo.yml" -AuthType AD
    Generates AD parameters file from the azl-demo config.

.EXAMPLE
    .\Generate-AzureLocal-Parameters.ps1 -ConfigPath "config/infrastructure-azl-lab.yml" -AuthType LocalIdentity -WhatIf
    Shows what would be generated for local identity without writing a file.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$ConfigPath = "",

    [Parameter(Position = 1)]
    [ValidateSet("AD", "LocalIdentity")]
    [string]$AuthType = "AD",

    [Parameter(Position = 2)]
    [string]$OutputPath = "",

    [switch]$WhatIf
)

# ---------------------------------------------------------------------------
# Module check: powershell-yaml is required
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Module 'powershell-yaml' is required. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
    exit 1
}
Import-Module powershell-yaml -ErrorAction Stop

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$repoRoot = (Get-Location).Path

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot "configs\infrastructure.yml"
}
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

$authSuffix = if ($AuthType -eq "AD") { "ad" } else { "local-identity" }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Get-Location).Path "azuredeploy.parameters.$authSuffix.generated.json"
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Azure Local ARM Parameter Generator" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Config:    $ConfigPath"
Write-Host "  Auth Type: $AuthType"
Write-Host "  Output:    $OutputPath"
Write-Host ""

# ---------------------------------------------------------------------------
# Parse YAML configuration
# ---------------------------------------------------------------------------
Write-Host "Reading configuration file..." -ForegroundColor Yellow
try {
    $yaml = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml
    Write-Host "  Parsed successfully." -ForegroundColor Green
}
catch {
    Write-Error "Failed to parse YAML: $_"
    exit 1
}

# Shorthand references to config sections
$arm    = $yaml.cluster_arm_deployment           # cluster_arm_deployment.*
$acct   = $yaml.accounts                         # accounts.*
$intents = $yaml.networking.network_intents       # networking.network_intents[]
$nodes  = $yaml.cluster_nodes                     # cluster_nodes[]
$compute = $yaml.compute                          # compute.*

# ---------------------------------------------------------------------------
# Helper: Build physicalNodesSettings array from cluster_nodes
# ---------------------------------------------------------------------------
function Build-PhysicalNodesSettings {
    param([array]$ClusterNodes)
    $result = @()
    foreach ($node in $ClusterNodes) {
        $result += @{
            name        = $node.hostname
            ipv4Address = $node.management_ip
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Helper: Build intentList array from network_intents
# ---------------------------------------------------------------------------
# Reads explicit override flags and adapter property overrides from YAML.
# The YAML network_intents[] structure mirrors the ARM intentList[] schema,
# using snake_case for YAML and camelCase for the ARM output.
# ---------------------------------------------------------------------------
function Build-IntentList {
    param([array]$NetworkIntents)
    $result = @()
    foreach ($intent in $NetworkIntents) {
        # Read virtual switch config overrides from YAML (or defaults)
        $vsOverrides = $intent.virtual_switch_configuration_overrides
        $vsEnableIov = if ($vsOverrides -and $vsOverrides.enable_iov) { $vsOverrides.enable_iov } else { "" }
        $vsLoadBalancing = if ($vsOverrides -and $vsOverrides.load_balancing_algorithm) { $vsOverrides.load_balancing_algorithm } else { "" }

        # Read QoS policy overrides from YAML (or defaults)
        $qosOverrides = $intent.qos_policy_overrides
        $qosCluster = if ($qosOverrides -and $qosOverrides.priority_value_8021_action_cluster) { $qosOverrides.priority_value_8021_action_cluster } else { "7" }
        $qosSmb = if ($qosOverrides -and $qosOverrides.priority_value_8021_action_smb) { $qosOverrides.priority_value_8021_action_smb } else { "3" }
        $qosBandwidth = if ($qosOverrides -and $qosOverrides.bandwidth_percentage_smb) { $qosOverrides.bandwidth_percentage_smb } else { "50" }

        # Read adapter property overrides from YAML (or defaults)
        $adapterOverrides = $intent.adapter_property_overrides
        $jumboPacket = if ($adapterOverrides -and $adapterOverrides.jumbo_packet) { [string]$adapterOverrides.jumbo_packet } else { "1514" }
        $networkDirect = if ($adapterOverrides -and $adapterOverrides.network_direct) { $adapterOverrides.network_direct } else { "Disabled" }
        $networkDirectTech = if ($adapterOverrides -and $adapterOverrides.network_direct_technology) { $adapterOverrides.network_direct_technology } else { "" }

        $intentObj = [ordered]@{
            name                               = $intent.name
            trafficType                        = [array]$intent.traffic_types
            adapter                            = [array]$intent.adapter_names
            overrideVirtualSwitchConfiguration = [bool]$intent.override_virtual_switch_configuration
            virtualSwitchConfigurationOverrides = [ordered]@{
                enableIov              = $vsEnableIov
                loadBalancingAlgorithm = $vsLoadBalancing
            }
            overrideQosPolicy                  = [bool]$intent.override_qos_policy
            qosPolicyOverrides                 = [ordered]@{
                priorityValue8021Action_Cluster = $qosCluster
                priorityValue8021Action_SMB     = $qosSmb
                bandwidthPercentage_SMB         = $qosBandwidth
            }
            overrideAdapterProperty            = [bool]$intent.override_adapter_property
            adapterPropertyOverrides           = [ordered]@{
                jumboPacket             = $jumboPacket
                networkDirect           = $networkDirect
                networkDirectTechnology = $networkDirectTech
            }
        }

        $result += $intentObj
    }
    return $result
}

# ---------------------------------------------------------------------------
# Helper: Build storageNetworkList from networking.storage_networks
# ---------------------------------------------------------------------------
function Build-StorageNetworkList {
    param([array]$StorageNetworks)
    $result  = @()
    $counter = 1
    foreach ($sn in $StorageNetworks) {
        $result += [ordered]@{
            name               = if ($sn.name) { $sn.name } else { "StorageNetwork$counter" }
            networkAdapterName = $sn.adapter_name
            vlanId             = [string]$sn.vlan_id
        }
        $counter++
    }
    return $result
}

# ---------------------------------------------------------------------------
# Helper: Determine networkingPattern from intent layout
# ---------------------------------------------------------------------------
function Get-NetworkingPattern {
    param([array]$NetworkIntents)

    $intentCount = $NetworkIntents.Count
    if ($intentCount -eq 1) {
        $types = $NetworkIntents[0].traffic_types
        if (($types -contains "Management") -and ($types -contains "Compute") -and ($types -contains "Storage")) {
            return "hyperConverged"
        }
    }
    elseif ($intentCount -eq 2) {
        # Check if it's Management+Compute / Storage  or  Compute+Storage / Management
        $first  = $NetworkIntents[0].traffic_types
        $second = $NetworkIntents[1].traffic_types
        if (($first -contains "Management") -and ($first -contains "Compute")) {
            return "convergedManagementCompute"
        }
        if (($first -contains "Compute") -and ($first -contains "Storage")) {
            return "convergedComputeStorage"
        }
    }

    # 3+ intents or unrecognized layout
    return "custom"
}

# ---------------------------------------------------------------------------
# Helper: Determine networkingType from node count and config
# ---------------------------------------------------------------------------
function Get-NetworkingType {
    param($Config, [array]$ClusterNodes)

    $nodeCount = $ClusterNodes.Count

    if ($nodeCount -eq 1) {
        return "singleServerDeployment"
    }

    # Check if switchless storage from networking section
    if ($Config.networking.storage_connectivity_switchless -eq $true) {
        return "switchlessMultiServerDeployment"
    }

    return "switchedMultiServerDeployment"
}

# ---------------------------------------------------------------------------
# Build the parameters object
# ---------------------------------------------------------------------------
Write-Host "Building parameter values..." -ForegroundColor Yellow

$physicalNodes     = Build-PhysicalNodesSettings -ClusterNodes $nodes
$intentList        = Build-IntentList -NetworkIntents $intents
$storageNetworks   = $yaml.networking.storage_networks          # networking.storage_networks[]
$storageNetworkList = Build-StorageNetworkList -StorageNetworks $storageNetworks
$networkingPattern = Get-NetworkingPattern -NetworkIntents $intents
$networkingType    = Get-NetworkingType -Config $yaml -ClusterNodes $nodes

# Storage config from networking section
$storageSwitchless = [bool]$yaml.networking.storage_connectivity_switchless  # networking.storage_connectivity_switchless
$storageAutoIp     = if ($null -ne $yaml.networking.enable_storage_auto_ip) { [bool]$yaml.networking.enable_storage_auto_ip } else { $true }  # networking.enable_storage_auto_ip

# Subscription and resource group from arc_node_resource_ids (parse first entry)
$subscriptionId    = ""
$resourceGroup     = ""
if ($arm.arc_node_resource_ids -and $arm.arc_node_resource_ids.Count -gt 0) {
    $firstArc = $arm.arc_node_resource_ids[0]
    if ($firstArc -match "/subscriptions/([^/]+)/resourceGroups/([^/]+)/") {
        $subscriptionId = $Matches[1]
        $resourceGroup  = $Matches[2]
    }
}

# Tenant ID - from compute section or environment
$tenantId = ""
if ($compute -and $compute.tenant_id) {
    $tenantId = $compute.tenant_id
}

$parameters = [ordered]@{
    deploymentMode = [ordered]@{
        value = if ($arm.mode -eq "deploy") { "Deploy" } else { "Validate" }
    }

    keyVaultName = [ordered]@{
        value = $arm.keyvault_name                                  # cluster_arm_deployment.keyvault_name
    }
    createNewKeyVault = [ordered]@{
        value = $true
    }
    softDeleteRetentionDays = [ordered]@{
        value = 30
    }

    diagnosticStorageAccountName = [ordered]@{
        value = $arm.diagnostic_storage_account_name                # cluster_arm_deployment.diagnostic_storage_account_name
    }
    logsRetentionInDays = [ordered]@{
        value = if ($arm.logs_retention_days) { [int]$arm.logs_retention_days } else { 30 }
    }
    storageAccountType = [ordered]@{
        value = "Standard_LRS"
    }

    clusterName = [ordered]@{
        value = $arm.cluster_name                                   # cluster_arm_deployment.cluster_name
    }
    location = [ordered]@{
        value = if ($compute -and $compute.location) { $compute.location } else { "eastus" }
    }
    tenantId = [ordered]@{
        value = $tenantId
    }

    witnessType = [ordered]@{
        value = if ($arm.witness_type -eq "cloud_witness") { "Cloud" } else { "Cloud" }
    }
    clusterWitnessStorageAccountName = [ordered]@{
        value = $yaml.azure_local.witness_storage_account           # azure_local.witness_storage_account
    }

    localAdminUserName = [ordered]@{
        value = $acct.local_admin_username                          # accounts.local_admin_username
    }
    localAdminPassword = [ordered]@{
        reference = [ordered]@{
            keyVault = [ordered]@{
                id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$($arm.keyvault_name)"
            }
            secretName = "local-admin-password"
        }
    }
    AzureStackLCMAdminUsername = [ordered]@{
        value = $acct.lcm_username                                  # accounts.lcm_username
    }
    AzureStackLCMAdminPassword = [ordered]@{
        reference = [ordered]@{
            keyVault = [ordered]@{
                id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$($arm.keyvault_name)"
            }
            secretName = "lcm-deployment-password"
        }
    }

    hciResourceProviderObjectID = [ordered]@{
        value = $arm.resource_provider_object_id                    # cluster_arm_deployment.resource_provider_object_id
    }

    arcNodeResourceIds = [ordered]@{
        value = [array]$arm.arc_node_resource_ids                   # cluster_arm_deployment.arc_node_resource_ids
    }

    domainFqdn = [ordered]@{
        value = if ($AuthType -eq "AD") { $arm.domain_fqdn } else { "" }   # cluster_arm_deployment.domain_fqdn (AD only)
    }
    namingPrefix = [ordered]@{
        value = $arm.naming_prefix                                  # cluster_arm_deployment.naming_prefix
    }
    adouPath = [ordered]@{
        value = if ($AuthType -eq "AD") { $arm.ou_path } else { "" }       # cluster_arm_deployment.ou_path (AD only)
    }

    securityLevel = [ordered]@{
        value = if ($arm.security_level) { (Get-Culture).TextInfo.ToTitleCase($arm.security_level) } else { "Recommended" }
    }
    driftControlEnforced = [ordered]@{
        value = [bool]($arm.drift_control_enforced -ne $false)      # cluster_arm_deployment.drift_control_enforced
    }
    credentialGuardEnforced = [ordered]@{
        value = [bool]($arm.credential_guard_enforced -ne $false)   # cluster_arm_deployment.credential_guard_enforced
    }
    smbSigningEnforced = [ordered]@{
        value = [bool]($arm.smb_signing_enforced -ne $false)        # cluster_arm_deployment.smb_signing_enforced
    }
    smbClusterEncryption = [ordered]@{
        value = [bool]$arm.smb_cluster_encryption                   # cluster_arm_deployment.smb_cluster_encryption
    }
    bitlockerBootVolume = [ordered]@{
        value = [bool]($arm.bitlocker_boot_volume -ne $false)       # cluster_arm_deployment.bitlocker_boot_volume
    }
    bitlockerDataVolumes = [ordered]@{
        value = [bool]($arm.bitlocker_data_volumes -ne $false)      # cluster_arm_deployment.bitlocker_data_volumes
    }
    wdacEnforced = [ordered]@{
        value = [bool]$arm.wdac_enforced                            # cluster_arm_deployment.wdac_enforced
    }

    streamingDataClient = [ordered]@{
        value = $true
    }
    euLocation = [ordered]@{
        value = [bool]$arm.telemetry_eu_location                    # cluster_arm_deployment.telemetry_eu_location
    }
    episodicDataUpload = [ordered]@{
        value = $true
    }

    configurationMode = [ordered]@{
        value = if ($arm.storage_configuration_mode) { (Get-Culture).TextInfo.ToTitleCase($arm.storage_configuration_mode) } else { "Express" }
    }

    subnetMask = [ordered]@{
        value = $arm.subnet_mask                                    # cluster_arm_deployment.subnet_mask
    }
    defaultGateway = [ordered]@{
        value = $arm.default_gateway                                # cluster_arm_deployment.default_gateway
    }
    startingIPAddress = [ordered]@{
        value = $arm.starting_ip                                    # cluster_arm_deployment.starting_ip
    }
    endingIPAddress = [ordered]@{
        value = $arm.ending_ip                                      # cluster_arm_deployment.ending_ip
    }
    dnsServers = [ordered]@{
        value = [array]$arm.dns_servers                             # cluster_arm_deployment.dns_servers
    }
    useDhcp = [ordered]@{
        value = [bool]$arm.arm_use_dhcp                             # cluster_arm_deployment.arm_use_dhcp
    }

    physicalNodesSettings = [ordered]@{
        value = $physicalNodes
    }

    networkingType = [ordered]@{
        value = $networkingType
    }
    networkingPattern = [ordered]@{
        value = $networkingPattern
    }
    intentList = [ordered]@{
        value = $intentList
    }
    storageNetworkList = [ordered]@{
        value = $storageNetworkList
    }
    storageConnectivitySwitchless = [ordered]@{
        value = $storageSwitchless                                               # networking.storage_connectivity_switchless
    }
    enableStorageAutoIp = [ordered]@{
        value = $storageAutoIp                                                   # networking.enable_storage_auto_ip
    }

    customLocation = [ordered]@{
        value = ""
    }

    sbeVersion = [ordered]@{
        value = if ($arm.sbe_version) { $arm.sbe_version } else { "" }       # cluster_arm_deployment.sbe_version
    }
    sbeFamily = [ordered]@{
        value = if ($arm.sbe_family) { $arm.sbe_family } else { "" }         # cluster_arm_deployment.sbe_family
    }
    sbePublisher = [ordered]@{
        value = if ($arm.sbe_publisher) { $arm.sbe_publisher } else { "" }   # cluster_arm_deployment.sbe_publisher
    }
    sbeManifestSource = [ordered]@{
        value = ""
    }
    sbeManifestCreationDate = [ordered]@{
        value = ""
    }
    partnerProperties = [ordered]@{
        value = @()
    }
    partnerCredentiallist = [ordered]@{
        value = @()
    }
}

# ---------------------------------------------------------------------------
# Assemble the full document
# ---------------------------------------------------------------------------
$document = [ordered]@{
    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters     = $parameters
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
$json = $document | ConvertTo-Json -Depth 10

Write-Host ""
Write-Host "Parameter summary:" -ForegroundColor Yellow
Write-Host "  Cluster:           $($arm.cluster_name)"
Write-Host "  Auth Type:         $AuthType"
Write-Host "  Nodes:             $($nodes.Count) ($($nodes.hostname -join ', '))"
Write-Host "  Networking:        $networkingPattern ($networkingType)"
Write-Host "  Intents:           $($intents.Count)"
Write-Host "  Storage Networks:  $($storageNetworkList.Count)"
Write-Host "  Total Parameters:  $($parameters.Count)"
Write-Host ""

if ($WhatIf -or $WhatIfPreference) {
    Write-Host "[WhatIf] Would write parameters to: $OutputPath" -ForegroundColor Magenta
    Write-Host ""
    Write-Host $json
}
else {
    if ($PSCmdlet.ShouldProcess($OutputPath, "Write ARM parameters file")) {
        $json | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Host "Generated: $OutputPath" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Review the generated file and verify all values"
Write-Host "  2. Ensure Key Vault secrets exist: local-admin-password, lcm-deployment-password"
Write-Host "  3. Run validation:  az deployment group create --mode Validate ..."
Write-Host "  4. After validation passes, change deploymentMode to 'Deploy'"
Write-Host ""
