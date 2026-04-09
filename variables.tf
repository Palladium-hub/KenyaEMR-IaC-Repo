variable "vpc_id" {
  description = "VPC ID for the EKS cluster and RDS"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the RDS subnet group"
  type        = list(string)
}

variable "eks_node_security_group_id" {
  description = "Security group ID of EKS worker nodes"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "kms_key_id" {
  description = "KMS key ID for encrypting secrets (optional)"
  type        = string
  default     = null
}

variable "rotation_lambda_arn" {
  description = "ARN of the Lambda function for Secrets Manager rotation (optional)"
  type        = string
  default     = null
}
