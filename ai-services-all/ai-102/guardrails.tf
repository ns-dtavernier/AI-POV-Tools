# ══════════════════════════════════════════════════════════════════════════════
# AI Guardrails (GPU LLM inference service)
# ══════════════════════════════════════════════════════════════════════════════

# ── Guardrails — Security Group ───────────────────────────────────────────────
#
# All traffic ingress is scoped to the AIG security group — only the AIG
# appliance in this VPC can call the Guardrails service. The Guardrails
# instance has no public IP so there is no internet exposure.

resource "aws_security_group" "guardrails" {
  name        = "${local.guardrails_name}-instance-sg"
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

  tags = { Name = "${local.guardrails_name}-instance-sg" }
}

# ── Guardrails — IAM ──────────────────────────────────────────────────────────

resource "aws_iam_role" "guardrails" {
  name = "${local.guardrails_name}-instance-role"

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

# Only created when a bucket is configured. With a custom AMI that already
# ships the LLM image, no bucket (and no S3 access) is needed.
resource "aws_iam_role_policy" "s3_image_download" {
  count = var.guardrails_llm_image_s3_bucket != "" ? 1 : 0

  name = "s3-image-download"
  role = aws_iam_role.guardrails.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetImageObject"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.guardrails_llm_image_s3_bucket}/${var.guardrails_llm_image_s3_key}"
      },
      {
        Sid      = "ListImageBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.guardrails_llm_image_s3_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = [var.guardrails_llm_image_s3_key] }
        }
      }
    ]
  })
}

# The readiness parameter is created by Terraform (so it is removed on destroy)
# but its value belongs to the instance, which writes progress and finally
# "healthy:<instance id>" to it; Terraform ignores changes to the value.
locals {
  guardrails_ready_parameter = "/${var.aws_object_unique_prefix}/guardrails-ready"
}

resource "aws_ssm_parameter" "guardrails_ready" {
  name  = local.guardrails_ready_parameter
  type  = "String"
  value = "Guardrails not started"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_iam_role_policy" "guardrails_ready_signal" {
  name = "guardrails-ready-signal"
  role = aws_iam_role.guardrails.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteReadinessSignal"
      Effect   = "Allow"
      Action   = "ssm:PutParameter"
      Resource = aws_ssm_parameter.guardrails_ready.arn
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
  name = "${local.guardrails_name}-instance-profile"
  role = aws_iam_role.guardrails.name
}

# ── Guardrails — CloudWatch Log Group ────────────────────────────────────────

resource "aws_cloudwatch_log_group" "guardrails" {
  name              = "/${var.aws_object_unique_prefix}/guardrails"
  retention_in_days = 30
}

# ── Guardrails — EC2 Instance ─────────────────────────────────────────────────
#
# The private IP is pinned (var.guardrails_private_ip) so the bootstrap secret
# can embed the Guardrails host URL before this instance is created.
#
# The AMI is var.guardrails_ami_id (custom, pre-built) or stock Ubuntu 22.04.
# The userdata checks each component (NVIDIA driver, NVIDIA Container Toolkit,
# Docker, LLM image), installs what is missing, upgrades what is present, and
# restarts the Guardrails container if anything changed.
#
# Two-phase setup:
#   Phase 1 (UserData, first boot): OS upgrade, NVIDIA driver install/upgrade,
#     write Phase 2 script and systemd service. Reboots only if the driver or
#     kernel changed; otherwise starts Phase 2 directly.
#   Phase 2 (guardrails-setup.service): install/upgrade NVIDIA Container
#     Toolkit and Docker, use the local LLM image (S3 download only if absent),
#     create/restart the container, signal readiness.
#
# terraform apply completes when the instance is created (~2 min). The full
# Guardrails setup takes ~5-30 min depending on how much the AMI already has.
# Monitor via SSM Session Manager:
#   /var/log/user-data.log          -- Phase 1 progress
#   /var/log/guardrails-phase2.log  -- Phase 2 progress

