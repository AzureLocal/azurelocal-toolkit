# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Removed the MkDocs site, docs publishing workflow, and repository `docs/` tree; the README is now the primary repo-level documentation.

### Features

- `infrastructure.yml` schema 5.3. BIOS in two phases: `hardware.bios` and `nodes[].bios` are the final state, `hardware.bios_during_provisioning` and `nodes[].bios_during_provisioning` hold temporary values for the OS install (merged node over hardware, during-provisioning over bios), with rule AZL-026 and the readers `Get-AzlBiosSetting -Phase` and `Get-AzlBiosProvisioningOverride`. `networking.management.static_method` (`device` default, or `site`), `provisioning_dhcp_range`, `nodes[].maintenance_address` and `provisioning.simplified.maintenance_password`, with rule AZL-027. SAN details: `storage.san.array`, `fibre_channel` (fabrics, target WWPNs), `iscsi` (targets, CHAP), `nodes[].san` (HBAs and WWPNs, initiator IQN) and the port roles `iscsi:a` and `iscsi:b`, with rule AZL-028. Examples: the full Fibre Channel example, a new `disaggregated-iscsi.yml`, and the BIOS phases in `lom-management-ztp.yml`.
- `_metadata.scope` and a ZTP-only template, `config/infrastructure/infrastructure.ztp.example.yml`: with `scope: ztp` the validator requires only what azurelocal-ztp reads; `full` (default) enforces everything. `Get-AzlInfrastructureScope`.
- `config/infrastructure/VARIABLES.md`, a variables reference generated from the schema by `New-InfrastructureVariablesReference.ps1`, with a test that it is current.
- Initial repository scaffold — MkDocs Material, release-please, GitHub Pages, CI/CD workflows
- Migrate toolkit content from AzureLocalCloud-docs-azl-toolkit (scripts, configs)
- Branding scrub — remove all Azure Local Cloud/AzureLocalCloud/HCS references
