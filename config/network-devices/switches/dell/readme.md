# Dell PowerSwitch OS10 Configuration for Azure Local

Reference configurations for a Dell PowerSwitch VLT pair running SmartFabric OS10, optimized for Azure Local deployments with RDMA (RoCE) storage traffic.

## Files in this directory

| File | Description |
|------|-------------|
| `tor1-azlocal-config.txt` | Full switch configuration for TOR1 (primary VLT peer) |
| `tor2-azlocal-config.txt` | Full switch configuration for TOR2 (secondary VLT peer) |
| `guides/azlocal-switch-config-roce-iwarp.md` | Dell AX reference guide - switch configs for RoCE and iWARP (markdown) |
| `guides/os10-ch05-cli-basics.md` | Dell OS10 User Guide - Chapter 5: CLI Basics |
| `guides/os10-ch06-advanced-cli.md` | Dell OS10 User Guide - Chapter 6: Advanced CLI Tasks |
| `guides/os10-ch07-zero-touch-deployment.md` | Dell OS10 User Guide - Chapter 7: Zero-Touch Deployment |
| `guides/os10-ch08-provisioning.md` | Dell OS10 User Guide - Chapter 8: Provisioning |
| `guides/os10-ch17-security.md` | Dell OS10 User Guide - Chapter 17: Security |
| `guides/os10-ch19-acl.md` | Dell OS10 User Guide - Chapter 19: ACLs and Route Maps |

## Supported switch models

