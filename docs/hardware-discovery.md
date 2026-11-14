# Hardware discovery through Redfish

There are two scripts in Phase 01, Task 02. Use `Get-HardwareInventory.ps1` for the inventory of any maker. Use `Invoke-HardwareDiscovery.ps1` (Dell only) when you also want the proposal for `nodes[]` and the write-back of serial numbers and MAC addresses.

| | `Get-HardwareInventory.ps1` | `Invoke-HardwareDiscovery.ps1` |
|---|---|---|
| Makers | Any BMC that offers the DMTF Redfish standard (Dell, DataON, Lenovo, HPE and others) | Dell iDRAC only |
| Reads | Standard Redfish resources only. No vendor (OEM) path. | Standard resources and the Dell adapter (OEM paths) |
| Writes | One inventory file per run (JSON or YAML) | One JSON file per node, a summary and a proposal for `nodes[]` |
| Input | `-InfrastructureFile` only. The BMC password is a secret reference. | `-InfrastructureFile`, and `-Credential` or the secret reference in the file. It never asks. |

## The hardware inventory (any maker)

`scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Get-HardwareInventory.ps1`

```powershell
./Get-HardwareInventory.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf   # the plan; no BMC is contacted
./Get-HardwareInventory.ps1 -InfrastructureFile ./infrastructure.yml           # reads every BMC, writes the file
```

Exit codes: 0 done; 1 a precondition or a call failed (a BMC that cannot be read is recorded as failed in the file, and the file is still written); 2 a value in the file is missing or unusable (nothing was sent to any BMC).

### Where the values come from

Only `infrastructure.yml`. The BMC address is `nodes[].bmc.ip_address`. The login is `nodes[].bmc.username` and `password`, else `hardware.bmc`. The password is a secret reference (`keyvault://`, `env://`, `file://` or `command://`) that the toolkit secret resolver (`scripts/common/secrets/AzlSecret.psm1`) reads; the script never asks for a password and never writes one. The certificate is checked when `hardware.bmc.verify_certificate` is true.

| Key | Default | Meaning |
|---|---|---|
| `hardware.inventory.output_directory` | `hardware-inventory` | Folder of the inventory file. Keep it out of git: it holds serial numbers and MAC addresses. |
| `hardware.inventory.file_name_prefix` | `hardware-inventory` | The file is `<prefix>-<UTC time>.json` (or `.yml`). Every run writes a new file. |
| `hardware.inventory.format` | `json` | `json` or `yaml`. |
| `hardware.inventory.timeout_seconds` | `60` | How long to wait for one answer of a BMC (5 to 600). |

### Read only, standard resources only

The script sends GET requests only (checked by a test on every request). It reads: Systems (identity, BIOS version, Secure Boot, TrustedModules, and `Links.TrustedComponents` when TrustedModules lists nothing), Processors (CPU and GPU), Memory, Storage and Drives (and Volumes, to see which drives are in a RAID volume), NetworkAdapters with Ports and NetworkDeviceFunctions, Chassis, Managers (version, MAC), and UpdateService FirmwareInventory. It does not read the BIOS attributes, sensors or logs (the Dell flow does).

No vendor extension is needed for any field. When a BMC shows a fact only under its OEM path, the field is the text `not reported`, and the path of the field is in `notReported` of the node. There is no per-vendor table in this version. If one is ever needed it must be a small, clearly named, optional table; none exists today.

### What the file holds

| Block | Content |
|---|---|
| `rules` | The rules below, in words |
| `nodes[]` | Per node: `status` (`read` or `failed`, with `error`), `vendor` (what the Redfish answers say it is), `identity` (manufacturer, model, `serialNumber`, `sku`, `chassisSerialNumber`, UUID, asset tag), `cpu`, `memory` (total, ECC, modules), `drives[]`, `driveSummary`, `network.ports[]`, `gpu`, `tpm`, `secureBoot`, `bios.version`, `bmc` (model, firmware, MAC), `firmware[]`, `notReported[]`, `readErrors[]` |
| `symmetry[]` | Is each fact the same on every machine? Required by Microsoft: manufacturer, model, processors, network adapters, number and type of drives, capacity and firmware of drives. Recommended: drive model. Information: memory, BIOS and BMC version. Result `same`, `differs` or `not reported`. |
| `planComparison[]` | For each hardware key that `infrastructure.yml` sets (`hardware.vendor`, `model`, `cpu_cores`, `memory_gib`, `gpu.*`, `drives.capacity.*`, `drives.cache.*`, `nodes[].bmc.type`, `nodes[].serial_number`): planned, found, `match`, `differs` or `not reported`. Report only; the exit code does not change. |

