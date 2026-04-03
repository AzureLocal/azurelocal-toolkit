# Terraform Modules for Azure Local

Six Terraform modules that provision the Azure foundation for Azure Local deployments. These modules handle management groups, networking, identity, monitoring, security, and management VMs.

## Quick Start

```bash
# 1. Bootstrap remote state
cd src/terraform/backend
terraform init
terraform apply -var="subscription_id=<your-sub>" -var="org_code=iic"

# 2. Generate terraform.tfvars from variables.yml
pwsh -Command "
  . scripts/common/utilities/helpers/config-loader.ps1
  \$config = Get-Config -ConfigPath 'config/variables/variables.yml'
  Export-TerraformTfvars -Config \$config -OutputPath 'src/terraform/environments/azure-local/terraform.tfvars'
"

# 3. Deploy
cd src/terraform/environments/azure-local
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Structure

```
src/terraform/
├── backend/                    # State backend bootstrap
│   ├── main.tf                 # Storage Account + Container
│   ├── variables.tf
│   └── outputs.tf
├── modules/
│   ├── landing-zone/           # Management groups, resource groups
│   ├── networking/             # VNet, subnets, NSGs, VPN, Bastion, NAT
│   ├── identity/               # Key Vault, RBAC, managed identities
│   ├── monitoring/             # Log Analytics, solutions, alerts
│   ├── security/               # Defender for Cloud, Azure Policy
│   └── compute/                # Management VMs (DC, Jumpbox, WAC, Syslog)
├── environments/
│   └── azure-local/            # Root module orchestrating all child modules
│       ├── main.tf
│       ├── providers.tf
│       ├── backend.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── terraform.tfvars.example
└── README.md
```

## Modules

### landing-zone
Management group hierarchy (Root → Platform → Identity/Connectivity/Management/Security, Landing Zones) and resource groups via `for_each`.

### networking
Hub VNet with dynamic subnet and NSG creation. NSG rules are flattened from nested `nsg.rules[]`. VPN Gateway, NAT Gateway, and Bastion Host are all conditional via `enable_*` booleans.

### identity
Platform Key Vault (RBAC authorization, diagnostics) and optional Azure Local cluster Key Vault. SPN role assignments at subscription and resource group scope. Managed identities for workloads.

### monitoring
Log Analytics workspace with configurable retention. Solutions (Updates, Security). Action group for critical alerts. Optional cluster health metric alert.

### security
Defender for Cloud plans via `for_each`. Azure Policy assignments at subscription and resource group level. Security contact configuration.

### compute
Management VM shells (guest OS configuration is handled by Ansible or PowerShell). Filters VMs by `deployment_target == "azure"`. Admin password stored in Key Vault.

## Providers

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    random  = { source = "hashicorp/random",  version = "~> 3.0" }
  }
}
```

## Remote State

Backend uses Azure Storage with blob lease locking:

```hcl
backend "azurerm" {
  resource_group_name  = "rg-iic-terraform-01"
  storage_account_name = "stiictfstatelab"
  container_name       = "tfstate"
  key                  = "azurelocal.tfstate"
}
```

## Variables

All variables flow from `config/variables/variables.yml` via `Export-TerraformTfvars`. See `terraform.tfvars.example` for the full IIC example with all supported variables.
