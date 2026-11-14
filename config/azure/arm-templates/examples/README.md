# ARM Template Examples

This directory contains validated parameter files for Azure Local cluster deployments. The IIC (Contoso) examples cover all three networking patterns with both AD and Local Identity authentication methods. Environment templates provide starting points for real deployments.

## Purpose

- **Reference**: See how all 54 parameters are populated across different networking configurations
- **Validation**: Compare your parameter file against working examples
- **Troubleshooting**: Identify differences when deployments fail
- **Generation**: Compare with the file `Invoke-AzureLocalArmDeployment.ps1 -InfrastructureFile ./infrastructure.yml -Mode Plan -Offline` generates from `infrastructure.yml`

## Structure

```
examples/
├── README.md                        # This file
├── single-intent-converged/         # IIC: 1-intent converged networking
│   ├── azuredeploy.parameters.ad.json
│   ├── azuredeploy.parameters.local-identity.json
│   └── README.md
├── two-intent-standard/             # IIC: 2-intent standard networking
│   ├── azuredeploy.parameters.ad.json
│   ├── azuredeploy.parameters.local-identity.json
│   └── README.md
└── three-intent-separated/          # IIC: 3-intent separated networking
    ├── azuredeploy.parameters.ad.json
    ├── azuredeploy.parameters.local-identity.json
    └── README.md
```

## IIC Examples — Networking Patterns

All IIC examples use the fictional Contoso (`contoso.cloud`, prefix `iic`). Each pattern includes both AD and Local Identity parameter files with all 54 parameters populated.

| Pattern | Directory | Intent Count | Use Case |
|---------|-----------|-------------|----------|
| Converged | `single-intent-converged/` | 1 | PoC, small edge, single NIC pair |
| Standard | `two-intent-standard/` | 2 | Production — compute+management split from storage |
| Separated | `three-intent-separated/` | 3 | High-performance — dedicated storage, compute, management |

## Adding Examples

When adding a new example:

1. **Sanitize sensitive data** — Remove or replace:
   - Actual subscription IDs → `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
   - Real customer names → Generic identifiers
   - IP addresses if customer-specific → Use example ranges
   - Keep structure and parameter names intact

2. **Document the context** — Add a `README.md` explaining:
   - Networking pattern and node count
   - Authentication method
   - Any special configurations or lessons learned

3. **Naming convention**: Use the networking pattern as directory name

## Security Notice

⚠️ **Never commit actual secrets, passwords, or real subscription IDs** to this directory. All sensitive values should be:
- Replaced with placeholder text
- Redacted completely
- Referenced via Key Vault (which is acceptable to show)
