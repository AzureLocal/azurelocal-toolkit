# Authoring Tools

This folder contains script authoring helpers used to create or transform scripts in this repository.

## Files in this folder

| File | Purpose | Key prerequisites |
|------|---------|-------------------|
| `New-ScriptFromTemplate.ps1` | Generates a new script from a template aligned with repo conventions | PowerShell 7 |
| `Convert-ToStandaloneScript.ps1` | Converts a config-driven script into a standalone script with inline values | PowerShell 7, `powershell-yaml` |

## When to use these tools

- Use `New-ScriptFromTemplate.ps1` when you are starting a new script and want a consistent structure.
- Use `Convert-ToStandaloneScript.ps1` when you already have a config-driven script and need a portable standalone copy.

## New-ScriptFromTemplate.ps1

Creates a new script skeleton for one of the supported script types:

- `PowerShell`
- `AzurePowerShell`
- `AzureCliPowerShell`
- `AzureCliBash`
- `InvokeScript`

### Common parameters

- `-ScriptType` chooses the template family.
- `-Name` sets the generated script name.
- `-Description` sets the help text.
- `-OutputPath` chooses where the file is written.
- `-Standalone` generates a standalone PowerShell variant with inline configuration.

### Example

```powershell
pwsh -File .\scripts\tools\authoring\New-ScriptFromTemplate.ps1 `
  -ScriptType AzurePowerShell `
  -Name New-AzKeyVault `
  -Description "Creates a Key Vault" `
  -OutputPath .\scratch
```

## Convert-ToStandaloneScript.ps1

Reads a config-driven PowerShell script, inspects its `$config` references, and writes a standalone script with inline variables.

### Common parameters

- `-SourceScript` points to the original script.
- `-ConfigPath` points to the YAML config file to read.
- `-OutputPath` optionally overrides the generated output path.

### Example

```powershell
pwsh -File .\scripts\tools\authoring\Convert-ToStandaloneScript.ps1 `
  -SourceScript .\scripts\deploy\example.ps1 `
  -ConfigPath .\config\variables\variables.example.yml `
  -OutputPath .\scratch\example-standalone.ps1
```

## Notes

- `Convert-ToStandaloneScript.ps1` requires the `powershell-yaml` module to be installed.
- These scripts are authoring helpers only. They do not replace the manual QA tools in `..\qa\`.