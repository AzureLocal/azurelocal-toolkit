# Terraform for Azure Local

Terraform modules that build the Azure foundation for an Azure Local instance: management groups, networking, identity, monitoring, security and management VMs. They are an alternative route to the PowerShell scripts in `scripts/deploy` for the same tasks. Do not run both routes for the same resource.

The values come from `infrastructure.yml`. The code has no values of its own for the facts of an environment (names, subscriptions, addresses). The registry says, for every variable, which key it comes from.

## Quick start

```powershell
# 1. Write the variable files from infrastructure.yml. Keep the output folder out of the repository.
pwsh config/variables/scripts/New-IacVariableFiles.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory D:\work\iac

# 2. Bootstrap the remote state (the names come from devops.state).
cd src/terraform/backend
terraform init
terraform apply -var-file=D:\work\iac\terraform\backend\terraform.tfvars.json

# 3. Deploy the Azure foundation.
cd ../environments/azure-local
terraform init -backend-config=D:\work\iac\terraform\azure-local\backend.hcl
terraform plan -var-file=D:\work\iac\terraform\azure-local\terraform.tfvars.json -out=tfplan
terraform apply tfplan
```

Every value comes from `infrastructure.yml` (a key the file leaves out gets its registry default); a variable with a default is a setting of the code (class c in the registry). Add no `.tfvars` file of your own: a later `-var-file` overrides the generated values. A secret is never in a file. The generator writes `not-written.txt` next to the variable file and names the environment variable that supplies each one:

```powershell
$env:TF_VAR_vm_admin_password = '<resolve landing_zone.virtual_machines[].admin_password>'
$env:TF_VAR_vpn_shared_key    = '<resolve landing_zone.connectivity.vpn_gateway.site_to_site[0].shared_key>'
```

Run `terraform plan` yourself and read it before `apply`. This repository's tests never run Terraform.

## Where each variable comes from

