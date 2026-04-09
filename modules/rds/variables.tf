variable "vpc_id" {
  description = "VPC ID where the RDS instance will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "eks_node_security_group_id" {
  description = "Security group ID of EKS worker nodes (allowed to connect to RDS)"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "kms_key_id" {
  description = "KMS key ID for encrypting the master user secret (optional)"
  type        = string
  default     = null
}
