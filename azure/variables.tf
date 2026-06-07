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

variable "model_serve_api_key" {
  type        = string
  sensitive   = true
  description = "API key for model serve authentication. Stored as a Container App secret — never appears in plan/apply output."
}

variable "flask_secret_key" {
  type        = string
  sensitive   = true
  description = "Secret key used by Flask to sign session cookies. Must be a long random string."
}

variable "model_serve_image_tag" {
  type        = string
  default     = "latest"
  description = "Docker image tag for the model serve container. Use a git SHA instead of 'latest' in production."
}

variable "web_ui_image_tag" {
  type        = string
  default     = "latest"
  description = "Docker image tag for the web UI container."
}

variable "alert_email" {
  type        = string
  description = "Email address that receives monitoring alerts (error rate spikes, container restarts)."
}