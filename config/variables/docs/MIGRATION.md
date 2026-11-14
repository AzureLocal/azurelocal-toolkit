# Moving to infrastructure.yml schema 5

Schema 5 replaces three earlier shapes. This page says where each of their keys went.

| Earlier shape | Who wrote or read it |
| --- | --- |
| [The environment file read by azurelocal-ztp](#from-the-azurelocal-ztp-environment-file) (`cluster_nodes`, `network_intents`, `onprem`, `credentials`, `ztp`) | Environment repositories, `Invoke-ZtpEnvironment.ps1` |
| [Trailwright's export](#from-trailwrights-export) (a subset of registry 4.0.0) | Trailwright 1.x |
| [The toolkit's `variables.yml`](#from-the-toolkits-variablesyml-registry-400) (registry 4.0.0) | Toolkit scripts |

Three things changed throughout:

- **Choices moved to `scenario`.** Identity, storage, topology, connectivity and the install method are set once there, instead of being implied by which keys exist.
- **Secrets are only `keyvault://<vault>/<secret>` references**, and every vault is listed once in `key_vaults` with its subscription and resource group. Separate vault, subscription and secret-name keys are gone.
- **Enum values are `snake_case`** (`active_directory`, `rack_aware`, `two_way`), and so are all keys.

Not carried over: `cluster_ip` (the deployment takes it from the infrastructure pool), `cluster_node_count` (it's the number of `nodes`), the `nested` topology, `disk_witness`, and generated ARM parameters (tools generate them from the file).

## One template per tool (registry 5.0.41)

The generated folders `config/variables/templates/purposes` and `config/variables/schema/purposes` are now `config/variables/templates/tools` and `config/variables/schema/tools`, and the generator writes a template and a schema for every tool that has keys, not only for the six earlier ones: `trailwright` and `ranger` are new. The file names of the six are unchanged. The generator parameter `-Cut <tool>` takes the same ids; the module functions `Get-PurposePath` and `Select-InfrastructurePurpose` are now `Get-ToolPath` and `Select-InfrastructureTool` (parameter `-Tool`). No key was added, removed or renamed, and the infrastructure schema version is unchanged (5.6.14). In the registry, `used_by` lost `monitoring` on `identity.active_directory.lcm_user` (and its two keys) and on the `secrets` section, which Sonar does not read.
## From the azurelocal-ztp environment file

| Before | Schema 5 |
| --- | --- |
| `cluster_nodes[].name` | `nodes[].name` |
| `cluster_nodes[].ip_address` | `nodes[].management.ip_address` |
| `cluster_nodes[].mac_address` | `nodes[].management.mac_address` (the management port) |
| `cluster_nodes[].adapter_name` | `nodes[].management.adapter_name` |
| `cluster_nodes[].arc_machine_name` | `nodes[].arc_machine_name` (schema 5.1). Default: `nodes[].name`. |
| `cluster_nodes[].service_tag` | `nodes[].serial_number` |
| `cluster_nodes[].idrac_ip` | `nodes[].bmc.ip_address`, with `nodes[].bmc.type: idrac` |
| `cluster_nodes[].rack_position` | `nodes[].rack_position` |
| `network_intents.management.subnet`, `gateway`, `vlan_id`, `dns_servers` | `networking.management.subnet`, `gateway`, `vlan_id`, `dns_servers` |
| `network_intents.management.ip_assignment` (`static`, `dhcp`, `preconfigured`) | `networking.management.ip_assignment`, same values (schema 5.1). Default `static`. Not `networking.management.use_dhcp`, which is the deployment's ARM `useDhcp`. |
| `network_intents.storage.subnet_1`, `subnet_2`, `vlan_id_1`, `vlan_id_2` | `networking.storage.networks[]`: `name`, `adapter`, `vlan_id`, `subnet` |
| `network_intents.storage.rdma_enabled` | `hardware.network_cards[].ports[].rdma` |
| `network_intents.compute` | `networking.vlans[]` and `networking.logical_networks[]` |
| `network_intents.oob_management` | `networking.oob` |
| (no equivalent: intents were implied) | `networking.intents[]`: name, traffic and adapters of each Network ATC intent |
| `onprem.ntp_servers` | `networking.ntp_servers` |
| `onprem.dns_servers` | `networking.management.dns_servers` |
| `onprem.domain_name`, `domain_netbios`, `ou_path` | `identity.active_directory.domain_fqdn`, `netbios_name`, `ou_path` |
| `credentials.local_admin_username` | `identity.local_admin.username` |
| `credentials.local_admin_password_secret` | `identity.local_admin.password` |
| `credentials.domain_join_username` (`user@domain`) | `identity.active_directory.lcm_user.username` (name only) |
| `credentials.domain_join_password_secret` | `identity.active_directory.lcm_user.password` |
| `hardware.vendor`, `model` | `hardware.vendor`, `model` |
| `hardware.gpu_enabled`, `gpu_model` | `hardware.gpu.enabled`, `model` |
| `azure_identity.azure_tenant_id` | `azure.tenant_id` |
| `azure_identity.azure_subscription_id` | The management subscription: `landing_zone.subscriptions[]` with `role: management` |
| `azure_resources.location` | `azure.location` |
| `azure_resources.tags`, `tags` | `tags` |
| `azure_local.cluster_name` | `cluster.name` |
| `azure_local.network_topology` (`traditional`, `switchless`) | `scenario.storage_connectivity` (`switched`, `switchless`) |
| `azure_local.identity_provider` | `scenario.identity` |
| `azure_local.arc_resource_group` | `azure.resource_group` |
| `azure_local.witness_type` (`cloud_witness`, `file_share_witness`) | `cluster.witness.type` (`cloud`, `file_share`) |
| `azure_local.deployment_mode` (`validate_only`, `deploy`) | `cluster.deployment_mode` (`validate`, `deploy`) |
| `keyvault.platform_keyvault_name` | An entry in `key_vaults` |
| `storage.storage_account_name` | `cluster.witness.storage_account`, or `landing_zone.storage_accounts[]` |
| `networking.vnet_name`, `vnet_address_space`, `subnet_*` | `landing_zone.networks[]` |
| `site.*`, `environment.*` | `site.*`, `environment.*` (`environment.name` is free-form) |
| `network_devices[].device_hostname`, `device_type`, `device_role`, `device_vendor`, `device_model` | `network_devices[].hostname`, `type`, `role`, `vendor`, `model` |
| `network_devices[].device_management_ip`, `device_management_vlan`, `device_management_protocol` | `network_devices[].management.ip_address`, `vlan_id`, `protocol` (lowercase) |
| `network_devices[].device_username_secret`, `device_password_secret` | `network_devices[].credentials.username`, `password` |
| `network_devices[].device_ha_enabled`, `device_ha_mode` | `network_devices[].ha.enabled`, `mode` |
| `ztp.subscription_id`, `resource_group` | `provisioning.simplified.subscription_id`, `resource_group`. Leave out when they're `azure.subscription_id` and `azure.resource_group`. |
| `ztp.site_name` | `provisioning.simplified.site_name` |
| `ztp.time_zone` | `site.time_zone` |
| `ztp.os_version` | `provisioning.os_version` |
| `ztp.provisioning_iso` | `provisioning.simplified.maintenance_iso` |
| `ztp.share_name`, `share_host`, `share_host_adapter` | `provisioning.simplified.media_share.name`, `host`, `host_adapter` |
| `ztp.admin_secret.username` | `provisioning.simplified.admin.username` |
| `ztp.admin_secret.vault`, `name` | `provisioning.simplified.admin.password: keyvault://<vault>/<name>` |
| `ztp.admin_secret.subscription_id`, `resource_group` | The vault's entry in `key_vaults` |
| `ztp.bmc_secret.vault`, `username_name`, `password_name` | `hardware.bmc.username: keyvault://<vault>/<username_name>`, `hardware.bmc.password: keyvault://<vault>/<password_name>`. A node can set its own in `nodes[].bmc`. |
| `ztp.azl_rp_object_id` | `azure.hci_resource_provider_object_id` |
| `ztp.automation_identity` (`type: managed-identity`) | `azure.automation_identity` (`type: managed_identity`) |
| `ztp.node_preparation.sbe_bundle` | `hardware.sbe.bundle_path` |
| `ztp.node_preparation.allow_unvalidated_sbe` | `hardware.sbe.allow_unvalidated` |
| `ztp.tags` | `tags` |
| `cluster_nodes[].bios`, `hardware.bios` | `nodes[].bios`, `hardware.bios` (schema 5.2) |
| `network_intents.management.site_ip_range` | `networking.management.site_ip_range` (schema 5.2) |
| `network_intents.management.provisioning_network` | `networking.management.provisioning_network` (schema 5.2) |
| `ztp.media_path`, `ztp.evidence_path` | `provisioning.simplified.media_path`, `evidence_path` (schema 5.2) |
| (implied by the presence of `ztp`) | `scenario.os_install: simplified` |
| Other top-level keys of one environment (for example `devops_runner`) | `devops`, or `extensions.<name>` |

`hardware.bmc.username` and `nodes[].bmc.username` take either a user name or a `keyvault://` reference to a secret holding it. Tools resolve the reference when the value starts with `keyvault://`.

## From Trailwright's export

| Before | Schema 5 |
| --- | --- |
| `identity.mode` (`active-directory`, `local-identity-key-vault`) | `scenario.identity` (`active_directory`, `local_identity`) |
| `identity.local_admin_username` | `identity.local_admin.username` |
| `identity.secrets[]` (`local-admin-password`, `lcm-password`) | `identity.local_admin.password`, `identity.active_directory.lcm_user.password` |
| `identity.active_directory.ad_domain_fqdn`, `ou_path`, `lcm_username` | `identity.active_directory.domain_fqdn`, `ou_path`, `lcm_user.username` |
| `identity.local_identity.dns_server_config` (`UseDnsServer`), `dns_zone`, `dns_forwarders` | `identity.local_identity.dns_server_config` (`use_dns_server`), `dns_zone`, `dns_forwarders` |
| `environment.azure_region` | `azure.location` |
| `environment.azure_cloud` | `scenario.cloud` |
| `environment.connectivity_mode` | `scenario.connectivity` |
| `environment.architecture` (`hyperconverged`, `hybrid`, `disaggregated`) | `scenario.storage_architecture` (`s2d`, `hybrid`, `san`) |
| `azure_platform.tenant_id` | `azure.tenant_id` |
| `azure_platform.subscriptions.sub_azure_local_id` | `azure.subscription_id` |
| `azure_platform.resource_groups.rg_azurelocal_cluster` | `azure.resource_group` |
| `azure_platform.instance_name`, `naming_prefix` | `cluster.name`, `cluster.naming_prefix` |
| `azure_platform.hci_resource_provider_object_id`, `custom_location` | `azure.hci_resource_provider_object_id`, `azure.custom_location` |
| `azure_platform.key_vault.name`, `soft_delete_retention_days` | `cluster.key_vault.name`, `soft_delete_retention_days` |
| `azure_platform.key_vault.audit_storage_account`, `audit_retention_days` | `cluster.diagnostics.storage_account`, `logs_retention_days` |
| `azure_platform.witness_storage_account` | `cluster.witness.storage_account` |
| `provisioning.os_install`, `deploy_method` | `scenario.os_install`, `scenario.deploy_method` |
| `provisioning.site.time_zone`, `time_server` | `site.time_zone`, `networking.ntp_servers` |
| `connectivity.outbound_path` (`arc-gateway`, `proxy-arc-gateway`, `private-path`) | `scenario.outbound_path` (`arc_gateway`, `proxy_arc_gateway`, `private_path`) |
| `connectivity.proxy_url`, `arc_gateway_name`, `private_path.*` | `networking.outbound.proxy.url`, `networking.outbound.arc_gateway.name`, `networking.outbound.private_path.*` |
| `infrastructure_network.subnet_mask` and `default_gateway` | `networking.management.subnet` (CIDR) and `gateway` |
| `infrastructure_network.ip_pool`, `dns_servers`, `use_dhcp`, `management_vlan` | `networking.management.infrastructure_pool`, `dns_servers`, `use_dhcp`, `vlan_id` |
| `networking.storage_mode` | `scenario.storage_connectivity` |
| `networking.tor_switches`, `storage_auto_ip` | `networking.storage.tor_switches`, `networking.storage.auto_ip` |
| `networking.storage_vlans` | `networking.storage.networks[].vlan_id` |
| `networking.intents[]` (`override_qos`, `override_adapter`) | `networking.intents[]` (`overrides.qos`, `overrides.adapter`, `overrides.virtual_switch`) |
| `networking.vlans`, `ip_plan` | `networking.vlans` |
| `compute.cluster.topology` (`rack-aware`), `witness_type` | `scenario.topology` (`rack_aware`), `cluster.witness.type` |
| `compute.nodes[].name`, `ip`, `serial` | `nodes[].name`, `management.ip_address`, `serial_number` |
| `compute.nodes[].cores`, `memory_gib`, `drives` | `hardware.cpu_cores`, `memory_gib`, `drives` |
| `storage.configuration_mode` (`Express`), `volumes[].resiliency` (`two-way`) | `storage.configuration_mode` (`express`), `volumes[].resiliency` (`two_way`) |
| `storage.san_luns`, `infra_volume_lun_id`, `infra_performance_lun_id` | `storage.san.luns`, `infra_volume_lun_id`, `performance_history_lun_id` |
| `sdn.logical_networks` | `networking.logical_networks` |
| `security.level` (`Recommended`) and the other settings | `security.level` (`recommended`), same keys |
| `operations.*` | `operations.*` |
| `arm_parameters` | Not stored: generated from the file |

## From the toolkit's variables.yml (registry 4.0.0)

| Before | Schema 5 |
| --- | --- |
| `identity.accounts.account_local_admin_username`, `account_local_admin_password` | `identity.local_admin.username`, `password` |
| `identity.accounts.account_lcm_username`, `account_lcm_password` | `identity.active_directory.lcm_user.username`, `password` |
| `identity.active_directory.ad_domain_fqdn`, `ad_netbios_name`, `ad_ou_path` | `identity.active_directory.domain_fqdn`, `netbios_name`, `ou_path` |
| `identity.active_directory.ad_dns_servers`, `networking.onprem.dns.servers` | `networking.management.dns_servers` |
| `identity.service_principal` | `azure.automation_identity` with `type: service_principal`; its secret stays in Key Vault |
| `networking.onprem.vlans.management.id`, `subnet`, `gateway` | `networking.management.vlan_id`, `subnet`, `gateway` |
| `compute.azure_local.default_gateway`, `subnet_mask` | `networking.management.gateway`, `subnet` |
| `networking.onprem.network_intents[]` (`traffic_types`, `adapter_names`) | `networking.intents[]` (`traffic`, `adapters`) |
| `networking.onprem.network_devices.*` | `network_devices[]` |
| `networking.azure.*`, `networking.hybrid.vpn` | `landing_zone.networks[]`, `landing_zone.connectivity` |
| `compute.cluster_nodes[].node_hostname`, `node_management_ip`, `node_idrac_ip`, `node_service_tag` | `nodes[].name`, `management.ip_address`, `bmc.ip_address`, `serial_number` |
| `compute.clusters.azure_local.azl_name`, `azl_resource_group` | `cluster.name`, `azure.resource_group` |
| `compute.clusters.azure_local.azl_identity_provider`, `azl_network_topology` | `scenario.identity`, `scenario.storage_connectivity` |
| `compute.clusters.azure_local.azl_witness_type`, `azl_deployment_mode` | `cluster.witness.type`, `cluster.deployment_mode` |
| `compute.vms.management.*` (DCs, jump box, WAC, syslog) | `landing_zone.virtual_machines[]` |
| `security.keyvault`, `security.key_vaults` | `key_vaults[]`, and `cluster.key_vault` for the instance's own vault |
| `cluster_shared_volumes.volumes` | `storage.volumes` |
| `azure_platform.azure_tenants`, `management_groups`, `subscriptions`, `resource_groups` | `azure.tenant_id`, `landing_zone.management_groups`, `subscriptions`, `resource_groups` |
| `operations.monitoring` | `operations.monitoring` |
| `devops.gitlab`, `devops.terraform` | `devops` |
| Legacy roots `azure`, `platform`, `cluster`, `azure_infrastructure`, `azure_resources`, `azure_local`, `azure_vms` | The sections above; they held copies of the same values |

## Within schema 5

Minor versions add optional keys; a key that is renamed keeps working until the next major version.

| Before | Now |
| --- | --- |
| `nodes[].arc_resource_name` (5.0) | `nodes[].arc_machine_name` (5.1). `arc_resource_name` still reads as the Arc machine name, with a deprecation warning (AZL-018). |
| `nodes[].management` (5.0) | `nodes[].network_adapters` (5.2): the port with role `management` and an `ip_assignment` other than `none`. `nodes[].management` still works for nodes without `network_adapters`. |
| `networking.management.ip_assignment` (5.1): `static`, `dhcp`, `preconfigured` | Each port's `ip_assignment` (5.2): `static`, `dhcp_reservation`, `dhcp`, `preconfigured`, `none`. 5.1's `dhcp` meant a reserved address, so it reads as `dhcp_reservation`. |
| `hardware.bios`, `nodes[].bios` (5.2: set before the maintenance boot) | The machine's FINAL state (5.3). Values that hold for the OS install only go in `bios_during_provisioning`. |
| `hardware.network_cards[].ports[]` (5.0) | Still valid as a hardware summary; `nodes[].network_adapters` (5.2) holds each machine's ports with MACs and addresses. |

## To 5.2: the ports of each machine

Schema 5.2 only adds keys: every 5.0 and 5.1 file stays valid, and tools read both shapes through `Get-AzlManagementAdapter`.

**The decision.** `nodes[].management` and `networking.management.ip_assignment` become derivable from `nodes[].network_adapters` and are deprecated aliases, not removed:

- A node without `network_adapters` is read as before: one management port, made from `nodes[].management`, with the site-wide `ip_assignment` (`dhcp` is read as `dhcp_reservation`).
- A node with `network_adapters` takes its management port, address and MAC from the list. If it also has `nodes[].management`, the two must agree (AZL-020 error), and the repeat is a warning. The same for the site-wide `ip_assignment`.
- List the ports on every node or on none (AZL-019).
- A major version (6.0) would remove the aliases.

**Steps for a 5.1 file:**

1. Set `_metadata.schema_version` to `5.2.0`.
2. On each node, add `network_adapters` with every physical port: `name` as the OS names it, `mac_address`, `roles` and `ip_assignment`.
3. Move `management.ip_address` and `management.mac_address` to the management port (`roles: [management]`, `ip_assignment: static` or `dhcp_reservation`). Give its team partner `ip_assignment: none`. Delete `nodes[].management`.
4. Delete `networking.management.ip_assignment`; each port has its own.
5. Make `networking.intents[].adapters` and `networking.storage.networks[].adapter` use the port names, with the management port first in the management intent.
6. With simplified provisioning, give at least one port per node the role `provisioning`: the port the maintenance environment reaches Azure through. Set `networking.management.provisioning_network` if it isn't DHCP.
7. Run `Test-InfrastructureFile.ps1`. AZL-019 to AZL-025 check the ports against each other, the intents and the networks.

Before and after, for one node:

```yaml
# 5.1
nodes:
  - name: "iic-azl-n01"
    management: { ip_address: "192.0.2.11", mac_address: "00:00:5E:00:53:11", adapter_name: "Port1" }
networking:
  management: { ip_assignment: static, ... }

# 5.2
nodes:
  - name: "iic-azl-n01"
    network_adapters:
      - { name: "Port1", mac_address: "00:00:5E:00:53:11", roles: [management], ip_assignment: static, ip_address: "192.0.2.11" }
      - { name: "Port2", mac_address: "00:00:5E:00:53:12", roles: [management], ip_assignment: none }
      - { name: "Port3", mac_address: "00:00:5E:00:53:13", roles: [compute, storage, provisioning], ip_assignment: none }
      - { name: "Port4", mac_address: "00:00:5E:00:53:14", roles: [compute, storage, provisioning], ip_assignment: none }
```

**Two findings to know**, from live simplified-provisioning runs in 2026-11, both open research items:

- The service overwrites the Arc machine name set at claim time (edge machine `arcMachineResourceId`): the Arc machines came out as `ROE1-<id>` and then `<device-id>-1`. `arc_machine_name` stays in the schema; tools read the name actually used from the edge machine afterwards.
- The maintenance environment needs network access to Azure before the machine is claimed. Learn documents only the Configurator app for a static address there; whether the bootable image can carry a preset address is unresearched. So `provisioning_network: static` is a warning (AZL-024), and the example files use DHCP on a provisioning port.

## To 5.3: BIOS phases, the static method and the SAN

Schema 5.3 only adds keys: every 5.0 to 5.2 file stays valid. Nothing is renamed or removed.

| New key | What it is for |
| --- | --- |
| `hardware.bios_during_provisioning`, `nodes[].bios_during_provisioning` | Temporary BIOS values for the OS install only. `hardware.bios` and `nodes[].bios` keep their keys and are now described as the machine's FINAL state. A node's map is merged over the hardware one, and during-provisioning wins over `bios`. |
| `networking.management.static_method` | `device` (default) or `site`: who sets a static management address. |
| `networking.management.provisioning_dhcp_range` | The DHCP range the Device stage scans (TCP 20001) to find each maintenance environment by MAC. |
| `nodes[].maintenance_address` | The maintenance environment's address, when known (replaces the scan for that node). |
| `provisioning.simplified.maintenance_password` | A `keyvault://` reference: the maintenance environment's password. Default: the out-of-box password Learn documents. |
| `storage.san.array`, `storage.san.fibre_channel`, `storage.san.iscsi`, `nodes[].san` | The SAN: array, fabrics, target WWPNs, iSCSI targets and CHAP, each machine's HBA ports or initiator IQN. |
| port role `iscsi:a`, `iscsi:b` in `nodes[].network_adapters[].roles` | The iSCSI ports; their addresses use the existing `ip_assignment`, `ip_address`, `prefix_length` and VLAN keys. |
| `_metadata.scope` | `full` (default) or `ztp`: a file that holds only what azurelocal-ztp reads. |

**What changes in behaviour.** Read these before you move a file to 5.3:

- **Static addresses with simplified provisioning default to `device`.** ZTP sets each static management address through the maintenance environment before the claim, and the Arc site is Automatic. Before 5.3 the site was Manual with an address range and Microsoft's OS install assigned the address. To keep the old path, set `networking.management.static_method: site` (AZL-027 warns that Microsoft then uses the first ready port, not the MAC). `networking.management.site_ip_range` is used only with `site`.
- **The maintenance environment's own address.** The 5.2 note still holds for the address the maintenance environment uses to reach Azure: `provisioning_network: static` stays a warning (AZL-024), because Learn documents only the Configurator app for it. What 5.3 settles is the machine's management address: with `device`, ZTP sets it through the Configurator service of the maintenance environment, which it finds by MAC (`provisioning_dhcp_range`) or at `nodes[].maintenance_address`.
- **`bios` is the final state.** If a BIOS value was only right for the install (a Fibre Channel HBA turned off so the maintenance environment can't install onto its SAN LUN), move it to `bios_during_provisioning` and put the final value in `bios`. ZTP's Restore stage sets it back, restarts the node and waits for Arc.
- **A `san` or `hybrid` file needs the SAN details** as before (`storage.san`), and from 5.3 the rules in AZL-028 apply to them: set `fibre_channel` or `iscsi` to match `type`, and each node's `san`.

**Steps for a 5.2 file:**

1. Set `_metadata.schema_version` to `5.3.0`.
2. If a BIOS key was there only for the install, move it to `bios_during_provisioning` and set its final value in `bios`.
3. With simplified provisioning and static addresses, add `networking.management.provisioning_dhcp_range` (or `nodes[].maintenance_address` on every node), or keep the old path with `static_method: site`.
4. For a SAN, fill `storage.san.array`, the `fibre_channel` or `iscsi` block, and each node's `san`. For iSCSI, give the iSCSI ports the roles `iscsi:a` and `iscsi:b` in `network_adapters`.
5. Run `Test-InfrastructureFile.ps1`. AZL-026 to AZL-028 check the new keys.

**A ZTP-only file** (`_metadata.scope: ztp`) is new in 5.3. Start it from `infrastructure.ztp.example.yml`; to grow it into the full file, add the rest and set `scope: full`. See the README (Which template).

## To 5.4: every ZTP setting, and BIOS actions derived from the inventory

Schema 5.4 only adds optional keys; a 5.3 file is valid as it is. Nothing changes for a file that uses none of them: ZTP behaves as before, with the old values as defaults.

| New key | What it is for |
| --- | --- |
| `provisioning.simplified.isolate_san_adapters` | Turn the PCIe slots of `nodes[].san.hbas[]` off for the OS install and on in Restore. Default: true when a node lists `san.hbas`. |
| `provisioning.simplified.enable_embedded_nics` | Enable the embedded NICs when a management or provisioning port has `slot: Embedded`. Default true. |
| `nodes[].san.hbas[].type`; `ports` no longer required | `fibre_channel` (default) or `iscsi_offload`. ZTP needs only the `slot`. |
| `nodes[].san.hbas[].bios_attribute`, `bios_disabled_value`, `bios_enabled_value` | The adapter's own BIOS attribute, for a vendor ZTP has no mapping for or a label that is not `Slot <n>`. |
| `provisioning.simplified.create_resource_group`, `configuration_name`, `managed_resource_group_name`, `apply_site_settings`, `use_key_vault_configuration`, `assign_provisioning_roles`, `assign_hci_rp_role`, `network_kind`, `ntp`, `site_mode`, `deployment_name` | The Microsoft.Edge site and its configuration. Defaults: what ZTP created before. |
| `provisioning.simplified.timeouts.*` (5.4.1 adds `adapters_minutes`, default 10), `retry_provision_os`, `skip_azure_check`, `include_preview`, `max_train` | Stage budgets and the Resolve and Ready choices. Defaults: the values ZTP used. |
| `provisioning.simplified.usb_image`, `maintenance_environment`, `media_share.account_name`, `media_share.keep` | The USB image size and name, the Configurator service's port and user, the share account. |
| `hardware.bmc.rfs_write_attribute`, `hardware.bmc.verify_certificate` | The iDRAC Remote File Share attribute (default: true for Dell only) and the BMC certificate check (default false). |

**What changes in behaviour.** A file that lists `nodes[].san.hbas` with `provisioning.simplified` now gets the slot turned off for the OS install without a raw `bios_during_provisioning`. If you already wrote the raw attribute, it wins and the result is the same. If the vendor has no slot mapping in ZTP and the file has no raw `bios_during_provisioning`, ZTP stops before it touches the hardware and says which. A slot label that is not `Slot <n>` is AZL-029 (an error) unless `isolate_san_adapters` is false.

**Steps for a 5.3 file:** set `_metadata.schema_version` to `5.4.0`; list each machine's SAN adapters in `nodes[].san.hbas[]` and give the network ports a `slot`; you may then delete the raw `Slot` and embedded-NIC attributes from `bios` and `bios_during_provisioning`, or keep them as explicit overrides; run `Test-InfrastructureFile.ps1`. AZL-029 checks the new keys.

## To 5.4.2: how the SBE package reaches the nodes

Schema 5.4.2 only adds two optional keys; every 5.0 to 5.4.1 file stays valid. Set `_metadata.schema_version` to `5.4.2` to use them.

| New key | What it does |
| --- | --- |
| `hardware.sbe.delivery` | `winrm_copy`, `node_pull` or `skip` (default). How OS configuration puts the SBE package from `hardware.sbe.bundle_path` into each node's `C:\SBE`. |
| `hardware.sbe.node_pull_url` | With `node_pull`: the read-only HTTPS (or UNC) folder the nodes download the three SBE files from. No credential in the address (rule AZL-030). |

**What changes in behaviour.** The staging storage account route is gone: `Set-AzureLocalNodeConfiguration.ps1` no longer takes `-StagingStorageAccount` or `-StagingContainer`, and nothing is uploaded to Azure. Before, a WinRM run copied the package by default and an Arc run needed a storage account. Now nothing is delivered unless `delivery` says how (`skip` is the default), the Sbe step runs last, and a package that is not delivered is reported without failing the other steps. If you used the WinRM transport to copy the package, set `delivery: winrm_copy`. If you passed `-StagingStorageAccount`, serve the SBE folder read-only from a host the nodes can reach and set `delivery: node_pull` and `node_pull_url`.

## Registry 5.0.2: the SBE is optional (no schema version change)

`hardware.sbe` was never a required key, but rule AZL-015 asked simplified provisioning for `hardware.sbe.bundle_path`. That is gone: **no `hardware.sbe` means deploy without a Solution Builder Extension** (the OS keeps the OEM drivers already installed; Microsoft Learn: the SBE is used only if the hardware partner provides one). A 5.x file stays valid as it is.

| If your file | Then |
| --- | --- |
| has no `hardware.sbe` | Valid. AZL-032 says so as an Info. The OS configuration run has nothing to do for the Sbe and Drivers steps and the ARM deployment passes no SBE parameter. |
| has `hardware.sbe` | It must be complete: `bundle_path` (publisher, family and version are read from the package), or `publisher`, `family` and `version` for an SBE you placed in `C:\SBE` yourself (a `ztp` file needs `bundle_path`). Otherwise AZL-015 is an error. |

**Opt-in only.** Nothing adds a `hardware.sbe` block, and no tool sets `hardware.sbe.delivery` for you: `skip` stays the default and a block with no `delivery` copies nothing. A package is delivered to `C:\SBE` only when you set `delivery` to `winrm_copy` or `node_pull`.

## To 5.4.3: the OS configuration switch

Schema 5.4.3 only adds one optional section; a 5.4.0 file is valid as it is. Nothing changes for a file that does not use it: leftover local storage is reported as blocking and nothing is wiped.

| New key | What it is for |
| --- | --- |
| `os_configuration.clear_storage` | `true`: the OS configuration run (`Invoke-AzureLocalOsConfiguration.ps1`) wipes leftover storage pools, virtual disks and the data on non-boot, non-system local disks in Apply mode. Default `false`. |

**Steps for a 5.4 file:** set `_metadata.schema_version` to `5.4.3`; add `os_configuration: { clear_storage: true }` only for machines that are re-used. Plan mode prints the wipe list; Apply never wipes a SAN LUN, a USB disk, or a boot or system disk.

## To 5.4.4: the guarded network change and the transport

Schema 5.4.4 adds optional keys only; every 5.4.3 file stays valid, and a file that sets none of them behaves as before.

| New key | What it is for |
| --- | --- |
| `os_configuration.network.confirm_minutes` (default 10), `stable_seconds` (default 60) | The commit-confirmed window of a guarded network change: the change is undone unless the node answers on the new address and stays stable. |
| `os_configuration.remoting.transport` | `winrm` (default), `winrm_https` or `arc`: how the run reaches the nodes. |
| `os_configuration.remoting.bootstrap_transport` | `none` or `arc`: whether the one-time Arc bootstrap may open WinRM. (5.6 adds `smb` and `auto`.) |
| `os_configuration.remoting.allowed_source_cidrs` | Runner and jump server addresses, as the nodes see them. |

See [Changing the management address safely](../../../docs/os-configuration-and-arm-deployment.md#changing-the-management-address-safely). **Steps:** nothing is required. To use the keys, set `_metadata.schema_version` to `5.4.4` or later.

## To 5.5: the domain join

Schema 5.5 only adds optional keys; a 5.4 file is valid as it is, and needs no new key to be joined: with `scenario.identity: active_directory` the OS configuration now joins each machine to the domain and to `identity.active_directory.ou_path` (the `DomainJoin` step, after Network, DNS, Time and Hostname) before the cluster validation and the deployment, **with the LCM user** (`identity.active_directory.lcm_user`). Microsoft's Active Directory preparation (`New-HciAdObjectsPreCreation`) gives that user the right to create and delete computer objects in the dedicated OU, and it is the account Microsoft uses for domain-join actions such as adding or repairing a node. Before, the machines stayed in a workgroup until the deployment.

| New key (all optional) | What it is for |
| --- | --- |
| `identity.active_directory.domain_join_account.username` / `.password` | Override: join with another account (same rights on `ou_path`) instead of the LCM user. The password is a `keyvault://<vault>/<secret>` reference. |
| `identity.active_directory.join_options.rename_after_join` | Fixed to `false`: the machine gets its final name first (the Hostname step) and is never renamed after the join. |
| `identity.active_directory.join_options.allow_ou_move` | Default `false`. `true`: **before the deployment**, a machine already in this domain but in another OU is moved into `ou_path`. Microsoft does not support moving the computer objects after the deployment, so a machine that is already in a cluster is blocked, never moved. |
| `identity.active_directory.local_admin_members` | Domain users and groups (names without the domain) added to the local Administrators group of every machine after the join and the restart. Default: the `security_groups` entry whose `purpose` says it administers the instance, and the LCM user. |

Rules: AZL-050 (an AD design has a join credential: the LCM user with a Key Vault password, or `domain_join_account`; the LCM user name is valid for Azure Local and differs from the local administrator), AZL-051 (`ou_path` is a valid distinguished name inside `domain_fqdn` without `& " ' < >`), AZL-052 (`domain_controllers`, when set, are the DNS servers of the management port), AZL-053 (warning: local identity with `domain_join_account` or `local_admin_members`).

**Steps for a 5.4 file:** nothing is required. Make sure the OU in `ou_path` is the dedicated one with Group Policy inheritance blocked (what `New-HciAdObjectsPreCreation` creates): the OS configuration reads it and blocks the join on a production, dev or dmz design when inheritance is not blocked. Set `_metadata.schema_version` to `5.5.0` to use the new keys.

## To 5.5: the CI/CD infrastructure in devops

Schema 5.5 adds optional keys to `devops`, so a 5.4 file stays valid. They are the inputs of tasks 01 to 06 of automation / 01-cicd-infra (`scripts/deploy/01-cicd-infra`).

| Earlier shape | Schema 5.5 |
| --- | --- |
| `cicd.project.name`, `cicd.organization.url`, `cicd.repository.name` (the automation pages' `variables.yml` paths, never in the registry) | `devops.project`, `devops.url`, `devops.organization`, `devops.repository.name` |
| `cicd.project.default_branch`, `branch_policy`, `pipeline_path` | `devops.repository.default_branch`, `devops.settings` (`required_approvals`, `squash_only`, `secret_scanning`, `resolve_conversations`, `required_status_checks`, `reviewers`) |
| `cicd.environments[].name`, `approval_required`, `approvers` | `devops.environments[]`: `name`, `approval_required`, `approvers`, `wait_minutes`, `deployment_branch` |
| `identity.service_principal.app_id`, the client secret | `azure.automation_identity` (name, `client_id`) and `devops.authentication` (`method`: `oidc` or `client_secret`, `client_secret` as a Key Vault reference, `roles`) |
| `cicd.runners.pool_name`, `image`, `count` | `devops.runners[]`: `name`, `os_type`, `purpose` (`general` or `ztp`), `count`, `compute_type`, `size`, `labels`, `registration_secret`, `pool`, `subnet`, `private_ips`, `data_disk_gb` |
| (no equivalent) | `devops.runner_network` (VNet, `hub_peering`, `reachable_cidrs`, `bmc_cidrs`), `devops.runner_access` (resource groups, RBAC Administrator, Arc Run Command, vaults), `devops.subscription`, `devops.resource_group`, `devops.api_token`, `devops.state.key` |
| `devops.runner` (one runner, 5.0 to 5.4) | Still read when `devops.runners` is absent. `devops.runners` replaces it. |

## To 5.6: the deployment block and the remote management security profile

Schema 5.6 only adds optional keys: every 5.0 to 5.5 file stays valid. It adds two things: the `deployment` block for the ARM Validate and Deploy run, and the remote management security profile of the OS configuration run (environment class, remoting profiles). **One behaviour changes for a file that sets nothing:** a missing `scenario.environment_class` means `production`, so the OS configuration run applies the strict profile (HTTPS, sources only from the management and out-of-band networks and `allowed_source_cidrs`, no TrustedHosts wildcard). A lab that relied on open access must say so with `environment_class: lab`.

### The deployment block

Schema 5.6 adds one optional section, `deployment`, for the toolkit's ARM Validate and Deploy run (`Invoke-AzureLocalArmDeployment.ps1`; see [docs/arm-deployment-guide.md](../../../docs/arm-deployment-guide.md)). A file without the section behaves as before, with the defaults shown below.

| Key | Default | Meaning |
| --- | --- | --- |
| `deployment.validate_timeout_minutes` | 90 | How long the run waits for a Validate |
| `deployment.deploy_timeout_minutes` | 360 | How long the run waits for a Deploy |
| `deployment.poll_seconds`, `poll_max_seconds` | 15, 120 | First and longest delay between status reads (the delay grows by half each read) |
| `deployment.approval` | `stop` | `ValidateAndDeploy`: `stop` ends after a good Validate, `prompt` asks, `none` continues |
| `deployment.resume` | `false` | Allow a failed Deploy to be resubmitted |
| `deployment.require_os_configuration_report` | `false` | A missing OS configuration report fails a precondition instead of being skipped |
| `deployment.skip_preconditions` | none | Preconditions to skip on purpose (reported as Skipped) |
| `deployment.acknowledge_known_issues` | none | Known issue ids you accept (`config/known-issues/arm-deployment.json`) |
| `deployment.deployment_settings_api_version` | the template's | Patch Microsoft's template api-version |
| `deployment.solution_version`, `deployment.sbe_catalog_path` | derived, the catalog in `hardware.sbe.bundle_path` | The precondition `SbeValidatedWithSolution` (registry 5.0.1) |
| `deployment.register_resource_providers` | `false` | Opt in: register the mandatory resource providers that are missing (registry 5.0.3) |
| `deployment.pre_cluster_verification_max_age_hours`, `pre_cluster_verification_report_directory` | 4, the environment data folder | The pre-cluster verification gate (registry 5.0.7) |
| `deployment.verification_min_memory_gib`, `verification_min_boot_disk_gb`, `verification_min_data_disk_gb`, `verification_min_link_gbps`, `verification_max_clock_skew_seconds` | 32, 200, 500, 10, 300 | The node checks of the gate (registry 5.0.9) |

**Steps:** nothing is required. To use the block, set `_metadata.schema_version` to `5.6.0` and add the keys you want. AZL-040 checks them.

### The remote management security profile

| New key | What it does |
| --- | --- |
| `scenario.environment_class` | `lab`, `test`, `dev`, `production` (default) or `dmz`. Picks the profile in `config/remoting-profiles.json`. |
| `os_configuration.remoting.transport`, `bootstrap_transport` | How the run reaches the nodes (`winrm`, `winrm_https`, `arc`) and whether the one-time Arc bootstrap may open WinRM (`none`, `arc`). |
| `os_configuration.remoting.allowed_source_cidrs` | Runner and jump server addresses, as the nodes see them. Added to the management and out-of-band networks. |
| `os_configuration.remoting.allow_any_source`, `trusted_hosts`, `use_https`, `isolation_confirmed`, `certificate` | Refine the class. `allow_any_source` and a wildcard `trusted_hosts` are honoured in `lab` and `test` only. |
| `networking.logical_networks[].purpose`, `networking.cluster_networks[].purpose` | `management`, `oob`, `automation`, `compute`, `storage` or `other`. `networking.vlans[].purpose` was already free text; its values `management` and `oob` (any case) now count too. |

New rules AZL-060 to AZL-068 (see README). **Steps for a 5.5 file:** set `_metadata.schema_version` to `5.6.0`; add `scenario.environment_class` (`lab` for an isolated lab, `production` otherwise); for `dev`, `production` and `dmz` list your jump servers in `os_configuration.remoting.allowed_source_cidrs`; for production and dmz, plan the HTTPS certificate (`os_configuration.remoting.certificate`, or the self-signed pre-join certificate and its trust procedure in `docs/os-configuration-and-arm-deployment.md`). To use the `deployment` block, add the keys you want; AZL-040 checks them.

## To 5.6.1, 5.6.2 and 5.6.3

- **5.6.1** adds `identity.active_directory.security_groups[].local_groups`. Nothing is required.
- **5.6.2: adapters are identified by hardware facts.** `nodes[].network_adapters[].mac_address` is now required. New optional keys: `port_index`, `pci_location` (`bus`, `device`, `function`), `vendor` (written by hardware discovery), `allowed_vlans` (the VLANs the switch port allows) and `os_name_override`. **Steps:** a file whose ports lack the MAC: run `Invoke-HardwareDiscovery.ps1 -UpdateInfrastructure` or add the MAC. Nothing else changes: without `os_name_override` no adapter is renamed and the deployment sends the name the node reports for the MAC. To get one name everywhere, add `os_name_override` per used port and run the OS configuration (step `NicNames`).
- **5.6.3** adds `enabled`, `ip_allocation_method` and `nsg_name` to `networking.logical_networks[]`. Nothing is required. A logical network uses `gateway` and `ip_pool`; the 4.0 names `default_gateway` and `ip_pools` belong to the deprecated `networking.onprem.logical_networks[]`.

## To 5.6.24: the partner properties and credentials of the SBE

Schema 5.6.24 adds two optional keys under `hardware.sbe`. Nothing is required: a 5.6.21 file is valid as it is.

- `hardware.sbe.partner_properties[]` (`name`, `value`): properties that the hardware vendor's Solution Builder Extension asks for. The ARM deployment passes them as `partnerProperties` (Microsoft Learn lists the parameter in every deployment template: a list of partner-specific properties, each a name and a value). Until now the deployment always sent an empty list, so a vendor that needs a property could not be served.
- `hardware.sbe.partner_credentials[]` (`secret_name`): the names of Key Vault secrets that the vendor's SBE needs while the deployment runs, for example the login of its download connector (`partnerCredentiallist`). The template reads each secret from the cluster's own Key Vault (`cluster.key_vault.name`), so create the secret there with the name the vendor gives before Deploy. The file holds the name, never the value.

Both are sent only when an SBE is configured (`hardware.sbe.version`); with none the deployment sends empty lists, as before. Leave both out unless the vendor's SBE documentation names a property or a credential.

Not keys, by decision (the values stay in the code with the source that fixes them, or are settings of the tool): the Redfish paths and the IPMI attribute of the Dell iDRAC scripts (Dell's iDRAC Redfish API), the BOSS volume label (`-VolumeName` of `Invoke-ResetBossVirtualDisk.ps1`), the WinRM ports, the NTP peer flag (`0x8`), the Kerberos clock limit, the folder `C:\SBE` and the node state folder, the firewall endpoint lists (Learn), the Azure API versions, the address of Microsoft's quickstart templates, and the waits and limits of the ARM run and its pre-cluster verification (the run settings `providerRegistrationTimeoutMinutes`, `providerRegistrationPollSeconds`, `deploymentNamePrefix` and the `verification*` limits, set with `-Settings` or `-ConfigPath`, not in the infrastructure file). `hardware.vendor` has no default any more: it is required, and an empty value stops the SBE and OEM steps with a message.

## To 5.6.23: hard-coded values of the discovery, Azure foundation and identity scripts

Schema 5.6.23 adds optional keys. Nothing is required: a 5.6.21 file is valid as it is.

- `landing_zone.networks[].allow_forwarded_traffic` (default `true`, what the script always set), `allow_gateway_transit` and `use_remote_gateways` (default `false`): the options of the virtual network peerings `Deploy-VirtualNetworks.ps1` makes (Microsoft Learn, Virtual network peering). A peering is made in both directions and each direction uses the options of the network it starts in. A hub that has the VPN gateway sets `allow_gateway_transit`; the spokes that use it set `use_remote_gateways`, and the peer must offer it.
- `identity.active_directory.precreate_computer_objects` (default `false`): `Set-ADConfiguration.ps1` creates the computer objects of the machines (`nodes[].name`) and of the cluster (`cluster.name`, disabled) in `ou_path` before the deployment. Microsoft Learn allows this instead of letting the deployment create them (Custom Active Directory configuration for your Azure Local instance; Prestage cluster computer objects).
- Scripts that read the file now: `Register-ResourceProviders.ps1`, `Register-ResourceProviders.azcli.ps1` and `Test-ResourceProviders.ps1` take `-InfrastructureFile` and the one provider list of the toolkit (`Get-AzlArmMandatoryProvider`, 13 providers; the three older copies had 12 and lacked `Microsoft.KeyVault`); `Set-ADConfiguration.ps1` prepares the dedicated OU and the LCM user with Microsoft's `New-HciAdObjectsPreCreation` (it took `-ClusterName`, `-NodeNames` and `-OUPath`, and created sub-OUs, a service account and fixed groups); `New-ADSecurityGroups.ps1` creates `identity.active_directory.security_groups[]`, the same list `Set-ADGroupMemberships.ps1` fills (it created fixed `GRP-<cluster>-*` names); `New-ADAccounts.ps1` creates `identity.active_directory.domain_join_account` (it created `svc-<cluster>` with a generated password that was not stored).
- Removed scripts that a schema 5 script replaces or that Microsoft does not document: `Set-RbacRoleAssignments.ps1` (phase 03 and task 02) and `Test-RbacRoleAssignments.ps1` (roles come from `identity.entra.groups[].roles`; `Set-EntraGroupRoleAssignments.ps1`), `New-DeploymentServicePrincipal.ps1` (`New-AutomationManagedIdentity.ps1` and the CI/CD bootstrap create the identity of `azure.automation_identity`), `New-PipelineSP.ps1` and `New-ArcOnboardingSP.ps1` (the same), `Add-KeyVaultCredentials.ps1` (it prompted for secrets of fixed names; `Deploy-KeyVaults.ps1` lists the secrets of the file that are missing and you set them with `Set-AzKeyVaultSecret`) and `Set-DnsForwarding.ps1` (conditional forwarders to 168.63.129.16, an address an on-premises DNS server cannot reach; Learn names host records for the machines, the cluster and its client access point instead, and the pre-cluster verification checks them).
- `keyvault-helper.ps1` no longer has `Set-SecretToKeyVault`, `Set-ServicePrincipalToKeyVault` and `Get-ServicePrincipalFromKeyVault` (they wrote and read secrets named `sp-<name>-appid` and `sp-<name>-secret`), and `Get-SecretFromConfig` builds the reference in the provider of `secrets.provider`.
- New script parameters (registered): `Invoke-HardwareDiscovery.ps1` `-SummaryFileName`, `-ProposalFileName`, `-TimeoutSeconds`, `-ConnectTimeoutSeconds`, `-MaxRetries`, `-RetryDelaySeconds`, `-NodeBudgetSeconds`, `-MaxMembers`; `Inventory-AzureTenant.ps1` `-BaseName`; `Register-ResourceProviders.ps1` `-Wait`, `-MaxWaitMinutes`, `-PollSeconds`.
- Terraform: the variables the generator feeds from the file have no literal default in the `.tf` files any more (`vpn_config.sku`, `bastion_config.sku`, `nat_gateway_idle_timeout`, `enable_nat_gateway`, `spn_subscription_roles`, `log_analytics_retention_days`, `vm_admin_username`, `windows_server_sku` and the same variables of the modules); `New-IacVariableFiles.ps1` writes them from `landing_zone.connectivity`, `devops.authentication.roles`, `operations.monitoring.retention_days` and `landing_zone.virtual_machines[]`. The management group display names of the landing zone module come from `landing_zone.management_groups[].display_name` (the name when there is none). The VPN gateway generation follows the SKU in the module, and the Key Vault network rules follow `key_vault_allowed_ips` (the cluster vault keeps the Azure default).
- Not keys (named constants with their source in the scripts): the VPN gateway type `Vpn`, the route-based VPN type and the AZ SKU family; the Key Vault SKU `Standard` and Azure RBAC; the list of environment classes whose vaults have no purge protection; the iDRAC attribute `IPMILan.1#Enable`; the vendor adapters that exist; the Log Analytics pricing tier `PerGB2018`; the three Key Vault roles of the deployment identity in the Terraform identity module.

## To 5.6.21: security groups of the landing zone, security baseline settings, and readers for keys nothing read

Schema 5.6.21 adds optional keys. Nothing is required: a 5.6.19 file is valid as it is.

- `landing_zone.network_security_groups[]` (`name`, `rules[]`: `name`, `priority` 100 to 4096, `direction`, `access`, `protocol`, `source_address_prefixes`, `source_port_ranges`, `destination_address_prefixes`, `destination_port_ranges`, `description`): the network security groups of the Azure virtual networks of the landing zone. `New-LandingZoneNsg.ps1` (Azure foundation, phase 04, manual deployment, task 06) creates each group in the subscription, resource group and region of every network whose subnets name it in `landing_zone.networks[].subnets[].network_security_group`, and adds the rules that are missing. Run it before `Deploy-VirtualNetworks.ps1`, which attaches a group to a subnet by name and looks it up in the resource group of the network. A rule takes lists, and one service tag at most (Microsoft Learn, Azure network security groups overview). These are not the Azure Local groups of `networking.network_security_groups`. The Terraform variable `nsgs` had this key as its proposed key; it now comes from it (the Terraform module takes one value in each address and port field, so a rule with a list of several values is refused when the Terraform files are written).
- `security.baseline_settings[]` (`type`, `name`, `value`, `acknowledge_weaker_security`): the individual settings of the security baseline that `Set-SecurityBaselines.ps1` (stage 05, phase 04, task 03) changes with `Set-AzsSecurity -Cluster`, the only supported way from Azure Local 2610 (Microsoft Learn, Manage security defaults for Azure Local). The script was rewritten to this: the earlier version checked eight fixed settings, wrote a report and could not change anything. It refuses the settings Learn lists as blocked, and it does not turn drift control off. The features `Enable-AzsSecurity` and `Disable-AzsSecurity` switch (Credential Guard, HVCI, DRTM, SMB signing, SMB cluster encryption) stay the keys under `security` that the deployment reads.
- Readers for keys that nothing read: `landing_zone.resource_groups[]` (`name`, `subscription`, `location`, `purpose`) by `Deploy-ResourceGroups.ps1` (rewritten; it read `azure_infrastructure.resource_groups`, which no file has); `identity.active_directory.security_groups[].members` by `Set-ADGroupMemberships.ps1` (rewritten; it built fixed group names `GRP-<cluster>-...` from parameters); `operations.licensing.azure_hybrid_benefit` by `Enable-AzureHybridBenefit.ps1` (rewritten: Azure Hybrid Benefit for Azure Local is a setting of the instance, `Invoke-AzStackHciExtendClusterSoftwareAssuranceBenefit -SoftwareAssuranceIntent Enable`, and cannot be undone; the earlier script set the license type of the Arc machines); `network_devices[]` (`hostname`, `type`, `role`, `vendor`, `management.ip_address`, `management.protocol`, `credentials.username`, `credentials.password`) by `Set-PowerSwitchEndpoint.ps1` and `Test-OpengearVerification.ps1`, which now only check each device (address, management port, that the password reference can be read); `site.customer`, `cluster.name`, `azure.subscription_id` and `azure.resource_group` by `Set-CustomerTransfer.ps1` and `New-DeploymentDocumentation.ps1` (they took them as parameters; `-ClusterName`, `-CustomerName`, `-AzureSubscriptionId`, `-ResourceGroup` and `-ConfigFile` are gone, use `-InfrastructureFile`); `nodes[].name`, `nodes[].management.ip_address` and `landing_zone.virtual_machines[]` by `New-IacVariableFiles.ps1`, which now also writes `ansible/inventory/hosts.yml`; `nodes[]` and `nodes[].arc_machine_name` by `Invoke-SSHConnectivity-Orchestrated.ps1` (it read `compute.cluster_nodes` and `arc_resource_id`).
- Ansible connection settings (`ansible_connection`, `ansible_winrm_transport`, `ansible_winrm_server_cert_validation`, `ansible_port`) are registered under `tools.ansible.variables` (`src/ansible/inventory/hosts.yml`, target `inventory`), not as keys of the file. The certificate validation default is `ignore`: a security choice of the code.
- Not keys: `nodes[].bmc.mac_address` and `networking.dhcp.server`. Microsoft Learn recommends DHCP reservations for the node addresses (Network considerations for cloud deployments of Azure Local, Decision 8) but names no Azure Local step for them, the DHCP server is the network team's and may not be a Windows server, and the BMC reservations are not in Learn at all. `networking.management.ip_assignment: dhcp` already says to reserve each `ip_address` for its MAC. The DHCP reservation scripts were removed in 5.6.19 and are not rebuilt. `hardware.bmc.settings`: the BMC (iDRAC) baseline of `Test-BiosIdracSettings.ps1` and `Set-BiosIdracSettings.ps1` is one fixed vendor attribute (IPMI over LAN enabled) that Learn does not document; no deployment chooses it, so it is not a key. `provisioning.iso.path`: `provisioning.iso.image_uri` (5.6.19) is the one key for the location of the OS ISO.
- Removed: `Set-OpengearEndpoint.ps1`. It wrote serial ports (mode, baud rate), alerts and users to a console server from keys the registry does not have; configuring the console server is the vendor's work.

## To 5.6.19: older scripts follow the registry

Schema 5.6.19 adds optional keys. Nothing is required: a 5.6.16 file is valid as it is. The older scripts under `scripts/deploy` read keys of the old layout (`compute.nodes`, `cluster.nodes`, `azure.*` names of the 4.0 file) or carried values in the code. They read the keys below now, or they were removed because a schema 5 script does the same job.

- `provisioning.iso.image_uri`: the address (http, https, nfs or cifs) the BMC fetches the OS ISO from. `Invoke-MountGoldImageISO.ps1` (phase 04, cluster deployment, OS installation, task 02) inserts it as the virtual CD of every machine of `nodes[]`, over the BMC address `nodes[].bmc.ip_address`. It replaces `cluster.gold_image_iso_path`; the BOSS reset script reads `nodes[].bmc.ip_address` too (it read `cluster.nodes` and `idrac_ip`).
- `landing_zone.subscriptions[].billing_scope` and `.workload`: how `Deploy-Subscriptions.ps1` (Azure foundation, phase 01, task 02) creates a subscription that has no `id`: with a subscription alias, under the billing scope of your agreement (an enrollment account, an invoice section or a customer; Microsoft Learn, Programmatically create Azure subscriptions) and the workload type `Production` (default) or `DevTest`. An entry with an `id` is an existing subscription and is skipped. The script puts the subscription under the entry's `management_group` in the same call.
- `landing_zone.connectivity.vpn_gateway.point_to_site.protocols` (OpenVPN, IkeV2, SSTP), `.root_certificate_name` and `.root_certificate` (a secret reference to the public data of the root certificate): what `Configure-P2sVpn.ps1` (task 04) needs for sign-in with a certificate. Sign-in with Microsoft Entra ID needs none of them (OpenVPN only, tenant from `azure.tenant_id`). RADIUS is not built. They replace `azure.vpn_gateway.*`.
- `landing_zone.connectivity.bastion.network`: the virtual network of the Bastion host (an entry of `landing_zone.networks` with an `AzureBastionSubnet` of /26 or larger), read by `New-AzureBastion.ps1` (task 05).
- `landing_zone.connectivity.nat_gateway` (`name`, `resource_group`, `network`, `subnets`, `idle_timeout_minutes` from 4 to 120): the NAT gateway `New-NatGateway.ps1` (task 07) creates and attaches to the listed subnets.
- `landing_zone.virtual_machines[].os` takes `windows_server_2022`, `windows_server_2025` or `ubuntu_2404`. `Deploy-ManagementVMs.ps1` (task 11) creates every entry whose `deploy_target` is `azure` (it built five fixed machines from `azure.management_vms`). It replaces the role scripts of tasks 12 to 15.
- Not keys: the Azure VPN Client application ID that Microsoft Entra ID sign-in uses as the audience (fixed by Microsoft), the Bastion features other than the SKU and its scale units (Azure defaults), the IKE settings of a site-to-site connection (Azure defaults) and the OS disk type of a management machine (the Azure default for the size). The Marketplace images behind the three `os` values are fixed by their publishers.
- Removed scripts that a schema 5 script replaces: `Deploy-ManagementGroup.ps1` and `Deploy-Subscription.ps1` of the simplified deployment (a file with one entry gives the same result), `Test-Connectivity.ps1` and `Test-Configuration.ps1` of the pipeline validation (they read `azure.networking` and `azure.key_vault`, which have no key; the pre-cluster verification checks Key Vault and secrets), `Deploy-ManagementVnet.ps1`, `Deploy-Network.ps1`, `New-VirtualNetwork.ps1`, `Configure-VnetDns.ps1` and `Deploy-VnetPeering.ps1` (`Deploy-VirtualNetworks.ps1` creates networks, subnets and peerings; the DNS forwarders of the domain controllers have no key), `New-VpnGateway.ps1` (`Deploy-VpnGateway.ps1`), `New-LogAnalyticsWorkspace.ps1` and `Deploy-DiagnosticSettings.ps1` (the workspace is `Deploy-LogAnalyticsWorkspace.ps1` of phase 05; diagnostic settings are outside the Azure Monitor scope of the toolkit), `New-KeyVault.ps1` (`Deploy-KeyVaults.ps1`), `Deploy-LighthouseNsg.ps1`, `New-DomainController.ps1`, `Deploy-JumpServer.ps1`, `New-NdmServer.ps1` and `Deploy-Lighthouse.ps1` (the machines come from `Deploy-ManagementVMs.ps1`; the Lighthouse rules for a vendor appliance have no key), `Set-NsgConfiguration.ps1` of the SDN phase (`New-NetworkSecurityGroup.ps1` creates the Azure Local network security groups from `networking.network_security_groups[]`), the two DHCP reservation scripts (no key names the DHCP server, the scope or the BMC MAC address), `Test-DnsClientConfig.ps1` (`Test-DnsConfiguration.ps1`), the two `Register-AzureLocalArc` snippets with REPLACE_ values (`Register-AzureLocalArc-Remote.ps1`), and the four `-Standalone` scripts of phase 06 with an embedded configuration (the Orchestrated script of each task).
- `hardware.idrac_settings` and `hardware.bios_settings` are gone: `Test-BiosIdracSettings.ps1` and `Set-BiosIdracSettings.ps1` read `hardware.bios` and `nodes[].bios`. The iDRAC attribute baseline (IPMI over LAN enabled) is fixed in the scripts.


## To 5.6.20: updates after the deployment, and keys that no tool reads

Schema 5.6.20 adds two optional keys and removes the keys listed below. A 5.6.17 file is valid as it is, unless it holds a removed key: delete that key (the validator names it as an unknown key).

Added. `scripts/lifecycle/updates/powershell/Start-SolutionUpdateAfterDeployment.ps1` reads both keys.

- `operations.updates.install_after_deployment`: `true` starts the solution update after the deployment. Default `false`.
- `operations.updates.target_version`: `latest` (default) or a solution version such as `12.2610.1004.50`.

The script checks the health of the update environment, starts the update with `Start-SolutionUpdate` and returns. It does not wait: an update takes hours and the machines restart. It reports, and starts nothing, when the switch is off, when the instance runs the target version, or when an update is already running. `-WhatIf` shows the plan. Sonar follows the run. Learn: Update Azure Local by using PowerShell.

Read now (no new key):

- `networking.outbound.proxy.url` and `.bypass`, `networking.outbound.private_path.firewall_private_ip`, `.firewall_port` and `.proxy_bypass`, and `deployment.solution_version`. The OS configuration passes them to `Invoke-AzStackHciArcInitialization` as `-Proxy`, `-ProxyBypass` and `-TargetSolutionVersion`. The private path uses `http://<firewall_private_ip>:<firewall_port>` as the proxy and passes the Arc gateway too. A path that needs a value the file does not give is Blocked in the plan.
- `site.time_zone`. The Time step sets it with `Set-TimeZone`, only when it differs. An empty key leaves the zone alone.

Checked on Learn and in Microsoft's templates, and not added:

- `security.hvci`, `security.drtm`, `security.side_channel_mitigation`. Microsoft's quickstart templates set `hvciProtection`, `drtmProtection` and `sideChannelMitigationEnforced` to `true` inside the template; they are not template parameters. Learn lists Credential Guard, Application Control, BitLocker, SMB signing and SMB cluster encryption and drift control as the settings you configure during the deployment. HVCI, DRTM and side channel mitigation can only be switched after the deployment (`Enable-AzsSecurity`, `Disable-AzsSecurity`). Every other `securitySettings` property of the template has a registered key that is read.
- `storage.san.iscsi.chap.mutual_secret`. The `create-cluster-san-iscsi` template takes `chapType` (`None`, `OneWay`, `Mutual`), `chapUsername` and `chapCredential`. Its description says that with `Mutual` the same single credential is used for both directions. `storage.san.iscsi.chap.mutual` stays as it is.
- A disk witness (`cluster.witness.type: disk` and a witness LUN). No SAN quickstart template takes one: `witnessType` allows `Cloud` and `No Witness`. The ARM reference has `witnessLunId`, and the rack aware SAN article selects a disk witness in the portal and adds the disk after the deployment.

Documentation only (kept; the description says "Documentation only; not read by the tools"):

- A design record that a person fills in: `networking.oob.gateway` and `.vlan_id`, `provisioning.iso.image_source`, `networking.outbound.private_path.transport`, `virtual_network`, `workload_subnet`, `firewall_subnet` and `arc_private_link_scope`, `landing_zone.connectivity.firewall.*`, `nodes[].rack`, `nodes[].network_adapters[].port_index`, `.vendor`, `.rdma` and `.switch_port.description`, `network_devices[].serial_number`, `.firmware_version`, `.management.vlan_id`, `.ha.enabled` and `.ha.mode`, `storage.san.fibre_channel.fabrics[].name` and `target_wwpns[].wwpn` and `.fabric`.
- Keys that Trailwright writes, so they stay: `scenario.deploy_method`, `hardware.network_cards[].*`, `environment.name` and `.type`, `networking.storage.switchless_links`, `.tor_switches` and `.layout`, `landing_zone.log_analytics.name`, `hardware.sbe.allow_unvalidated`, `operations.update_method`.

`hardware.sbe.allow_unvalidated` changes nothing: the deployment gate fails an SBE the OEM has not validated, whatever the key says. The validator (AZL-013) no longer warns about it.

Removed:

| Key | Why, and what to use |
| --- | --- |
| `landing_zone.resource_providers` | Microsoft fixes the list of resource providers. `deployment.register_resource_providers` is the choice. |
| `identity.entra.break_glass_accounts`, `identity.break_glass_account_ids` | Emergency access accounts belong to conditional access and PIM, which are out of scope. |
| `identity.managed_identities.*` (eight keys) | The old layout. The one identity the toolkit uses is `azure.automation_identity.*`. |
| `landing_zone.log_analytics.resource_group`, `.retention_days` | Use `operations.monitoring.workspace_resource_group` and `.retention_days`. |
| `compute.vms.management.dc1`, `dc2`, `jumpbox` and `wac`: `azure_vm_<vm>_image_sku`, `azure_vm_<vm>_os_disk_type` | The old layout. The image SKU is `landing_zone.virtual_machines[].os`. |
| `identity.active_directory.service_accounts[]` (`name`, `purpose`, `password`) | Learn names one account for Azure Local, the deployment user (`identity.active_directory.lcm_user`). |
| `identity.accounts.account_ad_domain_admin_username`, `_password`, `identity.accounts.idrac_vnc_*` (five keys) | The old layout. Use `identity.active_directory.domain_join_account`. |
| `provisioning.iso.image_version` | Repeats `provisioning.os_version`. |
| `identity.active_directory.join_options.rename_after_join` | Fixed: the machine gets its final name before the join and is never renamed after it. |

Kept although no tool reads them: `environment.env_name`, `.env_type`, `.env_owner` and `.env_description` (the schema of the old `variables.yml`, `variables.schema.json`, requires `env_name`), and `identity.active_directory.security_groups_by_role.*` (a deprecated alias that expires on 2027-05-07; `alias-policy.json` and its test hold it until then). Removing them needs the old `variables.yml` layout to go first.

Left for the pass over the scripts under `scripts/deploy`: `provisioning.iso.path`, `nodes[].bmc.mac_address`, `networking.dhcp.server` and `hardware.bmc.settings`. Their readers are there.
## To 5.6.17: the Terraform and Ansible variables come from the file

Schema 5.6.17 adds two optional keys. A 5.6.16 file is valid as it is. You need them only when you use the Terraform route (`src/terraform/environments/azure-local`).

- `landing_zone.management_groups[].role`: which group of the fixed hierarchy the Terraform landing zone module builds (`root`, `platform`, `identity`, `connectivity`, `management`, `security` or `landing_zones`). The generator takes the names from the groups that carry a role.
- `azure.automation_identity.object_id`: the object ID of the identity's principal. The Terraform identity module assigns the roles of the deployment identity to it.
- `landing_zone.virtual_machines[].os` is read as the Windows Server image SKU of the Azure Marketplace (for example `2025-datacenter-azure-edition`) for a machine that Terraform deploys.
- The Terraform and Ansible code no longer has values of its own for these facts. `config/variables/scripts/New-IacVariableFiles.ps1` writes `terraform.tfvars.json` and `backend.hcl` for each Terraform environment, and `group_vars/all.yml` and `host_vars/<node>.yml` for Ansible, from your file. See [Terraform and Ansible variable files](infrastructure-file.md#terraform-and-ansible-variable-files-schema-5617).
- Removed from the code, not from the file: the Terraform backend names built from `org_code` and `environment` (`devops.state` names them now), the cluster health alert rule of the Terraform monitoring module and the data collection rule of the Ansible monitoring-agents role (Azure Monitor work is the workspace, the data collection endpoint, the Azure Monitor Agent extension and the Azure Local Insights association), and the PowerShell functions `Export-TerraformTfvars` and `Export-AnsibleVars`, which wrote the whole old `variables.yml` to a file.

## To 5.6.16: SAN volumes, and keys that no tool reads

Schema 5.6.16 adds one optional key and removes one. A 5.6.14 file is valid as it is, except that it must not carry `security.backup_key_vault`.

- `storage.san.luns[].unique_id`: the UniqueId of the disk the LUN shows on the machines, as `Get-Disk` reports it (Microsoft Learn: use UniqueId as the authoritative identifier; disk numbers differ between machines). `New-SanVolume.ps1` (phase 06, task 05) finds the disk of a LUN only by this value. It never picks a disk by size or number, and it does nothing to a LUN that has no `unique_id`. Leave `storage.san.luns` out if you do not use the script.
- `storage.san.luns[].name`, `size_gib` and `lun_id` are now read by the same script. `name` becomes the name of the cluster disk and of the CSV. `size_gib` and `lun_id` are cross-checks: a disk whose size differs by more than 1 percent, or that shows another LUN number, is refused.
- **Removed: `security.backup_key_vault`.** No tool read it, and the toolkit names no Key Vault: the deployment keeps the BitLocker recovery keys in its own vault. Delete the key from your file (the schema refuses it).
- Four keys that no tool can act on now say so in their description (Documentation only; not read by the tools): `storage.san.array.name`, `storage.san.array.management_address`, `storage.san.fibre_channel.fabrics[].switch` and `storage.san.fibre_channel.fabrics[].zone_set`. Nothing else changed for them.
- The OS configuration no longer enables iSCSI before the deployment of a SAN-only design (`scenario.storage_architecture: san`, `storage.san.type: iscsi`) on Azure Local 2610 or later. Microsoft Learn says the deployment configures iSCSI from 2610 and the machines must not have it enabled by hand before. The release comes from `deployment.solution_version`, else the ZTP handoff; for a SAN-only iSCSI design with no known release the iSCSI item is Blocked until you set `deployment.solution_version` (for example `12.2610.1004.50`). A hybrid design and releases before 2610 are unchanged.

## To 5.6.15: SDN enabled by Azure Arc

Schema 5.6.15 adds two optional keys to `sdn`, removes one, and gives two more a job. Nothing is required: a 5.6.14 file is valid as it is, except that it must not carry `sdn.default_access_policy`. `sdn.enabled` still defaults to the off position (`false`).

Microsoft Learn (Enable SDN integration on Azure Local using PowerShell) documents two ways to run SDN. The toolkit builds only the first, SDN enabled by Azure Arc: the Network Controller runs as a Failover Cluster service and you manage logical networks, network interfaces of Azure Local VMs and network security groups from Azure. It is the supported route for a new instance (Azure Local 2506 or later, OS build 26100 or later). SDN managed by on-premises tools (SDN Express, Windows Admin Center, Network Controller VMs, with virtual networks, the software load balancer and gateways) is not built. Learn says not to mix the two, and virtual networks, the software load balancer and gateways are not supported with SDN enabled by Azure Arc.

- **`sdn.enabled: true` now turns SDN on.** `Enable-ArcSdn.ps1` (phase 06, task 01) runs `Add-EceFeature -Name NC` on a machine of the instance. **This cannot be undone.** Learn: once SDN is enabled you cannot roll back or disable it, and `false` does not switch it off. Enabling interrupts the network of running workloads for a short time, so plan a maintenance window. Do not set it where Network Controller was deployed with on-premises tools. Run the script with `-WhatIf` first.
- `sdn.prefix` is the SDN prefix (`Add-EceFeature -SDNPrefix`). Learn: at most eight characters, letters, digits and hyphens, no two hyphens in a row, no hyphen at the end. The schema also refuses a hyphen at the start. Required when `sdn.enabled` is true.
- `sdn.dns_records` is `dynamic` (Active Directory integrated DNS creates the record `<prefix>-NC`) or `static` (you create it first, pointing at the fifth address of `networking.management.infrastructure_pool`). Required when `sdn.enabled` is true. The script resolves the name on the machine and stops on a wrong answer.
- New `sdn.acknowledge_maintenance_window` (default `false`): your answer to the maintenance window confirmation of `Add-EceFeature`. The script enables SDN only when it is `true`.
- New `sdn.acknowledge_dns_record` (default `false`): your answer to the DNS confirmation, read only when `sdn.dns_records` is `static`.
- **Removed: `sdn.default_access_policy`.** Nothing read it. Learn sets the default network access policy for each VM network interface when the VM is created (none, basic or advanced), not for the instance. Delete the key from your file (the schema refuses it).
- The script refuses a design Learn does not support with SDN enabled by Azure Arc (exit 2): more than three intents, a compute and storage intent without management, a standalone compute intent on one machine, three intents on two or three machines with switchless storage, the group-all intent or five or more machines with switchless storage, and management plus compute without a storage intent on more than one machine.
- Not keys: the cmdlet name `NC` (Learn: no other value is allowed), the address of the DNS record (derived: the fifth address of the infrastructure pool), the intent pattern (derived from `networking.intents`), the Network Controller URL (derived: `<prefix>-NC.<domain>`), and the dynamic update setting of the DNS zone (a DNS server task; Learn: Secure only).
- Old-layout keys `networking.azure.sdn.sdn_enabled`, `sdn_prefix`, `sdn_dns_mode`, `sdn_nc_reserved_ip` and `sdn_intent_pattern` are gone from the registry. Use the `sdn` section above. `networking.azure.sdn.nsgs` is deprecated: use `networking.network_security_groups[]`. The keys `sdn_gateway`, `sdn_load_balancer` and `sdn_network_controller` stay because the older phase 05 scripts read them; they belong to SDN managed by on-premises tools, which is not built.
- Removed scripts in `04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn`: `Invoke-DeploySDN-Orchestrated.ps1`, `Invoke-ConfigureSDNDns-Orchestrated.ps1`, `Enable-SDN-Standalone.ps1`, `Set-SDNDns-Standalone.ps1`, `Get-VirtualSwitchName.ps1`, `Get-VirtualSwitchName-Standalone.ps1` and the Azure CLI placeholder. They read the unregistered old names, answered both confirmations with true without asking, and two carried values in the code. `Enable-ArcSdn.ps1` replaces them.

## To 5.6.14: hardware inventory

Schema 5.6.14 adds one optional block. Nothing is required: a 5.6.13 file is valid as it is.

- `hardware.inventory` (`output_directory`, `file_name_prefix`, `format`, `timeout_seconds`) tells `Get-HardwareInventory.ps1` where to write the hardware inventory, what to call it, which format to use (`json` or `yaml`) and how long to wait for a BMC. Leave the block out to use the defaults (`hardware-inventory`, `hardware-inventory`, `json`, 60 seconds).
- The script also reads keys that were already in the schema and compares them with what the BMC reports: `hardware.vendor`, `model`, `cpu_cores`, `memory_gib`, `gpu.enabled`, `gpu.model`, `gpu.count_per_node`, `drives.capacity` and `drives.cache` (`media`, `count`, `size_tb`), `nodes[].bmc.type` and `nodes[].serial_number`. These keys were documented placeholders that no tool read. They are still optional.
- The older scripts `Get-HardwareDiscovery-Standalone.ps1` and `scripts/common/discovery/Get-DellServerInventory-FromiDRAC.ps1` are removed. `Get-HardwareInventory.ps1` replaces them for every maker. `Invoke-HardwareDiscovery.ps1` stays for Dell: it writes the proposal for `nodes[]` and the serial numbers and MAC addresses back to the file.

## To 5.6.13: secret providers

Schema 5.6.13 adds an optional section and two kinds of secret reference. Nothing is required: a 5.6.10 file is valid as it is, and every `keyvault://` reference keeps working unchanged.

- The section `secrets` (`provider`, `file.directory`, `command.executable`, `command.arguments`, `command.timeout_seconds`) holds the settings of the providers other than Key Vault.
- Every key that holds a secret reference (format `kv_ref`) now also accepts `env://<VARIABLE_NAME>`, `file://<name>` and `command://<name>`. A `file://` or `command://` reference holds a name only; the directory and the command come from the `secrets` section. Rule `AZL-054` reports a reference whose setting is missing.
- One resolver, `scripts/common/secrets/AzlSecret.psm1`, reads all four. The ARM deployment already uses it. The other scripts still read Key Vault their own way until they are moved to it.
- `-SecretMode KeyVaultReference` accepts `keyvault://` references only, because Azure Resource Manager cannot read the other providers.

See [Secret references and providers](secret-references.md).

## To 5.6.12: Azure Monitor keys

Schema 5.6.12 adds one optional key and removes two. A 5.6.10 file is valid as it is, except that it must not carry `operations.notifications.teams_webhook` or `operations.monitoring.health_alerts`. Azure Monitor in the toolkit is only the Log Analytics workspace, the data collection endpoint, the Azure Monitor Agent extension and the association of the Insights rule.

- `operations.monitoring.retention_days` (30 to 730, default 30): the retention of the workspace `Deploy-LogAnalyticsWorkspace.ps1` creates. A workspace that exists is not changed. Retention beyond 31 days is charged by Azure.
- `operations.monitoring.data_collection_rule` is now read: `Enable-HciInsights.ps1` associates the rule with the Arc machine of every node. It never creates the rule: Microsoft Learn documents no template for the Insights rule and says not to build your own. Enable Insights once in the Azure portal (the instance, Capabilities, Insights, Get Started) and put the name of its rule in this key; the script stops with exit 1 until the rule exists.
- **Removed: `operations.monitoring.health_alerts`.** Nothing reads it: alerting beyond the existing action group is not part of the toolkit. Delete the key from your file (the schema refuses it). Turn on the health alerts of Azure Local in the Azure portal if you want them.
- **Removed: `operations.notifications.teams_webhook`.** Nothing read it. The alerting of Azure Local in Microsoft Learn is an action group with email receivers, and a webhook URL put in an action group is stored in the group in plain form. Delete the key from your file (the schema refuses it). To tell a Teams channel, add the address of the channel's mailbox to `operations.notifications.emails`.
- Old-layout keys (the `variables.yml` of registry 4.x) under `operations.monitoring` are gone from the registry: `monitoring_log_analytics_workspace_name` (use `log_analytics_workspace`), `monitoring_resource_group` (`workspace_resource_group`), `monitoring_enabled` (`enabled`), `monitoring_alert_action_group_name` (`action_group`), `monitoring_alert_email_receiver` and `monitoring_alert_email_addresses` (`alert_email` and `operations.notifications.emails`), `monitoring_performance_counter_sampling_frequency`, `monitoring_log_analytics_retention_days` (`retention_days`), `monitoring_windows_performance_dcr_name`, `windows_events_dcr_name` and the `monitoring_dcr_*` names (`data_collection_rule`: Insights has one rule). The event channels, counters and sample rate of Insights belong to the rule the portal creates and are not keys. The others (`monitoring_log_analytics_workspace_sku`, the agent switches, `monitoring_application_insights_name`, `monitoring_alert_severity_levels`, `monitoring_alert_webhook_receiver`, `monitoring_workspace`, `monitoring_metrics_retention_days`, the Linux syslog keys, `monitoring_dcr_destination_table`, `log_analytics.workspace_id`) describe something Learn does not offer as a choice for Azure Local, and nothing reads them.

`operations.monitoring.wac.server` and `operations.monitoring.extended.scom.server` stay: the parked Windows Admin Center task reads them. Their canonical names `monitoring_wac_server` and `monitoring_scom_server` are removed.

## To 5.6.11: network security groups, the virtual switch of a logical network, and VM images

Schema 5.6.11 adds optional keys. Nothing is required: a 5.6.10 file is valid as it is.

- `networking.network_security_groups[]` (`name` and `rules[]`: `name`, `priority` 100 to 4096, `direction`, `access`, `protocol`, `source_address_prefixes`, `destination_address_prefixes`, `source_port_ranges`, `destination_port_ranges`, `description` up to 140 characters): `New-NetworkSecurityGroup.ps1` creates each group and the rules it does not have. The script read the unregistered path `network.nsgs` before. Network security groups need `sdn.enabled: true` (the script does not turn SDN on) and every group needs at least one rule. Run it before `New-LogicalNetwork.ps1`.
- `networking.logical_networks[].vm_switch_name`: optional. Leave it out and `New-LogicalNetwork.ps1` uses the one external virtual switch the cluster reports; name it only when the cluster has more than one. `nsg_name` now has to name a group of `networking.network_security_groups` and needs `sdn.enabled: true`. The `-AssociateNsg` switch is gone: `nsg_name` decides. The script reads `gateway` and `ip_pool` (it read `default_gateway` and `ip_pools`). The keys `enabled`, `ip_allocation_method` and `nsg_name` of 5.6.3 were rejected as unknown keys by the schema; they are accepted now.
- `storage.vm_images[]` (`name`, `os_type`, `publisher`, `offer`, `sku`, `version`, `storage_path`): `New-VmImage.ps1` downloads each Azure Marketplace image that does not exist yet. It replaces the image catalogue that was written into `Get-ImageDownloads.ps1` and the old `marketplace_images` section (never part of the schema). Only Azure Marketplace images are supported.

## To 5.6.10: SAN deployment values

Schema 5.6.10 adds optional keys. Nothing is required for a Fibre Channel SAN or a Storage Spaces Direct file: a 5.6.9 file is valid as it is.

- `networking.cluster_network_properties` (`bandwidth_percentage_smb`, `jumbo_packet`, `priority_cluster`, `priority_smb`): the adapter properties of the SAN cluster networks. The defaults are the values the deployment sent before (50, 9014, 7, 3).
- An iSCSI SAN is now deployed from the file. It needs `storage.san.iscsi.networks[]` (one entry per path: `fabric`, `subnet`, and `vlan_id` and `next_hop` when they apply), a port with the role `iscsi:a` or `iscsi:b` and `san.initiator_iqn` on every node. Optional: `storage.san.iscsi.jumbo_packet` and `storage.san.iscsi.chap.mutual`.

## To 5.6.9: storage volumes and storage paths

Schema 5.6.9 adds optional storage keys. Nothing is required: a 5.6.8 file is valid as it is.

- `storage.volumes[]` is now read: `New-StorageVolume.ps1` creates each volume that does not exist yet. New optional keys per volume: `provisioning_type`, `file_system`, `parity_percent`, `media_type` and `deduplication` (`type`, `schedule`). `resiliency` gains `mirror_accelerated_parity` and `nested_mirror_accelerated_parity`.
- `storage.pool.name`, `storage.pool.thin_provisioning_alert_threshold_percent` and `storage.csv.read_cache_size_mib`: a setting you leave out is not touched.
- `storage.paths[]` (`name`, `path`): `New-StoragePath.ps1` creates each storage path that does not exist yet.

A file that still has `compute.cluster_shared_volumes` (never a registered key): move each volume to `storage.volumes[]` (`volume_name` becomes `name`, `size_gb` becomes `size_gib`, `filesystem` becomes `file_system` in lower case, `resiliency` Mirror or Parity becomes one of the listed values) and each storage path to `storage.paths[]`. The scripts that read the old block are removed.

## To 5.6.8: the security contact of Defender for Cloud

Schema 5.6.8 adds the optional key `security.defender_for_cloud.security_contact_email`. Nothing is required: a 5.6.7 file is valid as it is. `Enable-DefenderForCloud.ps1` sets the address as the security contact of the subscription when the subscription has none; it never replaces a contact that exists. The contact is free.

## To 5.6.7: the free level of Defender for Cloud

Schema 5.6.7 adds the optional section `security.defender_for_cloud` with `enabled` and `apply_cloud_security_benchmark` (both default true). Nothing is required: a 5.6.6 file is valid as it is. `Enable-DefenderForCloud.ps1` reads the section and turns on only the free level Azure Local needs: Foundational CSPM and the Microsoft cloud security benchmark assignment. No key of the file turns on a paid plan.

## To 5.6.6: the action group of the alerting task

Schema 5.6.6 adds the optional key `operations.monitoring.action_group` (the name of the Azure Monitor action group). Nothing is required: a 5.6.5 file is valid as it is. The alerting task of the operational foundations (`Deploy-ActionGroup.ps1`) reads it, with `operations.monitoring.alert_email` and `operations.notifications.emails` for the receivers, and creates the group.

## To 5.6.5: the tag policy of the landing zone

Schema 5.6.5 adds the optional section `landing_zone.policy` with `required_tags` (the tag names to require) and `management_group` (where to assign; empty means the tenant root management group, whose id is `azure.tenant_id`). Nothing is required: a 5.6.4 file is valid as it is. The Azure Policy task of the operational foundations (`Invoke-AzurePolicyTier1-Orchestrated.ps1`) reads them and assigns the built-in policy Require a tag on resources, once per tag, in audit mode.

## To 5.6.4: the SBE package is a requirement

Schema 5.6.4 adds optional keys to `hardware.sbe`: `requirement` (`required` or `not_applicable`), `not_applicable_reason`, `source_path`, `source_username`, `source_password` (a `keyvault://` reference), `package_sha256` and `package_size_bytes`. A 5.6.3 file is valid as it is. What changes is the **gate**, not the file format:

| If your file | Then |
| --- | --- |
| has no `hardware.sbe` and the vendor is Dell, HPE or DataON | The pre-cluster verification fails SB-001: the OEM package must be downloaded and available on a share. Set `hardware.sbe.source_path` to the share or folder with the three files, or `requirement: not_applicable` with `not_applicable_reason` for hardware with no SBE or a cluster that downloads it with the vendor credential. AZL-032 (Info) says the same. |
| has no `hardware.sbe` and the vendor is Lenovo | SB-001 is a Warning that asks you to state the choice (the vendor catalog says the cluster downloads the package itself). |
| has `hardware.sbe.bundle_path` | It is read as `source_path` when `source_path` is empty. |
| has `hardware.sbe.delivery` | Unchanged. `skip` stays the default; the build-time side-load is still only `winrm_copy` or `node_pull`, and it now copies from `source_path`. |

Other rules: AZL-033 (the requirement keys are consistent), AZL-030 accepts `source_path` for a delivery, AZL-015 accepts `source_path` or `requirement` in place of `bundle_path`.

## To registry 5.0.0: where the files went
The registry became the source of the schema. Nothing in `infrastructure.yml` changes; the files moved. The old folder `config/infrastructure` is gone (removed after registry 5.0.27): `config/variables` is the only place for the registry, the schemas, the templates, the examples and the documents, and azurelocal-ztp, azurelocal-sonar and Trailwright read the files there.

| Was | Now |
| --- | --- |
| `config/infrastructure/infrastructure.schema.json` | `config/variables/schema/infrastructure.schema.json` (generated) |
| `config/infrastructure/infrastructure.example.yml`, `infrastructure.ztp.example.yml` | `config/variables/examples/` |
| `config/infrastructure/examples/*.yml` | `config/variables/examples/scenarios/` |
| `config/infrastructure/README.md`, `MIGRATION.md`, `VARIABLES.md` | `config/variables/docs/` |
| `config/infrastructure/variables-reference.metadata.psd1` | `config/variables/docs/variables-reference.metadata.psd1` |
| (new) | `config/variables/schema/tools/`, `config/variables/templates/` (generated) |

`identity.active_directory.security_groups` is the list of groups (`name`, `purpose`, `members`, `local_groups`); the 4.0 object-by-role form is `security_groups_by_role` (deprecated, expires 2027-05-07).
## Version history

One history, in order: 5.2 (the ports of each machine), 5.3 (BIOS phases, the static method, the SAN), 5.4 (every ZTP setting), 5.4.1 (adapter wait), 5.4.2 (SBE delivery), 5.4.3 (`clear_storage`), 5.4.4 (the guarded network change and the transport keys: `os_configuration.network`, `os_configuration.remoting.transport`, `bootstrap_transport`, `allowed_source_cidrs`), 5.5 (the domain join keys and the CI/CD `devops` keys), 5.6 (the `deployment` block and the remote management security profile), 5.6.1 (`local_groups`), 5.6.2 (adapter identity), 5.6.3 (logical network keys), 5.6.4 (the SBE package as a requirement), 5.6.5 (`landing_zone.policy`), 5.6.6 (`operations.monitoring.action_group`). A file that uses any of them says the version of the newest key it uses (`5.6.6` is the current version); each key's description in the schema says `since` which version added it. Rules: AZL-030 SBE delivery, AZL-033 SBE package requirement, AZL-031 `clear_storage`, AZL-040 `deployment`, AZL-050 to AZL-053 domain join, AZL-060 to AZL-068 security profile, AZL-070 `devops`.
