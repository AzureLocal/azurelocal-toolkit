# Script roadmap for the deployment tasks

## Scope

The scripts under `scripts/deploy/<stage>/<phase>/<task>/` follow three rules:

- **PowerShell for every task**, in the task's `powershell/` folder.
- **Azure CLI only for tasks that act on Azure** (resources, Entra ID, RBAC, policy, Azure Arc, monitoring, the ARM deployment), in the task's `azurecli/` folder. A task that runs on a node, against on-premises Active Directory or DNS, against hardware or a BMC, or is operating system work has no `azurecli/` folder.
- **No Bash** for tasks.

Whether Azure CLI applies to a task is decided in one place: `scripts/deploy/common/TaskCatalogue.psd1`.

## What is outstanding

The generated table [docs/script-status.md](../docs/script-status.md) is the checklist. It lists every task folder with whether its PowerShell script and its Azure CLI script are built, not built or not applicable, and which tasks still need a decision on Azure CLI. Regenerate it with `scripts/deploy/common/New-DeployScriptStatus.ps1`.

A script that is not written yet is a placeholder. Running a placeholder prints `NOT IMPLEMENTED`, changes nothing and ends with exit code 3.

## Acceptance criteria for a script that replaces a placeholder

- [ ] It replaces the placeholder file (delete the placeholder; do not keep both).
- [ ] It starts with `#Requires -Version 7.0`, `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`, and has comment-based help.
- [ ] It reads its settings from `infrastructure.yml` where applicable.
- [ ] It supports `-WhatIf` where it changes something, and is safe to run again.
- [ ] It is tested (Pester, with the Azure and node calls replaced), and tested against a reference environment before the task is called built.
- [ ] `scripts/deploy/common/New-DeployScriptStatus.ps1` is run and the table is committed.
