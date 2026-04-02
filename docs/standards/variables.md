# Variable Standards

> **Canonical reference:** [Variable Management Standard](https://azurelocal.cloud/standards/variable-management/)  
> **Full variable catalog:** [Variable Reference](../reference/variables.md)  
> **Last Updated:** 2026-04-02

---

## Overview

This repository uses a **single central configuration file** — `config/variables.yml` — as the source of truth for all deployment automation. Copy from `config/variables.example.yml` to get started.

All variable names, types, and metadata are governed by the **master registry** (`config/variables/schema/master-registry.yaml`). Variable access in scripts must use the **canonical reader module** for alias resolution and fail-fast validation.

---

## Architecture

```
config/variables/
├── variables.example.yml                    # Template with examples (committed)
├── variables.yml                            # Your actual config (gitignored)
├── schema/
│   ├── master-registry.yaml                 # Authoritative variable registry (v4.0.0)
│   ├── variables.schema.json                # JSON Schema for CI validation
│   ├── canonical-drift-allowlist.json       # Drift paths (should be empty)
│   └── legacy-compatible-roots.json         # Legacy section names allowed during migration
└── scripts/
    ├── validate-variables.ps1               # Schema + registry validator
    └── canonical_variables.py               # Python reader module
```

### Consumer Module

```
scripts/common/utilities/helpers/
└── CanonicalVariable.psm1                   # PowerShell reader module
```

---

## Naming Rules

| Rule | Standard | Example |
|------|----------|---------|
| Top-level sections | `snake_case` | `azure_local`, `networking` |
| Keys within sections | `snake_case` | `subscription_id`, `resource_name` |
| Pattern | `^[a-z][a-z0-9_]*$` | — |
| Max length | 50 characters | — |
| Booleans | Descriptive names | `monitoring_enabled: true` |
| Secrets | `keyvault://` URI format | `keyvault://kv-iic-platform/admin-password` |

---

## Master Registry

The master registry (`master-registry.yaml`) is the single source of truth for all variable definitions. Every variable must be registered with:

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | `string`, `boolean`, `integer`, `array`, `object` |
| `description` | Yes | Human-readable purpose |
| `required` | No | Whether the variable must be set |
| `category` | No | Top-level grouping |
| `subcategory` | No | Section within category |
| `alias_for` | No | Points to the canonical name (for aliases) |
| `sensitive` | No | Marks secrets (redacted in logs) |
| `pattern` | No | Regex validation |
| `allowedValues` | No | Enum constraint |
| `default` | No | Default value |
| `example` | No | Example value |

### Registry Sections (15)

| Section | Description |
|---------|-------------|
| `identity` | Azure AD, service principals, managed identities |
| `azure_platform` | Tenants, subscriptions, resource groups |
| `networking` | Azure networking, on-prem VLANs, SDN |
| `compute` | Cluster nodes, VMs, AVD, Azure Local clusters |
| `storage` | Storage accounts, CSVs, file shares |
| `security` | Key Vaults, credentials, RBAC |
| `operations` | Monitoring, backup, update management |
| `marketplace_images` | VM image definitions |
| `governance` | Policies, compliance, tagging |
| `azure_jumpbox_vm` | Jump box/WAC VM configuration |
| `arc_configuration` | Azure Arc onboarding |
| `services` | Azure services (DNS, Bastion, VPN) |
| `sentinel` | Microsoft Sentinel integration |
| `site` | Physical site metadata |
| `environment` | Deployment environment settings |

---

## Aliases

Aliases provide backward-compatible access to variables that were renamed or restructured. They are a **migration aid**, not a permanent feature.

### How Aliases Work

```yaml
# In master-registry.yaml
identity:
  active_directory:
    domain:
      fqdn:
        type: string
        description: "Domain FQDN (alias)"
        alias_for: ad_domain_fqdn    # ← points to canonical name
```

When a consumer script looks up `identity.active_directory.domain.fqdn`, the canonical reader resolves it to the value stored under `ad_domain_fqdn`.

### Alias Lifecycle

| Phase | State | Action |
|-------|-------|--------|
| Created | Active | Alias added with `alias_for` metadata |
| Migration | Active | Consumer scripts updated to use canonical name |
| Deprecated | Warning | Reader logs deprecation warning |
| Retired | Removed | Alias entry removed from registry |

**Policy:** Aliases must be retired within two major releases of their creation.

---

## Consumer Interface

### PowerShell

```powershell
Import-Module .\CanonicalVariable.psm1

# Initialize (auto-discovers config/variables/ directory)
Initialize-CanonicalVariables

# Read a variable by canonical path
$clusterName = Get-CanonicalVariable -Path 'compute.clusters.azure_local.azl_name'

# With default fallback
$location = Get-CanonicalVariable -Path 'azure_platform.location' -Default 'eastus'

# Fail-fast validation for required variables
Test-RequiredCanonicalVariables -Paths @(
    'identity.azure_tenant_id',
    'security.keyvault_name',
    'compute.clusters.azure_local.azl_name'
) -ScriptName 'Deploy-Cluster.ps1'

# Inspect alias map
$aliases = Get-CanonicalAliasMap
```

### Python

```python
from canonical_variables import CanonicalVariables

cv = CanonicalVariables()

# Read a variable
cluster_name = cv.get('compute.clusters.azure_local.azl_name')

# With default
location = cv.get('azure_platform.location', default='eastus')

# Fail-fast validation
cv.require(
    'identity.azure_tenant_id',
    'security.keyvault_name',
    caller='deploy-cluster.py'
)
```

---

## Config File Structure

```
config/
├── variables.example.yml        # Template with IIC examples (committed)
├── variables.yml                # Your actual config (gitignored)
└── schema/
    └── variables.schema.json    # JSON Schema for CI validation
```

---

## Key Vault Resolution

Secrets are never stored in plaintext:

```yaml
security:
  admin_password: "keyvault://kv-iic-platform/admin-password"
  domain_join_password: "keyvault://kv-iic-platform/domain-join"
```

---

## CI Validation

Every PR validates `config/variables.example.yml` against `config/schema/variables.schema.json` using the `validate-config.yml` workflow.

The validator enforces:
- JSON Schema compliance
- Unknown key rejection (all paths must be in the registry)
- Required variable presence
- Type correctness
- Zero drift allowlist (all paths normalized)

---

## Migration and Rollback

### Migrating a Consumer Repo

1. Copy `CanonicalVariable.psm1` into the repo's common scripts directory
2. Import the module in each script that loads configuration
3. Replace inline `ConvertFrom-Yaml` with `Initialize-CanonicalVariables` + `Get-CanonicalVariable`
4. Update variable paths from legacy names to canonical dotted paths
5. Add `Test-RequiredCanonicalVariables` for fail-fast behavior
6. Run the canonical validator to confirm zero unknown paths
7. Test all scripts in dry-run mode before deploying

### Rollback

If a migration introduces regressions:
1. Revert to the previous `variables.example.yml` and `master-registry.yaml` (both are versioned)
2. Restore the previous `CanonicalVariable.psm1` or remove it
3. Scripts can fall back to inline `ConvertFrom-Yaml` without the module

---

## Troubleshooting Validation Failures

| Error | Cause | Fix |
|-------|-------|-----|
| `schema validation failed: 'X' is a required property` | Missing required section in variables.yml | Add the section or remove it from schema `required` |
| `canonical unknown variable paths` | Variable path not in registry | Add variable to master-registry.yaml |
| `Duplicate key` | Two variables with same name at same level | Rename one or merge into single entry |
| `Type mismatch` | Value doesn't match registry type | Fix the value or update the type in registry |
| `Pattern mismatch` | Value doesn't match regex constraint | Fix value to match the pattern |

---

## Detailed Reference

For the complete variable catalog see:

- **[Variable Reference](../reference/variables.md)** — per-variable documentation
- **[Variable Management Standard](https://azurelocal.cloud/docs/implementation/04-variable-management-standard)** — org-wide governance
- **[Variable Management Suite](https://azurelocal.cloud/standards/variable-management/)** — registry, schema validation, workflows
- Tool-specific parameter mapping