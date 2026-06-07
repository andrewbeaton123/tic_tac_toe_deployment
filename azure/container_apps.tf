# The Container Apps Environment is the shared managed cluster both services run on.
# Integrating it with the VNet means containers get private IPs and can communicate
# with each other without traversing the public internet.
resource "azurerm_container_app_environment" "env" {
  name                       = "cae-tictactoe"
  location                   = azurerm_resource_group.ttt.location
  resource_group_name        = azurerm_resource_group.ttt.name
  infrastructure_subnet_id   = azurerm_subnet.c.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.tags
}

# --- Model Serve ---
# Internal ingress only: the FQDN is VNet-private and unreachable from the internet.
# Only the web UI (in the same environment) can call it via its internal FQDN.
resource "azurerm_container_app" "model_serve" {
  name                         = "ca-model-serve"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.ttt.name
  revision_mode                = "Single"

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  secret {
    name  = "model-serve-api-key"
    value = var.model_serve_api_key
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "model-serve"
      image  = "${azurerm_container_registry.acr.login_server}/model-serve:${var.model_serve_image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "API_KEY"
        secret_name = "model-serve-api-key"
      }

      env {
        name  = "Q_VALUES_PATH"
        value = "/app/saved_q_values.pkl"
      }
    }
  }

  ingress {
    external_enabled = false
    target_port      = 9100
    transport        = "http"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = var.tags
}

# --- Web UI ---
# External ingress required so Front Door can reach it, but access is locked to
# Front Door IPs via the ip_security_restriction block (Layer 1 security).
# Layer 2 (X-Azure-FDID header check) is enforced in the Flask app middleware.
resource "azurerm_container_app" "web_ui" {
  name                         = "ca-web-ui"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.ttt.name
  revision_mode                = "Single"

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  secret {
    name  = "flask-secret-key"
    value = var.flask_secret_key
  }

  secret {
    name  = "model-serve-api-key"
    value = var.model_serve_api_key
  }

  template {
    min_replicas = 1
    max_replicas = 5

    container {
      name   = "web-ui"
      image  = "${azurerm_container_registry.acr.login_server}/web-ui:${var.web_ui_image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "FLASK_SECRET_KEY"
        secret_name = "flask-secret-key"
      }

      # Internal call — stays inside the VNet, never hits the public internet.
      env {
        name  = "ENDPOINT_URL"
        value = "https://${azurerm_container_app.model_serve.ingress[0].fqdn}/next_move"
      }

      env {
        name        = "OCP_APIM_SUBSCRIPTION_KEY"
        secret_name = "model-serve-api-key"
      }

      # Used by the Flask before_request middleware to validate the X-Azure-FDID header
      # (Layer 2 of the Front Door security model — see DEPLOYMENT.md).
      env {
        name  = "AZURE_FRONT_DOOR_ID"
        value = azurerm_cdn_frontdoor_profile.fd.id
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8001
    transport        = "http"

    # NOTE: Layer 1 IP restriction (AzureFrontDoor.Backend service tag) cannot be set
    # via Terraform — the azurerm provider validates ip_address_range as a CIDR and
    # rejects service tag names even though the underlying Azure API accepts them.
    # Apply it as a post-deploy step using the az CLI (see DEPLOYMENT.md).
    # Layer 2 (X-Azure-FDID header check in Flask middleware) is enforced by the app.

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = var.tags
}
