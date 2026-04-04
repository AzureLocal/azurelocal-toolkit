# Tools

This top-level folder contains general-purpose support assets for working with the solution, not the developer meta-tools used to maintain repo code.

## What belongs here

Use this folder for workstation setup helpers, planning artifacts, calculators, and similar operator or project-support assets.

Do not confuse this folder with `scripts/tools/`:

- `tools/` is for broader support assets used around the solution.
- `scripts/tools/` is for repo-maintenance tools such as script authoring helpers and QA entrypoints.

## Folder layout

| Item | Purpose |
|------|---------|
| `install-tools.ps1` | Bootstrap script for installing a baseline workstation toolset and Windows features |
| `planning/` | Pre-deployment planning assets and calculators |

## How to navigate this folder

- Use `install-tools.ps1` when setting up or refreshing a workstation used to work with Azure Local tooling.
- Use `planning/` when doing sizing, pre-deployment estimation, or design-phase work.

## install-tools.ps1

This script installs a baseline set of workstation tools and Windows Server administration features.

### What it installs

- Visual Studio Code
- PowerShell
- Git
- Azure CLI
- GitHub Desktop
- PuTTY
- kubectl
- WinSCP
- Helm
- Az PowerShell module
- RSAT and related Windows features such as clustering, Hyper-V, AD DS, AD CS, DHCP, and DNS tools

### Important notes

- It changes machine state and should be treated as a workstation bootstrap script.
- Some steps may require an elevated PowerShell session.
- The script is aimed at Windows environments where `winget` and Windows feature installation are available.

### Example

```powershell
pwsh -File .\tools\install-tools.ps1
```
