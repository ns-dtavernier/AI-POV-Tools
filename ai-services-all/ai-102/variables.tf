# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_object_unique_prefix" {
  description = "Unique prefix for the names of all AWS resources (Name tags and name attributes). Lowercase letters, digits and hyphens, 1-20 characters."
  type        = string
  default     = "netskope"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,19}$", var.aws_object_unique_prefix))
    error_message = "aws_object_unique_prefix must be 1-20 characters: lowercase letters, digits and hyphens, starting with a letter or digit."
  }
}

variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone for all subnets. Must be valid for aws_region. Check with: aws ec2 describe-availability-zones --region YOUR_REGION --query 'AvailabilityZones[*].ZoneName'"
  type        = string
  default     = "us-east-1a"
}

# ── AWS — Tags ────────────────────────────────────────────────────────────────
# Applied to every taggable AWS resource through the provider's default_tags.

variable "aws_tag_owner" {
  description = "Email address of the person responsible for this deployment. Applied as the 'owner' tag."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.aws_tag_owner))
    error_message = "aws_tag_owner must be a valid email address (e.g. user@example.com)."
  }
}

variable "aws_tag_purpose" {
  description = "Purpose of this deployment: core, pov, demo, lab, or integration. Applied as the 'purpose' tag."
  type        = string

  validation {
    condition     = contains(["core", "pov", "demo", "lab", "integration"], var.aws_tag_purpose)
    error_message = "aws_tag_purpose must be one of: core, pov, demo, lab, integration."
  }
}

variable "aws_tag_terminate_after" {
  description = "Date after which this deployment may be torn down, formatted YYYY-MM-DD. Applied as the 'terminate_after' tag."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.aws_tag_terminate_after)) && can(formatdate("YYYY-MM-DD", "${var.aws_tag_terminate_after}T00:00:00Z"))
    error_message = "aws_tag_terminate_after must be a valid calendar date formatted YYYY-MM-DD (e.g. 2026-12-31)."
  }
}

variable "aws_tag_project" {
  description = "Optional project name. Applied as the 'project' tag; omitted when null or empty. Letters, numbers, spaces and _ . : / = + - @ only, up to 256 characters."
  type        = string
  default     = null

  validation {
    condition     = var.aws_tag_project == null || can(regex("^[\\p{L}\\p{Z}\\p{N}_.:/=+@-]{0,256}$", var.aws_tag_project))
    error_message = "aws_tag_project may contain only letters, numbers, spaces and _ . : / = + - @, up to 256 characters."
  }
}

variable "aws_tag_description" {
  description = "Optional free-text description. Applied as the 'description' tag; omitted when null or empty. Letters, numbers, spaces and _ . : / = + - @ only, up to 256 characters."
  type        = string
  default     = null

  validation {
    condition     = var.aws_tag_description == null || can(regex("^[\\p{L}\\p{Z}\\p{N}_.:/=+@-]{0,256}$", var.aws_tag_description))
    error_message = "aws_tag_description may contain only letters, numbers, spaces and _ . : / = + - @, up to 256 characters."
  }
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

# ── Netskope Tenant ───────────────────────────────────────────────────────────

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

variable "netskope_onpremappliance_licensekey" {
  description = "Netskope license key for the DLPoD appliance (single tenant key for all Netskope On-Prem Appliances). Sensitive — use a gitignored tfvars file or TF_VAR_netskope_onpremappliance_licensekey."
  type        = string
  sensitive   = true
  default     = ""
}

# ── AIG — Netskope ────────────────────────────────────────────────────────────

variable "aig_netskope_name" {
  description = "AIG appliance display name in the Netskope tenant — 1 to 15 characters."
  type        = string
  default     = "aig-lab"

  validation {
    condition     = length(var.aig_netskope_name) >= 1 && length(var.aig_netskope_name) <= 15
    error_message = "aig_netskope_name must be 1-15 characters (Netskope limit)."
  }
}

variable "secret_name" {
  description = "Secrets Manager secret name for the AIG bootstrap config (enrollment token + Guardrails host). Must start with \"aig/\". Defaults to aig/<aws_object_unique_prefix>/bootstrap."
  type        = string
  default     = null

  validation {
    condition     = var.secret_name == null || startswith(var.secret_name, "aig/")
    error_message = "secret_name must start with \"aig/\" (required by the deployment IAM policy)."
  }
}

# ── SSH Keys ──────────────────────────────────────────────────────────────────
# One key pair, <aws_object_unique_prefix>-keypair, is created in AWS from a
# private key and is always used by the AIG. The private key is stored in
# Secrets Manager and downloaded by the bastion so it can SSH to the AIG.

variable "keypair_existing_private_key_local_path" {
  description = "Local path to an existing unencrypted SSH private key (PEM or OpenSSH format) to use for the new <aws_object_unique_prefix>-keypair AWS key pair. Leave blank to generate a private key locally, written to my-private-key.pem in the project root directory. A path that does not exist, or a file that is not a valid private key, fails the plan."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.keypair_existing_private_key_local_path == "" || fileexists(pathexpand(var.keypair_existing_private_key_local_path))
    error_message = "keypair_existing_private_key_local_path does not point to an existing file. Provide a valid path to a private key, or leave it blank to generate one."
  }
}

