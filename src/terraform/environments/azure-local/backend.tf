# =============================================================================
# Azure Local Environment — Backend Configuration
# =============================================================================
# Update values from the output of the backend bootstrap module.
# =============================================================================

terraform {
  backend "azurerm" {
    resource_group_name  = "rg-iic-tfstate-lab"
    storage_account_name = "stiictfstatelab"
    container_name       = "tfstate"
    key                  = "azure-local.tfstate"
  }
}
