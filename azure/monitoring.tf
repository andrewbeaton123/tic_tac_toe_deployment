# Observability stack — without this you have no signal when things go wrong.
# The analogy: you wouldn't ship a model to production without logging metrics.

# Central log aggregation database. All other monitoring resources ship data here.
# PerGB2018 = pay per gigabyte of ingested data (the modern, cost-effective pricing model).
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-tictactoe-${var.environment}"
  location            = azurerm_resource_group.ttt.location
  resource_group_name = azurerm_resource_group.ttt.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# Application Insights provides the metrics dashboard layer on top of Log Analytics —
# request rates, failure rates, response times. workspace_id links it to the
# Log Analytics workspace (workspace-based mode is the modern approach;
# classic standalone App Insights is deprecated).
resource "azurerm_application_insights" "ai" {
  name                = "ai-tictactoe-${var.environment}"
  location            = azurerm_resource_group.ttt.location
  resource_group_name = azurerm_resource_group.ttt.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
  tags                = var.tags
}

# Diagnostic settings connect a resource's log/metric output to a destination.
# Without these, logs stay inside the service and are inaccessible for querying or alerting.

resource "azurerm_monitor_diagnostic_setting" "aca_env_diag" {
  name                       = "diag-aca-env"
  target_resource_id         = azurerm_container_app_environment.env.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log { category = "ContainerAppConsoleLogs" } # stdout/stderr from containers
  enabled_log { category = "ContainerAppSystemLogs" }  # ACA platform events (restarts, scaling)

  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "fd_diag" {
  name                       = "diag-frontdoor"
  target_resource_id         = azurerm_cdn_frontdoor_profile.fd.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log { category = "FrontDoorAccessLog" }                  # all requests with status codes
  enabled_log { category = "FrontDoorWebApplicationFirewallLog" }  # WAF block/detect events

  enabled_metric { category = "AllMetrics" }
}

# Action group = notification list. When an alert fires, this group is notified.
# For a production service you would add a Teams webhook or PagerDuty integration here.
resource "azurerm_monitor_action_group" "email_ag" {
  name                = "ag-tictactoe-email"
  resource_group_name = azurerm_resource_group.ttt.name
  short_name          = "ttt-email"

  email_receiver {
    name                    = "on-call"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Alert: fires when more than 5% of responses from Front Door are 5xx errors.
# This catches application crashes and unhandled exceptions.
resource "azurerm_monitor_metric_alert" "fd_5xx" {
  name                = "alert-fd-5xx-rate-${var.environment}"
  resource_group_name = azurerm_resource_group.ttt.name
  scopes              = [azurerm_cdn_frontdoor_profile.fd.id]
  description         = "Front Door 5xx error rate exceeded 5% — investigate Container App logs"
  severity            = 2 # Warning

  criteria {
    metric_namespace = "Microsoft.Cdn/profiles"
    metric_name      = "Percentage5XX"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 5
  }

  window_size = "PT5M"
  frequency   = "PT1M"

  action {
    action_group_id = azurerm_monitor_action_group.email_ag.id
  }
}

# Alert: fires when a container restarts more than 3 times in 5 minutes.
# Repeated restarts indicate a crash loop — the container keeps failing on startup.
resource "azurerm_monitor_metric_alert" "container_restarts" {
  name                = "alert-container-restarts-${var.environment}"
  resource_group_name = azurerm_resource_group.ttt.name
  scopes              = [azurerm_container_app_environment.env.id]
  description         = "Container restart count exceeded 3 in 5 minutes — indicates a crash loop"
  severity            = 1 # Error

  criteria {
    metric_namespace = "Microsoft.App/managedEnvironments"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 3
  }

  window_size = "PT5M"
  frequency   = "PT1M"

  action {
    action_group_id = azurerm_monitor_action_group.email_ag.id
  }
}
