# =============================================================================
# CI/CD infrastructure - remote state
# =============================================================================
# The settings are not in this file. Pass them at init:
#   terraform init -backend-config=backend.hcl
# See backend.hcl.example. The state holds the generated Windows administrator
# password, so keep the container private and grant it by RBAC (Storage Blob
# Data Contributor), not by account key.
# =============================================================================

terraform {
  backend "azurerm" {}
}
