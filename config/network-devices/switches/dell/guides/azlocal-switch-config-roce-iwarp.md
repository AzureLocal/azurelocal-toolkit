# Dell AX System for Azure Local: Switch Configurations - RoCE and iWARP

This reference guide lists sample networking switch configurations for Mellanox, Intel E810, and Broadcom based deployments for Dell AX System for Azure Local solutions.

**Dell Technologies Solutions**
Part Number: H19195.5 | April 2026

---

> **NOTE:** A NOTE indicates important information that helps you make better use of your product.

> **CAUTION:** A CAUTION indicates either potential damage to hardware or loss of data and tells you how to avoid the problem.

> **WARNING:** A WARNING indicates a potential for property damage, personal injury, or death.

Copyright &copy; Dell Inc. All Rights Reserved. Dell Technologies, Dell, and other trademarks are trademarks of Dell Inc. or its subsidiaries. Other trademarks may be trademarks of their respective owners.

---

## About copying commands from this guide

> **CAUTION:** Many PDF editors and viewers add a line break to the end of each line of text in a PDF. As a result, when you copy commands that wrap across multiple lines in a PDF, the copied command is in the wrong format. It contains erroneous line breaks that might cause the script to fail.

To address this known limitation, do one of the following:

- Paste the copied commands into a text editor and remove the line breaks.
- Use the HTML version of this document when you are copying commands.

---

## Revision history

| Date | Revision | Description of changes |
|------|----------|----------------------|
| April 2026 | 5 | Added note regarding priority levels for cluster traffic; Added Broadcom BCM57504 to the RoCE row of Table 2; Added note about using ToR switches for Azure Local instance deployments; Added break lines around "policy-map type queuing ets-policy" sections; Updated ets-policy sections in ToR1 and ToR2 for S5212F-ON, S52148F-ON, S5232F-ON, and S5248F-ON to add bandwidth percent for each class for 25 GbE switches |
| May 2025 | 4 | Updates due to product rebranding |
| March 2025 | 3 | Updates due to feedback |
| January 2025 | 2 | Updates related to release |
| March 2023 | 1 | Updates not documented |
| March 2022 | 0 | Initial publication |

---

## Switch configuration recommendations for Mellanox, Intel E810, and Broadcom

This guide consists of switch configuration recommendations for all Mellanox, Intel E810, and Broadcom based deployments.

Dell Technologies recommends that you use DCB (PFC/ETS) for all Mellanox and Intel E810 based deployments on switch ports that are used for RDMA traffic.

### Topology for Mellanox, Intel E810, and Broadcom based deployments

| Topology | Converged | Non-converged |
|----------|-----------|---------------|
| **Flow Control** | DCB (PFC/ETS) | DCB (PFC/ETS) |
| **UDP RDMA (RoCE)** | Mellanox CX5, Mellanox CX6, Broadcom BCM57504, Intel E810 (RoCE) | Mellanox CX5, Mellanox CX6, Broadcom BCM57504, Intel E810 (RoCE) |
| **iWARP** | Intel E810 (iWARP) | Intel E810 (iWARP) |

> **NOTE:**
>
> - Dell Technologies has updated its guidance for all Mellanox and Intel E810-based deployments. If you have existing deployments that followed our earlier guidance, when using Network ATC with Azure Stack HCI OS 23H2 and later, we recommend that you configure PFC/ETS for all RDMA ports, including the ones using Qlogic 41262 cards with iWarp traffic.
> - For brownfield deployments where DCB is already configured on the switch, changing the cluster-traffic priority to 7 is optional.
> - Historically, Dell Technologies used Priority 5 for cluster traffic. Microsoft supports both Priority 5 and Priority 7. This guide references Priority 5, but Priority 7 is also supported. You can implement either priority.

### ToR switches

Top-of-rack (ToR) switches that are used in Azure Local instance deployments and that forward RDMA storage-network traffic must be listed in the Azure Local ToR switch list on the Microsoft page: Physical network requirements for Azure Local > Network switches for Azure Local.

> **NOTE:** For deployments with ToR switches that are not listed, you must use the switchless storage-network deployment option.

