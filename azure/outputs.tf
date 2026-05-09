# Tells terraform which values to report after work is complete 
output "resource_group_name" {
  description = "The name of the primary resource group."
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "The ID of the primary resource group."
  value       = azurerm_resource_group.main.id
}