variable "bastion_key_pair_name" {
  description = "Name of an existing AWS EC2 key pair to use for the bastion instance. Leave blank to use the new <aws_object_unique_prefix>-keypair. A non-blank value must name a key pair that already exists in aws_region."
  type        = string
  default     = ""
  nullable    = false
}

variable "guardrails_key_pair_name" {
  description = "Name of an existing AWS EC2 key pair to use for the Guardrails instance. Leave blank to use the new <aws_object_unique_prefix>-keypair. A non-blank value must name a key pair that already exists in aws_region."
  type        = string
  default     = ""
  nullable    = false
}

variable "dlpod_key_pair_name" {
  description = "Name of an existing AWS EC2 key pair to use for the DLPoD instance. Leave blank to use the new <aws_object_unique_prefix>-keypair. A non-blank value must name a key pair that already exists in aws_region."
  type        = string
  default     = ""
  nullable    = false
}

# ── AIG - Signing CA ──────────────────────────────────────────────────────────
# The bastion signs the CSR generated by the AIG with this CA. The CA key and
# certificate are stored in Secrets Manager and downloaded by the bastion to
# /home/ssm-user/ as lab-root-ca-key.pem and lab-root-ca-cert.pem.

variable "ca_existing_signing_key_local_path" {
  description = "Local path to an existing CA signing private key (PEM). When set, no signing key is created and ca_existing_signing_cert_local_path must also be set. Leave blank to generate a new root CA with openssl: lab-root-ca-key.pem and lab-root-ca-cert.pem in the project root directory, built from the ca_new_* variables."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.ca_existing_signing_key_local_path == "" || fileexists(pathexpand(var.ca_existing_signing_key_local_path))
    error_message = "ca_existing_signing_key_local_path does not point to an existing file. Provide a valid path to the CA private key, or leave it blank to generate a new root CA."
  }
}

variable "ca_existing_signing_cert_local_path" {
  description = "Local path to the CA certificate (PEM) matching ca_existing_signing_key_local_path. Required when ca_existing_signing_key_local_path is set; ignored otherwise."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.ca_existing_signing_key_local_path == "" || (var.ca_existing_signing_cert_local_path != "" && fileexists(pathexpand(var.ca_existing_signing_cert_local_path)))
    error_message = "ca_existing_signing_cert_local_path must point to an existing certificate file when ca_existing_signing_key_local_path is set."
  }
}

variable "ca_new_subj" {
  description = "Subject (openssl req -subj format) of the new root CA certificate. Only used when ca_existing_signing_key_local_path is blank."
  type        = string
  default     = "/C=US/ST=CA/L=SantaClara/O=NetskopeLab/OU=Security/CN=Netskope Lab Root CA/emailAddress=admin@lab.internal"
}

variable "ca_new_addext" {
  description = "X.509 extensions for the new root CA certificate, one openssl req -addext value per entry. Only used when ca_existing_signing_key_local_path is blank."
  type        = list(string)
  default = [
    "basicConstraints=critical,CA:TRUE",
    "keyUsage=critical,keyCertSign,cRLSign",
  ]
}

