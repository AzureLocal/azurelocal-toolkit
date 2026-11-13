# Secret references and providers

No secret value is ever written in `infrastructure.yml`, in a log, in an error message or in a report. A key that needs a secret holds a **reference**. One resolver reads it: `scripts/common/secrets/AzlSecret.psm1`. No script names a vault, a directory or a command; they all come from the master file.

## The four reference forms

A reference names its own provider in its scheme. One file can mix providers.

| Form | Provider | What the part after `://` is |
| --- | --- | --- |
| `keyvault://<vault>/<secret>` | Azure Key Vault (the default) | The vault, which must be listed under `key_vaults`, and the secret name. |
| `env://<VARIABLE_NAME>` | Environment variable | The name of a variable of the process. Letters, digits and `_`. |
| `file://<name>` | File | The name of a file in `secrets.file.directory`. |
| `command://<name>` | Custom command | The name passed to the command in `secrets.command`. |

`<name>` for `file://` and `command://`: letters, digits, `_` and `-`, starting with a letter or digit, up to 100 characters, and one optional extension of up to 10 letters or digits (`lcm-password`, `lcm-password.txt`). It cannot hold a slash, a backslash, a colon, a space or `..`.

A text that is not one of these four forms is not a reference. The validator refuses it, and no tool uses it as a value. This is how a password written by mistake is caught.

### Why a name and not a path or a command

A path such as `C:\secrets\x.txt` has a drive letter, backslashes and spaces, which do not survive a URI. The larger reason is safety. A reference lives in a file that people share. If it held a path, anyone who edits the file could make a machine read any file. If it held a command, anyone who edits the file could make a machine run it. So the directory and the command are **settings of the machine's own master file** (the `secrets` section), and a reference only picks a name inside them.

## The `secrets` section

All keys are optional. Add the ones the providers you use need.

| Key | Default | Meaning |
| --- | --- | --- |
| `secrets.provider` | `keyvault` | The provider used to build a new reference when the caller does not name one (`New-AzlSecretReference`). It never changes how an existing reference is read. |
| `secrets.file.directory` | none | The absolute path of the directory that holds the secret files. Needed by `file://`. |
| `secrets.command.executable` | none | The program to start: a command name on the path, or an absolute path. Needed by `command://`. |
| `secrets.command.arguments` | none | The arguments, one list item each. `{name}` in an item is replaced by the name in the reference. At least one item must hold `{name}`. |
| `secrets.command.timeout_seconds` | `30` | How long the command may run (1 to 300). After that it is stopped and the read fails. |

Rule `AZL-054` reports a `file://` reference without `secrets.file.directory` and a `command://` reference without the executable and an argument that holds `{name}`.

```yaml
key_vaults:
  - name: kv-iic-mgmt-01
    subscription_id: 00000000-0000-0000-0000-000000000000
    resource_group: rg-iic-mgmt-01
secrets:
  provider: keyvault
  file:
    directory: C:\ProgramData\iic-secrets
  command:
    executable: iic-secret-tool
    arguments: [get, "{name}"]
    timeout_seconds: 30
identity:
  local_admin:
    password: keyvault://kv-iic-mgmt-01/local-admin-password
  active_directory:
    lcm_user:
      password: file://lcm-password
```

## What each provider does

**Azure Key Vault.** Uses `Get-AzKeyVaultSecret` from the Az.KeyVault module. There is no Azure CLI fallback. The vault must be listed under `key_vaults`; otherwise it is an input error and nothing is sent to Azure. The signed-in identity needs to read secrets on the vault (Key Vault Secrets User). The resolver never signs in: run `Connect-AzAccount` first. The errors say which of these happened: not signed in, vault not found, secret not found, access denied.

**Environment variable.** The variable must be set and not empty.

**File.** One secret per file. UTF-8, with or without a byte order mark. The trailing line breaks are removed and nothing else is changed (spaces are part of the secret). At most 256 KiB. The file must be a plain file inside the directory; a link is refused. On Windows the resolver writes a warning when Everyone, Users or Authenticated Users can read the file. On Linux and macOS it warns when group or other can. The warning names the file, never its content. Give the file to the account that runs the toolkit and nobody else.

**Command.** The executable is started directly with the argument list. There is no shell, no command string and no `Invoke-Expression`. Standard input is closed. Standard output is the secret (trailing line breaks removed). If the command ends with a code other than 0, the read fails with the exit code only; neither its output nor its error text is ever shown, because a command can print a secret there in a form that cannot be recognised. If the command, or the reading of its output, does not finish within `timeout_seconds`, it is stopped. Pre-flight checks run the command, because that is the only way to know it works.

## Using the resolver in a script

```powershell
Import-Module ./scripts/common/secrets/AzlSecret.psm1
$infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation

# Where a SecureString or a PSCredential is accepted:
$secure = Get-AzlSecretValue -Reference (Get-AzlInfrastructureValue -Infrastructure $infra -Path 'identity.local_admin.password') -Infrastructure $infra

# Only where the value must go into a request body or a protected parameter:
$plain = Get-AzlSecretPlainText -Reference $reference -Infrastructure $infra

# Pre-flight: can it be read? No value comes back.
Test-AzlSecretReference -Reference $reference -Infrastructure $infra -Detailed

# Which provider?
Get-AzlSecretProvider $reference
```

