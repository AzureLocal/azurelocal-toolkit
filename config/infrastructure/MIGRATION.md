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
| (implied by the presence of `ztp`) | `scenario.os_install: simplified` |
| Other top-level keys of one environment (for example `devops_runner`) | `devops`, or `extensions.<name>` |

`hardware.bmc.username` and `nodes[].bmc.username` take either a user name or a `keyvault://` reference to a secret holding it. Tools resolve the reference when the value starts with `keyvault://`.

## Within schema 5

Minor versions add optional keys; a key that is renamed keeps working until the next major version.

| Before | Now |
| --- | --- |
| `nodes[].arc_resource_name` (5.0) | `nodes[].arc_machine_name` (5.1). `arc_resource_name` still reads as the Arc machine name, with a deprecation warning (AZL-018). |

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
