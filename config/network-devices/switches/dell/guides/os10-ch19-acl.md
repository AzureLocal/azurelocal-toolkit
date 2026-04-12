# Access Control Lists

OS10 uses two types of access policies—hardware-based ACLs and software-based route-maps. Use an ACL to filter traffic and drop or forward matching packets. To redistribute routes that match the configured criteria, use a route-map.

## ACLs

ACLs are a filter containing criteria to match; for example, examine internet protocol (IP), transmission control protocol (TCP), or user datagram protocol (UDP) packets, and an action to take such as forwarding or dropping packets at the NPU. ACLs permit or deny traffic based on MAC and/or IP addresses. The number of ACL entries is hardware-dependent.

ACLs have only two actions—forward or drop. Route-maps not only permit or block redistributed routes but also modify information that is associated with the route when it is redistributed into another protocol. When a packet matches a filter, the device drops or forwards the packet based on the filter's specified action. If the packet does not match any of the filters in the ACL, the packet drops, an implicit deny. ACL rules do not consume hardware resources until you apply the ACL to an interface.

ACLs process in sequence. If a packet does not match the criterion in the first filter, the second filter applies. If you configure multiple hardware-based ACLs, filter rules apply on the packet content based on the priority numeric processing unit (NPU) rule.

ACLs for VLT scenario—When ACLs are applied to a VLAN (either ingress or egress), they are applied to Po1000 (ICL) and all other member ports of the VLAN.

## Route maps

Route-maps are software-based protocol filtering redistributing routes from one protocol to another and used in decision criterion in route advertisements. A route-map defines which of the routes from the specified routing protocol redistributes into the target routing process, see Route-maps.

Route-maps which have more than one match criterion, two or more matches within the same route-map sequence, have different match commands. Matching a packet against this criterion is an AND operation. If no match is found in a route-map sequence, the process moves to the next route-map sequence until a match is found, or until there are no more sequences. When a match is found, the packet forwards and no additional route-map sequences process. If you include a continue clause in the route-map sequence, the next route-map sequence also processes after a match is found.

## IP ACLs

An ACL filters packet based on the:

- IP protocol number
- Source and destination IP address
- Source and destination TCP port number
- Source and destination UDP port number

For ACL, TCP, and UDP filters, match criteria on specific TCP or UDP ports. For ACL TCP filters, you can also match criteria on established TCP sessions.

When creating an ACL, the sequence of the filters is important. You can assign sequence numbers to the filters as you enter them or OS10 can assign numbers in the order you create the filters. The sequence numbers are displayed in the `show running-configuration` and `show ip access-lists [in | out]` command output.

Hot-lock ACLs allow you to append or delete new rules into an existing ACL without disrupting traffic flow. Existing entries in the content-addressable memory (CAM) shuffle to accommodate the new entries. Hot-lock ACLs are enabled by default and support ACLs on all platforms.

> **NOTE:** Hot-lock ACLs support ingress ACLs only.

> **NOTE:** When applied on VLANs, the implicit deny rule in IP ACLs does not permit the following packets at egress:
>
> - IPv4 Address Resolution Protocol (ARP)
> - IPv6 Neighbor Discovery (ND)
> - IPv6 Neighbor Solicitation (NS)
>
> To permit these packets, you must configure an explicit permit statement for the specific hosts or subnetworks with the deny rule having a lower priority to drop the rest of the packets. The `deny ip any any` and `deny ipv6 any any` rules are implicit. You do not have to configure them explicitly.

> **NOTE:** When configuring access lists with permit or deny rules for TCP traffic, if multiple TCP flags (for example, ACK, FIN, PSH, RST, SYN, URG) are specified within a single sequence number, a packet matches the rule only if all the specified flags are present in the received packet.

### Restrictions and limitations

Consider a scenario where you create a single IPv4 ACL using the `seq 10 permit ip any any count` command and apply it to 150 VLANs using the range command.

When you apply sequential rules in the hardware, negligible traffic loss occurs when the implicit deny rule is run during the time interval between these rules.

For example, when you apply the following sequential rules, negligible traffic loss occurs in the IPv4 traffic streams:

1. Number of VLANs x number of tiles x one Implicit deny rule. For example, 150 x 4 x 1 = 600 rules.
2. Number of VLANs x number of tiles x number of rules in the list. For example, 150 x 4 x 1 = 600 rules.

You can see this behavior in multi-tile platforms such as Z9100-ON, Z9264-ON, Z9332-ON, and so on. Because you need to install more number of implicit deny rules before configuring the ACL rules. In all other Dell SmartFabric OS10 platforms, you can see this behavior if you increase the number of VLANs in the same TC.

## MAC ACLs

MAC ACLs filter traffic on the header of a packet. This traffic filtering is based on:

| Field | Description |
|-------|-------------|
| Source MAC packet address | MAC address range—address mask in 3x4 dotted hexadecimal notation, and any to denote that the rule matches all source addresses. |
| Destination MAC packet address | MAC address range—address-mask in 3x4 dotted hexadecimal notation, and any to denote that the rule matches all destination addresses. |
| Packet protocol | Set by its EtherType field contents and assigned protocol number for all protocols. |
| VLAN ID | Set in the packet header |
| Class of service | Present in the packet header |

IPv4/IPv6 and MAC ACLs apply separately for inbound and outbound packets. You can assign an interface to multiple ACLs, with a limit of one ACL per packet direction per ACL type.

## Control-plane ACLs

OS10 offers control-plane ACLs to selectively restrict packets that are destined to the CPU port, thereby providing increased security. Control-plane ACLs offer:

- An option to protect the CPU from denial of service (DoS) attacks.
- Fine-grained control to allow or block traffic going to the CPU.

Control-plane ACLs apply on the front-panel and management ports. Control-plane ACLs are one of the following types:

- IP ACL
- IPv6 ACL
- MAC ACL

> **NOTE:** MAC ACL is applied only on packets that enter through the front-panel ports.

There is no implicit deny rule. If none of the configured conditions match, the default behavior is to permit. If you need to deny traffic that does not match any of the configured conditions, explicitly configure a deny statement.

The control-plane ACL is mutually exclusive with the VTY ACL, the management ACL. VTY ACL provides secure access for session connection protocols, such as SSH or TELNET; however, control-plane ACLs permit or deny any TCP or UDP, including SSH and TELNET sessions, from specific hosts and networks, and also filters both IPv4 and IPv6 traffic.

### Configure control-plane ACL

To configure control-plane ACLs, use the existing ACL template and create the appropriate rules to permit or deny traffic as needed, similar to creating an access list for VTY ACLs. However, when you apply this control-plane ACL, you must apply it in CONTROL-PLANE mode instead of VTY mode. For example:

```
OS10# configure terminal
OS10(config)# control-plane
OS10(config-control-plane)# ip access-group acl_name in
```

Where `acl_name` is the name of the control-plane ACL, a maximum of 140 characters.

> **NOTE:** Apply control-plane ACLs on ingress traffic only.

To delete the control-plane ACL configuration, use the `no ip access-group` command. Initially, you may encounter an issue where the `ip access-group` command is run instead. This issue is rectified upon the second execution of the `no ip access-group` command, effectively removing the control-plane ACL configuration.

### Configuration notes

The control-plane MAC ACL is not supported for management port on all platforms.

### Control-plane ACL qualifiers

This section lists the supported control-plane ACL rule qualifiers.

> **NOTE:** OS10 supports only the qualifiers listed below. Ensure that you use only these qualifiers in ACL rules.

- IPv4 qualifiers:
  - DST_IP—Destination IP address
  - SRC_IP—Source IP address
  - IP_TYPE—IP type
  - IP_PROTOCOL—Protocols such as TCP, UDP, and so on
  - L4_DST_PORT—Destination port number
- IPv6 qualifiers:
  - DST_IPv6—Destination address
  - SRC_IPv6—Source address
  - IP_TYPE—IP Type; for example, IPv4 or IPv6
  - IP_PROTOCOL—TCP, UDP, and so on
  - L4_DST_PORT—Destination port
- MAC qualifiers:
  - OUT_PORT—Egress CPU port
  - SRC_MAC—Source MAC address
  - DST_MAC—Destination MAC address
  - ETHER_TYPE—Ethertype
  - OUTER_VLAN_ID—VLAN ID
  - IP_TYPE—IP type
  - OUTER_VLAN_PRI—DOT1P value

## IP fragment handling

OS10 supports a configurable option to explicitly deny IP-fragmented packets, particularly for the second and subsequent packets. This option extends the existing ACL command syntax with the fragments keyword for all L3 rules:

- Second and subsequent fragments are allowed because you cannot apply a L3 rule to these fragments. If the packet is denied eventually, the first fragment must be denied and the packet as a whole cannot be reassembled.
- The system applies implicit permit for the second and subsequent fragment before the implicit deny.
- If you configure an explicit deny, the second and subsequent fragments do not hit the implicit permit rule for fragments.

### IP fragments ACL

When a packet exceeds the maximum packet size, the packet is fragmented into a number of smaller packets that contain portions of the contents of the original packet. This packet flow begins with an initial packet that contains all of the L3 and Layer 4 (L4) header information contained in the original packet, and is followed by a number of packets that contain only the L3 header information.

This packet flow contains all of the information from the original packet distributed through packets that are small enough to avoid the maximum packet size limit. This provides a particular problem for ACL processing.

If the ACL filters based on L4 information, the non-initial packets within the fragmented packet flow will not match the L4 information, even if the original packet would have matched the filter. Because of this filtering, packets are not processed by the ACL.

The examples show denying second and subsequent fragments, and permitting all packets on an interface. These ACLs deny all second and subsequent fragments with destination IP 10.1.1.1, but permit the first fragment and non-fragmented packets with destination IP 10.1.1.1. The second example shows ACLs which permits all packets — both fragmented and non-fragmented — with destination IP 10.1.1.1.

**Deny second and subsequent fragments**

```
OS10(config)# ip access-list ABC
OS10(conf-ipv4-acl)# deny ip any 10.1.1.1/32 fragments
OS10(conf-ipv4-acl)# permit ip any 10.1.1.1/32
```

**Permit all packets on interface**

```
OS10(config)# ip access-list ABC
OS10(conf-ipv4-acl)# permit ip any 10.1.1.1/32
OS10(conf-ipv4-acl)# deny ip any 10.1.1.1/32 fragments
```

### L3 ACL rules

Use ACL commands for L3 packet filtering. TCP packets from host 10.1.1.1 with the TCP destination port equal to 24 are permitted, and all others are denied.

TCP packets that are first fragments or non-fragmented from host 10.1.1.1 with the TCP destination port equal to 24 are permitted, and all TCP non-first fragments from host 10.1.1.1 are permitted. All other IP packets that are non-first fragments are denied.

**Permit ACL with L3 information only**

If a packet's L3 information matches the information in the ACL, the packet's fragment offset (FO) is checked:

- If a packet's FO > 0, the packet is permitted
- If a packet's FO = 0, the next ACL entry processes

**Deny ACL with L3 information only**

If a packet's L3 information does not match the L3 information in the ACL, the packet's FO is checked:

- If a packet's FO > 0, the packet is denied
- If a packet's FO = 0, the next ACL line processes

**Permit all packets from host**

```
OS10(config)# ip access-list ABC
OS10(conf-ipv4-acl)# permit tcp host 10.1.1.1 any eq 24
OS10(conf-ipv4-acl)# deny ip any any fragment
```

**Permit only first fragments and non-fragmented packets from host**

```
OS10(config)# ip access-list ABC
OS10(conf-ipv4-acl)# permit tcp host 10.1.1.1 any eq 24
OS10(conf-ipv4-acl)# permit tcp host 10.1.1.1 any fragment
OS10(conf-ipv4-acl)# deny ip any any fragment
```

To log all packets denied and to override the implicit deny rule and the implicit permit rule for TCP/UDP fragments, use a similar configuration. When an ACL filters packets, it looks at the FO to determine whether it is a fragment:

- FO = 0 means it is either the first fragment or the packet is a non-fragment
- FO > 0 means it is the fragments of the original packet

## Assign sequence number to the filter

IP ACLs filter on source and destination IP addresses, IP host addresses, TCP addresses, TCP host addresses, UDP addresses, and UDP host addresses. Traffic passes through the filter by filter sequence. Configure the IP ACL by first entering IP ACCESS-LIST mode and then assigning a sequence number to the filter.

**User-provided sequence number**

- Enter IP ACCESS LIST mode by creating an IP ACL in CONFIGURATION mode.

  ```
  ip access-list access-list-name
  ```

- Configure a drop or forward filter in IPV4-ACL mode.

  ```
  seq sequence-number {deny | permit | remark} {ip-protocol-number | icmp | ip |
  protocol | tcp | udp} {source prefix | source mask | any | host} {destination mask
  | any | host ip-address} [count [byte]] [fragments]
  ```

**Autogenerated sequence number**

If you are creating an ACL with only one or two filters, you can let the system assign a sequence number based on the order you configure the filters. The system assigns sequence numbers to filters using multiples of ten values.

- Configure a deny or permit filter to examine IP packets in IPV4-ACL mode.

  ```
  {deny | permit} {source mask | any | host ip-address} [count [byte]] [fragments]
  ```

- Configure a deny or permit filter to examine TCP packets in IPV4-ACL mode.

  ```
  {deny | permit} tcp {source mask] | any | host ip-address}} [count [byte]] [fragments]
  ```

- Configure a deny or permit filter to examine UDP packets in IPV4-ACL mode.

  ```
  {deny | permit} udp {source mask | any | host ip-address}} [count [byte]] [fragments]
  ```

**Assign sequence number to filter**

```
OS10(config)# ip access-list acl1
OS10(conf-ipv4-acl)# seq 5 deny tcp any any capture session 1 count
```

**View ACLs and packets processed through ACL**

```
OS10# show ip access-lists in
Ingress IP access-list acl1
 Active on interfaces :
  ethernet1/1/5
 seq 5 permit ip any any count (10000 packets)
```

## Delete ACL rule

Before release 10.4.2, deleting ACL rules required a sequence number.

After release 10.4.2 or later, you can also delete ACL rules using the no form of the CLI command without using a sequence number.

While deleting ACL rules, the following conditions apply:

- Enter the exact no form of the CLI command. Each ACL rule is an independent entity. For example, the rule `deny ip any any` is different from `deny ip any any count`. For example, if you configured the following rules:

  ```
  deny ip 192.0.2.1/24 192.0.2.2/24
  deny ip any any
  ```

  Using the `no deny ip any any` command deletes only the `deny ip any any` rule. To delete the `deny ip 192.0.2.1/24 192.0.2.2/24` rule, you must explicitly use the `no deny ip 192.0.2.1/24 192.0.2.2/24` command.

  > **NOTE:** The wildcard option is not supported.

- You can no longer configure the same ACL rule multiple times using different sequence numbers. This option prevents duplicate rules from being entered in the system and taking up memory space.
- When you upgrade from a previous release to release 10.4.2 or later, the upgrade procedure removes all duplicate ACL rules and only one instance of an ACL rule remains in the system.

## L2 and L3 ACLs

Configure both L2 and L3 ACLs on an interface in L2 mode. Rules apply if you use both L2 and L3 ACLs on an interface.

- L3 ACL filters packets and then the L2 ACL filters packets
- Egress L3 ACL filters packets

Rules apply in order:

- Ingress L3 ACL
- Ingress L2 ACL
- Egress L3 ACL
- Egress L2 ACL

> **NOTE:** In ingress ACLs, L2 has a higher priority than L3 and in egress ACLs, L3 has a higher priority than L2.

**Table 138. L2 and L3 targeted traffic**

| L2 ACL / L3 ACL | Targeted traffic |
|-----------------|------------------|
| Deny / Deny | L3 ACL denies |
| Deny / Permit | L3 ACL permits |
| Permit / Deny | L3 ACL denies |
| Permit / Permit | L3 ACL permits |

## Assign and apply ACL filters

