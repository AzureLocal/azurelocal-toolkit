# Variable map: what variable goes where

**This page is generated. Do not edit it.** It is built from the master registry ([`master-registry.yaml`](../schema/master-registry.yaml), the only master of every variable) and from a scan of the code that reads the variables. Because it is generated, it cannot drift: a test regenerates it and fails when the committed copy differs.

```powershell
./config/variables/scripts/New-VariableMap.ps1           # regenerate (rescans the toolkit; ZTP, Sonar and Trailwright from the committed snapshot)
./config/variables/scripts/New-VariableMap.ps1 -RescanExternal   # also rescan the ZTP, Sonar and Trailwright checkouts, refreshing the snapshot
./config/variables/scripts/New-VariableMap.ps1 -Check    # exit 1 when a committed file is out of date (the tests run this)
```

The machine-readable copy, one row per variable with every column, is [`reports/variable-map.csv`](../reports/variable-map.csv). This page shows the variables of `infrastructure.yml` in full; the variables owned by a tool and the older variables-file sections are summarised (their rows are in the CSV). The diagram of the same flow is [`variable-flow.drawio`](diagrams/variable-flow.drawio) ([PNG](diagrams/variable-flow.png)).

Registry version 5.0.30. Sources of the scan: toolkit (this repository), sonar 39e26b9, trailwright 3c7aa5a, ztp 302b4c2.

## In numbers

| | Variables | read | read as part | validated only | placeholder | deprecated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Keys of infrastructure.yml | 579 | 285 | 121 | 3 | 168 | 2 |
| Owned by a tool (`tools.*`) | 2467 | 2460 | 0 | 0 | 7 | 0 |
| Older variables-file sections | 1480 | 62 | 521 | 0 | 892 | 5 |
| All registry leaves | 4526 | 2807 | 642 | 3 | 1067 | 7 |

A "leaf" is a registry variable with no variable below it (`nodes[].name`, not `nodes`). Status: **read**: a tool names the key in code; **read as part**: no tool names it, but one reads the section or list that holds it; **validated only**: only the validator names it; **placeholder**: documented in the registry, no tool in the scan reads it; **deprecated**: kept for compatibility (`replaced_by` says what replaces it). For a tool-owned variable, read means the registry points at the code that reads or writes it.

## How to read the rows

| Column | Meaning |
| --- | --- |
| Provided by | Who gives the key its value. **operator by hand**: you write it. **Trailwright questionnaire**: a question in Trailwright's catalog writes it. **Dell/Redfish discovery**: `ConvertTo-AzlDiscoveryProposal` writes it into the proposal (you review it; `Get-AzlDiscoveryChange` can apply some on request). **Key Vault reference**: the file holds `keyvault://<vault>/<secret>`, never the secret. **default**: the registry has a default for when the key is left out. Values that no person gives (the ZTP handoff, the OS configuration report) are in the ARM table below, because they feed the ARM parameters, not the file. |
| Purposes | The purpose files that carry the key (registry `used_by`): `ztp`, `os_configuration`, `deployment`, `monitoring` (Sonar), `discovery`, `cicd_infra`. Each is a generated subset of the master file ([templates/purposes](../templates/purposes)). |
| Read by | The tools whose code reads the key by name (`chain` or `literal` in the scan, see Limits). In parentheses, a key that is read only as part of a section: `(part: tool)`. |
| Becomes | What the key turns into downstream: **ARM** template parameter, **OS** configuration step, **Sonar** configuration key, **Gate** pre-cluster verification check id. A leading `~` means the parameter or step is built from the whole parent section or list that holds the key. |

## By phase: Design, Discovery, ZTP, OS configuration, Pre-cluster verification, ARM Validate/Deploy, Sonar

The master `infrastructure.yml` is the one file every phase reads. Each phase reads its own part (its purpose file); nobody edits a purpose file by hand.

| Phase | Tool | Keys of infrastructure.yml it reads or fills | Sections | Purpose file | Hands on |
| --- | --- | ---: | --- | --- | --- |
| Design | Trailwright | 130 | azure, cluster, devops, disconnected, environment, hardware, identity, landing_zone, networking, nodes, operations, provisioning, scenario, sdn, security, site, storage | any (it writes the whole file) | infrastructure.yml (Trailwright exports it) |
| Discovery | Invoke-HardwareDiscovery.ps1 | 18 | hardware, nodes | discovery | a proposal for nodes[] (serial number, ports, MACs), reviewed by you |
| ZTP | azurelocal-ztp | 89 | _metadata, azure, cluster, hardware, key_vaults, network_devices, networking, nodes, provisioning, scenario, site, tags | ztp | ztp-handoff.json (Arc machine IDs, installed build, management address verified), ztp-events.jsonl |
| OS configuration | Set-AzureLocalNodeConfiguration.ps1, Invoke-AzureLocalOsConfiguration.ps1 | 69 | _metadata, azure, cluster, hardware, identity, networking, nodes, os_configuration, provisioning, scenario, storage | os_configuration | the OS configuration report (ports and OS adapter names by MAC, SAN disks), os-configuration-events.jsonl |
| Pre-cluster verification | AzlPreClusterVerification.psm1 | 64 | azure, cluster, hardware, identity, key_vaults, networking, nodes, provisioning, scenario, storage | deployment | the verification report (verdict and check results), precluster-verification-events.jsonl |
| ARM Validate/Deploy | Invoke-AzureLocalArmDeployment.ps1 (New-AzlArmParameterSet) | 74 | _metadata, azure, cluster, hardware, identity, key_vaults, networking, nodes, scenario, security, storage | deployment | deploymentParameters.json (the ARM parameters), arm-deployment-events.jsonl, the deployment on Azure |
| Sonar | azurelocal-sonar | 14 | _metadata, azure, cluster, identity, nodes, provisioning, scenario | monitoring | a live view; reads the feeds above |
| Outside the flow | cicd-infra, validator, helpers, legacy scripts | 140 | _metadata, azure, cluster, devops, hardware, identity, key_vaults, landing_zone, networking, nodes, operations, scenario, security, site, tags | cicd_infra | CI/CD runners, the validator, shared helpers and the older numbered deploy scripts |

### Which section is read in which phase (number of keys)

| Section | Design | Discovery | ZTP | OS configuration | Pre-cluster verification | ARM Validate/Deploy | Sonar | Outside the flow |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `site` | 5 |  | 5 |  |  |  |  | 4 |
| `environment` | 4 |  |  |  |  |  |  |  |
| `tags` |  |  | 1 |  |  |  |  | 1 |
| `identity` | 11 |  |  | 13 | 13 | 9 | 4 | 13 |
| `networking` | 22 |  | 7 | 5 | 24 | 16 |  | 18 |
| `security` | 1 |  |  |  |  | 11 |  | 2 |
| `operations` | 13 |  |  |  |  |  |  | 1 |
| `devops` | 4 |  |  |  |  |  |  | 41 |
| `scenario` | 9 |  | 1 | 6 | 5 | 6 | 2 | 2 |
| `azure` | 8 |  | 5 | 4 | 5 | 6 | 3 | 7 |
| `key_vaults` |  |  | 1 |  | 3 | 3 |  | 3 |
| `cluster` | 9 |  | 1 | 1 | 1 | 11 | 1 | 4 |
| `deployment` |  |  |  |  |  |  |  |  |
| `nodes` | 10 | 16 | 27 | 15 | 5 | 4 | 1 | 18 |
| `hardware` | 11 | 2 | 6 | 4 | 4 | 3 |  | 13 |
| `storage` | 4 |  |  | 9 | 3 | 4 |  |  |
| `sdn` | 1 |  |  |  |  |  |  |  |
| `provisioning` | 9 |  | 31 | 1 | 1 |  | 2 |  |
| `os_configuration` |  |  |  | 10 |  |  |  |  |
| `disconnected` | 8 |  |  |  |  |  |  |  |
| `network_devices` |  |  | 3 |  |  |  |  |  |
| `landing_zone` | 1 |  |  |  |  |  |  | 11 |
| `extensions` |  |  |  |  |  |  |  |  |
| `_metadata` |  |  | 1 | 1 |  | 1 | 1 | 2 |

### Keys that three or more phases read (52)

These are the keys to get right first: a wrong value reaches every phase that reads it.

`identity.active_directory.domain_fqdn`, `identity.active_directory.netbios_name`, `identity.active_directory.ou_path`, `identity.active_directory.lcm_user.username`, `identity.active_directory.lcm_user.password`, `identity.active_directory.domain_controllers`, `identity.local_admin.username`, `identity.local_admin.password`, `identity.local_identity.dns_server_config`, `identity.local_identity.dns_zone`, `identity.local_identity.dns_forwarders`, `networking.management.subnet`, `networking.management.gateway`, `networking.management.vlan_id`, `networking.management.dns_servers`, `networking.management.use_dhcp`, `networking.management.infrastructure_pool.start`, `networking.management.infrastructure_pool.end`, `networking.ntp_servers`, `networking.outbound.arc_gateway.name`, `scenario.identity`, `scenario.storage_architecture`, `scenario.connectivity`, `scenario.cloud`, `scenario.outbound_path`, `scenario.os_install`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `azure.hci_resource_provider_object_id`, `key_vaults[].name`, `cluster.name`, `nodes[].name`, `nodes[].management.ip_address`, `nodes[].management.mac_address`, `nodes[].network_adapters[].name`, `nodes[].network_adapters[].roles`, `nodes[].network_adapters[].ip_address`, `nodes[].bmc.ip_address`, `nodes[].maintenance_address`, `hardware.vendor`, `hardware.model`, `hardware.bmc.username`, `hardware.bmc.password`, `hardware.sbe.bundle_path`, `storage.san.type`, `storage.san.infra_volume_lun_id`, `storage.san.performance_history_lun_id`, `provisioning.os_version`, `provisioning.simplified.site_name`, `_metadata.schema_version`

## By tool: the variables it reads and writes

Reads are keys of `infrastructure.yml` the code names (from the scan). Writes are what the tool puts into the file or into a handoff. "Owns" is the number of variables the registry lists for the tool itself (`tools.<tool>.*`: parameters, settings, events, secrets).

| Tool | Phase | Reads (keys) | Writes or fills (keys) | Owns (tool variables) |
| --- | --- | ---: | ---: | ---: |
| trailwright | Design | 0 | 130 | 0 |
| discovery | Discovery | 7 | 13 | 179 |
| ztp | ZTP | 89 | 0 | 1135 |
| os-configuration | OS configuration | 69 | 0 | 274 |
| pre-cluster-verification | Pre-cluster verification | 64 | 0 | 0 |
| arm-deployment | ARM Validate/Deploy | 74 | 0 | 266 |
| sonar | Sonar | 14 | 0 | 266 |
| cicd-infra | Outside the flow | 53 | 0 | 347 |
| infrastructure-helpers | Outside the flow | 39 | 0 | 0 |
| validator | Outside the flow | 108 | 0 | 0 |
| toolkit-legacy-scripts | Outside the flow | 57 | 0 | 0 |

### trailwright

**Writes or fills (130):**
`site.code`, `site.location`, `site.name`, `site.customer`, `site.time_zone`, `environment.name`, `environment.type`, `environment.owner`, `environment.description`, `identity.active_directory.domain_fqdn`, `identity.active_directory.netbios_name`, `identity.active_directory.ou_path`, `identity.active_directory.lcm_user.username`, `identity.active_directory.lcm_user.password`, `identity.active_directory.domain_controllers`, `identity.local_admin.username`, `identity.local_admin.password`, `identity.local_identity.dns_server_config`, `identity.local_identity.dns_zone`, `identity.local_identity.dns_forwarders`, `networking.management.subnet`, `networking.management.gateway`, `networking.management.vlan_id`, `networking.management.dns_servers`, `networking.management.ip_assignment`, `networking.management.use_dhcp`, `networking.management.infrastructure_pool.start`, `networking.management.infrastructure_pool.end`, `networking.oob.subnet`, `networking.oob.gateway`, `networking.ntp_servers`, `networking.storage.auto_ip`, `networking.storage.switchless_links`, `networking.storage.tor_switches`, `networking.storage.layout`, `networking.outbound.proxy.url`, `networking.outbound.proxy.bypass`, `networking.outbound.arc_gateway.name`, `networking.outbound.private_path.transport`, `networking.outbound.private_path.virtual_network`, `networking.outbound.private_path.firewall_private_ip`, `networking.outbound.private_path.firewall_port`, `security.level`, `operations.monitoring.enabled`, `operations.monitoring.log_analytics_workspace`, `operations.monitoring.workspace_resource_group`, `operations.update_method`, `operations.backup.enabled`, `operations.backup.approach`, `operations.backup.solution`, `operations.disaster_recovery.method`, `operations.disaster_recovery.recovery_vault`, `operations.disaster_recovery.target_rto_minutes`, `operations.disaster_recovery.target_rpo_minutes`, `operations.notifications.emails`, `operations.licensing.azure_hybrid_benefit`, `devops.platform`, `devops.organization`, `devops.runner.name`, `devops.runner.type`, `scenario.identity`, `scenario.storage_architecture`, `scenario.storage_connectivity`, `scenario.topology`, `scenario.connectivity`, `scenario.cloud`, `scenario.outbound_path`, `scenario.os_install`, `scenario.deploy_method`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `azure.hci_resource_provider_object_id`, `azure.custom_location`, `azure.automation_identity.type`, `azure.automation_identity.name`, `cluster.name`, `cluster.naming_prefix`, `cluster.deployment_mode`, `cluster.witness.type`, `cluster.witness.storage_account`, `cluster.witness.path`, `cluster.key_vault.name`, `cluster.key_vault.create_new`, `cluster.diagnostics.storage_account`, `nodes[].name`, `nodes[].management.ip_address`, `nodes[].management.mac_address`, `nodes[].serial_number`, `nodes[].bmc.ip_address`, `nodes[].rack`, `nodes[].rack_position`, `nodes[].zone`, `nodes[].storage_ips`, `nodes[].arc_machine_name`, `hardware.vendor`, `hardware.model`, `hardware.cpu_cores`, `hardware.memory_gib`, `hardware.gpu.enabled`, `hardware.gpu.model`, `hardware.bmc.username`, `hardware.bmc.password`, `hardware.sbe.version`, `hardware.sbe.bundle_path`, `hardware.sbe.allow_unvalidated`, `storage.configuration_mode`, `storage.san.type`, `storage.san.infra_volume_lun_id`, `storage.san.performance_history_lun_id`, `sdn.enabled`, `provisioning.os_version`, `provisioning.iso.image_source`, `provisioning.simplified.site_name`, `provisioning.simplified.maintenance_iso`, `provisioning.simplified.admin.username`, `provisioning.simplified.admin.password`, `provisioning.simplified.media_share.name`, `provisioning.simplified.media_share.host`, `provisioning.simplified.media_share.host_adapter`, `disconnected.role`, `disconnected.domain_suffix`, `disconnected.ingress.ip_address`, `disconnected.management.ip_address`, `disconnected.dns_server`, `disconnected.identity.authority`, `disconnected.identity.ldap_server`, `disconnected.internal_ca`, `landing_zone.log_analytics.name`

### discovery

**Writes or fills (13):**
`nodes[].name`, `nodes[].management.mac_address`, `nodes[].network_adapters[].name`, `nodes[].network_adapters[].mac_address`, `nodes[].network_adapters[].slot`, `nodes[].network_adapters[].port_index`, `nodes[].network_adapters[].vendor`, `nodes[].network_adapters[].model`, `nodes[].network_adapters[].speed_gbps`, `nodes[].network_adapters[].rdma`, `nodes[].network_adapters[].roles`, `nodes[].network_adapters[].ip_assignment`, `nodes[].serial_number`

**Reads (7):**
`nodes[].name`, `nodes[].management.mac_address`, `nodes[].bmc.ip_address`, `nodes[].bmc.username`, `nodes[].bmc.password`, `hardware.bmc.username`, `hardware.bmc.password`

Where in the code (file, function, keys read by name; 4 places):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/common/redfish/AzlRedfishCore.psm1` | `Resolve-AzlBmcCredential` | 4 |
| `scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Invoke-HardwareDiscovery.ps1` | `(script)` | 4 |
| `scripts/common/idrac-management/Enable-IdracVnc.ps1` | `(script)` | 2 |
| `scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Invoke-HardwareDiscovery.ps1` | `Get-ExistingManagementMac` | 1 |

### ztp

**Reads (89):**
`site.code`, `site.location`, `site.name`, `site.owner`, `site.time_zone`, `tags.*`, `networking.management.subnet`, `networking.management.gateway`, `networking.management.vlan_id`, `networking.management.dns_servers`, `networking.management.ip_assignment`, `networking.management.provisioning_network`, `networking.management.static_method`, `scenario.os_install`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `azure.hci_resource_provider_object_id`, `key_vaults[].name`, `cluster.name`, `nodes[].name`, `nodes[].management.ip_address`, `nodes[].management.mac_address`, `nodes[].management.adapter_name`, `nodes[].network_adapters[].name`, `nodes[].network_adapters[].mac_address`, `nodes[].network_adapters[].slot`, `nodes[].network_adapters[].model`, `nodes[].network_adapters[].roles`, `nodes[].network_adapters[].ip_assignment`, `nodes[].network_adapters[].ip_address`, `nodes[].network_adapters[].vlan_id`, `nodes[].network_adapters[].vlan_mode`, `nodes[].serial_number`, `nodes[].bmc.ip_address`, `nodes[].bmc.username`, `nodes[].bmc.password`, `nodes[].rack_position`, `nodes[].arc_machine_name`, `nodes[].arc_resource_name`, `nodes[].maintenance_address`, `nodes[].san.hbas[].slot`, `nodes[].san.hbas[].type`, `nodes[].san.hbas[].bios_attribute`, `nodes[].san.hbas[].bios_disabled_value`, `nodes[].san.hbas[].bios_enabled_value`, `nodes[].san.hbas[].model`, `hardware.vendor`, `hardware.model`, `hardware.bmc.username`, `hardware.bmc.password`, `hardware.bmc.rfs_write_attribute`, `hardware.bmc.verify_certificate`, `provisioning.os_version`, `provisioning.simplified.site_name`, `provisioning.simplified.subscription_id`, `provisioning.simplified.resource_group`, `provisioning.simplified.maintenance_iso`, `provisioning.simplified.admin.username`, `provisioning.simplified.admin.password`, `provisioning.simplified.maintenance_password`, `provisioning.simplified.media_share.name`, `provisioning.simplified.media_share.host`, `provisioning.simplified.media_share.host_adapter`, `provisioning.simplified.media_share.account_name`, `provisioning.simplified.media_share.keep`, `provisioning.simplified.media_path`, `provisioning.simplified.evidence_path`, `provisioning.simplified.isolate_san_adapters`, `provisioning.simplified.enable_embedded_nics`, `provisioning.simplified.create_resource_group`, `provisioning.simplified.configuration_name`, `provisioning.simplified.managed_resource_group_name`, `provisioning.simplified.apply_site_settings`, `provisioning.simplified.use_key_vault_configuration`, `provisioning.simplified.assign_provisioning_roles`, `provisioning.simplified.assign_hci_rp_role`, `provisioning.simplified.network_kind`, `provisioning.simplified.site_mode`, `provisioning.simplified.deployment_name`, `provisioning.simplified.skip_azure_check`, `provisioning.simplified.include_preview`, `provisioning.simplified.max_train`, `provisioning.simplified.retry_provision_os`, `network_devices[].type`, `network_devices[].role`, `network_devices[].model`, `_metadata.schema_version`

Where in the code (file, function, keys read by name; 22 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `ConvertFrom-ZtpInfrastructureV5` | 67 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `ConvertTo-ZtpSchema5Message` | 20 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Get-ZtpV5ManagementPort` | 12 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Test-ZtpInfrastructureV5` | 10 |
| `scripts/common/utilities/tools/Generate-ClusterConfigMD.ps1` | `(script)` | 9 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Get-ZtpDerivedBios` | 8 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Get-ZtpEnvironmentPort` | 7 |
| `scripts/common/discovery/Inventory-OnPrem.ps1` | `Start-OnPremDiscovery` | 2 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Get-ZtpManagementDhcp` | 2 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Get-ZtpRfsWriteAttribute` | 2 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Test-ZtpEnvironment` | 2 |
| `scripts/simplified-provisioning/ZtpEnvironment.Common.ps1` | `Test-ZtpProvisioningDhcpPort` | 2 |

