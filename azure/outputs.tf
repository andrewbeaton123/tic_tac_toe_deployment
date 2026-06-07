# Values printed after terraform apply. Use these to configure CI/CD, share URLs,
# and run the verification checks in DEPLOYMENT.md.

output "resource_group_name" {
  description = "Name of the primary resource group."
  value       = azurerm_resource_group.ttt.name
}

output "front_door_endpoint_url" {
  description = "Public HTTPS URL — share this with users."
  value       = "https://${azurerm_cdn_frontdoor_endpoint.ep.host_name}"
}

output "acr_login_server" {
  description = "ACR hostname for docker tag / docker push commands."
  value       = azurerm_container_registry.acr.login_server
}

output "web_ui_fqdn" {
  description = "Container App FQDN for the web UI (also used as the Front Door origin host)."
  value       = azurerm_container_app.web_ui.ingress[0].fqdn
}

output "model_serve_fqdn" {
  description = "Internal Container App FQDN for model serve. Set ENDPOINT_URL to https://<this>/next_move."
  value       = azurerm_container_app.model_serve.ingress[0].fqdn
}

output "application_insights_connection_string" {
  description = "App Insights connection string for SDK instrumentation in application code."
  value       = azurerm_application_insights.ai.connection_string
  sensitive   = true
}
