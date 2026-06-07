resource "azurerm_resource_group" "ttt" {
  name     = "rg-tictactoe-mlops-uk"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-tictactoe"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.ttt.location
  resource_group_name = azurerm_resource_group.ttt.name
  tags                = var.tags
}

# Dedicated subnet for the Container Apps Environment.
# The delegation tells Azure to reserve this subnet exclusively for ACA —
# no other services can be placed here.
resource "azurerm_subnet" "c" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.ttt.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/23"]

  delegation {
    name = "aca-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
