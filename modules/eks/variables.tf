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

variable "vpc_id" {
  description = "VPC ID for the EKS cluster"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the EKS cluster and node groups"
  type        = list(string)
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

variable "node_disk_size" {
  description = "Disk size in GB for worker nodes"
  type        = number
  default     = 50
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
