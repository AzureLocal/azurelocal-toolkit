# Documentation Standards

> **Canonical reference:** [Documentation Standards (full)](https://azurelocal.cloud/standards/documentation/documentation-standards)  
> **Applies to:** All AzureLocal repositories  
> **Last Updated:** 2026-03-17

---

## Principles

| Principle | Rule |
|-----------|------|
| Documentation-First | Document **before** implementing. Keep docs current with code. |
| Single Source of Truth | One authoritative document per topic. Cross-reference, don't duplicate. |
| Audience-Aware | Write for operators, developers, or executives — with appropriate depth. |
| Actionable | Step-by-step procedures, examples, prerequisites, and outcomes. |

---

## File Naming

| Type | Convention | Pattern | Example |
|------|-----------|---------|---------|
| Directories | lowercase-with-hyphens | `^[a-z][a-z0-9-]*$` | `deployment/`, `configuration/` |
| Markdown (docs/) | lowercase with hyphens | `*.md` | `azure-foundation.md` |
| Root files | UPPERCASE | — | `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md` |
| PowerShell scripts | PascalCase | `Verb-Noun.ps1` | `Deploy-AzureFoundation.ps1` |
| Config files | lowercase-with-hyphens | — | `variables.example.yml` |

---

## MkDocs Material Conventions

This repo uses **MkDocs Material** with:

- **Admonitions**: `!!! note`, `!!! warning`, `!!! danger`, `!!! info`, `!!! tip`
- **Code blocks**: Always include a language identifier (e.g., ` ```powershell `, ` ```yaml `)
- **Code copy**: Enabled via `content.code.copy`
- **Mermaid diagrams**: Supported via `pymdownx.superfences` custom fence
- **Tables**: Use standard Markdown tables
- **Tabs**: `=== "Tab Name"` via `pymdownx.tabbed`

---

## Fictional Company — Infinite Improbability Corp (IIC)

All examples must use IIC naming patterns:

| Never Use | Use Instead |
|-----------|-------------|
| `contoso`, `fabrikam`, `northwind` | Infinite Improbability Corp |
| `example.com`, `test.com` | `improbability.cloud` |
| Real customer names | IIC naming patterns |

---

## Related Standards

- [Naming Conventions (full reference)](https://azurelocal.cloud/standards/documentation/naming-conventions)
- [Badge Library](https://azurelocal.cloud/standards/documentation/badge-library)
- [Naming Conventions](naming.md)
- [Scripting Standards](scripting.md)