resource "aws_instance" "guardrails" {
  ami                         = var.guardrails_ami_id != "" ? var.guardrails_ami_id : data.aws_ami.ubuntu_22_04.id
  instance_type               = var.guardrails_instance_type
  iam_instance_profile        = aws_iam_instance_profile.guardrails.name
  key_name                    = local.guardrails_key_pair_name
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

  # Gzip-compressed: the rendered script is over EC2's 16 KB user-data limit
  # uncompressed. cloud-init decompresses gzip user-data automatically.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/guardrails-userdata.sh.tpl", {
    aws_region                     = data.aws_region.current.name
    guardrails_llm_image_s3_bucket = var.guardrails_llm_image_s3_bucket
    guardrails_llm_image_s3_key    = var.guardrails_llm_image_s3_key
    guardrails_ready_parameter     = local.guardrails_ready_parameter
  }))

  user_data_replace_on_change = false

  tags = { Name = local.guardrails_name }

  depends_on = [
    aws_nat_gateway.this,
    aws_ssm_parameter.guardrails_ready,
    aws_iam_role_policy.guardrails_ready_signal,
  ]
}

# ── Guardrails readiness gates ────────────────────────────────────────────────
#
# The Guardrails two-phase setup takes 15-30 minutes. These null_resources poll
# an SSM Parameter that the Guardrails userdata script writes once the /ping
# endpoint returns Healthy. Two gates share one script so each consumer can wait
# (or not) independently:
#
#   guardrails_ready            the AIG instance waits for it
#                               (var.wait_for_guardrails_to_deploy_aig)
#   guardrails_ready_for_dlpod  the DLPoD instance waits for it
#                               (var.wait_for_guardrails_to_deploy_dlpod)
#
# Waiting on the AIG avoids a failed host setting: the AIG Config API rejects the
# Guardrails host while the service is not responding, so an AIG that boots first
# completes its bootstrap but fails to set the host. The bastion script retries
# until the service is healthy and sets it then.
#
# A gate with count = 0 polls nothing, but its dependent still waits for the
# Guardrails instance to be created, because Terraform's dependencies are static.
#
# The final value is "healthy:<instance id>", so a gate passes only for this
# instance; a value left by an earlier instance can never satisfy it. Each gate
# resets the parameter to "Guardrails booting" before polling, unless it already
# reads healthy for this instance (so enabling a gate on a running deployment
# does not erase the signal). The parameter is managed by
# aws_ssm_parameter.guardrails_ready, so it is removed on destroy.

locals {
  guardrails_ready_script = <<-EOF
    CUR=$(aws ssm get-parameter \
        --name "${aws_ssm_parameter.guardrails_ready.name}" \
        --region ${var.aws_region} \
        --query "Parameter.Value" \
        --output text 2>/dev/null || true)
    WANT="healthy:${aws_instance.guardrails.id}"
    if [ "$CUR" != "$WANT" ]; then
      aws ssm put-parameter \
        --name "${aws_ssm_parameter.guardrails_ready.name}" \
        --value "Guardrails booting" \
        --type String \
        --overwrite \
        --region ${var.aws_region}
    fi

    echo "Waiting for Guardrails service to become healthy (up to 90 minutes)..."
    n=0
    while true; do
      STATUS=$(aws ssm get-parameter \
          --name "${aws_ssm_parameter.guardrails_ready.name}" \
          --region ${var.aws_region} \
          --query "Parameter.Value" \
          --output text 2>/dev/null || true)
      [ "$STATUS" = "$WANT" ] && break
      n=$((n + 1))
      if [ $n -ge 540 ]; then
        echo "ERROR: Guardrails did not become healthy within 90 minutes."
        exit 1
      fi
      [ -n "$STATUS" ] || STATUS="(guardrails-ready parameter not set yet)"
      printf "%s %s\n" "$(date '+%H:%M:%S')" "$STATUS"
      sleep 10
    done
    echo "Guardrails is healthy."
  EOF
}

resource "null_resource" "guardrails_ready" {
  count = var.wait_for_guardrails_to_deploy_aig ? 1 : 0

  triggers = {
    instance_id    = aws_instance.guardrails.id
    parameter_name = aws_ssm_parameter.guardrails_ready.name
    region         = var.aws_region
  }

  provisioner "local-exec" {
    command = local.guardrails_ready_script
  }

  depends_on = [aws_instance.guardrails]
}

resource "null_resource" "guardrails_ready_for_dlpod" {
  count = var.wait_for_guardrails_to_deploy_dlpod ? 1 : 0

  triggers = {
    instance_id    = aws_instance.guardrails.id
    parameter_name = aws_ssm_parameter.guardrails_ready.name
    region         = var.aws_region
  }

  provisioner "local-exec" {
    command = local.guardrails_ready_script
  }

  depends_on = [aws_instance.guardrails]
}
