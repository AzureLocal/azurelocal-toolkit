# Deployment Overview

The Azure Local Toolkit follows a structured deployment lifecycle organized into stages 02 through 08. Each stage has its own set of PowerShell scripts in `scripts/deploy/`.

!!! note "Stage 01 Skipped"
    Stage 01 was environment-specific CI/CD infrastructure and is not included in this toolkit.

## Stage Progression

```mermaid
graph LR
    A[02 Azure Foundation] --> B[03 On-Prem Readiness]
    B --> C[04 Cluster Deployment]
    C --> D[05 Operational Foundations]
    D --> E[06 Testing & Validation]
    E --> F[07 Validation & Handover]
    F --> G[08 Lifecycle Operations]
```

## Common Modules

The `scripts/common/` directory contains shared modules used across all stages:

- **Config Loader** — Reads `infrastructure.yml` and resolves variable references
- **Key Vault Resolver** — Retrieves secrets from Azure Key Vault at runtime
- **Logging** — Standardized output formatting and log file management
