# QA Tools

This folder contains the manual QA entrypoints for validating repository code before or after changes.

## What this folder covers

The QA scripts target the main automation surfaces in this repo:

- PowerShell under `scripts/`
- Terraform under `src/terraform/`
- Ansible under `src/ansible/`
- Bicep under `src/bicep/`
- ARM templates under `src/arm-templates/`
- Variable registry and variable files under `config/variables/`

## Files in this folder

| File | Purpose | Notes |
|------|---------|-------|
| `Install-QADependencies.ps1` | Installs or bootstraps QA prerequisites | Installs PowerShell modules, Terraform, Azure CLI, ARM TTK, and a WSL Ubuntu distro with Ansible packages when needed |
| `PSScriptAnalyzerSettings.psd1` | Shared rule configuration for PowerShell QA | Used by `Test-PowerShellScripts.ps1` |
| `Test-PowerShellScripts.ps1` | Parses all `.ps1` files and optionally runs PSScriptAnalyzer | Reports issues in the target repo scripts, not in the QA wrapper itself |
| `Test-TerraformCode.ps1` | Runs `terraform fmt -check` and `terraform validate` across Terraform directories | Cleans temporary `.terraform` state it creates during validation |
| `Test-AnsibleCode.ps1` | Runs full Ansible QA when available, or a Basic YAML/import validation fallback | Supports `Native`, `WSL`, or `Basic` execution modes |
| `Test-BicepCode.ps1` | Runs `az bicep build` and `az bicep lint` | Skips cleanly if no `.bicep` files exist |
| `Test-ArmTemplates.ps1` | Runs ARM TTK validation against ARM template JSON files | Skips cleanly if no ARM templates exist |
| `Test-VariableConfig.ps1` | Wraps the existing variable validation scripts into one QA entrypoint | Uses the existing `validate-registry.ps1` and `validate-variables.ps1` scripts |

## Recommended start point

If the machine is not already prepared, run:

```powershell
pwsh -File .\scripts\tools\qa\Install-QADependencies.ps1
```

You can also install a subset:

```powershell
pwsh -File .\scripts\tools\qa\Install-QADependencies.ps1 -PowerShell -Terraform
pwsh -File .\scripts\tools\qa\Install-QADependencies.ps1 -Ansible
pwsh -File .\scripts\tools\qa\Install-QADependencies.ps1 -Ansible -WslDistribution Ubuntu-24.04
```

## How to run each QA tool

### Test-PowerShellScripts.ps1

Validates PowerShell syntax using the PowerShell parser and optionally runs PSScriptAnalyzer.

Important parameters:

- `-Path` overrides the root path to scan.
- `-SettingsPath` overrides the analyzer settings file.
- `-SkipAnalyzer` runs only parser validation.

Example:

```powershell
pwsh -File .\scripts\tools\qa\Test-PowerShellScripts.ps1
pwsh -File .\scripts\tools\qa\Test-PowerShellScripts.ps1 -SkipAnalyzer
```

### Test-TerraformCode.ps1

Runs `terraform fmt -check` plus `terraform validate` for each directory containing Terraform files.

Important parameters:

- `-Path` overrides the Terraform root.
- `-SkipInit` skips `terraform init -backend=false` before validation.

Example:

```powershell
pwsh -File .\scripts\tools\qa\Test-TerraformCode.ps1
```

### Test-AnsibleCode.ps1

Runs collection installation, linting, and syntax-check validation for the Ansible content.

Important parameters:

- `-Path` overrides the Ansible root.
- `-SkipCollectionInstall` skips collection installation.
- `-SkipSyntaxCheck` skips playbook syntax validation.
- `-ExecutionMode Auto|Native|WSL|Basic` controls whether commands run directly on Windows, through WSL, or through the fallback basic validator.
- `-WslDistribution` selects the WSL distro to use for `WSL` mode.

Example:

```powershell
pwsh -File .\scripts\tools\qa\Test-AnsibleCode.ps1
pwsh -File .\scripts\tools\qa\Test-AnsibleCode.ps1 -ExecutionMode WSL
pwsh -File .\scripts\tools\qa\Test-AnsibleCode.ps1 -ExecutionMode WSL -WslDistribution Ubuntu-24.04
pwsh -File .\scripts\tools\qa\Test-AnsibleCode.ps1 -ExecutionMode Basic
```

Windows note:

- If native Ansible commands are not installed on Windows, the script can use WSL when Ansible is installed in the default distro.
- If neither native Ansible nor WSL is usable, `Basic` mode can still validate YAML parsing, imported playbook references, inventory parsing, collection requirements parsing, and role path references.

### Test-BicepCode.ps1

Runs Azure CLI Bicep build and lint checks against every `.bicep` file.

Important parameters:

- `-Path` overrides the Bicep root.

Example:

```powershell
pwsh -File .\scripts\tools\qa\Test-BicepCode.ps1
```

### Test-ArmTemplates.ps1

Runs ARM TTK against ARM template JSON files, excluding parameter files.

Important parameters:

- `-Path` overrides the ARM template root.

Example:

```powershell
pwsh -File .\scripts\tools\qa\Test-ArmTemplates.ps1
```

### Test-VariableConfig.ps1

Runs the existing variable registry and variable schema checks through one wrapper.

Important parameters:

- `-VariablesPath` overrides the variables file.
- `-RegistryPath` overrides the master registry file.
- `-SchemaPath` overrides the schema file.
- `-StrictUnknown` fails on unknown canonical variable paths.

Example:

```powershell
pwsh -File .\scripts\tools\qa\Test-VariableConfig.ps1
pwsh -File .\scripts\tools\qa\Test-VariableConfig.ps1 -StrictUnknown
```

## Dependency summary

- PowerShell QA requires `PSScriptAnalyzer`.
- Terraform QA requires the `terraform` CLI.
- Full Ansible QA requires `ansible-lint`, `ansible-playbook`, and `ansible-galaxy`.
- Basic Ansible QA requires Python with `PyYAML`.
- Bicep QA requires Azure CLI with Bicep support.
- ARM QA requires the `arm-ttk` PowerShell module.
- Variable config QA depends on Python plus the existing validation scripts already in the repo.