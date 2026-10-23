# ══════════════════════════════════════════════════════════════════════════════
# DLP On-Demand (DLPoD)
# ══════════════════════════════════════════════════════════════════════════════

# ── TLS: DLPoD CA + server certificate ───────────────────────────────────────
#
# DLPoD rejects CA:TRUE certs in dlpaas.server-cert. A proper two-tier
# hierarchy is required:
#
#   tls_self_signed_cert.dlpod_ca  — self-signed CA (CA:TRUE, cert_signing)
#   tls_locally_signed_cert.dlpod  — server cert signed by CA (CA:FALSE, server_auth)
#
# Bootstrap mapping:
#   dlpaas.server-cert                  → leaf server cert (CA:FALSE)
#   dlpaas.server-key                   → server private key (PKCS#8)
#   dlpaas.server-intermediate-ca-chain → CA cert
#   dlp.certificate in AIG secret       → CA cert (verifies DLPoD's TLS chain)
#
# Private key material lives in Terraform state — use S3 remote state with
# SSE-KMS encryption (see backend.hcl.example) to protect it at rest.

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
    common_name  = var.dlpod_hostname
    organization = "Netskope POV"
  }

  dns_names    = [var.dlpod_hostname]
  ip_addresses = [var.dlpod_private_ip]
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

# ── DLPoD bootstrap config ────────────────────────────────────────────────────
#
# bootstrap.json is delivered as raw JSON in EC2 user-data.
# nsbootstrap.service reads it at first boot — fail-closed on unknown keys.
# The dlpaas section installs the Terraform-generated cert so the AIG's
# dlp.certificate value matches what DLPoD actually presents over TLS.

locals {
  _dlpod_system = merge(
    {
      licensekey = var.dlpod_licensekey
    },
    var.dlpod_hostname != "" ? { hostname = var.dlpod_hostname } : {},
    var.dlpod_ssh_public_key != "" ? {
      ssh-public-keys = [{ key = var.dlpod_ssh_public_key, user = "nsadmin" }]
    } : {}
  )

  dlpod_bootstrap = {
    persona = var.dlpod_persona
    dns = {
      # VPC DNS resolver is always the VPC base address + 2
      primary = cidrhost(var.vpc_cidr, 2)
    }
    interface = {
      v4 = { dhcp = { enable = true } }
    }
    system = local._dlpod_system
    dlpaas = {
      "server-cert"                  = tls_locally_signed_cert.dlpod.cert_pem
      "server-key"                   = tls_private_key.dlpod.private_key_pem_pkcs8
      "server-intermediate-ca-chain" = tls_self_signed_cert.dlpod_ca.cert_pem
    }
  }
}

# ── DLPoD — IAM ───────────────────────────────────────────────────────────────
#
# DLPoD reads bootstrap from raw user-data — no Secrets Manager access needed.
# Instance profile is a base for operational access (add AmazonSSMManagedInstanceCore
# to aws_iam_role.dlpod if SSM Session Manager access is required).

resource "aws_iam_role" "dlpod" {
  name = "${var.dlpod_appliance_name}-role"

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
  name = "${var.dlpod_appliance_name}-instance-profile"
  role = aws_iam_role.dlpod.name
}

# ── DLPoD — Security Group ────────────────────────────────────────────────────
#
# Ingress is scoped to the AIG security group only — no other traffic reaches
# DLPoD. This mirrors the Guardrails SG pattern.

resource "aws_security_group" "dlpod" {
  name        = "${var.dlpod_appliance_name}-sg"
  description = "Netskope DLP On-Demand appliance"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "All traffic from AIG - DLP inspection and management"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.aig.id]
  }

  ingress {
    description     = "DLPoD readiness probe from Guardrails"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.guardrails.id]
  }

  egress {
    description = "All outbound - Netskope cloud, licensing, package updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.dlpod_appliance_name}-sg" }
}

# ── DLPoD — EC2 Instance ──────────────────────────────────────────────────────
#
# Private IP is pinned so the AIG bootstrap secret can embed dlp.host before
# this instance is created. IMDSv2 is enforced per the ZTP security design
# (blocks SSRF reads of user-data from within the appliance).

resource "aws_instance" "dlpod" {
  ami                    = var.dlpod_ami_id
  instance_type          = var.dlpod_instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = var.dlpod_private_ip
  iam_instance_profile   = aws_iam_instance_profile.dlpod.name
  vpc_security_group_ids = [aws_security_group.dlpod.id]
  key_name               = var.dlpod_key_name

  # Raw JSON bootstrap.json — read by nsbootstrap.service at first boot.
  user_data = jsonencode(local.dlpod_bootstrap)

  # High IOPS during initialization speeds up nsbootstrap significantly.
  # The appliance engineer recommends 9000 IOPS GP3 for init. This can be
  # reduced to 3000 after the appliance is configured to avoid ongoing cost.
  root_block_device {
    volume_type           = "gp3"
    iops                  = 9000
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  tags = { Name = var.dlpod_appliance_name }

  depends_on = [aws_nat_gateway.this]
}

# ── DLPoD readiness gate ───────────────────────────────────────────────────────
#
# DLPoD bootstrap (nsbootstrap.service) applies the dlpaas cert and starts the
# HTTPS service on port 443. This takes several minutes after the instance
# launches. This null_resource uses SSM Send Command on the Guardrails instance
# (same VPC, SSM-accessible) to curl DLPoD port 443 and block AIG creation
# until the TLS service is actually accepting connections.
#
# Depends on guardrails_ready so the Guardrails SSM agent is confirmed active
# before we try to use it as a proxy for the connectivity check.

resource "null_resource" "dlpod_ready" {
  triggers = {
    instance_id = aws_instance.dlpod.id
  }

  provisioner "local-exec" {
    command = <<-EOF
      echo "Waiting for DLPoD HTTPS service to become ready (up to 20 minutes)..."
      GUARDRAILS="${aws_instance.guardrails.id}"
      DLPOD_IP="${aws_instance.dlpod.private_ip}"
      REGION="${var.aws_region}"
      n=0
      until
        CMDID=$(aws ssm send-command \
          --region "$REGION" \
          --instance-ids "$GUARDRAILS" \
          --document-name "AWS-RunShellScript" \
          --parameters "commands=[\"curl -sk --max-time 5 https://$DLPOD_IP/ -o /dev/null && echo PORT_OPEN || echo PORT_CLOSED\"]" \
          --query "Command.CommandId" \
          --output text 2>/dev/null) && \
        sleep 8 && \
        aws ssm get-command-invocation \
          --region "$REGION" \
          --command-id "$CMDID" \
          --instance-id "$GUARDRAILS" \
          --query "StandardOutputContent" \
          --output text 2>/dev/null | grep -q "PORT_OPEN"
      do
        n=$((n + 1))
        if [ $n -ge 40 ]; then
          echo "ERROR: DLPoD HTTPS service did not become ready within 20 minutes."
          exit 1
        fi
        printf "  still waiting... %s\n" "$(date '+%H:%M:%S')"
        sleep 22
      done
      echo "DLPoD HTTPS service is ready. Creating AIG instance."
    EOF
  }

  depends_on = [
    null_resource.guardrails_ready,
    aws_instance.dlpod,
  ]
}
