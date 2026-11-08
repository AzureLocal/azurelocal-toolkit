# Dell Redfish fixtures (synthetic)

These trees feed the discovery tests (`tests/discovery/Redfish*.Tests.ps1`). **They are not captures from real hardware.**
They are hand-built, DMTF-shaped Redfish responses written by `New-DellFixture.ps1`, in the shape of the lab's first Dell
scan (an AX-760 with an embedded Broadcom LOM, ConnectX-6 cards, NVMe drives and a BOSS-N1 card).

| Fixture | Schema variant | What it is for |
|---|---|---|
| `idrac9-ax760-synthetic/tree.json` | classic: NetworkPorts, Power, Thermal | Both lab defects: the LOM lists port `NIC.Embedded.2-1` under adapter `NIC.Embedded.1`, and that adapter has an empty `Model`. BOSS with a RAID1 virtual disk. |
| `idrac9-newschema-synthetic/tree.json` | newer: Ports, PowerSubsystem, ThermalSubsystem, Sensors | The schema variant selection in the capability report. |

Format: one JSON object, Redfish path -> response body. The key `_fixture` is metadata and is never served.

Values are documentation values only: MACs `00:00:5E:00:53:xx` (RFC 7042), IP addresses from `192.0.2.0/24`, host names under
`.invalid`, serials and service tags starting with `DOC`. The test `Fixtures are scrubbed` fails on a real-looking MAC, serial
or lab identifier. Regenerate with `pwsh -File ./New-DellFixture.ps1`.

A fixture proves the code handles a shape. It does not prove an iDRAC returns that shape: see the verified / not verified
table in `docs/hardware-discovery.md`.
