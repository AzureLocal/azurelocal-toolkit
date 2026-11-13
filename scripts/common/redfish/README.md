# Redfish discovery core and vendor adapters

Read-only hardware discovery over Redfish. Full description, the per-node JSON, the capability report and the
verified / not verified table: [docs/hardware-discovery.md](../../../docs/hardware-discovery.md).

| File | Job |
|---|---|
| `AzlRedfishCore.psm1` | Vendor-neutral. GET-only HTTP with retry, timeouts, optional session auth and secret redaction; standard DMTF collectors; vendor detection; capability report; `Invoke-AzlRedfishDiscovery`, `Invoke-AzlRedfishBatch` (bounded parallelism), `ConvertTo-AzlDiscoveryLegacyView` |
| `AzlRedfishInventory.psm1` | Vendor-neutral inventory of one node from the report of the core run with `-Vendor None -Detail Inventory`: drive media type and role (cache or capacity), ports in BMC order, GPU, TPM, "not reported" for what the standard resources do not give; the symmetry checks across nodes; the plan against found comparison. Used by `Get-HardwareInventory.ps1` |
| `AzlRedfishDell.psm1` | Dell iDRAC adapter (`Get-AzlRedfishDellAdapter`): port labels, NIC model sources, service tag, BOSS, iDRAC attributes, firmware states, `Oem.Dell` raw blocks. Every OEM path it uses is marked `lab-observed`, `documented` or `inferred` in the capability report |

An adapter is a `Get-AzlRedfish<Vendor>Adapter` command in `AzlRedfish<Vendor>.psm1` next to the core. It returns the vendor name, the
fallback paths, an optional `PortLabel` and `IsGenericModel`, and optional `Hooks` (`OemSystem`, `OemBmc`, `OemNetwork`, `OemStorage`,
`OemFirmware`, `OemSettings`, `OemHealth`) that add only what the standard resources lack. Only the Dell adapter exists in this version.

Every network port carries the same facts for every vendor, because the file keeps them under the same keys (`nodes[].network_adapters[]`): `mac` (the identity), `slot`, `portIndex`, `speedMbps` and `maxSpeedMbps`, the adapter `manufacturer` and `model`, `pciLocation` and `rdma`. The standard Redfish resources give the first ones. `pciLocation` (`bus`, `device`, `function`) and `rdma` (`none`, `iwarp`, `roce`, `roce_v2`) are vendor data: an adapter fills them through the optional hooks `NicPciLocation` (`param($Context, $Function)`) and `NicRdma` (`param($Context, $Function, $Adapter)`); a vendor without them leaves them empty. HPE, Lenovo and the others fill the same keys later, nothing else changes.

Run: `Invoke-HardwareDiscovery.ps1` (Phase 01 Task 02). Test: `Invoke-Pester ./tests/discovery`.
