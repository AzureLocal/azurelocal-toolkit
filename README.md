# Azure Local Toolkit

Primary automation repository for Azure Local deployment, configuration, validation, and lifecycle operations.

> This repository is under active development. Treat the contents as implementation assets and working automation, not as a polished documentation site.

## What This Repo Contains

This repository is the operational toolkit for building and running Azure Local automation. It includes:

- deployment and validation scripts across the full lifecycle
- infrastructure-as-code sources for Terraform, Bicep, ARM templates, and Ansible
- CI/CD pipeline samples for GitLab, GitHub Actions, and Azure DevOps
- config-driven variable handling and schema assets
- repo-management artifacts for planning, checklists, and working notes

This README is the primary entry point for understanding the repository.

## Supported Automation Paths

The toolkit currently supports three main automation patterns:

1. Terraform + PowerShell
2. Terraform + Ansible
3. Ansible-only

Terraform handles Azure resource provisioning. PowerShell and Ansible handle on-premises, guest OS, and post-provisioning tasks that Terraform does not cover well.

## Repository Layout

| Path | Purpose |
|------|---------|
| `config/` | Variable templates, schema assets, reports, and supporting configuration files |
| `pipelines/` | Reusable CI/CD samples for GitLab, GitHub Actions, and Azure DevOps |
| `repo-management/` | Plans, checklists, reports, helper scripts, and working artifacts for this repo |
| `scripts/` | PowerShell automation organized by deployment stage plus common helpers and validation tooling |
| `src/` | Source assets for `ansible/`, `arm-templates/`, `bicep/`, and `terraform/` |
| `tests/` | Test scaffolding and future automated validation suites |
| `tools/` | Standalone utilities such as planning and sizing helpers |

## Deployment Lifecycle Coverage

The script layout follows the Azure Local deployment lifecycle:

| Stage | Name | Scope |
|------:|------|-------|
| 02 | Azure Foundation | Landing zones, RBAC, networking, management infrastructure |
| 03 | On-Prem Readiness | Active Directory, hardware validation, network preparation |
| 04 | Cluster Deployment | Host preparation, OS configuration, Arc registration, cluster creation |
| 05 | Operational Foundations | Monitoring, backup, and operational services |
| 06 | Testing & Validation | Post-deployment checks and validation workflows |
| 07 | Validation & Handover | Handover and transition artifacts |
| 08 | Lifecycle Operations | Update, maintenance, and day-2 operations |

## Configuration Model

The repository is designed to be configuration-driven.

| Path | Purpose |
|------|---------|
| `config/variables/variables.example.yml` | Example deployment variable file |
| `config/variables/schema/` | Schema and validation assets for the variable system |
| `config/variables/scripts/` | Variable-management helper scripts |
| `config/variables/reports/` | Generated validation and drift reports |
| `scripts/common/utilities/helpers/config-loader.ps1` | PowerShell loader and export helpers for configuration data |

Where supported, automation should consume variables from the shared variable model rather than hardcoded values.

## Infrastructure and Automation Assets

| Area | Location | Notes |
|------|----------|-------|
| Ansible | `src/ansible/` | Roles, inventory, collections, and playbooks for on-prem and guest configuration |
| Terraform | `src/terraform/` | Backend bootstrap, reusable modules, and the Azure Local environment root module |
| Pipeline samples | `pipelines/` | CI/CD examples for multiple platforms |
| PowerShell deployment scripts | `scripts/deploy/` | Stage-based implementation scripts and orchestration |
| Validation scripts | `scripts/validation/` | Health checks and test tooling |

## Start Here

If you are new to this repository, start with these files:

| File | Why it matters |
|------|----------------|
| `CONTRIBUTING.md` | Contribution workflow, testing expectations, and coding conventions |
| `src/terraform/README.md` | Terraform structure and usage |
| `src/ansible/README.md` | Ansible structure and execution model |
| `pipelines/README.md` | CI/CD sample architecture and prerequisites |
| `repo-management/README.md` | Planning and governance layout for this repo |

## Standards and Governance

This repository does not use a repo-local documentation site as the source of truth.

Canonical standards are maintained centrally in the Azure Local docs repository and published through the Azure Local standards set. Use the central standards source for governance and conventions, and use this repository for implementation assets.

## Related Repositories

| Repo | Purpose |
|------|---------|
| [azurelocal.github.io](https://github.com/AzureLocal/azurelocal.github.io) | Central docs, standards, and shared governance source |
| [azurelocal-avd](https://github.com/AzureLocal/azurelocal-avd) | Azure Virtual Desktop on Azure Local |
| [azurelocal-sofs-fslogix](https://github.com/AzureLocal/azurelocal-sofs-fslogix) | SOFS + FSLogix solution assets |
| [azurelocal-loadtools](https://github.com/AzureLocal/azurelocal-loadtools) | Load generation and benchmarking tools |
| [azurelocal-vm-conversion-toolkit](https://github.com/AzureLocal/azurelocal-vm-conversion-toolkit) | VM conversion tooling |

## Quick Links

| Resource | Link |
|----------|------|
| Issues | [GitHub Issues](https://github.com/AzureLocal/azurelocal-toolkit/issues) |
| Contributing | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Changelog | [CHANGELOG.md](CHANGELOG.md) |
| License | [MIT](LICENSE) |
