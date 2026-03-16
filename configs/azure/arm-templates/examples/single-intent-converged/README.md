# Single-Intent Converged (HyperConverged) Examples

These parameter files demonstrate a **fully converged** network intent layout where
Management, Compute, and Storage traffic all share the same pair of network adapters.

## When to Use This Layout

- Small clusters (1–4 nodes) with limited NIC ports
- Lab or proof-of-concept environments
- Hardware with only 2 high-speed network adapters per node

## ARM Template Settings

| Setting | Value |
|---------|-------|
| `networkingPattern` | `hyperConverged` |
| `networkingType` | `switchedMultiServerDeployment` |
| Intent count | 1 |
| Adapters per node | 2 × 25 Gbps |
| RDMA | Enabled (RoCEv2) — required for storage traffic |
| Jumbo frames | 9014 |

## Hardware Layout (Per Node)

```
NIC1 (25 Gbps) ──┐
                  ├── Intent: Management + Compute + Storage
NIC2 (25 Gbps) ──┘
```

## Files

- `azuredeploy.parameters.ad.json` — Active Directory authentication
- `azuredeploy.parameters.local-identity.json` — Local Identity authentication

The **only difference** between the two files is:
- AD: `domainFqdn` and `adouPath` are populated
- Local Identity: `domainFqdn` and `adouPath` are empty strings (`""`)

## Example Company

All values use the **Infinite Improbability Corp** fictional company per documentation standards.
