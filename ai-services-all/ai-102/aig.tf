# ══════════════════════════════════════════════════════════════════════════════
# AI Gateway (AIG)
# ══════════════════════════════════════════════════════════════════════════════

# ── Netskope: register appliance + generate enrollment token ──────────────────
#
# The appliance is registered with the AIG's Elastic IP before the EC2 instance
# is created — the enrollment token depends on the appliance ID, which in turn
# depends on the known public IP. The instance self-enrolls at first boot by
# reading the bootstrap secret.

resource "netskope_aig_appliance" "this" {
  name = var.appliance_name
  host = aws_eip.aig.public_ip

  ports = {
    https = { enable = true, port = 443 }
    http  = { enable = false, port = 80 }
  }
}

resource "netskope_aig_appliance_enrollment_token" "this" {
  appliance_id = netskope_aig_appliance.this.id
}

# ── Secrets Manager: AIG bootstrap secret ─────────────────────────────────────
#
# The AIG reads this secret at first boot to self-enroll with the Netskope
# tenant. The ai_guardrails block automatically configures the Guardrails
# service host during enrollment — no manual CLI step required.
#
# dlp.host uses the hostname (not bare IP) because the AIG's Go TLS stack
# validates the certificate against the host string. A bare IP causes
# verification against an empty string even when an IP SAN is present.
# Route 53 resolves var.dlpod_hostname → var.dlpod_private_ip within the VPC.

resource "aws_secretsmanager_secret" "aig_bootstrap" {
  name                    = var.secret_name
  description             = "Netskope AIG automated bootstrap — enrollment token and AI Guardrails config"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "aig_bootstrap" {
  secret_id = aws_secretsmanager_secret.aig_bootstrap.id
  secret_string = jsonencode({
    bootstrap        = true
    enrollment_token = netskope_aig_appliance_enrollment_token.this.enrollment_token
    ai_guardrails = {
      host = "http://${var.guardrails_private_ip}:8080/invocations"
    }
    dlp = {
      certificate = tls_self_signed_cert.dlpod_ca.cert_pem
      host        = "https://${var.dlpod_hostname}"
    }
  })
}

# ── AIG — IAM ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "aig" {
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

resource "aws_iam_role_policy" "aig_read_secret" {
  name = "${var.appliance_name}-read-bootstrap-secret"
  role = aws_iam_role.aig.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadAIGBootstrapSecret"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.aig_bootstrap.arn
    }]
  })
}

resource "aws_iam_instance_profile" "aig" {
  name = "${var.appliance_name}-instance-profile"
  role = aws_iam_role.aig.name
}

# ── AIG — Security Group ──────────────────────────────────────────────────────

resource "aws_security_group" "aig" {
  name        = "${var.appliance_name}-sg"
  description = "Netskope AI Gateway"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS proxy"
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

# ── AIG — EC2 Instance ────────────────────────────────────────────────────────

resource "aws_instance" "aig" {
  ami                    = var.aig_ami_id
  instance_type          = var.aig_instance_type
  subnet_id              = aws_subnet.public.id
  iam_instance_profile   = aws_iam_instance_profile.aig.name
  vpc_security_group_ids = [aws_security_group.aig.id]
  key_name               = var.aig_key_name

  user_data = jsonencode({
    bootstrap_secret = aws_secretsmanager_secret.aig_bootstrap.name
  })

  tags = { Name = var.appliance_name }

  depends_on = [
    aws_secretsmanager_secret_version.aig_bootstrap,
    null_resource.guardrails_ready,
    null_resource.dlpod_ready,
  ]
}

resource "aws_eip_association" "aig" {
  instance_id   = aws_instance.aig.id
  allocation_id = aws_eip.aig.id
}