To filter an Ethernet interface, a LAG interface, or a VLAN, assign an IP ACL filter to the corresponding interface. Based on the configured ACL filter, the IP ACL applies to traffic that is directly connected towards source or destination. The traffic either forwards or drops depending on the criteria and actions you configure in the ACL filter.

To change the ACL filter functionality, apply the same ACL filters to different interfaces. For example, take ACL "ABCD" and apply it using the `in` keyword and it becomes an ingress ACL. If you apply the same ACL filter using the `out` keyword, it becomes an egress ACL.

> **NOTE:** This note is applicable only for the S5200F-ON series platform switches. Applying an egress ACL to a VLAN interface with access ports as members (untagged) has no effect. The system does not apply egress ACL rules on untagged access ports.

You can apply an IP ACL filter to a physical interface, LAG interface, VLAN interface, or on the access ports which are members of the virtual-network interfaces. The number of ACL filters allowed is hardware-dependent.

1. Enter the interface information in CONFIGURATION mode.

   ```
   interface ethernet node/slot/port
   ```

2. Configure an IP address for the interface, placing it in L3 mode in INTERFACE mode.

   ```
   ip address ip-address
   ```

3. Apply an IP ACL filter to traffic entering or exiting an interface in INTERFACE mode.

   ```
   ip access-group access-list-name {in | out}
   ```

**Configure IP ACL**

```
OS10(config)# interface ethernet 1/1/28
OS10(conf-if-eth1/1/28)# ip address 10.1.2.0/24
OS10(conf-if-eth1/1/28)# ip access-group abcd in
```

**View ACL filters applied to interface**

```
OS10# show ip access-lists in
Ingress IP access-list acl1
Active on interfaces :
 ethernet1/1/28
seq 10 permit ip host 10.1.1.1 host 100.1.1.1 count (0 packets)
seq 20 deny ip host 20.1.1.1 host 200.1.1.1 count (0 packets)
seq 30 permit ip 10.1.2.0/24 100.1.2.0/24 count (0 packets)
seq 40 deny ip 20.1.2.0/24 200.1.2.0/24 count (0 packets)
seq 50 permit ip 10.0.3.0 255.0.255.0 any count (0 packets)
seq 60 deny ip 20.0.3.0 255.0.255.0 any count (0 packets)
seq 70 permit tcp any eq 1000 100.1.4.0/24 eq 1001 count (0 packets)
seq 80 deny tcp any eq 2100 200.1.4.0/24 eq 2200 count (0 packets)
seq 90 permit udp 10.1.5.0/28 eq 10000 any eq 10100 count (0 packets)
seq 100 deny tcp host 20.1.5.1 any rst psh count (0 packets)
seq 110 permit tcp any any fin syn rst psh ack urg count (0 packets)
seq 120 deny icmp 20.1.6.0/24 any fragment count (0 packets)
seq 130 permit 150 any any dscp 63 count (0 packets)
```

To view the number of packets matching the ACL, use the count option when creating ACL entries.

- Create an ACL that uses rules with the count option, see Assign sequence number to filter.
- Apply the ACL as an inbound or outbound ACL on an interface in CONFIGURATION mode, and view the number of packets matching the ACL.

  ```
  show ip access-list {in | out}
  ```

## Ingress ACL filters

Ingress ACL filters affect the traffic that is directly connected towards source. In the following example, an ingress IP ACL on VLAN 2 cannot block traffic in the direction from host1 to server 1 because source is directly connected on VLAN 2. To block traffic from host 1, you must apply ingress ACL on L3 port or egress ACL on VLAN 2.

```
L3 port
VLAN 2
Host 1
Server 1
```

To create an ingress ACL filter, use the `ip access-group` command in EXEC mode. To configure ingress, use the `in` keyword. Apply the rules to the ACL with the `ip access-list acl-name` command. To view the access-list, use the `show access-lists` command.

1. Apply an ingress access-list on the interface in INTERFACE mode.

   ```
   ip access-group access-group-name in
   ```

2. Return to CONFIGURATION mode.

   ```
   exit
   ```

3. Create the access-list in CONFIGURATION mode.

   ```
   ip access-list access-list-name
   ```

4. Create the rules for the access-list in ACCESS-LIST mode.

   ```
   permit ip host ip-address host ip-address count
   ```

**Apply ACL rules to access-group and view access-list**

```
OS10(config)# interface ethernet 1/1/28
OS10(conf-if-eth1/1/28)# ip access-group abcd in
OS10(conf-if-eth1/1/28)# exit
OS10(config)# ip access-list acl1
OS10(conf-ipv4-acl)# permit ip host 10.1.1.1 host 100.1.1.1 count
```

### Configuration notes

**Dell PowerSwitch S4200-ON Series:**

- The following applications require ACL tables: VLT, iSCSI, L2 ACL, L3 v4 ACL, L3 v6 ACL, PBR v4, PBR v6, QoS L2, QoS L3, and FCoE. In ingress ACL, you can create ACL tables for two or three applications at a time.
- When a packet matches more than one ACL table, the system increments the counter for the table with the highest priority.
- In IPv6 user ACL, PBR v6 ACL, and IPv6 QoS tables—destination-port, l4-source-port, flow label, and TCP flags are not supported.
- IP fragment supports only two options: non-fragment and head/non-head.

**Dell PowerSwitch S5200-ON Series:**

When you configure a QoS service-policy on an S5200-ON switch that is in a VLT setup with MAC and IP ACLs configured, an error appears. This issue occurs because of ACL group width limitation in the S5200-ON series switches. VLT, IP, MAC, and QoS ACLs require double-width ACL table slice. The S5200-ON series switches support only three applications that require a double-wide ACL table slice at a time. An error appears because the QoS application configuration requires a fourth ACL table slice.

**All Dell PowerSwitches:**

IP ACL applied to SVI interface effects L2 switch traffic also.

### Scaling of ingress user ACLs (Z9332F-ON)

This section is specific to the Z9332F-ON platform.

The scaling of Ingress user ACLs depends on the order in which they are configured. The Network Processing Unit (NPU) has nine pools for Ingress ACLs. Out of these nine pools, six pools contain 256 entries each, and three pools contain 512 entries each. User ACLs use six reserved pools: three with 256 entries and three with 512 entries.

The number and size of qualifiers determine the number of pools and the scale of the ACL. For example, an ACL with only Layer 2 (L2) qualifiers needs one pool in single wide mode, while an ACL with both IPv6 and L2 qualifiers needs three pools in triple wide mode. OS10 assigns smaller pools for triple wide mode user ACLs, such as those with IPv6 + L2 qualifiers.

#### Examples

The following examples illustrate how the scale and configuration of ingress user ACLs vary depending on the order and type of ACLs created.

**Example 1: 768 (IPv6+L2) user ACLs**

Without any user ACL configured, you can create up to 768 (IPv6 + L2) user ACLs. These ACLs require three pools in triple wide mode. Therefore, the `acl-table-usage detail` output shows six pools as two tables: one with 256 entries and another with 512 entries. The scale of these ACLs is 256+512 = 768.

**Example 2: 768 IPv4 user ACLs and 256 (IPv6+L2) user ACLs**

When IPv4 ACLs are configured, they use one pool (256 entries) in single wide mode, because the qualifiers and sizes fit in one pool. If IPv6+L2 user ACLs are added later, the NPU assigns the smaller pools to IPv6+L2 ACLs and moves the IPv4 ACLs to larger pools. Therefore, IPv6+L2 ACLs get three pools (256 entries each) and can scale up to 256 ACLs only.

The IPv4 ACL occupies one pool. To accommodate more than 256 ACL entries (IPv6+L2), three additional pools are required. However, only two pools are available, limiting the scale to 256 in this scenario. By using two smaller pools, it is possible to add 512 more IPv4 ACLs. Therefore, the total scale of IPv4 ACLs is 256+512 = 768.

## Egress ACL filters

Egress ACL filters affect the traffic that is directly connected towards destination. Configuring egress ACL filters onto physical interfaces protects the system infrastructure from a malicious and intentional attack by explicitly allowing only authorized traffic. These system-wide ACL filters eliminate the need to apply ACL filters onto each interface.

You can use an egress ACL filter to restrict egress traffic. For example, when you isolate denial of service (DoS) attack traffic to a specific interface, and apply an egress ACL filter to block the DoS flow from exiting the network, you protect downstream devices.

1. Apply an egress access-list on the interface in INTERFACE mode.

   ```
   ip access-group access-group-name out
   ```

2. Return to CONFIGURATION mode.

   ```
   exit
   ```

3. Create the access-list in CONFIGURATION mode.

   ```
   ip access-list access-list-name
   ```

4. Create the rules for the access-list in ACCESS-LIST mode.

   ```
   seq 10 deny ip any any count fragment
   ```

**Apply rules to ACL filter**

```
OS10(config)# interface ethernet 1/1/29
OS10(conf-if-eth1/1/29)# ip access-group egress out
OS10(conf-if-eth1/1/29)# exit
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 10 deny ip any any count fragment
```

**View IP ACL filter configuration**

```
OS10# show ip access-lists out
Egress IP access-list abcd
 Active on interfaces :
  ethernet1/1/29
 seq 10 deny ip any any fragment count (100 packets)
```

### Configuration notes

**Dell PowerSwitch S4200-ON Series:**

- You can create either Layer 2 ACL or Layer 3 ACL. You cannot create both the tables at a time.
- In egress L3 IPv4 ACL, the fragment, TCP flags, and DSCP fields are not supported.
- IPv6 user ACL table is not supported.
- In egress ACLs, L2 user table is used only for switched packets and L3 user table is used only for routed packets.
- In L2 user ACL, Ether type is not supported.

## VTY ACLs

To limit Telnet and SSH connections to the switch, apply access lists on a virtual terminal line (VTY). See Virtual terminal line ACLs for more information.

For VTY ACLs, there is no implicit deny rule. If none of the configured conditions match, the default behavior is to permit. If you need to deny traffic that does not match any of the configured conditions, explicitly configure a deny statement.

## SNMP ACLs

To filer SNMP requests on the switch, assign access lists to an SNMP community. Both IPv4 and IPv6 access lists are supported to restrict IP source addresses. See Restrict SNMP access for more information.

### Restrictions and limitations

- SNMP ACL works only when the SNMP server is reachable through the default VRF.
- SNMP ACLs support only permit or deny rules based on the source IP field. Other ACL parameters such as destination IP, protocol type, port number, and count are not supported.

## Clear access-list counters

Clear IPv4, IPv6, or MAC access-list counters for a specific access-list or all lists. The counter counts the number of packets that match each permit or deny statement in an access-list. To get a more recent count of packets matching an access-list, clear the counters to start at zero. If you do not configure an access-list name, all IP access-list counters are clear.

To view access-list information, use the `show access-lists` command.

- Clear IPv4 access-list counters in EXEC mode.

  ```
  clear ip access-list counters access-list-name
  ```

- Clear IPv6 access-list counters in EXEC mode.

  ```
  clear ipv6 access-list counters access-list-name
  ```

- Clear MAC access-list counters in EXEC mode.

  ```
  clear mac access-list counters access-list-name
  ```

## IP prefix-lists

IP prefix-lists control the routing policy. An IP prefix-list is a series of sequential filters that contain a matching criterion and an permit or deny action to process routes. The filters process in sequence so that if a route prefix does not match the criterion in the first filter, the second filter applies, and so on.

A route prefix is an IP address pattern that matches on bits within the IP address. The format of a route prefix is `A.B.C.D/x`, where A.B.C.D is a dotted-decimal address and /x is the number of bits that match the dotted decimal address.

When the route prefix matches a filter, the system drops or forwards the packet based on the filter's designated action. If the route prefix does not match any of the filters in the prefix-list, the route drops, an implicit deny.

For example, in 112.24.0.0/16, the first 16 bits of the address 112.24.0.0 match all addresses between 112.24.0.0 to 112.24.255.255. Use permit or deny filters for specific routes with the `le` (less or equal) and `ge` (greater or equal) parameters, where x.x.x.x/x represents a route prefix:

- To deny only /8 prefixes, enter `deny x.x.x.x/x ge 8 le 8`
- To permit routes with the mask greater than /8 but less than /12, enter `permit x.x.x.x/x ge 8 le 12`
- To deny routes with a mask less than /24, enter `deny x.x.x.x/x le 24`
- To permit routes with a mask greater than /20, enter `permit x.x.x.x/x ge 20`

The following rules apply to prefix-lists:

- A prefix-list without permit or deny filters allows all routes
- An implicit deny is assumed — the route drops for all route prefixes that do not match a permit or deny filter
- After a route matches a filter, the filter's action applies and no additional filters apply to the route

> **NOTE:** Use prefix-lists in processing routes for routing protocols such as open shortest path first (OSPF), route table manager (RTM), and border gateway protocol (BGP).

To configure a prefix-list, use commands in PREFIX-LIST and ROUTER-BGP modes. Create the prefix-list in PREFIX-LIST mode and assign that list to commands in ROUTER-BGP modes.

## Route-maps

Route-maps are a series of commands that contain a matching criterion and action. They change the packets meeting the matching criterion. ACLs and prefix-lists can only drop or forward the packet or traffic while route-maps process routes for route redistribution. For example, use a route-map to filter only specific routes and to add a metric.

- Route-maps also have an implicit deny. Unlike ACLs and prefix-lists where the packet or traffic drops, if a route does not match the route-map conditions, the route does not redistribute.
- Route-maps process routes for route redistribution. For example, to add a metric, a route-map can filter only specific routes. If the route does not match the conditions, the route-map decides where the packet or traffic drops. The route does not redistribute if it does not match.
- Route-maps use commands to decide what to do with traffic. To remove the match criteria in a route-map, use the `no match` command.
- In a BGP route-map, if you repeat the same match statements; for example, a match metric, with different values in the same sequence number, only the last match and set values are considered.

> **NOTE:** If you configure matching routes which conflict with local IP, the traffic is lifted to the CPU. For other nonmatching routes, the traffic is forwarded with the matching entry in the NPU table.

**Configure match metric**

```
OS10(config)# route-map hello
OS10(conf-route-map)# match metric 20
```

**View route-map**

```
OS10(conf-route-map)# do show route-map
route-map hello, permit, sequence 10
  Match clauses:
    metric 20
```

**Change match**

```
OS10(conf-route-map)# match metric 30
```

**View updated route-map**

```
OS10(conf-route-map)# do show route-map
route-map hello, permit, sequence 10
  Match clauses:
    metric 30
```

To filter the routes for redistribution, combine route-maps and IP prefix lists. The following table explains the action that is performed for multiple match commands under a single route-map.

**Table 139. Multiple match commands under a single route-map**

| Route-map clause | Prefix list | Incoming Route | Action |
|------------------|-------------|----------------|--------|
| permit | permit | MATCH | The route is permitted. |
| permit | permit | NO MATCH | Continue with next route-map clause. |
| permit | deny | MATCH | Continue with next route-map clause. |
| permit | deny | NO MATCH | Continue with next route-map clause. |
| deny | permit | MATCH | The route is denied. |
| deny | permit | NO MATCH | Continue with next route-map clause. |
| deny | deny | MATCH | Continue with next route-map clause. |
| deny | deny | NO MATCH | Continue with next route-map clause. |

**View both IP prefix-list and route-map configuration**

```
OS10(conf-router-bgp-neighbor-af)# do show ip prefix-list
ip prefix-list p1:
seq 1 deny 10.1.1.0/24
seq 10 permit 0.0.0.0/0 le 32
ip prefix-list p2:
seq 1 permit 10.1.1.0/24
seq 10 permit 0.0.0.0/0 le 32
```

**View route-map configuration**

```
OS10(conf-router-bgp-neighbor-af)# do show route-map
route-map test1, deny, sequence 10
Match clauses:
ip address prefix-list p1
Set clauses:
route-map test2, permit, sequence 10
Match clauses:
ip address prefix-list p1
Set clauses:
route-map test3, deny, sequence 10
Match clauses:
ip address prefix-list p2
Set clauses:
route-map test4, permit, sequence 10
Match clauses:
ip address prefix-list p2
Set clauses:
```

