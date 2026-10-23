# ══════════════════════════════════════════════════════════════════════════════
# AI Guardrails (GPU LLM inference service)
# ══════════════════════════════════════════════════════════════════════════════

# ── Guardrails — Security Group ───────────────────────────────────────────────
#
# All traffic ingress is scoped to the AIG security group — only the AIG
# appliance in this VPC can call the Guardrails service. The Guardrails
# instance has no public IP so there is no internet exposure.

resource "aws_security_group" "guardrails" {
  name        = "${local.guardrails_prefix}-instance-sg"
  description = "Controls inbound access to the Guardrails GPU instance"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "All traffic from AIG - LLM inference, health checks, future ports"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.aig.id]
  }

  egress {
    description = "All outbound via NAT Gateway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.guardrails_prefix}-instance-sg" }
}

# ── Guardrails — IAM ──────────────────────────────────────────────────────────

resource "aws_iam_role" "guardrails" {
  name = "${local.guardrails_prefix}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM Session Manager — management access without SSH
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

resource "aws_iam_role_policy" "guardrails_ready_signal" {
  name = "guardrails-ready-signal"
  role = aws_iam_role.guardrails.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "WriteReadinessSignal"
      Effect = "Allow"
      Action = [
        "ssm:PutParameter",
        "ssm:DeleteParameter",
      ]
      Resource = "arn:aws:ssm:${data.aws_region.current.name}:*:parameter/${local.guardrails_prefix}/guardrails-ready"
    }]
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
  name = "${local.guardrails_prefix}-instance-profile"
  role = aws_iam_role.guardrails.name
}

# ── Guardrails — CloudWatch Log Group ────────────────────────────────────────

resource "aws_cloudwatch_log_group" "guardrails" {
  name              = "/${local.guardrails_prefix}/guardrails"
  retention_in_days = 30
}

# ── Guardrails — EC2 Instance ─────────────────────────────────────────────────
#
# The private IP is pinned (var.guardrails_private_ip) so the bootstrap secret
# can embed the Guardrails host URL before this instance is created.
#
# Two-phase setup:
#   Phase 1 (UserData, first boot): install NVIDIA drivers, write Phase 2
#     script and systemd service, reboot.
#   Phase 2 (guardrails-setup.service, post-reboot): install NVIDIA Container
#     Toolkit, Docker CE, load Guardrails image from S3, start container.
#
# terraform apply completes when the instance is created (~2 min). The full
# Guardrails setup takes 15-30 min. Monitor via SSM Session Manager:
#   /var/log/user-data.log          -- Phase 1 progress
#   /var/log/guardrails-phase2.log  -- Phase 2 progress

resource "aws_instance" "guardrails" {
  ami                         = data.aws_ami.ubuntu_22_04.id
  instance_type               = var.guardrails_instance_type
  iam_instance_profile        = aws_iam_instance_profile.guardrails.name
  key_name                    = var.guardrails_key_pair_name != "" ? var.guardrails_key_pair_name : null
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.guardrails.id]
  associate_public_ip_address = false
  private_ip                  = var.guardrails_private_ip

  root_block_device {
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/userdata.sh.tpl", {
    aws_region        = data.aws_region.current.name
    image_s3_bucket   = var.image_s3_bucket
    image_s3_key      = var.image_s3_key
    guardrails_prefix = local.guardrails_prefix
  })

  user_data_replace_on_change = false

  tags = { Name = "${local.guardrails_prefix}-guardrails" }

  depends_on = [aws_nat_gateway.this]
}

# ── Guardrails readiness gate ─────────────────────────────────────────────────
#
# The Guardrails two-phase setup takes 15-30 minutes. This null_resource polls
# an SSM Parameter that the Guardrails userdata script writes once the /ping
# endpoint returns Healthy. The AIG instance depends on this resource so it is
# not created until the Guardrails service is actually ready — preventing the
# "unlinked" state that results when the AIG tries to validate the host before
# the container is running.
#
# The trigger on instance ID ensures this re-runs if Guardrails is replaced.

resource "null_resource" "guardrails_ready" {
  triggers = {
    instance_id = aws_instance.guardrails.id
  }

  provisioner "local-exec" {
    command = <<-EOF
      echo "Purging stale readiness parameter from any previous deployment..."
      aws ssm delete-parameter \
          --name "/${local.guardrails_prefix}/guardrails-ready" \
          --region ${var.aws_region} 2>/dev/null || true

      echo "Waiting for Guardrails service to become healthy (up to 90 minutes)..."
      n=0
      until aws ssm get-parameter \
          --name "/${local.guardrails_prefix}/guardrails-ready" \
          --region ${var.aws_region} \
          --query "Parameter.Value" \
          --output text 2>/dev/null | grep -q "^healthy$"; do
        n=$((n + 1))
        if [ $n -ge 90 ]; then
          echo "ERROR: Guardrails did not become healthy within 90 minutes."
          exit 1
        fi
        printf "  still waiting after $n minutes... %s\n" "$(date '+%H:%M:%S')"
        sleep 60
      done
      echo "Guardrails is healthy. Creating AIG instance."
    EOF
  }

  depends_on = [aws_instance.guardrails]
}