---

## Dell Networking S4112F-ON switch

Sample configurations for Dell Networking S4112F-ON switch in Mellanox and Intel E810-based deployments.

### Base configuration

**TOR1:**

```
!
hostname OS10-S4112F-TOR1
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.1/30
 ipv6 address autoconfig
!
interface range ethernet1/1/11-1/1/12
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/9-1/1/10
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.2
 discovery-interface ethernet1/1/11
 discovery-interface ethernet1/1/12
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.124/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 301
 description STORAGE-1
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

**TOR2:**

```
!
hostname OS10-S4112F-TOR2
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.2/30
 ipv6 address autoconfig
!
interface range ethernet1/1/11-1/1/12
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/9-1/1/10
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.1
 discovery-interface ethernet1/1/11
 discovery-interface ethernet1/1/12
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.125/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 302
 description STORAGE-2
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

### Converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/8
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/8
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

### Non-converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/4
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/5-1/1/8
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/4
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/5-1/1/8
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

---

## Dell Networking S4148F-ON switch

Sample configurations for Dell Networking S4148F-ON switch in Mellanox and Intel E810-based deployments.

### Base configuration

**TOR1:**

```
!
hostname OS10-S4148F-TOR1
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.1/30
 ipv6 address autoconfig
!
interface range ethernet1/1/30-1/1/31
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/30-1/1/31
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.2
 discovery-interface ethernet1/1/49
 discovery-interface ethernet1/1/50
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.124/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 301
 description STORAGE-1
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

**TOR2:**

```
!
hostname OS10-S4148F-TOR2
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.2/30
 ipv6 address autoconfig
!
interface range ethernet1/1/30-1/1/31
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/30-1/1/31
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.1
 discovery-interface ethernet1/1/49
 discovery-interface ethernet1/1/50
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.125/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 302
 description STORAGE-2
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

### Converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

### Non-converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

---

## Dell Networking S5212F-ON switch

Sample configurations for Dell Networking S5212F-ON switch in Mellanox and Intel E810-based deployments.

### Base configuration

**TOR1:**

```
!
hostname OS10-S5212F-TOR1
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.1/30
 ipv6 address autoconfig
!
interface range ethernet1/1/11-1/1/12
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/9-1/1/10
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.2
 discovery-interface ethernet1/1/11
 discovery-interface ethernet1/1/12
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.124/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 301
 description STORAGE-1
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

**TOR2:**

```
!
hostname OS10-S5212F-TOR2
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.2/30
 ipv6 address autoconfig
!
interface range ethernet1/1/11-1/1/12
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/9-1/1/10
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.1
 discovery-interface ethernet1/1/11
 discovery-interface ethernet1/1/12
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.125/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 302
 description STORAGE-2
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

### Converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/8
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/8
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

### Non-converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/4
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/5-1/1/8
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/4
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/5-1/1/8
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

---

## Dell Networking S5148F-ON switch

Sample configurations for Dell Networking S5148F-ON switch in Mellanox and Intel E810-based deployments.

### Base configuration

**TOR1:**

```
hostname OS10-S5148F-TOR1
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface vlan 200
 description DataCenterUplink
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.1/30
 ipv6 address autoconfig
!
interface range ethernet1/1/49-1/1/50
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/47-1/1/48
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.2
 discovery-interface ethernet1/1/49
 discovery-interface ethernet1/1/50
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.124/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 301
 description STORAGE-1
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

**TOR2:**

```
hostname OS10-S5148F-TOR2
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface vlan 200
 description DataCenterUplink
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.2/30
 ipv6 address autoconfig
!
interface range ethernet1/1/49-1/1/50
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/47-1/1/48
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.1
 discovery-interface ethernet1/1/49
 discovery-interface ethernet1/1/50
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.125/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 302
 description STORAGE-2
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

### Converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

### Non-converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

---

## Dell Networking S5232F-ON switch

Sample configurations for Dell Networking S5232F-ON switch in Mellanox and Intel E810-based deployments.

### Base configuration

**TOR1:**

