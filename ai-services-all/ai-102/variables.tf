# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone for all subnets. Must be valid for aws_region. Check with: aws ec2 describe-availability-zones --region YOUR_REGION --query 'AvailabilityZones[*].ZoneName'"
  type        = string
}

# ── VPC / Networking ──────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet. Hosts the AIG instance (EIP) and NAT Gateway."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet. Hosts the Guardrails GPU instance (no public IP)."
  type        = string
  default     = "10.0.2.0/24"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks permitted to reach the AI Gateway on TCP port 443 (HTTPS proxy)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── AIG — Netskope ────────────────────────────────────────────────────────────

variable "netskope_server_url" {
  description = "Netskope tenant API v2 URL. Overridden by NETSKOPE_SERVER_URL environment variable (recommended)."
  type        = string
  default     = ""
}

variable "netskope_api_key" {
  description = "Netskope REST API v2 token. Overridden by NETSKOPE_API_KEY environment variable (recommended)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "appliance_name" {
  description = "AIG appliance display name — 1 to 15 characters. Used as prefix for all AIG AWS resource Name tags."
  type        = string
  default     = "aig-pov"

  validation {
    condition     = length(var.appliance_name) >= 1 && length(var.appliance_name) <= 15
    error_message = "appliance_name must be 1-15 characters (Netskope limit)."
  }
}

variable "secret_name" {
  description = "Secrets Manager secret name for the AIG bootstrap config (enrollment token + Guardrails host)"
  type        = string
  default     = "aig/prod/bootstrap"
}

# ── AIG — EC2 ─────────────────────────────────────────────────────────────────

variable "aig_ami_id" {
  description = "AMI ID for the Netskope AI Gateway appliance. Region-specific — obtain from Netskope or the AWS Marketplace listing for your region."
  type        = string
}

variable "aig_instance_type" {
  description = "EC2 instance type for the AI Gateway. c6a.4xlarge (16 vCPU, 32 GB RAM) is the recommended minimum."
  type        = string
  default     = "c6a.4xlarge"
}

variable "aig_key_name" {
  description = "EC2 key pair name for AIG SSH access (optional). Leave null to use SSM Session Manager only."
  type        = string
  default     = null
}

# ── Guardrails — Project ──────────────────────────────────────────────────────

variable "project" {
  description = "Short project identifier used in Guardrails resource names and tags"
  type        = string
  default     = "guardrails"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.project))
    error_message = "Must be lowercase alphanumeric and hyphens, starting with a letter or digit."
  }
}

variable "environment" {
  description = "Deployment environment used in Guardrails resource names and tags"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

# ── Guardrails — EC2 ──────────────────────────────────────────────────────────

variable "guardrails_instance_type" {
  description = "GPU-enabled EC2 instance type for the Guardrails LLM service"
  type        = string
  default     = "g4dn.xlarge"

  validation {
    condition = contains(
      ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge", "g5.xlarge", "g5.2xlarge", "p3.2xlarge"],
      var.guardrails_instance_type
    )
    error_message = "Must be one of: g4dn.xlarge, g4dn.2xlarge, g4dn.4xlarge, g5.xlarge, g5.2xlarge, p3.2xlarge."
  }
}

variable "volume_size_gb" {
  description = "Root EBS volume size in GB for the Guardrails instance. Minimum 80 GB for NVIDIA drivers and Docker images."
  type        = number
  default     = 100

  validation {
    condition     = var.volume_size_gb >= 80 && var.volume_size_gb <= 500
    error_message = "Must be between 80 and 500."
  }
}

variable "guardrails_key_pair_name" {
  description = "EC2 key pair name for Guardrails SSH access. Leave empty to use SSM Session Manager only (recommended)."
  type        = string
  default     = ""
}

variable "guardrails_private_ip" {
  description = "Fixed private IP for the Guardrails GPU instance. Must be within private_subnet_cidr. This address is embedded in the AIG bootstrap secret at plan time — do not change after apply."
  type        = string
  default     = "10.0.2.10"

  validation {
    condition     = can(cidrhost(format("%s/32", var.guardrails_private_ip), 0))
    error_message = "Must be a valid IPv4 address."
  }
}

# ── Guardrails — Image ────────────────────────────────────────────────────────

variable "image_s3_bucket" {
  description = "S3 bucket containing the Guardrails LLM Docker image tarball. Upload aisecurity-llm.tgz here before running terraform apply."
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

# ── DLPoD ─────────────────────────────────────────────────────────────────────

variable "dlpod_appliance_name" {
  description = "Name tag for the DLPoD instance and associated AWS resources"
  type        = string
  default     = "dlpod-pov"
}

variable "dlpod_ami_id" {
  description = "AMI ID for the Netskope DLPoD appliance. Default is for us-west-1 — update for other regions."
  type        = string
  default     = "ami-0b3a14615c7e7944e"
}

variable "dlpod_instance_type" {
  description = "EC2 instance type for the DLPoD appliance"
  type        = string
  default     = "c5d.4xlarge"
}

variable "dlpod_private_ip" {
  description = "Fixed private IP for the DLPoD instance. Must be within private_subnet_cidr and must not conflict with guardrails_private_ip. This address is embedded in the AIG bootstrap secret at plan time."
  type        = string
  default     = "10.0.2.20"

  validation {
    condition     = can(cidrhost(format("%s/32", var.dlpod_private_ip), 0))
    error_message = "Must be a valid IPv4 address."
  }
}

variable "dlpod_key_name" {
  description = "EC2 key pair name for DLPoD SSH access (optional)"
  type        = string
  default     = null
}

variable "dlpod_ssh_public_key" {
  description = "SSH public key to inject into nsadmin on the DLPoD appliance via bootstrap. DLPoD does not use EC2 key injection — this must be set explicitly."
  type        = string
  default     = ""
}

variable "bastion_key_name" {
  description = "EC2 key pair name for bastion SSH access (optional). Leave null to use SSM Session Manager only."
  type        = string
  default     = null
}

variable "dlpod_persona" {
  description = "DLPoD appliance persona. Must be 'dlp-on-demand' or 'dspm'."
  type        = string
  default     = "dlp-on-demand"

  validation {
    condition     = contains(["dlp-on-demand", "dspm"], var.dlpod_persona)
    error_message = "persona must be 'dlp-on-demand' or 'dspm'."
  }
}

variable "dlpod_licensekey" {
  description = "Netskope license key for the DLPoD appliance. Sensitive — use a gitignored tfvars file or TF_VAR_dlpod_licensekey."
  type        = string
  sensitive   = true
}

variable "dlpod_hostname" {
  description = "Hostname used as the TLS certificate CN and DNS SAN for the DLPoD server cert. Does not need to resolve in DNS — the AIG connects by IP (dlpod_private_ip)."
  type        = string
  default     = "dlp.aigw.internal"
}
