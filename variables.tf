variable "vpc_id" {
  description = "VPC ID for the EKS cluster and RDS"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS, node groups, and RDS"
  type        = list(string)
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "kenyaemr-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["m5.large"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
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

variable "eks_node_security_group_id" {
  description = "Security group ID of EKS worker nodes (used if providing your own cluster)"
  type        = string
  default     = ""
}