### os-configuration

**Reads (69):**
`identity.active_directory.domain_fqdn`, `identity.active_directory.netbios_name`, `identity.active_directory.ou_path`, `identity.active_directory.lcm_user.username`, `identity.active_directory.domain_join_account.username`, `identity.active_directory.domain_join_account.password`, `identity.active_directory.local_admin_members`, `identity.active_directory.join_options.allow_ou_move`, `identity.active_directory.domain_controllers`, `identity.active_directory.security_groups[].name`, `identity.active_directory.security_groups[].purpose`, `identity.local_admin.username`, `identity.local_admin.password`, `networking.management.subnet`, `networking.oob.subnet`, `networking.ntp_servers`, `networking.outbound.arc_gateway.name`, `networking.outbound.arc_gateway.resource_group`, `scenario.identity`, `scenario.storage_architecture`, `scenario.cloud`, `scenario.outbound_path`, `scenario.os_install`, `scenario.environment_class`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `cluster.name`, `nodes[].name`, `nodes[].management.ip_address`, `nodes[].network_adapters[].name`, `nodes[].network_adapters[].mac_address`, `nodes[].network_adapters[].pci_location.bus`, `nodes[].network_adapters[].pci_location.device`, `nodes[].network_adapters[].pci_location.function`, `nodes[].network_adapters[].os_name_override`, `nodes[].network_adapters[].roles`, `nodes[].network_adapters[].ip_assignment`, `nodes[].network_adapters[].ip_address`, `nodes[].network_adapters[].prefix_length`, `nodes[].maintenance_address`, `nodes[].san.hbas[].ports[].wwpn`, `nodes[].san.initiator_iqn`, `hardware.vendor`, `hardware.sbe.bundle_path`, `hardware.sbe.delivery`, `hardware.sbe.node_pull_url`, `storage.san.type`, `storage.san.array.vendor`, `storage.san.array.model`, `storage.san.iscsi.targets[].iqn`, `storage.san.iscsi.targets[].portals`, `storage.san.iscsi.targets[].fabric`, `storage.san.iscsi.chap.enabled`, `storage.san.infra_volume_lun_id`, `storage.san.performance_history_lun_id`, `provisioning.os_version`, `os_configuration.clear_storage`, `os_configuration.network.confirm_minutes`, `os_configuration.network.stable_seconds`, `os_configuration.remoting.bootstrap_transport`, `os_configuration.remoting.allowed_source_cidrs`, `os_configuration.remoting.allow_any_source`, `os_configuration.remoting.trusted_hosts`, `os_configuration.remoting.use_https`, `os_configuration.remoting.isolation_confirmed`, `os_configuration.remoting.certificate`, `_metadata.schema_version`

