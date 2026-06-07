# Azure Container Registry — stores Docker images for both services.
# Container Apps pull from here at deploy time.
# Name must be globally unique across all Azure customers and contain only alphanumerics.
resource "azurerm_container_registry" "acr" {
  name                = "acrtictactoe${var.environment}"
  resource_group_name = azurerm_resource_group.ttt.name
  location            = azurerm_resource_group.ttt.location
  sku                 = "Basic"
  admin_enabled       = true # enables username/password auth used by the Container App registry{} block

  tags = var.tags
}
