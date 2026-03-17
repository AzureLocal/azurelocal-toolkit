# Automation Interoperability

> **Canonical reference:** [Scripting Framework (full)](https://azurelocal.cloud/standards/scripting/scripting-framework)  
> **Applies to:** All AzureLocal repositories  
> **Last Updated:** 2026-03-17

---

## Overview

This standard defines how multiple automation tools (Terraform, Bicep, ARM, PowerShell, Ansible) interoperate within the Azure Local Platform Toolkit. All tools share a single configuration source and must produce identical infrastructure.

---

## Config Flow

```mermaid
flowchart TB
    A["config/infrastructure.yml<br/>(single source of truth)"] --> B[Generate-AzureLocal-Parameters.ps1]
    B --> C[Terraform .tfvars]
    B --> D[Bicep .bicepparam]
    B --> E[ARM parameters.json]
    B --> F[Ansible group_vars]
    A --> G[PowerShell ConvertFrom-Yaml]
    C --> H[Identical Infrastructure]
    D --> H
    E --> H
    F --> H
    G --> H
```

---

## Deployment Path Matrix

| Tool | Azure Foundation | Domain Join | Cluster Deploy | Guest Config | Operations |
|------|:---:|:---:|:---:|:---:|:---:|
| **Terraform** | ✅ | ✅ | Delegates | Delegates | ✅ |
| **Bicep** | ✅ | ✅ | Delegates | Delegates | ✅ |
| **ARM** | ✅ | ✅ | Delegates | Delegates | — |
| **PowerShell** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Ansible** | ✅ | ✅ | ✅ | ✅ | ✅ |

!!! warning "Delegates"
    "Delegates" means the IaC tool provisions Azure resources but does not configure the on-premises or guest OS layer. A separate tool (PowerShell or Ansible) handles those phases.

---

## Interoperability Rules

1. **Single source of truth** — `config/infrastructure.yml` is the only config file. All tool-specific parameter files are derived via `Generate-AzureLocal-Parameters.ps1`.
2. **Identical output** — Given the same config, every tool must produce the same infrastructure.
3. **13-section hierarchy** — All configs follow the master-registry v4.0.0 structure (metadata, infrastructure_scenarios, site, environment, tags, azure_platform, identity, networking, compute, storage, security, monitoring, operations).
4. **Idempotency** — All scripts and templates must be safe to re-run.
5. **Error handling** — Every tool must validate config before executing changes.
6. **Logging** — All operations logged to `./logs/` with consistent format.

---

## Variable Path Contract

Scripts must use variable paths that exist in the schema. See the [Variable Standards](variables.md) for naming rules and the [Variable Reference](../reference/variables.md) for the complete catalog.

---

## Related Standards

- [Scripting Standards](scripting.md)
- [Infrastructure Standards](infrastructure.md)
- [Solution Standards](solutions.md)
- [Variable Standards](variables.md)
