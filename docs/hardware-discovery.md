# Hardware discovery through Redfish

Hardware discovery is the **first stage of the flow**: it runs before azurelocal-ztp and before the OS configuration. It reads
each node's BMC over Redfish (read only) and writes one JSON file per node with everything the BMC offers. The discovered facts
later update `infrastructure.yml`; the JSON is the contract, and `infrastructure.yml` only gets the keys the master variable
registry already has (service tag as `serial_number`, the MAC and name of every port).

```text
BMC addresses (Phase 01 Task 01) -> Discovery (Phase 01 Task 02) -> <serial>.json per node -> infrastructure.yml -> ZTP -> OS configuration
```

**This version supports Dell iDRAC only.** Any other BMC is reported for that node as `Unsupported vendor in this version`
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
.\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml

.\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml -Detail Summary -ThrottleLimit 2
.\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml -Vendor Dell -UseSession
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
```

Fixtures are in `tests/fixtures/redfish/dell/` and are generated by `New-DellFixture.ps1`. Each is labelled `synthetic`; a test fails on a real-looking MAC, serial or lab identifier.

## Not in this version

- Other vendors (above).
- New `infrastructure.yml` keys from the discovered facts (boot device, TPM, GPUs, drives, firmware). They go through the master variable registry first (`config/variables`), then the schema.
- Windows drivers (outside Redfish; the OS configuration run reads those).
- RDMA state (not in standard Redfish; the field is `source: unknown`) and GPU memory.
