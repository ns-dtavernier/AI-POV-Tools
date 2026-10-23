# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone for the public and private subnets. Must be valid for the chosen aws_region — check with: aws ec2 describe-availability-zones --region YOUR_REGION"
  type        = string
}

# ── VPC / Networking ──────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (NAT Gateway only — no GPU instances here)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (GPU instance lives here)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed inbound on port 22. Default (127.0.0.1/32) effectively disables direct SSH — use SSM Session Manager instead."
  type        = string
  default     = "127.0.0.1/32"
  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0))
    error_message = "Must be a valid IPv4 CIDR block."
  }
}

variable "allowed_service_cidr" {
  description = "CIDR allowed inbound on port 8080 (Guardrails service). Restrict to AIGW source CIDR or your private network range — the instance has no public IP."
  type        = string
  default     = "10.0.0.0/8"
  validation {
    condition     = can(cidrhost(var.allowed_service_cidr, 0))
    error_message = "Must be a valid IPv4 CIDR block."
  }
}

# ── Project ───────────────────────────────────────────────────────────────────

variable "project" {
  description = "Short project identifier used in resource names and tags"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.project))
    error_message = "Must be lowercase alphanumeric and hyphens, starting with a letter or digit."
  }
}

variable "environment" {
  description = "Deployment environment used in resource names and tags"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "GPU-enabled EC2 instance type"
  type        = string
  default     = "g4dn.xlarge"
  validation {
    condition = contains(
      ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge", "g5.xlarge", "g5.2xlarge", "p3.2xlarge"],
      var.instance_type
    )
    error_message = "Must be one of: g4dn.xlarge, g4dn.2xlarge, g4dn.4xlarge, g5.xlarge, g5.2xlarge, p3.2xlarge."
  }
}

variable "volume_size_gb" {
  description = "Root EBS volume size in GB. Minimum 80 GB for NVIDIA drivers and Docker images."
  type        = number
  default     = 100
  validation {
    condition     = var.volume_size_gb >= 80 && var.volume_size_gb <= 500
    error_message = "Must be between 80 and 500."
  }
}

variable "key_pair_name" {
  description = "EC2 key pair name for direct SSH. Leave empty to use SSM Session Manager only (recommended)."
  type        = string
  default     = ""
}

# ── Guardrails image ──────────────────────────────────────────────────────────

variable "image_s3_bucket" {
  description = "S3 bucket containing the Guardrails LLM Docker image tarball. Upload aisecurity-llm.tgz here before applying."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.image_s3_bucket))
    error_message = "Must be a valid S3 bucket name (lowercase, no underscores)."
  }
}

variable "image_s3_key" {
  description = "S3 object key for the Guardrails LLM Docker image tarball."
  type        = string
  default     = "aisecurity-llm.tgz"
  validation {
    condition     = length(var.image_s3_key) > 0
    error_message = "Image S3 key cannot be empty."
  }
}
