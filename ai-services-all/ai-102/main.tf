terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    netskope = {
      source  = "netskopeoss/netskope"
      version = "~> 0.4.8"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

provider "netskope" {
  # Credentials via environment variables (recommended):
  #   NETSKOPE_SERVER_URL = "https://mycompany.goskope.com/api/v2"
  #   NETSKOPE_API_KEY    = "your-rest-api-v2-token"
  server_url = var.netskope_server_url
  api_key    = var.netskope_api_key
}

# ── Data sources ──────────────────────────────────────────────────────────────

data "aws_region" "current" {}

# Latest Ubuntu 22.04 LTS AMI (Canonical account 099720109477)
data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── Shared locals ─────────────────────────────────────────────────────────────

locals {
  guardrails_prefix = "${var.project}-${var.environment}"
  # Extract the parent zone from dlpod_hostname (e.g. "dlp.aigw.internal" → "aigw.internal")
  dlpod_dns_zone = join(".", slice(split(".", var.dlpod_hostname), 1, length(split(".", var.dlpod_hostname))))
}
