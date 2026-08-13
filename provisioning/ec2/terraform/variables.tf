# provisioning/ec2/terraform/variables.tf
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az" {
  description = "Availability zone for the single subnet"
  type        = string
  default     = "us-east-1a"
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair name for SSH"
  type        = string
}

variable "ssh_cidr" {
  description = "CIDR allowed to reach SSH / RKE2 ports"
  type        = string
  default     = "0.0.0.0/0"
}

variable "rack_engine_url" {
  description = "Base URL the frontend calls at runtime"
  type        = string
  default     = "http://localhost:8000"
}

variable "rke2_token" {
  description = "Shared RKE2 cluster join token (same for every node)"
  type        = string
  sensitive   = true
}

variable "git_repo" {
  description = "Repo to clone on the control plane"
  type        = string
  default     = "https://github.com/androidcircus/ManifestAI-cogniforge-vx.git"
}

variable "image_tag" {
  description = "Container image tag to deploy"
  type        = string
  default     = "latest"
}

# One control-plane (tier1) plus N GPU workers. Each GPU worker's instance
# type selects a tier: g4dn.xlarge=16GB (tier2), g5.xlarge=24GB (tier2),
# p4d.24xlarge=A100 40GB (tier3), p5.48xlarge=H100 80GB (tier3).
variable "gpu_instance_type" {
  description = "Instance type for GPU workers"
  type        = string
  default     = "g4dn.xlarge"
}

variable "gpu_tier" {
  description = "Tier label for GPU workers"
  type        = string
  default     = "tier2"
}

variable "gpu_worker_count" {
  description = "Number of GPU worker instances"
  type        = number
  default     = 0
}