These configurations are designed for Dell PowerSwitch models running SmartFabric OS10 that are listed on the [Microsoft Azure Local ToR switch compatibility list](https://learn.microsoft.com/en-us/azure/azure-local/concepts/physical-network-requirements?tabs=overview%2C23H2reqs#network-switches-for-azure-local):

- Dell S4112F-ON
- Dell S4148F-ON
- Dell S5212F-ON
- Dell S5148F-ON
- Dell S5232F-ON
- Dell S5248F-ON

Port numbers for VLTi, uplinks, and node ports may differ by model. Adjust `interface` and `interface range` commands accordingly.

## Architecture overview

```
                    ┌──────────────────┐
                    │  Upstream Network │
                    └────────┬─────────┘
                             │
              ┌──────────────┴──────────────┐
              │         Uplink Trunk         │
              │   (ethernet1/1/1 on each)    │
              │                              │
      ┌───────┴───────┐            ┌────────┴──────┐
      │     TOR1      │◄──VLTi────►│     TOR2      │
      │  (Primary)    │  1/1/13-14 │  (Secondary)  │
      │  Priority 100 │            │  Priority 200 │
      └───────┬───────┘            └────────┬──────┘
              │                              │
              │  Node Ports 1/1/2 - 1/1/12   │
              │  (DCB enabled, PFC/ETS)      │
              │                              │
      ┌───────┴──────────────────────────────┴──────┐
      │          Azure Local Cluster Nodes           │
      │     (Mellanox CX5/CX6, Intel E810, etc.)    │
      └─────────────────────────────────────────────┘
```

## Configuration sections explained

### 1. Global settings

| Setting | Command | Purpose |
|---------|---------|---------|
| Hostname | `hostname tor1-iic-azlocal` | Unique switch identity |
| Timezone | `clock timezone EST -5 0` | Local time for logs and timestamps |
| SSH ciphers | `ip ssh server cipher aes256-ctr ...` | Restrict SSH to secure ciphers only |
| SSH MAC | `ip ssh server mac hmac-sha2-256` | SHA-256 MAC for SSH integrity |
| LLDP | `lldp enable` | Link Layer Discovery Protocol for neighbor detection |
| DCBX | `dcbx enable` | Data Center Bridging eXchange for PFC/ETS negotiation |
| Console logging | `logging console disable` | Suppress console log output for cleaner sessions |
| Session timeout | `exec-timeout 1800` | Auto-logout after 30 minutes of inactivity |

### 2. Management interface

The out-of-band management port (`mgmt1/1/1`) is configured with a static IP on the OOB management network. A default route points to the management gateway.

| Parameter | TOR1 | TOR2 | Change for your environment |
|-----------|------|------|-----------------------------|
| Management IP | `10.0.0.6/24` | `10.0.0.7/24` | Use your OOB management subnet |
| Default gateway | `10.0.0.1` | `10.0.0.1` | Your management gateway |

The default route uses `management route 0.0.0.0/0 <gateway>` because the management interface resides in the `management` VRF. Standard `ip route` commands only affect the default VRF and will not route management-interface traffic.

### 3. VLAN definitions

| VLAN ID | Name | Subnet | Purpose |
|---------|------|--------|---------|
| 700 | oob-mgmt | `10.0.0.0/24` | Out-of-band management (switch, BMC/iDRAC) |
| 710 | mgmt | `10.0.1.0/24` | Azure Local node management |
| 720 | compute | `10.0.2.0/24` | VM workload traffic |
| 711 | storage1 | L2 only | RDMA/S2D storage traffic |
| 712 | storage2 | L2 only | RDMA/S2D storage traffic |
| 713 | storage3 | L2 only | RDMA/S2D storage traffic (optional) |
| 714 | storage4 | L2 only | RDMA/S2D storage traffic (optional) |
| 730-734 | tenant1-5 | `10.0.10-14.0/24` | Tenant/workload isolation VLANs |

Storage VLANs are Layer 2 only (no IP address assigned at the switch level). RDMA traffic between nodes stays within the VLAN at L2.

Adjust VLAN IDs and subnets to match your network design. Add or remove tenant VLANs as needed.

### 4. QoS / DCB (PFC + ETS)

This is the most critical section for Azure Local RDMA performance. The configuration follows the Dell AX reference guide for Mellanox and Intel E810 based deployments.

| Priority | Traffic class | Queue | Bandwidth | PFC |
|----------|--------------|-------|-----------|-----|
| 0-2, 4, 6-7 | S2DManagement (default) | Q0 | 48% | No |
| 3 | SmbStorage (RDMA) | Q3 | 50% | Yes (pause enabled) |
| 5 | NodeHeartBeat (cluster) | Q5 | 2% | No |

**Key commands:**

- `trust dot1p-map trust_map` - Maps 802.1p CoS values to internal QoS groups
- `policy-map type queuing ets-policy` - Allocates bandwidth per traffic class (ETS)
- `policy-map type network-qos pfc-policy` - Enables Priority Flow Control on CoS 3
- `system qos` / `trust-map dot1p trust_map` - Applies the trust map globally

> **NOTE:** Dell historically used Priority 5 for cluster traffic. Microsoft supports both Priority 5 and Priority 7. These configs use Priority 5. See the Dell AX reference guide for details.

### 5. VLT interconnect (VLTi)

Ports `ethernet1/1/13` and `ethernet1/1/14` form the VLT interconnect between TOR1 and TOR2. These ports are configured as routed (no switchport) with jumbo frames and full DCB policy applied.

| Setting | Value | Notes |
|---------|-------|-------|
| MTU | 9216 | Jumbo frames required for RDMA |
| Flowcontrol | Receive off, Transmit off | PFC handles flow control |
| PFC | Enabled | Applied via pfc-policy |
| ETS | Enabled | Applied via ets-policy |

### 6. Uplink port

Port `ethernet1/1/1` is a trunk port carrying all defined VLANs to the upstream network. Flow control is set to receive-on to handle upstream congestion.

Change the allowed VLAN list to match your VLAN design:

```
switchport trunk allowed vlan 700,710-714,720,730-734
```

### 7. Node ports (1/1/2 through 1/1/12)

Each node port connects to an Azure Local host NIC. All ports are configured identically with:

- **Access mode** on the management VLAN (710)
- **MTU 9216** for jumbo frame support
- **DCB enabled** - PFC/ETS policies for RDMA storage traffic
- **BPDU guard** and **edge port** for spanning tree protection

Adjust the number of active node ports to match your cluster size. Unused ports can be shut down for security.

### 8. VLT domain

| Parameter | TOR1 | TOR2 | Change for your environment |
|-----------|------|------|-----------------------------|
| Backup destination | `10.0.0.7` (TOR2 mgmt IP) | `10.0.0.6` (TOR1 mgmt IP) | Peer switch management IP |
| Primary priority | `100` (primary) | `200` (secondary) | Lower number = primary |
| VLT MAC | `00:11:22:33:44:55` | `00:11:22:33:44:55` | Must match on both peers |
| Discovery interfaces | `1/1/13`, `1/1/14` | `1/1/13`, `1/1/14` | Must match VLTi ports |

The `peer-routing` command enables both VLT peers to route traffic, avoiding asymmetric routing issues.

### 9. Spanning tree

RSTP mode is used with a low bridge priority (4096) to ensure the ToR switches become the root bridge for all defined VLANs. This prevents Azure Local nodes from becoming the spanning tree root.

### 10. DNS and NTP

| Parameter | Value | Change for your environment |
|-----------|-------|-----------------------------|
| DNS servers | `10.0.0.10`, `10.0.0.11` | Your DNS server IPs |
| NTP servers | `10.0.0.10`, `10.0.0.11` | Your NTP server IPs |

Time synchronization is critical for log correlation and certificate validation. Use at least two NTP sources.

### 11. Logging and SNMP

| Parameter | Value | Change for your environment |
|-----------|-------|-----------------------------|
| Syslog server | `10.0.0.20` | Your syslog/SIEM collector |
| SNMP contact | `IIC Infrastructure Team` | Your team or NOC name |
| SNMP location | `IIC Azure Local Rack 1` | Physical location of the switch |
| SNMP host | `10.0.0.20` | Your SNMP trap receiver |
| SNMP auth/priv keys | `<SNMP_AUTH_KEY>` / `<SNMP_PRIV_KEY>` | Generate unique keys |

SNMPv3 is used with authentication (SHA) and encryption (AES). Generate unique auth and priv keys before deployment.

SNMP traps are enabled for:
- LLDP neighbor changes
- Entity (hardware) events
- Environmental monitoring (fan, PSU, temperature)
- SNMP authentication failures
- Link state changes (up/down)
- DOM (Digital Optical Monitoring) alerts
- Configuration changes

### 12. User accounts

| Parameter | Value | Change for your environment |
|-----------|-------|-----------------------------|
| `admin` password | `<ADMIN_PASSWORD>` | Set a strong password (15+ chars) |
| `iicadmin` username | `iicadmin` | Rename to your organization's admin username |
| `iicadmin` password | `<ADMIN_PASSWORD>` | Set a strong password (15+ chars) |

Both accounts have the `sysadmin` role. Consider removing the default `admin` account after verifying the secondary account works (`no username admin`).

### 13. SSH access control

An ACL restricts SSH access to the OOB management subnet only. Adjust the source network to match your environment:

```
ip access-list SSH-Allowed
 seq 10 permit ip 10.0.0.0 255.255.255.0 any log
```

## Settings you must change

Before applying these configurations, replace every `<PLACEHOLDER>` and adjust the following values:

| Setting | Placeholder / Example | What to set |
|---------|----------------------|-------------|
| Hostname | `tor1-iic-azlocal` / `tor2-iic-azlocal` | Your switch naming convention |
| Timezone | `EST -5 0` | Your local timezone and UTC offset |
| Management IPs | `10.0.0.6/24` / `10.0.0.7/24` | Your OOB management addresses |
| Default gateway | `10.0.0.1` | Your management gateway |
| VLAN IDs | 700, 710-714, 720, 730-734 | Your VLAN numbering scheme |
| VLAN subnets | `10.0.x.0/24` | Your IP address plan |
| Uplink allowed VLANs | `700,710-714,720,730-734` | Match your VLAN IDs |
| Node port VLAN | `710` | Your management VLAN ID |
| VLT backup IPs | `10.0.0.7` / `10.0.0.6` | Peer switch management IPs |
| VLT MAC | `00:11:22:33:44:55` | Unique MAC for your VLT domain |
| DNS servers | `10.0.0.10`, `10.0.0.11` | Your DNS servers |
| NTP servers | `10.0.0.10`, `10.0.0.11` | Your NTP servers |
| Syslog server | `10.0.0.20` | Your syslog collector |
| SNMP host | `10.0.0.20` | Your SNMP trap receiver |
| SNMP contact | `IIC Infrastructure Team` | Your team name |
| SNMP location | `IIC Azure Local Rack 1` | Physical location |
| SNMP auth key | `<SNMP_AUTH_KEY>` | Generated SHA auth key |
| SNMP priv key | `<SNMP_PRIV_KEY>` | Generated AES priv key |
| Admin password | `<ADMIN_PASSWORD>` | Strong password (15+ characters) |
| Admin username | `iicadmin` | Your admin account name |
| SSH ACL source | `10.0.0.0 255.255.255.0` | Your management subnet |

## Applying the configuration

1. Connect to the switch via console cable or SSH
2. Copy the configuration file contents
3. Enter configuration mode:
   ```
   configure terminal
   ```
4. Paste the configuration (excluding the `configure terminal` line at the top if already in config mode)
5. Review the configuration:
   ```
   show running-configuration
   ```
6. Save:
   ```
   write memory
   ```
7. Repeat for the second switch

> **CAUTION:** Apply TOR1 and TOR2 configurations to the correct switch. The management IPs, VLT backup destinations, and VLT priorities are different between the two.

## Adjusting for your switch model

The port numbers in these configs are based on a generic layout. Adjust for your specific switch model:

| Switch Model | Node Ports | VLTi Ports | Uplink Ports |
|-------------|------------|------------|--------------|
| S4112F-ON | 1/1/1 - 1/1/8 | 1/1/11 - 1/1/12 | 1/1/9 - 1/1/10 |
| S4148F-ON | 1/1/1 - 1/1/16 | 1/1/49 - 1/1/50 | 1/1/30 - 1/1/31 |
| S5212F-ON | 1/1/1 - 1/1/8 | 1/1/11 - 1/1/12 | 1/1/9 - 1/1/10 |
| S5148F-ON | 1/1/1 - 1/1/16 | 1/1/49 - 1/1/50 | 1/1/47 - 1/1/48 |
| S5232F-ON | 1/1/1 - 1/1/16 | 1/1/31 - 1/1/32 | 1/1/33 - 1/1/34 |
| S5248F-ON | 1/1/1 - 1/1/16 | 1/1/49 - 1/1/50 | 1/1/47 - 1/1/48 |

Refer to `guides/azlocal-switch-config-roce-iwarp.md` for model-specific configuration examples from Dell.

## 25 GbE bandwidth adjustment

If your node NICs are 25 GbE (instead of 10 GbE), update the ETS bandwidth allocation per the Dell reference guide:

```
policy-map type queuing ets-policy
    class Q0
        bandwidth percent 49
    class Q3
        bandwidth percent 50
    class Q5
        bandwidth percent 1
```

## Additional security hardening (optional)

The Dell AX reference guide includes additional security settings. Apply these if required by your security policy:

```
! FIPS compliance
crypto fips enable

! Password complexity
password-attributes character-restriction upper 1 lower 1 numeric 1 special-char 1 min-length 15 lockout-period 15 max-retry 3

! Limit SSH auth attempts
ip ssh server max-auth-tries 3

! Login statistics and session limits
login-statistics enable
login concurrent-session limit 3

! Disable system shell access
system-cli disable

! Shut down unused ports
interface range ethernet 1/1/<first_unused>-1/1/<last_unused>
 shutdown
 switchport access vlan 2
```

See `guides/azlocal-switch-config-roce-iwarp.md` > "Switch security and other settings" for the full list.

## References

- [Dell AX System for Azure Local - Switch Configurations (RoCE and iWARP)](guides/azlocal-switch-config-roce-iwarp.md) - in this directory
- [Dell OS10 User Guide - Chapter 5: CLI Basics](guides/os10-ch05-cli-basics.md) - in this directory
- [Dell OS10 User Guide - Chapter 6: Advanced CLI Tasks](guides/os10-ch06-advanced-cli.md) - in this directory
- [Dell OS10 User Guide - Chapter 7: Zero-Touch Deployment](guides/os10-ch07-zero-touch-deployment.md) - in this directory
- [Dell OS10 User Guide - Chapter 8: Provisioning](guides/os10-ch08-provisioning.md) - in this directory
- [Dell OS10 User Guide - Chapter 17: Security](guides/os10-ch17-security.md) - in this directory
- [Dell OS10 User Guide - Chapter 19: ACLs and Route Maps](guides/os10-ch19-acl.md) - in this directory
- [Microsoft - Physical network requirements for Azure Local](https://learn.microsoft.com/en-us/azure/azure-local/concepts/physical-network-requirements)
- [Microsoft - Network switches for Azure Local](https://learn.microsoft.com/en-us/azure/azure-local/concepts/physical-network-requirements?tabs=overview%2C23H2reqs#network-switches-for-azure-local)
- [Microsoft - Host network requirements for Azure Local](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements)
- [AzureLocal Standards - Examples & IIC Policy](https://azurelocal.cloud/standards/fictional-company-policy)
