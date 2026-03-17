# Standards

This repository follows the **org-wide AzureLocal standards** maintained on the central documentation site.

!!! info "Central Standards"
    The full standards suite is at [azurelocal.cloud/standards](https://azurelocal.cloud/standards/).
    This section provides the key rules adapted for the Azure Local Platform Toolkit.

---

## Standards Pages

| Standard | Local Page | Central Reference |
|----------|-----------|------------------|
| Documentation | [Documentation Standards](documentation.md) | [Full Reference](https://azurelocal.cloud/standards/documentation/documentation-standards) |
| Scripting | [Scripting Standards](scripting.md) | [Full Reference](https://azurelocal.cloud/standards/scripting/scripting-standards) |
| Variables | [Variable Standards](variables.md) | [Full Reference](https://azurelocal.cloud/standards/variable-management/) |
| Naming Conventions | [Naming Conventions](naming.md) | [Full Reference](https://azurelocal.cloud/standards/documentation/naming-conventions) |
| Solutions | [Solution Standards](solutions.md) | [Full Reference](https://azurelocal.cloud/standards/solutions/solution-development-standard) |
| Infrastructure | [Infrastructure Standards](infrastructure.md) | [Full Reference](https://azurelocal.cloud/standards/infrastructure/) |
| Automation | [Automation Interoperability](automation.md) | [Full Reference](https://azurelocal.cloud/standards/scripting/scripting-framework) |
| Examples & IIC | [Examples & IIC](examples.md) | [Full Reference](https://azurelocal.cloud/standards/fictional-company-policy) |

---

## References

- [Variable Reference](../reference/variables.md) — Per-variable catalog for this repo
- [Repository Structure](https://azurelocal.cloud/standards/repo-structure) — Required file layout

---

## Repo-Specific Conventions

- **13-section hierarchy**: `config/infrastructure.yml` follows the master-registry v4.0.0 structure with 13 top-level sections (metadata, infrastructure_scenarios, site, environment, tags, azure_platform, identity, networking, compute, storage, security, monitoring, operations)
- **Schema validation**: The 800-line `config/schema/variables.schema.json` enforces structure on every PR via `validate-config.yml`
- **Platform scope**: This is the platform toolkit — it manages the full Azure Local infrastructure lifecycle, not a single workload
- **Central config**: `config/infrastructure.yml` is the comprehensive template; `config/variables.example.yml` is the simplified deployment-specific extract