Where in the code (file, function, keys read by name; 34 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/common/node-configuration/AzlNodeConfiguration.psm1` | `Get-AzlNodeSpec` | 32 |
| `scripts/common/node-configuration/AzlDomainJoin.psm1` | `Get-AzlDomainJoinSpec` | 13 |
| `scripts/common/remoting/AzlRemotingProfile.psm1` | `Resolve-AzlRemotingProfile` | 9 |
| `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Set-AzureLocalNodeConfiguration.ps1` | `(script)` | 9 |
| `scripts/common/node-configuration/AzlOsConfigurationRun.psm1` | `Invoke-AzlArcRegistration` | 8 |
| `scripts/common/node-configuration/AzlOsConfigurationRun.psm1` | `Invoke-AzlOsConfiguration` | 7 |
| `scripts/common/remoting/AzlRemotingProfile.psm1` | `Get-AzlRemotingNodeAddress` | 4 |
| `scripts/common/node-configuration/AzlOsConfigurationRun.psm1` | `Get-AzlNodeAddressCandidate` | 3 |
| `scripts/common/node-configuration/AzlOsConfigurationRun.psm1` | `Get-AzlNodeEvidence` | 3 |
| `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp/powershell/Invoke-ConfigureNTP-Orchestrated.ps1` | `Get-ClusterConfig` | 3 |
| `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/task-12-complete-combined-script-all-steps/powershell/Invoke-Phase03OsConfiguration-Orchestrated.ps1` | `Get-ClusterConfig` | 3 |
| `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/task-13-phase03-verification/powershell/Invoke-Phase03Verification-Orchestrated.ps1` | `Get-Config` | 3 |

### pre-cluster-verification

**Reads (64):**
`identity.active_directory.domain_fqdn`, `identity.active_directory.netbios_name`, `identity.active_directory.ou_path`, `identity.active_directory.lcm_user.username`, `identity.active_directory.lcm_user.password`, `identity.active_directory.domain_controllers`, `identity.active_directory.use_gmsa`, `identity.active_directory.dns_secure_dynamic_updates`, `identity.local_admin.username`, `identity.local_admin.password`, `identity.local_identity.dns_server_config`, `identity.local_identity.dns_zone`, `identity.local_identity.dns_forwarders`, `networking.management.subnet`, `networking.management.gateway`, `networking.management.vlan_id`, `networking.management.dns_servers`, `networking.management.use_dhcp`, `networking.management.infrastructure_pool.start`, `networking.management.infrastructure_pool.end`, `networking.ntp_servers`, `networking.intents[].name`, `networking.intents[].traffic`, `networking.intents[].adapters`, `networking.intents[].overrides.adapter.jumbo_packet`, `networking.intents[].overrides.adapter.network_direct`, `networking.vlans[].name`, `networking.vlans[].id`, `networking.vlans[].subnet`, `networking.vlans[].purpose`, `networking.logical_networks[].name`, `networking.logical_networks[].purpose`, `networking.logical_networks[].vlan_id`, `networking.logical_networks[].address_prefix`, `networking.outbound.proxy.url`, `networking.outbound.arc_gateway.name`, `networking.outbound.arc_gateway.resource_group`, `scenario.identity`, `scenario.storage_architecture`, `scenario.connectivity`, `scenario.cloud`, `scenario.outbound_path`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `azure.hci_resource_provider_object_id`, `key_vaults[].name`, `key_vaults[].subscription_id`, `key_vaults[].resource_group`, `cluster.name`, `nodes[].name`, `nodes[].management.ip_address`, `nodes[].network_adapters[].roles`, `nodes[].network_adapters[].ip_address`, `nodes[].maintenance_address`, `hardware.model`, `hardware.cpu_cores`, `hardware.memory_gib`, `hardware.drives.capacity.count`, `storage.san.type`, `storage.san.array.vendor`, `storage.san.array.model`, `provisioning.os_version`

Where in the code (file, function, keys read by name; 36 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/common/arm-deployment/verification/AzlVerification.Network.psm1` | `Get-AzlVerVlanPlan` | 15 |
| `scripts/common/arm-deployment/verification/AzlVerification.Identity.psm1` | `(script)` | 12 |
| `scripts/common/arm-deployment/AzlPreClusterVerification.psm1` | `New-AzlPclContext` | 9 |
| `scripts/common/arm-deployment/verification/AzlVerification.Network.psm1` | `Get-AzlVerificationCheckDefinition` | 7 |
| `scripts/common/arm-deployment/verification/AzlVerification.Azure.psm1` | `Get-AzlVerifyTarget` | 6 |
| `scripts/common/arm-deployment/verification/AzlVerification.Identity.psm1` | `Get-VfIdLcm` | 6 |
| `scripts/common/arm-deployment/verification/AzlVerification.NodeCommon.psm1` | `Get-AzlVerIntent` | 5 |
| `scripts/common/arm-deployment/verification/AzlVerification.Nodes.psm1` | `Get-AzlVerificationCheckDefinition` | 5 |
| `scripts/common/arm-deployment/verification/AzlVerification.NodeCommon.psm1` | `Get-AzlVerNodeList` | 4 |
| `scripts/common/arm-deployment/verification/AzlVerification.Nodes.psm1` | `Invoke-AzlVerReadinessDefault` | 4 |
| `scripts/common/arm-deployment/verification/AzlVerification.Azure.psm1` | `Test-AzlVerifyKeyVault` | 3 |
| `scripts/common/arm-deployment/verification/AzlVerification.Identity.psm1` | `Get-VfIdProbe` | 3 |

### arm-deployment

**Reads (74):**
`identity.active_directory.domain_fqdn`, `identity.active_directory.ou_path`, `identity.active_directory.lcm_user.username`, `identity.active_directory.lcm_user.password`, `identity.local_admin.username`, `identity.local_admin.password`, `identity.local_identity.dns_server_config`, `identity.local_identity.dns_zone`, `identity.local_identity.dns_forwarders`, `networking.management.subnet`, `networking.management.gateway`, `networking.management.dns_servers`, `networking.management.use_dhcp`, `networking.management.infrastructure_pool.start`, `networking.management.infrastructure_pool.end`, `networking.ntp_servers`, `networking.storage.auto_ip`, `networking.storage.networks[].name`, `networking.storage.networks[].adapter`, `networking.storage.networks[].vlan_id`, `networking.storage.networks[].subnet`, `networking.cluster_networks[].name`, `networking.cluster_networks[].adapter`, `networking.cluster_networks[].vlan_id`, `networking.cluster_networks[].subnet`, `security.level`, `security.drift_control`, `security.credential_guard`, `security.smb_signing`, `security.smb_cluster_encryption`, `security.bitlocker_boot_volume`, `security.bitlocker_data_volumes`, `security.wdac`, `security.telemetry.streaming_data`, `security.telemetry.episodic_data_upload`, `security.telemetry.eu_location`, `scenario.identity`, `scenario.storage_architecture`, `scenario.storage_connectivity`, `scenario.topology`, `scenario.connectivity`, `scenario.cloud`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `azure.hci_resource_provider_object_id`, `azure.custom_location`, `key_vaults[].name`, `key_vaults[].subscription_id`, `key_vaults[].resource_group`, `cluster.name`, `cluster.naming_prefix`, `cluster.deployment_mode`, `cluster.witness.type`, `cluster.witness.storage_account`, `cluster.key_vault.name`, `cluster.key_vault.create_new`, `cluster.key_vault.soft_delete_retention_days`, `cluster.diagnostics.storage_account`, `cluster.diagnostics.logs_retention_days`, `cluster.diagnostics.storage_account_type`, `nodes[].name`, `nodes[].network_adapters[].name`, `nodes[].zone`, `nodes[].storage_ips`, `hardware.vendor`, `hardware.sbe.bundle_path`, `hardware.sbe.source_path`, `storage.configuration_mode`, `storage.san.type`, `storage.san.infra_volume_lun_id`, `storage.san.performance_history_lun_id`, `_metadata.schema_version`

Where in the code (file, function, keys read by name; 19 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/common/arm-deployment/AzlArmDeployment.psm1` | `New-AzlArmParameterSet` | 61 |
| `scripts/common/arm-deployment/AzlArmDeployment.psm1` | `Select-AzlArmTemplate` | 6 |
| `scripts/common/arm-deployment/AzlArmDeploymentRun.psm1` | `(script)` | 6 |
| `scripts/common/arm-deployment/AzlArmDeploymentRun.psm1` | `Invoke-AzlArmDeploymentRun` | 6 |
| `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalClusterDeployment.ps1` | `(script)` | 6 |
| `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion/powershell/Invoke-VerifyADDomainStatus-Orchestrated.ps1` | `(script)` | 6 |
| `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-01-initiate-deployment-via-arm-template/powershell/Invoke-VerifyADPrerequisites-Orchestrated.ps1` | `(script)` | 5 |
| `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion/powershell/Test-ADDomainStatus.ps1` | `(script)` | 4 |
| `scripts/common/arm-deployment/AzlArmDeployment.psm1` | `ConvertTo-AzlArmParameterFile` | 3 |
| `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/New-AzureLocalArmParameters.ps1` | `(script)` | 3 |
| `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion/powershell/Invoke-VerifyClusterHealth-Orchestrated.ps1` | `(script)` | 3 |
| `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-02-verify-deployment-completion/powershell/Invoke-VerifyClusterHealth-Orchestrated.ps1` | `(script)` | 3 |

### sonar

**Reads (14):**
`identity.active_directory.netbios_name`, `identity.active_directory.domain_join_account.username`, `identity.active_directory.domain_join_account.password`, `identity.local_admin.username`, `scenario.identity`, `scenario.os_install`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `cluster.name`, `nodes[].name`, `provisioning.simplified.site_name`, `provisioning.simplified.evidence_path`, `_metadata.schema_version`

Where in the code (file, function, keys read by name; 15 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `src/AzlSonar/Private/Infrastructure.ps1` | `ConvertFrom-AzlSonarInfrastructureTree` | 13 |
| `src/AzlSonar/Private/Details.ps1` | `Get-AzlSonarConfigKeyName` | 8 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `ConvertTo-AzlSonarExtensionNode` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `ConvertTo-AzlSonarOemNode` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `ConvertTo-AzlSonarSimplifiedNode` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `Get-AzlSonarArcMachineStatus` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `Get-AzlSonarDeploymentState` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `Get-AzlSonarEdgeMachine` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `Get-AzlSonarFailedStepText` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `Get-AzlSonarInitialState` | 1 |
| `src/AzlSonar/Private/AzurePoller.ps1` | `Resolve-AzlSonarArcTarget` | 1 |
| `src/AzlSonar/Private/Config.ps1` | `ConvertTo-AzlSonarPublicConfig` | 1 |

### cicd-infra

**Reads (53):**
`devops.platform`, `devops.url`, `devops.organization`, `devops.project`, `devops.api_token`, `devops.subscription`, `devops.resource_group`, `devops.create_resource_group`, `devops.repository.name`, `devops.repository.template`, `devops.repository.visibility`, `devops.repository.default_branch`, `devops.settings.required_approvals`, `devops.settings.reviewers`, `devops.settings.squash_only`, `devops.settings.secret_scanning`, `devops.settings.resolve_conversations`, `devops.settings.required_status_checks`, `devops.environments[].name`, `devops.environments[].approval_required`, `devops.environments[].approvers`, `devops.environments[].wait_minutes`, `devops.environments[].deployment_branch`, `devops.authentication.method`, `devops.authentication.client_secret`, `devops.authentication.roles`, `devops.authentication.grant_graph_role_management`, `devops.authentication.register_encryption_at_host`, `devops.runners[].name`, `devops.runners[].os_type`, `devops.runners[].purpose`, `devops.runners[].count`, `devops.runners[].compute_type`, `devops.runners[].size`, `devops.runners[].labels`, `devops.runners[].registration_secret`, `devops.runners[].pool`, `devops.runners[].private_ips`, `devops.runners[].subnet.name`, `devops.runners[].subnet.prefix`, `devops.runners[].data_disk_gb`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `azure.automation_identity.name`, `azure.automation_identity.client_id`, `key_vaults[].name`, `key_vaults[].subscription_id`, `key_vaults[].resource_group`, `landing_zone.subscriptions[].name`, `landing_zone.subscriptions[].id`, `landing_zone.subscriptions[].role`

Where in the code (file, function, keys read by name; 2 places):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/common/cicd-infra/AzlCicdInfra.psm1` | `ConvertTo-AzlCicdSetting` | 53 |
| `scripts/common/cicd-infra/AzlCicdInfra.psm1` | `Resolve-AzlCicdInput` | 1 |

### infrastructure-helpers

**Reads (39):**
`networking.management.subnet`, `networking.management.gateway`, `networking.management.vlan_id`, `networking.management.dns_servers`, `networking.management.ip_assignment`, `networking.management.site_ip_range.start`, `networking.management.site_ip_range.end`, `networking.management.provisioning_network`, `networking.management.static_method`, `networking.outbound.arc_gateway.name`, `networking.outbound.arc_gateway.resource_group`, `scenario.outbound_path`, `azure.subscription_id`, `azure.resource_group`, `cluster.witness.type`, `cluster.witness.storage_account`, `cluster.witness.path`, `nodes[].name`, `nodes[].management.ip_address`, `nodes[].management.mac_address`, `nodes[].management.adapter_name`, `nodes[].network_adapters[].name`, `nodes[].network_adapters[].mac_address`, `nodes[].network_adapters[].os_name_override`, `nodes[].network_adapters[].roles`, `nodes[].network_adapters[].ip_assignment`, `nodes[].network_adapters[].ip_address`, `nodes[].network_adapters[].prefix_length`, `nodes[].network_adapters[].gateway`, `nodes[].network_adapters[].dns_servers`, `nodes[].network_adapters[].vlan_mode`, `nodes[].serial_number`, `nodes[].bmc.ip_address`, `nodes[].arc_machine_name`, `nodes[].arc_resource_name`, `landing_zone.storage_accounts[].name`, `landing_zone.storage_accounts[].resource_group`, `landing_zone.storage_accounts[].sku`, `_metadata.scope`

Where in the code (file, function, keys read by name; 15 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlManagementAdapter` | 13 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlClusterWitness` | 8 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlArcGateway` | 5 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlManagementNetwork` | 4 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlNodeNetworkAdapter` | 4 |
| `scripts/common/infrastructure/AzlInfrastructureEdit.psm1` | `Get-AzlDiscoveryChange` | 4 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlArcMachineName` | 3 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlInfrastructureNode` | 3 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlManagementMode` | 2 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlSiteIpRange` | 2 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Test-AzlProvisioningDhcpPort` | 2 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AzlInfrastructureScope` | 1 |

### validator

**Reads (108):**
`identity.active_directory.domain_fqdn`, `identity.active_directory.ou_path`, `identity.active_directory.lcm_user.username`, `identity.active_directory.lcm_user.password`, `identity.active_directory.domain_join_account.username`, `identity.active_directory.domain_join_account.password`, `identity.active_directory.local_admin_members`, `identity.active_directory.domain_controllers`, `identity.local_admin.username`, `networking.management.subnet`, `networking.management.gateway`, `networking.management.vlan_id`, `networking.management.dns_servers`, `networking.management.ip_assignment`, `networking.management.use_dhcp`, `networking.management.provisioning_network`, `networking.management.static_method`, `networking.management.provisioning_dhcp_range.start`, `networking.management.provisioning_dhcp_range.end`, `networking.management.infrastructure_pool.start`, `networking.management.infrastructure_pool.end`, `networking.intents[].name`, `networking.intents[].traffic`, `networking.intents[].adapters`, `networking.storage.auto_ip`, `networking.storage.networks[].name`, `networking.storage.networks[].adapter`, `networking.storage.networks[].vlan_id`, `networking.storage.networks[].subnet`, `networking.logical_networks[].address_prefix`, `devops.platform`, `devops.resource_group`, `devops.environments[].name`, `devops.environments[].approval_required`, `devops.environments[].approvers`, `devops.authentication.method`, `devops.authentication.client_secret`, `devops.runners[].name`, `devops.runners[].os_type`, `devops.runners[].purpose`, `devops.runners[].count`, `devops.runners[].compute_type`, `devops.runners[].labels`, `devops.runners[].registration_secret`, `devops.runners[].subnet.prefix`, `devops.runners[].data_disk_gb`, `devops.runner_network.address_space`, `devops.runner_network.hub_peering.enabled`, `devops.runner_network.hub_peering.hub_network`, `devops.runner_network.hub_peering.hub_vnet_id`, `devops.runner_network.bmc_cidrs`, `scenario.identity`, `scenario.storage_architecture`, `scenario.storage_connectivity`, `scenario.topology`, `scenario.connectivity`, `scenario.cloud`, `scenario.outbound_path`, `scenario.os_install`, `azure.location`, `key_vaults[].name`, `cluster.witness.type`, `deployment.validate_timeout_minutes`, `deployment.deploy_timeout_minutes`, `deployment.poll_seconds`, `deployment.poll_max_seconds`, `deployment.approval`, `deployment.acknowledge_known_issues`, `nodes[].name`, `nodes[].management.ip_address`, `nodes[].management.mac_address`, `nodes[].network_adapters[].name`, `nodes[].network_adapters[].roles`, `nodes[].network_adapters[].ip_assignment`, `nodes[].bmc.password`, `nodes[].zone`, `nodes[].storage_ips`, `nodes[].arc_machine_name`, `nodes[].arc_resource_name`, `hardware.bios_during_provisioning.*`, `hardware.sbe.publisher`, `hardware.sbe.family`, `hardware.sbe.version`, `hardware.sbe.bundle_path`, `hardware.sbe.requirement`, `hardware.sbe.not_applicable_reason`, `hardware.sbe.source_path`, `hardware.sbe.source_username`, `hardware.sbe.source_password`, `hardware.sbe.delivery`, `hardware.sbe.node_pull_url`, `hardware.sbe.allow_unvalidated`, `storage.volumes[].name`, `storage.volumes[].resiliency`, `storage.san.type`, `storage.san.fibre_channel.fabrics[].name`, `storage.san.iscsi.targets[].iqn`, `storage.san.iscsi.targets[].fabric`, `provisioning.os_version`, `provisioning.simplified.isolate_san_adapters`, `provisioning.simplified.ntp.configuration`, `provisioning.simplified.ntp.server`, `provisioning.simplified.ntp.alternate_server`, `provisioning.simplified.timeouts.bootstrap_minutes`, `provisioning.simplified.timeouts.bootstrap_voucher_minutes`, `os_configuration.clear_storage`, `landing_zone.networks[].name`, `_metadata.schema_version`

Where in the code (file, function, keys read by name; 14 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-SemanticFinding` | 35 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-CicdFinding` | 22 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-AdapterFinding` | 11 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-DomainJoinFinding` | 10 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-SbePresenceFinding` | 9 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-SanFinding` | 8 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-ZtpActionFinding` | 7 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-DeploymentOptionFinding` | 6 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-ProvisioningNetworkFinding` | 5 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-SbeDeliveryFinding` | 4 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-OsConfigurationFinding` | 2 |
| `scripts/common/infrastructure/AzlInfrastructure.psm1` | `Get-SiteRangeFinding` | 2 |

### toolkit-legacy-scripts

**Reads (57):**
`site.code`, `site.location`, `site.name`, `site.owner`, `tags.*`, `identity.active_directory.domain_fqdn`, `identity.active_directory.netbios_name`, `identity.active_directory.ou_path`, `identity.active_directory.lcm_user.username`, `identity.active_directory.lcm_user.password`, `identity.active_directory.security_groups[].name`, `identity.active_directory.security_groups[].local_groups`, `identity.local_admin.username`, `identity.local_admin.password`, `identity.entra.groups[].name`, `identity.entra.groups[].purpose`, `identity.entra.groups[].roles`, `identity.entra.groups[].scope`, `networking.logical_networks[].name`, `networking.logical_networks[].enabled`, `networking.logical_networks[].ip_allocation_method`, `networking.logical_networks[].nsg_name`, `networking.logical_networks[].vlan_id`, `networking.logical_networks[].address_prefix`, `networking.logical_networks[].dns_servers`, `security.defender_for_cloud.enabled`, `security.defender_for_cloud.apply_cloud_security_benchmark`, `operations.notifications.emails`, `scenario.environment_class`, `azure.tenant_id`, `azure.location`, `azure.subscription_id`, `azure.resource_group`, `azure.custom_location`, `azure.automation_identity.client_id`, `cluster.name`, `hardware.vendor`, `hardware.model`, `hardware.sbe.publisher`, `hardware.sbe.family`, `hardware.sbe.version`, `hardware.sbe.bundle_path`, `hardware.sbe.requirement`, `hardware.sbe.not_applicable_reason`, `hardware.sbe.source_path`, `hardware.sbe.source_username`, `hardware.sbe.source_password`, `hardware.sbe.package_sha256`, `hardware.sbe.package_size_bytes`, `landing_zone.management_groups[].name`, `landing_zone.management_groups[].display_name`, `landing_zone.subscriptions[].name`, `landing_zone.subscriptions[].id`, `landing_zone.subscriptions[].management_group`, `landing_zone.policy.required_tags`, `landing_zone.policy.management_group`, `_metadata.schema_version`

Where in the code (file, function, keys read by name; 90 places, the first 12):

| File | Function | Keys |
| --- | --- | ---: |
| `scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-08-logical-network-creation/powershell/Invoke-LogicalNetworks-Orchestrated.ps1` | `(script)` | 11 |
| `scripts/common/sbe/AzlSbePackage.psm1` | `Get-AzlSbeSource` | 9 |
| `scripts/lifecycle/updates/monitoring/powershell/Monitor-Update.ps1` | `(script)` | 9 |
| `scripts/deploy/04-cluster-deployment/phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc/powershell/Invoke-ArcRegistration-Orchestrated.ps1` | `Get-Config` | 7 |
| `scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-02-cluster-quorum-configuration/powershell/Invoke-ConfigureClusterQuorum-Orchestrated.ps1` | `(script)` | 7 |
| `scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/task-02-assign-rbac-roles/powershell/Set-EntraGroupRoleAssignments.ps1` | `(script)` | 6 |
| `scripts/deploy/04-cluster-deployment/phase-04-arc-registration/task-01-pre-registration-validation/powershell/Invoke-ArcPrerequisites-Orchestrated.ps1` | `Get-Config` | 6 |
| `scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-VerifyPostDeployment.ps1` | `(script)` | 6 |
| `scripts/common/utilities/tools/Generate-ClusterConfigMD.ps1` | `(script)` | 5 |
| `scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/task-01-create-azure-local-deployment-spn/powershell/New-AutomationManagedIdentity.ps1` | `(script)` | 5 |
| `scripts/deploy/04-cluster-deployment/phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc/azurecli/Register-AzureLocalArc.ps1` | `(script)` | 5 |
| `scripts/deploy/04-cluster-deployment/phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc/powershell/Register-AzureLocalArc-Remote.ps1` | `(script)` | 5 |

## By ARM parameter: the template parameter and the file key it comes from

From `New-AzlArmParameterSet` (`scripts/common/arm-deployment/AzlArmDeployment.psm1`), which builds the parameters of Microsoft's quickstart template. **Direct**: keys the statement reads. **Through a helper**: keys read by a function the statement calls (for example `Get-AzlManagementAdapter`). **Also from**: values that are not in the file (the ZTP handoff, the OS configuration report, the SBE folder, a parameter of the command). **When**: the condition around the statement. Templates: how many of the seven quickstart templates declare the parameter (`config/azure/arm-templates/template-parameters.json`).

| ARM parameter | Direct (file keys) | Through a helper | Also from | When | Templates | Secret |
| --- | --- | --- | --- | --- | ---: | --- |
| `AzureStackLCMAdminPasssword` | not set by the builder (the template default applies) | | | | 1 | securestring |
| `AzureStackLCMAdminPassword` | `identity.active_directory.lcm_user.password` |  |  | `$identity -eq 'active_directory'` | 4 | securestring |
| `AzureStackLCMAdminUsername` | `identity.active_directory.lcm_user.username` |  |  | `$identity -eq 'active_directory'` | 5 |  |
| `adouPath` | `identity.active_directory.ou_path` |  |  | `$identity -eq 'active_directory'` | 5 |  |
| `arcNodeResourceIds` | `azure.resource_group`, `azure.subscription_id`, `nodes[].name` | `nodes[].arc_machine_name`, `nodes[].arc_resource_name` | ZTP handoff, parameter -ArcResourceId |  | 6 |  |
| `bitlockerBootVolume` | `security.bitlocker_boot_volume` |  |  |  | 7 |  |
| `bitlockerDataVolumes` | `security.bitlocker_data_volumes` |  |  |  | 7 |  |
| `chapCredential` | not set by the builder (the template default applies) | | | | 1 | securestring |
| `chapType` | not set by the builder (the template default applies) | | | | 1 |  |
| `chapUsername` | not set by the builder (the template default applies) | | | | 1 |  |
| `clusterName` | `cluster.name` |  |  |  | 7 |  |
| `clusterPattern` |  |  |  | `$template.Name -eq 'create-cluster-rac-enabled'` | 1 |  |
| `clusterWitnessStorageAccountName` | `cluster.witness.storage_account`, `cluster.witness.type` |  |  |  | 7 |  |
| `configurationMode` | `scenario.storage_architecture`, `storage.configuration_mode` |  |  |  | 7 |  |
| `createNewKeyVault` | `cluster.key_vault.create_new` |  |  |  | 7 |  |
| `credentialGuardEnforced` | `security.credential_guard` |  |  |  | 7 |  |
| `customLocation` | `azure.custom_location`, `cluster.name` |  |  |  | 7 |  |
| `defaultGateway` | `networking.management.gateway` |  |  |  | 7 |  |
| `deploymentMode` | `cluster.deployment_mode` |  | parameter -Mode |  | 7 |  |
| `diagnosticStorageAccountName` | `cluster.diagnostics.storage_account` |  |  |  | 7 |  |
| `dnsServerConfig` | `identity.local_identity.dns_server_config` |  |  | `else of: $identity -eq 'active_directory'` | 2 |  |
| `dnsServers` | `networking.management.dns_servers` |  |  |  | 7 |  |
| `dnsZones` | `identity.local_identity.dns_forwarders`, `identity.local_identity.dns_zone` |  |  | `else of: $identity -eq 'active_directory'` | 2 |  |
| `domainFqdn` | `identity.active_directory.domain_fqdn` |  |  | `$identity -eq 'active_directory'` | 5 |  |
| `driftControlEnforced` | `security.drift_control` |  |  |  | 7 |  |
| `enableStorageAutoIp` | `networking.storage.auto_ip` |  |  | `else of: $template.Name -in 'create-cluster-san', 'create-cluster-adless-san'` | 4 |  |
| `endingIPAddress` | `networking.management.infrastructure_pool.end` |  |  |  | 7 |  |
| `episodicDataUpload` | `security.telemetry.episodic_data_upload` |  |  |  | 7 |  |
| `euLocation` | `security.telemetry.eu_location` |  |  |  | 7 |  |
| `hciResourceProviderObjectID` | `azure.hci_resource_provider_object_id` |  | parameter -HciResourceProviderObjectId |  | 7 |  |
| `identityProvider` |  |  |  | `else of: $identity -eq 'active_directory'` | 2 |  |
| `infraPerfLunId` | `storage.san.performance_history_lun_id` |  | OS configuration report, parameter -SanLunIdSource | `$template.Name -in 'create-cluster-san', 'create-cluster-adless-san'` | 3 |  |
| `infraVolLunId` | `storage.san.infra_volume_lun_id` |  | OS configuration report, parameter -SanLunIdSource | `$template.Name -in 'create-cluster-san', 'create-cluster-adless-san'` | 3 |  |
| `intentList` | `networking.intents` | `nodes[].name`, `nodes[].network_adapters[].name` | OS configuration report |  | 7 |  |
| `keyVaultName` | `cluster.key_vault.name` |  |  |  | 7 |  |
| `localAdminPassword` | `identity.local_admin.password` |  |  |  | 7 | securestring |
| `localAdminUserName` | `identity.local_admin.username` |  |  |  | 7 |  |
| `localAvailabilityZones` |  |  |  | `$template.Name -eq 'create-cluster-rac-enabled'` | 1 |  |
| `location` | `azure.location` |  |  |  | 7 |  |
| `logsRetentionInDays` | `cluster.diagnostics.logs_retention_days` |  |  |  | 7 |  |
| `namingPrefix` | `cluster.naming_prefix` |  |  |  | 7 |  |
| `networkingPattern` | `networking.intents` |  |  |  | 6 |  |
| `networkingType` | `scenario.storage_connectivity` |  |  |  | 6 |  |
| `nodes` | not set by the builder (the template default applies) | | | | 1 |  |
| `partnerCredentiallist` |  |  |  | `$sbeConfigured` | 7 |  |
| `partnerProperties` |  |  |  | `$sbeConfigured` | 7 |  |
| `physicalNodesSettings` | `nodes[].name` | `networking.management`, `networking.management.dns_servers`, `networking.management.gateway`, `networking.management.subnet`, `networking.management.vlan_id`, `nodes[].network_adapters[].dns_servers`, ... (14) |  |  | 6 |  |
| `sanNetworkList` | `networking.cluster_networks[].adapter`, `networking.cluster_networks[].name`, `networking.cluster_networks[].subnet`, `networking.cluster_networks[].vlan_id` | `nodes[].name`, `nodes[].network_adapters[].name` | OS configuration report | `$template.Name -in 'create-cluster-san', 'create-cluster-adless-san'` | 3 |  |
| `sbeFamily` | `hardware.sbe.family` |  | SBE folder (Get-AzlSbeBundle) |  | 7 |  |
| `sbeManifestCreationDate` | `hardware.sbe.manifest_creation_date` |  | SBE folder (Get-AzlSbeBundle) |  | 7 |  |
| `sbeManifestSource` | `hardware.sbe.manifest_source` |  | SBE folder (Get-AzlSbeBundle) |  | 7 |  |
| `sbePublisher` | `hardware.sbe.publisher` |  | SBE folder (Get-AzlSbeBundle) |  | 7 |  |
| `sbeVersion` | `hardware.sbe.version` |  | SBE folder (Get-AzlSbeBundle) |  | 7 |  |
| `securityLevel` | `security.level` |  |  |  | 6 |  |
| `smbClusterEncryption` | `security.smb_cluster_encryption` |  |  |  | 7 |  |
| `smbSigningEnforced` | `security.smb_signing` |  |  |  | 7 |  |
| `softDeleteRetentionDays` | `cluster.key_vault.soft_delete_retention_days` |  |  |  | 7 |  |
| `startingIPAddress` | `networking.management.infrastructure_pool.start` |  |  |  | 7 |  |
| `storageAccountType` | `cluster.diagnostics.storage_account_type` |  |  |  | 7 |  |
| `storageConnectivitySwitchless` | `scenario.storage_connectivity` |  |  |  | 7 |  |
| `storageNetworkList` | `networking.storage.auto_ip`, `networking.storage.networks[].adapter`, `networking.storage.networks[].name`, `networking.storage.networks[].subnet`, `networking.storage.networks[].vlan_id`, `nodes[].name`, `nodes[].storage_ips` | `nodes[].network_adapters[].name` | OS configuration report | `else of: $template.Name -in 'create-cluster-san', 'create-cluster-adless-san'` | 4 |  |
| `streamingDataClient` | `security.telemetry.streaming_data` |  |  |  | 7 |  |
| `subnetMask` | `networking.management.subnet` |  |  |  | 7 |  |
| `tenantId` | `azure.tenant_id` |  |  |  | 7 |  |
| `useDhcp` | `networking.management.use_dhcp` |  |  |  | 7 |  |
| `wdacEnforced` | `security.wdac` |  |  |  | 7 |  |
| `witnessType` | `cluster.witness.type` |  |  |  | 7 |  |

## Where do I set X: the 40 most used variables

Ranked by how many different tools read the key, then how many places in the code. All of these are keys of `infrastructure.yml`: you set them in the file (or answer the Trailwright question that writes it), then run the phase that reads them.

| Variable | What it is | Set it by | Read by | Becomes |
| --- | --- | --- | --- | --- |
| `azure.subscription_id` | Subscription ID (GUID) of the Arc machines and the cluster, and of the site and edge machines unless provisioning.simplified.subscription_id names another one. | operator by hand; Trailwright questionnaire | arm-deployment; cicd-infra; infrastructure-helpers; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM arcNodeResourceIds; OS ArcRegistration; Sonar subscriptionId |
| `azure.resource_group` | Resource group of the Arc machines and the cluster: 1 to 90 characters (letters, digits, hyphen, underscore, period, parentheses). | operator by hand; Trailwright questionnaire | arm-deployment; cicd-infra; infrastructure-helpers; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM arcNodeResourceIds; OS ArcRegistration; Sonar resourceGroup |
| `azure.location` | Azure region, for example eastus. | operator by hand; Trailwright questionnaire | arm-deployment; cicd-infra; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM location; OS ArcRegistration; Gate NW-005 |
| `nodes[].name` | Host name: up to 15 characters. | operator by hand; Trailwright questionnaire; Dell/Redfish discovery (proposed) | arm-deployment; discovery; infrastructure-helpers; os-configuration; pre-cluster-verification; sonar; ztp | ARM arcNodeResourceIds; physicalNodesSettings; storageNetworkList; OS Hostname; Network; RemoteManagement; Sonar nodes[].name; Gate ND-001; NW-001; NW-015; SB-005; ST-011 |
| `cluster.name` | Cluster name: a NetBIOS name of up to 15 characters. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM clusterName; customLocation; Sonar clusterName |
| `azure.tenant_id` | Microsoft Entra tenant ID (GUID) of the subscription. | operator by hand; Trailwright questionnaire | arm-deployment; cicd-infra; os-configuration; pre-cluster-verification; toolkit-legacy-scripts; ztp | ARM tenantId; OS ArcRegistration |
| `identity.local_admin.username` | User name of the deployment local administrator on every machine (ARM localAdminUserName). | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts | ARM localAdminUserName; OS LocalAdmin |
| `networking.management.subnet` | CIDR. | operator by hand; Trailwright questionnaire | arm-deployment; infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | ARM subnetMask; OS Dns; Network; NicNames; RemoteManagement; UnusedAdapters; Gate NW-015 |
| `_metadata.schema_version` | The schema version this file follows. | operator by hand | arm-deployment; os-configuration; sonar; toolkit-legacy-scripts; ztp |  |
| `identity.local_admin.password` | At least 14 characters with lowercase, uppercase, a digit and a special character. | operator by hand; Trailwright questionnaire; Key Vault reference (keyvault://) | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM localAdminPassword; OS LocalAdmin |
| `identity.active_directory.lcm_user.username` | Name only, no domain. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM AzureStackLCMAdminUsername; OS DomainJoin |
| `identity.active_directory.domain_fqdn` | ARM domainFqdn. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM domainFqdn; OS DomainJoin |
| `networking.management.dns_servers` | ARM dnsServers. | operator by hand; Trailwright questionnaire | arm-deployment; infrastructure-helpers; pre-cluster-verification; ztp | ARM dnsServers; OS Dns; Network; NicNames; UnusedAdapters; Gate ND-006; NW-015 |
| `nodes[].network_adapters[].roles` | What the port is for: management, compute, storage (the Network ATC traffic types), provisioning (the maintenance environment of simplified provisioning reache... | operator by hand; Dell/Redfish discovery (proposed) | infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | OS Dns; Mpio; Network; NicNames; RemoteManagement; SanVerify; UnusedAdapters; Gate ND-001; NW-001; NW-015; SB-005 |
| `scenario.identity` | active_directory: machines join an AD domain (needs identity.active_directory). local_identity: no AD, secrets in Key Vault (needs identity.local_identity). ht... | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification; sonar | OS DomainJoin; Sonar identityModel; Gate RD-006 |
| `identity.active_directory.netbios_name` | Up to 15 letters, digits and hyphens. | operator by hand; Trailwright questionnaire | os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts | OS DomainJoin |
| `identity.active_directory.ou_path` | Distinguished name of the dedicated OU. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM adouPath; OS DomainJoin |
| `networking.management.gateway` | The one default gateway. | operator by hand; Trailwright questionnaire | arm-deployment; infrastructure-helpers; pre-cluster-verification; ztp | ARM defaultGateway; OS Dns; Network; NicNames; UnusedAdapters; Gate NW-004; NW-015 |
| `nodes[].management.ip_address` | Management address. | operator by hand; Trailwright questionnaire | infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | OS Mpio; Network; NicNames; RemoteManagement; SanVerify; UnusedAdapters; Gate ND-001; NW-001; NW-015; SB-005 |
| `hardware.vendor` | OEM, for example Dell, HPE, Lenovo or DataON. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; toolkit-legacy-scripts; ztp | OS Drivers; Sbe |
| `nodes[].network_adapters[].ip_address` | The host address. | operator by hand | infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | OS Dns; Mpio; Network; NicNames; RemoteManagement; SanVerify; UnusedAdapters; Gate ND-001; NW-001; NW-015; SB-005 |
| `nodes[].network_adapters[].name` | The port's name in this file: the key that networking.intents[].adapters, networking.storage.networks[].adapter and networking.cluster_networks[].adapter use. | operator by hand; Dell/Redfish discovery (proposed) | arm-deployment; infrastructure-helpers; os-configuration; ztp | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement; Gate NW-001 (named) |
| `key_vaults[].name` | Key Vault name, as a keyvault://<name>/<secret> reference uses it: 3 to 24 characters, letters, digits and hyphens. | operator by hand | arm-deployment; cicd-infra; pre-cluster-verification; ztp |  |
| `identity.active_directory.lcm_user.password` | At least 14 characters with lowercase, uppercase, a digit and a special character. | operator by hand; Trailwright questionnaire; Key Vault reference (keyvault://) | arm-deployment; pre-cluster-verification; toolkit-legacy-scripts | ARM AzureStackLCMAdminPassword; OS ~DomainJoin |
| `scenario.storage_architecture` | s2d: Storage Spaces Direct (hyperconverged). san: external SAN only (disaggregated; needs storage.san). hybrid: both (S2D plus a SAN). san and hybrid TELL THE... | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification | ARM configurationMode; OS ClearStorage; Mpio; SanVerify; Gate NW-013; ST-004; ST-008 |
| `azure.hci_resource_provider_object_id` | Object ID of the Azure Local resource provider's service principal (application 1412d89f-b8a8-4111-b4fd-e82905cbd85d) in the tenant. | operator by hand; Trailwright questionnaire | arm-deployment; pre-cluster-verification; ztp | ARM hciResourceProviderObjectID |
| `hardware.sbe.bundle_path` | Folder on the management host with the OEM's SBE files as downloaded: one SBE_*.zip, its SBE_*.xml and SBE_Discovery_<oem>.xml. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; toolkit-legacy-scripts |  |
| `nodes[].network_adapters[].ip_assignment` | How the installed OS gets this port's host address before deployment. | operator by hand; Dell/Redfish discovery (proposed) | infrastructure-helpers; os-configuration; ztp | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement |
| `scenario.cloud` | Azure public cloud or Azure Government. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification | OS ArcRegistration; Gate NW-005 |
| `scenario.os_install` | iso: the OS is installed from an ISO (by hand or out-of-band). simplified: simplified machine provisioning from Azure, which azurelocal-ztp automates (needs pr... | operator by hand; Trailwright questionnaire | os-configuration; sonar; ztp | Sonar provisioningRoute |
| `networking.management.vlan_id` | 0 means untagged. | operator by hand; Trailwright questionnaire | infrastructure-helpers; pre-cluster-verification; ztp | OS Dns; Network; NicNames; UnusedAdapters; Gate NW-013; NW-015 |
| `nodes[].management.mac_address` | MAC of the management port. | operator by hand; Trailwright questionnaire; Dell/Redfish discovery (proposed, applied on request) | discovery; infrastructure-helpers; ztp | OS Mpio; Network; NicNames; SanVerify; UnusedAdapters |
| `scenario.outbound_path` | How the machines reach Azure. | operator by hand; Trailwright questionnaire | infrastructure-helpers; os-configuration; pre-cluster-verification | OS ArcRegistration; Gate NW-006 |
| `networking.ntp_servers` | Time sources, as host names or addresses. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification | OS Time; Gate ND-005 |
| `provisioning.os_version` | The solution version the machines run: latest, latest-preview, or a version such as 12.2610.1004.50. | operator by hand; Trailwright questionnaire | os-configuration; pre-cluster-verification; ztp | Gate ND-004; SB-003; SB-005; SB-006 |
| `hardware.model` | Model, for example AX-760. | operator by hand; Trailwright questionnaire | pre-cluster-verification; toolkit-legacy-scripts; ztp | Gate SB-001; SB-002; SB-003; SB-004; SB-005; SB-006 |
| `nodes[].network_adapters[].mac_address` | The port's identity. | operator by hand; Dell/Redfish discovery (proposed) | infrastructure-helpers; os-configuration; ztp | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement; Gate NW-013 (named) |
| `storage.san.type` | Whether the SAN is fibre_channel or iscsi. | operator by hand; Trailwright questionnaire | arm-deployment; os-configuration; pre-cluster-verification | OS Mpio; SanVerify; Gate ST-011 |
| `nodes[].bmc.ip_address` | IPv4 address of the BMC (iDRAC, iLO, XCC). | operator by hand; Trailwright questionnaire | discovery; infrastructure-helpers; ztp |  |
| `nodes[].maintenance_address` | Simplified provisioning: the address the machine's maintenance environment answers on (its Configurator service, TCP 20001), when it is known: a DHCP reservati... | operator by hand | os-configuration; pre-cluster-verification; ztp |  |

## Unread and placeholder variables

Variables the registry documents that no tool in the scan reads by name. Each is either a key a coming phase will read, a key only the validator checks, or a name kept for compatibility. Nothing here is an error; it is the list to look at before you spend time filling a key in that nothing uses yet.

### Placeholder: documented, not read by any tool in the scan (168)

| Variable | Purposes | Provided by | Note |
| --- | --- | --- | --- |
| `site.datacenter` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `site.customer` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `environment.name` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `environment.type` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `environment.owner` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `environment.description` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `identity.active_directory.join_options.rename_after_join` | os_configuration | operator by hand; default | documented in the registry; no tool in the scan reads it |
| `identity.active_directory.security_groups[].members` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `identity.active_directory.service_accounts[].name` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `identity.active_directory.service_accounts[].purpose` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `identity.active_directory.service_accounts[].password` |  | operator by hand; Key Vault reference (keyvault://) | documented in the registry; no tool in the scan reads it |
| `identity.local_admin.username_secret` | deployment | operator by hand; Key Vault reference (keyvault://) | documented in the registry; no tool in the scan reads it |
| `identity.entra.break_glass_accounts` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `networking.oob.gateway` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.oob.vlan_id` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `networking.storage.switchless_links` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.storage.tor_switches` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.storage.layout` | os_configuration | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.outbound.proxy.bypass` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.transport` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.virtual_network` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.workload_subnet` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.firewall_subnet` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.firewall_private_ip` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.firewall_port` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.arc_private_link_scope` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `networking.outbound.private_path.proxy_bypass` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `security.backup_key_vault` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.enabled` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.log_analytics_workspace` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.workspace_resource_group` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.data_collection_rule` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.data_collection_endpoint` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.action_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.health_alerts` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.monitoring.alert_email` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.update_method` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.backup.enabled` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.backup.approach` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.backup.solution` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.backup.recovery_vault` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.backup.resource_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.backup.policy` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.method` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.recovery_vault` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.resource_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.replication_policy` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.recovery_plan` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.network` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.test_network` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.storage_account` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.target_rto_minutes` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.disaster_recovery.target_rpo_minutes` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.notifications.teams_webhook` |  | operator by hand; Key Vault reference (keyvault://) | documented in the registry; no tool in the scan reads it |
| `operations.licensing.azure_hybrid_benefit` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `operations.licensing.windows_server_subscription` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `operations.licensing.azure_verification_for_vms` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.name` | cicd_infra | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `devops.runner.type` | cicd_infra | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `devops.runner.subscription` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.resource_group` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.network` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.subnet` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.private_ip` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.size` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.labels` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `devops.runner.registration_token` | cicd_infra | operator by hand; Key Vault reference (keyvault://) | documented in the registry; no tool in the scan reads it |
| `scenario.deploy_method` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `hardware.gpu.enabled` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `hardware.gpu.model` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `hardware.gpu.count_per_node` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.network_cards[].label` | os_configuration | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.network_cards[].make` | os_configuration | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.network_cards[].model` | os_configuration | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.network_cards[].ports[].name` | os_configuration | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.network_cards[].ports[].speed_gbps` | os_configuration | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.network_cards[].ports[].rdma` | os_configuration | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.network_cards[].ports[].role` | os_configuration | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.drives.capacity.media` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.drives.capacity.size_tb` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.drives.cache.media` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.drives.cache.count` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `hardware.drives.cache.size_tb` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.volumes[].size_gib` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.array.name` | deployment | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.array.management_address` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.fibre_channel.fabrics[].switch` | deployment | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.fibre_channel.fabrics[].zone_set` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.fibre_channel.target_wwpns[].wwpn` | deployment | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.fibre_channel.target_wwpns[].fabric` | deployment | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.iscsi.chap.username` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.iscsi.chap.secret` |  | operator by hand; Key Vault reference (keyvault://) | documented in the registry; no tool in the scan reads it |
| `storage.san.luns[].name` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.luns[].size_gib` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `storage.san.luns[].lun_id` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `sdn.enabled` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `sdn.prefix` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `sdn.dns_records` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `sdn.default_access_policy` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `provisioning.iso.image_source` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `provisioning.iso.image_version` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `os_configuration.remoting.transport` | os_configuration | operator by hand; default | documented in the registry; no tool in the scan reads it |
| `disconnected.role` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `disconnected.base_path` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.domain_suffix` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `disconnected.ingress.ip_address` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `disconnected.ingress.gateway` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.ingress.prefix_length` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.management.ip_address` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `disconnected.management.gateway` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.management.prefix_length` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.dns_server` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `disconnected.time_servers` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.identity.authority` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `disconnected.identity.client_id` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.identity.root_operator_upn` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.identity.ldap_server` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `disconnected.identity.ldaps` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.identity.sync_group_identifier` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.operator_subscription_name` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.resource_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `disconnected.internal_ca` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `network_devices[].hostname` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].vendor` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].serial_number` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].firmware_version` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].management.ip_address` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].management.vlan_id` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].management.protocol` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].credentials.username` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].credentials.password` |  | operator by hand; Key Vault reference (keyvault://) | documented in the registry; no tool in the scan reads it |
| `network_devices[].ha.enabled` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `network_devices[].ha.mode` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.management_groups[].parent` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.resource_groups[].name` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.resource_groups[].subscription` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.resource_groups[].location` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.resource_groups[].purpose` | cicd_infra | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.resource_providers` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.connectivity.bastion.name` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.connectivity.bastion.resource_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.connectivity.bastion.sku` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.connectivity.firewall.name` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.connectivity.firewall.resource_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.connectivity.firewall.sku` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.connectivity.firewall.private_ip` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].name` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].hostname` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].role` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].deploy_target` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].subscription` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].resource_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].network` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].subnet` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].private_ip` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].size` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].os` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].admin_username` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.virtual_machines[].admin_password` |  | operator by hand; Key Vault reference (keyvault://) | documented in the registry; no tool in the scan reads it |
| `landing_zone.log_analytics.name` |  | operator by hand; Trailwright questionnaire | documented in the registry; no tool in the scan reads it |
| `landing_zone.log_analytics.resource_group` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.log_analytics.retention_days` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `landing_zone.storage_accounts[].purpose` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `extensions` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `_metadata.file_version` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `_metadata.last_updated` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `_metadata.generated_by` |  | operator by hand | documented in the registry; no tool in the scan reads it |
| `_metadata.notes` |  | operator by hand | documented in the registry; no tool in the scan reads it |

### Validated only: the validator names it, nothing consumes it (3)

| Variable | Purposes | Provided by | Note |
| --- | --- | --- | --- |
| `storage.volumes[].name` |  | operator by hand | only the validator names it |
| `storage.volumes[].resiliency` |  | operator by hand | only the validator names it |
| `storage.san.fibre_channel.fabrics[].name` | deployment | operator by hand | only the validator names it |

### Read as part: no tool names the key; a tool reads the section or list that holds it (121)

| Variable | Purposes | Provided by | Note |
| --- | --- | --- | --- |
| `networking.management.provisioning_dhcp_range.start` | ztp; os_configuration | operator by hand | read as part by ztp |
| `networking.management.provisioning_dhcp_range.end` | ztp; os_configuration | operator by hand | read as part by ztp |
| `networking.intents[].overrides.qos.cluster_priority` | os_configuration; deployment | operator by hand | read as part by arm-deployment |
| `networking.intents[].overrides.qos.smb_priority` | os_configuration; deployment | operator by hand | read as part by arm-deployment |
| `networking.intents[].overrides.qos.smb_bandwidth_percent` | os_configuration; deployment | operator by hand | read as part by arm-deployment |
| `networking.intents[].overrides.adapter.network_direct_technology` | os_configuration; deployment | operator by hand | read as part by arm-deployment |
| `networking.intents[].overrides.virtual_switch.enable_iov` | os_configuration; deployment | operator by hand | read as part by arm-deployment |
| `networking.intents[].overrides.virtual_switch.load_balancing_algorithm` | os_configuration; deployment | operator by hand | read as part by arm-deployment |
| `networking.cluster_networks[].purpose` | os_configuration | operator by hand | read as part by os-configuration; pre-cluster-verification |
| `networking.logical_networks[].gateway` | deployment | operator by hand | read as part by os-configuration |
| `networking.logical_networks[].ip_pool.start` | deployment | operator by hand | read as part by os-configuration |
| `networking.logical_networks[].ip_pool.end` | deployment | operator by hand | read as part by os-configuration |
| `devops.runner_network.vnet_name` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.address_space` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.dns_servers` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.hub_peering.enabled` | cicd_infra | operator by hand; default | read as part by cicd-infra |
| `devops.runner_network.hub_peering.hub_network` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.hub_peering.hub_vnet_id` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.hub_peering.use_remote_gateways` | cicd_infra | operator by hand; default | read as part by cicd-infra |
| `devops.runner_network.hub_peering.create_hub_side` | cicd_infra | operator by hand; default | read as part by cicd-infra |
| `devops.runner_network.reachable_cidrs` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.reachable_tcp_ports` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.bmc_cidrs` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_network.admin_source_cidrs` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_access.resource_groups` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_access.rbac_administrator` | cicd_infra | operator by hand; default | read as part by cicd-infra |
| `devops.runner_access.rbac_delegable_role_ids` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.runner_access.arc_run_command` | cicd_infra | operator by hand; default | read as part by cicd-infra |
| `devops.runner_access.key_vaults` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.state.subscription_id` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.state.key` | cicd_infra | operator by hand; default | read as part by cicd-infra |
| `devops.state.storage_account` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.state.container` | cicd_infra | operator by hand | read as part by cicd-infra |
| `devops.state.resource_group` | cicd_infra | operator by hand | read as part by cicd-infra |
| `azure.automation_identity.type` | cicd_infra | operator by hand; Trailwright questionnaire | read as part by discovery |
| `azure.automation_identity.subscription_id` | cicd_infra | operator by hand | read as part by discovery |
| `azure.automation_identity.resource_group` | cicd_infra | operator by hand | read as part by discovery |
| `key_vaults[].purpose` | ztp; cicd_infra | operator by hand | read as part by toolkit-legacy-scripts |
| `deployment.validate_timeout_minutes` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.deploy_timeout_minutes` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.poll_seconds` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.poll_max_seconds` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.approval` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.resume` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.require_os_configuration_report` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.skip_preconditions` | deployment | operator by hand | read as part by arm-deployment; ztp |
| `deployment.acknowledge_known_issues` | deployment | operator by hand | read as part by arm-deployment; ztp |
| `deployment.deployment_settings_api_version` | deployment | operator by hand | read as part by arm-deployment; ztp |
| `deployment.solution_version` | deployment | operator by hand | read as part by arm-deployment; ztp |
| `deployment.sbe_catalog_path` | deployment | operator by hand | read as part by arm-deployment; ztp |
| `deployment.pre_cluster_verification_max_age_hours` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.verification_min_memory_gib` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.verification_min_boot_disk_gb` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.verification_min_data_disk_gb` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.verification_min_link_gbps` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.verification_max_clock_skew_seconds` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `deployment.pre_cluster_verification_report_directory` | deployment | operator by hand | read as part by arm-deployment; ztp |
| `deployment.register_resource_providers` | deployment | operator by hand; default | read as part by arm-deployment; ztp |
| `nodes[].network_adapters[].port_index` | os_configuration; discovery | operator by hand; Dell/Redfish discovery (proposed) | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].vendor` | os_configuration; discovery | operator by hand; Dell/Redfish discovery (proposed) | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].speed_gbps` | os_configuration | operator by hand; Dell/Redfish discovery (proposed) | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].rdma` | os_configuration | operator by hand; Dell/Redfish discovery (proposed) | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].allowed_vlans` | deployment | operator by hand | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].switch_port.switch` | os_configuration | operator by hand | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].switch_port.port` | os_configuration | operator by hand | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].switch_port.description` | os_configuration | operator by hand | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].network_adapters[].notes` | os_configuration | operator by hand | read as part by discovery; toolkit-legacy-scripts |
| `nodes[].bmc.type` | ztp; discovery | operator by hand | read as part by toolkit-legacy-scripts |
| `nodes[].rack` |  | operator by hand; Trailwright questionnaire | read as part by toolkit-legacy-scripts |
| `nodes[].bios.*` | ztp; os_configuration | operator by hand | read as part by infrastructure-helpers; toolkit-legacy-scripts; ztp |
| `nodes[].bios_during_provisioning.*` | ztp; os_configuration | operator by hand | read as part by infrastructure-helpers; toolkit-legacy-scripts; ztp |
| `nodes[].san.hbas[].ports[].fabric` | deployment | operator by hand | read as part by pre-cluster-verification; toolkit-legacy-scripts |
| `hardware.bios.*` | ztp | operator by hand | read as part by infrastructure-helpers; ztp |
| `hardware.bios_during_provisioning.*` | ztp | operator by hand | read as part by infrastructure-helpers; ztp |
| `hardware.sbe.manifest_source` | deployment | operator by hand | read as part by ztp |
| `hardware.sbe.manifest_creation_date` | deployment | operator by hand | read as part by ztp |
| `hardware.sbe.allow_unvalidated` | ztp | operator by hand; Trailwright questionnaire | read as part by ztp |
| `provisioning.simplified.ntp.configuration` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.ntp.server` | ztp | operator by hand | read as part by ztp |
| `provisioning.simplified.ntp.alternate_server` | ztp | operator by hand | read as part by ztp |
| `provisioning.simplified.usb_image.size_gb` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.usb_image.name_prefix` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.maintenance_environment.port` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.maintenance_environment.username` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.bootstrap_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.bootstrap_voucher_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.bootstrap_stall_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.voucher_wait_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.device_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.ready_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.network_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.restore_settle_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.bios_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.adapters_minutes` | ztp | operator by hand; default | read as part by ztp |
| `provisioning.simplified.timeouts.poll_interval_seconds` | ztp | operator by hand; default | read as part by ztp |
| `landing_zone.networks[].name` | cicd_infra | operator by hand | read as part by cicd-infra |
| `landing_zone.networks[].subscription` | cicd_infra | operator by hand | read as part by cicd-infra |
| `landing_zone.networks[].resource_group` | cicd_infra | operator by hand | read as part by cicd-infra |
| `landing_zone.networks[].location` | cicd_infra | operator by hand | read as part by cicd-infra |
| `landing_zone.networks[].role` | cicd_infra | operator by hand | read as part by cicd-infra |
| `landing_zone.networks[].address_space` | cicd_infra | operator by hand | read as part by cicd-infra |
| `landing_zone.networks[].dns_servers` | cicd_infra | operator by hand | read as part by cicd-infra |
| `landing_zone.networks[].subnets[].name` | cicd_infra | operator by hand | read as part by cicd-infra; toolkit-legacy-scripts |
| `landing_zone.networks[].subnets[].prefix` | cicd_infra | operator by hand | read as part by cicd-infra; toolkit-legacy-scripts |
| `landing_zone.networks[].subnets[].network_security_group` | cicd_infra | operator by hand | read as part by cicd-infra; toolkit-legacy-scripts |
| `landing_zone.networks[].subnets[].route_table` | cicd_infra | operator by hand | read as part by cicd-infra; toolkit-legacy-scripts |
| `landing_zone.networks[].peer_with` |  | operator by hand | read as part by cicd-infra |
| `landing_zone.connectivity.vpn_gateway.name` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.resource_group` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.network` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.sku` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.bgp_asn` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].connection_name` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].local_gateway_name` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_public_ip` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_address_prefixes` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_bgp_address` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_asn` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].shared_key` |  | operator by hand; Key Vault reference (keyvault://) | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.point_to_site.address_pool` |  | operator by hand | read as part by toolkit-legacy-scripts |
| `landing_zone.connectivity.vpn_gateway.point_to_site.authentication` |  | operator by hand | read as part by toolkit-legacy-scripts |

### Deprecated, with what replaces them (7)

| Variable | Replaced by | Still read by |
| --- | --- | --- |
| `networking.onprem.network_intents[].jumbo_packet_size` | `networking.intents[].overrides.adapter.jumbo_packet` |  |
| `networking.onprem.network_intents[].network_direct_enabled` | `networking.intents[].overrides.adapter.network_direct` |  |
| `networking.onprem.network_intents[].network_direct_technology` | `networking.intents[].overrides.adapter.network_direct_technology` |  |
| `networking.onprem.network_devices.jumbo_frames_mtu` | `networking.intents[].overrides.adapter.jumbo_packet` |  |
| `networking.management.ip_assignment` | (none named) | infrastructure-helpers; ztp |
| `compute.clusters.azure_local.azl_storage_rdma_technology` | `networking.intents[].overrides.adapter.network_direct_technology` |  |
| `nodes[].arc_resource_name` | (none named) | infrastructure-helpers; ztp |

### Tool variables the tool documents and does not read yet (7)

| Variable | Owner | Kind |
| --- | --- | --- |
| `tools.ztp.config_keys.config_oem_vendor_json.displayName` | ztp | config_keys |
| `tools.ztp.config_keys.config_oem_vendor_json.bmc_managerId` | ztp | config_keys |
| `tools.ztp.config_keys.config_oem_vendor_json.bmc_systemId` | ztp | config_keys |
| `tools.ztp.config_keys.config_oem_vendor_json.bmc_virtualMediaSlot` | ztp | config_keys |
| `tools.ztp.config_keys.config_oem_vendor_json.bmc_signalsStatus` | ztp | config_keys |
| `tools.ztp.config_keys.config_oem_vendor_json.bios_status` | ztp | config_keys |
| `tools.ztp.config_keys.config_oem_vendor_json.models_validatedBySimplifiedProvisioning` | ztp | config_keys |

### Older variables-file sections (1480 variables)

These registry sections (`compute`, `identity.accounts`, `azure_platform`, ...) describe the earlier variables file, not `infrastructure.yml`. The numbered deploy scripts under `scripts/deploy` read some of them. They are in the CSV (`kind` = `variables-file`).

| Section | Variables | read | placeholder | deprecated |
| --- | ---: | ---: | ---: | ---: |
| `azure_platform` | 73 | 28 | 45 | 0 |
| `cluster_shared_volumes` | 15 | 11 | 4 | 0 |
| `compute` | 398 | 397 | 0 | 1 |
| `devops` | 8 | 0 | 8 | 0 |
| `environment` | 4 | 0 | 4 | 0 |
| `identity` | 143 | 11 | 132 | 0 |
| `infrastructure_scenarios` | 1 | 0 | 1 | 0 |
| `marketplace_images` | 9 | 7 | 2 | 0 |
| `networking` | 527 | 55 | 468 | 4 |
| `operations` | 126 | 5 | 121 | 0 |
| `security` | 109 | 56 | 53 | 0 |
| `site` | 23 | 2 | 21 | 0 |
| `storage_accounts` | 33 | 0 | 33 | 0 |
| `tags` | 11 | 11 | 0 | 0 |

## The map: every key of infrastructure.yml

Grouped by section, in the order of the file. `req`: yes when the registry marks the key required (the schema has conditional rules on top of this; see [VARIABLES.md](VARIABLES.md)).

### _metadata

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `_metadata.schema_version` | string, required | operator | ztp; os_configuration; deployment; monitoring | arm-deployment; os-configuration; sonar; toolkit-legacy-scripts; ztp |  | read |
| `_metadata.scope` | default `full`, one of `full`, `ztp` | operator; default | ztp | infrastructure-helpers |  | read |
| `_metadata.file_version` | string | operator |  |  |  | placeholder |
| `_metadata.last_updated` | string (date) | operator |  |  |  | placeholder |
| `_metadata.generated_by` | string | operator |  |  |  | placeholder |
| `_metadata.notes` | string | operator |  |  |  | placeholder |

### azure

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `azure.tenant_id` | string (guid), required | operator; Trailwright | ztp; os_configuration; deployment; cicd_infra | arm-deployment; cicd-infra; os-configuration; pre-cluster-verification; toolkit-legacy-scripts; ztp | ARM tenantId; OS ArcRegistration | read |
| `azure.location` | string (azure_region), required | operator; Trailwright | ztp; os_configuration; deployment; cicd_infra; monitoring | arm-deployment; cicd-infra; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM location; OS ArcRegistration; Gate NW-005 | read |
| `azure.subscription_id` | string (guid), required | operator; Trailwright | ztp; os_configuration; deployment; cicd_infra; monitoring | arm-deployment; cicd-infra; infrastructure-helpers; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM arcNodeResourceIds; OS ArcRegistration; Sonar subscriptionId | read |
| `azure.resource_group` | string (resource_group), required | operator; Trailwright | ztp; os_configuration; deployment; cicd_infra; monitoring | arm-deployment; cicd-infra; infrastructure-helpers; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM arcNodeResourceIds; OS ArcRegistration; Sonar resourceGroup | read |
| `azure.hci_resource_provider_object_id` | string (guid) | operator; Trailwright | ztp; deployment | arm-deployment; pre-cluster-verification; ztp | ARM hciResourceProviderObjectID | read |
| `azure.custom_location` | string | operator; Trailwright | deployment | arm-deployment; toolkit-legacy-scripts | ARM customLocation | read |
| `azure.automation_identity.type` | string, required, one of `managed_identity`, `service_principal` | operator; Trailwright | cicd_infra | (part: discovery) |  | read-as-part |
| `azure.automation_identity.name` | string, required | operator; Trailwright | cicd_infra | cicd-infra |  | read |
| `azure.automation_identity.client_id` | string (guid) | operator | cicd_infra | cicd-infra; toolkit-legacy-scripts |  | read |
| `azure.automation_identity.subscription_id` | string (guid) | operator | cicd_infra | (part: discovery) |  | read-as-part |
| `azure.automation_identity.resource_group` | string (resource_group) | operator | cicd_infra | (part: discovery) |  | read-as-part |

### cluster

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `cluster.name` | string (netbios_name), required | operator; Trailwright | os_configuration; deployment; monitoring | arm-deployment; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts; ztp | ARM clusterName; customLocation; Sonar clusterName | read |
| `cluster.naming_prefix` | string | operator; Trailwright | deployment | arm-deployment | ARM namingPrefix | read |
| `cluster.deployment_mode` | string, one of `validate`, `deploy` | operator; Trailwright | deployment | arm-deployment | ARM deploymentMode | read |
| `cluster.witness.type` | string, required, one of `cloud`, `file_share`, `none` | operator; Trailwright | deployment | arm-deployment; infrastructure-helpers | ARM clusterWitnessStorageAccountName; witnessType | read |
| `cluster.witness.storage_account` | string (storage_account_name) | operator; Trailwright | deployment | arm-deployment; infrastructure-helpers | ARM clusterWitnessStorageAccountName | read |
| `cluster.witness.path` | string | operator; Trailwright |  | infrastructure-helpers |  | read |
| `cluster.key_vault.name` | string (key_vault_name), required | operator; Trailwright | deployment | arm-deployment | ARM keyVaultName | read |
| `cluster.key_vault.create_new` | boolean | operator; Trailwright | deployment | arm-deployment | ARM createNewKeyVault | read |
| `cluster.key_vault.soft_delete_retention_days` | integer | operator | deployment | arm-deployment | ARM softDeleteRetentionDays | read |
| `cluster.diagnostics.storage_account` | string (storage_account_name) | operator; Trailwright | deployment | arm-deployment | ARM diagnosticStorageAccountName | read |
| `cluster.diagnostics.logs_retention_days` | integer | operator | deployment | arm-deployment | ARM logsRetentionInDays | read |
| `cluster.diagnostics.storage_account_type` | string | operator | deployment | arm-deployment | ARM storageAccountType | read |

### deployment

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `deployment.validate_timeout_minutes` | integer, default `90` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.deploy_timeout_minutes` | integer, default `360` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.poll_seconds` | integer, default `15` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.poll_max_seconds` | integer, default `120` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.approval` | string, default `stop`, one of `stop`, `prompt`, `none` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.resume` | boolean, default `false` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.require_os_configuration_report` | boolean, default `false` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.skip_preconditions` | array, one of `AzureContext`, `ResourceGroup`, `ResourceProviders`, `Permissions`, `NamesAvailable`, `KeyVaultSecrets`, ... (17) | operator | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.acknowledge_known_issues` | array | operator | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.deployment_settings_api_version` | string | operator | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.solution_version` | string | operator | deployment | (part: arm-deployment; ztp) | Gate SB-006 (named) | read-as-part |
| `deployment.sbe_catalog_path` | string | operator | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.pre_cluster_verification_max_age_hours` | integer, default `4` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.verification_min_memory_gib` | integer, default `32` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.verification_min_boot_disk_gb` | integer, default `200` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.verification_min_data_disk_gb` | integer, default `500` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.verification_min_link_gbps` | integer, default `10` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.verification_max_clock_skew_seconds` | integer, default `300` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.pre_cluster_verification_report_directory` | string | operator | deployment | (part: arm-deployment; ztp) |  | read-as-part |
| `deployment.register_resource_providers` | boolean, default `false` | operator; default | deployment | (part: arm-deployment; ztp) |  | read-as-part |

### devops

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `devops.platform` | string, required, one of `github`, `gitlab`, `azure_devops` | operator; Trailwright | cicd_infra | cicd-infra |  | read |
| `devops.url` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.organization` | string | operator; Trailwright | cicd_infra | cicd-infra |  | read |
| `devops.project` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.api_token` | string (kv_ref) | operator; Key Vault ref | cicd_infra | cicd-infra |  | read |
| `devops.subscription` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.resource_group` | string (resource_group) | operator | cicd_infra | cicd-infra |  | read |
| `devops.create_resource_group` | boolean, default `false` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.repository.name` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.repository.template` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.repository.visibility` | string, default `private`, one of `private`, `internal` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.repository.default_branch` | string, default `main` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.settings.required_approvals` | integer, default `2` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.settings.reviewers` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.settings.squash_only` | boolean, default `true` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.settings.secret_scanning` | boolean, default `true` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.settings.resolve_conversations` | boolean, default `true` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.settings.required_status_checks` | array | operator | cicd_infra | cicd-infra |  | read |
| `devops.environments[].name` | string, required | operator | cicd_infra | cicd-infra |  | read |
| `devops.environments[].approval_required` | boolean, default `false` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.environments[].approvers` | array | operator | cicd_infra | cicd-infra |  | read |
| `devops.environments[].wait_minutes` | integer, default `0` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.environments[].deployment_branch` | string, default `main` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.authentication.method` | string, default `oidc`, one of `oidc`, `client_secret` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.authentication.client_secret` | string (kv_ref) | operator; Key Vault ref | cicd_infra | cicd-infra |  | read |
| `devops.authentication.roles` | array | operator | cicd_infra | cicd-infra |  | read |
| `devops.authentication.grant_graph_role_management` | boolean, default `false` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.authentication.register_encryption_at_host` | boolean, default `true` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.runners[].name` | string, required | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].os_type` | string, required, one of `linux`, `windows` | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].purpose` | string, default `general`, one of `general`, `ztp` | operator; default | deployment; cicd_infra | cicd-infra |  | read |
| `devops.runners[].count` | integer, default `1` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.runners[].compute_type` | string, default `vm`, one of `vm`, `vmss` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.runners[].size` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].labels` | array | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].registration_secret` | string (kv_ref) | operator; Key Vault ref | cicd_infra | cicd-infra |  | read |
| `devops.runners[].pool` | string | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].private_ips` | array | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].subnet.name` | string, required | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].subnet.prefix` | string (cidr), required | operator | cicd_infra | cicd-infra |  | read |
| `devops.runners[].data_disk_gb` | integer, default `0` | operator; default | cicd_infra | cicd-infra |  | read |
| `devops.runner_network.vnet_name` | string | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.address_space` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.dns_servers` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.hub_peering.enabled` | boolean, default `false` | operator; default | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.hub_peering.hub_network` | string | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.hub_peering.hub_vnet_id` | string | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.hub_peering.use_remote_gateways` | boolean, default `true` | operator; default | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.hub_peering.create_hub_side` | boolean, default `true` | operator; default | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.reachable_cidrs` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.reachable_tcp_ports` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.bmc_cidrs` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_network.admin_source_cidrs` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_access.resource_groups` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_access.rbac_administrator` | boolean, default `true` | operator; default | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_access.rbac_delegable_role_ids` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_access.arc_run_command` | boolean, default `true` | operator; default | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner_access.key_vaults` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.runner.name` | string, required | operator; Trailwright | cicd_infra |  |  | placeholder |
| `devops.runner.type` | string, required, one of `vm`, `container_app`, `existing` | operator; Trailwright | cicd_infra |  |  | placeholder |
| `devops.runner.subscription` | string | operator | cicd_infra |  |  | placeholder |
| `devops.runner.resource_group` | string (resource_group) | operator | cicd_infra |  |  | placeholder |
| `devops.runner.network` | string | operator | cicd_infra |  |  | placeholder |
| `devops.runner.subnet` | string | operator | cicd_infra |  |  | placeholder |
| `devops.runner.private_ip` | string (ipv4) | operator | cicd_infra |  |  | placeholder |
| `devops.runner.size` | string | operator | cicd_infra |  |  | placeholder |
| `devops.runner.labels` | array | operator | cicd_infra |  |  | placeholder |
| `devops.runner.registration_token` | string (kv_ref) | operator; Key Vault ref | cicd_infra |  |  | placeholder |
| `devops.state.subscription_id` | string (guid) | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.state.key` | string, default `cicd-infra.tfstate` | operator; default | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.state.storage_account` | string (storage_account_name) | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.state.container` | string | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `devops.state.resource_group` | string (resource_group) | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |

### disconnected

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `disconnected.role` | string, required, one of `management`, `workload` | operator; Trailwright |  |  |  | placeholder |
| `disconnected.base_path` | string | operator |  |  |  | placeholder |
| `disconnected.domain_suffix` | string | operator; Trailwright |  |  |  | placeholder |
| `disconnected.ingress.ip_address` | string (ipv4) | operator; Trailwright |  |  |  | placeholder |
| `disconnected.ingress.gateway` | string (ipv4) | operator |  |  |  | placeholder |
| `disconnected.ingress.prefix_length` | integer | operator |  |  |  | placeholder |
| `disconnected.management.ip_address` | string (ipv4) | operator; Trailwright |  |  |  | placeholder |
| `disconnected.management.gateway` | string (ipv4) | operator |  |  |  | placeholder |
| `disconnected.management.prefix_length` | integer | operator |  |  |  | placeholder |
| `disconnected.dns_server` | string (ipv4) | operator; Trailwright |  |  |  | placeholder |
| `disconnected.time_servers` | array | operator |  |  |  | placeholder |
| `disconnected.identity.authority` | string | operator; Trailwright |  |  |  | placeholder |
| `disconnected.identity.client_id` | string | operator |  |  |  | placeholder |
| `disconnected.identity.root_operator_upn` | string | operator |  |  |  | placeholder |
| `disconnected.identity.ldap_server` | string | operator; Trailwright |  |  |  | placeholder |
| `disconnected.identity.ldaps` | boolean | operator |  |  |  | placeholder |
| `disconnected.identity.sync_group_identifier` | string | operator |  |  |  | placeholder |
| `disconnected.operator_subscription_name` | string | operator |  |  |  | placeholder |
| `disconnected.resource_group` | string | operator |  |  |  | placeholder |
| `disconnected.internal_ca` | boolean | operator; Trailwright |  |  |  | placeholder |

### environment

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `environment.name` | string, required | operator; Trailwright |  |  |  | placeholder |
| `environment.type` | string, required, one of `lab`, `demo`, `poc`, `dev`, `test`, `stg`, ... (7) | operator; Trailwright |  |  |  | placeholder |
| `environment.owner` | string | operator; Trailwright |  |  |  | placeholder |
| `environment.description` | string | operator; Trailwright |  |  |  | placeholder |

### extensions

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `extensions` | object | operator |  |  |  | placeholder |

### hardware

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `hardware.vendor` | string, required | operator; Trailwright | ztp; os_configuration; deployment | arm-deployment; os-configuration; toolkit-legacy-scripts; ztp | OS Drivers; Sbe | read |
| `hardware.model` | string, required | operator; Trailwright | ztp; os_configuration | pre-cluster-verification; toolkit-legacy-scripts; ztp | Gate SB-001; SB-002; SB-003; SB-004; SB-005; SB-006 | read |
| `hardware.cpu_cores` | integer | operator; Trailwright |  | pre-cluster-verification | Gate ND-008 | read |
| `hardware.memory_gib` | integer | operator; Trailwright |  | pre-cluster-verification | Gate ND-008 | read |
| `hardware.gpu.enabled` | boolean | operator; Trailwright |  |  |  | placeholder |
| `hardware.gpu.model` | string | operator; Trailwright |  |  |  | placeholder |
| `hardware.gpu.count_per_node` | integer | operator |  |  |  | placeholder |
| `hardware.bmc.username` | string, required | operator; Trailwright | ztp; discovery | discovery; ztp |  | read |
| `hardware.bmc.password` | string (kv_ref), required | operator; Trailwright; Key Vault ref | ztp; discovery | discovery; ztp |  | read |
| `hardware.bmc.rfs_write_attribute` | boolean | operator | ztp; discovery | ztp |  | read |
| `hardware.bmc.verify_certificate` | boolean, default `false` | operator; default | ztp; discovery | ztp |  | read |
| `hardware.bios.*` | string | operator | ztp | (part: infrastructure-helpers; ztp) |  | read-as-part |
| `hardware.bios_during_provisioning.*` | string | operator | ztp | (part: infrastructure-helpers; ztp) |  | read-as-part |
| `hardware.sbe.publisher` | string | operator | os_configuration; deployment | toolkit-legacy-scripts | ARM sbePublisher; Gate SB-004 (named) | read |
| `hardware.sbe.family` | string | operator | os_configuration; deployment | toolkit-legacy-scripts | ARM sbeFamily; Gate SB-003 (named); SB-004 (named) | read |
| `hardware.sbe.version` | string | operator; Trailwright | os_configuration; deployment | toolkit-legacy-scripts | ARM sbeVersion; Gate SB-003 (named); SB-004 (named) | read |
| `hardware.sbe.manifest_source` | string | operator | deployment | (part: ztp) | ARM sbeManifestSource | read-as-part |
| `hardware.sbe.manifest_creation_date` | string | operator | deployment | (part: ztp) | ARM sbeManifestCreationDate | read-as-part |
| `hardware.sbe.bundle_path` | string | operator; Trailwright | ztp; os_configuration; deployment | arm-deployment; os-configuration; toolkit-legacy-scripts |  | read |
| `hardware.sbe.requirement` | string, one of `required`, `not_applicable` | operator | os_configuration; deployment | toolkit-legacy-scripts | Gate SB-001 (named) | read |
| `hardware.sbe.not_applicable_reason` | string | operator | os_configuration; deployment | toolkit-legacy-scripts | Gate SB-001 (named) | read |
| `hardware.sbe.source_path` | string | operator | os_configuration; deployment | arm-deployment; toolkit-legacy-scripts | Gate SB-001 (named); SB-002 (named) | read |
| `hardware.sbe.source_username` | string | operator | os_configuration; deployment | toolkit-legacy-scripts | Gate SB-002 (named) | read |
| `hardware.sbe.source_password` | string (kv_ref) | operator; Key Vault ref | os_configuration; deployment | toolkit-legacy-scripts |  | read |
| `hardware.sbe.package_sha256` | string | operator | os_configuration; deployment | toolkit-legacy-scripts | Gate SB-004 (named) | read |
| `hardware.sbe.package_size_bytes` | integer | operator | os_configuration; deployment | toolkit-legacy-scripts | Gate SB-004 (named) | read |
| `hardware.sbe.delivery` | string, default `skip`, one of `winrm_copy`, `node_pull`, `skip` | operator; default | os_configuration | os-configuration | OS Drivers; Sbe | read |
| `hardware.sbe.node_pull_url` | string | operator | os_configuration | os-configuration | OS Drivers; Sbe | read |
| `hardware.sbe.allow_unvalidated` | boolean | operator; Trailwright | ztp | (part: ztp) |  | read-as-part |
| `hardware.network_cards[].label` | string | operator | os_configuration |  |  | placeholder |
| `hardware.network_cards[].make` | string | operator | os_configuration |  |  | placeholder |
| `hardware.network_cards[].model` | string | operator | os_configuration |  |  | placeholder |
| `hardware.network_cards[].ports[].name` | string, required | operator | os_configuration |  |  | placeholder |
| `hardware.network_cards[].ports[].speed_gbps` | number | operator | os_configuration |  |  | placeholder |
| `hardware.network_cards[].ports[].rdma` | string, one of `none`, `iwarp`, `roce`, `roce_v2` | operator | os_configuration |  |  | placeholder |
| `hardware.network_cards[].ports[].role` | string | operator | os_configuration |  |  | placeholder |
| `hardware.drives.capacity.media` | string, one of `nvme`, `ssd`, `hdd` | operator |  |  |  | placeholder |
| `hardware.drives.capacity.count` | integer | operator |  | pre-cluster-verification | Gate ST-001 | read |
| `hardware.drives.capacity.size_tb` | number | operator |  |  |  | placeholder |
| `hardware.drives.cache.media` | string, one of `nvme`, `ssd`, `hdd` | operator |  |  |  | placeholder |
| `hardware.drives.cache.count` | integer | operator |  |  |  | placeholder |
| `hardware.drives.cache.size_tb` | number | operator |  |  |  | placeholder |

### identity

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `identity.active_directory.domain_fqdn` | string, required | operator; Trailwright | os_configuration; deployment | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM domainFqdn; OS DomainJoin | read |
| `identity.active_directory.netbios_name` | string (netbios_name) | operator; Trailwright | os_configuration; deployment; monitoring | os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts | OS DomainJoin | read |
| `identity.active_directory.ou_path` | string, required | operator; Trailwright | os_configuration; deployment | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM adouPath; OS DomainJoin | read |
| `identity.active_directory.lcm_user.username` | string, required | operator; Trailwright | os_configuration; deployment; monitoring | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM AzureStackLCMAdminUsername; OS DomainJoin | read |
| `identity.active_directory.lcm_user.password` | string (kv_ref), required | operator; Trailwright; Key Vault ref | os_configuration; deployment; monitoring | arm-deployment; pre-cluster-verification; toolkit-legacy-scripts | ARM AzureStackLCMAdminPassword; OS ~DomainJoin | read |
| `identity.active_directory.domain_join_account.username` | string, required | operator | os_configuration; monitoring | os-configuration; sonar | OS DomainJoin | read |
| `identity.active_directory.domain_join_account.password` | string (kv_ref), required | operator; Key Vault ref | os_configuration; monitoring | os-configuration; sonar | OS DomainJoin | read |
| `identity.active_directory.local_admin_members` | array | operator | os_configuration | os-configuration | OS DomainJoin; LocalAdmin | read |
| `identity.active_directory.join_options.rename_after_join` | boolean, default `false` | operator; default | os_configuration |  | OS Hostname; ~DomainJoin | placeholder |
| `identity.active_directory.join_options.allow_ou_move` | boolean, default `false` | operator; default | os_configuration | os-configuration | OS DomainJoin | read |
| `identity.active_directory.domain_controllers` | array | operator; Trailwright | os_configuration | os-configuration; pre-cluster-verification | OS DomainJoin; Gate NW-015 | read |
| `identity.active_directory.use_gmsa` | boolean, default `false` | operator; default | deployment | pre-cluster-verification | OS ~DomainJoin | read |
| `identity.active_directory.dns_secure_dynamic_updates` | boolean | operator | deployment | pre-cluster-verification | OS ~DomainJoin | read |
| `identity.active_directory.security_groups[].name` | string, required | operator | os_configuration | os-configuration; toolkit-legacy-scripts | OS DomainJoin | read |
| `identity.active_directory.security_groups[].purpose` | string | operator | os_configuration | os-configuration | OS DomainJoin | read |
| `identity.active_directory.security_groups[].members` | array | operator |  |  | OS ~DomainJoin | placeholder |
| `identity.active_directory.security_groups[].local_groups` | array | operator | os_configuration | toolkit-legacy-scripts | OS ~DomainJoin | read |
| `identity.active_directory.service_accounts[].name` | string, required | operator |  |  | OS ~DomainJoin | placeholder |
| `identity.active_directory.service_accounts[].purpose` | string | operator |  |  | OS ~DomainJoin | placeholder |
| `identity.active_directory.service_accounts[].password` | string (kv_ref) | operator; Key Vault ref |  |  | OS ~DomainJoin | placeholder |
| `identity.local_admin.username` | string, required | operator; Trailwright | ztp; os_configuration; deployment; monitoring | arm-deployment; os-configuration; pre-cluster-verification; sonar; toolkit-legacy-scripts | ARM localAdminUserName; OS LocalAdmin | read |
| `identity.local_admin.username_secret` | string (kv_ref) | operator; Key Vault ref | deployment |  | OS ~LocalAdmin | placeholder |
| `identity.local_admin.password` | string (kv_ref), required | operator; Trailwright; Key Vault ref | ztp; os_configuration; deployment | arm-deployment; os-configuration; pre-cluster-verification; toolkit-legacy-scripts | ARM localAdminPassword; OS LocalAdmin | read |
| `identity.local_identity.dns_server_config` | string, required, one of `use_dns_server`, `use_forwarder` | operator; Trailwright | deployment | arm-deployment; pre-cluster-verification | ARM dnsServerConfig | read |
| `identity.local_identity.dns_zone` | string | operator; Trailwright | deployment | arm-deployment; pre-cluster-verification | ARM dnsZones | read |
| `identity.local_identity.dns_forwarders` | array | operator; Trailwright | deployment | arm-deployment; pre-cluster-verification | ARM dnsZones | read |
| `identity.entra.groups[].name` | string, required | operator |  | toolkit-legacy-scripts |  | read |
| `identity.entra.groups[].purpose` | string | operator |  | toolkit-legacy-scripts |  | read |
| `identity.entra.groups[].roles` | array | operator |  | toolkit-legacy-scripts |  | read |
| `identity.entra.groups[].scope` | string | operator |  | toolkit-legacy-scripts |  | read |
| `identity.entra.break_glass_accounts` | array | operator |  |  |  | placeholder |

### key_vaults

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `key_vaults[].name` | string (key_vault_name), required | operator | ztp; deployment; cicd_infra | arm-deployment; cicd-infra; pre-cluster-verification; ztp |  | read |
| `key_vaults[].subscription_id` | string (guid), required | operator | ztp; deployment; cicd_infra | arm-deployment; cicd-infra; pre-cluster-verification |  | read |
| `key_vaults[].resource_group` | string (resource_group), required | operator | ztp; deployment; cicd_infra | arm-deployment; cicd-infra; pre-cluster-verification |  | read |
| `key_vaults[].purpose` | string | operator | ztp; cicd_infra | (part: toolkit-legacy-scripts) |  | read-as-part |

### landing_zone

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `landing_zone.management_groups[].name` | string, required | operator |  | toolkit-legacy-scripts |  | read |
| `landing_zone.management_groups[].display_name` | string | operator |  | toolkit-legacy-scripts |  | read |
| `landing_zone.management_groups[].parent` | string | operator |  |  |  | placeholder |
| `landing_zone.subscriptions[].name` | string, required | operator | cicd_infra | cicd-infra; toolkit-legacy-scripts |  | read |
| `landing_zone.subscriptions[].id` | string (guid) | operator | cicd_infra | cicd-infra; toolkit-legacy-scripts |  | read |
| `landing_zone.subscriptions[].role` | string, required, one of `connectivity`, `identity`, `management`, `security`, `devops`, `workload`, ... (7) | operator | cicd_infra | cicd-infra |  | read |
| `landing_zone.subscriptions[].management_group` | string | operator | cicd_infra | toolkit-legacy-scripts |  | read |
| `landing_zone.resource_groups[].name` | string (resource_group), required | operator | cicd_infra |  |  | placeholder |
| `landing_zone.resource_groups[].subscription` | string | operator | cicd_infra |  |  | placeholder |
| `landing_zone.resource_groups[].location` | string (azure_region) | operator | cicd_infra |  |  | placeholder |
| `landing_zone.resource_groups[].purpose` | string | operator | cicd_infra |  |  | placeholder |
| `landing_zone.resource_providers` | array | operator |  |  |  | placeholder |
| `landing_zone.policy.required_tags` | array | operator |  | toolkit-legacy-scripts |  | read |
| `landing_zone.policy.management_group` | string | operator |  | toolkit-legacy-scripts |  | read |
| `landing_zone.networks[].name` | string, required | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `landing_zone.networks[].subscription` | string | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `landing_zone.networks[].resource_group` | string (resource_group) | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `landing_zone.networks[].location` | string (azure_region) | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `landing_zone.networks[].role` | string, one of `hub`, `spoke` | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `landing_zone.networks[].address_space` | array, required | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `landing_zone.networks[].dns_servers` | array | operator | cicd_infra | (part: cicd-infra) |  | read-as-part |
| `landing_zone.networks[].subnets[].name` | string, required | operator | cicd_infra | (part: cicd-infra; toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.networks[].subnets[].prefix` | string (cidr), required | operator | cicd_infra | (part: cicd-infra; toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.networks[].subnets[].network_security_group` | string | operator | cicd_infra | (part: cicd-infra; toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.networks[].subnets[].route_table` | string | operator | cicd_infra | (part: cicd-infra; toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.networks[].peer_with` | array | operator |  | (part: cicd-infra) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.name` | string, required | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.resource_group` | string (resource_group) | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.network` | string | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.sku` | string | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.bgp_asn` | integer | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].connection_name` | string, required | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].local_gateway_name` | string | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_public_ip` | string (ipv4) | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_address_prefixes` | array | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_bgp_address` | string (ipv4) | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_asn` | integer | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].shared_key` | string (kv_ref), required | operator; Key Vault ref |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.point_to_site.address_pool` | string (cidr), required | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.vpn_gateway.point_to_site.authentication` | string, one of `entra_id`, `certificate`, `radius` | operator |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `landing_zone.connectivity.bastion.name` | string, required | operator |  |  |  | placeholder |
| `landing_zone.connectivity.bastion.resource_group` | string (resource_group) | operator |  |  |  | placeholder |
| `landing_zone.connectivity.bastion.sku` | string | operator |  |  |  | placeholder |
| `landing_zone.connectivity.firewall.name` | string, required | operator |  |  |  | placeholder |
| `landing_zone.connectivity.firewall.resource_group` | string (resource_group) | operator |  |  |  | placeholder |
| `landing_zone.connectivity.firewall.sku` | string | operator |  |  |  | placeholder |
| `landing_zone.connectivity.firewall.private_ip` | string (ipv4) | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].name` | string, required | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].hostname` | string (netbios_name) | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].role` | string, required, one of `domain_controller`, `jumpbox`, `windows_admin_center`, `syslog`, `management`, `other` | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].deploy_target` | string, one of `azure`, `azure_local`, `onprem` | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].subscription` | string | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].resource_group` | string (resource_group) | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].network` | string | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].subnet` | string | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].private_ip` | string (ipv4) | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].size` | string | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].os` | string | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].admin_username` | string | operator |  |  |  | placeholder |
| `landing_zone.virtual_machines[].admin_password` | string (kv_ref) | operator; Key Vault ref |  |  |  | placeholder |
| `landing_zone.log_analytics.name` | string, required | operator; Trailwright |  |  |  | placeholder |
| `landing_zone.log_analytics.resource_group` | string (resource_group) | operator |  |  |  | placeholder |
| `landing_zone.log_analytics.retention_days` | integer | operator |  |  |  | placeholder |
| `landing_zone.storage_accounts[].name` | string (storage_account_name), required | operator |  | infrastructure-helpers |  | read |
| `landing_zone.storage_accounts[].resource_group` | string (resource_group) | operator |  | infrastructure-helpers |  | read |
| `landing_zone.storage_accounts[].sku` | string | operator |  | infrastructure-helpers |  | read |
| `landing_zone.storage_accounts[].purpose` | string | operator |  |  |  | placeholder |

### network_devices

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `network_devices[].hostname` | string, required | operator |  |  |  | placeholder |
| `network_devices[].type` | string, required, one of `switch`, `firewall`, `router`, `console_server`, `load_balancer`, `wireless_controller` | operator |  | ztp |  | read |
| `network_devices[].role` | string, one of `primary`, `secondary`, `standalone` | operator |  | ztp |  | read |
| `network_devices[].vendor` | string | operator |  |  |  | placeholder |
| `network_devices[].model` | string | operator |  | ztp |  | read |
| `network_devices[].serial_number` | string | operator |  |  |  | placeholder |
| `network_devices[].firmware_version` | string | operator |  |  |  | placeholder |
| `network_devices[].management.ip_address` |  | operator |  |  |  | placeholder |
| `network_devices[].management.vlan_id` | integer | operator |  |  |  | placeholder |
| `network_devices[].management.protocol` | string, one of `ssh`, `https`, `telnet`, `snmp` | operator |  |  |  | placeholder |
| `network_devices[].credentials.username` | string, required | operator |  |  |  | placeholder |
| `network_devices[].credentials.password` | string (kv_ref), required | operator; Key Vault ref |  |  |  | placeholder |
| `network_devices[].ha.enabled` | boolean | operator |  |  |  | placeholder |
| `network_devices[].ha.mode` | string | operator |  |  |  | placeholder |

### networking

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `networking.management.subnet` | string (cidr), required | operator; Trailwright | ztp; os_configuration; deployment | arm-deployment; infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | ARM subnetMask; OS Dns; Network; NicNames; RemoteManagement; UnusedAdapters; Gate NW-015 | read |
| `networking.management.gateway` | string (ipv4), required | operator; Trailwright | ztp; os_configuration; deployment | arm-deployment; infrastructure-helpers; pre-cluster-verification; ztp | ARM defaultGateway; OS Dns; Network; NicNames; UnusedAdapters; Gate NW-004; NW-015 | read |
| `networking.management.vlan_id` | integer | operator; Trailwright | ztp; os_configuration | infrastructure-helpers; pre-cluster-verification; ztp | OS Dns; Network; NicNames; UnusedAdapters; Gate NW-013; NW-015 | read |
| `networking.management.dns_servers` | array, required | operator; Trailwright | ztp; os_configuration; deployment | arm-deployment; infrastructure-helpers; pre-cluster-verification; ztp | ARM dnsServers; OS Dns; Network; NicNames; UnusedAdapters; Gate ND-006; NW-015 | read |
| `networking.management.ip_assignment` | string, default `static`, one of `static`, `dhcp`, `preconfigured` | operator; Trailwright; default | ztp; os_configuration; deployment | infrastructure-helpers; ztp | OS Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~Dns | deprecated |
| `networking.management.use_dhcp` | boolean | operator; Trailwright | os_configuration; deployment | arm-deployment; pre-cluster-verification | ARM useDhcp; OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters | read |
| `networking.management.site_ip_range.start` | string (ipv4), required | operator | ztp; os_configuration | infrastructure-helpers | OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters | read |
| `networking.management.site_ip_range.end` | string (ipv4), required | operator | ztp; os_configuration | infrastructure-helpers | OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters | read |
| `networking.management.provisioning_network` | string, default `dhcp`, one of `dhcp`, `static` | operator; default | ztp; os_configuration | infrastructure-helpers; ztp | OS Dns; Network; UnusedAdapters; ~NicNames | read |
| `networking.management.static_method` | string, default `device`, one of `device`, `site` | operator; default | ztp; os_configuration | infrastructure-helpers; ztp | OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters | read |
| `networking.management.provisioning_dhcp_range.start` | string (ipv4), required | operator | ztp; os_configuration | (part: ztp) | OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters | read-as-part |
| `networking.management.provisioning_dhcp_range.end` | string (ipv4), required | operator | ztp; os_configuration | (part: ztp) | OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters | read-as-part |
| `networking.management.infrastructure_pool.start` | string (ipv4), required | operator; Trailwright | os_configuration; deployment | arm-deployment; pre-cluster-verification | ARM startingIPAddress; OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters; Gate NW-015 | read |
| `networking.management.infrastructure_pool.end` | string (ipv4), required | operator; Trailwright | os_configuration; deployment | arm-deployment; pre-cluster-verification | ARM endingIPAddress; OS ~Dns; ~Network; ~NicNames; ~UnusedAdapters; Gate NW-015 | read |
| `networking.oob.subnet` | string (cidr) | operator; Trailwright | os_configuration | os-configuration | OS Network; RemoteManagement | read |
| `networking.oob.gateway` | string (ipv4) | operator; Trailwright |  |  |  | placeholder |
| `networking.oob.vlan_id` | integer | operator |  |  |  | placeholder |
| `networking.ntp_servers` | array | operator; Trailwright | ztp; os_configuration; deployment | arm-deployment; os-configuration; pre-cluster-verification | OS Time; Gate ND-005 | read |
| `networking.intents[].name` | string, required | operator | os_configuration; deployment | pre-cluster-verification | ARM ~intentList; ~networkingPattern; Gate NW-001; NW-002; NW-003; NW-009; NW-010; NW-011; NW-012; NW-013; NW-014 | read |
| `networking.intents[].traffic` | array, required, one of `management`, `compute`, `storage` | operator | os_configuration; deployment | pre-cluster-verification | ARM ~intentList; ~networkingPattern; Gate NW-001; NW-002; NW-003; NW-009; NW-010; NW-011; NW-012; NW-013; NW-014 | read |
| `networking.intents[].adapters` | array, required | operator | os_configuration; deployment | pre-cluster-verification | ARM ~intentList; ~networkingPattern; Gate NW-001; NW-002; NW-003; NW-009; NW-010; NW-011; NW-012; NW-013; NW-014 | read |
| `networking.intents[].overrides.qos.cluster_priority` | integer | operator | os_configuration; deployment | (part: arm-deployment) | ARM ~intentList; ~networkingPattern | read-as-part |
| `networking.intents[].overrides.qos.smb_priority` | integer | operator | os_configuration; deployment | (part: arm-deployment) | ARM ~intentList; ~networkingPattern | read-as-part |
| `networking.intents[].overrides.qos.smb_bandwidth_percent` | integer | operator | os_configuration; deployment | (part: arm-deployment) | ARM ~intentList; ~networkingPattern | read-as-part |
| `networking.intents[].overrides.adapter.jumbo_packet` | integer, one of `1514`, `4088`, `9014` | operator | os_configuration; deployment | pre-cluster-verification | ARM ~intentList; ~networkingPattern; Gate NW-001; NW-002; NW-003; NW-009; NW-010; NW-011; NW-012; NW-013; NW-014 | read |
| `networking.intents[].overrides.adapter.network_direct` | boolean | operator | os_configuration; deployment | pre-cluster-verification | ARM ~intentList; ~networkingPattern; Gate NW-001; NW-002; NW-003; NW-009; NW-010; NW-011; NW-012; NW-013; NW-014 | read |
| `networking.intents[].overrides.adapter.network_direct_technology` | string, one of `iwarp`, `roce`, `roce_v2` | operator | os_configuration; deployment | (part: arm-deployment) | ARM ~intentList; ~networkingPattern | read-as-part |
| `networking.intents[].overrides.virtual_switch.enable_iov` | boolean | operator | os_configuration; deployment | (part: arm-deployment) | ARM ~intentList; ~networkingPattern | read-as-part |
| `networking.intents[].overrides.virtual_switch.load_balancing_algorithm` | string, one of `dynamic`, `hyper_v_port` | operator | os_configuration; deployment | (part: arm-deployment) | ARM ~intentList; ~networkingPattern | read-as-part |
| `networking.storage.auto_ip` | boolean | operator; Trailwright | os_configuration; deployment | arm-deployment | ARM enableStorageAutoIp; storageNetworkList | read |
| `networking.storage.switchless_links` | string, one of `single`, `dual` | operator; Trailwright |  |  |  | placeholder |
| `networking.storage.tor_switches` | integer | operator; Trailwright |  |  |  | placeholder |
| `networking.storage.layout` | string, one of `dedicated`, `converged` | operator; Trailwright | os_configuration |  |  | placeholder |
| `networking.storage.networks[].name` | string, required | operator | os_configuration; deployment | arm-deployment | ARM storageNetworkList | read |
| `networking.storage.networks[].adapter` | string, required | operator | os_configuration; deployment | arm-deployment | ARM storageNetworkList | read |
| `networking.storage.networks[].vlan_id` | integer, required | operator | os_configuration; deployment | arm-deployment | ARM storageNetworkList; Gate NW-014 (named) | read |
| `networking.storage.networks[].subnet` | string (cidr) | operator | os_configuration; deployment | arm-deployment | ARM storageNetworkList | read |
| `networking.cluster_networks[].name` | string, required | operator | os_configuration; deployment | arm-deployment | ARM sanNetworkList; OS ~Network; ~RemoteManagement | read |
| `networking.cluster_networks[].adapter` | string, required | operator | os_configuration; deployment | arm-deployment | ARM sanNetworkList; OS ~Network; ~RemoteManagement | read |
| `networking.cluster_networks[].vlan_id` | integer, required | operator | os_configuration; deployment | arm-deployment | ARM sanNetworkList; OS ~Network; ~RemoteManagement | read |
| `networking.cluster_networks[].subnet` | string (cidr), required | operator | os_configuration; deployment | arm-deployment | ARM sanNetworkList; OS ~Network; ~RemoteManagement | read |
| `networking.cluster_networks[].purpose` | string, one of `management`, `oob`, `automation`, `compute`, `storage`, `other` | operator | os_configuration | (part: os-configuration; pre-cluster-verification) | OS ~Network; ~RemoteManagement | read-as-part |
| `networking.vlans[].name` | string, required | operator | os_configuration | pre-cluster-verification | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.vlans[].id` | integer, required | operator | os_configuration | pre-cluster-verification | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.vlans[].subnet` | string (cidr) | operator | os_configuration | pre-cluster-verification | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.vlans[].purpose` | string | operator | os_configuration | pre-cluster-verification | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.logical_networks[].name` | string, required | operator | deployment | pre-cluster-verification; toolkit-legacy-scripts | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.logical_networks[].enabled` | boolean, default `true` | operator; default | deployment | toolkit-legacy-scripts | OS ~Network; ~RemoteManagement | read |
| `networking.logical_networks[].ip_allocation_method` | string, default `Static`, one of `Static`, `Dynamic` | operator; default | deployment | toolkit-legacy-scripts | OS ~Network; ~RemoteManagement | read |
| `networking.logical_networks[].nsg_name` | string | operator | deployment | toolkit-legacy-scripts | OS ~Network; ~RemoteManagement | read |
| `networking.logical_networks[].purpose` | string, one of `management`, `oob`, `automation`, `compute`, `storage`, `other` | operator | os_configuration; deployment | pre-cluster-verification | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.logical_networks[].vlan_id` | integer | operator | deployment | pre-cluster-verification; toolkit-legacy-scripts | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.logical_networks[].address_prefix` | string (cidr) | operator | os_configuration; deployment | pre-cluster-verification; toolkit-legacy-scripts | OS ~Network; ~RemoteManagement; Gate NW-015 | read |
| `networking.logical_networks[].gateway` | string (ipv4) | operator | deployment | (part: os-configuration) | OS ~Network; ~RemoteManagement | read-as-part |
| `networking.logical_networks[].dns_servers` | array | operator | deployment | toolkit-legacy-scripts | OS ~Network; ~RemoteManagement | read |
| `networking.logical_networks[].ip_pool.start` | string (ipv4), required | operator | deployment | (part: os-configuration) | OS ~Network; ~RemoteManagement | read-as-part |
| `networking.logical_networks[].ip_pool.end` | string (ipv4), required | operator | deployment | (part: os-configuration) | OS ~Network; ~RemoteManagement | read-as-part |
| `networking.outbound.proxy.url` | string, required | operator; Trailwright |  | pre-cluster-verification | Gate NW-006 | read |
| `networking.outbound.proxy.bypass` | array | operator; Trailwright |  |  |  | placeholder |
| `networking.outbound.arc_gateway.name` | string, required | operator; Trailwright | os_configuration | infrastructure-helpers; os-configuration; pre-cluster-verification | OS ArcRegistration | read |
| `networking.outbound.arc_gateway.resource_group` | string (resource_group) | operator | os_configuration | infrastructure-helpers; os-configuration; pre-cluster-verification | OS ArcRegistration | read |
| `networking.outbound.private_path.transport` | string, one of `expressroute`, `site_to_site_vpn` | operator; Trailwright |  |  |  | placeholder |
| `networking.outbound.private_path.virtual_network` | string | operator; Trailwright |  |  |  | placeholder |
| `networking.outbound.private_path.workload_subnet` | string | operator |  |  |  | placeholder |
| `networking.outbound.private_path.firewall_subnet` | string | operator |  |  |  | placeholder |
| `networking.outbound.private_path.firewall_private_ip` | string (ipv4) | operator; Trailwright |  |  |  | placeholder |
| `networking.outbound.private_path.firewall_port` | integer | operator; Trailwright |  |  |  | placeholder |
| `networking.outbound.private_path.arc_private_link_scope` | boolean | operator |  |  |  | placeholder |
| `networking.outbound.private_path.proxy_bypass` | array | operator |  |  |  | placeholder |

