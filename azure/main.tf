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
  
  backend_address_pool{
    name = "tictactoe-backend-pool"
    fqdns = ["FQDN OF CONTAINER"]
  }
  gateway_ip_configuration {
    
  }
  frontend_port {
    name = "frontend-port"
    port = 80
  }
  
  frontend_ip_configuration{
    name = "pip -appgateway"
    location
  }
  
  
  backend_http_settings{
    name = "tictactoe-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "tictactoe-probe"  # Link the probe
  }

  http_listener {
    name = "tictactoe-http-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name = "frontend-port"
    protocol = "Http"
  }
  request_routing_rule {
    name = "tictactoe-routing"
    rule_type = "Basic"
    http_listener_name = "tictactoe-listener"
    backend_address_pool_name = "tictactoe-backend-pool"
    backend_http_settings_name = "tictactoe-http-settings"
    priority = 100
  }

  probe {
  name                                      = "tictactoe-probe"
  host                                      = "FQDN OF CONTAINER"
  protocol                                  = "Http"
  port                                      = 80
  path                                      = "/health"  # Your app's health endpoint
  interval                                  = 30
  timeout                                   = 10
  unhealthy_threshold                       = 3
  pick_host_name_from_backend_http_settings = false
}


  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 1
  }
}

