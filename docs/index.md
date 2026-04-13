---
title: Azure Local Toolkit
---

# Azure Local Toolkit

Primary automation repository for Azure Local deployment, configuration, validation, and lifecycle operations.

## What This Repo Contains

- Deployment and validation scripts across the full lifecycle
- Infrastructure-as-code sources for Terraform, Bicep, ARM templates, and Ansible
- CI/CD pipeline samples for GitHub Actions and Azure DevOps
- Config-driven variable handling and schema assets

## Supported Automation Paths

1. **Terraform + PowerShell** — Azure resource provisioning via Terraform; on-prem and guest OS tasks via PowerShell
2. **Terraform + Ansible** — Azure resource provisioning via Terraform; post-provisioning configuration via Ansible
3. **Ansible-only** — Full on-prem configuration without Azure resource provisioning

See the [README](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/README.md) for the full repository layout and usage guide.
