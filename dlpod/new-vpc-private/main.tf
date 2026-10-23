terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── VPC ───────────────────────────────────────────────────────────────────────
#
# DNS support is required so the DLPoD can resolve Netskope cloud endpoints,
# licensing servers, and package sources at boot.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.appliance_name}-vpc" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────
#
# Public subnet: NAT Gateway only — no DLPoD instances here.
# Private subnet: DLPoD instance — outbound via NAT, no inbound from internet.

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${var.appliance_name}-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${var.appliance_name}-private" }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.appliance_name}-igw" }
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────
#
# The DLPoD needs outbound internet to reach Netskope cloud for licensing,
# policy delivery, and software updates. NAT Gateway provides this without
# exposing the appliance directly.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.appliance_name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = { Name = "${var.appliance_name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.appliance_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.appliance_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── IAM: instance profile ─────────────────────────────────────────────────────
#
# DLPoD reads its bootstrap config from raw EC2 user-data (not Secrets Manager),
# so no AWS API permissions are required for bootstrap. An instance profile is
# still created as a base for operational tooling — attach the AWS-managed policy
# AmazonSSMManagedInstanceCore to aws_iam_role.dlpod if AWS Systems Manager
# Session Manager access is needed (avoids opening SSH inbound).

resource "aws_iam_role" "dlpod" {
  name = "${var.appliance_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "dlpod" {
  name = "${var.appliance_name}-instance-profile"
  role = aws_iam_role.dlpod.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "dlpod" {
  name        = "${var.appliance_name}-sg"
  description = "Netskope DLP On-Demand appliance"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS / management"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.appliance_name}-sg" }
}

# ── Bootstrap config (bootstrap.json) ────────────────────────────────────────
#
# DLPoD Zero-Touch Provisioning delivers bootstrap.json as raw JSON in EC2
# user-data. At first boot:
#   1. cloud-init caches the user-data to disk (never executes it — cloud-init
#      is locked down on the DLPoD image; see §7 of the ZTP security design).
#   2. nsbootstrap.service reads the cached user-data, validates it strictly
#      against the schema, applies each section via clib, writes the persona,
#      then finalises (blanking secrets in the persisted bootstrap.json.done).
#   3. nssetupdlpaas.service installs DLP pods after base config is applied.
#
# Fail-closed: any unrecognised top-level key rejects the entire file.
# Allowed top-level keys: persona, dns, interface, management-plane,
#                         system, dlpaas, request
#
# IMDSv2 is enforced (http_tokens = "required") per the ZTP security design:
# it blocks SSRF reads of instance metadata and user-data from within the
# appliance.

# ── TLS: DLPoD CA + server certificate ───────────────────────────────────────
#
# DLPoD rejects CA:TRUE certs in dlpaas.server-cert. A two-tier hierarchy is
# required:
#
#   tls_self_signed_cert.dlpod_ca  — self-signed CA (CA:TRUE, cert_signing)
#   tls_locally_signed_cert.dlpod  — server cert signed by CA (CA:FALSE, server_auth)
#
# The CA cert PEM is exported as ca_cert_pem. Pass it to any AIG or upstream
# proxy that needs to verify the DLPoD TLS chain.
#
# Private key material lives in Terraform state. Use S3 remote state with
# SSE-KMS encryption to protect it at rest.

resource "tls_private_key" "dlpod_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "dlpod_ca" {
  private_key_pem = tls_private_key.dlpod_ca.private_key_pem

  subject {
    common_name  = "Netskope POV DLPoD CA"
    organization = "Netskope POV"
  }

  validity_period_hours = 8760
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

resource "tls_private_key" "dlpod" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "dlpod" {
  private_key_pem = tls_private_key.dlpod.private_key_pem

  subject {
    common_name  = var.system_hostname != "" ? var.system_hostname : var.appliance_name
    organization = "Netskope POV"
  }

  # Always include the private IP as an IP SAN.
  # Include the hostname as a DNS SAN when set — the AIG Go TLS stack resolves
  # the host string against DNS SANs; a bare IP host fails verification even
  # when an IP SAN is present (see aig.tf dlp.host comment).
  ip_addresses = [var.dlpod_private_ip]
  dns_names    = var.system_hostname != "" ? [var.system_hostname] : []
}

resource "tls_locally_signed_cert" "dlpod" {
  cert_request_pem   = tls_cert_request.dlpod.cert_request_pem
  ca_private_key_pem = tls_private_key.dlpod_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.dlpod_ca.cert_pem

  validity_period_hours = 8760
  is_ca_certificate     = false

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

locals {
  # ── AMI map ───────────────────────────────────────────────────────────────────
  # DLPoD 141 AMIs per region. Override with var.dlpod_ami_id for other regions.
  dlpod_ami_map = {
    us-east-2      = "ami-0243cf88485fd4bc6"
    us-west-1      = "ami-0854b3cf767442e81"
    us-west-2      = "ami-0f4949c5514a641b5"
    eu-central-1   = "ami-08fdd8e9b27d936fb"
    ap-southeast-1 = "ami-0dcf398010bb5985a"
  }

  dlpod_ami_id = coalesce(var.dlpod_ami_id, lookup(local.dlpod_ami_map, var.aws_region, null))

  # DLP host URL for the AIG bootstrap secret dlp.host field.
  # Prefer hostname over bare IP — the AIG Go TLS stack validates the cert
  # against the host string; a bare IP fails verification even with an IP SAN.
  dlp_host = "https://${var.system_hostname != "" ? var.system_hostname : var.dlpod_private_ip}"

  # DNS — secondary is optional; omit the key rather than passing an empty string.
  _dns = merge(
    { primary = var.dns_primary },
    var.dns_secondary != "" ? { secondary = var.dns_secondary } : {}
  )

  # Interface — always DHCP on EC2. The hypervisor NIC is DHCP-assigned
  # regardless of what the appliance OS configures; static mode is only
  # applicable for bare-metal / VMware deployments.
  _interface = {
    v4 = { dhcp = { enable = true } }
  }

  # System — licensekey is required; hostname and timezone are optional.
  _system = merge(
    { licensekey = var.dlpod_licensekey },
    var.system_hostname != "" ? { hostname = var.system_hostname } : {},
    var.system_timezone != "" ? { timezone = var.system_timezone } : {}
  )

  # Final bootstrap.json — only top-level keys defined in the appliance schema.
  bootstrap = merge(
    { persona = var.persona },
    { dns = local._dns },
    { interface = local._interface },
    { system = local._system },
    { dlpaas = {
      "server-cert"                  = tls_locally_signed_cert.dlpod.cert_pem
      "server-key"                   = tls_private_key.dlpod.private_key_pem_pkcs8
      "server-intermediate-ca-chain" = tls_self_signed_cert.dlpod_ca.cert_pem
    }}
  )
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "dlpod" {
  ami                    = local.dlpod_ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = var.dlpod_private_ip # null = AWS assigns from subnet
  iam_instance_profile   = aws_iam_instance_profile.dlpod.name
  vpc_security_group_ids = [aws_security_group.dlpod.id]
  key_name               = var.key_pair_name

  # Raw JSON bootstrap config — read by nsbootstrap.service at first boot.
  # jsonencode() produces the exact JSON string that nsbootstrap expects.
  # The licensekey and other secrets are redacted from bootstrap.json.done
  # by the appliance after bootstrap completes.
  user_data = jsonencode(local.bootstrap)

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only — blocks SSRF reads of user-data
    http_put_response_hop_limit = 1
  }

  tags = { Name = var.appliance_name }

  depends_on = [aws_nat_gateway.this]
}
