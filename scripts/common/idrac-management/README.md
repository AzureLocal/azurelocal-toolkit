# iDRAC management and hardware discovery

Dell iDRAC tools that use the Redfish API. Hardware discovery is the **first stage of the flow**: it runs before
azurelocal-ztp and before the OS configuration, and its output fills `infrastructure.yml`. Discovery itself is the Redfish core
plus the Dell adapter in `../redfish/` (see [docs/hardware-discovery.md](../../../docs/hardware-discovery.md)); this folder keeps the Dell
management tools and the proposal text.

```text
iDRAC addresses (Phase 01 Task 01) -> Discovery (Phase 01 Task 02) -> infrastructure.yml -> ZTP -> OS configuration -> Validate and Deploy
```

| What discovery reads | Where it goes | Who uses it |
|---|---|---|
| Service tag (Redfish `SKU`) | `nodes[].serial_number` | ZTP maps ownership vouchers by it |
| MAC of every network port, with a suggested name and slot | `nodes[].network_adapters[].mac_address` | ZTP finds the maintenance environment by the management MAC; the OS configuration finds every port by MAC |
| Which port is the management port | the port with role `management` (a suggestion you confirm) | ZTP Device stage, OS configuration |
| BOSS card, its drives and whether its virtual disk exists | discovery JSON and summary | Phase 02 Task 01 (create the BOSS virtual disk) |
| BIOS and iDRAC attributes, firmware, PCIe devices and GPUs, memory, sensors, event summary | discovery JSON (one file per node, schemaVersion 2.0, with a capability report of what could not be read and why) | Phase 01 Tasks 04 and 05 |

## Files

| File | Purpose |
|---|---|
| `AzlDellRedfish.psm1` | Management-port selection, the `infrastructure.yml` proposal text, the iDRAC VNC setting (re-exports the credential helpers of the core) |
| `../redfish/AzlRedfishCore.psm1` | Read-only Redfish client and standard collectors, vendor detection, capability report, `Invoke-AzlRedfishDiscovery` |
| `../redfish/AzlRedfishDell.psm1` | The Dell adapter: port names from the Port resource, service tag, BOSS boot device, iDRAC attributes, firmware states |
| `Enable-IdracVnc.ps1` | Enable or disable the iDRAC VNC server (the only tool here that writes to an iDRAC; `-WhatIf` supported) |
| `../redfish/AzlRedfishInventory.psm1` | The vendor-neutral inventory of one node from the standard Redfish resources (no adapter, no OEM path); used by `Get-HardwareInventory.ps1` |
| `../infrastructure/AzlInfrastructureEdit.psm1` | Comment-preserving edits of `infrastructure.yml` |
| `scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api/powershell/` | `Get-HardwareInventory.ps1` (any maker, one inventory file per run), `Invoke-HardwareDiscovery.ps1` (Dell: proposal for `nodes[]`), `Update-InfrastructureYml-FromDiscovery.ps1` |

## Credentials

In this order, never from a plain-text file:

1. `-Credential`.
2. The Key Vault references in `infrastructure.yml` (`nodes[].bmc` or `hardware.bmc`, `username` and `password` as `keyvault://<vault>/<secret>`), read with `Get-AzKeyVaultSecret` (needs `Az.KeyVault` and a signed-in Az session).
3. An interactive `Get-Credential` prompt.

The iDRAC certificate is self-signed by default, so it is not checked unless `-VerifyCertificate` is set (matching `hardware.bmc.verify_certificate`).

## Typical run

```powershell
# 1. Read every node (read only), write the proposal
.\Invoke-HardwareDiscovery.ps1 -ConfigPath .\infrastructure.yml

# 2. Review .\discovery\infrastructure.discovered.yml, then preview what would change in the file
.\Update-InfrastructureYml-FromDiscovery.ps1 -ConfigPath .\infrastructure.yml -ManagementPort 'Slot 3 Port 1'

# 3. Write serial numbers and MACs (backup first, confirmation unless -Force)
.\Update-InfrastructureYml-FromDiscovery.ps1 -ConfigPath .\infrastructure.yml -ManagementPort 'Slot 3 Port 1' -Apply
```

Roles and IP assignment are never written: discovery cannot read them from hardware. Ports are named `Slot 3 Port 1`,
`Embedded NIC 1`; keep one name per port on every node, because networking intents name ports by it.

The output folder (`discovery/`, git-ignored) holds serial numbers and MACs. Do not commit it.

## Enable-IdracVnc.ps1

```powershell
.\Enable-IdracVnc.ps1 -ConfigPath .\infrastructure.yml -WhatIf          # every node with bmc.ip_address
.\Enable-IdracVnc.ps1 -ConfigPath .\infrastructure.yml -TargetNode node-1
.\Enable-IdracVnc.ps1 -BmcAddress '<idrac-address>' -Port 5901 -TimeoutSeconds 3600
```

The VNC password is a `SecureString` (`-VncPassword`) or a Key Vault reference (`-VncSecretReference`), 4 to 8 characters (an iDRAC limit).

## Requirements

PowerShell 7, the `powershell-yaml` module, TCP 443 to the iDRACs, iDRAC 9 with Redfish. Tests: `Invoke-Pester ./tests/discovery` (a fake BMC answering from synthetic fixtures; nothing is contacted).

This version reads Dell iDRAC only. A BMC of another vendor is reported as `Unsupported vendor in this version` for that node.

## Reference

- [Dell iDRAC 9 Redfish API guide](https://www.dell.com/support/manuals/en-us/idrac9-lifecycle-controller-v3.x-series/idrac_3.30.30.30_redfishapiguide/)
- Dell endpoints for Azure Local: `config/oem/dell-endpoints.md`
