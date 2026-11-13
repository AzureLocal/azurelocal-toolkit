# =============================================================================
# Azure Local Environment — Backend Configuration
# =============================================================================
# The settings are not in this file. New-IacVariableFiles.ps1 writes them to
# terraform/azure-local/backend.hcl from devops.state of infrastructure.yml:
#   terraform init -backend-config=backend.hcl
# No key and no SAS token: sign-in is by Entra ID.
# =============================================================================

terraform {
  backend "azurerm" {}
}
