output "rds_endpoint" {
  description = "RDS instance endpoint (host:port)"
  value       = aws_db_instance.kenyaemr.endpoint
}

output "rds_address" {
  description = "RDS instance hostname"
  value       = aws_db_instance.kenyaemr.address
}

output "rds_master_secret_arn" {
  description = "ARN of the Secrets Manager secret for the RDS master password"
  value       = aws_db_instance.kenyaemr.master_user_secret[0].secret_arn
}
