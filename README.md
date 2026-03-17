# Azure Local Toolkit

!!! warning "Under Active Development"
    This repository is a work in progress. Scripts, templates, and automation are **not guaranteed to work** at this time. Use at your own risk and expect breaking changes.

Platform automation toolkit for **Azure Local** — deployment scripts, validation suites, and config management covering the full deployment lifecycle.

---

## What's Inside

| Directory | Description |
|-----------|-------------|
| **[scripts/](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/scripts)** | 200+ PowerShell scripts organized by deployment stage (02–08), plus common modules, validation, handover, lifecycle, and tools |
| **[config/](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/configs)** | Master infrastructure config template, ARM templates, and variable registry |
| **[tools/](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/tools)** | Planning utilities (S2D capacity calculator) |
| **[tests/](https://github.com/AzureLocal/azurelocal-toolkit/tree/main/tests)** | Test infrastructure (future Pester suites) |

## Deployment Stages

The toolkit follows a structured deployment lifecycle:

| Stage | Name | Scripts |
|-------|------|---------|
| 02 | Azure Foundation | Landing zones, RBAC, VNet, management infrastructure |
| 03 | On-Prem Readiness | Active Directory, hardware validation, network prep |
| 04 | Cluster Deployment | Hardware → OS → Arc registration → cluster creation |
| 05 | Operational Foundations | SDN, monitoring, backup configuration |
| 06 | Testing & Validation | Automated test suites |
| 07 | Validation & Handover | Customer transfer and sign-off |
| 08 | Lifecycle Operations | Updates, maintenance, day-2 operations |

## Configuration Architecture

The toolkit uses a config-driven approach:

- **`config/infrastructure.yml`** — Master configuration template with 14 sections covering Azure tenant, networking, compute, storage, security, and more
- **`config/variables.example.yml`** — Azure Local-specific variables for deployment

## Related Repositories

| Repo | Purpose |
|------|---------|
| [azurelocal-sofs-fslogix](https://github.com/AzureLocal/azurelocal-sofs-fslogix) | SOFS + FSLogix solution for AVD profile containers |
| [aurelocal-avd](https://github.com/AzureLocal/aurelocal-avd) | Azure Virtual Desktop on Azure Local |
| [azurelocal-loadtools](https://github.com/AzureLocal/azurelocal-loadtools) | Load testing and benchmarking tools |
| [azurelocal-vm-conversion-toolkit](https://github.com/AzureLocal/azurelocal-vm-conversion-toolkit) | VM Gen1 → Gen2 conversion |

---

## Quick Links

| Resource | Link |
|----------|------|
| Documentation | [azurelocal.github.io/azurelocal-toolkit](https://azurelocal.github.io/azurelocal-toolkit/) |
| Issues | [GitHub Issues](https://github.com/AzureLocal/azurelocal-toolkit/issues) |
| Contributing | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Changelog | [CHANGELOG.md](CHANGELOG.md) |
| License | [MIT](LICENSE) |