## ACL resequencing

Access control list (ACL) resequencing allows you to renumber the rules and remarks in an access or prefix list.

The placement of rules within the list is critical because packets are matched against rules in sequential order. To insert a new rule between existing ACL entries with consecutive sequence numbers, sequence numbers must be changed to create gap in between the existing rules without altering their priority. The ACL resequence configuration is used to change the sequence numbers of existing ACLs with required gap in between them.

For example, the following table contains some rules that are numbered in increments of 1. It is not possible to create new rules between these rules, so apply resequencing to create numbering space, as shown in the table below.

**Table 140. ACL resequencing**

| Rules | Resquencing |
|-------|-------------|
| Rules before resequencing | `seq 5 permit any host 1.1.1.1`<br>`seq 6 permit any host 1.1.1.2`<br>`seq 7 permit any host 1.1.1.3`<br>`seq 10 permit any host 1.1.1.4` |
| Rules after resequencing | `seq 5 permit any host 1.1.1.1`<br>`seq 10 permit any host 1.1.1.2`<br>`seq 15 permit any host 1.1.1.3`<br>`seq 20 permit any host 1.1.1.4` |

To resequence an ACL, use the `resequence access-list {ipv4 | ipv6 | mac} {access-list-name StartingSeqNum Step-to-Increment}` command.

You can resequence IPv4 and IPv6 ACLs, prefixes, and MAC ACLs.

> **NOTE:**
>
> - ACL resequencing does not affect the rules, remarks, or order in which they are applied. Resequencing merely renumbers the rules so that you can place new rules within the list as needed.
> - The no form of the `resequence access-list {mac | ipv4 | ipv6} {access-list-name StartingSeqNum Step-to-Increment}` command is not supported.

## Match routes

Configure match criterion for a route-map. There is no limit to the number of match commands per route map, but keep the number of match filters in a route-map low. The set commands do not require a corresponding match command.

- Match routes with a specific metric value in ROUTE-MAP mode, from 0 to 4294967295.

  ```
  match metric metric-value
  ```

- Match routes with a specific tag in ROUTE-MAP mode, from 0 to 4294967295.

  ```
  match tag tag-value
  ```

- Match routes whose next hop is a specific interface in ROUTE-MAP mode.

  ```
  match interface interface
  ```

  - ethernet—Enter the Ethernet interface information.
  - port-channel—Enter the LAG number.
  - vlan—Enter the VLAN ID number.

**Check match routes**

```
OS10(config)# route-map test permit 1
0S10(conf-route-map)# match tag 250000
OS10(conf-route-map)# set weight 100
```

## Set conditions

There is no limit to the number of set commands per route map, but keep the number of set filters in a route-map low. The set commands do not require a corresponding match command.

- Enter the IP address in A.B.C.D format of the next-hop for a BGP route update in ROUTE-MAP mode.

  ```
  set ip next-hop address
  ```

- Enter an IPv6 address in A::B format of the next-hop for a BGP route update in ROUTE-MAP mode.

  ```
  set ipv6 next-hop address
  ```

- Enter the range value for the BGP route LOCAL_PREF attribute in ROUTE-MAP mode, from 0 to 4294967295.

  ```
  set local-preference range-value
  ```

- Enter a metric value for redistributed routes in ROUTE-MAP mode, from 0 to 4294967295.

  ```
  set metric {+ | - | metric-value}
  ```

- Enter an OSPF type for redistributed routes in ROUTE-MAP mode.

  ```
  set metric-type {type-1 | type-2 | external | internal}
  ```

- Enter an ORIGIN attribute in ROUTE-MAP mode.

  ```
  set origin {egp | igp | incomplete}
  ```

- Enter a tag value for the redistributed routes in ROUTE-MAP mode, from 0 to 4294967295.

  ```
  set tag tag-value
  ```

- Enter a value as the route weight in ROUTE-MAP mode, from 0 to 65535.

  ```
  set weight value
  ```

**Check set conditions**

```
OS10(config)# route-map ip permit 1
OS10(conf-route-map)# match metric 2567
```

## Continue clause

Only BGP route-maps support the continue clause. When a match is found, set clauses run and the packet forwards — no route-map processing occurs. If you configure the continue clause without configuring a module, the next sequential module processes.

If you configure the continue command at the end of a module, the next module processes even after a match is found. The example shows a continue clause at the end of a route-map module — if a match is found in the route-map test module 10, module 30 processes.

**Route-map continue clause**

```
OS10(config)# route-map test permit 10
OS10(conf-route-map)# continue 30
```

## ACL flow-based monitoring

Flow-based monitoring conserves bandwidth by selecting only the required flow to mirror instead of mirroring entire packets from an interface. This feature is available for L2 and L3 ingress traffic. Specify flow-based monitoring using ACL rules.

Flow-based monitoring copies incoming packets that match the ACL rules that are applied on the ingress port and forwards, or mirrors them to another port. The source port is the monitored port (MD), and the destination port is the monitoring port (MG).

When a packet arrives at a monitored port, the packet validates against the configured ACL rules. If the packet matches an ACL rule, the system examines the corresponding flow processor and performs the action that is specified for that port. If the mirroring action is set in the flow processor entry, the port details are sent to the destination port.

### Flow-based mirroring

Flow-based mirroring is a mirroring session in which traffic matches specified policies that mirror to a destination port. Port-based mirroring maintains a database that contains all monitoring sessions, including port monitor sessions. The database has information regarding the sessions that are enabled or not enabled for flow-based monitoring. Flow-based mirroring is also known as policy-based mirroring.

To enable flow-based mirroring, use the `flow-based enable` command. Traffic with particular flows that traverse through the ingress interfaces are examined. Appropriate ACL rules apply in the ingress direction. By default, flow-based mirroring is not enabled.

To enable evaluation and replication of traffic traversing to the destination port, configure the monitor option using the `permit`, `deny`, or `seq` commands for ACLs assigned to the source or the monitored port (MD). Enter the keywords `capture session session-id` with the `seq`, `permit`, or `deny` command for the ACL rules to allow or drop IPv4, IPv6, ARP, UDP, EtherType, ICMP, and TCP packets.

**IPV4-ACL mode**

```
seq sequence-number {deny | permit} {source [mask] | any | host ip-address} [count [byte]]
[fragments] [threshold-in-msgs count] [capture session session-id]
```

If you configure the `flow-based enable` command and do not apply an ACL on the source port or the monitored port, both flow-based monitoring and port mirroring do not function. Flow-based monitoring is supported only for ingress traffic.

The `show monitor session session-id` command displays output that indicates if a particular session is enabled for flow-monitoring.

**View flow-based monitoring**

```
OS10# show monitor session 1
S.Id  Source        Destination    Dir  SrcIP  DstIP  DSCP  TTL  State Reason
----------------------------------------------------------------------------
1    ethernet1/1/1  ethernet1/1/4  both  N/A   N/A    N/A  N/A  true   Is UP
```

**Traffic matching ACL rule**

```
OS10# show ip access-lists in
Ingress IP access-list testflow
 Active on interfaces :
  ethernet1/1/1
 seq 5 permit icmp any any capture session 1 count (0 packets)
 seq 10 permit ip 102.1.1.0/24 any capture session 1 count bytes (0 bytes)
 seq 15 deny udp any any capture session 2 count bytes (0 bytes)
 seq 20 deny tcp any any capture session 3 count bytes (0 bytes)
```

### Enable flow-based monitoring

Flow-based monitoring conserves bandwidth by mirroring only specified traffic, rather than all traffic on an interface. It is available for L2 and L3 ingress and egress traffic. Configure traffic to monitor using ACL filters.

1. Create a monitor session in MONITOR-SESSION mode.

   ```
   monitor session session-number type  {local | rspan-source}
   ```

2. Enable flow-based monitoring for the mirroring session in MONITOR-SESSION mode.

   ```
   flow-based enable
   ```

3. Define ACL rules that include the keywords `capture session session-id` in CONFIGURATION mode. The system only considers port monitoring traffic that matches rules with the keywords `capture session`.

   ```
   ip access-list
   ```

4. Apply the ACL to the monitored port in INTERFACE mode.

   ```
   ip access-group access-list
   ```

**Enable flow-based monitoring**

```
OS10(config)# monitor session 1 type local
OS10(conf-mon-local-1)# flow-based enable
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# seq 5 permit icmp any any capture session 1
OS10(conf-ipv4-acl)# seq 10 permit ip 102.1.1.0/24 any capture session 1 count byte
OS10(conf-ipv4-acl)# seq 15 deny udp any any capture session 2 count byte
OS10(conf-ipv4-acl)# seq 20 deny tcp any any capture session 3 count byte
OS10(conf-ipv4-acl)# exit
OS10(config)# interface ethernet 1/1/1
OS10(conf-if-eth1/1/1)# ip access-group testflow in
OS10(conf-if-eth1/1/1)# no shutdown
```

**View access-list configuration**

```
OS10# show ip access-lists in
Ingress IP access-list testflow
 Active on interfaces :
  ethernet1/1/1
 seq 5 permit icmp any any capture session 1 count (0 packets)
 seq 10 permit ip 102.1.1.0/24 any capture session 1 count bytes (0 bytes)
 seq 15 deny udp any any capture session 2 count bytes (0 bytes)
 seq 20 deny tcp any any capture session 3 count bytes (0 bytes)
```

**View monitor sessions**

```
OS10(conf-if-eth1/1/1)# show monitor session all
S.Id  Source       Destination    Dir  SrcIP  DstIP  DSCP TTL  State  Reason
----------------------------------------------------------------------------
1   ethernet1/1/1  ethernet1/1/4  both  N/A   N/A    N/A  N/A  true   Is UP
```

## View ACL table utilization report

The `show acl-table-usage detail` command shows the ingress and egress ACL tables for the various features and their utilization.

The hardware pool area displays the ingress application groups (pools), the features mapped to each of these groups, and the amount of used and free space available in each of the pools. The amount of space required to store a single ACL rule in a pool depends on the keywidth of the TCAM slice.

The service pool displays the amount of used and free space for each of the features. The number of ACL rules that are configured for a feature is displayed in the configured rules column. The number of used rows depends on the number of ports the configured rules are applied on. Under Allocated pools, you can view the percentage of dedicated space reserved for a particular feature or the phrase Shared if you have not reserved space for each of the features individually, against the total number of pools allocated for the application group. In the example given below, the SYSTEM_FLOW feature has 15 percentage of space reserved in ingress app-group-1 with a pool count of 1, which is represented by 15:1.

```
OS10# show acl-table-usage detail
Ingress ACL utilization
Hardware Pools
-----------------------------------------------------------------------------------------
Pool ID     App(s)                                                   Used rows    Free rows    Max rows
-----------------------------------------------------------------------------------------
0         SYSTEM_FLOW                                                 49           975          1024
1         SYSTEM_FLOW                                                 49           975          1024
2         USER_IPV4_ACL                                               3            1021         1024
3         USER_L2_ACL                                                 2            1022         1024
4         USER_IPV6_ACL                                               2            510          512
5         USER_IPV6_ACL                                               2            510          512
6         FCOE                                                        55           457          512
7         FCOE                                                        55           457          512
8         ISCSI_SNOOPING                                              12           500          512
9         FREE                                                        0            512          512
10        PBR_V6                                                      1            511          512
11        PBR_V6                                                      1            511          512
-----------------------------------------------------------------------------------------
Service Pools
-----------------------------------------------------------------------------------------
App                 Allocated pools  App group   Configured rules    Used rows    Free rows    Max rows
-----------------------------------------------------------------------------------------
USER_L2_ACL         Shared:1         G3          1                   2            1022         1024
USER_IPV4_ACL       Shared:1         G2          2                   3            1021         1024
USER_IPV6_ACL       Shared:2         G4          1                   2            510          512
PBR_V6              Shared:2         G10         1                   1            511          512
SYSTEM_FLOW         Shared:2         G0          49                  49           975          1024
ISCSI_SNOOPING      Shared:1         G8          12                  12           500          512
FCOE                Shared:2         G6          55                  55           457          512
-----------------------------------------------------------------------------------------
Egress ACL utilization
Hardware Pools
-----------------------------------------------------------------------------------------
Pool ID     App(s)                                                   Used rows    Free rows    Max rows
-----------------------------------------------------------------------------------------
0         USER_IPV4_EGRESS                                            2            254          256
1         USER_L2_ACL_EGRESS                                          2            254          256
2         USER_IPV6_EGRESS                                            2            254          256
3         USER_IPV6_EGRESS                                            2            254          256
-----------------------------------------------------------------------------------------
Service Pools
-----------------------------------------------------------------------------------------
App                 Allocated pools  App group   Configured rules    Used rows    Free rows    Max rows
-----------------------------------------------------------------------------------------
USER_L2_ACL_EGRESS  Shared:1         G1          1                   2            254          256
USER_IPV4_EGRESS    Shared:1         G0          1                   2            254          256
USER_IPV6_EGRESS    Shared:2         G2          1                   2            254          256
```

### Known behavior

- On the S4200-ON platform, the `show acl-table-usage detail` command output lists several hardware pools as available (FREE), but you will see an "ACL CAM table full" warning log when the system creates a service pool. The system cannot create any service pools. The existing groups, however, can continue to grow up to the maximum available pool space.
- On the S4200-ON platform, the `show acl-table usage detail` command output lists all the available hardware pools under the Ingress ACL utilization table and none under the Egress ACL utilization table. The system allocates pool space for Egress ACL table only when you configure Egress ACLs. You can run the `show acl-table-usage detail` command again to view pool space that is allocated under the Egress ACL utilization table as well.
- On S5200-ON, Z9100-ON, Z9200-ON platforms, the number of Configured Rules that are listed under Service Pools for each of the features is the number of ACLs multiplied by the number of ports on which they are applied. This number is cumulative. You can view the Used rows and Free rows that indicate the amount of space that is used and available in the hardware.

## ACL logging

You can configure ACLs to filter traffic, drop, or forward packets that match certain conditions. The ACL logging feature allows you to get additional information about packets that match an access control entry (ACE) applied on an interface in inbound direction.

ACL logging helps to administer and manage traffic that traverses your network and is useful for network supervision and maintenance activities. High volumes of network traffic can result in large volume of logs, which can negatively impact system performance and efficiency. You can configure the log update threshold, logging interval, and logging rate limit to reduce impact on device CPU load.

This feature is applicable only for IP user ACLs and control-plane ACLs.

### Important notes

The ACL logging feature is:

- Applicable only for IPv4 and IPv6 user ACLs and control-plane ACLs. MAC ACLs are not logged.
- Applicable only for IP user ACLs or control-plane ACLs applied on interfaces in the inbound direction. Even though ACL logging cannot be enabled for outbound ACLs, ACL configuration is applied.
- ACL logging is not supported for control-plane ACL data.

For IP user ACLs, Dell Technologies recommends a maximum scale of 128 log-enabled ACL entries. If logging cannot be enabled on further ACL entries, a syslog error message appears to indicate that logging cannot be enabled. However, the ACL entries are applied.

### IP ACL logging

The IP ACL logging feature allows you to monitor the user-created ACL flows and log packets that match ACEs applied on an interface in inbound direction. To control the volume of logs, specify the threshold after which a log is created and the interval at which the logs must be created.

You can specify the threshold after which a log is created and the interval at which the logs must be created. The threshold defines how often a log message is created after an initial packet match. The default threshold is 10 messages. This value is configurable, and the range is from 1 to 100 messages.

By default, the interval is set to 5 minutes and logs are created every 5 minutes. During this interval, the system continues to examine the packets against the configured ACL rule and permits or denies traffic, but logging is halted temporarily. This value is configurable, and the range is from 1 to 10 minutes.