### nodes

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `nodes[].name` | string (netbios_name), required | operator; Trailwright; Dell/Redfish discovery (proposes) | ztp; os_configuration; deployment; monitoring; discovery | arm-deployment; discovery; infrastructure-helpers; os-configuration; pre-cluster-verification; sonar; ztp | ARM arcNodeResourceIds; physicalNodesSettings; storageNetworkList; OS Hostname; Network; RemoteManagement; Sonar nodes[].name; Gate ND-001; NW-001; NW-015; SB-005; ST-011 | read |
| `nodes[].management.ip_address` | string (ipv4), required | operator; Trailwright | ztp; os_configuration; deployment; monitoring | infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | OS Mpio; Network; NicNames; RemoteManagement; SanVerify; UnusedAdapters; Gate ND-001; NW-001; NW-015; SB-005 | read |
| `nodes[].management.mac_address` | string (mac) | operator; Trailwright; Dell/Redfish discovery (proposes, applies) | ztp; os_configuration; discovery | discovery; infrastructure-helpers; ztp | OS Mpio; Network; NicNames; SanVerify; UnusedAdapters | read |
| `nodes[].management.adapter_name` | string | operator | ztp; os_configuration | infrastructure-helpers; ztp | OS Mpio; Network; NicNames; SanVerify; UnusedAdapters | read |
| `nodes[].network_adapters[].name` | string, required | operator; Dell/Redfish discovery (proposes) | ztp; os_configuration; discovery | arm-deployment; infrastructure-helpers; os-configuration; ztp | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement; Gate NW-001 (named) | read |
| `nodes[].network_adapters[].mac_address` | string (mac), required | operator; Dell/Redfish discovery (proposes) | ztp; os_configuration; discovery | infrastructure-helpers; os-configuration; ztp | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement; Gate NW-013 (named) | read |
| `nodes[].network_adapters[].slot` | string | operator; Dell/Redfish discovery (proposes) | ztp; os_configuration; discovery | ztp | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read |
| `nodes[].network_adapters[].port_index` | integer | operator; Dell/Redfish discovery (proposes) | os_configuration; discovery | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].network_adapters[].pci_location.bus` | integer | operator | os_configuration; discovery | os-configuration | OS Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement | read |
| `nodes[].network_adapters[].pci_location.device` | integer | operator | os_configuration; discovery | os-configuration | OS Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement | read |
| `nodes[].network_adapters[].pci_location.function` | integer | operator | os_configuration; discovery | os-configuration | OS Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement | read |
| `nodes[].network_adapters[].vendor` | string | operator; Dell/Redfish discovery (proposes) | os_configuration; discovery | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].network_adapters[].os_name_override` | string | operator | os_configuration; deployment | infrastructure-helpers; os-configuration | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement; Gate NW-013 (named) | read |
| `nodes[].network_adapters[].model` | string | operator; Dell/Redfish discovery (proposes) | ztp; os_configuration; discovery | ztp | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read |
| `nodes[].network_adapters[].speed_gbps` | number | operator; Dell/Redfish discovery (proposes) | os_configuration | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].network_adapters[].rdma` | string, one of `none`, `iwarp`, `roce`, `roce_v2` | operator; Dell/Redfish discovery (proposes) | os_configuration | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].network_adapters[].roles` | array, required, one of `management`, `compute`, `storage`, `provisioning`, `iscsi:a`, `iscsi:b`, ... (7) | operator; Dell/Redfish discovery (proposes) | ztp; os_configuration; monitoring; discovery | infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | OS Dns; Mpio; Network; NicNames; RemoteManagement; SanVerify; UnusedAdapters; Gate ND-001; NW-001; NW-015; SB-005 | read |
| `nodes[].network_adapters[].ip_assignment` | string, required, one of `static`, `dhcp_reservation`, `dhcp`, `preconfigured`, `none` | operator; Dell/Redfish discovery (proposes) | ztp; os_configuration; monitoring; discovery | infrastructure-helpers; os-configuration; ztp | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement | read |
| `nodes[].network_adapters[].ip_address` | string (ipv4) | operator | ztp; os_configuration; deployment; monitoring | infrastructure-helpers; os-configuration; pre-cluster-verification; ztp | OS Dns; Mpio; Network; NicNames; RemoteManagement; SanVerify; UnusedAdapters; Gate ND-001; NW-001; NW-015; SB-005 | read |
| `nodes[].network_adapters[].prefix_length` | integer | operator | os_configuration | infrastructure-helpers; os-configuration | OS Dns; Mpio; Network; NicNames; SanVerify; UnusedAdapters; ~RemoteManagement | read |
| `nodes[].network_adapters[].gateway` | string (ipv4) | operator | os_configuration | infrastructure-helpers | OS Dns; Network; NicNames; UnusedAdapters; ~Mpio; ~RemoteManagement; ~SanVerify | read |
| `nodes[].network_adapters[].dns_servers` | array | operator | os_configuration | infrastructure-helpers | OS Dns; Network; NicNames; UnusedAdapters; ~Mpio; ~RemoteManagement; ~SanVerify | read |
| `nodes[].network_adapters[].vlan_id` | integer | operator | ztp; os_configuration | ztp | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters; Gate NW-015 (named) | read |
| `nodes[].network_adapters[].vlan_mode` | string, one of `access`, `tagged` | operator | ztp; os_configuration | infrastructure-helpers; ztp | OS Dns; Network; NicNames; UnusedAdapters; ~Mpio; ~RemoteManagement; ~SanVerify | read |
| `nodes[].network_adapters[].allowed_vlans` | array | operator | deployment | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters; Gate NW-015 (named) | read-as-part |
| `nodes[].network_adapters[].switch_port.switch` | string | operator | os_configuration | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].network_adapters[].switch_port.port` | string | operator | os_configuration | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].network_adapters[].switch_port.description` | string | operator | os_configuration | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].network_adapters[].notes` | string | operator | os_configuration | (part: discovery; toolkit-legacy-scripts) | OS ~Mpio; ~Network; ~NicNames; ~RemoteManagement; ~SanVerify; ~UnusedAdapters | read-as-part |
| `nodes[].serial_number` | string | operator; Trailwright; Dell/Redfish discovery (proposes, applies) | ztp; discovery | infrastructure-helpers; ztp |  | read |
| `nodes[].bmc.ip_address` | string (ipv4) | operator; Trailwright | ztp; discovery | discovery; infrastructure-helpers; ztp |  | read |
| `nodes[].bmc.type` | string, one of `idrac`, `ilo`, `xcc`, `other` | operator | ztp; discovery | (part: toolkit-legacy-scripts) |  | read-as-part |
| `nodes[].bmc.username` | string | operator | ztp; discovery | discovery; ztp |  | read |
| `nodes[].bmc.password` | string (kv_ref) | operator; Key Vault ref | ztp; discovery | discovery; ztp |  | read |
| `nodes[].rack` | string | operator; Trailwright |  | (part: toolkit-legacy-scripts) |  | read-as-part |
| `nodes[].rack_position` | string | operator; Trailwright | ztp | ztp |  | read |
| `nodes[].zone` | string | operator; Trailwright | deployment | arm-deployment |  | read |
| `nodes[].storage_ips` | array | operator; Trailwright | os_configuration; deployment | arm-deployment | ARM storageNetworkList | read |
| `nodes[].arc_machine_name` | string | operator; Trailwright | ztp; os_configuration; deployment; monitoring | infrastructure-helpers; ztp | OS Network | read |
| `nodes[].arc_resource_name` | string | operator | ztp; os_configuration | infrastructure-helpers; ztp | OS Network | deprecated |
| `nodes[].bios.*` | string | operator | ztp; os_configuration | (part: infrastructure-helpers; toolkit-legacy-scripts; ztp) |  | read-as-part |
| `nodes[].bios_during_provisioning.*` | string | operator | ztp; os_configuration | (part: infrastructure-helpers; toolkit-legacy-scripts; ztp) |  | read-as-part |
| `nodes[].maintenance_address` | string (ipv4) | operator | ztp; os_configuration | os-configuration; pre-cluster-verification; ztp |  | read |
| `nodes[].san.hbas[].slot` | string, required | operator | ztp; deployment | ztp | OS ~Mpio; ~SanVerify | read |
| `nodes[].san.hbas[].type` | string, default `fibre_channel`, one of `fibre_channel`, `iscsi_offload` | operator; default | ztp; deployment | ztp | OS ~Mpio; ~SanVerify | read |
| `nodes[].san.hbas[].bios_attribute` | string | operator | ztp; deployment | ztp | OS ~Mpio; ~SanVerify | read |
| `nodes[].san.hbas[].bios_disabled_value` | string | operator | ztp; deployment | ztp | OS ~Mpio; ~SanVerify | read |
| `nodes[].san.hbas[].bios_enabled_value` | string | operator | ztp; deployment | ztp | OS ~Mpio; ~SanVerify | read |
| `nodes[].san.hbas[].model` | string | operator | ztp; deployment | ztp | OS ~Mpio; ~SanVerify | read |
| `nodes[].san.hbas[].ports[].wwpn` | string (wwpn), required | operator | os_configuration; deployment | os-configuration | OS Mpio; SanVerify; Gate ST-011 (named) | read |
| `nodes[].san.hbas[].ports[].fabric` | string, required | operator | deployment | (part: pre-cluster-verification; toolkit-legacy-scripts) | OS ~Mpio; ~SanVerify | read-as-part |
| `nodes[].san.initiator_iqn` | string (iscsi_name) | operator | os_configuration; deployment | os-configuration | OS Mpio; SanVerify | read |

### operations

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `operations.monitoring.enabled` | boolean, required | operator; Trailwright |  |  |  | placeholder |
| `operations.monitoring.log_analytics_workspace` | string | operator; Trailwright |  |  |  | placeholder |
| `operations.monitoring.workspace_resource_group` | string (resource_group) | operator; Trailwright |  |  |  | placeholder |
| `operations.monitoring.data_collection_rule` | string | operator |  |  |  | placeholder |
| `operations.monitoring.data_collection_endpoint` | string | operator |  |  |  | placeholder |
| `operations.monitoring.action_group` | string | operator |  |  |  | placeholder |
| `operations.monitoring.health_alerts` | boolean | operator |  |  |  | placeholder |
| `operations.monitoring.alert_email` | string | operator |  |  |  | placeholder |
| `operations.update_method` | string, one of `portal`, `powershell` | operator; Trailwright |  |  |  | placeholder |
| `operations.backup.enabled` | boolean, required | operator; Trailwright |  |  |  | placeholder |
| `operations.backup.approach` | string, one of `host`, `guest`, `both` | operator; Trailwright |  |  |  | placeholder |
| `operations.backup.solution` | string | operator; Trailwright |  |  |  | placeholder |
| `operations.backup.recovery_vault` | string | operator |  |  |  | placeholder |
| `operations.backup.resource_group` | string (resource_group) | operator |  |  |  | placeholder |
| `operations.backup.policy` | string | operator |  |  |  | placeholder |
| `operations.disaster_recovery.method` | string, one of `none`, `asr`, `hyper_v_replica` | operator; Trailwright |  |  |  | placeholder |
| `operations.disaster_recovery.recovery_vault` | string | operator; Trailwright |  |  |  | placeholder |
| `operations.disaster_recovery.resource_group` | string (resource_group) | operator |  |  |  | placeholder |
| `operations.disaster_recovery.replication_policy` | string | operator |  |  |  | placeholder |
| `operations.disaster_recovery.recovery_plan` | string | operator |  |  |  | placeholder |
| `operations.disaster_recovery.network` | string | operator |  |  |  | placeholder |
| `operations.disaster_recovery.test_network` | string | operator |  |  |  | placeholder |
| `operations.disaster_recovery.storage_account` | string (storage_account_name) | operator |  |  |  | placeholder |
| `operations.disaster_recovery.target_rto_minutes` | integer | operator; Trailwright |  |  |  | placeholder |
| `operations.disaster_recovery.target_rpo_minutes` | integer | operator; Trailwright |  |  |  | placeholder |
| `operations.notifications.emails` | array | operator; Trailwright |  | toolkit-legacy-scripts |  | read |
| `operations.notifications.teams_webhook` | string (kv_ref) | operator; Key Vault ref |  |  |  | placeholder |
| `operations.licensing.azure_hybrid_benefit` | boolean | operator; Trailwright |  |  |  | placeholder |
| `operations.licensing.windows_server_subscription` | boolean | operator |  |  |  | placeholder |
| `operations.licensing.azure_verification_for_vms` | boolean | operator |  |  |  | placeholder |

### os_configuration

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `os_configuration.clear_storage` | boolean, default `false` | operator; default | os_configuration | os-configuration | OS ClearStorage; Gate ST-002 (named) | read |
| `os_configuration.network.confirm_minutes` | integer, default `10` | operator; default | os_configuration | os-configuration |  | read |
| `os_configuration.network.stable_seconds` | integer, default `60` | operator; default | os_configuration | os-configuration |  | read |
| `os_configuration.remoting.transport` | string, default `winrm`, one of `winrm`, `winrm_https`, `arc` | operator; default | os_configuration |  | OS ~RemoteManagement | placeholder |
| `os_configuration.remoting.bootstrap_transport` | string, default `none`, one of `none`, `arc`, `smb`, `auto` | operator; default | os_configuration | os-configuration | OS RemoteManagement | read |
| `os_configuration.remoting.allowed_source_cidrs` | array | operator | os_configuration | os-configuration | OS RemoteManagement | read |
| `os_configuration.remoting.allow_any_source` | boolean | operator | os_configuration | os-configuration | OS RemoteManagement | read |
| `os_configuration.remoting.trusted_hosts` | string, default `auto`, one of `auto`, `exact`, `wildcard` | operator; default | os_configuration | os-configuration | OS RemoteManagement | read |
| `os_configuration.remoting.use_https` | default `auto`, one of `auto`, `True`, `False` | operator; default | os_configuration | os-configuration | OS RemoteManagement | read |
| `os_configuration.remoting.isolation_confirmed` | boolean | operator | os_configuration | os-configuration | OS RemoteManagement | read |
| `os_configuration.remoting.certificate` | string | operator | os_configuration | os-configuration | OS RemoteManagement | read |

### provisioning

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `provisioning.os_version` | string, required | operator; Trailwright | ztp; os_configuration | os-configuration; pre-cluster-verification; ztp | Gate ND-004; SB-003; SB-005; SB-006 | read |
| `provisioning.iso.image_source` | string, one of `microsoft`, `oem` | operator; Trailwright |  |  |  | placeholder |
| `provisioning.iso.image_version` | string | operator |  |  |  | placeholder |
| `provisioning.simplified.site_name` | string, required | operator; Trailwright | ztp; monitoring | sonar; ztp |  | read |
| `provisioning.simplified.subscription_id` | string (guid) | operator | ztp | ztp |  | read |
| `provisioning.simplified.resource_group` | string (resource_group) | operator | ztp | ztp |  | read |
| `provisioning.simplified.maintenance_iso` | string, required | operator; Trailwright | ztp | ztp |  | read |
| `provisioning.simplified.admin.username` | string, required | operator; Trailwright | ztp | ztp |  | read |
| `provisioning.simplified.admin.password` | string (kv_ref), required | operator; Trailwright; Key Vault ref | ztp | ztp |  | read |
| `provisioning.simplified.maintenance_password` | string (kv_ref) | operator; Key Vault ref | ztp | ztp |  | read |
| `provisioning.simplified.media_share.name` | string, required | operator; Trailwright | ztp | ztp |  | read |
| `provisioning.simplified.media_share.host` | string (ipv4) | operator; Trailwright | ztp | ztp |  | read |
| `provisioning.simplified.media_share.host_adapter` | string | operator; Trailwright | ztp | ztp |  | read |
| `provisioning.simplified.media_share.account_name` | string, default `svc-ztp-media` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.media_share.keep` | boolean, default `false` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.media_path` | string | operator | ztp | ztp |  | read |
| `provisioning.simplified.evidence_path` | string | operator | ztp; monitoring | sonar; ztp | Sonar discoveryPath (file discovery); osConfigEventsPath (file os-configuration-events.jsonl); ztpEvents.path (file ztp-events.jsonl) | read |
| `provisioning.simplified.isolate_san_adapters` | boolean | operator | ztp | ztp |  | read |
| `provisioning.simplified.enable_embedded_nics` | boolean, default `true` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.create_resource_group` | boolean, default `true` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.configuration_name` | string, default `default` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.managed_resource_group_name` | string | operator | ztp | ztp |  | read |
| `provisioning.simplified.apply_site_settings` | boolean, default `true` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.use_key_vault_configuration` | boolean, default `true` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.assign_provisioning_roles` | boolean, default `true` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.assign_hci_rp_role` | boolean, default `true` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.network_kind` | string, default `LAN`, one of `LAN`, `WLAN` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.ntp.configuration` | string, default `Automatic`, one of `Automatic`, `Manual` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.ntp.server` | string | operator | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.ntp.alternate_server` | string | operator | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.site_mode` | string, default `Auto`, one of `Auto`, `Create`, `Reuse` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.deployment_name` | string | operator | ztp; deployment | ztp |  | read |
| `provisioning.simplified.skip_azure_check` | boolean, default `false` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.include_preview` | boolean, default `false` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.max_train` | string | operator | ztp | ztp |  | read |
| `provisioning.simplified.retry_provision_os` | boolean, default `true` | operator; default | ztp | ztp |  | read |
| `provisioning.simplified.usb_image.size_gb` | integer, default `4` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.usb_image.name_prefix` | string, default `ztp-usb-` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.maintenance_environment.port` | integer, default `20001` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.maintenance_environment.username` | string, default `edgeuser` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.bootstrap_minutes` | integer, default `120` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.bootstrap_voucher_minutes` | integer, default `90` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.bootstrap_stall_minutes` | integer, default `20` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.voucher_wait_minutes` | integer, default `120` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.device_minutes` | integer, default `30` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.ready_minutes` | integer, default `180` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.network_minutes` | integer, default `60` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.restore_settle_minutes` | integer, default `5` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.bios_minutes` | integer, default `30` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.adapters_minutes` | integer, default `10` | operator; default | ztp | (part: ztp) |  | read-as-part |
| `provisioning.simplified.timeouts.poll_interval_seconds` | integer, default `60` | operator; default | ztp | (part: ztp) |  | read-as-part |

