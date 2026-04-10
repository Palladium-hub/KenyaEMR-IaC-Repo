resource "aws_db_subnet_group" "kenyaemr" {
  name       = "kenyaemr-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "kenyaemr-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "kenyaemr-rds-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "kenyaemr-rds-sg"
  }
}

resource "aws_db_instance" "kenyaemr" {
  identifier     = "kenyaemr-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage     = 50
  max_allocated_storage = 200
  storage_encrypted     = true

  db_name  = "openmrs"
  username = "admin"

  manage_master_user_password = true
  master_user_secret_kms_key_id = var.kms_key_id

  db_subnet_group_name   = aws_db_subnet_group.kenyaemr.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = true
  deletion_protection = false
  skip_final_snapshot = true

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  tags = {
    Project = "KenyaEMR"
  }
}
