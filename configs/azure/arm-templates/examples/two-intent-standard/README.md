# Two-Intent Standard (Management+Compute / Storage) Examples

These parameter files demonstrate the **standard two-intent** network layout where
Management and Compute traffic share one pair of adapters, and Storage has its
own dedicated pair.

## When to Use This Layout

- Most common production deployment pattern
- Nodes with 4 high-speed network adapters (2 pairs)
- When you want dedicated RDMA storage bandwidth separate from management/compute
- Standard Azure Local Cloud deployment configuration

## ARM Template Settings

| Setting | Value |
|---------|-------|
| `networkingPattern` | `convergedManagementCompute` |
| `networkingType` | `switchedMultiServerDeployment` |
| Intent count | 2 |
| Adapters per node | 4 × 25 Gbps (2 per intent) |
| RDMA | Enabled on storage intent only (RoCEv2) |
| Jumbo frames | 1514 on mgmt/compute, 9014 on storage |

## Hardware Layout (Per Node)

```
NIC1 (25 Gbps) ──┐
                  ├── Intent 1: Management + Compute (no RDMA)
NIC2 (25 Gbps) ──┘

SMB1 (25 Gbps) ──┐
                  ├── Intent 2: Storage (RDMA enabled)
SMB2 (25 Gbps) ──┘
```

## Files

- `azuredeploy.parameters.ad.json` — Active Directory authentication
- `azuredeploy.parameters.local-identity.json` — Local Identity authentication

The **only difference** between the two files is:
- AD: `domainFqdn` and `adouPath` are populated
- Local Identity: `domainFqdn` and `adouPath` are empty strings (`""`)

## Example Company

All values use the **Infinite Improbability Corp** fictional company per documentation standards.