```
hostname OS10-S5232-TOR1
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.1/30
 ipv6 address autoconfig
!
interface range ethernet1/1/31-1/1/32
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/33-1/1/34
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.2
 discovery-interface ethernet1/1/31
 discovery-interface ethernet1/1/32
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.124/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 301
 description STORAGE-1
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

**TOR2:**

```
hostname OS10-S5232-TOR2
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.2/30
 ipv6 address autoconfig
!
interface range ethernet1/1/31-1/1/32
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/33-1/1/34
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.1
 discovery-interface ethernet1/1/31
 discovery-interface ethernet1/1/32
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.125/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 302
 description STORAGE-2
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

### Converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

### Non-converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

---

## Dell Networking S5248F-ON switch

Sample configurations for Dell Networking S5248F-ON switch in Mellanox and Intel E810-based deployments.

### Base configuration

**TOR1:**

```
hostname OS10-S5248F-TOR1
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface vlan 200
 description DataCenterUplink
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.1/30
 ipv6 address autoconfig
!
interface range ethernet1/1/49-1/1/50
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/47-1/1/48
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.2
 discovery-interface ethernet1/1/49
 discovery-interface ethernet1/1/50
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.124/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 301
 description STORAGE-1
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

**TOR2:**

```
hostname OS10-S5248F-TOR2
!
dcbx enable
!
class-map type queuing Q0
 match queue 0
!
class-map type queuing Q3
 match queue 3
!
class-map type network-qos S2DManagement
 match qos-group 0
!
class-map type network-qos SmbStorage
 match qos-group 3
!
class-map type queuing Q5
 match queue 5
!
class-map type network-qos NodeHeartBeat
 match qos-group 5
!
trust dot1p-map trust_map
 qos-group 0 dot1p 0-2,4,6-7
 qos-group 3 dot1p 3
 qos-group 5 dot1p 5
!
qos-map traffic-class queue-map
 queue 0 qos-group 0-2,4,6-7
 queue 3 qos-group 3
 queue 5 qos-group 5
!
policy-map type application policy-iscsi
!
! For 10 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 48
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 2
!
! For 25 GbE bandwidth
policy-map type queuing ets-policy
 !
 class Q0
  bandwidth percent 49
 !
 class Q3
  bandwidth percent 50
 !
 class Q5
  bandwidth percent 1
!
policy-map type network-qos pfc-policy
 !
 class SmbStorage
  pause
  pfc-cos 3
!
system qos
 trust-map dot1p trust_map
!
interface vlan 200
 description DataCenterUplink
!
interface mgmt1/1/1
 no shutdown
 no ip address dhcp
 ip address 192.168.255.2/30
 ipv6 address autoconfig
!
interface range ethernet1/1/49-1/1/50
 description VLTiLink
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 no shutdown
 no switchport
!
interface port-channel10
 description DataCenterUplink
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 vlt-port-channel 10
!
interface range ethernet1/1/47-1/1/48
 description CUSTOMER.UPLINK
 no shutdown
 channel-group 10 mode active
 no switchport
 flowcontrol receive on
 flowcontrol transmit off
!
vlt-domain 1
 backup destination 192.168.255.1
 discovery-interface ethernet1/1/49
 discovery-interface ethernet1/1/50
 vlt-mac 00:00:00:00:00:02
!
interface Vlan 200
 description MANAGEMENT
 no shutdown
 ip address 172.18.100.125/25
!
 vrrp-group 200
  virtual-address 172.18.100.126
!
interface Vlan 302
 description STORAGE-2
 no ip address
 mtu 9216
 no shutdown
!
lldp enable
!
ip ssh server enable
!
end
!
clock set <HH:MM:SS> <YYYY-MM-DD>
!
clear logging log-file
!
write memory
```

### Converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/16
 description NodeDCB
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200,302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

### Non-converged topology

**TOR1:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 301
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

**TOR2:**

```
interface range ethernet1/1/1-1/1/8
 description NodeManagement
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 200
 mtu 9216
 flowcontrol receive on
 flowcontrol transmit off
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
interface range ethernet1/1/9-1/1/16
 description Storage
 no shutdown
 switchport mode trunk
 switchport access vlan 1
 switchport trunk allowed vlan 302
 mtu 9216
 flowcontrol receive off
 flowcontrol transmit off
 priority-flow-control mode on
 service-policy input type network-qos pfc-policy
 service-policy output type queuing ets-policy
 ets mode on
 qos-map traffic-class queue-map
 spanning-tree bpduguard enable
 spanning-tree port type edge