For example, if you have configured a threshold value of 20 and an interval of 10 minutes, after an initial packet match is logged, the 20th packet that matches the ACE is logged. The system then waits for the interval period of 10 minutes to elapse, during which time no logging occurs. Once the interval period elapses, the 20th packet that matches the ACE is logged again.

### Control-plane management ACL logging

Control-plane management ACL logging is used to monitor the packets that ingress from the management interface, and drop or forward packets that match certain conditions. OS10 creates a log message that includes additional information about the packet, when a matching packet hits a log-enabled ACE. This feature is applicable only for control-plane ACLs applied on the management interface in the inbound direction.

By default, this feature limits the number of logged packets per ACL rule at the rate of two packets per minute and a burst size of two packets. Use the `logging access-list mgmt rate` and `logging access-list mgmt burst` commands to reconfigure the logging rate and burst size of a control-plane ACL applied on the management interface. Use the `show control-plane logging` command to view the configured burst size and logging rate for control-plane management ACL.

## ACL commands

### clear ip access-list counters

Clears ACL counters for a specific access-list.

**Syntax**

```
clear ip access-list counters [access-list-name]
```

**Parameters**

`access-list-name`—(Optional) Enter the name of the IP access-list to clear counters. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

If you do not enter an access-list name, all IPv6 access-list counters are cleared. The counter counts the number of packets that match each permit or deny statement in an access-list. To get a more recent count of packets matching an access list, clear the counters to start at zero. To view access-list information, use the `show access-lists` command.

**Example**

```
OS10# clear ip access-list counters
```

**Supported Releases**

10.2.0E or later

### clear ipv6 access-list counters

Clears IPv6 access-list counters for a specific access-list.

**Syntax**

```
clear ipv6 access-list counters [access-list-name]
```

**Parameters**

`access-list-name`—(Optional) Enter the name of the IPv6 access-list to clear counters. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

If you do not enter an access-list name, all IPv6 access-list counters are cleared. The counter counts the number of packets that match each permit or deny statement in an access list. To get a more recent count of packets matching an access list, clear the counters to start at zero. To view access-list information, use the `show access-lists` command.

**Example**

```
OS10# clear ipv6 access-list counters
```

**Supported Releases**

10.2.0E or later

### clear mac access-list counters

Clears counters for a specific or all MAC access lists.

**Syntax**

```
clear mac access-list counters [access-list-name]
```

**Parameters**

`access-list-name`—(Optional) Enter the name of the MAC access list to clear counters. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

If you do not enter an access-list name, all MAC access-list counters are cleared. The counter counts the number of packets that match each permit or deny statement in an access list. To get a more recent count of packets matching an access list, clear the counters to start at zero. To view access-list information, use the `show access-lists` command.

**Example**

```
OS10# clear mac access-list counters
```

**Supported Releases**

10.2.0E or later

### deny

Configures a filter to drop packets with a specific IP address.

**Syntax**

```
deny [protocol-number | icmp | ip | tcp | udp] [A.B.C.D | A.B.C.D/x | any
| host ip-address] [A.B.C.D | A.B.C.D/x | any | host ip-address] [capture
| count | dscp value | fragment | log]
```

**Parameters**

