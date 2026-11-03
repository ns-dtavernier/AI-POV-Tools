# ══════════════════════════════════════════════════════════════════════════════
# LibreChat (optional)
#
# Created only when var.enable_librechat is true. A LibreChat chat UI on its own
# instance in the public subnet, with an Elastic IP. nginx terminates TLS on
# TCP 443 with a server certificate signed by the lab root CA (the same CA that
# signs the DLPoD certificate in dlpod.tf), and proxies to LibreChat; MongoDB runs
# alongside it. All three run in Docker Compose under /opt/librechat.
#
# Access: 443 from var.librechat_allowed_cidr_blocks. Registration is open, so
# those CIDRs are the only access control. Nothing is preconfigured: LibreChat
# starts with its defaults and no librechat.yaml (see the README for adding one).
#
# The Terraform-signed certificate and key are stored in Secrets Manager and
# downloaded by the instance at boot, so they are not in user data. The LibreChat
# secrets (JWT, credentials key) are generated on the instance at first boot, so
# they are not in Terraform state. Browsers must trust the lab root CA to avoid a
# certificate warning.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  librechat_tls_secret_name = "aig/${var.aws_object_unique_prefix}/librechat-tls"
  librechat_image           = "ghcr.io/danny-avila/librechat:${var.librechat_image_tag}"
  librechat_mongo_image     = "mongo:8.0"
  librechat_nginx_image     = "nginx:1.27-alpine"
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
# Allocated before the instance so the certificate can name its public DNS and IP.

resource "aws_eip" "librechat" {
  count = var.enable_librechat ? 1 : 0

  domain = "vpc"

  depends_on = [aws_internet_gateway.this]

  tags = { Name = "${local.librechat_name}-eip" }
}

resource "aws_eip_association" "librechat" {
  count = var.enable_librechat ? 1 : 0

  instance_id   = aws_instance.librechat[0].id
  allocation_id = aws_eip.librechat[0].id
}

# ── TLS certificate, signed by the lab root CA ────────────────────────────────
# Private key material lives in Terraform state — use S3 remote state with
# SSE-KMS encryption (see backend.hcl.example) to protect it at rest.

