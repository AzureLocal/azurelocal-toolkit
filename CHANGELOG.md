# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Removed the staging storage account for the SBE package: `Set-AzureLocalNodeConfiguration.ps1 -StagingStorageAccount` and `-StagingContainer`, `New-AzlArcRunCommandTransport -StagingStorageAccount`/`-StagingContainer`, the blob upload and read-only SAS path, the `sas:<name>` secret, and the Az.Storage and Storage Blob roles it needed. Azure Arc Run Command can't carry a file; use `hardware.sbe.delivery`.
- Removed the MkDocs site, docs publishing workflow, and repository `docs/` tree; the README is now the primary repo-level documentation.

### Features

- A draw.io diagram of the OS configuration flow, `docs/diagrams/os-configuration-flow.drawio` with its exported PNG, embedded in `docs/os-configuration-and-arm-deployment.md`: the ZTP handoff and `infrastructure.yml` in, the three management address modes, each step in run order (marked skip-if-correct, read only or opt in), the SBE delivery routes, and the exit to ARM Validate and Deploy.
- `infrastructure.yml` schema 5.4.2 and rule AZL-030: `hardware.sbe.delivery` (`winrm_copy`, `node_pull` or `skip`, default `skip`) and `hardware.sbe.node_pull_url` choose how the Dell SBE package reaches the nodes' `C:\SBE` during OS configuration. `node_pull`: each node downloads the files from a read-only HTTPS or UNC location and the SHA-256 is checked on the node. `winrm_copy`: copied over a WinRM session (to a `.part` file, checked, renamed) from the host that runs the script, beside the Arc transport for the other steps. `skip`: the Sbe step reports "NOT DELIVERED" and nothing else is affected. The Sbe step now runs last, so a delivery that fails never stops the other steps.
- `infrastructure.yml` schema 5.4.1: `provisioning.simplified.timeouts.adapters_minutes` (default 10). azurelocal-ztp's Network stage waits that long for an edge machine to report its network adapters before it judges the management port; a machine whose management port never shows up in the list within that time is not verified in any mode (a Warning, never a success state), and the Handoff stage reads the adapters again. 0 reads once and does not wait.
- `infrastructure.yml` schema 5.4: every azurelocal-ztp setting is a key of the master schema (no key only ZTP knows), each with the value ZTP used before as its default: `provisioning.simplified.create_resource_group`, `configuration_name`, `managed_resource_group_name`, `apply_site_settings`, `use_key_vault_configuration`, `assign_provisioning_roles`, `assign_hci_rp_role`, `network_kind`, `ntp`, `site_mode`, `deployment_name`, `skip_azure_check`, `include_preview`, `max_train`, `retry_provision_os`, `usb_image`, `maintenance_environment`, `timeouts`, `media_share.account_name` and `keep`, and `hardware.bmc.rfs_write_attribute` and `verify_certificate`.
- BIOS actions derived from the hardware inventory: `provisioning.simplified.isolate_san_adapters` (turn the PCIe slots of `nodes[].san.hbas[]` off for the OS install, on again in Restore) and `enable_embedded_nics` (a management or provisioning port with `slot: Embedded`). `nodes[].san.hbas[].type` (`fibre_channel`, `iscsi_offload`); an HBA needs only its `slot`. Rule AZL-029. The raw `hardware.bios` and `bios_during_provisioning` stay as explicit overrides.
- `infrastructure.yml` schema 5.3. BIOS in two phases: `hardware.bios` and `nodes[].bios` are the final state, `hardware.bios_during_provisioning` and `nodes[].bios_during_provisioning` hold temporary values for the OS install (merged node over hardware, during-provisioning over bios), with rule AZL-026 and the readers `Get-AzlBiosSetting -Phase` and `Get-AzlBiosProvisioningOverride`. `networking.management.static_method` (`device` default, or `site`), `provisioning_dhcp_range`, `nodes[].maintenance_address` and `provisioning.simplified.maintenance_password`, with rule AZL-027. SAN details: `storage.san.array`, `fibre_channel` (fabrics, target WWPNs), `iscsi` (targets, CHAP), `nodes[].san` (HBAs and WWPNs, initiator IQN) and the port roles `iscsi:a` and `iscsi:b`, with rule AZL-028. Examples: the full Fibre Channel example, a new `disaggregated-iscsi.yml`, and the BIOS phases in `lom-management-ztp.yml`.
- `_metadata.scope` and a ZTP-only template, `config/infrastructure/infrastructure.ztp.example.yml`: with `scope: ztp` the validator requires only what azurelocal-ztp reads; `full` (default) enforces everything. `Get-AzlInfrastructureScope`.
- `config/infrastructure/VARIABLES.md`, a variables reference generated from the schema by `New-InfrastructureVariablesReference.ps1`, with a test that it is current.
- Initial repository scaffold — MkDocs Material, release-please, GitHub Pages, CI/CD workflows
- Migrate toolkit content from AzureLocalCloud-docs-azl-toolkit (scripts, configs)
- Branding scrub — remove all Azure Local Cloud/AzureLocalCloud/HCS references
