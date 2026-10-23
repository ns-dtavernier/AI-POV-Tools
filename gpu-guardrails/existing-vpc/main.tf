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

# ── Security Group ────────────────────────────────────────────────────────────
#
# Created in the existing VPC. Port 8080 should be restricted to the AIGW
# source CIDR or private network range.

resource "aws_security_group" "guardrails" {
  name        = "${local.name_prefix}-instance-sg"
  description = "Controls inbound access to the Guardrails GPU instance"
  vpc_id      = var.vpc_id

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
    description = "All outbound — required for apt, Docker Hub, and NVIDIA repos"
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
# Placed in the provided subnet with no public IP assigned.
# The subnet must have outbound internet access (via NAT Gateway or IGW route)
# for Phase 1 and Phase 2 setup to complete successfully.
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
  subnet_id                   = var.subnet_id
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
}
