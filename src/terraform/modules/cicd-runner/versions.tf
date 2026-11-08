# =============================================================================
# cicd-runner module - provider requirements
# =============================================================================
# The caller passes two azurerm providers: the default one (the subscription
# that holds the runners) and "azurerm.hub" (the subscription that holds the
# hub VNet, only used when hub peering is enabled). Both may be the same
# subscription.
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      version               = "~> 4.0"
      configuration_aliases = [azurerm.hub]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
