# infrastructure.yml: the one environment file

> **Registry first.** The master of every variable is [`config/variables/schema/master-registry.yaml`](../schema/master-registry.yaml). The schema, the master file, the one template per tool and the variables reference below are **generated** from it by `./config/variables/scripts/New-InfrastructureArtifacts.ps1`; change the registry, not them. A test regenerates them and fails when one is stale. See [config/variables/README.md](../README.md).

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

All under `config/variables`. Generated files say so in their first lines; do not edit them.

| File | What it is |
| --- | --- |
| [`schema/master-registry.yaml`](../schema/master-registry.yaml) | The master. Every variable, with type, default, allowed values, since version, and which tools read it. |
| [`schema/infrastructure.schema.json`](../schema/infrastructure.schema.json) | **Generated.** The contract: JSON Schema draft 2020-12. Its `$id` is `https://azurelocal.cloud/schemas/infrastructure/5/infrastructure.schema.json`. |
| [`schema/tools/`](../schema/tools) | **Generated.** One schema per tool: the part of the schema that tool reads (`ztp`, `os-configuration`, `deployment`, `cicd-infra`, `monitoring`, `discovery`, `trailwright`, `ranger`). |
| [`templates/infrastructure.master.yml`](../templates/infrastructure.master.yml) | **Generated.** Every variable, with comments and the allowed values. [`templates/scenarios/`](../templates/scenarios) has it for one scenario choice; [`templates/tools/`](../templates/tools) has one template per tool, with only the variables that tool reads. |
| [`examples/infrastructure.example.yml`](../examples/infrastructure.example.yml) | A complete worked file with every section and placeholder values: Active Directory, Storage Spaces Direct, switched, simplified provisioning, ARM. Start here for realistic values. |
| [`examples/scenarios/`](../examples/scenarios) | One file per scenario: local identity and switchless with Arc gateway, disaggregated Fibre Channel with a proxy (the full SAN details), disaggregated iSCSI (`disaggregated-iscsi.yml`), rack aware with ZTP, disconnected operations, a single machine on a DHCP reservation, management on the onboard LOMs with ZTP (`lom-management-ztp.yml`, every port listed), and no DHCP anywhere with switchless storage (`no-dhcp-switchless.yml`). |
| [`examples/infrastructure.ztp.example.yml`](../examples/infrastructure.ztp.example.yml) | The ZTP-only worked file, `_metadata.scope: ztp`: only what azurelocal-ztp reads, for someone who uses it on its own. See [Which template](#which-template). |
| [`VARIABLES.md`](VARIABLES.md) | **Generated.** The variables reference: every key with its type, required (full and ztp scope), default, example, where to get the value and which tool reads it. |
| [`MIGRATION.md`](MIGRATION.md) | Where every key from the earlier files went: the environment file ZTP read, the toolkit's `variables.yml` (registry 4.0.0), and Trailwright's export. |

To give a tool its input from your `infrastructure.yml`: `./config/variables/scripts/New-InfrastructureArtifacts.ps1 -Cut ztp -From ./infrastructure.yml`. The tool validates the cut file against `schema/tools/ztp.schema.json`.
## One master file, one template per tool

The registry is the only master. From it the generator writes **one master file** (`templates/infrastructure.master.yml`, every key) and **one template per tool** (`templates/tools/<tool>.yml`, only the keys that tool reads) with a matching JSON schema (`schema/tools/<tool>.schema.json`). Someone who fills in a file for one tool sees only that tool's keys. The tools are listed in the registry section `_tool_catalog`; the keys of a tool are the ones that name it in `used_by`. The file name is the tool id with hyphens for underscores.

| Tool id | Tool | Template | Keys |
| --- | --- | --- | ---: |
| `ztp` | [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) | [`ztp.yml`](../templates/tools/ztp.yml) | 119 |
| `os_configuration` | OS configuration (toolkit) | [`os-configuration.yml`](../templates/tools/os-configuration.yml) | 168 |
| `deployment` | Pre-cluster verification and ARM deployment (toolkit) | [`deployment.yml`](../templates/tools/deployment.yml) | 223 |
| `cicd_infra` | CI/CD infrastructure (toolkit) | [`cicd-infra.yml`](../templates/tools/cicd-infra.yml) | 117 |
| `monitoring` | [azurelocal-sonar](https://github.com/AzureLocal/azurelocal-sonar) | [`monitoring.yml`](../templates/tools/monitoring.yml) | 19 |
| `discovery` | Hardware discovery (toolkit) | [`discovery.yml`](../templates/tools/discovery.yml) | 44 |
| `trailwright` | [azurelocal-trailwright](https://github.com/AzureLocal/azurelocal-trailwright), which **writes** the file | [`trailwright.yml`](../templates/tools/trailwright.yml) | 195 |
| `ranger` | [azurelocal-ranger](https://github.com/AzureLocal/azurelocal-ranger), design comparison (`-DesignPath`) | [`ranger.yml`](../templates/tools/ranger.yml) | 10 |

The key counts are the keys below the file's own `_metadata` section, which every template keeps. [azurelocal-loadtools](https://github.com/AzureLocal/azurelocal-loadtools), [azurelocal-surveyor](https://github.com/AzureLocal/azurelocal-surveyor) and [azurelocal-draftsman](https://github.com/AzureLocal/azurelocal-draftsman) read no key of `infrastructure.yml`, so they have no template; their entries in `_tool_catalog` give the evidence. `ztp` is azurelocal-ztp and `monitoring` is azurelocal-sonar: the toolkit has no stage of its own for either. A test (`tests/variables/ToolTemplates.Tests.ps1`) fails when a template holds a key whose `used_by` does not name its tool, misses one that does, or when `used_by` names something that is not in `_tool_catalog`.

## The own settings of a tool

The keys above are facts of the environment. A tool also has settings of its own: a key in its configuration file, a command parameter, an environment variable, a link parameter. They are registered too, in the same registry, under `tools.<tool>.<kind>.<group>.<name>` (the `tools_section` of the tool in `_tool_catalog`). The group is the file or command that defines the settings; its `area` says which. A tool whose settings are all of this kind, and that reads no key of `infrastructure.yml`, has no template.

| Tool | Registry section | What is registered |
| --- | --- | --- |
| [azurelocal-ranger](https://github.com/AzureLocal/azurelocal-ranger) | `tools.ranger` | The configuration keys (`Get-RangerDefaultConfig`, publishing, credentials, hints), the WAF rule tunables, the parameters of every exported command, two environment variables |
| [azurelocal-loadtools](https://github.com/AzureLocal/azurelocal-loadtools) | `tools.loadtools` | `variables.yml`, the solution JSON keys the scripts read, the per-cluster file, `keyvault-config.yml`, `variables.example.yml`, the workload profiles, the test thresholds in `alert-rules.yml`, the script parameters, the pipeline inputs, the Bicep parameters, the Ansible inventory variables |
| [azurelocal-sonar](https://github.com/AzureLocal/azurelocal-sonar) | `tools.sonar` | Its configuration file keys, command parameters, events and environment variables |
| [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) | `tools.ztp` | Script parameters, configuration keys, handoff and state fields, environment variables |
| [azurelocal-draftsman](https://github.com/AzureLocal/azurelocal-draftsman) | `tools.draftsman` | The URL parameters of the page and `VITE_BASE` |
| [azurelocal-surveyor](https://github.com/AzureLocal/azurelocal-surveyor) | none | It has no setting outside its page |

An entry has the name as the tool writes it, `type`, the tool's own `default`, `enum` where the code fixes the values, `required`, `read_at` (the file and line, or "not read by code" for a setting that is only documented) and a one-line description. The test thresholds in the load tool's `alert-rules.yml` are the load tool's own limits for a test run, not Azure Monitor alert rules.

**Same fact as an infrastructure key.** When a setting of a tool is the same fact as a key of `infrastructure.yml` (a cluster name, a subscription ID, a node name, a Key Vault name), the entry has `source_key` with that path, for example `azure.subscription_id` or `nodes[].name`. The fact is defined once, in the key; the entry only marks a place where the tool asks again instead of reading the master file. A value that is derived from a key (an FQDN, a workspace ID) has no `source_key`; its description names the key.

**Checks.** [`tests/variables/ToolSettings.Tests.ps1`](../../../tests/variables/ToolSettings.Tests.ps1) compares the registered settings of each tool with its source: a setting in the tool that is not registered fails, and so does a registered one that the tool no longer has. It also checks that every `source_key` is a key of the master file. The comparison needs the repository of the tool (`D:\git\azurelocal\azurelocal-<tool>`, or `AZL_<TOOL>_REPO`); without it the test is skipped with a message. [`tool-mappings/`](../tool-mappings/README.md) lists the names of each tool with their registry paths.
Two templates come from the same schema. Pick by what runs after the OS is installed.

| Template | `_metadata.scope` | Use it when | What it holds |
| --- | --- | --- | --- |
| [`infrastructure.example.yml`](../examples/infrastructure.example.yml) | `full` (default) | You deploy the whole instance: ZTP, then OS configuration, then the cluster deployment (ARM or portal). | Everything: design choices, machines, networks, identity, storage, security, cluster, provisioning. |
| [`infrastructure.ztp.example.yml`](../examples/infrastructure.ztp.example.yml) | `ztp` | You use azurelocal-ztp on its own to install the OS and register the machines, and run no automation after it. | Only what ZTP reads: `azure`, `site`, `key_vaults`, `nodes` (serial number, BMC address, management and provisioning ports with MACs, BIOS), `hardware` (vendor, model, BMC login, BIOS, SBE folder), `networking.management` and `ntp_servers`, `identity.local_admin`, `provisioning`, `tags`. |

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
| `storage_architecture` | `s2d`, `san`, `hybrid` | `san` and `hybrid`: `storage.san` and `networking.cluster_networks`. They also **tell the solution there is a SAN**: the OS configuration then does the host-side MPIO / MSDSM work (see "SAN in the file" below) |
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
| `name` | Text, unique on the machine | The key of the port in this file, the same on every machine: intents (`networking.intents[].adapters`), storage networks and cluster networks name ports by it. Hardware discovery derives it from the slot and the port, for example `Slot 3 Port 1`; it is not read from the OS, so it does not have to be what the OS calls the adapter. A file that already uses the OS name here keeps working. |
| `mac_address` | MAC (required) | The identity of the port. Every tool finds the physical adapter on a node by it (case and separators are ignored), never by a name: OS configuration, the ARM parameters and the pre-cluster verification all resolve the OS adapter name from it. |
| `slot`, `port_index`, `pci_location`, `vendor`, `model`, `speed_gbps`, `rdma` | | The hardware, as hardware discovery reports it from the BMC: which slot and which port of the card (`port_index` from 1), the PCI location (`bus`, `device`, `function`, when the BMC reports it), manufacturer, model, link speed and RDMA capability. Ports in one intent must be the same model and speed. `pci_location` is compared with the node and a difference is reported; no key makes a tool behave differently for a brand. |
| `os_name_override` | Text, 1 to 64 characters | **Optional, off by default.** The name you want the adapter to have in the OS, for example `Mgmt1` or `Storage1`. Without it nothing is renamed: the OS configuration step `NicNames` leaves every adapter name alone and the deployment sends the name the OS already uses (found by MAC). With it, `NicNames` renames the adapter found by MAC (a guarded change, idempotent, the management adapter last) and the deployment sends this name. Give the same value for the same port on every machine. |
| `roles` | List of `management`, `compute`, `storage`, `provisioning`, `unused` | What the port is for. A converged port lists several (`[management, compute]`). `provisioning`: the maintenance environment of simplified provisioning reaches Azure through it. `unused` stands alone. |
| `ip_assignment` | `static`, `dhcp_reservation`, `dhcp`, `preconfigured`, `none` | How the installed OS gets the port's host address before deployment. `none`: no host address (Network ATC or the storage networks give it one, or it isn't used); node preparation turns DHCP off on it. |
| `ip_address`, `prefix_length`, `gateway`, `dns_servers` | | The host address. The management port takes the prefix, gateway and DNS from `networking.management`, and must match them if it sets them. |
| `vlan_id`, `vlan_mode` | 0-4094; `access` or `tagged` | `access`: the switch port is an access port in `vlan_id` and the host sends untagged frames (simplified provisioning sends VLAN 0). `tagged`: the host tags `vlan_id`. |
| `switch_port` | `switch`, `port`, `description` | Where the port is cabled. |
| `allowed_vlans` | List of VLAN ids, 1 to 4094 | **Optional.** The VLANs the switch port allows (a trunk). The pre-cluster verification checks that the compute VLANs of `networking.vlans[]` reach the compute adapters and prints a switch port checklist in its report; without it the check says it could not verify. The gate cannot read the switch. |

**Names, in short.** Roles and intents refer to a port by `name`. The physical adapter is found on a node by `mac_address`. The name the deployment sends to Azure (`intentList` adapter, `storageNetworkList` networkAdapterName) is what the node calls that adapter, or `os_name_override` when set. If the same port has different names on different nodes, the deployment and the pre-cluster verification stop and give the two ways out: install the nodes consistently, or set `os_name_override` and run the OS configuration (`NicNames`, opt-in). Migration: existing files need no change; to get one name everywhere add `os_name_override` per used port. See [Adapter identity and names](../../../docs/os-configuration-and-arm-deployment.md#adapter-identity-and-names-the-nicnames-step).

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
| `storage.san.type` (required) | `fibre_channel` or `iscsi`: **selects the OS configuration's host-side steps**. With `storage.san.array.vendor` and `.model` it is all they need. |
| `storage.san.fibre_channel` (for zoning; needed for `type: fibre_channel` in a `san` design, optional in `hybrid`) | `fabrics`: `name` (A, B), optional `switch` and `zone_set`. `target_wwpns`: the array's `wwpn` and the `fabric` each is cabled to. |
| `nodes[].san.hbas` | Per HBA: `slot` (a PCIe slot label such as `Slot 2`, which azurelocal-ztp turns off in the BIOS for the OS install), `type` (5.4: `fibre_channel` or `iscsi_offload`), `model`, and `ports` with each port's `wwpn` and `fabric` (needed for a Fibre Channel SAN). |
| `storage.san.iscsi` (needed for `type: iscsi` to get portals and sessions; not made for a `san` design on Azure Local 2610 or later, where the deployment configures iSCSI) | `targets`: `iqn`, `portals` (IPv4 or IPv4:port) and `fabric`. Optional `chap`: `enabled`, `username`, and `secret` (a `keyvault://` reference). |
| `nodes[].san.initiator_iqn` | The machine's iSCSI initiator name. |
| `storage.san.luns[]` (5.6.16) | The LUNs the array presents for workload volumes, after the deployment: `name` (the cluster disk and CSV name), `unique_id` (the disk's UniqueId from `Get-Disk`; the only way the disk is found), `size_gib` and `lun_id` (both cross-checks). `New-SanVolume.ps1` (phase 06, task 05) makes each one an NTFS CSV and never touches a disk that has a partition. |
| `nodes[].network_adapters[]` with role `iscsi:a` or `iscsi:b` | The iSCSI ports and their addresses (`ip_assignment`, `ip_address`, `prefix_length`, VLAN). No gateway. |

A WWPN is 16 hex digits, written as colon-separated pairs or without colons. Rule AZL-028: a SAN needs `storage.san` (schema); Fibre Channel needs the target WWPNs and every node's HBA WWPNs; every WWPN names a defined fabric; iSCSI needs targets and every node's initiator IQN, and its ports need an address; no WWPN or IQN appears twice. In a `hybrid` design the missing WWPNs, targets and IQNs are warnings (they are for zoning and LUN masking, not for the host-side work); in a `san` design they are errors.

**SAN in the file: fibre_channel or iscsi.** Say it in the file and the OS configuration does the rest. `scenario.storage_architecture: hybrid` (S2D plus a SAN) or `san`, or a `storage.san` block, declares a SAN; `storage.san.type: fibre_channel` or `iscsi` picks the steps. Fibre Channel: MPIO, the array's MSDSM hardware ID (from `config/san/msdsm-vendors.json`, picked by `storage.san.array.vendor` and `.model`), the MPIO claim of that device (`mpclaim -n -i -d`; the MSDSM registration alone does not make MPIO claim the paths), the load balance policy, the vendor's MPIO settings, the generic `Vendor*` entry removed for Pure, the node's WWPNs collected, a restart so MPIO claims the paths, and a check that every LUN is seen once. iSCSI: the same, plus the MSiSCSI service, MSDSM auto-claim for iSCSI, and the target portals and sessions (not for a `san` design on Azure Local 2610 or later: Microsoft Learn says the deployment configures iSCSI there and not to enable it by hand before it; the release comes from `deployment.solution_version`). Every node is also checked, read only, for SAN LUNs the file does not declare. A minimal hybrid file needs only:

```yaml
scenario:
  storage_architecture: hybrid
storage:
  san:
    type: fibre_channel
    array: { name: "arr-01", vendor: "Pure Storage", model: "FlashArray//X" }
```

(`networking.cluster_networks` is still required by the schema for `hybrid` and `san`.) The steps, their order and what they report are in [os-configuration-and-arm-deployment.md](../../../docs/os-configuration-and-arm-deployment.md#san-in-the-file-fibre_channel-or-iscsi).

Complete files: [`examples/disaggregated-fibre-channel-proxy.yml`](../examples/scenarios/disaggregated-fibre-channel-proxy.yml) and [`examples/disaggregated-iscsi.yml`](../examples/scenarios/disaggregated-iscsi.yml).

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

## The networks the tools read

- `networking.management`: `subnet`, `gateway`, `vlan_id`, `dns_servers` and, for static addressing, `site_ip_range`, `infrastructure_pool`, `static_method`, `provisioning_network` and `provisioning_dhcp_range`.
- `networking.oob`: the out-of-band network of the BMCs. Only `subnet` is read (the remote management security profile counts it as a source in `dev` and `production`); `gateway` and `vlan_id` are documentation.
- `networking.vlans[]`, `networking.intents[]`, `networking.storage.networks[]`, `networking.cluster_networks[]`: the design. Ports are named by `nodes[].network_adapters[].name`; the physical adapter is found by MAC (see above).
- `networking.logical_networks[]`: the Arc VM logical networks created after the deployment (task `phase-06-post-deployment/task-08-logical-network-creation`). Keys: `name`, `vlan_id`, `address_prefix`, `gateway`, `dns_servers`, `ip_pool` (`start`, `end`; one pool, which `az stack-hci-vm` takes), `purpose`, and since 5.6.3 `enabled` (default `true`), `ip_allocation_method` (`Static` default, or `Dynamic`) and `nsg_name` (a group of `networking.network_security_groups[]`; it is tied to the logical network when the network is created, so create the groups first), and since 5.6.11 `vm_switch_name` (leave it out: `New-LogicalNetwork.ps1` uses the one external virtual switch the cluster reports; name it only when the cluster has several). A Static network needs `address_prefix`, `gateway`, `dns_servers`, `vlan_id` and `ip_pool`. The 4.0 form `networking.onprem.logical_networks[]` (`default_gateway`, `ip_pools`) is deprecated.
- `networking.network_security_groups[]` (5.6.11): the network security groups for Azure Local virtual machines and logical networks, created by `New-NetworkSecurityGroup.ps1` (task `phase-06-post-deployment/task-07-configure-nsgs`). Keys: `name` and `rules[]` (`name`, `priority` 100 to 4096, `direction`, `access`, `protocol`, `source_address_prefixes`, `destination_address_prefixes`, `source_port_ranges`, `destination_port_ranges`, `description` up to 140 characters). Needs `sdn.enabled: true` (the script does not enable SDN), and every group needs at least one rule.

## VM images (schema 5.6.11)

`storage.vm_images[]` lists the Azure Marketplace images that `New-VmImage.ps1` (task `phase-06-post-deployment/task-06-image-downloads`) downloads to the instance as Azure Local VM images. Keys: `name`, `os_type` (Windows or Linux), `publisher`, `offer`, `sku`, `version` (a version, or `latest`, the default) and the optional `storage_path`, a name from `storage.paths[]`. The script never writes the version it finds back to the file. Only Azure Marketplace images are supported: images from a local path, a storage account, an existing virtual machine or a compute gallery are not.
## The deployment block and the pre-cluster verification (schema 5.6)

`deployment` is optional and every key has a default. A `-Settings` value on the command line wins over the file. The keys of `Invoke-AzureLocalArmDeployment.ps1` are the timeouts, polling, approval and resume (see [MIGRATION.md](MIGRATION.md#the-deployment-block)). The pre-cluster verification gate (`Invoke-AzureLocalPreClusterVerification.ps1`, which the ARM run requires before Validate and Deploy) reads:

| Key | Default | Meaning |
| --- | --- | --- |
| `deployment.pre_cluster_verification_max_age_hours` | 4 (1 to 168) | How long a passing result stays valid for the ARM run |
| `deployment.pre_cluster_verification_report_directory` | the environment data folder, `arm-report\verification\live` | Where the report, the summary and the event feed are written |
| `deployment.verification_min_memory_gib`, `verification_min_boot_disk_gb`, `verification_min_data_disk_gb`, `verification_min_link_gbps` | 32, 200, 500, 10 | The node minimums (Microsoft Learn system requirements) |
| `deployment.verification_max_clock_skew_seconds` | 300 | The largest clock difference between a node and this host (Kerberos allows 300) |
| `deployment.register_resource_providers` | `false` | Opt in: register the mandatory resource providers that are missing (the run never changes Azure by itself) |

The Environment Checker is chosen with the switches `-InstallEnvironmentChecker` and `-KeepEnvironmentChecker` of the gate (run settings `installEnvironmentChecker`, `keepEnvironmentChecker`); the bypass of the gate is only the switch `-SkipPreClusterVerification`, never a file key. `identity.active_directory.use_gmsa` and `dns_secure_dynamic_updates` are read by the identity checks of the gate.

## The SBE package is a requirement (schema 5.6.4)

The OEM Solution Builder Extension (SBE) package is **downloaded and available on a share the automation can read**. You need it for the first cluster update anyway (a vendor whose SBE has no download connector for the cluster leaves the update in `AdditionalContentRequired`; Dell's download is behind a support login), and the build can use it too. The toolkit still never side-loads it at build time unless the file says so (`hardware.sbe.delivery`, default `skip`).

| Key | Default | Meaning |
| --- | --- | --- |
| `hardware.sbe.source_path` | none; `bundle_path` when empty | The share or folder with the three files `SBE_Discovery_<Vendor>.xml`, `SBE_<Vendor>_<Family>_<Version>.xml` and `.zip`. No credential in the path |
| `hardware.sbe.requirement` | the vendor catalog (`config/oem/<vendor>.json`): `required` for a manual download (Dell, HPE, DataON), a Warning to state it for a vendor whose cluster downloads the package itself (Lenovo Premier) | `required`, or `not_applicable` for hardware with no SBE or a cluster that downloads it with the vendor credential |
| `hardware.sbe.not_applicable_reason` | none | Required with `not_applicable`: why. An empty reason fails SB-001 and AZL-033 |
| `hardware.sbe.source_username`, `source_password` | none | Optional read account; the password is a `keyvault://` reference read into memory only |
| `hardware.sbe.package_sha256`, `package_size_bytes` | none | Optional pins for the payload zip; the discovery manifest's `PackageHash` is checked either way |
| `hardware.sbe.delivery` | `skip` | Unchanged and separate: `winrm_copy` or `node_pull` side-loads the package at build time |

The pre-cluster verification checks the package (SB-001 to SB-006): source configured or declared not applicable with a reason, reachable read only with the credential, the three files present, the files consistent (names, discovery entry, sizes, SHA-256), the family listing the hardware model of every node (`SupportedModels` of the package's own discovery manifest), and the version validated for the target solution version. See [pre-cluster-verification.md](../../../docs/pre-cluster-verification.md) and [os-configuration-and-arm-deployment.md](../../../docs/os-configuration-and-arm-deployment.md#sbe-the-oems-solution-builder-extension). After the deployment, `Get-AzureLocalSbeImportPlan.ps1` (Phase 06, task 10) lists the files and the exact `Add-SolutionUpdate` commands to import the same package (printed, not executed).

## What the check covers
**The schema** checks structure, types, formats (IPv4, CIDR, MAC, GUID), the `keyvault://` form, name lengths (cluster and node names up to 15 characters, the LCM user up to 20), and the conditional sections above. Every section rejects unknown keys, so a misspelt key is an error, not a silently ignored value.

**The toolkit's rules** check what a JSON schema can't. Each finding has an ID; rules that come from Microsoft's documentation link to it.

| ID | Rule |
| --- | --- |
| AZL-000 | `schema_version` is 5.x |
| AZL-001 | Every `keyvault://` reference names a vault listed in `key_vaults` |
| AZL-054 | A `file://` reference needs `secrets.file.directory`; a `command://` reference needs `secrets.command.executable` and an argument with `{name}` (5.6.13) |
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
| AZL-013 | Warnings: the OS version isn't pinned, simplified provisioning outside eastus |
| AZL-014 | No public DNS servers |
| AZL-015 | Simplified provisioning has a BMC login for every machine. The SBE package is a requirement (AZL-033, SB-001); a `hardware.sbe` that is there needs `source_path` or `bundle_path` (publisher, family and version are read from the package), or `requirement` (`not_applicable` with a reason), or `publisher`, `family` and `version` for an SBE you placed in `C:\SBE` yourself; in a `ztp` file, `bundle_path` or `requirement` |
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
| AZL-032 | Info, not a warning: the file has no `hardware.sbe`, so no package source is configured and nothing is side-loaded at build time. The vendor catalog decides whether the package is required (pre-cluster verification SB-001): for a manual download (Dell, HPE, DataON) it is. Side-loading at build time is opt-in; nothing adds the block or a delivery setting for you. |
| AZL-033 | The SBE package as a requirement (5.6.4): `requirement` is `required` or `not_applicable`; `not_applicable` needs `not_applicable_reason`; `required` needs `source_path` (or `bundle_path`); `source_username` and `source_password` (a `keyvault://` reference) go together; a path with a query string or fragment is an error (no credential in the file) |
| AZL-030 | The SBE package's delivery (5.4.2): `hardware.sbe.delivery` is `winrm_copy`, `node_pull` or `skip`; `winrm_copy` and `node_pull` need `hardware.sbe.source_path` (or `bundle_path`); `node_pull` needs `node_pull_url`, an `https://` (or `http://`, a warning) address or a UNC folder with no user name, password, token or query string; an address with another route is a warning (not used); `winrm_copy` warns for a node with no management `ip_address` |
| AZL-031 | The OS configuration run (5.4.3): `os_configuration.clear_storage: true` on a SAN design warns that only local disks are wiped (the key itself must be a boolean, which the schema checks). |
| AZL-040 | The `deployment` block (5.6, ARM Validate and Deploy): `poll_max_seconds` is not less than `poll_seconds`; a Validate limit under 30 minutes, a Deploy limit under 4 hours and `approval: none` are warnings; an `acknowledge_known_issues` id that is not in `config/known-issues/arm-deployment.json` is a warning |
| AZL-050 | The domain join credential (5.5): with `scenario.identity: active_directory` the file has `lcm_user` with a Key Vault password (the default join account) or `domain_join_account`; the LCM user name is valid for Azure Local (1 to 20 letters, numbers, hyphens, underscores, not starting with a hyphen or number) and is not the local administrator's name. |
| AZL-051 | `identity.active_directory.ou_path` is a valid distinguished name (`OU=` or `CN=` parts first, then the `DC=` parts), its `DC=` parts are the labels of `domain_fqdn`, and it has none of `& " ' < >` (Azure Local does not support them). |
| AZL-052 | `identity.active_directory.domain_controllers`, when set, are the DNS servers of every node's management port (the same set): the machines find the domain, and so join it, through them. |
| AZL-053 | Warning: `scenario.identity` is `local_identity` but `domain_join_account` or `local_admin_members` is set; no machine joins a domain. |
| AZL-060 | The environment class (5.6): `scenario.environment_class` is `lab`, `test`, `dev`, `production` or `dmz`; anything else is an error that names the allowed values (a missing class means `production`). Also used for an invalid `os_configuration.remoting.bootstrap_transport` (not `none`, `arc`, `smb` or `auto`), and for an error when the remote management profile could not be evaluated at all (for example a damaged `config/remoting-profiles.json`) |
| AZL-061 | Any and the wildcard (5.6): `allow_any_source` must be `true` or `false` and `trusted_hosts` must be `auto`, `exact` or `wildcard` (other types or values are errors); `os_configuration.remoting.allow_any_source: true` and `trusted_hosts: wildcard` only in `lab` and `test`; `trusted_hosts: exact` is not allowed in `dmz` |
| AZL-062 | Allowed sources (5.6): every `os_configuration.remoting.allowed_source_cidrs` entry is a well-formed IPv4 or IPv6 CIDR, not /0 to /8, and not wider than the class takes (/24 or /64 in `dev` and `production`); a management or out-of-band network wider than that is a warning and is left out of the node firewall scope |
| AZL-063 | At least one source (5.6): `production` and `dmz` need a management network or a listed source that is allowed in the class (an error); `dev` warns |
| AZL-064 | The `dmz` class (5.6): every source is a single address, /32 or /128 |
| AZL-065 | HTTPS (5.6): `use_https: false` (or `transport: winrm` with it) is an error in `production` and `dmz`, a warning in `dev` |
| AZL-066 | The isolation statement (5.6): `isolation_confirmed: true` is not allowed in `dev`, `production` or `dmz`, where Any is never accepted |
| AZL-067 | The server certificate (5.6): `certificate` is a 40-hex thumbprint or a `keyvault://` reference; `dmz` needs one; a certificate with HTTPS off is a warning |
| AZL-068 | The relaxed classes (5.6): `lab` and `test` open WinRM, RDP and ICMP to any source and set TrustedHosts to `*` (a warning that says so; the baseline denylist still holds) |
| AZL-070 | The CI/CD infrastructure (5.5, `devops`; this rule was AZL-030 on its branch, which the SBE delivery rule already held): runner names are unique; one ztp runner (Windows, one VM, with `bmc_cidrs` on `runner_network`) and one Linux general pool; a Windows runner is a VM; a runner needs its `registration_secret` and a subnet inside `runner_network` that overlaps no other; `hub_peering` needs its names; `devops.resource_group` and `runner_network` are needed when runners are; environment names are unique; `authentication.method: client_secret` needs `client_secret` |
| (scope) | `_metadata.scope: ztp` requires only ZTP's keys (see [Which template](#which-template)); `full` requires everything |
Design guidance (which pattern to pick, sizing, best practices) stays in Trailwright, which cites Microsoft Learn for every rule. The toolkit's rules are the ones that stop a deployment.

## Updates after the deployment (schema 5.6.20)

`operations.updates.install_after_deployment` (default `false`) and `operations.updates.target_version` (`latest`, the default, or a solution version such as `12.2610.1004.50`) ask for a solution update after the deployment. One script reads them:

```powershell
./scripts/lifecycle/updates/powershell/Start-SolutionUpdateAfterDeployment.ps1 -InfrastructureFile ./infrastructure.yml [-ComputerName <node>] [-Credential <deployment user>] [-WhatIf]
```

The script connects to the cluster, reads the update environment and the discovered updates, checks that the health is not `Failure`, `Error` or `Warning`, and starts the update with `Start-SolutionUpdate`. It returns without waiting. It starts nothing, and exits 0, when the switch is off, when the instance runs the target version, or when an update is already running (`Downloading`, `Preparing`, `HealthChecking` or `Installing`). An update in a failed state, one that needs vendor content (`AdditionalContentRequired`) or one that needs another update first is reported and left alone: exit code 1. A value in the file that is not usable is exit code 2 and nothing is sent. Follow the run with `Get-SolutionUpdate` on a node, or in Update Manager in the Azure portal; Sonar watches the progress.
## Terraform and Ansible variable files (schema 5.6.17)

The Terraform code (`src/terraform`) and the Ansible roles (`src/ansible`) are an alternative route to tasks the PowerShell scripts do. They need the same facts: names, addresses, subscriptions. Those facts are keys of this file, so the code has no values of its own for them. One script writes the variable files the code reads:

```powershell
./config/variables/scripts/New-IacVariableFiles.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory <a folder outside the repository> [-Target AzureLocal, Backend, CicdInfra, Ansible] [-WhatIf]
```

| Written | Read by |
| --- | --- |
| `terraform/azure-local/terraform.tfvars.json` and `backend.hcl` | `src/terraform/environments/azure-local` (the landing zone, the hub network, the platform Key Vault, the Log Analytics workspace and action group, the management VMs) |
| `terraform/backend/terraform.tfvars.json` | `src/terraform/backend` (the state storage account, named by `devops.state`) |
| `terraform/cicd-infra/terraform.tfvars.json` and `backend.hcl` | `src/terraform/environments/cicd-infra` (the same variables task 06 of the CI/CD set-up builds) |
| `ansible/inventory/group_vars/all.yml` and `host_vars/<node>.yml` | the roles of `src/ansible` |

The mapping is in the registry, not in the script. Each variable of the code is a registry entry under `tools.terraform.variables`, `tools.ansible.variables` or (for the CI/CD runners) `tools.cicd_infra.terraform_variables`, with these fields:

| Field | Meaning |
| --- | --- |
| `class` | `a`: the same fact as a key of this file. `b`: a real choice that has no key yet (`proposed_key` says which). `c`: a setting of the code itself (a module toggle, a tool version, a timeout), with its default in the entry. `d`: belongs to a feature that is out of scope (it says which). |
| `source` | `infrastructure` (written from the file), `tool` (the default in the code; group_vars also gets the registry default), `secret` (the file holds a reference; never written) or `runtime` (not in the file; supplied when the code runs). |
| `infrastructure_key` | The key the value comes from: a dotted path, with `[]` (every item), `[role=hub]` (the items whose role is hub) or `[0]` (the first item). A list means several keys feed the value. |
| `form` | How the value is shaped when it is not a plain copy (`names_map`, `subnets_map`, `present`, `lowercase` and so on; `New-IacVariableFiles.ps1 -ListForm`). |
| `target` | Where it is written: `tfvars`, `backend_hcl`, `group_vars`, `host_vars`, or `none` (a module input or a role default that the generator does not write). |
| `passed_from` | A module variable that receives the value of a variable of the root environment. |
| `same_as` | The same setting in the other tool (Terraform and Ansible install the same tools on a runner); a test checks that the defaults agree. |

A secret is never resolved and never written. The file for a Terraform environment is `terraform.tfvars.json`, which cannot carry a comment, so a variable that is a secret or a run-time value is named in `not-written.txt` next to it, with the environment variable that supplies it (`TF_VAR_vm_admin_password`, for example). In `group_vars/all.yml` the same note is a comment. A secret reference where a value is needed stops the run with exit code 2. The files hold subscription IDs and names: keep the output folder out of git.

The committed `src/ansible/inventory/group_vars/all.yml` is the output for `examples/infrastructure.example.yml`; a test fails when it differs.

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
- Secrets are never values. A password key accepts only a secret reference: `keyvault://<vault>/<secret>`, `env://<VARIABLE>`, `file://<name>` or `command://<name>` (schema 5.6.13). See [Secret references and providers](secret-references.md).
- Anything the schema doesn't define goes under `extensions.<your-key>`: settings for one environment or one tool. Tools ignore keys they don't own.
- The file can hold subscription and tenant IDs. Keep files with real values in private environment repositories, never in a public repository.

## The OS configuration switch (schema 5.4.3)

`os_configuration.network` and `os_configuration.remoting` (since 5.4.4) set the confirmation window of a guarded network change and how the OS configuration reaches the nodes: PowerShell remoting by default, Arc Run Command as an option, and an optional one-time Arc bootstrap that opens a closed node firewall. See [Choosing the transport](../../../docs/os-configuration-and-arm-deployment.md#choosing-the-transport).

`os_configuration.clear_storage` (default `false`) tells `Invoke-AzureLocalOsConfiguration.ps1` to wipe the leftover storage of re-used machines: storage pools, virtual disks and the data on local disks that are not boot, system, SAN or USB. Plan mode lists the disks per machine and wipes nothing; Apply mode wipes only what the plan listed. See [OS configuration and ARM deployment](../../../docs/os-configuration-and-arm-deployment.md#run-it-in-one-go).
## The domain join (schema 5.5)

With `scenario.identity: active_directory`, `Invoke-AzureLocalOsConfiguration.ps1` joins each machine to `identity.active_directory.domain_fqdn`, into `ou_path`, with the LCM user (`lcm_user`; `domain_join_account` overrides it) before the cluster validation and the deployment, then adds `local_admin_members` to the local Administrators group. `join_options.allow_ou_move` (default `false`) allows a move before the deployment only; `rename_after_join` is fixed to `false`. See [Joining the domain](../../../docs/os-configuration-and-arm-deployment.md#joining-the-domain) for the order, the rights, the OU checks, what happens on a failure and what to do with a node in the wrong OU.

## Versioning

`_metadata.schema_version` is the schema version the file follows.

- A **minor** version (5.4.0) adds optional keys. Files written for 5.0 stay valid. One exception: 5.6.2 requires `nodes[].network_adapters[].mac_address` (the identity of the port).
- A **major** version (6.0.0) can rename or remove keys. It comes with a migration in `MIGRATION.md`, and tools refuse files from a major they don't read.

The current version is 5.6.21. 5.6.1 added `security_groups[].local_groups`; 5.6.2 identifies adapters by hardware facts (`mac_address` required; `port_index`, `pci_location`, `vendor`, `os_name_override`, `allowed_vlans`); 5.6.3 added `enabled`, `ip_allocation_method` and `nsg_name` to `networking.logical_networks[]`; 5.6.4 added the SBE package as a requirement (below); 5.6.5 added `landing_zone.policy` (the tag names and the management group of the Tier 1 tag policy); 5.6.6 added `operations.monitoring.action_group` (the name of the alerting action group); 5.6.7 added `security.defender_for_cloud` (the free level of Defender for Cloud); 5.6.8 added `security.defender_for_cloud.security_contact_email`; 5.6.9 added the storage keys `storage.pool`, `storage.csv`, `storage.paths` and the volume options under `storage.volumes`; 5.6.10 added `networking.cluster_network_properties` and the iSCSI deployment keys under `storage.san.iscsi`; 5.6.11 added `networking.network_security_groups`, `networking.logical_networks[].vm_switch_name` and `storage.vm_images`; 5.6.12 added `operations.monitoring.retention_days` and removed `operations.notifications.teams_webhook` and `operations.monitoring.health_alerts`; 5.6.13 added the `secrets` section (`provider`, `file.directory`, `command`) and the `env://`, `file://` and `command://` reference forms; 5.6.14 added `hardware.inventory` (`output_directory`, `file_name_prefix`, `format`, `timeout_seconds`) for `Get-HardwareInventory.ps1`; 5.6.15 added `sdn.acknowledge_maintenance_window` and `sdn.acknowledge_dns_record`, gave `sdn.prefix` and `sdn.dns_records` their rules and a reader (`Enable-ArcSdn.ps1`, SDN enabled by Azure Arc, which cannot be undone) and removed `sdn.default_access_policy`; 5.6.16 added `storage.san.luns[].unique_id` (how `New-SanVolume.ps1` finds the disk of a LUN) and removed `security.backup_key_vault`; 5.6.17 added `landing_zone.management_groups[].role` and `azure.automation_identity.object_id` (read by the Terraform generator, `New-IacVariableFiles.ps1`); 5.6.19 added `provisioning.iso.image_uri` (the address `Invoke-MountGoldImageISO.ps1` gives the BMC virtual media), `landing_zone.subscriptions[].billing_scope` and `workload`, `point_to_site.protocols`, `root_certificate_name` and `root_certificate`, `landing_zone.connectivity.bastion.network` and `nat_gateway`, and a list of values for `landing_zone.virtual_machines[].os`; 5.6.20 added `operations.updates.install_after_deployment` and `operations.updates.target_version` (read by `Start-SolutionUpdateAfterDeployment.ps1`, which starts the solution update after the deployment and returns) and removed the keys that no tool read (see MIGRATION, To 5.6.20); 5.6.21 added `landing_zone.network_security_groups` (the network security groups of the landing zone networks, created by `New-LandingZoneNsg.ps1`) and `security.baseline_settings` (the individual security baseline settings that `Set-SecurityBaselines.ps1` changes with `Set-AzsSecurity`). Each key's description says which version added it.

## How a variable is added

The registry is the only master (rule R19). A variable that exists only in a script, an infrastructure file, a hand-edited schema or a document is drift, and the tests fail on it.

1. **Registry first.** Add the entry to [`schema/master-registry.yaml`](../schema/master-registry.yaml): `type`, `description`, `required`, `default`, `enum` or limits, `example` (a documentation placeholder: RFC 5737 addresses, the zero GUID, `00:00:5E:00:53:xx` MACs, `example.com`; never a value from a real environment), `used_by` (only the purposes whose code reads it) and `since`. A key no tool reads yet says "Not read by the tools yet". A parameter, setting or event of a tool goes under `tools.<tool>.<kind>.<group>.<name>`.
2. Bump `_metadata.version`, add a `_metadata.change_log` entry and a line to the change log in the file header (one of each per bump); bump `_metadata.infrastructure_schema_version` when a key of `infrastructure.yml` changes.
3. Regenerate: `./config/variables/scripts/New-InfrastructureArtifacts.ps1`, then `./config/variables/scripts/New-ToolMapping.ps1 -Tool ztp` and `-Tool sonar`. Check with `-Check`.
4. Only then change the script, the example and this page; add or update the tests (`tests/variables`, `tests/infrastructure`).
5. Run the checks in [`config/variables/README.md`](../README.md#checks).

Change the schema, the examples, the tests and this page together. The tests in `tests/infrastructure` validate every example and check every rule.