resource "tls_private_key" "librechat" {
  count = var.enable_librechat ? 1 : 0

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "librechat" {
  count = var.enable_librechat ? 1 : 0

  private_key_pem = tls_private_key.librechat[0].private_key_pem

  subject {
    common_name = aws_eip.librechat[0].public_dns
  }

  dns_names    = [aws_eip.librechat[0].public_dns]
  ip_addresses = [aws_eip.librechat[0].public_ip, var.librechat_private_ip]
}

resource "tls_locally_signed_cert" "librechat" {
  count = var.enable_librechat ? 1 : 0

  cert_request_pem   = tls_cert_request.librechat[0].cert_request_pem
  ca_private_key_pem = data.local_sensitive_file.ca_key.content
  ca_cert_pem        = data.local_file.ca_cert.content

  validity_period_hours = var.librechat_cert_validity_period_days * 24
  is_ca_certificate     = false

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# The name starts with "aig/" to match the deployment IAM policy. The certificate
# is stored with the lab CA appended, so clients that do not yet trust the CA can
# still read the chain.
resource "aws_secretsmanager_secret" "librechat_tls" {
  count = var.enable_librechat ? 1 : 0

  name                    = local.librechat_tls_secret_name
  description             = "LibreChat server certificate (signed by the lab root CA) and private key - downloaded by the LibreChat instance at boot"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "librechat_tls" {
  count = var.enable_librechat ? 1 : 0

  secret_id = aws_secretsmanager_secret.librechat_tls[0].id
  secret_string = jsonencode({
    cert = "${tls_locally_signed_cert.librechat[0].cert_pem}${data.local_file.ca_cert.content}"
    key  = tls_private_key.librechat[0].private_key_pem
  })
}

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "librechat" {
  count = var.enable_librechat ? 1 : 0

  name = "${local.librechat_name}-role"

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
resource "aws_iam_role_policy_attachment" "librechat_ssm" {
  count = var.enable_librechat ? 1 : 0

  role       = aws_iam_role.librechat[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "librechat_read_tls" {
  count = var.enable_librechat ? 1 : 0

  name = "${local.librechat_name}-read-tls"
  role = aws_iam_role.librechat[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadLibreChatTLSSecret"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.librechat_tls[0].arn
    }]
  })
}

resource "aws_iam_instance_profile" "librechat" {
  count = var.enable_librechat ? 1 : 0

  name = "${local.librechat_name}-instance-profile"
  role = aws_iam_role.librechat[0].name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "librechat" {
  count = var.enable_librechat ? 1 : 0

  name        = "${local.librechat_name}-sg"
  description = "LibreChat - HTTPS from librechat_allowed_cidr_blocks, full egress"
  vpc_id      = aws_vpc.this.id

  # No rule at all when the list is empty (an ingress block needs a source)
  dynamic "ingress" {
    for_each = length(var.librechat_allowed_cidr_blocks) > 0 ? [1] : []

    content {
      description = "HTTPS from librechat_allowed_cidr_blocks"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.librechat_allowed_cidr_blocks
    }
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.librechat_name}-sg" }
}

# Let LibreChat reach the AIG on 443 whatever aig_allowed_cidr_blocks says
resource "aws_security_group_rule" "aig_https_from_librechat" {
  count = var.enable_librechat ? 1 : 0

  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aig.id
  source_security_group_id = aws_security_group.librechat[0].id
  description              = "AIG HTTPS from LibreChat"
}

# Let the bastion SSH to LibreChat (troubleshooting), like the other instances
resource "aws_security_group_rule" "librechat_ssh_from_bastion" {
  count = var.enable_librechat && var.enable_bastion ? 1 : 0

  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.librechat[0].id
  source_security_group_id = aws_security_group.bastion[0].id
  description              = "LibreChat SSH from bastion (troubleshooting)"
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
# user_data_replace_on_change: changing the image tag, certificate or any part of
# the setup script replaces the instance, and with it LibreChat's chats and
# accounts (MongoDB is on the instance's disk).

resource "aws_instance" "librechat" {
  count = var.enable_librechat ? 1 : 0

  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = var.librechat_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = var.librechat_private_ip
  iam_instance_profile   = aws_iam_instance_profile.librechat[0].name
  vpc_security_group_ids = [aws_security_group.librechat[0].id]
  key_name               = local.librechat_key_pair_name

  # A temporary public IP lets first boot reach the internet (Docker, images) until
  # the Elastic IP is attached.
  associate_public_ip_address = true

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/librechat-userdata.sh.tpl", {
    region          = var.aws_region
    tls_secret_name = local.librechat_tls_secret_name
    domain          = aws_eip.librechat[0].public_dns
    librechat_image = local.librechat_image
    mongo_image     = local.librechat_mongo_image
    nginx_image     = local.librechat_nginx_image
  }))

  user_data_replace_on_change = true

  depends_on = [
    aws_iam_role_policy.librechat_read_tls,
    aws_secretsmanager_secret_version.librechat_tls,
    aws_route_table_association.public,
  ]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 40
    encrypted   = true
  }

  tags = { Name = local.librechat_name }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
# Null when enable_librechat is false.

output "librechat_url" {
  description = "LibreChat URL (HTTPS, port 443). Browse by this name: the certificate is signed by the lab root CA, which clients must trust. Null when enable_librechat is false."
  value       = var.enable_librechat ? "https://${aws_eip.librechat[0].public_dns}" : null
}

output "librechat_public_ip" {
  description = "Elastic IP of the LibreChat instance. Null when enable_librechat is false."
  value       = one(aws_eip.librechat[*].public_ip)
}

output "librechat_private_ip" {
  description = "Private IP of the LibreChat instance (public subnet). Null when enable_librechat is false."
  value       = one(aws_instance.librechat[*].private_ip)
}

output "librechat_instance_id" {
  description = "LibreChat instance ID. Null when enable_librechat is false."
  value       = one(aws_instance.librechat[*].id)
}

output "librechat_ssm_connect_command" {
  description = "SSM connect command for the LibreChat instance. Null when enable_librechat is false."
  value       = var.enable_librechat ? "aws ssm start-session --target ${aws_instance.librechat[0].id} --region ${var.aws_region}" : null
}
