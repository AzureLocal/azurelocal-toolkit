# Repo intent — azurelocal-toolkit

**Primary automation repository for Azure Local deployment, configuration, validation, and lifecycle operations.**

## What this repo is

The operational toolkit for building and running Azure Local automation:
deployment/validation scripts across the full lifecycle, IaC sources for
Terraform, Bicep, ARM templates, and Ansible, CI/CD pipeline samples (GitLab,
GitHub Actions, Azure DevOps), config-driven variable handling, and
repo-management artifacts. Per its own README: "Treat the contents as
implementation assets and working automation, not as a polished documentation
site."

## Supported automation paths

1. Terraform + PowerShell
2. Terraform + Ansible
3. Ansible-only

Terraform handles Azure resource provisioning; PowerShell/Ansible handle
on-premises, guest OS, and post-provisioning tasks Terraform doesn't cover well.

## How it relates to other repos

- The shared automation-pattern reference every other `azurelocal-*` deployment
  tool builds on (azurelocal-avd, azurelocal-sofs-fslogix, azurelocal-sql-ha, etc.)

## Status

Active — the primary/central automation toolkit for the org.
