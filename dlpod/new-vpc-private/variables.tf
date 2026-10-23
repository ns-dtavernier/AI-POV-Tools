# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy the DLPoD appliance"
  type        = string
  default     = "us-west-1"
}

variable "availability_zone" {
  description = "Availability zone for the public and private subnets"
  type        = string
  default     = "us-west-1b"
}

# ── VPC / Networking ──────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (NAT Gateway only)"
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (DLPoD instance)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "dlpod_private_ip" {
  description = "Optional fixed private IP for the DLPoD instance — must be within private_subnet_cidr. Set to null to let AWS assign from the subnet automatically."
  type        = string
  default     = "10.0.1.10"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks permitted to reach the DLPoD appliance on port 443"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

variable "dlpod_ami_id" {
  description = "AMI ID for the Netskope DLPoD 141 appliance. If null, the AMI is looked up from the built-in region map (us-east-2, us-west-1, us-west-2, eu-central-1, ap-southeast-1). Set explicitly for any other region."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type for the DLPoD appliance"
  type        = string
  default     = "m5.2xlarge"
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access (optional — omit to rely on AWS Systems Manager)"
  type        = string
  default     = null
}

# ── Appliance identity ────────────────────────────────────────────────────────

variable "appliance_name" {
  description = "Display name for the appliance. Used as the Name tag prefix for all AWS resources. Must start with 'dlpod-' to match the deployment IAM policy conditions."
  type        = string
  default     = "dlpod-pov"

  validation {
    condition     = length(var.appliance_name) >= 1
    error_message = "appliance_name must not be empty."
  }
}

# ── Bootstrap: required ───────────────────────────────────────────────────────
#
# These variables are assembled into bootstrap.json and delivered via EC2
# user-data. nsbootstrap.service reads the config at first boot and applies
# it before DLP pod installation begins. Secrets (licensekey) are redacted
# from the persisted bootstrap.json.done by the appliance after bootstrap.

variable "persona" {
  description = "DLPoD appliance persona. Must be 'dlp-on-demand' or 'dspm'."
  type        = string

  validation {
    condition     = contains(["dlp-on-demand", "dspm"], var.persona)
    error_message = "persona must be 'dlp-on-demand' or 'dspm'."
  }
}

variable "dlpod_licensekey" {
  description = "Netskope license key for the DLPoD appliance. Treated as a secret — never logged or included in terraform output."
  type        = string
  sensitive   = true
}

variable "dns_primary" {
  description = "Primary DNS server IP for the appliance"
  type        = string
}

# ── Bootstrap: optional ───────────────────────────────────────────────────────

variable "dns_secondary" {
  description = "Secondary DNS server IP. Leave empty to omit from bootstrap config."
  type        = string
  default     = ""
}

  # Interface is always DHCP on EC2 — no static IP variables needed.

variable "system_hostname" {
  description = "Appliance hostname. Leave empty to omit (cloud-init owns the hostname on EC2). Set explicitly if a specific FQDN is required."
  type        = string
  default     = ""
}

variable "system_timezone" {
  description = "IANA timezone string (e.g. 'America/Los_Angeles'). Leave empty to use the appliance default (UTC)."
  type        = string
  default     = ""
}
