# Azure Local Toolkit

!!! warning "Under Active Development"
    This repository is a work in progress. Scripts, templates, and automation are **not guaranteed to work** at this time. Use at your own risk and expect breaking changes.

Platform automation toolkit for **Azure Local** — deployment scripts, validation suites, config management, and solution packages covering the full deployment lifecycle.

---

## What's Inside

| Directory | Description |
|-----------|-------------|
| **scripts/** | 200+ PowerShell scripts organized by deployment stage (02–08), plus common modules, validation, handover, lifecycle, and tools |
| **configs/** | Master infrastructure config template, solution definitions, ARM templates, and variable registry |
| **solutions/** | Per-solution deployment packages (placeholders for future solutions) |
| **tools/** | Planning utilities (S2D capacity calculator) |
| **tests/** | Test infrastructure (future Pester suites) |

## Deployment Stages

| Stage | Name | Description |
|-------|------|-------------|
| 02 | [Azure Foundation](deployment/02-azure-foundation.md) | Landing zones, RBAC, VNet, management infrastructure |
| 03 | [On-Prem Readiness](deployment/03-onprem-readiness.md) | Active Directory, hardware validation, network prep |
| 04 | [Cluster Deployment](deployment/04-cluster-deployment.md) | Hardware → OS → Arc registration → cluster creation |
| 05 | [Operational Foundations](deployment/05-operational-foundations.md) | SDN, monitoring, backup configuration |
| 06 | [Testing & Validation](deployment/06-testing-validation.md) | Automated test suites |
| 07 | [Validation & Handover](deployment/07-validation-handover.md) | Customer transfer and sign-off |
| 08 | [Lifecycle Operations](deployment/08-lifecycle-operations.md) | Updates, maintenance, day-2 operations |

## Configuration

- [Variables Reference](configuration/variables.md) — Master infrastructure config and variable registry
- [Solutions Mapping](configuration/solutions.md) — Which variables each solution needs

## Getting Started

1. Clone the repository
2. Copy `configs/variables.template.yml` to `configs/variables.yml`
3. Fill in your environment-specific values
4. Follow the deployment stage guides in order (02 → 08)

See the [Contributing Guide](contributing.md) for development guidelines.
