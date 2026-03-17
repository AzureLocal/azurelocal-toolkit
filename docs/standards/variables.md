# Variable Standards

> **Canonical reference:** [Variable Management Standard](https://azurelocal.cloud/standards/variable-management/)  
> **Schema reference:** [Schema Validation](https://azurelocal.cloud/standards/variable-management/schema-validation)  
> **Last Updated:** 2026-03-17

---

## Overview

This repository uses two configuration files:

| File | Purpose | Committed |
|------|---------|:---------:|
| `config/infrastructure.yml` | Complete 13-section infrastructure template (master config) | Yes |
| `config/variables.example.yml` | Simplified deployment-specific extract with IIC examples | Yes |
| `config/variables.yml` | Your actual deployment values | **No** (`.gitignore`) |

Copy the example file and fill in your values:

```powershell
cp config/variables.example.yml config/variables.yml
```

---

## 13-Section Hierarchy

The toolkit follows the master-registry v4.0.0 structure:

| # | Section | Description |
|---|---------|-------------|
| 1 | `_metadata` | File version, schema version, changelog |
| 2 | `infrastructure_scenarios` | Deployment type taxonomy, variable grouping |
| 3 | `site` | Physical location, hardware details (vendor, model, iDRAC) |
| 4 | `environment` | Environment classification (lab, demo, production) |
| 5 | `tags` | Azure resource tagging standards |
| 6 | `azure_platform` | Tenant, management groups, subscriptions, resource groups, Key Vault |
| 7 | `identity` | Accounts, AD, Entra ID, service principals, security groups |
| 8 | `networking` | VLANs, subnets, VPN, VNet, network devices, intents |
| 9 | `compute` | Cluster nodes, NIC hardware, BMC/iDRAC |
| 10 | `storage` | Volumes, deduplication, Storage Spaces Direct |
| 11 | `security` | Key Vault, certificates, RBAC |
| 12 | `monitoring` | Log Analytics, alerts, diagnostics |
| 13 | `operations` | Backup, update management, lifecycle |

---

## Naming Rules

| Rule | Standard | Example |
|------|----------|---------|
| Top-level sections | `snake_case` | `azure_platform`, `identity` |
| Keys within sections | `snake_case` | `subscription_id`, `cluster_name` |
| Pattern | `^[a-z][a-z0-9_]*$` | — |
| Max length | 50 characters | — |
| Booleans | Descriptive names | `sdn_enabled: false` |
| Secrets | `keyvault://` URI format | `keyvault://kv-platform/admin-password` |

---

## Key Vault Resolution

Secrets are never stored in plaintext. The `keyvault://` URI format tells tools to resolve at runtime:

```yaml
account_local_admin_password: "keyvault://kv-demos-platform/azlocal-admin-password"
shared_key: "keyvault://kv-demos-platform/vpn-shared-key"
```

**Resolution flow:**

1. Tool parses URI → vault name + secret name
2. Tool calls `az keyvault secret show` to retrieve the value
3. Secret is passed directly to the operation — never written to disk

---

## JSON Schema Validation

`config/schema/variables.schema.json` (800 lines) enforces:

- Required sections: `site`, `environment`, `tags`, `azure_platform`, `identity`, `networking`, `compute`
- GUID pattern validation for tenant IDs, subscription IDs
- `keyvault://` pattern enforcement for all password fields
- Email format validation for owner fields
- Enum constraints for hardware vendors (`Dell`, `HPE`, `Lenovo`, `DataON`)

Every PR runs the `validate-config.yml` workflow to validate against this schema.

---

## Detailed References

- **[Variables Reference](../configuration/variables.md)** — overview of config files for this repo
- **[Variable Management Standard](https://azurelocal.cloud/standards/variable-management/)** — org-wide governance
- **[Schema Validation](https://azurelocal.cloud/standards/variable-management/schema-validation)** — JSON Schema patterns