Errors are exceptions. `$_.Exception.Data['AzlSecretError']` holds the category (`InvalidReference`, `VaultNotListed`, `NotConfigured`, `NotSignedIn`, `VaultNotFound`, `SecretNotFound`, `AccessDenied`, `KeyVaultError`, `NotSet`, `FileNotFound`, `FileUnsafe`, `CommandFailed`, `CommandTimeout`, `EmptySecret`, `TooLarge`, `Unexpected`) and `$_.Exception.Data['AzlExit']` the exit code to use: 2 for a wrong or missing input or setting, 1 for a failed call.

### Every reader uses it

No script reads a secret by itself. A script does not call `Get-AzKeyVaultSecret` or `az keyvault secret show`, does not parse a `keyvault://` text, and does not name a vault or a secret. It reads a reference from the infrastructure file and gives it to the resolver. The scripts of phases 02 to 06 keep a small helper (`Resolve-KeyVaultRef`) that calls the resolver, logs a warning without a value and returns `$null`, so the script can still ask for a credential. Modules use `Get-AzlSecret` (a wrapper of `Get-AzlSecretPlainText` in `AzlAzure.psm1`) or `New-AzlSecretResolver` for the `-SecretResolver` parameters. There is no Azure CLI fallback.

The Arc registration scripts (phase 04, tasks 01 and 02) read the secret of the automation identity from `devops.authentication.client_secret`. When the file signs in with OIDC or a managed identity there is no such secret; the registration script then asks for it, and the pre-registration check warns.

The scripts that write secrets or create vaults (`Add-KeyVaultCredentials.ps1` and `Deploy-KeyVaults.ps1`) keep their own Key Vault calls. `tests/secrets/ScriptsUseResolver.Tests.ps1` lists them and fails when any other script reads a secret itself.

## Rules that hold for every provider

- The value is returned only as a `SecureString`, or as a string from `Get-AzlSecretPlainText` for the few callers that must put it in a request body.
- The value is never written to a file, a log, an error message, the verbose, debug, information or warning streams, or a result object. Only references appear in messages. A text that is not a reference is never repeated, only its length.
- The module has no `Invoke-Expression`, no `Write-Host` of values, no `ConvertFrom-SecureString` and no `ConvertTo-SecureString -AsPlainText`. A test checks this.
- When in doubt, the resolver refuses with a message.

## The ARM deployment

The ARM deployment (`Invoke-AzlArmDeployment`) reads each secret parameter on the machine that runs it, through this resolver, and sends the value as the value of a `securestring` template parameter. Because the value is read locally, **every provider works** there.

One option is different. `-SecretMode KeyVaultReference` (`New-AzureLocalArmParameters.ps1`, `ConvertTo-AzlArmParameterFile`) writes a parameter file in which Azure Resource Manager itself reads the secret from Key Vault; the value never reaches this machine. Azure Resource Manager can read Key Vault only. So with `env://`, `file://` or `command://` this option **refuses with a message** instead of guessing. Use the default `Placeholder` mode: the file holds `null` for the secrets and the deployment fills them from the resolver.

The pre-cluster check `KeyVaultSecrets` proves each reference with the resolver. It keeps its name. With the run setting `secretMode` set to `KeyVaultReference` (`-Settings @{ secretMode = 'KeyVaultReference' }`, the same choice as the parameter file option) it fails for a reference that is not `keyvault://`, with the reason "Azure Resource Manager can read only keyvault:// references". The default is `Placeholder`.

### The pre-cluster verification gate

The gate checks (`AZ-010`, `AZ-012`, `AZ-013`) treat a reference of any of the four providers as valid:

- `AZ-010` checks that the vault is listed under `key_vaults` and exists, for a `keyvault://` reference only. A file whose references are all `env://`, `file://` or `command://` has no vault to check; the check is not applicable. A text that is not a reference fails (only its length is shown).
- `AZ-012` reads each reference with the resolver. A `keyvault://` reference goes through the adapter member `GetKeyVaultSecret`, the others through `TestSecretReference`. No value is returned or shown.
- `AZ-013` compares the vault's user name secret with `identity.local_admin.username`. It is not applicable when the password is not a `keyvault://` reference (it has no vault) and `identity.local_admin.username_secret` is not set.
- With `secretMode` `KeyVaultReference`, `AZ-010`, `AZ-011` and `AZ-012` fail for a deployment secret (`identity.local_admin.password`, `identity.active_directory.lcm_user.password`) that is not `keyvault://`. This is a rule of Azure Resource Manager, not of the toolkit.

## Other tools

`azurelocal-ztp`, Sonar and Trailwright read the same file with their own code. Until they use this resolver, they understand `keyvault://` only. Do not use another provider for a secret that one of them reads.
