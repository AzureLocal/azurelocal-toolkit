# infrastructure.yml: the one environment file

`infrastructure.yml` describes one Azure Local instance: the design choices, the machines, the networks, identity, the Azure targets, how the OS gets onto the machines, and the cluster deployment. Every Azure Local tool reads the same file:

| Tool | Reads | Writes |
| --- | --- | --- |
| [azurelocal-toolkit](https://github.com/AzureLocal/azurelocal-toolkit) | Everything its scripts need, through `Import-AzlInfrastructure` | No |
| [azurelocal-toolkit](https://github.com/AzureLocal/azurelocal-toolkit) CI/CD infrastructure (`scripts/deploy/01-cicd-infra`) | The `devops` section (schema 5.5), `azure`, `key_vaults`, `landing_zone` | No |
| [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) | `scenario`, `azure`, `key_vaults`, `nodes` (with `network_adapters`, `bios`, `bios_during_provisioning` and `maintenance_address`), `hardware` (with `bios` and `bios_during_provisioning`), `networking.management` (with `static_method` and `provisioning_dhcp_range`), `networking.ntp_servers`, `identity.local_admin`, `provisioning` (with `simplified.maintenance_password`), `tags` |
| ARM and SAN deployment | The ARM parameters (each schema description names its parameter) and the SAN: `storage.san`, `nodes[].san` | No |
| [Trailwright](https://labs.hybridsolutions.cloud/azurelocal-trailwright/) | The design sections | Yes: it produces the file from a guided design |
| Beacon, Sonar, Ranger | Addresses, names and identity for their checks and reports | No |

The ARM parameters for Microsoft's deployment templates come from this file. The schema descriptions name the ARM parameter each key becomes. **Every key, with its type, whether it is required, its default, an example, where to get the value and which tool reads it, is in [`VARIABLES.md`](VARIABLES.md).**

## Files

| File | What it is |
| --- | --- |
| [`infrastructure.schema.json`](infrastructure.schema.json) | The contract: JSON Schema draft 2020-12. Its `$id` is `https://azurelocal.cloud/schemas/infrastructure/5/infrastructure.schema.json`. |
| [`infrastructure.example.yml`](infrastructure.example.yml) | A complete file with every section and placeholder values: Active Directory, Storage Spaces Direct, switched, simplified provisioning, ARM. Start here. |
| [`examples/`](examples) | One file per scenario: local identity and switchless with Arc gateway, disaggregated Fibre Channel with a proxy (the full SAN details), disaggregated iSCSI (disaggregated-iscsi.yml), rack aware with ZTP, disconnected operations, a single machine on a DHCP reservation, management on the onboard LOMs with ZTP (`lom-management-ztp.yml`, every port listed), and no DHCP anywhere with switchless storage (`no-dhcp-switchless.yml`). |
| [`infrastructure.ztp.example.yml`](infrastructure.ztp.example.yml) | The ZTP-only template, `_metadata.scope: ztp`: only what azurelocal-ztp reads, for someone who uses it on its own. See [Which template](#which-template). |
| [`VARIABLES.md`](VARIABLES.md) | The variables reference: every key with its type, required (full and ztp scope), default, example, where to get the value and which tool reads it. Generated from the schema by `scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1` (with `variables-reference.metadata.psd1`); a test fails when it is out of date. |
| [`MIGRATION.md`](MIGRATION.md) | Where every key from the earlier files went: the environment file ZTP read, the toolkit's `variables.yml` (registry 4.0.0), and Trailwright's export. |

## Which template

Two templates come from the same schema. Pick by what runs after the OS is installed.

| Template | `_metadata.scope` | Use it when | What it holds |
| --- | --- | --- | --- |
| [`infrastructure.example.yml`](infrastructure.example.yml) | `full` (default) | You deploy the whole instance: ZTP, then OS configuration, then the cluster deployment (ARM or portal). | Everything: design choices, machines, networks, identity, storage, security, cluster, provisioning. |
| [`infrastructure.ztp.example.yml`](infrastructure.ztp.example.yml) | `ztp` | You use azurelocal-ztp on its own to install the OS and register the machines, and run no automation after it. | Only what ZTP reads: `azure`, `site`, `key_vaults`, `nodes` (serial number, BMC address, management and provisioning ports with MACs, BIOS), `hardware` (vendor, model, BMC login, BIOS, SBE folder), `networking.management` and `ntp_servers`, `identity.local_admin`, `provisioning`, `tags`. |

With `scope: ztp` the validator requires only ZTP's keys and skips the cluster deployment's requirements: `cluster`, `environment`, `networking.intents`, `storage`, `identity` beyond `local_admin`, the infrastructure pool, and every scenario choice except `os_install` (which must be `simplified`). With `scope: full`, or no `scope`, everything is enforced as before. Rules that check what is there (addresses in the subnet, unique MACs and names, Key Vault references, the BIOS and SAN rules) run in both.

**Growing a ZTP file into the full one.** The two templates use the same keys. When you want the cluster deployment too, add the rest (`cluster`, `environment`, the other `scenario` choices, `networking.intents` and the infrastructure pool, `identity`, `storage`) and change `_metadata.scope` to `full` (or delete it). The validator then tells you what is still missing.

Every key, with its type, whether it is required in each scope, its default, an example, where to get the value and which tool reads it, is in [`VARIABLES.md`](VARIABLES.md).
## Start a file

1. Copy `infrastructure.example.yml` (everything), `infrastructure.ztp.example.yml` (azurelocal-ztp alone: see [Which template](#which-template)), or the example closest to your design, to your environment repository as `infrastructure.yml`. Or produce it with Trailwright.
2. Set `scenario` first. Each choice there makes its section required: for example `identity: active_directory` needs `identity.active_directory`, and `os_install: simplified` needs `provisioning.simplified` and a serial number, BMC address and management MAC on every node.
3. Fill in every value. Put each secret in Key Vault and reference it as `keyvault://<vault>/<secret>`. List every vault you reference under `key_vaults`, with its subscription and resource group.
4. Check the file:

   ```powershell
   ./scripts/common/infrastructure/Test-InfrastructureFile.ps1 -Path ./infrastructure.yml
   ```

   It lists every problem at once and exits 1 if there are errors. Warnings don't fail it.

## The scenario switches

| Key | Values | Makes required |
| --- | --- | --- |
| `identity` | `active_directory`, `local_identity` | `identity.active_directory` or `identity.local_identity` |
| `storage_architecture` | `s2d`, `san`, `hybrid` | `san` and `hybrid`: `storage.san` and `networking.cluster_networks` |
| `storage_connectivity` | `switched`, `switchless` | `switchless`: `networking.storage.switchless_links` |
| `topology` | `standard`, `rack_aware` | `rack_aware`: `nodes[].zone` |
| `connectivity` | `connected`, `disconnected` | `disconnected`: the `disconnected` section |
| `cloud` | `public`, `government` | |
| `outbound_path` | `direct`, `proxy`, `arc_gateway`, `proxy_arc_gateway`, `private_path` | The matching `networking.outbound` entries |
| `os_install` | `iso`, `simplified` | `simplified`: `provisioning.simplified`, and on every node `serial_number`, `bmc.ip_address` and the management MAC: `management.mac_address`, or (5.2) a `mac_address` on every `network_adapters` port with role `management` and at least one port with role `provisioning` |
| `deploy_method` | `portal`, `arm` | |

There is no unattended install from an ISO. With `iso`, the OS is installed first; the toolkit's OS configuration starts after that.

## The management port and the Arc machine name

Two settings decide what happens to each machine before deployment. Both are optional, schema 5.1.

| Key | Values | What it does |
| --- | --- | --- |
| `networking.management.ip_assignment` | `static` (default), `dhcp`, `preconfigured` | How each `nodes[].management.ip_address` gets onto the management port, the one with `nodes[].management.mac_address`. `static`: the address, mask, gateway, DNS servers and `vlan_id` are set on that port. Simplified provisioning sets them at the OS install (edge machine `networkAdapters[]`, `ipAssignmentType: Manual`, keyed by the MAC). For an ISO install, the operator or the toolkit sets them. `dhcp`: the port stays on DHCP, so reserve each address for its MAC (read as `dhcp_reservation`: Mode A, see [Management address modes](#management-address-modes)). `preconfigured`: the port is already set up, and the tools don't change it. |
| `nodes[].arc_machine_name` | 1-54 letters, digits, `-`, `_`, `.`, not ending in `.` | The Arc machine name. Default: `nodes[].name`. Simplified provisioning sets it when it claims the machine (edge machine `arcMachineResourceId`). Without it the service names the Arc machine `ROE1-<id>`, and an Arc machine can't be renamed. An ISO install registers the Arc machine under the host name. |

`ip_assignment` isn't `networking.management.use_dhcp`. `use_dhcp` is the deployment's ARM `useDhcp`, which takes the host and cluster addresses from DHCP instead of the infrastructure pool. In scripts, read both settings with `Get-AzlManagementIpAssignment` and `Get-AzlArcMachineName`, which apply the defaults.

## Every port of every machine (schema 5.2)

`nodes[].network_adapters` lists each physical port of a machine, used or not, so every tool reads the same NICs: the toolkit, ZTP, Trailwright and your own tools. Each entry:

| Key | Values | What it is |
| --- | --- | --- |
| `name` | Text, unique on the machine | The adapter's name in the OS or its slot label, for example `Embedded NIC 1` or `Slot 3 Port 1`. Intents and storage networks name ports by it, so it's the same on every machine. |
| `mac_address` | MAC | Needed for a DHCP reservation, and for every management port with simplified provisioning. |
| `slot`, `model`, `speed_gbps`, `rdma` | | The hardware. Ports in one intent must be the same model and speed. |
| `roles` | List of `management`, `compute`, `storage`, `provisioning`, `unused` | What the port is for. A converged port lists several (`[management, compute]`). `provisioning`: the maintenance environment of simplified provisioning reaches Azure through it. `unused` stands alone. |
| `ip_assignment` | `static`, `dhcp_reservation`, `dhcp`, `preconfigured`, `none` | How the installed OS gets the port's host address before deployment. `none`: no host address (Network ATC or the storage networks give it one, or it isn't used); node preparation turns DHCP off on it. |
| `ip_address`, `prefix_length`, `gateway`, `dns_servers` | | The host address. The management port takes the prefix, gateway and DNS from `networking.management`, and must match them if it sets them. |
| `vlan_id`, `vlan_mode` | 0-4094; `access` or `tagged` | `access`: the switch port is an access port in `vlan_id` and the host sends untagged frames (simplified provisioning sends VLAN 0). `tagged`: the host tags `vlan_id`. |
| `switch_port` | `switch`, `port`, `description` | Where the port is cabled. |

**The management port is derived.** Exactly one port per machine owns the management address: the one with role `management` and an `ip_assignment` other than `none`. A second management port (its team partner) has `ip_assignment: none`. List the management port first in the management intent: the management virtual adapter takes the first adapter's MAC. `nodes[].management` and `networking.management.ip_assignment` still work for files without `network_adapters`; with them, they're deprecated and must agree. Read the result with `Get-AzlManagementAdapter`, which works for both shapes. See [MIGRATION.md](MIGRATION.md#to-52-the-ports-of-each-machine).

Other keys added in 5.2:

| Key | Values | What it does |
| --- | --- | --- |
| `hardware.bios`, `nodes[].bios` | BIOS attribute -> string value | Set before the OS goes on; a node's map is merged over the hardware one (`Get-AzlBiosSetting`). azurelocal-ztp applies it over Redfish before the maintenance boot. Dell examples: `Slot2: Disabled` (a Fibre Channel HBA whose SAN LUN would be offered as the install disk), `EmbNic1Nic2: Enabled` (LOMs shipped `DisabledOs`). |
| `networking.management.site_ip_range` | `start`, `end` | Simplified provisioning: the Manual range of the site's network setting when the management addresses are static. Default: the lowest to the highest static management address (`Get-AzlSiteIpRange`). |
| `networking.management.provisioning_network` | `dhcp` (default), `static` | How the maintenance environment gets the address it reaches Azure with, on the `provisioning` ports. With `static`, a static management port needs another `provisioning` port with `ip_assignment` `dhcp` or `dhcp_reservation` (Mode C), or validation stops (AZL-024, G23); otherwise it is a warning: Learn documents only the Configurator app for it, and a preset address in the bootable image is unresearched. See [Management address modes](#management-address-modes). |
| `provisioning.simplified.media_path`, `evidence_path` | Full paths | Where azurelocal-ztp keeps a run's downloads, images, vouchers and state, and its evidence (event log, change logs). Never inside a git working tree. |

**Arc machine names.** `nodes[].arc_machine_name` stays. In live runs (2026-11) the service overwrote the name set at claim time (`arcMachineResourceId`): the Arc machines still came out as `ROE1-<id>` and then `<device-id>-1`. Why, and whether another property sets it, is an open research item.
## Management address modes

The **management port** is the port with role `management` and an `ip_assignment` other than `none`, found by its MAC. It can be any port: an onboard LOM (the example here), a PCIe or ConnectX port, or a converged port. The tools key off the role and the MAC only, never a slot, a vendor or a port name.

How it gets its address is one of three modes: the port's `ip_assignment`, plus whether the management network has DHCP while the machine is provisioned. That is `networking.management.provisioning_network: dhcp` with the management port also in role `provisioning`. Read it with `Get-AzlManagementMode`.

> **Use Mode A.** DHCP on the management network plus a reservation per node for its management MAC is the only mode where azurelocal-ztp finishes with every management address correct. Modes B and C are supported, but **the static address isn't in place when ZTP finishes**. Microsoft's OS install resets every port to DHCP, and Microsoft's post-install per-NIC API (`jobs/ApplyConfiguration`) didn't run in our tests. OS configuration (`Set-AzureLocalNodeConfiguration.ps1`) after ZTP is required to set it.

| DHCP on management? | Reservation? | `ip_assignment` | Mode | What ZTP does | The management port after ZTP | What OS configuration does |
| --- | --- | --- | --- | --- | --- | --- |
| Yes | Yes | `dhcp_reservation` | **A, Reserved** (recommended) | Nothing to set; the Network stage verifies the reserved address | Its reserved address | Leaves DHCP on, verifies the address. Both verify. |
| Yes | No | `static` | **B, Static with DHCP** | The Device stage sets the static by MAC before the install. The install resets the ports to DHCP; the Network stage records it as left to OS configuration. | A DHCP address | Sets the static by MAC over Arc Run Command, DHCP off on it |
| No | - | `static` | **C, Static without management DHCP** | The same as B. Another port with role `provisioning` must have DHCP: with `provisioning_network: static` and none, validation stops (AZL-024, G23). | No address; Arc reaches the node over the provisioning port | Sets the static by MAC over Arc, before it turns DHCP off on any other port |
| Yes | No | `dhcp` | none: warned (AZL-020) | Reports only | A DHCP address that can change | Leaves it alone |
| - | - | `preconfigured` | none | Reports only: the operator sets it | What the operator set | Leaves it alone (verified only) |

`dhcp_reservation` without `ip_address` is a warning (AZL-020): the tools can only check that the port has some DHCP address. A file with scope `full` still needs the address for the deployment unless `use_dhcp` is true (an error).

**The other ports.** Every port other than the management port that lands on a DHCP network gets a DHCP address and a default gateway from the install, in every mode. OS configuration turns DHCP and the gateway off on each port the file lists with `ip_assignment: none`, in every mode, because validation fails with more than one default gateway. A port the file lists as `dhcp` or `dhcp_reservation` keeps DHCP, and OS configuration stops (Blocked) if it holds a second gateway.

**Mixed modes.** Each node is judged on its own management port. With `static_method: site`, mixing static and DHCP management ports is a warning (AZL-025): the site's network setting is one for every machine.

## BIOS phases, the static method and the SAN (schema 5.3)

Schema 5.3 only adds keys; every 5.0 to 5.2 file stays valid. [`MIGRATION.md`](MIGRATION.md#to-53-bios-phases-the-static-method-and-the-san) has the steps.

**BIOS in two phases.** `hardware.bios` and `nodes[].bios` are the machine's FINAL state. `hardware.bios_during_provisioning` and `nodes[].bios_during_provisioning` hold TEMPORARY values for the OS install only. A node's map is merged over the hardware one, and during-provisioning wins over `bios`. azurelocal-ztp applies them at its Boot stage; in its Restore stage, after the OS install and before Handoff, it sets each key back to its `bios` value (or the original value it saved), restarts the node and waits for Arc to reconnect. Example: a Fibre Channel HBA in slot 2 whose SAN LUN the maintenance environment would install onto:

```yaml
hardware:
  bios: { Slot2: "Enabled" }                     # final
  bios_during_provisioning: { Slot2: "Disabled" } # for the install only
```

On Dell, a slot can also be `BootDriverDisabled`: visible to the OS, never a boot device. Rule AZL-026 warns when a key is in `bios_during_provisioning` but not in `bios`, because Restore then falls back to the saved original value. `Get-AzlBiosSetting -Phase DuringProvisioning` returns the values for the install; `Get-AzlBiosProvisioningOverride` the keys to set back, each with its final value.

**Who sets a static management address.** `networking.management.static_method` matters only when the management `ip_assignment` is static.

| Value | What happens |
| --- | --- |
| `device` (default) | ZTP's Device stage sets the address on the management port, found by its MAC, through the maintenance environment's Configurator service, before the claim. The Arc site's network setting is Automatic and the claim carries no Manual adapter. |
| `site` | The older path. The site's network setting is Manual with an address range (`site_ip_range`) and Microsoft's OS install assigns the address. Microsoft ignores the MAC there and uses the first ready port, which was observed live on Dell AX-760 (a warning, AZL-027). |

To find each machine's maintenance environment, the Device stage uses `nodes[].maintenance_address` (IPv4, optional) when it is set; otherwise it scans `networking.management.provisioning_dhcp_range` (`start`, `end`, optional: the DHCP range on the provisioning network) on TCP 20001 for the node's MAC. The range must be inside `networking.management.subnet`, start at or below end (AZL-027). The Device stage signs in with `provisioning.simplified.maintenance_password`, a `keyvault://` reference; when it is left out the maintenance environment's out-of-box password is used, the one Microsoft Learn documents for the Configurator app. Set your own secret when your images carry another one.

**The SAN.** `storage.san` records the array and its connections, and `nodes[].san` each machine's side:

| Key | What it holds |
| --- | --- |
| `storage.san.array` | `name`, `vendor`, `model`, and an optional `management_address`. |
| `storage.san.fibre_channel` (required for `type: fibre_channel`) | `fabrics`: `name` (A, B), optional `switch` and `zone_set`. `target_wwpns`: the array's `wwpn` and the `fabric` each is cabled to. |
| `nodes[].san.hbas` | Per HBA: `slot` (a PCIe slot label such as `Slot 2`, which azurelocal-ztp turns off in the BIOS for the OS install), `type` (5.4: `fibre_channel` or `iscsi_offload`), `model`, and `ports` with each port's `wwpn` and `fabric` (needed for a Fibre Channel SAN). |
| `storage.san.iscsi` (required for `type: iscsi`) | `targets`: `iqn`, `portals` (IPv4 or IPv4:port) and `fabric`. Optional `chap`: `enabled`, `username`, and `secret` (a `keyvault://` reference). |
| `nodes[].san.initiator_iqn` | The machine's iSCSI initiator name. |
| `nodes[].network_adapters[]` with role `iscsi:a` or `iscsi:b` | The iSCSI ports and their addresses (`ip_assignment`, `ip_address`, `prefix_length`, VLAN). No gateway. |

A WWPN is 16 hex digits, written as colon-separated pairs or without colons. Rule AZL-028: a SAN needs `storage.san` (schema); Fibre Channel needs the target WWPNs and every node's HBA WWPNs; every WWPN names a defined fabric; iSCSI needs targets and every node's initiator IQN, and its ports need an address; no WWPN or IQN appears twice. Complete files: [`examples/disaggregated-fibre-channel-proxy.yml`](examples/disaggregated-fibre-channel-proxy.yml) and [`examples/disaggregated-iscsi.yml`](examples/disaggregated-iscsi.yml).
## Hardware-aware BIOS actions and every ZTP setting (schema 5.4)

Schema 5.4 only adds keys; every 5.0 to 5.3 file stays valid. It does two things for azurelocal-ztp:

**One file, no key that only ZTP knows.** Every setting ZTP reads is a key here, with the value ZTP used before the key existed as its default: the Azure site choices (`provisioning.simplified.create_resource_group`, `configuration_name`, `managed_resource_group_name`, `apply_site_settings`, `use_key_vault_configuration`, `assign_provisioning_roles`, `assign_hci_rp_role`, `network_kind`, `ntp`, `site_mode`, `deployment_name`), the stage `timeouts` (5.4.1 adds `adapters_minutes`: how long the Network stage waits for the machine to report its adapters), `retry_provision_os`, `skip_azure_check`, `include_preview` and `max_train`, the `usb_image`, the `maintenance_environment` (port and user), `media_share.account_name` and `keep`, and the BMC's `rfs_write_attribute` and `verify_certificate`. [`VARIABLES.md`](VARIABLES.md) lists each with its default.

**BIOS actions come from the inventory, not from vendor attribute names.** Before, `hardware.bios` and `hardware.bios_during_provisioning` held raw attribute names (`Slot2: Disabled`), which only someone who knows Dell's names can fill in. Now:

| You write | ZTP does |
| --- | --- |
| `nodes[].san.hbas[].slot` (`Slot 2`; `type` is `fibre_channel` by default, or `iscsi_offload`) | Turns that PCIe slot off in the BIOS for the OS install, so the maintenance environment can't install onto a SAN LUN, and in the Restore stage puts it back to the value it had before (the vendor's enabled value if it was already disabled). Switch: `provisioning.simplified.isolate_san_adapters` (default true when a node lists `san.hbas`, false otherwise). |
| `nodes[].network_adapters[].slot: Embedded` on a `management` or `provisioning` port | Makes sure the embedded NICs are enabled (Dell ships them as `DisabledOs`). Switch: `provisioning.simplified.enable_embedded_nics` (default true). |
| `hardware.bios`, `hardware.bios_during_provisioning` (and the node ones) | Explicit overrides. They win over a derived value for the same attribute. Use them for any other attribute, or for a vendor ZTP has no slot mapping for. |

The mapping from slot label to attribute is data in ZTP, `config/oem/<vendor>.json`, `bios` section (Dell: `Slot{n}` with `Disabled` and `Enabled`, and `EmbNic1Nic2`). For a vendor without a mapping, an HBA must name its own `bios_attribute` (with optional `bios_disabled_value` and `bios_enabled_value`); ZTP stops rather than guess, and an unrelated raw key does not excuse it. An HBA slot is never turned off when a network port is listed in the same slot, however the port's label is written (`Slot 2 Port 1`, `PCIe Slot 2`; rule AZL-029). `ports` under an HBA are for zoning and LUN masking (rule AZL-028); the BIOS action needs only the `slot`.

## What the check covers

**The schema** checks structure, types, formats (IPv4, CIDR, MAC, GUID), the `keyvault://` form, name lengths (cluster and node names up to 15 characters, the LCM user up to 20), and the conditional sections above. Every section rejects unknown keys, so a misspelt key is an error, not a silently ignored value.

**The toolkit's rules** check what a JSON schema can't. Each finding has an ID; rules that come from Microsoft's documentation link to it.

| ID | Rule |
| --- | --- |
| AZL-000 | `schema_version` is 5.x |
| AZL-001 | Every `keyvault://` reference names a vault listed in `key_vaults` |
| AZL-002, AZL-003 | Node names and management addresses are unique |
| AZL-004 | Node addresses (`nodes[].management`, or the 5.2 management port) and the gateway are in the management subnet |
| AZL-005 | The infrastructure pool is in the subnet, has at least six consecutive addresses, and holds no node or gateway address |
| AZL-006 | No infrastructure address is in a range the Arc resource bridge reserves (10.244.0.0/16, 10.96.0.0/24); 10.96.0.0/12 is a warning (AKS, and deployments created before 2610) |
| AZL-007 | Node counts: up to 16 with Storage Spaces Direct, 1 to 4 switchless, rack aware in two equal zones of up to 4 (8 with a SAN) |
| AZL-008 | Witness: two machines and rack aware clusters need one; connected uses cloud, disconnected uses a file share |
| AZL-009 | Intents: exactly one carries management, storage present for multi-machine S2D, storage on its own when switchless, no adapter in two intents |
| AZL-010 | Storage networks use storage-intent adapters; with `auto_ip: false` every network has a subnet and every node an address on each |
| AZL-011 | Intent adapters exist in `hardware.network_cards`, when the cards are described |
| AZL-012 | Rack aware volumes are two-way or four-way mirror |
| AZL-013 | Warnings: the OS version isn't pinned, an unvalidated SBE is allowed, simplified provisioning outside eastus |
| AZL-014 | No public DNS servers |
| AZL-015 | Simplified provisioning has a BMC login for every machine and the SBE folder |
| AZL-016 | Arc gateway (and the private path) isn't used with simplified provisioning or in Azure Government |
| AZL-017 | Management ports: no MAC is used by two nodes; with `ip_assignment: dhcp`, a warning per node to reserve its address for its MAC |
| AZL-018 | Arc machine names (`arc_machine_name`, default the node name) are unique; the deprecated `arc_resource_name` is a warning, or an error when it disagrees with `arc_machine_name`; `arc_machine_name` on an ISO install is a warning, because the Arc machine takes the host name |
| AZL-019 | Ports (5.2): listed on every node or none, names unique on a machine, every MAC on one port only |
| AZL-020 | The management port (5.2): exactly one per node; agrees with a repeated `nodes[].management` and the deprecated site-wide `ip_assignment`; on the one management network (prefix, gateway, DNS); has an address unless `use_dhcp` or scope `ztp`; `dhcp_reservation` (Mode A) without `ip_address` is a warning (the reserved IP can't be verified); in the management intent and first in it (an error with a DHCP reservation, else a warning); plain `dhcp` is a warning (the IP can change; use Mode A, B or C) |
| AZL-021 | Intents and ports (5.2): every intent and storage-network adapter is a port of every node, not `unused`, symmetric (model and speed) within the intent and across nodes; roles that don't fit the intent's traffic, and traffic ports in no intent, are warnings |
| AZL-022 | Addresses on the other ports (5.2): no second default gateway; DHCP left on is a warning; a static address needs `prefix_length`; no address on two ports; a host address on a storage port, a second port in the management subnet and an address with `ip_assignment: none` are warnings |
| AZL-023 | VLANs (5.2): the management port's host VLAN matches `networking.management.vlan_id`; a tagged port with an address has a `vlan_id`; a storage port's VLAN matches its storage network; a storage port on an access port is a warning |
| AZL-024 | The maintenance environment (simplified provisioning): a `provisioning` port on every node (5.2); a static management port with `provisioning_network: static` and no other `provisioning` port on DHCP is an error (Mode C with no DHCP anywhere, G23); otherwise `provisioning_network: static` is a warning (unresearched); a static management port that is also the provisioning port is a warning (Mode B: it needs DHCP there) |
| AZL-025 | The site range (simplified provisioning, static addresses): start before end, inside the subnet, holds every static management address; overlapping the infrastructure pool is a warning, and so is mixing static and DHCP management ports with `static_method: site` |
| AZL-026 | BIOS phases (5.3): a key in `bios_during_provisioning` that `bios` doesn't name is a warning (Restore falls back to the saved original value) |
| AZL-027 | The maintenance environment (5.3): `provisioning_dhcp_range` start at or below end and inside the management subnet; no maintenance address on two nodes; `static_method: site` with static addresses is a warning (Microsoft uses the first ready port, not the MAC) |
| AZL-028 | The SAN (5.3): Fibre Channel needs target WWPNs and every node's HBA WWPNs, and every WWPN names a defined fabric; iSCSI needs targets and every node's initiator IQN, and an address on its `iscsi:a` / `iscsi:b` ports; no WWPN or IQN is used twice; fabric names are unique |
| AZL-029 | What ZTP derives (5.4, simplified provisioning): an HBA slot is a PCIe slot label (`Slot 2`) while isolation is on, and no network port shares it; `isolate_san_adapters: true` with no HBA listed is a warning; `ntp.configuration: Manual` needs a server; the voucher budget is not longer than the Bootstrap budget |
| AZL-030 | The SBE package's delivery (5.4.2): `hardware.sbe.delivery` is `winrm_copy`, `node_pull` or `skip`; `winrm_copy` and `node_pull` need `hardware.sbe.bundle_path`; `node_pull` needs `node_pull_url`, an `https://` (or `http://`, a warning) address or a UNC folder with no user name, password, token or query string; an address with another route is a warning (not used); `winrm_copy` warns for a node with no management `ip_address` |
| AZL-031 | The OS configuration run (5.4.3): `os_configuration.clear_storage: true` on a SAN design warns that only local disks are wiped (the key itself must be a boolean, which the schema checks). |
| AZL-040 | The `deployment` block (5.6, ARM Validate and Deploy): `poll_max_seconds` is not less than `poll_seconds`; a Validate limit under 30 minutes, a Deploy limit under 4 hours and `approval: none` are warnings; an `acknowledge_known_issues` id that is not in `config/known-issues/arm-deployment.json` is a warning |
| AZL-070 | The CI/CD infrastructure (5.5, `devops`; this rule was AZL-030 on its branch, which the SBE delivery rule already held): runner names are unique; one ztp runner (Windows, one VM, with `bmc_cidrs` on `runner_network`) and one Linux general pool; a Windows runner is a VM; a runner needs its `registration_secret` and a subnet inside `runner_network` that overlaps no other; `hub_peering` needs its names; `devops.resource_group` and `runner_network` are needed when runners are; environment names are unique; `authentication.method: client_secret` needs `client_secret` |
| (scope) | `_metadata.scope: ztp` requires only ZTP's keys (see [Which template](#which-template)); `full` requires everything |
Design guidance (which pattern to pick, sizing, best practices) stays in Trailwright, which cites Microsoft Learn for every rule. The toolkit's rules are the ones that stop a deployment.

## Use it from a script

```powershell
Import-Module ./scripts/common/infrastructure/AzlInfrastructure.psm1
$infra = Import-AzlInfrastructure -Path ./infrastructure.yml   # stops if the file has errors
$gateway = $infra.networking.management.gateway
$value = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'provisioning.simplified.site_name'
$bios = Get-AzlBiosSetting -Infrastructure $infra -Node $infra.nodes[0] -Phase DuringProvisioning   # 5.3: the values for the OS install
Get-AzlBiosProvisioningOverride -Infrastructure $infra -Node $infra.nodes[0]                        # the keys ZTP sets back in Restore
Get-AzlManagementStaticMethod -Infrastructure $infra                                                 # device (default) or site
Get-AzlInfrastructureScope -Infrastructure $infra                                                    # full (default) or ztp
```

Without `-Path`, `Import-AzlInfrastructure` looks for `$env:AZL_INFRASTRUCTURE_FILE`, then `./infrastructure.yml`, then `./config/infrastructure.yml`. It needs the `powershell-yaml` module.

From JavaScript or TypeScript, validate with ajv's draft 2020-12 build. The schema compiles with `strict: true`:

```js
import Ajv2020 from 'ajv/dist/2020';
const validate = new Ajv2020({ strict: true, allErrors: true }).compile(schema);
```

## Rules for the file

- Keys are `snake_case` at every level, and so are enum values.
- Secrets are never values. A password key accepts only a `keyvault://` reference.
- Anything the schema doesn't define goes under `extensions.<your-key>`: settings for one environment or one tool. Tools ignore keys they don't own.
- The file can hold subscription and tenant IDs. Keep files with real values in private environment repositories, never in a public repository.

## The OS configuration switch (schema 5.4.3)

`os_configuration.network` and `os_configuration.remoting` (since 5.4.4) set the confirmation window of a guarded network change and how the OS configuration reaches the nodes: PowerShell remoting by default, Arc Run Command as an option, and an optional one-time Arc bootstrap that opens a closed node firewall. See [Choosing the transport](../../docs/os-configuration-and-arm-deployment.md#choosing-the-transport).

`os_configuration.clear_storage` (default `false`) tells `Invoke-AzureLocalOsConfiguration.ps1` to wipe the leftover storage of re-used machines: storage pools, virtual disks and the data on local disks that are not boot, system, SAN or USB. Plan mode lists the disks per machine and wipes nothing; Apply mode wipes only what the plan listed. See [OS configuration and ARM deployment](../../docs/os-configuration-and-arm-deployment.md#run-it-in-one-go).
## Versioning

`_metadata.schema_version` is the schema version the file follows.

- A **minor** version (5.4.0) adds optional keys. Files written for 5.0 stay valid.
- A **major** version (6.0.0) can rename or remove keys. It comes with a migration in `MIGRATION.md`, and tools refuse files from a major they don't read.

Change the schema, the examples, the tests and this page together. The tests in `tests/infrastructure` validate every example and check every rule.
