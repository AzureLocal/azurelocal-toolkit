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
terraform plan -var-file=D:\work\iac\terraform\azure-local\terraform.tfvars.json -var-file=extra.tfvars -out=tfplan
terraform apply tfplan
```

`extra.tfvars` is a copy of `terraform.tfvars.example`: the settings that `infrastructure.yml` has no key for yet (NSG rules, Key Vault IP ranges, policy assignments). A secret is never in a file. The generator writes `not-written.txt` next to the variable file and names the environment variable that supplies each one:

```powershell
$env:TF_VAR_vm_admin_password = '<resolve landing_zone.virtual_machines[0].admin_password>'
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

## Remote state

The backend blocks are empty (`backend "azurerm" {}`). The settings come from `backend.hcl`, which the generator writes from `devops.state`. There is no key and no SAS token: sign-in is by Microsoft Entra ID.

## Format and validate

```powershell
terraform fmt -check -recursive src/terraform
cd src/terraform/environments/azure-local; terraform init -backend=false; terraform validate
```
