# infrastructure.yml: the one environment file

`infrastructure.yml` describes one Azure Local instance: the design choices, the machines, the networks, identity, the Azure targets, how the OS gets onto the machines, and the cluster deployment. Every Azure Local tool reads the same file:

| Tool | Reads | Writes |
| --- | --- | --- |
| [azurelocal-toolkit](https://github.com/AzureLocal/azurelocal-toolkit) | Everything its scripts need, through `Import-AzlInfrastructure` | No |
| [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) | `scenario`, `azure`, `key_vaults`, `nodes`, `hardware`, `networking.management`, `networking.ntp_servers`, `identity.local_admin`, `provisioning`, `tags` | No |
| [Trailwright](https://labs.hybridsolutions.cloud/azurelocal-trailwright/) | The design sections | Yes: it produces the file from a guided design |
| Beacon, Sonar, Ranger | Addresses, names and identity for their checks and reports | No |

The ARM parameters for Microsoft's deployment templates come from this file. The schema descriptions name the ARM parameter each key becomes.

## Files

| File | What it is |
| --- | --- |
| [`infrastructure.schema.json`](infrastructure.schema.json) | The contract: JSON Schema draft 2020-12. Its `$id` is `https://azurelocal.cloud/schemas/infrastructure/5/infrastructure.schema.json`. |
| [`infrastructure.example.yml`](infrastructure.example.yml) | A complete file with every section and placeholder values: Active Directory, Storage Spaces Direct, switched, simplified provisioning, ARM. Start here. |
| [`examples/`](examples) | One file per scenario: local identity and switchless with Arc gateway, disaggregated Fibre Channel with a proxy, rack aware with ZTP, disconnected operations, single machine. |
| [`MIGRATION.md`](MIGRATION.md) | Where every key from the earlier files went: the environment file ZTP read, the toolkit's `variables.yml` (registry 4.0.0), and Trailwright's export. |

## Start a file

1. Copy `infrastructure.example.yml`, or the example closest to your design, to your environment repository as `infrastructure.yml`. Or produce it with Trailwright.
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
| `os_install` | `iso`, `simplified` | `simplified`: `provisioning.simplified`, and on every node `serial_number`, `bmc.ip_address` and `management.mac_address` |
| `deploy_method` | `portal`, `arm` | |

There is no unattended install from an ISO. With `iso`, the OS is installed first; the toolkit's OS configuration starts after that.

## The management port and the Arc machine name

Two settings decide what happens to each machine before deployment. Both are optional, schema 5.1.

| Key | Values | What it does |
| --- | --- | --- |
| `networking.management.ip_assignment` | `static` (default), `dhcp`, `preconfigured` | How each `nodes[].management.ip_address` gets onto the management port, the one with `nodes[].management.mac_address`. `static`: the address, mask, gateway, DNS servers and `vlan_id` are set on that port. Simplified provisioning sets them at the OS install (edge machine `networkAdapters[]`, `ipAssignmentType: Manual`, keyed by the MAC). For an ISO install, the operator or the toolkit sets them. `dhcp`: the port stays on DHCP, so reserve each address for its MAC. `preconfigured`: the port is already set up, and the tools don't change it. |
| `nodes[].arc_machine_name` | 1-54 letters, digits, `-`, `_`, `.`, not ending in `.` | The Arc machine name. Default: `nodes[].name`. Simplified provisioning sets it when it claims the machine (edge machine `arcMachineResourceId`). Without it the service names the Arc machine `ROE1-<id>`, and an Arc machine can't be renamed. An ISO install registers the Arc machine under the host name. |

`ip_assignment` isn't `networking.management.use_dhcp`. `use_dhcp` is the deployment's ARM `useDhcp`, which takes the host and cluster addresses from DHCP instead of the infrastructure pool. In scripts, read both settings with `Get-AzlManagementIpAssignment` and `Get-AzlArcMachineName`, which apply the defaults.

## What the check covers

**The schema** checks structure, types, formats (IPv4, CIDR, MAC, GUID), the `keyvault://` form, name lengths (cluster and node names up to 15 characters, the LCM user up to 20), and the conditional sections above. Every section rejects unknown keys, so a misspelt key is an error, not a silently ignored value.

**The toolkit's rules** check what a JSON schema can't. Each finding has an ID; rules that come from Microsoft's documentation link to it.

| ID | Rule |
| --- | --- |
| AZL-000 | `schema_version` is 5.x |
| AZL-001 | Every `keyvault://` reference names a vault listed in `key_vaults` |
| AZL-002, AZL-003 | Node names and management addresses are unique |
| AZL-004 | Node addresses and the gateway are in the management subnet |
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

Design guidance (which pattern to pick, sizing, best practices) stays in Trailwright, which cites Microsoft Learn for every rule. The toolkit's rules are the ones that stop a deployment.

## Use it from a script

```powershell
Import-Module ./scripts/common/infrastructure/AzlInfrastructure.psm1
$infra = Import-AzlInfrastructure -Path ./infrastructure.yml   # stops if the file has errors
$gateway = $infra.networking.management.gateway
$value = Get-AzlInfrastructureValue -Infrastructure $infra -Path 'provisioning.simplified.site_name'
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

## Versioning

`_metadata.schema_version` is the schema version the file follows.

- A **minor** version (5.1.0) adds optional keys. Files written for 5.0 stay valid.
- A **major** version (6.0.0) can rename or remove keys. It comes with a migration in `MIGRATION.md`, and tools refuse files from a major they don't read.

Change the schema, the examples, the tests and this page together. The tests in `tests/infrastructure` validate every example and check every rule.
