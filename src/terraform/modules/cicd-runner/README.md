# cicd-runner

Self-hosted CI/CD runners on Azure VMs (or a Linux VM scale set), Linux or Windows, that register themselves with GitHub Actions, GitLab CI/CD or Azure Pipelines. This is the module that task 06 of [automation / 01-cicd-infra](https://azurelocal.cloud/) names.

The full guide (manual and pipeline use, network prerequisites, roles) is [`docs/cicd-infra-deployment.md`](../../../../docs/cicd-infra-deployment.md).

## What it creates

| Resource | Notes |
| --- | --- |
| Resource group | Optional (`create_resource_group`). Otherwise it must exist. |
| User-assigned managed identity | The runner signs in to Azure as this identity and reads its registration credential from Key Vault with it. |
| Role assignments | Only what you list: Contributor, RBAC Administrator (optionally limited by an ABAC condition), Azure Connected Machine Resource Administrator (Arc Run Command), Key Vault Secrets User, and any extra assignment. |
| VNet, subnet | Created, or you pass `existing_vnet` or `existing_subnet_id`. |
| Hub peering | Optional. Both halves; the hub half uses the `azurerm.hub` provider, or set `create_hub_side = false` when the network team owns it. |
| NSG | Nothing inbound from the internet. Outbound: Azure, HTTPS and HTTP to the internet (downloads), and your lab ranges. `purpose = "ztp"` adds inbound TCP 445 from `bmc_cidrs` only. |
| VMs or a scale set | Linux: cloud-init. Windows: Run Command. `data_disk_size_gb` adds a data disk for the ZTP media. |

## The registration token never touches Terraform

`registration_secret` holds names only (vault, secret). At first boot the machine asks the instance metadata service for a token for its managed identity, reads the secret from Key Vault, registers the runner, and runs it as a service. The credential is not a variable, is not in state and is not in `custom_data` or the Run Command script.

| Platform | What the secret holds |
| --- | --- |
| `github` | `kind = "pat"` (default): a PAT or App token that can create registration tokens (organization runners need the administration scope for self-hosted runners). The machine exchanges it for a one-hour registration token. `kind = "token"`: a registration token, which has usually expired by the time a machine boots. |
| `gitlab` | The runner authentication token (`glrt-...`). GitLab fixes the runner's tags when it creates the token, so set them there. |
| `azure_devops` | A PAT with Agent Pools (read, manage). `azure_devops_pool` must exist. Labels become capabilities (`ztp=true`). |

## Example

```hcl
module "runner" {
  source = "../../modules/cicd-runner"

  providers = {
    azurerm     = azurerm
    azurerm.hub = azurerm.hub
  }

  name_prefix         = "vm-runner-lnx"
  location            = "eastus"
  resource_group_name = "rg-runners-eus-01"

  os_type  = "linux"
  purpose  = "general"
  platform = "github"
  scm_url  = "https://github.com/example-org"

  registration_secret = {
    key_vault_id   = "/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>"
    key_vault_name = "<vault>"
    secret_name    = "github-runner-token"
  }

  admin_ssh_public_key  = "ssh-ed25519 AAAA..."
  vnet_name             = "vnet-devops-eus-01"
  vnet_address_space    = ["10.250.10.0/24"]
  subnet_name           = "snet-runner-eus-01"
  subnet_address_prefix = "10.250.10.0/26"

  contributor_scopes = ["/subscriptions/<id>/resourceGroups/<cluster-rg>"]
}
```

For the ZTP runner use `os_type = "windows"`, `purpose = "ztp"`, `bmc_cidrs`, `data_disk_size_gb = 512`. The module refuses a ztp runner that is not a Windows VM, or has no `bmc_cidrs`.

## Limits

- Windows runners are VMs only. The Windows bootstrap runs through Run Command, which scale sets do not support. A ZTP runner keeps its state on its own disk, so it must stay a single VM.
- The Windows administrator password is generated and is held in Terraform state (Windows needs one at creation). Keep the state backend private and use RBAC. `windows_admin_password_secret_name` also writes it to the vault.
- A VM scale set does not remove the registrations of instances that scale in. Delete stale runners on the platform, or use ephemeral runners.
- The service runs as `NT AUTHORITY\SYSTEM` (or another well-known account that needs no password).
- The hub half of the peering and the lab firewall change are cross-team work; see the guide.

## Tests

```powershell
cd src/terraform/modules/cicd-runner
terraform init -backend=false
terraform test
```

The tests use mocked providers and run `plan` only; they need no Azure sign-in.
