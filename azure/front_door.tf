# Note on naming: Azure merged Front Door and CDN into one product. The Terraform
# provider still uses the azurerm_cdn_frontdoor_* namespace — this is legacy naming,
# not a mistake. These resources ARE Azure Front Door Standard.

resource "azurerm_cdn_frontdoor_profile" "fd" {
  name                = "fd-tictactoe-${var.environment}"
  resource_group_name = azurerm_resource_group.ttt.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

# The public-facing URL endpoint (e.g. ep-tictactoe-dev-xxxx.z01.azurefd.net).
# A profile can host multiple endpoints for different products or environments.
resource "azurerm_cdn_frontdoor_endpoint" "ep" {
  name                     = "ep-tictactoe-${var.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id
  tags                     = var.tags
}

# An origin group is a load-balancing pool of backend servers.
# Health probes run against this group — if an origin fails probes it is removed
# from rotation until it recovers. We have one origin (the web UI) but the group
# is required as an intermediate layer.
resource "azurerm_cdn_frontdoor_origin_group" "og" {
  name                     = "og-web-ui"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 50
  }

  health_probe {
    path                = "/"
    protocol            = "Https"
    interval_in_seconds = 30
    request_type        = "HEAD"
  }
}

# The origin is the actual backend server Front Door routes to.
# host_name points to the Container App's external FQDN.
resource "azurerm_cdn_frontdoor_origin" "web_ui" {
  name                          = "origin-web-ui"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.og.id

  host_name                      = azurerm_container_app.web_ui.ingress[0].fqdn
  origin_host_header             = azurerm_container_app.web_ui.ingress[0].fqdn
  https_port                     = 443
  http_port                      = 80
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true
  enabled                        = true
}

# A rule set is required by the route resource. Even when empty, it must exist.
resource "azurerm_cdn_frontdoor_rule_set" "rs" {
  name                     = "ruleset"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id
}

# The route binds the endpoint to an origin group for a set of URL patterns.
# forwarding_protocol = HttpOnly: Container Apps handle their own TLS at the environment
# edge, so Front Door forwards requests as plain HTTP internally.
# https_redirect_enabled: users arriving on HTTP are redirected to HTTPS at the Front Door edge.
resource "azurerm_cdn_frontdoor_route" "route" {
  name                          = "route-all"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.ep.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.og.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.web_ui.id]
  cdn_frontdoor_rule_set_ids    = [azurerm_cdn_frontdoor_rule_set.rs.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpOnly"
  https_redirect_enabled = true
  link_to_default_domain = true
  enabled                = true
}

# --- WAF ---
# WAF (Web Application Firewall) filters malicious requests before they reach the app —
# think of it as input validation for your serving infrastructure.
# Standard tier supports custom rules only (no managed OWASP ruleset — that requires Premium).
# mode = "Prevention" means matching requests are BLOCKED, not just logged.
resource "azurerm_cdn_frontdoor_firewall_policy" "waf" {
  name                = "wafpolicytictactoe"
  resource_group_name = azurerm_resource_group.ttt.name
  sku_name            = azurerm_cdn_frontdoor_profile.fd.sku_name
  mode                = "Prevention"
  enabled             = true

  # Rate limiting: block any IP that sends more than 100 requests in 1 minute.
  # Protects against brute force, scraping, and basic DoS attacks.
  custom_rule {
    name     = "RateLimitRule"
    enabled  = true
    priority = 100
    type     = "RateLimitRule"
    action   = "Block"

    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = 100

    match_condition {
      match_variable     = "RemoteAddr"
      operator           = "IPMatch"
      negation_condition = false
      match_values       = ["0.0.0.0/0"] # applies to all source IPs
    }
  }

  tags = var.tags
}

# Attaches the WAF policy to the Front Door endpoint.
# The policy and endpoint are defined separately and linked here.
resource "azurerm_cdn_frontdoor_security_policy" "sp" {
  name                     = "security-policy"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.waf.id

      association {
        patterns_to_match = ["/*"]

        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.ep.id
        }
      }
    }
  }
}