Every variable declared in a `variables.tf` here is registered in `config/variables/schema/master-registry.yaml` (`tools.terraform.variables`, and `tools.cicd_infra.terraform_variables` for the runners) with its class, source, `infrastructure_key`, `form` and `target`. See [Terraform and Ansible variable files](../../config/variables/docs/infrastructure-file.md#terraform-and-ansible-variable-files-schema-5617). A test fails when a variable is declared and not registered, or registered and not declared.

## Structure

```
src/terraform/
├── backend/                    # State storage bootstrap (devops.state)
├── modules/
│   ├── landing-zone/           # Management groups, resource groups
│   ├── networking/             # VNet, subnets, NSGs, VPN gateway, Bastion, NAT gateway
│   ├── identity/               # Key Vaults, role assignments, managed identities
│   ├── monitoring/             # Log Analytics workspace and action group
│   ├── security/               # Defender for Cloud security contact, Azure Policy
│   ├── compute/                # Management VMs
│   └── cicd-runner/            # Self-hosted CI/CD runners (Linux, Windows, ZTP)
└── environments/
    ├── azure-local/            # Root module that calls the modules above
    └── cicd-infra/             # CI/CD runners (task 06 of automation / 01-cicd-infra)
```

## Modules

### landing-zone
The fixed Azure landing zone hierarchy (root, platform with identity, connectivity, management and security, and landing zones) and the resource groups. The group names come from `landing_zone.management_groups[]`: the `role` of each group says which part of the hierarchy it is.

### networking
The hub VNet with its subnets, NSGs and their rules, a NAT gateway, a VPN gateway with its site-to-site connection and Azure Bastion. The gateway and Bastion subnets use the keys `gateway` and `bastion`.

### identity
The platform Key Vault and, when named, the Azure Local cluster Key Vault; role assignments of the deployment identity; user-assigned managed identities.

### monitoring
The Log Analytics workspace and the action group with an email receiver for each notification address. It creates no alert rule, no data collection endpoint and no data collection rule: Azure Monitor work in this toolkit is the workspace, the data collection endpoint, the Azure Monitor Agent extension and the Azure Local Insights association, and the PowerShell scripts do the last three.

### security
The Microsoft Defender for Cloud security contact and Azure Policy assignments. It turns on no paid Defender plan.

### compute
Management VM shells. Guest configuration is done by Ansible or PowerShell. The admin password goes to the platform Key Vault.

### cicd-runner
Self-hosted runners for GitHub Actions, GitLab CI/CD or Azure Pipelines. See [`modules/cicd-runner`](modules/cicd-runner) and [`environments/cicd-infra`](environments/cicd-infra).

## Providers

Each module declares `azurerm ~> 4.0` (the identity module also `azuread ~> 3.0`) in its own `required_providers` block. The provider versions are not variables: Terraform does not allow that.

## Moving an existing landing zone state

Before registry 5.0.62 (owner directive D121) the landing-zone module had one resource per role of the fixed hierarchy: `azurerm_management_group.root`, `platform`, `identity`, `connectivity`, `management`, `security` and `landing_zones`, and the subscription associations `connectivity[0]`, `identity[0]`, `management[0]`, `security[0]` and `azure_local[0]`. The module now builds the tree from `landing_zone.management_groups[]` (`name` and `parent`) and keys every group by its name, level by level (`level0["<name>"]` to `level5["<name>"]`), and every association by the subscription's name (`subscriptions["<name>"]`). On a state written by the old module, `terraform plan` would destroy every management group and create it again. Move the state first:

```powershell
# 1. List the moves for this environment (reads infrastructure.yml only; changes nothing). Keep the file out of the repository.
pwsh config/variables/scripts/New-TerraformStateMoveList.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath D:\work\iac\state-moves.txt

# 2. In the root module, with the generated backend, check what the state holds.
cd src/terraform/environments/azure-local
terraform init -backend-config=D:\work\iac\terraform\azure-local\backend.hcl
terraform state list module.landing_zone

# 3. Back up the state, run each command of state-moves.txt, then plan.
terraform state pull > D:\work\iac\azure-local.tfstate.backup
terraform state mv 'module.landing_zone.azurerm_management_group.root' 'module.landing_zone.azurerm_management_group.level0["mg-iic"]'
# ... the other lines of state-moves.txt ...
terraform plan -var-file=D:\work\iac\terraform\azure-local\terraform.tfvars.json
```

What the list holds, per old address (the script computes the level of each group the way the module does):

| Old address (in `module.landing_zone`) | New address | Kind |
|---|---|---|
| `azurerm_management_group.<role>` | `azurerm_management_group.level<N>["<name of the group with that role>"]` | Move |
| `azurerm_management_group_subscription_association.<role>[0]` (connectivity, identity, management, security) | `...association.subscriptions["<name of the subscription with that role>"]` | Move, when that subscription has an `id` and a `management_group` |
| `azurerm_management_group_subscription_association.azure_local[0]` | `...association.subscriptions["<name of the subscription whose id is azure.subscription_id>"]` | Move, as above |
| an association the old module never made (its subscription had no id) | none | None: no command |
| an association the module no longer makes | none | Forget: `terraform state rm`, which keeps the association in Azure |
| a role no group of the file has | none | Check: no command; `terraform state list` says whether the old state has it |

Run the lines in bash, or in PowerShell 7.3 or later (it passes the double quotes inside the single-quoted address on to `terraform`). Skip a line whose old address `terraform state list` does not show. After the moves `terraform plan` must show no management group and no association to destroy; it may show an in-place change (a display name, or an association that now sits under the group `management_group` names). Restore the backup with `terraform state push` if it does not. The script ends with exit code 2 when two groups (or two subscriptions) share a role, or when a parent chain loops or is deeper than six levels.

## Remote state

The backend blocks are empty (`backend "azurerm" {}`). The settings come from `backend.hcl`, which the generator writes from `devops.state`. There is no key and no SAS token: sign-in is by Microsoft Entra ID.

## Format and validate

```powershell
terraform fmt -check -recursive src/terraform
cd src/terraform/environments/azure-local; terraform init -backend=false; terraform validate
```
