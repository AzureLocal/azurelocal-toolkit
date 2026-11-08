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

## The Azure Local route

```text
Hardware discovery -> ZTP -> OS configuration -> PRE-CLUSTER VERIFICATION GATE -> ARM Validate -> ARM Deploy -> day 2
```

| # | Step | Tool | Page |
|--:|------|------|------|
| 1 | Hardware discovery (optional; Dell iDRAC only in this phase) | `Invoke-HardwareDiscovery.ps1` | [idrac-management README](scripts/common/idrac-management/README.md) |
| 2 | ZTP: install the OS from Azure and register the machines with Azure Arc | [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) | its README |
| 3 | OS configuration | `Invoke-AzureLocalOsConfiguration.ps1` | [docs/os-configuration-and-arm-deployment.md](docs/os-configuration-and-arm-deployment.md) |
| 4 | Pre-cluster verification gate: a read-only check that every machine is ready for a cluster | the toolkit, watched by the Sonar Verification monitor | [see the gate note](#the-pre-cluster-verification-gate) |
| 5 | ARM Validate | `Invoke-AzureLocalArmDeployment.ps1 -Mode Validate` | [docs/arm-deployment-guide.md](docs/arm-deployment-guide.md) |
| 6 | ARM Deploy | the same script, `-Mode Deploy` | same |
| 7 | Day 2: logical networks, monitoring, backup, updates, handover | `scripts/deploy/04-cluster-deployment/phase-06-post-deployment`, `scripts/lifecycle` | the Azure Local docs |

[Sonar](https://github.com/AzureLocal/azurelocal-sonar) watches steps 2 to 6 read only.

### The pre-cluster verification gate

<!-- TODO(gate): the gate is being built on the branch feat/pre-cluster-verification-gate. When it is in main, replace this paragraph with its script name, what it checks and its exit codes, and link the Sonar Verification monitor. -->

The gate sits between OS configuration and ARM Validate and changes nothing. Until its page is published, the input to ARM Validate is the OS configuration report (`-OsConfigurationReport <report directory>`): a node whose report says it is not converged is not ready for a cluster.

### The Solution Builder Extension (SBE) is optional

The toolkit side-loads an SBE only when a person asks for it, by setting `hardware.sbe.delivery` to `winrm_copy` or `node_pull`. There is no default: with no `hardware.sbe` block, or `delivery` unset or `skip`, the OS configuration Sbe and Drivers steps are skipped, the ARM deployment passes no SBE value and the machines keep the OEM drivers already installed. See [the SBE section](docs/os-configuration-and-arm-deployment.md#sbe-the-oems-solution-builder-extension).
## Prerequisites

Everything below is checked in more detail, with who checks what, in [docs/os-configuration-and-arm-deployment.md](docs/os-configuration-and-arm-deployment.md) (Operator host, Azure roles, Key Vault secrets) and [docs/access-and-connectivity.md](docs/access-and-connectivity.md) (roles by scope, network paths).

| Need | Detail |
|------|--------|
| PowerShell | PowerShell 7.0 or later (7.4 or later recommended; tested on 7.6). Scripts carry `#Requires -Version 7.0`. Windows PowerShell 5.1 is not supported on the operator host. |
| Modules (operator host) | `powershell-yaml` (0.4.12 tested) to read `infrastructure.yml`; `Az.Accounts` (5.5 tested; `Connect-AzAccount` first); `Az.KeyVault` (6.6) for `keyvault://` secrets; `Az.Resources` (10.2) only to look up the Azure Local resource provider's object ID. Individual scripts add `Az.Network`, `Az.Compute`, `Az.Security`, `Az.OperationalInsights`, `Az.RecoveryServices` or `Az.Subscription` (the `#Requires -Modules` line of the script says which). The Azure CLI is not used by the OS configuration and ARM scripts. |
| Test and lint tools | Pester **5.9.1** (import it explicitly: `Import-Module Pester -RequiredVersion 5.9.1`; Pester 6 runs zero tests here) and PSScriptAnalyzer 1.25. Only to run `tests/` and the analyzer. |
| Active Directory tooling | The `ActiveDirectory`, `DnsServer` and `DhcpServer` modules (RSAT) only for the on-premises readiness scripts that name them. The OS configuration domain join does not need them on the operator host. |
| Operating system | Operator host: Windows with PowerShell 7 (a jump server on the management network), or a Linux runner for the pipeline form (WinRM from Linux needs the PSWSMan module). Nodes: the Azure Local OS, build 25398 or later. |
| Azure | Registered resource providers (Phase 02; `Microsoft.Insights` is needed or the diagnostics account validation fails); roles on the resource group: Azure Connected Machine Resource Administrator and Reader (OS configuration over Arc), Azure Stack HCI Administrator, Reader, Storage Account Contributor and the Key Vault roles (ARM Validate and Deploy), Key Vault Secrets User on each vault named. |
| Credentials | Never in a file. Every secret is a `keyvault://<vault>/<secret>` reference in `infrastructure.yml`; the scripts read it with the signed-in Az context. |
| Network and ports | Operator host to Azure over HTTPS (`management.azure.com`, `login.microsoftonline.com`, `*.vault.azure.net`; `raw.githubusercontent.com` on an ARM execute; `aka.ms` for an SBE manifest). To the nodes: WinRM TCP 5985 or 5986 (default), or none with `-Transport ArcRunCommand`. To each BMC: TCP 443 (Redfish, discovery). The full matrix is in [docs/access-and-connectivity.md](docs/access-and-connectivity.md). |
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
| `config/variables/` | **The master of every variable** ([README](config/variables/README.md)). `schema/master-registry.yaml` is edited by hand; the `infrastructure.yml` schema, the master and purpose templates and the variables reference are generated from it (`scripts/New-InfrastructureArtifacts.ps1`). Registry first: a new variable goes in the registry before anything uses it. |
| `config/variables/schema/` | The registry, the variables schema, the generated `infrastructure.schema.json` and per-purpose schemas |
| `config/variables/templates/` | Generated: `infrastructure.master.yml` (every variable), scenario templates, one template per tool (ztp, os-configuration, deployment, cicd-infra, monitoring, discovery) |
| `config/variables/examples/` | Worked `infrastructure.yml` examples (a full file, a ZTP-only file, one per scenario) and `variables.example.yml` |
| `config/variables/docs/` | How to fill in `infrastructure.yml`, the migration guide, the generated variables reference |
| `config/variables/scripts/` | Validators, the registry reader and the artifact generator |
| `config/variables/reports/` | Generated validation and drift reports |
| `config/infrastructure/` | Generated stubs (schema, two example files) for tools that read those paths in place, and pointers to the new places |
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
| [docs/os-configuration-and-arm-deployment.md](docs/os-configuration-and-arm-deployment.md) | Prerequisites and run guide for node OS configuration (Arc Run Command or WinRM) and ARM Validate/Deploy from infrastructure.yml: roles, secrets, AD, SAN, SBE, the ZTP hand-off, and the keys each step reads |
| [docs/access-and-connectivity.md](docs/access-and-connectivity.md) | Account access and network connectivity across ZTP, OS configuration, ARM Validate/Deploy, Sonar and a pipeline runner: roles by scope, network paths, why OS configuration uses Arc Run Command, and troubleshooting |
| [config/variables/docs/VARIABLES.md](config/variables/docs/VARIABLES.md) | Reference for every infrastructure.yml key (generated from the master registry) |

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
