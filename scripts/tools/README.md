# Scripts Tools

This folder contains developer-facing meta-tools for working on the repository itself.
These scripts do not deploy Azure Local infrastructure. They help contributors create,
transform, and validate the scripts and automation code that live elsewhere in the repo.

## How this folder is organized

| Folder | Purpose | Use it when |
|--------|---------|-------------|
| `authoring/` | Script creation and script transformation helpers | You are creating a new script or converting an existing config-driven script into a standalone variant |
| `qa/` | Manual QA and validation tools for repo code | You want to validate PowerShell, Terraform, Ansible, Bicep, ARM, or variable config changes |

## Navigation guide

Start in this folder when your task is about the tooling around the repo, not about running a deployment.

- Go to `authoring/` if you need to scaffold a new script or generate a standalone copy of an existing script.
- Go to `qa/` if you need to run manual validation before committing or reviewing changes.

## Typical workflow

1. Create or refactor scripts with the tools in `authoring/`.
2. Install QA prerequisites with `qa/Install-QADependencies.ps1` if needed.
3. Run the relevant QA tool from `qa/` against the part of the repo you changed.

## Relationship to the top-level tools folder

Do not confuse `scripts/tools/` with the top-level `tools/` folder.

- `scripts/tools/` is for developer tooling that helps maintain repo code.
- `tools/` is for broader operator or workstation support assets.