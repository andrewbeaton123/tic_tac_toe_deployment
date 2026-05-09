
# main.tf
provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "ttt" {
  name     = "rg-tictactoe-mlops-uk"
  location = var.location
}

# --- Networking ---
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-tictactoe"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.ttt.location
  resource_group_name = azurerm_resource_group.ttt.name
}

resource "azurerm_subnet" " c " {
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

# --- ML Serving Tier ---
resource "azurerm_container_app_environment" "env" {
  name                       = "cae-tictactoe"
  location                   = azurerm_resource_group.ttt.location
  resource_group_name        = azurerm_resource_group.ttt.name
  infrastructure_subnet_id   = azurerm_subnet.aca_subnet.id
  
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# --- Security & Routing ---
resource "azurerm_application_gateway" "appgw" {
  name                = "agw-tictactoe"
  resource_group_name = azurerm_resource_group.ttt.name
  location            = azurerm_resource_group.ttt.location

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 1
  }
}
