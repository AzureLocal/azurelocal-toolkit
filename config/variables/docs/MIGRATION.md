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
The registry became the source of the schema. Nothing in `infrastructure.yml` changes; the files moved. Tools that read the old paths keep working through two generated stubs.

| Was | Now |
| --- | --- |
| `config/infrastructure/infrastructure.schema.json` | `config/variables/schema/infrastructure.schema.json` (generated). A stub copy stays at the old path. |
| `config/infrastructure/infrastructure.example.yml`, `infrastructure.ztp.example.yml` | `config/variables/examples/`. A stub copy of each stays at the old path. |
| `config/infrastructure/examples/*.yml` | `config/variables/examples/scenarios/` |
| `config/infrastructure/README.md`, `MIGRATION.md`, `VARIABLES.md` | `config/variables/docs/` (pointer files stay) |
| `config/infrastructure/variables-reference.metadata.psd1` | `config/variables/docs/variables-reference.metadata.psd1` |
| (new) | `config/variables/schema/purposes/`, `config/variables/templates/` (generated) |

`identity.active_directory.security_groups` is the list of groups (`name`, `purpose`, `members`, `local_groups`); the 4.0 object-by-role form is `security_groups_by_role` (deprecated, expires 2027-05-07).
## Version history

One history, in order: 5.2 (the ports of each machine), 5.3 (BIOS phases, the static method, the SAN), 5.4 (every ZTP setting), 5.4.1 (adapter wait), 5.4.2 (SBE delivery), 5.4.3 (`clear_storage`), 5.4.4 (the guarded network change and the transport keys: `os_configuration.network`, `os_configuration.remoting.transport`, `bootstrap_transport`, `allowed_source_cidrs`), 5.5 (the domain join keys and the CI/CD `devops` keys), 5.6 (the `deployment` block and the remote management security profile), 5.6.1 (`local_groups`), 5.6.2 (adapter identity), 5.6.3 (logical network keys), 5.6.4 (the SBE package as a requirement), 5.6.5 (`landing_zone.policy`). A file that uses any of them says the version of the newest key it uses (`5.6.4` is the current version); each key's description in the schema says `since` which version added it. Rules: AZL-030 SBE delivery, AZL-033 SBE package requirement, AZL-031 `clear_storage`, AZL-040 `deployment`, AZL-050 to AZL-053 domain join, AZL-060 to AZL-068 security profile, AZL-070 `devops`.