variable "ca_new_days" {
  description = "Validity in days of the new root CA certificate (openssl req -days). Only used when ca_existing_signing_key_local_path is blank."
  type        = number
  default     = 365

  validation {
    condition     = var.ca_new_days >= 1 && var.ca_new_days == floor(var.ca_new_days)
    error_message = "ca_new_days must be a positive whole number."
  }
}

# ── AIG - Cert ────────────────────────────────────────────────────────────────
# Subject and key settings for the certificate whose CSR the AIG generates (to be
# signed by the signing CA above). Optional fields left null are omitted.

variable "aig_cert_common_name" {
  description = "Certificate common name (CN), 1-256 characters. Required. For the AIG this is typically the DNS name clients use to reach it, e.g. the Elastic IP's ec2-<ip-with-dashes>.<region>.compute.amazonaws.com name."
  type        = string

  validation {
    condition     = length(var.aig_cert_common_name) >= 1 && length(var.aig_cert_common_name) <= 256
    error_message = "aig_cert_common_name is required and must be 1-256 characters."
  }
}

variable "aig_cert_organization" {
  description = "Optional. Organization name (O), up to 256 characters."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_organization == null ? true : length(var.aig_cert_organization) <= 256
    error_message = "aig_cert_organization must be at most 256 characters."
  }
}

variable "aig_cert_organization_unit" {
  description = "Optional. Organizational unit (OU), up to 256 characters."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_organization_unit == null ? true : length(var.aig_cert_organization_unit) <= 256
    error_message = "aig_cert_organization_unit must be at most 256 characters."
  }
}

variable "aig_cert_email" {
  description = "Optional. Email address for the certificate subject (valid email format)."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_email == null || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.aig_cert_email))
    error_message = "aig_cert_email must be a valid email address (e.g. admin@lab.internal)."
  }
}

variable "aig_cert_country" {
  description = "Optional. Two-letter country code (C), exactly 2 alphabetic characters."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_country == null || can(regex("^[A-Za-z]{2}$", var.aig_cert_country))
    error_message = "aig_cert_country must be exactly 2 alphabetic characters (e.g. US)."
  }
}

variable "aig_cert_state" {
  description = "Optional. State or province (ST), up to 256 characters."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_state == null ? true : length(var.aig_cert_state) <= 256
    error_message = "aig_cert_state must be at most 256 characters."
  }
}

variable "aig_cert_city" {
  description = "Optional. City or locality (L), up to 256 characters."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_city == null ? true : length(var.aig_cert_city) <= 256
    error_message = "aig_cert_city must be at most 256 characters."
  }
}

variable "aig_cert_key_algorithm" {
  description = "Optional. Private key algorithm: ecdsa, rsa or ed25519. When null the AIG defaults to ecdsa (P-256)."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_key_algorithm == null ? true : contains(["ecdsa", "rsa", "ed25519"], var.aig_cert_key_algorithm)
    error_message = "aig_cert_key_algorithm must be one of: ecdsa, rsa, ed25519."
  }
}

variable "aig_cert_key_size" {
  description = "Optional. RSA key size in bits: 2048, 3072 or 4096. Applies when aig_cert_key_algorithm is rsa."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_key_size == null ? true : contains(["2048", "3072", "4096"], var.aig_cert_key_size)
    error_message = "aig_cert_key_size must be one of: 2048, 3072, 4096."
  }
}

variable "aig_cert_key_curve" {
  description = "Optional. ECDSA curve: P256, P384 or P521. Applies when aig_cert_key_algorithm is ecdsa."
  type        = string
  default     = null

  validation {
    condition     = var.aig_cert_key_curve == null ? true : contains(["P256", "P384", "P521"], var.aig_cert_key_curve)
    error_message = "aig_cert_key_curve must be one of: P256, P384, P521."
  }
}

# ── Bastion Host - EC2 ────────────────────────────────────────────────────────

variable "bastion_private_ip" {
  description = "Fixed private IP for the bastion instance. Must be within public_subnet_cidr (AWS reserves the first four addresses of a subnet) and must not conflict with aig_private_ip."
  type        = string
  default     = "10.0.1.11"

  validation {
    condition     = can(cidrhost(format("%s/32", var.bastion_private_ip), 0))
    error_message = "Must be a valid IPv4 address."
  }
}

