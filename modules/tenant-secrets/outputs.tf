output "secret_arn" {
  description = "ARN of the tenant database credentials secret"
  value       = aws_secretsmanager_secret.tenant_db.arn
}

output "db_password" {
  description = "Generated database password for the tenant"
  value       = random_password.db_password.result
  sensitive   = true
}