### scenario

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `scenario.identity` | string, one of `active_directory`, `local_identity` | operator; Trailwright | os_configuration; deployment; monitoring | arm-deployment; os-configuration; pre-cluster-verification; sonar | OS DomainJoin; Sonar identityModel; Gate RD-006 | read |
| `scenario.storage_architecture` | string, one of `s2d`, `san`, `hybrid` | operator; Trailwright | os_configuration; deployment | arm-deployment; os-configuration; pre-cluster-verification | ARM configurationMode; OS ClearStorage; Mpio; SanVerify; Gate NW-013; ST-004; ST-008 | read |
| `scenario.storage_connectivity` | string, one of `switched`, `switchless` | operator; Trailwright | deployment | arm-deployment | ARM networkingType; storageConnectivitySwitchless | read |
| `scenario.topology` | string, one of `standard`, `rack_aware` | operator; Trailwright | deployment | arm-deployment |  | read |
| `scenario.connectivity` | string, one of `connected`, `disconnected` | operator; Trailwright | deployment | arm-deployment; pre-cluster-verification | Gate NW-005 | read |
| `scenario.cloud` | string, one of `public`, `government` | operator; Trailwright | os_configuration; deployment | arm-deployment; os-configuration; pre-cluster-verification | OS ArcRegistration; Gate NW-005 | read |
| `scenario.outbound_path` | string, one of `direct`, `proxy`, `arc_gateway`, `proxy_arc_gateway`, `private_path` | operator; Trailwright | os_configuration | infrastructure-helpers; os-configuration; pre-cluster-verification | OS ArcRegistration; Gate NW-006 | read |
| `scenario.os_install` | string, one of `iso`, `simplified` | operator; Trailwright | ztp; os_configuration; monitoring | os-configuration; sonar; ztp | Sonar provisioningRoute | read |
| `scenario.deploy_method` | string, one of `portal`, `arm` | operator; Trailwright |  |  |  | placeholder |
| `scenario.environment_class` | string, default `production`, one of `lab`, `test`, `dev`, `production`, `dmz` | operator; default | os_configuration | os-configuration; toolkit-legacy-scripts | OS DomainJoin; RemoteManagement | read |

