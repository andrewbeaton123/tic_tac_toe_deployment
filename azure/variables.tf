# used to create variables for use in main and to enforce 
# conditions on those variables.

variable "location" {
  type        = string
  description = "The Azure region where resources will be deployed."
  default     = "uksouth"
}

variable "environment" {
  type        = string
  description = "The environment name (e.g., dev, test, prod)."
  
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "tags" {
  type        = map(string)
  description = "A mapping of tags to assign to the resources."
  default = {
    managed_by = "terraform"
  }
}