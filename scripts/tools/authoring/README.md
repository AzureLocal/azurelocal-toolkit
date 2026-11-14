# Authoring Tools

This folder contains the script authoring helper used to create scripts in this repository.

## Files in this folder

| File | Purpose | Key prerequisites |
|------|---------|-------------------|
| `New-ScriptFromTemplate.ps1` | Generates a new script from the template of the toolkit (`-InfrastructureFile`, registered keys, exit codes 0, 1 and 2, no prompt) | PowerShell 7 |

`Convert-ToStandaloneScript.ps1` is retired. It baked the values of a file into a copy of a script as inline variables, which is the opposite of the rule that
the registry is the only master and that no script carries a value a deployment chooses. A script that has to run where the repository is not available
takes its values as parameters from the caller.

## New-ScriptFromTemplate.ps1

Creates a new script skeleton for one of the supported script types:

- `PowerShell`
- `AzurePowerShell` (checks the sign-in and the tenant of `azure.tenant_id`; never signs in)
- `AzureCliPowerShell` (checks that `az` is signed in to that tenant; never signs in)
- `InvokeScript`

The skeleton has `-InfrastructureFile` (mandatory) and `-LogPath`, `SupportsShouldProcess`, the standard header lines, and loads the file with
`Import-AzlInfrastructure`. It has no value of a deployment. Add the keys the script reads to `config/variables/schema/master-registry.yaml` first, then
read them with `Get-AzlInfrastructureValue`.

### Common parameters

- `-ScriptType` chooses the template family.
- `-Name` sets the generated script name.
- `-Description` sets the help text. It is required: the tool has no default text.
- `-OutputPath` chooses where the file is written.

### Example

```powershell
pwsh -File .\scripts\tools\authoring\New-ScriptFromTemplate.ps1 `
  -ScriptType AzurePowerShell `
  -Name New-AzKeyVault `
  -Description "Creates a Key Vault" `
  -OutputPath .\scratch
```

## Notes

- This script is an authoring helper only. It does not replace the manual QA tools in `..\qa\`.