### sdn

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `sdn.enabled` | boolean, required | operator; Trailwright |  |  |  | placeholder |
| `sdn.prefix` | string | operator |  |  |  | placeholder |
| `sdn.dns_records` | string, one of `dynamic`, `static` | operator |  |  |  | placeholder |
| `sdn.default_access_policy` | boolean | operator |  |  |  | placeholder |

### security

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `security.level` | string, one of `recommended`, `customized` | operator; Trailwright | deployment | arm-deployment | ARM securityLevel | read |
| `security.drift_control` | boolean | operator | deployment | arm-deployment | ARM driftControlEnforced | read |
| `security.credential_guard` | boolean | operator | deployment | arm-deployment | ARM credentialGuardEnforced | read |
| `security.smb_signing` | boolean | operator | deployment | arm-deployment | ARM smbSigningEnforced | read |
| `security.smb_cluster_encryption` | boolean | operator | deployment | arm-deployment | ARM smbClusterEncryption | read |
| `security.bitlocker_boot_volume` | boolean | operator | deployment | arm-deployment | ARM bitlockerBootVolume | read |
| `security.bitlocker_data_volumes` | boolean | operator | deployment | arm-deployment | ARM bitlockerDataVolumes | read |
| `security.wdac` | boolean | operator | deployment | arm-deployment | ARM wdacEnforced | read |
| `security.backup_key_vault` | string (key_vault_name) | operator |  |  |  | placeholder |
| `security.defender_for_cloud.enabled` | boolean, default `true` | operator; default |  | toolkit-legacy-scripts |  | read |
| `security.defender_for_cloud.apply_cloud_security_benchmark` | boolean, default `true` | operator; default |  | toolkit-legacy-scripts |  | read |
| `security.telemetry.streaming_data` | boolean | operator | deployment | arm-deployment | ARM streamingDataClient | read |
| `security.telemetry.episodic_data_upload` | boolean | operator | deployment | arm-deployment | ARM episodicDataUpload | read |
| `security.telemetry.eu_location` | boolean | operator | deployment | arm-deployment | ARM euLocation | read |

