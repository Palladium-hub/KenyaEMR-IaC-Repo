variable "tenant_name" {
  type = string
}

variable "db_schema" {
  type = string
}

variable "db_host" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "backend_image" {
  type = string
}

variable "frontend_image" {
  type = string
}

variable "oidc_realm" {
  type = string
}

variable "oidc_client_id" {
  type = string
}

variable "oidc_issuer" {
  type = string
}