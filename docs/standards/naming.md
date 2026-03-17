# Naming Conventions

> **Canonical reference:** [Naming Conventions (full)](https://azurelocal.cloud/standards/documentation/naming-conventions)  
> **Applies to:** All AzureLocal repositories  
> **Last Updated:** 2026-03-17

---

## File & Directory Naming

| Type | Convention | Pattern | Example |
|------|-----------|---------|---------|
| Directories | lowercase-with-hyphens | `^[a-z][a-z0-9-]*$` | `deployment/`, `configuration/` |
| Markdown (docs/) | lowercase with hyphens | `*.md` | `azure-foundation.md` |
| Root files | UPPERCASE | — | `README.md`, `CHANGELOG.md` |
| PowerShell scripts | PascalCase | `Verb-Noun.ps1` | `Deploy-AzureFoundation.ps1` |
| Config files | lowercase-with-hyphens | — | `variables.example.yml`, `infrastructure.yml` |

---

## Azure Resource Naming

All resources follow the [IIC naming patterns](examples.md):

| Resource Type | Pattern | Example |
|--------------|---------|---------|
| Resource Group | `rg-iic-<purpose>-<##>` | `rg-iic-platform-01` |
| Cluster | `iic-clus<NN>` | `iic-clus01` |
| Node | `iic-<clus>-n<NN>` | `iic-01-n01` |
| Key Vault | `kv-iic-<purpose>` | `kv-iic-platform` |
| Storage Account | `stiic<purpose><##>` | `stiicwitness01` |
| Log Analytics | `law-iic-<purpose>-<##>` | `law-iic-monitor-01` |

---

## Variable Naming

| Rule | Standard | Example |
|------|----------|---------|
| YAML sections | `snake_case` | `azure_platform`, `networking`, `compute` |
| YAML keys | `snake_case` | `subscription_id`, `cluster_name` |
| Pattern | `^[a-z][a-z0-9_]*$` | — |
| Max length | 50 characters | — |
| 13-section hierarchy | Follows master-registry v4.0.0 | `metadata`, `site`, `environment`, `tags`, `azure_platform`, `identity`, `networking`, `compute`, `storage`, `security`, `monitoring`, `operations`, `infrastructure_scenarios` |

---

## Git Branch Naming

| Pattern | Usage | Example |
|---------|-------|---------|
| `main` | Default branch | — |
| `feature/<description>` | New features | `feature/cloud-cache-support` |
| `fix/<description>` | Bug fixes | `fix/node-validation` |
| `docs/<description>` | Documentation | `docs/deployment-stages` |
| `infra/<description>` | CI/CD | `infra/add-pester-tests` |

---

## Related Standards

- [Full Naming Conventions](https://azurelocal.cloud/standards/documentation/naming-conventions)
- [Repository Structure](https://azurelocal.cloud/standards/repo-structure)
- [Documentation Standards](documentation.md)
- [Examples & IIC](examples.md)