- `protocol-number` — (Optional) Enter the protocol number identified in the IP header, from 0 to 255.
- `icmp` — (Optional) Enter the ICMP address to deny.
- `ip` — (Optional) Enter the IP address to deny.
- `tcp` — (Optional) Enter the TCP address to deny.
- `udp` — (Optional) Enter the UDP address to deny.
- `A.B.C.D` — Enter the IP address in dotted decimal format.
- `A.B.C.D/x` — Enter the number of bits to match to the dotted decimal address.
- `any` — (Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address` — (Optional) Enter the keyword and the IP address to use a host address only.
- `capture` — (Optional) Capture packets the filter processes.
- `count` — (Optional) Count packets the filter processes.
- `byte` — (Optional) Count bytes the filter processes.
- `dscp value` — (Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment` — (Optional) Use ACLs to control packet fragments.
- `log` — (Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# deny udp any any
```

**Supported Releases**

10.2.0E or later

### deny (IPv6)

Configures a filter to drop packets with a specific IPv6 address.

**Syntax**

```
deny [protocol-number | icmp | ipv6 | tcp | udp] [A::B | A::B/x | any |
host ipv6-address] [A::B | A::B/x | any | host ipv6-address] [capture |
count | dscp value | fragment | log]
```

**Parameters**

- `protocol-number`—(Optional) Enter the protocol number identified in the IP header, from 0 to 255.
- `icmp`—(Optional) Enter the ICMP address to deny.
- `ipv6`—(Optional) Enter the IPv6 address to deny.
- `tcp`—(Optional) Enter the TCP address to deny.
- `udp`—(Optional) Enter the UDP address to deny.
- `A::B`—Enter the IPv6 address in dotted decimal format.
- `A::B/x`—Enter the number of bits to match to the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the keyword and the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets that the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# deny ipv6 any any capture session 1
```

**Supported Releases**

10.2.0E or later

### deny (MAC)

Configures a filter to drop packets with a specific MAC address.

**Syntax**

```
deny {nn:nn:nn:nn:nn:nn [00:00:00:00:00:00] | any} {nn:nn:nn:nn:nn:nn
[00:00:00:00:00:00] | any} [protocol-number | capture | cos | count |
vlan]
```

**Parameters**

- `nn:nn:nn:nn:nn:nn`—Enter the MAC address of the network from or to which the packets are sent.
- `00:00:00:00:00:00`—(Optional) Enter which bits in the MAC address must match. If you do not enter a mask, a mask of 00:00:00:00:00:00 applies.
- `any`—(Optional) Set routes which are subject to the filter.
  - `protocol-number`—(Optional) MAC protocol number identified in the header, from 600 to ffff.
  - `capture`—(Optional) Capture packets the filter processes.
  - `cos`—(Optional) CoS value, from 0 to 7.
  - `count`—(Optional) Count packets the filter processes.
  - `vlan`—(Optional) VLAN number, from 1 to 4093.

**Default**

Disabled

**Command Mode**

MAC-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# mac access-list macacl
OS10(conf-mac-acl)# deny any any cos 7
OS10(conf-mac-acl)# deny any any vlan 2
```

**Supported Releases**

10.2.0E or later

### deny icmp

Configures a filter to drop all or specific Internet Control Message Protocol (ICMP) messages.

**Syntax**

```
deny icmp [A.B.C.D | A.B.C.D/x | any | host ip-address] [[A.B.C.D |
A.B.C.D/x | any | host ip-address] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `A.B.C.D`—Enter the IP address in hexadecimal format separated by colons.
- `A.B.C.D/x`—Enter the number of bits to match to the IP address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IP address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# deny icmp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### deny icmp (IPv6)

Configures a filter to drop all or specific ICMP messages.

**Syntax**

```
deny icmp [A::B | A::B/x | any | host ipv6-address] [A::B | A::B/x | any
| host ipv6-address] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits to match to the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# deny icmp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### deny ip

Configures a filter to drop all or specific packets from an IPv4 address.

**Syntax**

```
deny ip [A.B.C.D | A.B.C.D/x | any | host ip-address] [[A.B.C.D |
A.B.C.D/x | any | host ip-address] [capture |count [byte] | dscp value
| fragment]
```

**Parameters**

- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits to match to the dotted decimal address.
- `any`—(Optional) Set all routes which are subject to the filter:
  - `capture`—(Optional) Capture packets the filter processes.
  - `count`—(Optional) Count packets the filter processes.
  - `byte`—(Optional) Count the bytes the filter processes.
  - `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
  - `fragment`—(Optional) Use ACLs to control packet fragments.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# deny ip any any capture session 1 count
```

**Supported Releases**

10.2.0E or later

### deny ipv6

Configures a filter to drop all or specific packets from an IPv6 address.

**Syntax**

```
deny ipv6 [A::B | A::B/x | any | host ipv6–address] [A::B | A:B/x | any |
host ipv6–address] [capture | count [byte] | dscp | fragment]
```

**Parameters**

- `A::B`—(Optional) Enter the source IPv6 address from which the packet was sent and the destination address.
- `A::B/x`—(Optional) Enter the source network mask in /prefix format (/x) and the destination mask.
- `any`—(Optional) Set all routes which are subject to the filter:
  - `capture`—(Optional) Capture packets the filter processes.
  - `count`—(Optional) Count packets the filter processes.
  - `byte`—(Optional) Count the Count the the filter processes.
  - `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
  - `fragment`—(Optional) Use ACLs to control packet fragments.
- `host ipv6–address`—(Optional) Enter the IPv6 address to use a host address only.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# deny ipv6 any any capture session 1
```

**Supported Releases**

10.2.0E or later

### deny tcp

Configures a filter that drops Transmission Control Protocol (TCP) packets meeting the filter criteria.

**Syntax**

```
deny tcp [A.B.C.D | A.B.C.D/x | any | host ip-address [operator]]
[[A.B.C.D | A.B.C.D/x | any | host ip-address [operator]] [ack | fin |
psh | rst | syn | urg] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A.B.C.D` — Enter the IPv4 address in A.B.C.D format.
- `A.B.C.D/x` — Enter the number of bits to match in A.B.C.D/x format.
- `any` — (Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address` — (Optional) Enter the keyword and the IPv4 address to use a host address only.
- `ack` — (Optional) Set the bit as acknowledgement.
- `fin` — (Optional) Set the bit as finish—no more data from sender.
- `psh` — (Optional) Set the bit as push.
- `rst` — (Optional) Set the bit as reset.
- `syn` — (Optional) Set the bit as synchronize.
- `urg` — (Optional) Set the bit set as urgent.
- `capture` — (Optional) Capture packets the filter processes.
- `count` — (Optional) Count packets the filter processes.
- `byte` — (Optional) Count bytes the filter processes.
- `dscp value` — (Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment` — (Optional) Use ACLs to control packet fragments.
- `log` — (Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.
- `operator` — (Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq` — Equal to
  - `gt` — Greater than
  - `lt` — Lesser than
  - `neq` — Not equal to
  - `range` — Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# deny tcp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### deny tcp (IPv6)

Configures a filter that drops TCP IPv6 packets meeting the filter criteria.

**Syntax**

```
deny tcp [A::B | A::B/x | any | host ipv6-address [operator]] [A::B |
A:B/x | any | host ipv6-address [operator]] [ack | fin | psh | rst | syn
| urg] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits to match to the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# deny tcp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### deny udp

Configures a filter to drop User Datagram Protocol (UDP) packets meeting the filter criteria.

**Syntax**

```
deny udp [A.B.C.D | A.B.C.D/x | any | host ip-address [operator]]
[A.B.C.D | A.B.C.D/x | any | host ip-address [operator]] [ack | fin |
psh | rst | syn | urg] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits to match to the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# deny udp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### deny udp (IPv6)

Configures a filter to drop UDP IPv6 packets that match the filter criteria.

**Syntax**

```
deny udp [A::B | A::B/x | any | host ipv6-address [operator]] [A::B |
A:B/x | any | host ipv6-address [operator]] [ack | fin | psh | rst | syn
| urg] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits to match to the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the keyword and the IPv6 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you use the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# deny udp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### description

Configures an ACL description.

**Syntax**

```
description text
```

**Parameters**

`text` — Enter the description text string. A maximum of 80 characters.

**Default**

Disabled

**Command Modes**

IPV4-ACL, IPV6-ACL, MAC-ACL

**Usage Information**

- To use special characters as a part of the description string, enclose the string in double quotes.
- To use comma as a part of the description string add double back slash before the comma.
- The no version of this command deletes the ACL description.

**Example**

```
OS10(conf-ipv4-acl)# description ipacltest
```

**Supported Releases**

10.2.0E or later

### ip access-group

Configures an IPv4 access group.

**Syntax**

```
ip access-group access-list-name [security] {in | out}
```

**Parameters**

- `access-list-name`—Enter the name of an IPv4 access list up to a maximum of 140 characters.
- `security`—Enter the keyword to configure the control plane ACL to permit trusted IPs or deny untrusted IPs. This option is available only in CONTROL-PLANE mode.
- `in`—Apply the ACL to traffic that is directly connected towards source.
- `out`—Apply the ACL to traffic that is directly connected towards destination.

**Default**

Not configured

**Command Mode**

INTERFACE CONTROL-PLANE

**Usage Information**

Use this command in the CONTROL-PLANE mode to apply a control-plane ACL. Control-plane ACLs are only applied on the ingress traffic. By default, the control-plane ACL is applied to the front-panel ports as well as the management port. The no version of this command deletes the IPv4 ACL configuration, regardless of whether the access-list-name parameter is omitted or an incorrect ACL name is provided.

**Example**

```
OS10(conf-if-eth1/1/8)# ip access-group testgroup in
```

**Example (Control-plane ACL)**

```
OS10# configure terminal
OS10(config)# control-plane
OS10(config-control-plane)# ip access-group aaa-cp-acl in
```

**Example (Permit only trusted IPs)**

```
OS10# configure terminal
OS10(config)# ip access-list ip-permit
OS10(config-ipv4-acl)#seq 10 permit ip src-ip any count
OS10(config-ipv4-acl)# seq 20 deny any any count
OS10(config-ipv4-acl)# exit
OS10(config)# control-plane
OS10(config-control-plane)# ip access-group ip-permit security in
```

**Example (Deny untrusted IPs)**

```
OS10# configure terminal
OS10(config)# ip access-list ip-deny
OS10(config-ipv4-acl)# deny ip host src-ip any count
OS10(config-ipv4-acl)# exit
OS10(config)# control-plane
OS10(config-control-plane)# ip access-group ip-deny security in
```

**Supported Releases**

10.2.0E or later; 10.4.1 or later (control-plane ACL); 10.5.6.4 or later (security parameter)

### ip access-list

Creates an IP access list to filter based on an IP address.

**Syntax**

```
ip access-list access-list-name
```

**Parameters**

`access-list-name`—Enter the name of an IPv4 access list. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

None

**Example**

```
OS10(config)# ip access-list acl1
```

**Supported Releases**

10.2.0E or later

### ip as-path access-list

Create an AS-path ACL filter for BGP routes using a regular expression. The AS values should be configured only in the plain format (regular expressions) and not in the dotted format. This works similar to the AS values received in the BGP update messages.

**Syntax**

```
ip as-path access-list name {deny | permit} regexp-string
```

**Parameters**

- `name`—Enter an access list name.
- `deny | permit`—Reject or accept a matching route.
- `regexp-string`—Enter a regular expression string to match an AS-path route attribute.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

You can specify an access-list filter on inbound and outbound BGP routes. The ACL filter consists of regular expressions. If a regular expression matches an AS path attribute in a BGP route, the route is rejected or accepted. The AS path does not contain the local AS number. The no version of this command removes a single access list entry if you specify deny and a regexp. Otherwise, the entire access list is removed. The following table provides a list of characters that you can use in the regular expression string and indicates whether the character is supported or not:

**Table 141. Special characters supported in regular expression**

| Character | Supported or Not supported |
|-----------|----------------------------|
| Question mark (?) | Not supported |
| Pipe (\|) | Supported |
| Plus (+) | Supported |
| Caret (^) | Supported; use the caret (^) character to represent the beginning of a new line. |
| Dollar ($) | Supported |
| Square brackets ([ ]) | Supported |
| Asterisk (*) | Supported |
| Dot (.) | Supported |
| Backslash (\\) | Supported; precede the character with a backslash(\\). For example, enter \\\\. |
| Double quotes (") | Supported; precede the character with a backslash(\\). For example, enter \\". |
| Curly brackets ({ }) | Not supported; as a workaround, precede the open and close parentheses with a backslash, for example "\\(" and "\\)". |
| Parentheses (()) | Supported |
| Comma (,) | Supported; comma(,) can be used to match space in AS-PATH. |
| Space | Not supported; as a workaround, use comma(,) or [[:punct:]]. |
| Underscore ( _ ) | Not supported |

**Example**

```
OS10(config)# ip as-path access-list abc deny 123
```

**Supported Release**

10.3.0E or later

### ip community-list standard deny

Creates a standard community list for BGP to deny access.

**Syntax**

```
ip community-list standard name deny {aa:nn | no-advertise | local-AS |
no-export | internet}
```

**Parameters**

- `name`—Enter the name of the standard community list used to identify one more deny group of communities. Do not use the term none as the name of the standard community list.
- `aa:nn`—Enter the community number in the format aa:nn, where aa is the number that identifies the autonomous system and nn is a number the identifies the community within the autonomous system.
- `no-advertise`—BGP does to not advertise this route to any internal or external peer.
- `local-AS`—BGP does not advertise this route to external peers.
- `no-export`—BGP does not advertise this route outside a BGP confederation boundary.
- `internet`—BGP does not advertise this route to an Internet community.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the community list.

**Example**

```
OS10(config)# ip community-list standard STD_LIST deny local-AS
```

**Supported Release**

10.3.0E or later

### ip community-list standard permit

Creates a standard community list for BGP to permit access.

**Syntax**

```
ip community-list standard name permit {aa:nn | no-advertise | local-as |
no-export | internet}
```

**Parameters**

- `name`—Enter the name of the standard community list used to identify one more permit groups of communities. Do not use the term none as the name of the standard community list.
- `aa:nn`—Enter the community number in the format aa:nn, where aa is the number that identifies the autonomous system and nn is a number the identifies the community within the autonomous system.
- `no-advertise`—BGP does not advertise this route to any internal or external peer.
- `local-as`—BGP does not advertise this route to external peers.
- `no-export`—BGP does not advertise this route outside a BGP confederation boundary.
- `internet`—BGP does not advertise this route to an Internet community.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the community list.

**Example**

```
OS10(config)# ip community-list standard STD_LIST permit local-AS
```

**Supported Release**

10.3.0E or later

### ip extcommunity-list standard deny

Creates an extended community list for BGP to deny access.

**Syntax**

```
ip extcommunity-list standard name deny {4byteas-generic | rt | soo}
```

**Parameters**

- `name`—Enter the name of the community list used to identify one or more deny groups of extended communities. Do not use the term none as the name of the extended community list.
- `4byteas-generic`—Enter the generic extended community then the keyword transitive or non-transitive.
- `rt`—Enter the route target.
- `soo`—Enter the route origin or site-of-origin.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the extended community list.

**Example**

```
OS10(config)# ip extcommunity-list standard STD_LIST deny 4byteas-generic transitive 1.65534:40
```

**Supported Release**

10.3.0E or later

### ip extcommunity-list standard permit

Creates an extended community list for BGP to permit access.

**Syntax**

```
ip extcommunity-list standard name permit {4byteas-generic | rt | soo}
```

**Parameters**

- `name`—Enter the name of the community list used to identify one or more permit groups of extended communities. Do not use the term none as the name of the extended community list.
- `rt`—Enter the route target.
- `soo`—Enter the route origin or site-of-origin.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the extended community list.

**Example**

```
OS10(config)# ip extcommunity-list standard STD_LIST permit 4byteas-generic transitive 1.65412:60
```

**Supported Release**

10.3.0E or later

### ip prefix-list description

Configures a description of an IP prefix list.

**Syntax**

```
ip prefix-list name description
```

**Parameters**

- `name`—Enter the name of the prefix list.
- `description`—Enter the description for the named prefix list.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix list.

**Example**

```
OS10(config)# ip prefix-list TEST description TEST_LIST
```

**Supported Release**

10.3.0E or later

### ip prefix-list deny

Creates a prefix list to deny route filtering from a specified network address.

**Syntax**

```
ip prefix-list name deny [A.B.C.D/x [ge | le]] prefix-len
```

**Parameters**

- `name`—Enter the name of the prefix list.
- `A.B.C.D/x`—(Optional) Enter the source network address and mask in /prefix format (/x).
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix-list.

**Example**

```
OS10(config)# ip prefix-list denyprefix deny 10.10.10.2/16 le 30
```

**Supported Release**

10.3.0E or later

### ip prefix-list permit

Creates a prefix-list to permit route filtering from a specified network address.

**Syntax**

```
ip prefix-list name permit [A.B.C.D/x [ge | le]] prefix-len
```

**Parameters**

- `name`—Enter the name of the prefix list.
- `A.B.C.D/x`—(Optional) Enter the source network address and mask in /prefix format (/x).
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix-list.

**Example**

```
OS10(config)# ip prefix-list allowprefix permit 10.10.10.1/16 ge 10
```

**Supported Release**

10.3.0E or later

### ip prefix-list seq deny

Configures a filter to deny route filtering from a specified prefix list.

**Syntax**

```
ip prefix-list name seq num deny {A.B.C.D/x [ge | le] prefix-len}
```

**Parameters**

- `name`—Enter the name of the prefix list.
- `num`—Enter the sequence list number.
- `A.B.C.D/x`—Enter the source network address and mask in /prefix format (/x).
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix list.

**Example**

```
OS10(config)# ip prefix-list seqprefix seq 65535 deny 10.10.10.1/16 ge 10
```

**Supported Release**

10.3.0E or later

### ip prefix-list seq permit

Configures a filter to permit route filtering from a specified prefix list.

**Syntax**

```
ipv6 prefix-list [name] seq num permit A::B/x [ge | le} prefix-len
```

**Parameters**

- `name`—Enter the name of the prefix list.
- `num`—Enter the sequence list number.
- `A.B.C.D/x`—Enter the source network address and mask in /prefix format (/x).
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix list.

**Example**

```
OS10(config)# ip prefix-list seqprefix seq 65535 permit 10.10.10.1/16 le 30
```

**Supported Release**

10.3.0E or later

### ipv6 access-group

Configures an IPv6 access group.

**Syntax**

```
ipv6 access-group access-list-name [security] {in | out}
```

**Parameters**

- `access-list-name`—Enter the name of an IPv6 ACL up to a maximum of 140 characters.
- `security`—Enter the keyword to configure the control plane ACL to permit trusted IPs or deny untrusted IPs. This option is available only in CONTROL-PLANE mode.
- `in`—Apply the ACL to traffic that is directly connected towards source.
- `out`—Apply the ACL to traffic that is directly connected towards destination.

**Default**

Not configured

**Command Mode**

INTERFACE CONTROL-PLANE

**Usage Information**

Use this command in the CONTROL-PLANE mode to apply a control-plane ACL. Control-plane ACLs are only applied on the ingress traffic. By default, the control-plane ACL is applied to the front-panel ports as well as the management port. The no version of this command deletes an IPv6 ACL configuration, regardless of whether the access-list-name parameter is omitted or an incorrect ACL name is provided.

**Example**

```
OS10(conf-if-eth1/1/8)# ipv6 access-group test6 in
```

**Example (Control-plane ACL)**

```
OS10# configure terminal
OS10(config)# control-plane
OS10(config-control-plane)# ipv6 access-group aaa-cp-acl in
```

**Supported Releases**

10.2.0E or later; 10.4.1 or later (control-plane ACL) ; 10.5.6.4 or later (security parameter)

### ipv6 access-list

Creates an IP access list to filter based on an IPv6 address.

**Syntax**

```
ipv6 access-list access-list-name
```

**Parameters**

`access-list-name`—Enter the name of an IPv6 access list. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

None

**Example**

```
OS10(config)# ipv6 access-list acl6
```

**Supported Release**

10.2.0E or later

### ipv6 prefix-list deny

Creates a prefix list to deny route filtering from a specified IPv6 network address.

**Syntax**

```
ipv6 prefix-list prefix-list-name deny {A::B/x [ge | le] prefix-len}
```

**Parameters**

- `prefix-list-name`—Enter the IPv6 prefix list name.
- `A::B/x`—Enter the IPv6 address to deny.
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix list.

**Example**

```
OS10(config)# ipv6 prefix-list TEST deny AB10::1/128 ge 10 le 30
```

**Supported Release**

10.3.0E or later

### ipv6 prefix-list description

Configures a description of an IPv6 prefix-list.

**Syntax**

```
ipv6 prefix-list name description
```

**Parameters**

- `name`—Enter the name of the IPv6 prefix-list.
- `description`—Enter the description for the named prefix-list.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix list.

**Example**

```
OS10(config)# ipv6 prefix-list TEST description TEST_LIST
```

**Supported Release**

10.3.0E or later

### ipv6 prefix-list permit

Creates a prefix-list to permit route filtering from a specified IPv6 network address.

**Syntax**

```
ipv6 prefix-list prefix-list-name permit {A::B/x [ge | le] prefix-len}
```

**Parameters**

- `prefix-list-name`—Enter the IPv6 prefix-list name.
- `A::B/x`—Enter the IPv6 address to permit.
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix-list.

**Example**

```
OS10(config)# ipv6 prefix-list TEST permit AB20::1/128 ge 10 le 30
```

**Supported Release**

10.3.0E or later

### ipv6 prefix-list seq deny

Configures a filter to deny route filtering from a specified prefix-list.

**Syntax**

```
ipv6 prefix-list [name] seq num deny {A::B/x [ge | le] prefix-len}
```

**Parameters**

- `name`—(Optional) Enter the name of the IPv6 prefix-list.
- `num`—Enter the sequence number of the specified IPv6 prefix-list.
- `A::B/x`—Enter the IPv6 address and mask in /prefix format (/x).
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix-list.

**Example**

```
OS10(config)# ipv6 prefix-list TEST seq 65535 deny AB20::1/128 ge 10
```

**Supported Release**

10.3.0E or later

### ipv6 prefix-list seq permit

Configures a filter to permit route filtering from a specified prefix-list.

**Syntax**

```
ipv6 prefix-list [name] seq num permit A::B/x [ge | le} prefix-len
```

**Parameters**

- `name`—(Optional) Enter the name of the IPv6 prefix-list.
- `num`—Enter the sequence number of the specified IPv6 prefix list.
- `A::B/x`—Enter the IPv6 address and mask in /prefix format (/x).
- `ge`—Enter to indicate the network address is greater than or equal to the range specified.
- `le`—Enter to indicate the network address is less than or equal to the range specified.
- `prefix-len`—Enter the prefix length.

**Defaults**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command removes the specified prefix-list.

**Example**

```
OS10(config)# ipv6 prefix-list TEST seq 65535 permit AB10::1/128 ge 30
```

**Supported Release**

10.3.0E or later

### logging access-list mgmt burst

Configures the burst size for control-plane ACL applied on the management interface.

**Syntax**

```
[no] logging access-list mgmt burst value
```

**Parameters**

`value`—Specify the burst size (maximum tokens), from 1 to 10.

**Default**

2

**Command Mode**

CONTROL-PLANE

**Usage Information**

The no version of this command resets the value to the default.

**Example**

```
OS10(config)# control-plane
OS10(config-control-plane)# logging access-list mgmt burst 5
```

**Supported Releases**

10.5.2.1 or later

### logging access-list mgmt rate

Configures the logging rate of control-plane ACL applied on the management interface.

**Syntax**

```
[no] logging access-list mgmt rate value
```

**Parameters**

`value`—Specify the logging rate value, from 1 to 10.

**Default**

2

**Command Mode**

CONTROL-PLANE

**Usage Information**

The no version of this command resets the value to the default.

**Example**

```
OS10(config)# control-plane
OS10(config-control-plane)# logging access-list mgmt rate 5
```

**Supported Releases**

10.5.2.1 or later

### mac access-group

Configures a MAC access group.

**Syntax**

```
mac access-group access-list-name {in | out}
```

**Parameters**

- `access-list-name`—Enter the name of a MAC access list. A maximum of 140 characters.
- `in`—Apply the ACL to incoming traffic.
- `out`—Apply the ACL to outgoing traffic.

**Default**

Not configured

**Command Mode**

CONFIGURATION CONTROL-PLANE

**Usage Information**

Use this command in the CONTROL-PLANE mode to apply a control-plane ACL. Control-plane ACLs are only applied on the ingress traffic. By default, the control-plane ACL is applied to the front-panel ports. The no version of this command resets the value to the default.

**Example**

```
OS10(config)# mac access-group maclist in
OS10(conf-mac-acl)#
```

**Example (Control-plane ACL)**

```
OS10# configure terminal
OS10(config)# control-plane
OS10(config-control-plane)# mac access-group maclist in
```

**Supported Releases**

10.2.0E or later; 10.4.1 or later (control-plane ACL)

### mac access-list

Creates a MAC access list to filter based on a MAC address.

**Syntax**

```
mac access-list access-list-name
```

**Parameters**

`access-list-name`—Enter the name of a MAC access list. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

None

**Example**

```
OS10(config)# mac access-list maclist
```

**Supported Releases**

10.2.0E or later

### permit

Configures a filter to allow packets with a specific IPv4 address.

**Syntax**

```
permit [protocol-number | icmp | ip | tcp | udp] [A.B.C.D | A.B.C.D/x
| any | host ip-address] [A.B.C.D | A.B.C.D/x | any | host ip-address]
[capture | count | dscp value | fragment | log]
```

**Parameters**

- `protocol-number` — (Optional) Enter the protocol number identified in the IP header, from 0 to 255.
- `icmp` — (Optional) Enter the ICMP address to permit.
- `ip` — (Optional) Enter the IPv4 address to permit.
- `tcp` — (Optional) Enter the TCP address to permit.
- `udp` — (Optional) Enter the UDP address to permit.
- `A.B.C.D` — Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x` — Enter the number of bits that must match the dotted decimal address.
- `any` — (Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address` — (Optional) Enter the IPv4 address to use a host address only.
- `capture` — (Optional) Capture packets the filter processes.
- `count` — (Optional) Count packets the filter processes.
- `byte` — (Optional) Count bytes the filter processes.
- `dscp value` — (Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment` — (Optional) Use ACLs to control packet fragments.
- `log` — (Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# permit udp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit (IPv6)

Configures a filter to allow packets with a specific IPv6 address.

**Syntax**

```
permit [protocol-number | icmp | ipv6 | tcp | udp] [A::B | A::B/x | any
| host ipv6-address] [A::B | A:B/x | any | host ipv6-address] [capture |
count | dscp value | fragment | log]
```

**Parameters**

- `protocol-number`—(Optional) Enter the protocol number identified in the IPv6 header, from 0 to 255.
- `icmp`—(Optional) Enter the ICMP address to permit.
- `ipv6`—(Optional) Enter the IPv6 address to permit.
- `tcp`—(Optional) Enter the TCP address to permit.
- `udp`—(Optional) Enter the UDP address to permit.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# permit udp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit (MAC)

Configures a filter to allow packets with a specific MAC address.

**Syntax**

```
permit {nn:nn:nn:nn:nn:nn [00:00:00:00:00:00] | any} {nn:nn:nn:nn:nn:nn
[00:00:00:00:00:00] | any} [protocol-number | capture | count [byte] |
cos | vlan]
```

**Parameters**

- `nn:nn:nn:nn:nn:nn`—Enter the MAC address.
- `00:00:00:00:00:00`—(Optional) Enter which bits in the MAC address must match. If you do not enter a mask, a mask of 00:00:00:00:00:00 applies.
- `any`—(Optional) Set which routes are subject to the filter:
  - `protocol-number`—Enter the MAC protocol number identified in the MAC header, from 600 to ffff.
  - `capture`—(Optional) Enter the capture packets the filter processes.
  - `count`—(Optional) Enter the count packets the filter processes.
  - `byte`—(Optional) Enter the count bytes the filter processes.
  - `cos`—(Optional) Enter the CoS value, from 0 to 7.
  - `vlan`—(Optional) Enter the VLAN number, from 1 to 4093.

**Default**

Not configured

**Command Mode**

MAC-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# mac access-list macacl
OS10(conf-mac-acl)# permit 00:00:00:00:11:11 00:00:11:11:11:11 any cos 7
OS10(conf-mac-acl)# permit 00:00:00:00:11:11 00:00:11:11:11:11 any vlan 2
```

**Supported Releases**

10.2.0E or later

### permit icmp

Configures a filter to permit all or specific ICMP messages.

**Syntax**

```
permit icmp [A.B.C.D | A.B.C.D/x | any | host ip-address] [[A.B.C.D |
A.B.C.D/x | any | host ip-address] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# permit icmp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit icmp (IPv6)

Configures a filter to permit all or specific ICMP messages.

**Syntax**

```
permit icmp [A::B | A::B/x | any | host ipv6-address] [A::B | A:B/x | any
| host ipv6-address] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# permit icmp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit ip

Configures a filter to permit all or specific packets from an IPv4 address.

**Syntax**

```
permit ip [A.B.C.D | A.B.C.D/x | any | host ip-address] [[A.B.C.D |
A.B.C.D/x | any | host ip-address] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits to match to the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragments`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(conf-ipv4-acl)# permit ip any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit ipv6

Configures a filter to permit all or specific packets from an IPv6 address.

**Syntax**

```
permit ipv6 [A::B | A::B/x | any | host ipv6-address] [A::B | A:B/x | any
| host ipv6-address] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A::B`—(Optional) Enter the source IPv6 address from which the packet was sent and the destination address.
- `A::B/x`—(Optional) Enter the source network mask in /prefix format (/x) and the destination mask.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6–address`—Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Enter to capture packets the filter processes.
- `count`—(Optional) Enter to count packets the filter processes.
- `byte`—(Optional) Enter to count bytes the filter processes.
- `dscp value`—(Optional) Enter to deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Enter to use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(conf-ipv6-acl)# permit ipv6 any any count capture session 1
```

**Supported Releases**

10.2.0E or later

### permit tcp

Configures a filter to permit TCP packets meeting the filter criteria.

**Syntax**

```
permit tcp [A.B.C.D | A.B.C.D/x | any | host ip-address [operator]]
[[A.B.C.D | A.B.C.D/x | any | host ip-address [operator] ] [ack | fin
| psh | rst | syn | urg] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
  > **NOTE:** The control-plane ACLs do not support the any parameter.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.
  > **NOTE:** The control-plane ACLs support only the eq operator.

**Default**

Not configured

**Command Mode**

IPV4–ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(conf-ipv4-acl)# permit tcp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit tcp (IPv6)

Configures a filter to permit TCP packets meeting the filter criteria.

**Syntax**

```
permit tcp [A::B | A::B/x | any | host ipv6-address [eq | lt | gt | neq
| range]] [A::B | A:B/x | any | host ipv6-address [eq | lt | gt | neq |
range]] [ack | fin | psh | rst | syn | urg] [capture | count | dscp value
| fragment | log]
```

**Parameters**

- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
  > **NOTE:** The control-plane ACLs do not support the any parameter.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# permit tcp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit udp

Configures a filter that allows UDP packets meeting the filter criteria.

**Syntax**

```
permit udp [A.B.C.D | A.B.C.D/x | any | host ip-address [eq | lt | gt |
neq | range]] [[A.B.C.D | A.B.C.D/x | any | host ip-address [eq | lt | gt
| neq | range] ] [ack | fin | psh | rst | syn | urg] [capture | count |
dscp value | fragment | log]
```

**Parameters**

- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count bytes filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—(Optional) Permit packets which are equal to.
  - `lt`—(Optional) Permit packets which are less than.
  - `gt`—(Optional) Permit packets which are greater than.
  - `neq`—(Optional) Permit packets which are not equal to.
  - `range`—(Optional) Permit packets with a specific source and destination address.
  > **NOTE:** The control-plane ACL supports only the eq operator.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# permit udp any any capture session 1
```

**Supported Releases**

10.2.0E or later

### permit udp (IPv6)

Configures a filter to permit UDP packets meeting the filter criteria.

**Syntax**

```
permit udp [A::B | A::B/x | any | host ipv6-address [operator]] [A::B |
A:B/x | any | host ipv6-address [operator]] [ack | fin | psh | rst | syn
| urg] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
  > **NOTE:** The control-plane ACL supports only the eq operator.
- `host ipv6-address`—(Optional) Enter the keyword and the IPv6 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter.

**Example**

```
OS10(conf-ipv6-acl)# permit udp any any capture session 1 count
```

**Supported Releases**

10.2.0E or later

### remark

Specifies an ACL entry description.

**Syntax**

```
remark description
```

**Parameters**

`description`—Enter a description. A maximum of 80 characters.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

Configure up to 16,777,214 remarks for a given IPv4, IPv6, or MAC. The no version of the command removes the ACL entry description.

**Supported Releases**

10.2.0E or later

### resequence access-list

Reassign sequence numbers to entries of an existing access-list.

**Syntax**

```
resequence access-list {ipv4 | ipv6 | mac} {access-list-name
StartingSeqNum Step-to-Increment}
```

**Parameters**

- `ipv4 | ipv6 | mac`—Enter a keyword to identify the access list type to resequence.
- `access-list-name`—Enter the name of a configured IP access list.
- `StartingSeqNum`—Enter the starting sequence number to resequence. The range is from 1 to 16777214.
- `Step-to-Increment`—Enter the step to increment the sequence number. The range is from 1 to 16777214.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

The no form of this command is not supported.

**Example**

```
OS10# resequence access-list mac test 2 4
```

**Supported Releases**

10.6.1.0 or later

### seq deny

Assigns a sequence number to deny IPv4 addresses while creating the filter.

**Syntax**

```
seq sequence-number deny [protocol-number | icmp | ip | tcp | udp]
[A.B.C.D | A.B.C.D/x | any | host ip-address] [A.B.C.D | A.B.C.D/x | any
| host ip-address] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the ACL for editing and sequencing number, from 1 to 16777214.
- `protocol-number`—(Optional) Enter the protocol number, from 0 to 255.
- `icmp`—(Optional) Enter the ICMP address to deny.
- `ip`—(Optional) Enter the IPv4 address to deny.
- `tcp`—(Optional) Enter the TCP address to deny.
- `udp`—(Optional) Enter the UDP address to deny.
- `A.B.C.D`—(Optional) Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—(Optional) Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# seq 10 deny tcp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny (IPv6)

Assigns a sequence number to deny IPv6 addresses while creating the filter.

**Syntax**

```
seq sequence-number deny [protocol-number icmp | ip | tcp | udp] [A::B
| A::B/x | any | host ipv6-address] [A::B | A::B/x | any | host ipv6-
address] [capture | count | dscp value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `protocol-number`—(Optional) Enter the protocol number, from 0 to 255.
- `icmp`—(Optional) Enter the ICMP address to deny.
- `ip`—(Optional) Enter the IPv6 address to deny.
- `tcp`—(Optional) Enter the TCP address to deny.
- `udp`—(Optional) Enter the UDP address to deny.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter to use an IPv6 host address only.
- `capture`—(Optional) Enter to capture packets the filter processes.
- `count`—(Optional) Enter to count packets the filter processes.
- `byte`—(Optional) Enter to count bytes the filter processes.
- `dscp value`—(Optional) Enter to deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Enter to use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# seq 5 deny ipv6 any any capture session 1 count log
```

**Supported Releases**

10.2.0E or later

### seq deny (MAC)

Assigns a sequence number to a deny filter in a MAC access list while creating the filter.

**Syntax**

```
seq sequence-number deny {nn:nn:nn:nn:nn:nn [00:00:00:00:00:00] | any}
{nn:nn:nn:nn:nn:nn [00:00:00:00:00:00] | any} [protocol-number | capture
| cos | count [byte] | vlan]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `nn:nn:nn:nn:nn:nn`—Enter the source MAC address.
- `00:00:00:00:00:00`—(Optional) Enter which bits in the MAC address must match. If you do not enter a mask, a mask of 00:00:00:00:00:00 applies.
- `any`—(Optional) Set all routes which are subject to the filter:
  - `protocol-number`—Protocol number identified in the MAC header, from 600 to ffff.
  - `capture`—(Optional) Capture packets the filter processes.
  - `cos`—(Optional) CoS value, from 0 to 7.
  - `count`—(Optional) Count packets the filter processes.
  - `byte`—(Optional) Count the bytes the filter processes.
  - `vlan`—(Optional) VLAN number, from 1 to 4093.

**Default**

Not configured

**Command Mode**

CONFIG-MAC-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter's sequence number.

**Example**

```
OS10(config)# mac access-list macacl
OS10(conf-mac-acl)# seq 10 deny 00:00:00:00:11:11 00:00:11:11:11:11 any cos 7
OS10(conf-mac-acl)# seq 20 deny 00:00:00:00:11:11 00:00:11:11:11:11 any vlan 2
```

**Supported Releases**

10.2.0E or later

### seq deny icmp

Assigns a filter to deny ICMP messages while creating the filter.

**Syntax**

```
seq sequence-number deny icmp [A.B.C.D | A.B.C.D/x | any | host ip-
address] [A.B.C.D | A.B.C.D/x | any | host ip-address] [capture | count |
dscp value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host IP address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 5 deny icmp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny icmp (IPv6)

Assigns a sequence number to deny ICMP messages while creating the filter.

**Syntax**

```
seq sequence-number deny icmp [A::B | A::B/x | any | host ipv6-address]
[A::B | A::B/x | any | host ipv6-address] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# seq 10 deny icmp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny ip

Assigns a sequence number to deny IPv4 addresses while creating the filter.

**Syntax**

```
seq sequence-number deny ip [A.B.C.D | A.B.C.D/x | any | host ip-address]
[A.B.C.D | A.B.C.D/x | any | host ip-address] [capture | count | dscp
value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(config-ipv4-acl)# seq 10 deny ip any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny ipv6

Assigns a filter to deny IPv6 addresses while creating the filter.

**Syntax**

```
seq sequence-number deny ip [A::B | A::B/x | any | host ipv6-address]
[A::B | A:B/x | any | host ipv6-address] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination address.
- `host ip-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# seq 10 deny ipv6 any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny tcp

Assigns a filter to deny TCP packets while creating the filter.

**Syntax**

```
seq sequence-number deny tcp [A.B.C.D | A.B.C.D/x | any | host ip-address
[operator]] [[A.B.C.D | A.B.C.D/x | any | host ip-address [operator] ]
[ack | fin | psh | rst | syn | urg] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 10 deny tcp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny tcp (IPv6)

Assigns a filter to deny TCP packets while creating the filter.

**Syntax**

```
seq sequence-number deny tcp [A::B | A::B/x | any | host ipv6-address
[operator]] [A::B | A:B/x | any | host ipv6-address [operator]] [ack |
fin | psh | rst | syn | urg] [capture | count | dscp value | fragment |
log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv6 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter's sequence number.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# seq 10 deny tcp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny udp

Assigns a filter to deny UDP packets while creating the filter.

**Syntax**

```
seq sequence-number deny udp [A.B.C.D | A.B.C.D/x | any | host ip-address
[operator]] [[A.B.C.D | A.B.C.D/x | any | host ip-address [operator] ]
[ack | fin | psh | rst | syn | urg] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 10 deny udp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq deny udp (IPv6)

Assigns a filter to deny UDP packets while creating the filter.

**Syntax**

```
seq sequence-number deny udp [A::B | A::B/x | any | host ipv6-address
[operator]] [A::B | A:B/x | any | host ipv6-address [operator]] [ack |
fin | psh | rst | syn | urg] [capture | count | dscp value | fragment |
log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# seq 10 deny udp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit

Assigns a sequence number to permit packets while creating the filter.

**Syntax**

```
seq sequence-number permit [protocol-number A.B.C.D | A.B.C.D/x | any |
host ip-address] [A.B.C.D | A.B.C.D/x | any | host ip-address] [capture |
count | dscp value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `protocol-number`—(Optional) Enter the protocol number, from 0 to 255.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list testflow
OS10(conf-ipv4-acl)# seq 10 permit ip any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit (IPv6)

Assigns a sequence number to permit IPv6 packets, while creating a filter.

**Syntax**

```
seq sequence-number permit protocol-number [A::B | A::B/x | any | host
ipv6-address] [A::B | A:B/x | any | host ipv6-address] [capture | count |
dscp value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `protocol-number`—(Optional) Enter the protocol number, from 0 to 255.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to be used as the host address.
- `capture`—(Optional) Enter to capture packets the filter processes.
- `count`—(Optional) Enter to count packets the filter processes.
- `byte`—(Optional) Enter to count bytes the filter processes.
- `dscp value`—(Optional) Enter the DSCP value to permit a packet, from 0 to 63.
- `fragment`—(Optional) Enter to use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# seq 10 permit ipv6 any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit (MAC)

Assigns a sequence number to permit MAC addresses while creating a filter.

**Syntax**

```
seq sequence-number permit {nn:nn:nn:nn:nn:nn [00:00:00:00:00:00] | any}
{nn:nn:nn:nn:nn:nn [00:00:00:00:00:00] | any} [protocol-number | capture
| cos | count [byte] | vlan]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing, from 1 to 16777214.
- `nn:nn:nn:nn:nn:nn`—Enter the MAC address of the network from or to which the packets were sent.
- `00:00:00:00:00:00`—(Optional) Enter which bits in the MAC address must match. If you do not enter a mask, a mask of 00:00:00:00:00:00 applies.
- `any`—(Optional) Set all routes to be subject to the filter:
  - `protocol-number`—(Optional) Enter the protocol number identified in the MAC header, from 600 to ffff.
  - `capture`—(Optional) Enter the capture packets the filter processes.
  - `cos`—(Optional) Enter the CoS value, from 0 to 7.
  - `count`—(Optional) Enter the count packets the filter processes.
  - `byte`—(Optional) Enter the count bytes the filter processes.
  - `vlan`—(Optional) Enter the VLAN number, from 1 to 4093.

**Default**

Not configured

**Command Mode**

MAC-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# mac access-list macacl
OS10(conf-mac-acl)# seq 10 permit 00:00:00:00:11:11 00:00:11:11:11:11 any cos 7
OS10(conf-mac-acl)# seq 20 permit 00:00:00:00:11:11 00:00:11:11:11:11 any vlan 2
```

**Supported Releases**

10.2.0E or later

### seq permit icmp

Assigns a sequence number to allow ICMP messages while creating the filter

**Syntax**

```
seq sequence-number permit icmp [A.B.C.D | A.B.C.D/x | any | host ip-
address] [A.B.C.D | A.B.C.D/x | any | host ip-address] [capture | count |
dscp value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule are logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter's sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 5 permit icmp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit icmp (IPv6)

Assigns a sequence number to allow ICMP messages while creating the filter.

**Syntax**

```
seq sequence-number permit icmp [A::B | A::B/x | any | host ipv6-address]
[A::B | A:B/x | any | host ipv6-address] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list ipv6test
OS10(conf-ipv6-acl)# seq 5 permit icmp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit ip

Assigns a sequence number to allow packets while creating the filter.

**Syntax**

```
seq sequence-number permit ip [A.B.C.D | A.B.C.D/x | any | host ip-
address] [A.B.C.D | A.B.C.D/x | any | host ip-address] [capture | count |
dscp value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 5 permit ip any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit ipv6

Assigns a sequence number to allow packets while creating the filter.

**Syntax**

```
seq sequence-number permit ipv6 [A::B | A::B/x | any | host ipv6-address]
[A::B | A:B/x | any | host ipv6-address] [capture | count | dscp value |
fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list egress
OS10(conf-ipv6-acl)# seq 5 permit ipv6 any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit tcp

Assigns a sequence number to allow TCP packets while creating the filter.

**Syntax**

```
seq sequence-number permit tcp [A.B.C.D | A.B.C.D/x | any | host ip-
address [operator]] [[A.B.C.D | A.B.C.D/x | any | host ip-address
[operator] ] [ack | fin | psh | rst | syn | urg] [capture | count | dscp
value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 5 permit tcp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit tcp (IPv6)

Assigns a sequence number to allow TCP IPv6 packets while creating the filter.

**Syntax**

```
seq sequence-number permit tcp [A::B | A::B/x | any | host ipv6-address
[operator]] [A::B | A:B/x | any | host ipv6-address [operator]] [ack |
fin | psh | rst | syn | urg] [capture | count | dscp value | fragment |
log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list egress
OS10(conf-ipv6-acl)# seq 5 permit tcp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit udp

Assigns a sequence number to allow UDP packets while creating the filter.

**Syntax**

```
seq sequence-number permit udp [A.B.C.D | A.B.C.D/x | any | host ip-
address [operator]] [[A.B.C.D | A.B.C.D/x | any | host ip-address
[operator] ] [ack | fin | psh | rst | syn | urg] [capture | count | dscp
value | fragment | log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A.B.C.D`—Enter the IPv4 address in dotted decimal format.
- `A.B.C.D/x`—Enter the number of bits that must match the dotted decimal address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ip-address`—(Optional) Enter the IPv4 address to use a host address only.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Deny a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV4-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ip access-list egress
OS10(conf-ipv4-acl)# seq 5 permit udp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### seq permit udp (IPv6)

Assigns a sequence number to allow UDP IPv6 packets while creating a filter.

**Syntax**

```
seq sequence-number permit udp [A::B | A::B/x | any | host ipv6-address
[operator]] [A::B | A:B/x | any | host ipv6-address [operator]] [ack |
fin | psh | rst | syn | urg] [capture | count | dscp value | fragment |
log]
```

**Parameters**

- `sequence-number`—Enter the sequence number to identify the route-map for editing and sequencing number, from 1 to 16777214.
- `A::B`—Enter the IPv6 address in hexadecimal format separated by colons.
- `A::B/x`—Enter the number of bits that must match the IPv6 address.
- `any`—(Optional) Enter the keyword any to specify any source or destination IP address.
- `host ipv6-address`—(Optional) Enter the IPv6 address to use a host address only.
- `operator`—(Optional) Enter a logical operator to match the packets on the specified port number. The following options are available:
  - `eq`—Equal to
  - `gt`—Greater than
  - `lt`—Lesser than
  - `neq`—Not equal to
  - `range`—Range of ports, including the specified port numbers.
- `ack`—(Optional) Set the bit as acknowledgment.
- `fin`—(Optional) Set the bit as finish—no more data from sender.
- `psh`—(Optional) Set the bit as push.
- `rst`—(Optional) Set the bit as reset.
- `syn`—(Optional) Set the bit as synchronize.
- `urg`—(Optional) Set the bit set as urgent.
- `capture`—(Optional) Capture packets the filter processes.
- `count`—(Optional) Count packets the filter processes.
- `byte`—(Optional) Count the bytes the filter processes.
- `dscp value`—(Optional) Permit a packet based on the DSCP values, from 0 to 63.
- `fragment`—(Optional) Use ACLs to control packet fragments.
- `log`—(Optional) Enables ACL logging. Information about packets that match an ACL rule is logged.

**Default**

Not configured

**Command Mode**

IPV6-ACL

**Usage Information**

OS10 cannot count both packets and bytes; when you enter the count byte options, only bytes increment. The no version of this command removes the filter, or use the `no seq sequence-number` command if you know the filter sequence number.

**Example**

```
OS10(config)# ipv6 access-list egress
OS10(conf-ipv6-acl)# seq 5 permit udp any any capture session 1 log
```

**Supported Releases**

10.2.0E or later

### show access-group

Displays IP, MAC, or IPv6 access-group information.

**Syntax**

```
show {ip | mac | ipv6} access-group name
```

**Parameters**

- `ip`—View IP access group information.
- `mac`—View MAC access group information.
- `ipv6`—View IPv6 access group information.
- `access-group name`—Enter the name of the access group.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

None

**Example (IP)**

```
OS10# show ip access-group aaa
Ingress IP access list aaa on ethernet1/1/1
Ingress IP access list aaa on ethernet1/1/2
Egress IP access list aaa on ethernet1/1/2
```

**Example (MAC)**

```
OS10# show mac access-group bbb
Ingress MAC access list aaa on ethernet1/1/1
Ingress MAC access list aaa on ethernet1/1/2
Egress MAC access list aaa on ethernet1/1/2
```

**Example (IPv6)**

```
OS10# show ipv6 access-group ccc
Ingress IPV6 access list aaa on ethernet1/1/1
Ingress IPV6 access list aaa on ethernet1/1/2
Egress IPV6 access list aaa on ethernet1/1/2
```

**Example (Control-plane ACL - IP)**

```
OS10# show ip access-group aaa-cp-acl
Ingress IP access-list aaa-cp-acl on control-plane data mgmt
```

**Example (Control-plane ACL - MAC)**

```
OS10# show mac access-group aaa-cp-acl
Ingress MAC access-list aaa-cp-acl on control-plane data
```

**Example (Control-plane ACL - IPv6)**

```
OS10# show ipv6 access-group aaa-cp-acl
Ingress IPV6 access-list aaa-cp-acl on control-plane data mgmt
```

**Supported Releases**

10.2.0E or later; 10.4.1 or later (control-plane ACL)

### show access-lists

Displays IP, MAC, or IPv6 access-list information.

**Syntax**

```
show {ip | mac | ipv6} access-lists {in | out} access-list-name
```

**Parameters**

- `ip`—View IP access list information.
- `mac`—View MAC access list information.
- `ipv6`—View IPv6 access list information.
- `access-lists in | out`—Enter either access lists in or access lists out.
- `access-list—name`—Enter the name of the access-list.

**Default**

Not configured

**Command Mode**

EXEC

**Usage Information**

This command does not display counter metrics for security ACLs on the S5448F-ON, Z9432F-ON, and Z9664F-ON platforms due to firmware limitations.

**Example (MAC In)**

```
OS10# show mac access-lists in
Ingress MAC access list aaa
Active on interfaces :
  ethernet1/1/1
  ethernet1/1/2
 seq 10 permit any any
 seq 20 permit 11:11:11:11:11:11 22:22:22:22:22:22 any monitor count bytes (0 bytes)
```

**Example (MAC Out)**

```
OS10# show mac access-lists out
Egress MAC access list aaa
 Active on interfaces :
  ethernet1/1/1
  ethernet1/1/2
 seq 10 permit any any
 seq 20 permit 11:11:11:11:11:11 22:22:22:22:22:22 any monitor count bytes (0 bytes)
```

**Example (IP In)**

```
OS10# show ip access-lists in
Ingress IP access list aaaa
 Active on interfaces :
  ethernet1/1/1
  ethernet1/1/2
 seq 10 permit ip any any log
 seq 20 permit tcp any any count (0 packets)
 seq 30 permit udp any any count bytes (0 bytes)
```

**Example (IP Out)**

```
OS10# show ip access-lists out
Egress IP access list aaaa
 Active on interfaces :
  ethernet1/1/1
  ethernet1/1/2
 seq 10 permit ip any any
 seq 20 permit tcp any any count (0 packets)
 seq 30 permit udp any any count bytes (0 bytes)
```

**Example (IPv6 In)**

```
OS10# show ipv6 access-lists in
Ingress IPV6 access list bbb
 Active on interfaces :
  ethernet1/1/1
  ethernet1/1/2
 seq 10 permit any any
Ingress IPV6 access list ggg
 Active on interfaces :
  ethernet 1/1/3
 seq 5 permit ipv6 11::/32 any log count (0 packets)
```

**Example (IPv6 Out)**

```
OS10# show ipv6 access-lists out
Egress IPV6 access list bbb
 Active on interfaces :
  ethernet1/1/1
  ethernet1/1/2
 seq 10 permit any any
Egress IPV6 access list ggg
 Active on interfaces :
  ethernet 1/1/1
 seq 5 permit ipv6 11::/32 any count (0 packets)
```

**Example (IP In - Control-plane ACL)**

```
OS10# show ip access-lists in
Ingress IP access-list aaa-cp-acl
 Active on interfaces :
  control-plane data
 seq 10 permit ip any any
  control-plane mgmt
 seq 10 permit ip any any
```

**Example (IPv6 In - Control-plane ACL)**

```
OS10# show ipv6 access-lists in
Ingress IPV6 access-list aaa-cp-acl
 Active on interfaces :
  control-plane data
 seq 10 permit ipv6 any any
  control-plane mgmt
 seq 10 permit ipv6 any any
```

**Example (MAC In - Control-plane ACL)**

```
OS10# show mac access-lists in
Ingress MAC access-list mac-cp1
 Active on interfaces :
control-plane data
 seq 10 deny any any count (159 packets)
```

**Supported Releases**

10.2.0E or later; 10.4.1 or later (control-plane ACL)

### show acl-table-usage detail

Displays the ingress and egress ACL tables, the features that are used, and their space utilizations.

**Syntax**

```
show acl-table-usage detail
```

**Parameters**

None

**Default**

None

**Command Mode**

EXEC

**Usage Information**

The hardware pool displays the ingress application groups (pools), the features mapped to each of these groups, and the amount of used and free space available in each of the pools. The amount of space required to store a single ACL rule in a pool depends on the keywidth of the TCAM slice. The service pool displays the amount of used and free space for each of the features. The number of ACL rules that are configured for a feature is displayed in the configured rules column. The number of used rows depends on the number of ports the configured rules are applied on.

**Examples (Z9100-ON platform)**

```
OS10# show acl-table-usage detail
Ingress ACL utilization - Pipe 0
Hardware Pools
-----------------------------------------------------------------
Pool ID     App(s)            Used rows    Free rows    Max rows
-----------------------------------------------------------------
0         SYSTEM_FLOW          98           414          512
1         SYSTEM_FLOW          98           414          512
2         SYSTEM_FLOW          98           414          512
3         USER_IPV4_ACL        4            508          512
4         USER_IPV4_ACL        4            508          512
5         FREE                 0            512          512
6         USER_IPV6_ACL        4            508          512
7         USER_IPV6_ACL        4            508          512
8         USER_IPV6_ACL        4            508          512
9         USER_L2_ACL          4            508          512
10        USER_L2_ACL          4            508          512
11        FREE                 0            512          512
-----------------------------------------------------------------
Service Pools
---------------------------------------------------------------
App       Allocated pools App group Configured  Used Free Max
                                    rules       rows rows rows
---------------------------------------------------------------
USER_L2_ACL   Shared:2    G9        1            2   254  256
USER_IPV4_ACL Shared:2    G3        1            2   254  256
USER_IPV6_ACL Shared:3    G6        1            2   254  256
SYSTEM_FLOW   Shared:3    G0        49           49  207  256
---------------------------------------------------------------
Ingress ACL utilization - Pipe 1
Hardware Pools
---------------------------------------------------------
Pool ID   App(s)          Used rows  Free rows  Max rows
---------------------------------------------------------
0       SYSTEM_FLOW        98         414        512
1       SYSTEM_FLOW        98         414        512
2       SYSTEM_FLOW        98         414        512
3       USER_IPV4_ACL      0          512        512
4       USER_IPV4_ACL      0          512        512
5       FREE               0          512        512
6       USER_IPV6_ACL      0          512        512
7       USER_IPV6_ACL      0          512        512
8       USER_IPV6_ACL      0          512        512
9       USER_L2_ACL        0          512        512
10      USER_L2_ACL        0          512        512
11      FREE               0          512        512
---------------------------------------------------------
Service Pools
---------------------------------------------------------------
App       Allocated pools App group Configured  Used Free Max
                                    rules       rows rows rows
---------------------------------------------------------------
SYSTEM_FLOW  Shared:3        G0      49         49   207  256
---------------------------------------------------------------
Ingress ACL utilization - Pipe 2
Hardware Pools
---------------------------------------------------------
Pool ID   App(s)        Used rows  Free rows    Max rows
---------------------------------------------------------
0       SYSTEM_FLOW      98         414          512
1       SYSTEM_FLOW      98         414          512
2       SYSTEM_FLOW      98         414          512
3       USER_IPV4_ACL    0          512          512
4       USER_IPV4_ACL    0          512          512
5       FREE             0          512          512
6       USER_IPV6_ACL    0          512          512
7       USER_IPV6_ACL    0          512          512
8       USER_IPV6_ACL    0          512          512
9       USER_L2_ACL      0          512          512
10      USER_L2_ACL      0          512          512
11      FREE             0          512          512
---------------------------------------------------------
Service Pools
---------------------------------------------------------------
App       Allocated pools App group Configured  Used Free Max
                                    rules       rows rows rows
---------------------------------------------------------------
SYSTEM_FLOW  Shared:3        G0      49         49   207  256
---------------------------------------------------------------
Ingress ACL utilization - Pipe 3
Hardware Pools
----------------------------------------------------------
Pool ID     App(s)         Used rows  Free rows  Max rows
----------------------------------------------------------
0         SYSTEM_FLOW        98         414        512
1         SYSTEM_FLOW        98         414        512
2         SYSTEM_FLOW        98         414        512
3         USER_IPV4_ACL      0          512        512
4         USER_IPV4_ACL      0          512        512
5         FREE               0          512        512
6         USER_IPV6_ACL      0          512        512
7         USER_IPV6_ACL      0          512        512
8         USER_IPV6_ACL      0          512        512
9         USER_L2_ACL        0          512        512
10        USER_L2_ACL        0          512        512
11        FREE               0          512        512
----------------------------------------------------------
Service Pools
---------------------------------------------------------------
App       Allocated pools App group Configured  Used Free Max
                                    rules       rows rows rows
---------------------------------------------------------------
SYSTEM_FLOW  Shared:3        G0      49         49   207  256
---------------------------------------------------------------
Egress ACL utilization
Hardware Pools
-------------------------------------------------
Pool ID   App(s)  Used rows  Free rows  Max rows
-------------------------------------------------
0         FREE     0          256        256
1         FREE     0          256        256
2         FREE     0          256        256
3         FREE     0          256        256
-------------------------------------------------
Service Pools
---------------------------------------------------------------
App       Allocated pools App group Configured  Used Free Max
                                    rules       rows rows rows
---------------------------------------------------------------
---------------------------------------------------------------
```

**Supported Releases**

10.4.2.0 or later

### show control-plane logging

Displays the configured burst size and logging rate for control-plane management ACL.

**Syntax**

```
show control-plane logging access-list mgmt
```

**Parameters**

None

**Default**

None

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
OS10# show control-plane logging access-list mgmt
Control plane Management ACL Logging
Burst : 2 packets (default)
Rate  : 2 packets per minute (default)
```

**Supported Releases**

10.5.2.1 or later

### show ip as-path-access-list

Displays the configured AS path access lists.

**Syntax**

```
show ip as-path-access-list [name]
```

**Parameters**

`name`—(Optional) Specify the name of the AS path access list.

**Defaults**

None

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
OS10# show ip as-path-access-list
ip as-path access-list hello
        permit 123
        deny 35
```

**Supported Releases**

10.3.0E or later

### show ip prefix-list

Displays configured IPv4 or IPv6 prefix list information.

**Syntax**

```
show {ip | ipv6} prefix-list [prefix-name]
```

**Parameters**

- `ip | ipv6`—(Optional) Displays information that is related to IPv4 or IPv6.
- `prefix-name`—Enter a text string for the prefix list name. A maximum of 140 characters.

**Defaults**

None

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
OS10# show ip prefix-list
ip prefix-list hello:
seq 10 deny 1.2.3.4/24
seq 20 permit 3.4.4.5/32
```

**Example (IPv6)**

```
OS10# show ipv6 prefix-list
ipv6 prefix-list hello:
seq 10 permit 1::1/64
seq 20 deny 2::2/64
```

**Supported Releases**

10.3.0E or later

### show logging access-list

Displays the ACL logging threshold and interval configuration.

**Syntax**

```
show logging access-list
```

**Parameters**

None

**Default**

None

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
OS10# show logging access-list
ACL Logging
Threshold     :   10
Interval      :   5
```

**Supported Releases**

10.4.3.0 or later

## Route-map commands

### continue

Configures the next sequence of the route map.

**Syntax**

```
continue seq-number
```

**Parameters**

`seq-number` — Enter the next sequence number, from 1 to 65535.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes a match.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# continue 65535
```

**Supported Releases**

10.3.0E or later

### match as-path

Configures a filter to match routes that have a certain AS path in their BGP paths.

**Syntax**

```
match as-path as-path-name
```

**Parameters**

`as-path-name`—Enter the name of an established AS-PATH ACL. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes a match AS path filter.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match as-path pathtest1
```

**Supported Releases**

10.3.0E or later

### match community

Configures a filter to match routes that have a certain COMMUNITY attribute in their BGP path.

**Syntax**

```
match community community-list-name [exact-match]
```

**Parameters**

- `community-list-name`—Enter the name of a configured community list.
- `exact-match`—(Optional) Select only those routes with the specified community list name.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the community match filter.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match community commlist1 exact-match
```

**Supported Releases**

10.3.0E or later

### match extcommunity

Configures a filter to match routes that have a certain EXTCOMMUNITY attribute in their BGP path.

**Syntax**

```
match extcommunity extcommunity-list-name [exact-match]
```

**Parameters**

- `extcommunity-list-name`—Enter the name of a configured extcommunity list.
- `exact-match`—(Optional) Select only those routes with the specified extcommunity list name.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the extcommunity match filter.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match extcommunity extcommlist1 exact-match
```

**Supported Releases**

10.3.0E or later

### match inactive-path-additive

Configures a filter to include inactive route paths when used with the redistribute or advertise commands.

**Syntax**

```
match inactive-path-additive
```

**Parameters**

None

**Default**

None

**Command Mode**

ROUTE-MAP

**Usage Information**

You can use this command in ROUTE-MAP configuration mode in addition to the other match rules. The no version of this command deletes the match filter.

**Example**

```
OS10# configure terminal
OS10(config)# route-map redis-inactive-routes
OS10(config-route-map)# match inactive-path-additive
```

**Supported Releases**

10.5.2.0 or later

### match interface

Configures a filter to match routes whose next-hop is the configured interface.

**Syntax**

```
match interface interface
```

**Parameters**

`interface` — Interface type:

- `ethernet node/slot/port[:subport]` — Enter the Ethernet interface information as the next-hop interface.
- `port-channel id-number`—Enter the LAG number as the next-hop interface, from 1 to 999 or 1001 to 2000.
- `vlan vlan-id`—Enter the VLAN number as the next-hop interface, from 1 to 4093.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(conf-route-map)# match interface ethernet 1/1/1
OS10(conf-if-eth1/1/1)#
```

**Supported Releases**

10.2.0E or later

### match ip address

Configures a filter to match routes based on IP addresses specified in IP prefix lists.

**Syntax**

```
match ip address {prefix-list prefix-list-name | access-list-name}
```

**Parameters**

- `prefix-list-name`—Enter the name of the configured prefix list. A maximum of 140 characters.
- `access-list-name`—Enter the name of the configured access list.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes a match.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match ip address  prefix-list test10
```

**Supported Releases**

10.3.0E or later

### match ip next-hop

Configures a filter to match based on the next-hop IP addresses specified in IP prefix lists.

**Syntax**

```
match ip next-hop prefix-list prefix-list
```

**Parameters**

`prefix-list`—Enter the name of the configured prefix list. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match ip next-hop  prefix-list test100
```

**Supported Releases**

10.3.0E or later

### match ipv6 address

Configures a filter to match routes based on IPv6 addresses specified in IP prefix lists.

**Syntax**

```
match ipv6 address {prefix-list prefix-list | access-list}
```

**Parameters**

- `prefix-list`—Enter the name of the configured prefix list. A maximum of 140 characters.
- `access-list`—Enter the name of the access group or list.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match ipv6 address test100
```

**Supported Releases**

10.3.0E or later

### match ipv6 next-hop

Configures a filter to match based on the next-hop IPv6 addresses specified in IP prefix lists.

**Syntax**

```
match ipv6 next-hop prefix-list prefix-list
```

**Parameters**

`prefix-list`—Enter the name of the configured prefix list. A maximum of 140 characters.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match ipv6 next-hop  prefix-list test100
```

**Supported Releases**

10.3.0E or later

### match metric

Configures a filter to match on a specific value.

**Syntax**

```
match metric metric-value
```

**Parameters**

`metric-value`—Enter a value to match the route metric against, from 0 to 4294967295.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(conf-route-map)# match metric 429132
```

**Supported Releases**

10.2.0E or later

### match origin

Configures a filter to match routes based on the origin attribute of BGP.

**Syntax**

```
match origin {egp | igp | incomplete}
```

**Parameters**

- `egp`—Match only remote EGP routes.
- `igp`—Match only on local IGP routes.
- `incomplete`—Match on unknown routes that are learned through some other means.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match origin egp
```

**Supported Releases**

10.3.0E or later

### match route-type

Configures a filter to match routes based on how the route is defined.

**Syntax**

```
match route-type {external {type-1 | type-2} | internal | local}
```

**Parameters**

- `external`—Match only on external OSPF routes. Enter the keyword then one of the following:
  - `type–1`—Match only on OSPF Type 1 routes.
  - `type–2`—Match only on OSPF Type 2 routes.
- `internal`—Match only on routes that are generated within OSPF areas.
- `local`—Match only on routes that are generated locally.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# match route-type external type-1
```

**Supported Releases**

10.3.0E or later

### match tag

Configures a filter to redistribute only routes that match a specific tag value.

**Syntax**

```
match tag tag-value
```

**Parameters**

`tag-value`—Enter the tag value to match with the tag number, from 0 to 4294967295.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the match.

**Example**

```
OS10(conf-route-map)# match tag 656442
```

**Supported Releases**

10.2.0E or later

### route-map

Enables a route-map statement and configures its action and sequence number.

**Syntax**

```
route-map map-name [permit | deny | sequence-number]
```

**Parameters**

- `map-name` — Enter the name of the route-map. A maximum of 140 characters.
- `sequence-number` — (Optional) Enter the number to identify the route-map for editing and sequencing number from 1 to 65535. The default is 10.
- `permit` — (Optional) Set the route-map default as permit.
- `deny` — (Optional) Set the route default as deny.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

> **NOTE:** Exercise caution when you delete route-maps — if you do not enter a sequence number, all route-maps with the same map-name are deleted.

The no version of this command removes a route-map.

**Example**

```
OS10(config)# route-map route1 permit 100
OS10(config-route-map)#
```

**Supported Releases**

10.2.0E or later

### set comm-list add

Add communities in the specified list to the COMMUNITY attribute in a matching inbound or outbound BGP route.

**Syntax**

```
set comm-list {community-list-name} add
```

**Parameters**

`community-list-name`—Enter the name of an established community list. A maximum of 140 characters.

**Defaults**

None

**Command Mode**

ROUTE-MAP

**Usage Information**

In a route map, use this set command to add a list of communities that pass a permit statement to the COMMUNITY attribute of a BGP route sent or received from a BGP peer. Use the `set comm-list delete` command to delete a community list from a matching route.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# set comm-list comlist1 add
```

**Supported Releases**

10.4.0E(R1) or later

### set comm-list delete

Remove communities in the specified list from the COMMUNITY attribute in a matching inbound or outbound BGP route.

**Syntax**

```
set comm-list {community-list-name} delete
```

**Parameters**

`community-list-name`—Enter the name of an established community list. A maximum of 140 characters.

**Defaults**

None

**Command Mode**

ROUTE-MAP

**Usage Information**

Configure the community list that you use in the `set comm-list delete` command so that each filter contains only one community. For example, the filter `deny 100:12` is acceptable, but the filter `deny 120:13 140:33` results in an error. If you configure the `set comm-list delete` command and the `set community` command in the same route map sequence, the deletion `set comm-list delete` command processes before the insertion `set community` command. To add communities in a community list to the COMMUNITY attribute in a BGP route, use the `set comm-list add` command.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# set comm-list comlist1 delete
```

**Supported Releases**

10.3.0E or later

### set community

Sets the community attribute in BGP updates.

**Syntax**

```
set community {none | community-number}
```

**Parameters**

- `none`—Enter to remove the community attribute from routes meeting the route map criteria.
- `community-number`—Enter the community number in aa:nn format, where aa is the AS number, 2 bytes, and nn is a value specific to that AS.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes a BGP COMMUNITY attribute assignment.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# set community none
```

**Supported Releases**

10.3.0E or later

### set extcomm-list add

Add communities in the specified list to the EXTCOMMUNITY attribute in a matching inbound or outbound BGP route.

**Syntax**

```
set extcomm-list extcommunity-list-name add
```

**Parameter**

`extcommunity-list-name`—Enter the name of an established extcommunity list. A maximum of 140 characters.

**Defaults**

None

**Command Mode**

ROUTE-MAP

**Usage Information**

In a route map, use this set command to add an extended list of communities that pass a permit statement to the EXTCOMMUNITY attribute of a BGP route sent or received from a BGP peer. Use the `set extcomm-list delete` command to delete an extended community list from a matching route.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# set extcomm-list TestList add
```

**Supported Releases**

10.4.0E(R1) or later

### set extcomm-list delete

Remove communities in the specified list from the EXTCOMMUNITY attribute in a matching inbound or outbound BGP route.

**Syntax**

```
set extcomm-list extcommunity-list-name delete
```

**Parameter**

`extcommunity-list-name`—Enter the name of an established extcommunity list. A maximum of 140 characters.

**Defaults**

None

**Command Mode**

ROUTE-MAP

**Usage Information**

To add communities in an extcommunity list to the EXTCOMMUNITY attribute in a BGP route, use the `set extcomm-list add` command.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# set extcomm-list TestList delete
```

**Supported Releases**

10.3.0E or later

### set extcommunity

Sets the extended community attributes in a route map for BGP updates.

**Syntax**

```
set extcommunity rt {asn2:nn | asn4:nnnn | ip-addr:nn}
```

**Parameters**

- `asn2:nn`—Enter an AS number in 2-byte format; for example, 1–65535:1–4294967295.
- `asn4:nnnn`—Enter an AS number in 4-byte format; for example, 1–4294967295:1–65535 or 1–65535.1–65535:1–65535.
- `ip-addr:nn`—Enter an AS number in dotted format, from 1 to 65535.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the set clause from a route map.

**Example**

```
OS10(config)# route-map bgp
OS10(conf-route-map)# set extcommunity rt 10.10.10.2:325
```

**Supported Releases**

10.3.0E or later

### set local-preference

Sets the preference value for the AS path.

**Syntax**

```
set local-preference value
```

**Parameters**

`value`—Enter a number as the LOCAL_PREF attribute value, from 0 to 4294967295.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

This command changes the LOCAL_PREF attribute for routes meeting the route map criteria. To change the LOCAL_PREF for all routes, use the `bgp default local-preference` command. The no version of this command removes the LOCAL_PREF attribute.

**Example**

```
OS10(conf-route-map)# set local-preference 200
```

**Supported Releases**

10.2.0E or later

### set metric

Set a metric value for a routing protocol.

**Syntax**

```
set metric [+ | -] metric-value
```

**Parameters**

- `+`—(Optional) Add a metric value to the redistributed routes.
- `-`—(Optional) Subtract a metric value from the redistributed routes.
- `metric-value`—Enter a new metric value, from 0 to 4294967295.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

To establish an absolute metric, do not enter a plus or minus sign before the metric value. To establish a relative metric, enter a plus or minus sign immediately preceding the metric value. The value is added to or subtracted from the metric of any routes matching the route map. You cannot use both an absolute metric and a relative metric within the same route map sequence. Setting either metric overrides any previously configured value. The no version of this command removes the filter.

**Example (Absolute)**

```
OS10(conf-route-map)# set metric 10
```

**Example (Relative)**

```
OS10(conf-route-map)# set metric -25
```

**Supported Releases**

10.2.0E or later

### set metric-type

Set the metric type for a redistributed route.

**Syntax**

```
set metric-type {type-1 | type-2 | external}
```

**Parameters**

- `type-1`—Adds a route to an existing community.
- `type-2`—Sends a route in the local AS.
- `external`—Disables advertisement to peers.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

- BGP—Affects BGP behavior only in outbound route maps and has no effect on other types of route maps. If the route map contains both a `set metric-type` and a `set metric` clause, the `set metric` clause takes precedence. If you enter the internal metric type in a BGP outbound route map, BGP sets the MED of the advertised routes to the IGP cost of the next hop of the advertised route. If the cost of the next hop changes, BGP is not forced to readvertise the route.
  - `external`—Reverts to the normal BGP rules for propagating the MED, the default.
  - `internal`—Sets the MED of a received route that is being propagated to an external peer equal to the IGP costs of the indirect next hop.
- OSPF
  - `external`—Sets the cost of the external routes so that it is equal to the sum of all internal costs and the external cost.
  - `internal`—Sets the cost of the external routes so that it is equal to the external cost alone, the default.

The no version of this command removes the set clause from a route map.

**Example**

```
OS10(conf-route-map)# set metric-type internal
```

**Supported Releases**

10.2.0E or later

### set next-hop

Sets an IPv4 or IPv6 address as the next-hop.

**Syntax**

```
set {ip | ipv6} next-hop ip-address
```

**Parameters**

`ip-address`—Enter the IPv4 or IPv6 address for the next-hop.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

If you apply a route-map with the `set next-hop` command in ROUTER-BGP mode, it takes precedence over the `next-hop-self` command that is used in ROUTER-NEIGHBOR mode. In a route-map configuration, to configure more than one next-hop entry, use multiple `set {ip | ipv6} next-hop` commands. When you apply a route-map for redistribution or route updates in ROUTER-BGP mode, configure only one next-hop. Configure multiple next-hop entries only in a route-map used for other features, such as policy-based routing (PBR). The no version of this command deletes the setting.

**Example**

```
OS10(conf-route-map)# set ip next-hop 10.10.10.2
```

**Example (IPv6)**

```
OS10(conf-route-map)# set ipv6 next-hop 11AA:22CC::9
```

**Supported Releases**

10.2.0E or later

### set origin

Set the origin of the advertised route.

**Syntax**

```
set origin {egp | igp | incomplete}
```

**Parameters**

- `egp`—Enter to add to an existing community.
- `igp`—Enter to send inside the local-AS.
- `incomplete`—Enter to not advertise to peers.

**Default**

Not configured

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of this command deletes the set clause from a route map.

**Example**

```
OS10(conf-route-map)# set origin egp
```

**Supported Releases**

10.2.0E or later

### set tag

Sets a tag for redistributed routes.

**Syntax**

```
set tag tag-value
```

**Parameters**

`tag-value`—Enter a tag number for the route to redistribute, from 0 to 4294967295.

**Default**

Not configured

**Command Mode**

CONFIGURATION

**Usage Information**

The no version of this command deletes the set clause from a route map.

**Example**

```
OS10(conf-route-map)# set tag 23
```

**Supported Releases**

10.2.0E or later

### set weight

Set the BGP weight for the routing table.

**Syntax**

```
set weight weight
```

**Parameters**

`weight`—Enter a number as the weight that the route uses to meet the route map specification, from 0 to 65535.

**Default**

The default router-originated is 32768—all other routes are 0.

**Command Mode**

ROUTE-MAP

**Usage Information**

The no version of the command deletes the set clause from the route map.

**Example**

```
OS10(conf-route-map)# set weight 200
```

**Supported Releases**

10.2.0E or later

### show route-map

Displays the current route map configurations.

**Syntax**

```
show route-map [map-name]
```

**Parameters**

`map-name`—(Optional) Specify the name of a configured route map. A maximum of 140 characters.

**Defaults**

None

**Command Mode**

EXEC

**Usage Information**

None

**Example**

```
OS10# show route-map
route-map abc, permit, sequence 10
  Match clauses:
    ip address (access-lists): hello
    as-path abc
    community hello
    metric 2
    origin egp
    route-type external type-1
    tag 10
  Set clauses:
    metric-type type-1
    origin igp
    tag 100
```

**Supported Releases**

10.3.0E or later