### site

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `site.code` | string, required | operator; Trailwright | ztp | toolkit-legacy-scripts; ztp |  | read |
| `site.location` | string | operator; Trailwright |  | toolkit-legacy-scripts; ztp |  | read |
| `site.datacenter` | string | operator |  |  |  | placeholder |
| `site.name` | string | operator; Trailwright | ztp | toolkit-legacy-scripts; ztp |  | read |
| `site.owner` | string | operator |  | toolkit-legacy-scripts; ztp |  | read |
| `site.customer` | string | operator; Trailwright |  |  |  | placeholder |
| `site.time_zone` | string | operator; Trailwright | ztp | ztp |  | read |

### storage

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `storage.configuration_mode` | string, one of `express`, `infra_only`, `keep_storage` | operator; Trailwright | deployment | arm-deployment | ARM configurationMode | read |
| `storage.volumes[].name` | string, required | operator |  |  |  | validated-only |
| `storage.volumes[].size_gib` | number, required | operator |  |  |  | placeholder |
| `storage.volumes[].resiliency` | string, one of `two_way`, `three_way`, `four_way`, `parity`, `nested_two_way` | operator |  |  |  | validated-only |
| `storage.san.type` | string, required, one of `fibre_channel`, `iscsi` | operator; Trailwright | os_configuration; deployment | arm-deployment; os-configuration; pre-cluster-verification | OS Mpio; SanVerify; Gate ST-011 | read |
| `storage.san.array.name` | string, required | operator | deployment |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.array.vendor` | string, required | operator | os_configuration; deployment | os-configuration; pre-cluster-verification | OS Mpio; SanVerify; Gate ST-004; ST-006; ST-007 | read |
| `storage.san.array.model` | string, required | operator | os_configuration; deployment | os-configuration; pre-cluster-verification | OS Mpio; SanVerify; Gate ST-004; ST-006; ST-007 | read |
| `storage.san.array.management_address` | string (ipv4) | operator |  |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.fibre_channel.fabrics[].name` | string, required | operator | deployment |  | OS ~Mpio; ~SanVerify | validated-only |
| `storage.san.fibre_channel.fabrics[].switch` | string | operator | deployment |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.fibre_channel.fabrics[].zone_set` | string | operator |  |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.fibre_channel.target_wwpns[].wwpn` | string (wwpn), required | operator | deployment |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.fibre_channel.target_wwpns[].fabric` | string, required | operator | deployment |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.iscsi.targets[].iqn` | string (iscsi_name), required | operator | os_configuration; deployment | os-configuration | OS Mpio; SanVerify | read |
| `storage.san.iscsi.targets[].portals` | array, required | operator | os_configuration; deployment | os-configuration | OS Mpio; SanVerify | read |
| `storage.san.iscsi.targets[].fabric` | string | operator | os_configuration; deployment | os-configuration | OS Mpio; SanVerify | read |
| `storage.san.iscsi.chap.enabled` | boolean, required | operator | os_configuration; deployment | os-configuration | OS Mpio; SanVerify | read |
| `storage.san.iscsi.chap.username` | string | operator |  |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.iscsi.chap.secret` | string (kv_ref) | operator; Key Vault ref |  |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.infra_volume_lun_id` | string | operator; Trailwright | os_configuration; deployment | arm-deployment; os-configuration | ARM infraVolLunId; OS Mpio; SanVerify | read |
| `storage.san.performance_history_lun_id` | string | operator; Trailwright | os_configuration; deployment | arm-deployment; os-configuration | ARM infraPerfLunId; OS Mpio; SanVerify | read |
| `storage.san.luns[].name` | string, required | operator |  |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.luns[].size_gib` | number, required | operator |  |  | OS ~Mpio; ~SanVerify | placeholder |
| `storage.san.luns[].lun_id` | string | operator |  |  | OS ~Mpio; ~SanVerify | placeholder |

### tags

| Path | Type, default, allowed | Provided by | Purposes | Read by | Becomes | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `tags.*` | string | operator | ztp; cicd_infra | toolkit-legacy-scripts; ztp |  | read |

## Variables owned by a tool

The registry lists the variables of each tool under `tools.<tool>.<kind>.<group>.<name>`: command parameters, settings, config keys, events, state and handoff fields, secret names, environment variables. Each row in the CSV says where the tool reads or writes it (`readers`). The kinds:

| Tool | Kind | Variables | read | placeholder |
| --- | --- | ---: | ---: | ---: |
| arm_deployment | config_keys | 26 | 26 | 0 |
| arm_deployment | env_vars | 3 | 3 | 0 |
| arm_deployment | event_fields | 18 | 18 | 0 |
| arm_deployment | parameters | 166 | 166 | 0 |
| arm_deployment | report_fields | 20 | 20 | 0 |
| arm_deployment | run_settings | 31 | 31 | 0 |
| arm_deployment | secret_names | 2 | 2 | 0 |
| cicd_infra | ansible_variables | 27 | 27 | 0 |
| cicd_infra | config_keys | 5 | 5 | 0 |
| cicd_infra | env_vars | 53 | 53 | 0 |
| cicd_infra | parameters | 31 | 31 | 0 |
| cicd_infra | pipeline_inputs | 41 | 41 | 0 |
| cicd_infra | pipeline_variables | 85 | 85 | 0 |
| cicd_infra | secret_names | 15 | 15 | 0 |
| cicd_infra | terraform_variables | 90 | 90 | 0 |
| discovery | config_keys | 95 | 95 | 0 |
| discovery | env_vars | 1 | 1 | 0 |
| discovery | parameters | 81 | 81 | 0 |
| discovery | secret_names | 2 | 2 | 0 |
| os_configuration | config_keys | 83 | 83 | 0 |
| os_configuration | env_vars | 1 | 1 | 0 |
| os_configuration | event_fields | 83 | 83 | 0 |
| os_configuration | guard_settings | 21 | 21 | 0 |
| os_configuration | parameters | 49 | 49 | 0 |
| os_configuration | run_settings | 27 | 27 | 0 |
| os_configuration | secret_names | 10 | 10 | 0 |
| sonar | config_keys | 60 | 60 | 0 |
| sonar | env_vars | 3 | 3 | 0 |
| sonar | event_fields | 114 | 114 | 0 |
| sonar | parameters | 72 | 72 | 0 |
| sonar | secret_names | 9 | 9 | 0 |
| sonar | state_fields | 8 | 8 | 0 |
| ztp | config_keys | 178 | 171 | 7 |
| ztp | env_vars | 12 | 12 | 0 |
| ztp | handoff_fields | 39 | 39 | 0 |
| ztp | parameters | 862 | 862 | 0 |
| ztp | secret_names | 14 | 14 | 0 |
| ztp | state_fields | 30 | 30 | 0 |

## How the scan works, and what it cannot see

The scan parses PowerShell with the language parser (nothing is run) and records a key when code reads it in one of three ways: `chain` (`$infra.cluster.name`, `$node['bmc']['ip_address']`, the item of a `foreach` over `$infra.nodes`, `$_` in `Where-Object`), `literal` (a string that is exactly a registry path, or `Get-AzlProp $node 'bmc.ip_address'`, `.Contains('x')`), or `inferred` (a prefix plus a literal key in the same loop). The Trailwright catalog and Sonar's documented key mapping are read as text.

What it cannot see: a key read by a path built at run time from data; a value passed to another function that reads it there under another name (the map follows only functions that read the key by name; the ARM and OS tables follow one helper level); code that is not PowerShell (the Ansible roles, the Trailwright exporters, which still write the schema 4 shape); the tools' own feeds read by other tools (for example Sonar reading ZTP events). A variable shown as placeholder or read as part may still be used in one of those ways.

