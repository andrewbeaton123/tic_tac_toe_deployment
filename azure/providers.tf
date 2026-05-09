terraform {
  required_version = ">= 1.1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0" # Pin to the 3.x major version
    }
    # Add other providers like azuread or random here if needed
  }

  # Recommended: Configure a remote backend for state management
  # backend "azurerm" {
  #   resource_group_name  = "rg-terraform-state"
  #   storage_account_name = "sttfstate"
  #   container_name       = "tfstate"
  #   key                  = "prod.terraform.tfstate"
  # }
}

provider "azurerm" {
  features {} # Required block for azurerm, even if empty
  
  # subscription_id = "..." (Often better provided via Environment Variables)
}