!
```

---

## Switch security and other settings

The following switch settings are generic settings that a customer or Dell Services personnel may require during a switch configuration or deployment. Many of the commands are related to switch environment security. Use these commands and settings only if required for a given environment.

### Backup switch license

```
!!!
!!! REQUIRED - Backup license
!!!
! license is located in base OS /mnt/license
! copy license to management VM and provide to customer
! usb key mounts to base OS /mnt/usb
! alternatively one can use SCP or other protocols if the network is available
! below command assumes USB key is inserted
system "sudo -i"
cp /mnt/license/<SVCTAG>.lic /mnt/usb
exit
```

### Disable support assist

```
!!!
!!! REQUIRED - EULA reject
!!!
eula-consent support-assist reject
! confirm EULA reject
```

### FIPS compliance

```
crypto fips enable
! confirm fips enablement
```

### Set Daylight Saving time

```
! by default this has been set to Pacific Time Zone US Daylight Saving time.
clock summer-time PDT 2 Sun Mar 02:00 1 Sun Nov 02:00 60
```

### Customer banner MOTD

```
banner motd #
Insert your own customer banner here.
#
```

### Password update

```
! enable password <NEW.PASSWORD>
! enable password <NEW.PASSWORD>
! username azsadmin-lmuvl password <NEW.PASSWORD> role network-admin
```

### Password attributes and max-auth-tries

```
!
password-attributes character-restriction upper 1 lower 1 numeric 1 special-char 1 min-length 15 lockout-period 15 max-retry 3
!
ip ssh server max-auth-tries 3
```

### Login statistics, session timeout, and concurrent session limits

```
!
login-statistics enable
!
exec-timeout 600
!
login concurrent-session limit 3
```

### SSH server settings

```
ip ssh server cipher aes256-ctr aes192-ctr aes128-ctr
ip ssh server mac hmac-sha1 hmac-sha2-256
ip ssh server enable
```

### Configure RADIUS servers

```
! radius-server host <WDS Server IP> key 0 <secret> authentication accounting
! role name Prefix-BMCAdmin
!  description Radius authenticated accounts
!  rule 1 permit read-write
! aaa group server radius Prefix-BMCAdmin
! server <IP>
! source-interface mgmt0
! aaa authentication login default group <Group>
! aaa accounting default group <Group>
! aaa authentication login mschapv2 enable
```

### TACACS

```
! feature tacacs+
! tacacs-server key <secret>
! ip tacacs source-interface mgmt0
! tacacs-server host <IP>
! aaa group server tacacs+ tacacs
!    server <IP>
```

### Configure syslog

```
! logging server 10.128.0.116 7 facility syslog use-vrf management
! no logging console
```

### Configure syslog source interface

```
logging source-interface mgmt 1/1/1
```

### Configure logging audit enable

```
logging audit enable
```

### Configure logging to not display to non-authorized users

```
logging console disable
```

### Configure unused ports to non-default VLAN

```
!
interface vlan 2
 description "Unused port vlan"
 shutdown
!
interface range ethernet 1/1/4-1/1/28,1/1/33-1/1/34
 shutdown
 switchport access vlan 2
!
```

### Remove access to system command

```
system-cli disable
```

### Remove default user admin

```
no username admin
```

### Reset password of Linux user linuxadmin

```
system-user linuxadmin password <password>
```

---

## References

### Dell Technologies documentation

- Dell AX Solutions for Microsoft documentation
- Dell AX System for Azure Local specification sheet
- iDRAC documentation
- Azure Local Support Matrix
- For more information about manually configuring iDRAC, see PowerEdge: Support Articles for the iDRAC and the CMC.