# ── AIG — EC2 ─────────────────────────────────────────────────────────────────

variable "aig_ami_id" {
  description = "AMI ID for the Netskope AI Gateway appliance. Default is for us-east-1 — update for other regions referencing the AWS Marketplace listing."
  type        = string
  default     = "ami-01ca21d57390e7682"
}

variable "aig_instance_type" {
  description = "EC2 instance type for the AI Gateway. c6a.4xlarge (16 vCPU, 32 GB RAM) is the recommended minimum."
  type        = string
  default     = "c6a.4xlarge"
}

variable "aig_private_ip" {
  description = "Fixed private IP for the AIG instance. Must be within public_subnet_cidr (AWS reserves the first four addresses of a subnet) and must not conflict with other addresses in that subnet."
  type        = string
  default     = "10.0.1.10"

  validation {
    condition     = can(cidrhost(format("%s/32", var.aig_private_ip), 0))
    error_message = "Must be a valid IPv4 address."
  }
}

# ── Guardrails — EC2 ──────────────────────────────────────────────────────────

variable "guardrails_ami_id" {
  description = "Custom AMI ID for the Guardrails GPU instance (Ubuntu-based, ideally with NVIDIA driver, NVIDIA Container Toolkit, Docker and the LLM image pre-installed). Region-specific. Leave empty to use the latest stock Ubuntu 22.04 AMI and install everything at first boot."
  type        = string
  default     = ""

  validation {
    condition     = var.guardrails_ami_id == "" || can(regex("^ami-[0-9a-f]{8,17}$", var.guardrails_ami_id))
    error_message = "Must be empty or a valid AMI ID (ami-xxxxxxxx...)."
  }
}

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
  description = "Root EBS volume size in GB for the Guardrails instance. Minimum 80 GB for NVIDIA drivers and Docker images. Must be at least the size of the root snapshot when using guardrails_ami_id."
  type        = number
  default     = 100

  validation {
    condition     = var.volume_size_gb >= 80 && var.volume_size_gb <= 500
    error_message = "Must be between 80 and 500."
  }
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

variable "guardrails_llm_image_s3_bucket" {
  description = "S3 bucket containing the Guardrails LLM Docker image tarball. Upload aisecurity-llm.tgz here before running terraform apply. Required unless guardrails_ami_id is set (the AMI is expected to ship the image); when set alongside an AMI, it is only used as a fallback if the AMI has no image."
  type        = string
  default     = ""

  validation {
    condition     = var.guardrails_llm_image_s3_bucket == "" || can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.guardrails_llm_image_s3_bucket))
    error_message = "Must be empty or a valid S3 bucket name (lowercase, no underscores)."
  }

  # Cross-variable reference requires Terraform >= 1.9.
  validation {
    condition     = var.guardrails_llm_image_s3_bucket != "" || var.guardrails_ami_id != ""
    error_message = "guardrails_llm_image_s3_bucket is required when guardrails_ami_id is empty (a stock Ubuntu AMI has no Guardrails image). Set a bucket, or set guardrails_ami_id to a custom AMI that ships the image."
  }
}

variable "guardrails_llm_image_s3_key" {
  description = "S3 object key for the Guardrails LLM Docker image tarball."
  type        = string
  default     = "aisecurity-llm.tgz"

  validation {
    condition     = length(var.guardrails_llm_image_s3_key) > 0
    error_message = "Image S3 key cannot be empty."
  }
}

# ── DLPoD ─────────────────────────────────────────────────────────────────────

variable "dlpod_ami_id" {
  description = "AMI ID for the Netskope DLPoD appliance. Default is for us-east-1 — update for other regions."
  type        = string
  default     = "ami-0dc05a852535f0ab4"
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

variable "dlpod_ssh_public_key" {
  description = "SSH public key to inject into nsadmin on the DLPoD appliance via bootstrap. DLPoD does not use EC2 key injection — this must be set explicitly."
  type        = string
  default     = ""
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

variable "dlpod_hostname" {
  description = "Hostname used as the TLS certificate CN and DNS SAN for the DLPoD server cert. Does not need to resolve in DNS — the AIG connects by IP (dlpod_private_ip)."
  type        = string
  default     = "dlp.aig.internal"
}
