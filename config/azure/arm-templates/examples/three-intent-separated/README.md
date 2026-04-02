# Three-Intent Separated (Fully Disaggregated) Examples

These parameter files demonstrate a **fully disaggregated** network intent layout where
Management, Compute, and Storage traffic each have their own dedicated pair of adapters.

## When to Use This Layout

- Large production clusters where maximum bandwidth isolation is required
- Nodes with 6 network adapters (3 pairs)
- High-density workloads requiring dedicated compute bandwidth separate from management
- Environments where 1 GbE management NICs are used alongside 25 GbE data NICs

## ARM Template Settings

| Setting | Value |
|---------|-------|
| `networkingPattern` | `custom` |
| `networkingType` | `switchedMultiServerDeployment` |
| Intent count | 3 |
| Adapters per node | 2 × 1 GbE (mgmt) + 4 × 25 GbE (compute + storage) |
| RDMA | Enabled on storage intent only (RoCEv2) |
| Jumbo frames | 1514 on management, 1514 on compute, 9014 on storage |

## Hardware Layout (Per Node)

```
MGMT1 (1 GbE) ───┐
                  ├── Intent 1: Management (no RDMA, 1514 MTU)
MGMT2 (1 GbE) ───┘

NIC1 (25 Gbps) ──┐
                  ├── Intent 2: Compute (no RDMA, 1514 MTU)
NIC2 (25 Gbps) ──┘

SMB1 (25 Gbps) ──┐
                  ├── Intent 3: Storage (RDMA enabled, 9014 MTU)
SMB2 (25 Gbps) ──┘
```

## Files

- `azuredeploy.parameters.ad.json` — Active Directory authentication
- `azuredeploy.parameters.local-identity.json` — Local Identity authentication

The **only difference** between the two files is:
- AD: `domainFqdn` and `adouPath` are populated
- Local Identity: `domainFqdn` and `adouPath` are empty strings (`""`)

## Example Company

All values use the **Contoso** fictional company per documentation standards.
