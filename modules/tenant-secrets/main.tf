resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"
}

resource "aws_secretsmanager_secret" "tenant_db" {
  name        = "kenyaemr/${var.tenant_name}/db-credentials"
  description = "Database credentials for KenyaEMR tenant: ${var.tenant_name}"
}

resource "aws_secretsmanager_secret_version" "tenant_db" {
  secret_id = aws_secretsmanager_secret.tenant_db.id
  secret_string = jsonencode({
    username = var.db_user
    password = random_password.db_password.result
    dbname   = var.db_schema
    host     = var.db_host
    port     = 3306
  })
}

resource "aws_secretsmanager_secret_rotation" "tenant_db" {
  count               = var.rotation_lambda_arn != null ? 1 : 0
  secret_id           = aws_secretsmanager_secret.tenant_db.id
  rotation_lambda_arn = var.rotation_lambda_arn

  rotation_rules {
    automatically_after_days = 30
  }
}
