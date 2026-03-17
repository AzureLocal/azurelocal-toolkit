# Solution Development Standards

> **Canonical reference:** [Solution Development Standard (full)](https://azurelocal.cloud/standards/solutions/solution-development-standard)  
> **Applies to:** All AzureLocal repositories  
> **Last Updated:** 2026-03-17

---

## Overview

Standards for solution packaging, multi-tool automation parity, and deployment best practices for the Azure Local Platform Toolkit.

---

## IaC Tool Parity

All tools must produce **identical infrastructure** when given the same configuration values:

| Tool | Phase 1 (Azure) | Domain Join | Cluster Deploy | Operations |
|------|:---:|:---:|:---:|:---:|
| **Terraform** | ✅ | ✅ | Delegates | ✅ |
| **Bicep** | ✅ | ✅ | Delegates | ✅ |
| **ARM** | ✅ | ✅ | Delegates | — |
| **PowerShell** | ✅ | ✅ | ✅ | ✅ |
| **Ansible** | ✅ | ✅ | ✅ | ✅ |

---

## Parameter File Derivation

All tool-specific parameter files MUST be derivable from `config/infrastructure.yml`:

| Tool | Parameter File | Derivation |
|------|---------------|-----------|
| Terraform | `terraform.tfvars` | Map YAML sections to HCL variables |
| Bicep | `main.bicepparam` | Map YAML sections to Bicep parameters |
| ARM | `azuredeploy.parameters.json` | Map YAML sections to ARM parameter schema |
| PowerShell | *(reads config directly)* | `ConvertFrom-Yaml` + `Generate-AzureLocal-Parameters.ps1` |
| Ansible | `inventory/hosts.yml` | Map YAML sections to `group_vars` |

The central config (`config/infrastructure.yml`) is the **single source of truth**. Tool-specific files are convenience copies that should be regenerable.

---

## Solution Structure

| Directory | Purpose |
|-----------|---------|
| `config/` | Configuration files — infrastructure.yml, variables, schemas |
| `docs/` | Documentation source (MkDocs) |
| `scripts/` | PowerShell automation scripts |
| `tools/` | Utility tools and helpers |
| `tests/` | Pester test suites |
| `pipelines/` | CI/CD pipeline definitions |
| `logs/` | Runtime log output (gitignored) |

---

## Idempotency

All scripts must be safe to re-run without side effects:

- Check for existing resources before creating
- Use `-WhatIf` for dry-run validation
- Log all operations for audit trail

---

## Related Standards

- [Scripting Standards](scripting.md)
- [Variable Standards](variables.md)
- [Infrastructure Standards](infrastructure.md)
- [Automation Interoperability](automation.md)
