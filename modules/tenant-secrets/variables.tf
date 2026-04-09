variable "tenant_name" {
  description = "Tenant name"
  type        = string
}

variable "db_user" {
  description = "Database username for the tenant"
  type        = string
}

variable "db_schema" {
  description = "Database schema name for the tenant"
  type        = string
}

variable "db_host" {
  description = "Database host endpoint"
  type        = string
}

variable "rotation_lambda_arn" {
  description = "ARN of the Lambda function for secret rotation"
  type        = string
  default     = null
}
