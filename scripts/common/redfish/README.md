# Redfish discovery core and vendor adapters

Read-only hardware discovery over Redfish. Full description, the per-node JSON, the capability report and the
verified / not verified table: [docs/hardware-discovery.md](../../../docs/hardware-discovery.md).

| File | Job |
|---|---|
| `AzlRedfishCore.psm1` | Vendor-neutral. GET-only HTTP with retry, timeouts, optional session auth and secret redaction; standard DMTF collectors; vendor detection; capability report; `Invoke-AzlRedfishDiscovery`, `Invoke-AzlRedfishBatch` (bounded parallelism), `ConvertTo-AzlDiscoveryLegacyView` |
| `AzlRedfishDell.psm1` | Dell iDRAC adapter (`Get-AzlRedfishDellAdapter`): port labels, NIC model sources, service tag, BOSS, iDRAC attributes, firmware states, `Oem.Dell` raw blocks. Every OEM path it uses is marked `lab-observed`, `documented` or `inferred` in the capability report |

An adapter is a `Get-AzlRedfish<Vendor>Adapter` command in `AzlRedfish<Vendor>.psm1` next to the core. It returns the vendor name, the
fallback paths, an optional `PortLabel` and `IsGenericModel`, and optional `Hooks` (`OemSystem`, `OemBmc`, `OemNetwork`, `OemStorage`,
`OemFirmware`, `OemSettings`, `OemHealth`) that add only what the standard resources lack. Only the Dell adapter exists in this version.

Run: `Invoke-HardwareDiscovery.ps1` (Phase 01 Task 02). Test: `Invoke-Pester ./tests/discovery`.
