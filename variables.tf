variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-3"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones in the target region"
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b", "eu-west-3c"]
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

variable "cluster_admin_user_arns" {
  description = "List of IAM user ARNs to grant EKS cluster admin access"
  type        = list(string)
  default     = []
}

variable "cluster_admin_role_arns" {
  description = "List of IAM role ARNs to grant EKS cluster admin access"
  type        = list(string)
  default     = []
}