Which serial number is the service tag depends on the maker and is not in the standard, so the file keeps `serialNumber`, `sku` and `chassisSerialNumber` side by side.

### Drive media type and role

- **Media type.** `NVMe` when the Redfish `Protocol` is NVMe. Otherwise the Redfish `MediaType`: `SSD` is SSD; `HDD` and `SMR` are HDD. If the BMC gives neither, `not reported`.
- **Role (cache or capacity).** This is the Storage Spaces Direct default (Microsoft Learn, [Understanding the storage pool cache](https://learn.microsoft.com/windows-server/storage/storage-spaces/cache)): when more than one media type is present, all drives of the fastest type (NVMe, then SSD, then HDD) are cache and the others are capacity. When all drives are one type, no cache is set up and every drive is capacity. Examples: NVMe and SSD, NVMe is cache. SSD and HDD, SSD is cache. NVMe, SSD and HDD, NVMe is cache for both.
- **Not counted** (role `excluded`, with the reason in `roleReason`): a drive that is not present, and a drive that is a member of a RAID volume of its controller. Azure Local does not support RAID for Storage Spaces Direct drives, and the boot mirror of a boot card is such a volume. A boot drive that is not in a RAID volume cannot be told from a data drive by the standard resources; check `drives[]` for it.
- The role is what Storage Spaces Direct will do by default. It is not read from a machine, and the file does not judge it (all-HDD is listed as capacity; Microsoft does not support it).
- Sizes are `sizeBytes`, `sizeGiB` and `sizeTB` (decimal terabytes, as drives are sold). `blockSizeBytes` is the Redfish `BlockSizeBytes` (512 or 4096), when the BMC gives it.

### Network ports

`network.ports[]` lists every port of every adapter with `order`, `adapter`, `portNumber`, `mac` (upper case, colons), adapter `manufacturer`, `model` and `firmware`, `linkStatus` and `speedMbps`. The order is the order in which the BMC lists the adapters, then the port number on the adapter. It is not the PCI bus order (the standard has no field for it). RDMA mode and the PCI location are vendor data and are not in the file.

### Sources

- Microsoft Learn, Azure Local system requirements (view azloc-2610): [https://learn.microsoft.com/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610](https://learn.microsoft.com/azure/azure-local/concepts/system-requirements-23h2?view=azloc-2610): same model, processors, adapters and drives on every machine; ECC memory; TPM 2.0 and Secure Boot; drives direct attached, no RAID; at least two data drives; hybrid needs flash for cache.
- Microsoft Learn, Drive symmetry considerations: [https://learn.microsoft.com/windows-server/storage/storage-spaces/drive-symmetry-considerations](https://learn.microsoft.com/windows-server/storage/storage-spaces/drive-symmetry-considerations): same types and same number of each type are required; same model and size are recommended.
- Microsoft Learn, Understanding the storage pool cache: [https://learn.microsoft.com/windows-server/storage/storage-spaces/cache](https://learn.microsoft.com/windows-server/storage/storage-spaces/cache): the fastest type is cache; one type means no cache.
- DMTF Redfish schemas: [https://redfish.dmtf.org/schemas/v1/Drive.v1_20_0.json](https://redfish.dmtf.org/schemas/v1/Drive.v1_20_0.json) (MediaType HDD, SSD, SMR; Protocol; BlockSizeBytes; CapacityBytes; Revision), [Processor](https://redfish.dmtf.org/schemas/v1/Processor.v1_20_0.json) (ProcessorType CPU, GPU, FPGA, DSP, Accelerator; ProcessorMemory), [ComputerSystem](https://redfish.dmtf.org/schemas/v1/ComputerSystem.v1_22_0.json) (BiosVersion, SKU, SerialNumber, TrustedModules deprecated for Links.TrustedComponents), [NetworkAdapter](https://redfish.dmtf.org/schemas/v1/NetworkAdapter.v1_12_0.json) (Controllers, Ports; NetworkPorts deprecated).

### Not verified

Only unit tests exist. They run against made-up Redfish trees in three shapes (iDRAC-like, iLO-like, AMI/ODM-like such as DataON) with every HTTP call mocked. The script has not been run against a real BMC of any maker. Real BMCs differ in details the standard allows (where the adapters are, whether Ports or NetworkPorts, which fields are filled). Expect "not reported" fields on real hardware; they show what a maker leaves out of the standard resources. The `Links.TrustedComponents` read has not been checked against any real BMC.

Hardware discovery is the **first stage of the flow**: it runs before azurelocal-ztp and before the OS configuration. It reads
each node's BMC over Redfish (read only) and writes one JSON file per node with everything the BMC offers. The discovered facts
later update `infrastructure.yml`; the JSON is the contract, and `infrastructure.yml` only gets the keys the master variable
registry already has (service tag as `serial_number`, the MAC and name of every port).

```text
BMC addresses (Phase 01 Task 01) -> Discovery (Phase 01 Task 02) -> <serial>.json per node -> infrastructure.yml -> ZTP -> OS configuration
```

**`Invoke-HardwareDiscovery.ps1` supports Dell iDRAC only.** Any other BMC is reported for that node as `Unsupported vendor in this version`
(with what was detected and why) and nothing else is read from it. HPE iLO, Lenovo XClarity, Supermicro/AMI (DataON and other
OEM boxes) are planned in `pmo/azure-local/redfish-multivendor-discovery-plan.md` and are not built.

## Parts

| Part | File | Job |
|---|---|---|
| Core | `scripts/common/redfish/AzlRedfishCore.psm1` | Read-only HTTP, standard DMTF resources, vendor detection, capability report, bounded parallelism |
| Dell adapter | `scripts/common/redfish/AzlRedfishDell.psm1` | Only what is Dell: port names, the service tag, the BOSS boot device, iDRAC attributes, firmware states, `Oem.Dell` raw blocks |
| Orchestrator | `.../phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/Invoke-HardwareDiscovery.ps1` | Loops over `nodes[]`, picks the adapter by detected vendor (`-Vendor Dell` forces it), writes the files |
| Fixtures | `tests/fixtures/redfish/dell/` | Synthetic Redfish trees for the tests (not real captures) |

The core follows links from `/redfish/v1` (Systems, Chassis, Managers, UpdateService) and never hard-codes a member ID; the
adapter's well-known paths are used only when `-Vendor Dell` is given and the service root links nothing.

## Rules the code keeps

- **Read only.** The HTTP layer has no method parameter and sends GET. With `-UseSession` there is also one session POST and the DELETE of that session in a `finally`. A test fails if any other request reaches the HTTP layer.
- **No secrets in output.** The password, the session token and Authorization headers never reach a log, an error or the file. Secret-looking BIOS and iDRAC attribute values are written as `<redacted>` (the key stays). The output holds serial numbers and MACs: keep the folder out of git.
- **Errors are data.** A resource the BMC does not offer (404, 501) is `notSupported`, 401/403 is `denied`, a timeout or 5xx is `error` (after one retry). Each is in `readErrors` and in the capability report. Three rejected logins in a row stop that BMC (lockout guard).
- **Unknown is `null`**, never an empty string. MACs are `AA:BB:CC:DD:EE:FF`.
- **Bounded parallelism.** `-ThrottleLimit` nodes at a time (default 4, 1 to 16); the requests to one node are sequential. A failing node never stops the others.
- **TLS.** Self-signed certificates are accepted unless `-VerifyCertificate`; the skip applies to these requests only.

## Run it

```powershell
# every node with nodes[].bmc.ip_address, full detail, 4 at a time; writes .\discovery\<ServiceTag>.json
.\Invoke-HardwareDiscovery.ps1 -InfrastructureFile .\infrastructure.yml

.\Invoke-HardwareDiscovery.ps1 -InfrastructureFile .\infrastructure.yml -Detail Summary -ThrottleLimit 2
.\Invoke-HardwareDiscovery.ps1 -InfrastructureFile .\infrastructure.yml -Vendor Dell -UseSession
```

Then review `discovery\infrastructure.discovered.yml` and run `Update-InfrastructureYml-FromDiscovery.ps1` (preview, then `-Apply`).
Both the older 1.0 files and the 2.0 files are read.

## The per-node JSON (schemaVersion 2.0)

`Summary` reads identity, BMC interfaces, summary values, network, storage and the boot device. `Full` (default) reads everything below.

| Block | Content |
|---|---|
| `schemaVersion`, `tool`, `collectedAt`, `durationSeconds`, `bmcAddress`, `detail`, `nodeName` | provenance |
| `vendor` | `name`, `family` (idrac9...), `generation`, `confidence` (`high` Oem namespace, `medium` Manufacturer, `low` text, `override`), `evidence[]`, `adapter` |
| `identity` | manufacturer, model, `serialNumber`, `serviceTag` (Dell SKU), uuid, assetTag, hostName, powerState, chassis, `voucherSerialCandidates[]` (every serial the BMC offers) |
| `bmc` | manager model and firmware, MAC, `interfaces[]` (MAC, IPv4, VLAN, speed, link), `protocols`, `certificates[]` |
| `system` | BIOS version, boot mode and order, `secureBoot`, `tpm[]`, `virtualization` (Dell: from BIOS attributes), health, `processorSummary` |
| `processors[]`, `memory{totalGiB, modules[]}`, `pcie[]`, `gpus[]` | CPUs; DIMMs (empty slots with `present: false`); PCIe devices with functions; GPUs derived from them |
| `network.adapters[]` | per adapter: manufacturer, `model`, `modelSource`, `modelRejected[]`, firmware package, `ports[]` (name, slot, port number, MAC and `macSource`, permanent MAC, link, speed, max speed, MTU, LLDP if offered) and `functions[]` |
| `storage` | `controllers[]`, `drives[]` (serial, firmware, capacity, media, protocol, bay, life left, `isBoot`), `volumes[]`, `bootDevice{kind, controllerId, driveIds, volumeId, capacityGiB, hasVirtualDisk, needsVirtualDisk, detection}` |
| `firmware[]` | component, id, version, updateable, category (bios, bmc, nic, storage, drive, cpld, psu, gpu, other), `entryState` (Dell: installed, current, previous) |
| `settings` | `bios{attributes, pendingAttributes, registryVersion}`, `bmc{attributes, source}` |
| `health` | `sensors[]`, `power`, `thermal`, `leds` |
| `events` | `logServices[]` and a `summary` (total, critical, warning, last critical, last entry, last 10 messages); never the whole log |
| `raw.dell` | `Oem.Dell` blocks of the system, chassis and manager, secrets removed, size capped |
| `capabilities` | the capability report (below) |
| `readErrors[]` | `{area, path, status, kind, message, retried}` |
| `warnings[]` | non-fatal observations (a port without a MAC, an empty SKU) |

### Port names and the card model

Every port also carries the facts the file keeps for it, the same keys for any vendor: `portIndex` (the number of the port on its card, from 1), `pciLocation` (bus, device, function, when the BMC reports it; the Dell adapter reads it from `Oem.Dell.DellNIC` and marks that path `inferred`), `rdma` (only when a vendor adapter reports it), the adapter `manufacturer` and `model`, and the link speed now and the highest the port supports. The proposal file writes them as `nodes[].network_adapters[]` keys (`mac_address`, `slot`, `port_index`, `pci_location`, `vendor`, `model`, `speed_gbps`, `rdma`). The adapter is identified by its MAC; `name` is the key intents refer to, derived from the slot and the port, never an OS name.

Port names come from the **Port resource**, not from the adapter ID. The LOM lists both of its ports under the adapter
`NIC.Embedded.1`, as `NIC.Embedded.1-1` and `NIC.Embedded.2-1`; they are `Embedded NIC 1` and `Embedded NIC 2` (it used to be `Embedded NIC 1 (2)`).

An adapter's model is the first real value of: the adapter `Model`, the Dell NIC product name, the controller entries, the linked
PCIe device (`Model`, then `Description`), the adapter `Name`, and with `Full` the firmware inventory entry of the card. Generic
Dell labels are never a model (`Network Adapter View`, `Network Adapter`, `NIC in Slot 3`, `Embedded NIC 1`, `NIC.Embedded.1`,
`Network Adapter - NIC.Embedded.1`). If nothing names the card, `model` is `null`, `modelSource` is `none`, `modelRejected[]` lists what was refused,
and the `network` area of the capability report carries a note.

### Capability report

Per area (`identity`, `bmc`, `security`, `processors`, `memory`, `pcie`, `network`, `storage`, `firmware`, `bios`, `sensors`, `events`):
`status` (`ok`, `partial`, `notSupported`, `denied`, `error`, `skipped`), the `paths` read, the `schemaVariant` used (for example
`NetworkAdapters@Systems, NetworkPorts` or `Ports`, `Power, Thermal` or `PowerSubsystem, ThermalSubsystem, Sensors`,
`Chassis/PCIeDevices` or `Systems/PCIeDevices`), the `count`, a `reason` when not ok, and `notes[]`. Also `oemPaths[]`, every vendor path the adapter used, each with a `basis`:

- `lab-observed`: seen in the evidence scans of the lab AX-760 nodes.
- `documented`: named in Dell's iDRAC9 Redfish API guide or BIOS attribute registry; not seen on hardware here.
- `inferred`: not confirmed in either; needs a scan on real hardware. These are listed in `needsHardwareVerification`.

PCIe devices are looked for under the Chassis (where iDRAC9 has them) first, then under the Systems; the path that worked is recorded.
A 404 on the path that is not used is not an error.

## Verified on / not verified

Only Dell iDRAC9 has been seen on real hardware (three AX-760 nodes, BIOS 2.7.5). Everything else is code and tests against **synthetic** fixtures.

| Vendor / BMC | Status | Seen on real hardware | Not verified |
|---|---|---|---|
| Dell iDRAC9 (AX-760, 16G) | Built | Service tag as System `SKU`; NetworkAdapters, ports with `PhysicalPortNumber`; storage controllers, drives, volumes, BOSS-N1; firmware inventory (`Installed-`, `Current-`, `Previous-`); processors, memory modules, Power and Thermal; the BIOS and iDRAC attribute reads; the Systems `PCIeDevices` path is a 404 (Chassis path used) | The Chassis `PCIeDevices` read end to end (fix is from the lab's finding, tested on a synthetic tree); `Oem.Dell.DellNIC.ProductName` (inferred); `IommuSupport` (inferred); sensors via the newer `Sensors`/`PowerSubsystem` schema; event log reads; `-UseSession`; the SecureBoot and TrustedModules reads; certificate read; behaviour on iDRAC8 and iDRAC10 |
| Dell iDRAC8 / iDRAC10 | Detected, adapter runs, **not verified** | No | Everything |
| HPE iLO 5 / 6 | Not built | No | Reports `Unsupported vendor in this version` |
| Lenovo XClarity (XCC) | Not built | No | Reports `Unsupported vendor in this version` |
| Supermicro / AMI (DataON and other OEM) | Not built | No | Reports `Unsupported vendor in this version` |

## Tests

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester ./tests/discovery        # core, Dell adapter, scripts end to end (a fake BMC; nothing is contacted)
Invoke-Pester ./tests/hardware-discovery   # the vendor-neutral inventory: three differently shaped fake BMCs, every HTTP call mocked
```

Fixtures are in `tests/fixtures/redfish/dell/` and are generated by `New-DellFixture.ps1`. Each is labelled `synthetic`; a test fails on a real-looking MAC, serial or lab identifier.

## Not in this version

- Other vendors (above).
- New `infrastructure.yml` keys from the discovered facts (boot device, TPM, GPUs, drives, firmware). They go through the master variable registry first (`config/variables`), then the schema.
- Windows drivers (outside Redfish; the OS configuration run reads those).
- RDMA state (not in standard Redfish; the field is `source: unknown`) and GPU memory.
