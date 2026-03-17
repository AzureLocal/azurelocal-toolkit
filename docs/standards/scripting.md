# Scripting Standards

> **Canonical reference:** [Scripting Standards (full)](https://azurelocal.cloud/standards/scripting/scripting-standards)  
> **Applies to:** All AzureLocal repositories  
> **Last Updated:** 2026-03-17

---

## Runtime Requirement

All scripts in this repository require **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 is not supported.

---

## Script Naming

| Script Type | Pattern | Example |
|-------------|---------|---------|
| PowerShell Core | `Verb-Noun.ps1` | `Deploy-AzureFoundation.ps1` |
| Azure PowerShell | `Verb-AzResource.ps1` | `New-AzKeyVault.ps1` |
| Azure CLI (PowerShell) | `az-verb-resource.ps1` | `az-create-vnet.ps1` |
| Azure CLI (Bash) | `az-verb-resource.sh` | `az-create-vnet.sh` |
| Standalone (no config) | `Verb-Noun-Standalone.ps1` | `Deploy-AzureFoundation-Standalone.ps1` |
| Remote/orchestration | `Invoke-<Task>.ps1` | `Invoke-ClusterDeploy.ps1` |
| Config generator | `Generate-<Purpose>-Parameters.ps1` | `Generate-AzureLocal-Parameters.ps1` |

---

## Config-Driven vs Standalone

| Mode | Config File | Dependencies | Use Case |
|------|-------------|-------------|----------|
| Config-driven (Options 2–4) | `config/variables.yml` | Config loader, helpers, Key Vault | Multi-environment automation, CI/CD |
| Standalone (Option 5) | Inline `#region CONFIGURATION` | None | Demos, single-use, external sharing |

### Config-Driven Rules

- Read all values from `config/variables.yml` or `config/infrastructure.yml` — never hardcode
- Accept `-ConfigPath` parameter (auto-discover if not provided)
- Use helper functions: `ConvertFrom-Yaml`, `Resolve-KeyVaultRef`, logging

### Standalone Rules

- All variables in `#region CONFIGURATION` block at top
- Variable names match `variables.yml` paths (e.g., `$azure_tenant_id`)
- Zero external dependencies — copy, paste, run

---

## `Invoke-` Script Requirements

### Required Parameters

| Parameter | Type | Default | Purpose |
|-----------|------|---------|---------|
| `-ConfigPath` | `[string]` | `""` | Path to `variables.yml` |
| `-Credential` | `[PSCredential]` | `$null` | Override credential resolution |
| `-TargetNode` | `[string[]]` | `@()` (all) | Limit to specific node(s) |
| `-WhatIf` | `[switch]` | `$false` | Dry-run mode |
| `-LogPath` | `[string]` | `""` (auto) | Override log file path |

All `Invoke-` scripts must use `[CmdletBinding()]` to enable `-Verbose` and `-Debug`.

### Credential Resolution Order

1. **`-Credential` parameter** — if passed, use immediately
2. **Key Vault** — read from `identity.accounts` in config; try `Az.KeyVault` module, fall back to `az` CLI
3. **Interactive prompt** — `Get-Credential` with username pre-filled

---

## Logging

- Log to `./logs/<task-name>/<timestamp>.log`
- Use `Write-Verbose` for detailed output
- Use `Write-Warning` for override notifications
- Log format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] Message`

---

## Toolkit-Specific Script Conventions

| Convention | Rule |
|-----------|------|
| Platform scope | Scripts manage the full Azure Local infrastructure lifecycle (not a single workload) |
| Config source | `config/infrastructure.yml` (13-section master config) and `config/variables.yml` |
| Parameter generation | `config/Generate-AzureLocal-Parameters.ps1` derives tool-specific params |
| Idempotency | All scripts must be safe to re-run (`-WhatIf` for dry runs) |
| Validation | `tests/` contains Pester test suites for all script modules |

---

## Related Standards

- [PowerShell Organization Standard](https://azurelocal.cloud/standards/scripting/powershell-organization-standard)
- [Scripting Framework](https://azurelocal.cloud/standards/scripting/scripting-framework)
- [Bash Scripting Standards](https://azurelocal.cloud/standards/scripting/bash-scripting-standards)
- [Automation Interoperability](automation.md)
