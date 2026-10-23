terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ── VPC ───────────────────────────────────────────────────────────────────────
#
# Public subnet  : NAT Gateway only — no GPU instances placed here.
# Private subnet : GPU instance lives here with no public IP.
#                  Outbound internet (apt, Docker Hub, NVIDIA repos) routes
#                  through the NAT Gateway.
#
# DNS support is required so the instance can resolve S3 and other AWS
# service endpoints at boot.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-public" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-private" }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────
#
# The GPU instance needs outbound internet to pull NVIDIA drivers, Docker CE,
# and the NVIDIA Container Toolkit during first boot.

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.this]

  tags = { Name = "${local.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = { Name = "${local.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
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

  tags = { Name = "${local.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── VPC Endpoints ─────────────────────────────────────────────────────────────
#
# S3 gateway endpoint (free) keeps image-download traffic off the NAT Gateway.
# Interface endpoints keep SSM and CloudWatch Logs traffic on the AWS backbone,
# allowing instance management without internet access.

resource "aws_security_group" "endpoints" {
  name        = "${local.name_prefix}-endpoints-sg"
  description = "Allows HTTPS from within the VPC to interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
    description = "HTTPS from VPC"
  }

  tags = { Name = "${local.name_prefix}-endpoints-sg" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.name_prefix}-s3-endpoint" }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-ssm-endpoint" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-ssmmessages-endpoint" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-ec2messages-endpoint" }
}

resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-logs-endpoint" }
}

# ── Security Group ────────────────────────────────────────────────────────────
#
# The instance has no public IP. Port 8080 should be restricted to the AIGW
# source CIDR or private network range (VPN / Transit Gateway).

resource "aws_security_group" "guardrails" {
  name        = "${local.name_prefix}-instance-sg"
  description = "Controls inbound access to the Guardrails GPU instance"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "SSH - default disables direct SSH, use SSM Session Manager"
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_service_cidr]
    description = "Guardrails LLM service - restrict to AIGW source CIDR"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound via NAT Gateway"
  }

  tags = { Name = "${local.name_prefix}-instance-sg" }
}

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "guardrails" {
  name = "${local.name_prefix}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM Session Manager — allows management access without SSH
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.guardrails.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "s3_image_download" {
  name = "s3-image-download"
  role = aws_iam_role.guardrails.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetImageObject"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.image_s3_bucket}/${var.image_s3_key}"
      },
      {
        Sid      = "ListImageBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.image_s3_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = [var.image_s3_key] }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.guardrails.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "WriteLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.guardrails.arn}:*"
    }]
  })
}

resource "aws_iam_instance_profile" "guardrails" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.guardrails.name
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "guardrails" {
  name              = "/${local.name_prefix}/guardrails"
  retention_in_days = 30
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
#
# Two-phase setup:
#   Phase 1 (UserData, first boot): install NVIDIA drivers, write Phase 2
#     script and systemd service, reboot.
#   Phase 2 (guardrails-setup.service, post-reboot): install NVIDIA Container
#     Toolkit, Docker CE, load Guardrails image from S3, start container.
#
# NOTE: terraform apply completes once the instance is created (~2 min), not
# when the service is ready (~15-30 min). Monitor via SSM Session Manager and:
#   /var/log/user-data.log        — Phase 1 progress
#   /var/log/guardrails-phase2.log — Phase 2 progress

resource "aws_instance" "guardrails" {
  ami                         = data.aws_ami.ubuntu_22_04.id
  instance_type               = var.instance_type
  iam_instance_profile        = aws_iam_instance_profile.guardrails.name
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.guardrails.id]
  associate_public_ip_address = false

  root_block_device {
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/userdata.sh.tpl", {
    aws_region      = data.aws_region.current.name
    image_s3_bucket = var.image_s3_bucket
    image_s3_key    = var.image_s3_key
  })

  user_data_replace_on_change = false

  tags = { Name = "${local.name_prefix}-guardrails" }

  depends_on = [aws_nat_gateway.this]
}
