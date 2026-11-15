# Dell PowerSwitch OS10 configuration for Azure Local

The template of a Dell PowerSwitch top-of-rack pair running SmartFabric OS10 for Azure Local with RDMA (RoCE) storage traffic, and Dell's guides. The template holds no site value: every value of a site is a placeholder named after the `infrastructure.yml` key it comes from, and `New-SwitchConfiguration.ps1` fills it.

## Files in this directory

| File | Description |
|------|-------------|
| `tor.os10.template` | The switch configuration template, rendered once per `network_devices[]` entry of type `switch` and vendor `Dell`. Its header explains the placeholders |
| `guides/azlocal-switch-config-roce-iwarp.md` | Dell AX reference guide - switch configs for RoCE and iWARP (markdown) |
| `guides/os10-ch05-cli-basics.md` | Dell OS10 User Guide - Chapter 5: CLI Basics |
| `guides/os10-ch06-advanced-cli.md` | Dell OS10 User Guide - Chapter 6: Advanced CLI Tasks |
| `guides/os10-ch07-zero-touch-deployment.md` | Dell OS10 User Guide - Chapter 7: Zero-Touch Deployment |
| `guides/os10-ch08-provisioning.md` | Dell OS10 User Guide - Chapter 8: Provisioning |
| `guides/os10-ch17-security.md` | Dell OS10 User Guide - Chapter 17: Security |
| `guides/os10-ch19-acl.md` | Dell OS10 User Guide - Chapter 19: ACLs and Route Maps |

## Writing the configuration of a switch

```powershell
./scripts/deploy/03-onprem-readiness/phase-03-network-infrastructure/task-02-dell-powerswitch-configuration/powershell/New-SwitchConfiguration.ps1 `
    -InfrastructureFile ./infrastructure.yml -OutputDirectory ./switch-config -WhatIf
```

`-WhatIf` renders and checks every switch and writes nothing; without it the script writes `<hostname>.cfg` per switch. It never connects to a switch. Keep the output folder out of the repository: the files hold the site's addresses. Review each file, then apply it on its switch (console or SSH: `configure terminal`, paste, `show running-configuration`, `write memory`).

## Where each value comes from

| Part of the configuration | `infrastructure.yml` keys |
|---|---|
| Hostname, management address | `network_devices[].hostname`, `network_devices[].management.ip_address` |
| Management prefix and route, SSH source | `networking.oob.subnet`, `networking.oob.gateway` |
| Time zone (UTC offset of the Windows time zone ID) | `site.time_zone` |
| VLANs | `networking.management.vlan_id`, `network_devices[].ports.native_vlan_id`, `networking.oob.vlan_id`, `networking.logical_networks[].vlan_id`, `networking.storage.networks[]` (only with `scenario.storage_connectivity` switched) |
| QoS (PFC and ETS) | `networking.intents[]` with storage traffic: `overrides.qos.cluster_priority`, `smb_priority`, `smb_bandwidth_percent` (registry defaults 7, 3 and 50: Network ATC); the cluster reservation is 1 percent above 10 Gbps, else 2 (`hardware.network_cards[].ports[].speed_gbps` of the storage adapters) |
| Ports, MTU | `network_devices[].ports.uplinks`, `node_ports`, `peer_link`, `network_devices[].mtu` |
| VLT pair | `network_devices[].ha.domain_id`, `peer_address`, `priority`, `system_mac` |
| DNS and NTP | `networking.management.dns_servers`, `networking.ntp_servers` |
| Login | `network_devices[].credentials.username`; the password is a secret reference that the script names and never reads |

Values that stay in the template are fixed by Dell or Microsoft and say so in a comment: the SSH ciphers, LLDP and DCBX, the console and session hardening, RSTP with bridge priority 4096, the OS10 syntax. Syslog and SNMP forwarding are parked: the template leaves them out, and they have no keys.

## Supported switch models

The template follows Dell's reference for PowerSwitch models running SmartFabric OS10 that are listed on the [Microsoft Azure Local ToR switch compatibility list](https://learn.microsoft.com/azure/azure-local/concepts/physical-network-requirements#network-switches-for-azure-local), for example the S4112F-ON, S4148F-ON, S5212F-ON, S5148F-ON, S5232F-ON and S5248F-ON. Port names differ by model: they are `network_devices[].ports`, not part of the template. Dell's guide has model-specific examples: [guides/azlocal-switch-config-roce-iwarp.md](guides/azlocal-switch-config-roce-iwarp.md).

## QoS

Network ATC configures the hosts with cluster heartbeat priority 7 (1 percent above 10 Gbps, 2 percent otherwise), SMB Direct priority 3 with 50 percent, and priority 0 for the rest, and Microsoft says the physical network must match ([Network ATC default values](https://learn.microsoft.com/windows-server/networking/network-atc/network-atc#default-network-atc-values)). The template takes the same numbers from the file, so a change in `networking.intents[].overrides.qos` changes both. Dell's older guides use priority 5 for the cluster class; the toolkit follows Network ATC.

## Additional security hardening (optional)

Dell's AX reference guide includes more security settings (FIPS, password complexity, SSH authentication tries, session limits, shutting unused ports). Apply them if your security policy needs them; see [guides/azlocal-switch-config-roce-iwarp.md](guides/azlocal-switch-config-roce-iwarp.md), "Switch security and other settings".

## References

- [Microsoft - Physical network requirements for Azure Local](https://learn.microsoft.com/azure/azure-local/concepts/physical-network-requirements)
- [Microsoft - Host network requirements for Azure Local](https://learn.microsoft.com/azure/azure-local/concepts/host-network-requirements)
- [Microsoft - Network ATC default values](https://learn.microsoft.com/windows-server/networking/network-atc/network-atc#default-network-atc-values)
- The Dell guides in `guides/`
