# ══════════════════════════════════════════════════════════════════════════════
# Troubleshooting bastion — public subnet, SSM Session Manager + SSH access.
#
# DELETE THIS FILE when the POV is complete or when no longer needed.
# Removing bastion.tf removes all resources below, including the SG rules
# that allow bastion SSH → AIG, DLPoD, and Guardrails.
# ══════════════════════════════════════════════════════════════════════════════

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "bastion" {
  name = "${local.bastion_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read the SSH private key (matches the AIG key pair) from Secrets Manager
resource "aws_iam_role_policy" "bastion_read_ssh_key" {
  name = "${local.bastion_name}-read-ssh-private-key"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadSSHPrivateKeySecret"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.ssh_private_key.arn
    }]
  })
}

# Read the lab root CA key and certificate (for signing the AIG CSR) from Secrets Manager
resource "aws_iam_role_policy" "bastion_read_ca" {
  name = "${local.bastion_name}-read-ca"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadCASecrets"
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        aws_secretsmanager_secret.ca_key.arn,
        aws_secretsmanager_secret.ca_cert.arn,
      ]
    }]
  })
}

# Let the AIG certificate setup script check that the AIG instance is running.
# ec2:DescribeInstances does not support resource-level permissions.
resource "aws_iam_role_policy" "bastion_describe_aig" {
  name = "${local.bastion_name}-describe-instances"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DescribeInstances"
      Effect   = "Allow"
      Action   = "ec2:DescribeInstances"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.bastion_name}-instance-profile"
  role = aws_iam_role.bastion.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "bastion" {
  name        = "${local.bastion_name}-sg"
  description = "Troubleshooting bastion - SSM access, full VPC egress"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All outbound - SSM, VPC troubleshooting"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.bastion_name}-sg" }
}

# Allow bastion to reach DLPoD on port 443 (TLS cert check, curl)
resource "aws_security_group_rule" "dlpod_from_bastion" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.dlpod.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "DLPoD HTTPS from bastion (troubleshooting)"
}

# Allow bastion to SSH to DLPoD
resource "aws_security_group_rule" "dlpod_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.dlpod.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "DLPoD SSH from bastion (troubleshooting)"
}

# Allow DLPoD to SCP debug packages to the bastion
resource "aws_security_group_rule" "bastion_ssh_from_dlpod" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.bastion.id
  source_security_group_id = aws_security_group.dlpod.id
  description              = "SSH from DLPoD (debug package SCP)"
}

# Allow bastion to reach Guardrails on port 8080 (health check, ping)
resource "aws_security_group_rule" "guardrails_from_bastion" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.guardrails.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "Guardrails health check from bastion (troubleshooting)"
}

# Allow bastion to SSH to Guardrails
resource "aws_security_group_rule" "guardrails_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.guardrails.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "Guardrails SSH from bastion (troubleshooting)"
}

# Allow bastion to SSH to AIG
resource "aws_security_group_rule" "aig_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aig.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "AIG SSH from bastion (troubleshooting)"
}

# Allow bastion to reach AIG on port 8443 (configuration API)
resource "aws_security_group_rule" "aig_config_api_from_bastion" {
  type                     = "ingress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aig.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "AIG configuration API from bastion (certificate setup)"
}

# ── AIG certificate setup (runs on the bastion at every boot) ─────────────────
#
# templates/aig-cert-setup.sh is installed as aig-cert-setup.service. It reads
# its settings from /etc/aig-cert-setup.conf, written from the values below.
# The AIG is found at runtime by its Name tag, so the bastion does not depend on
# (or wait for) the AIG instance — only on its Elastic IP.

locals {
  aig_cert_key_algorithm_effective = coalesce(var.aig_cert_key_algorithm, "ecdsa")

  # CSR request fields other than common_name (always aig_fqdn). Unset values are
  # omitted; key size applies only to rsa and key curve only to ecdsa.
  aig_csr_fields = {
    for k, v in {
      organization      = var.aig_cert_organization
      organization_unit = var.aig_cert_organization_unit
      email             = var.aig_cert_email
      country           = var.aig_cert_country
      state             = var.aig_cert_state
      city              = var.aig_cert_city
      key_algorithm     = var.aig_cert_key_algorithm
      key_size          = local.aig_cert_key_algorithm_effective == "rsa" ? var.aig_cert_key_size : null
      key_curve         = local.aig_cert_key_algorithm_effective == "ecdsa" ? var.aig_cert_key_curve : null
    } : k => v if v != null
  }

  # Single-quote-safe for embedding in the shell config file
  aig_csr_fields_shell = replace(jsonencode(local.aig_csr_fields), "'", "'\\''")

}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  private_ip             = var.bastion_private_ip
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  key_name                    = local.bastion_key_pair_name
  associate_public_ip_address = true

  # Install and start the SSM agent — required for Session Manager on Ubuntu.
  # Then download from Secrets Manager:
  #   - the SSH private key into ~/.ssh of both the ubuntu user (SSH logins) and
  #     ssm-user (Session Manager's default OS user), so the bastion can SSH to
  #     the AIG from either;
  #   - the lab root CA key and certificate into /home/ssm-user/, for signing
  #     the AIG CSR.
  # ssm-user is normally created by the SSM agent at the first session; it is
  # created here instead so its home exists, with the same passwordless sudo the
  # agent grants. The IAM role policies can take a few seconds to propagate, so
  # each download is retried.
  # Finally installs jq and the aig-cert-setup service (see the locals above).
  user_data = <<-EOF
    #!/bin/bash
    snap install amazon-ssm-agent --classic
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
    systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

    snap install aws-cli --classic

    id ssm-user >/dev/null 2>&1 || useradd -m -s /bin/bash ssm-user
    echo "ssm-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ssm-agent-users
    chmod 440 /etc/sudoers.d/ssm-agent-users

    umask 077
    TMPFILE=$(mktemp)

    # fetch_secret <secret-id> <destination> <mode> <owner>
    fetch_secret() {
      for i in $(seq 1 30); do
        if /snap/bin/aws secretsmanager get-secret-value \
            --region ${var.aws_region} \
            --secret-id "$1" \
            --query SecretString --output text > "$TMPFILE"; then
          install -m "$3" -o "$4" -g "$4" "$TMPFILE" "$2"
          return 0
        fi
        sleep 10
      done
      return 1
    }

    for U in ubuntu ssm-user; do
      D=/home/$U/.ssh
      install -d -m 700 -o $U -g $U $D
      fetch_secret ${aws_secretsmanager_secret.ssh_private_key.name} "$D/${local.keypair_name}.pem" 600 $U
      printf 'Host *\n  IdentityFile %s\n' "$D/${local.keypair_name}.pem" > $D/config
      chown $U:$U $D/config
      chmod 600 $D/config
    done

    fetch_secret ${aws_secretsmanager_secret.ca_key.name} /home/ssm-user/${local.ca_file_stem}-key.pem 600 ssm-user
    fetch_secret ${aws_secretsmanager_secret.ca_cert.name} /home/ssm-user/${local.ca_file_stem}-cert.pem 644 ssm-user

    rm -f "$TMPFILE"

    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq

    # AIG certificate setup: runs at every boot until it completes, then exits at once
    cat > /etc/aig-cert-setup.conf <<'CONF'
    REGION=${var.aws_region}
    AIG_NAME=${local.aig_name}
    AIG_PRIVATE_IP=${var.aig_private_ip}
    AIG_FQDN=${local.aig_fqdn}
    GUARDRAILS_HOST=${local.guardrails_host}
    SSH_KEY=/home/ssm-user/.ssh/${local.keypair_name}.pem
    CA_KEY=/home/ssm-user/${local.ca_file_stem}-key.pem
    CA_CERT=/home/ssm-user/${local.ca_file_stem}-cert.pem
    CA_SERIAL=/home/ssm-user/${local.ca_file_stem}-cert.srl
    CERT_DAYS=${var.aig_cert_validity_period_days}
    CSR_FIELDS='${local.aig_csr_fields_shell}'
    CONF

    cat > /usr/local/bin/aig-cert-setup.sh <<'SCRIPT'
    ${file("${path.module}/templates/aig-cert-setup.sh")}
    SCRIPT
    chmod 755 /usr/local/bin/aig-cert-setup.sh

    cat > /etc/systemd/system/aig-cert-setup.service <<'UNIT'
    [Unit]
    Description=AIG certificate setup
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/aig-cert-setup.sh

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable aig-cert-setup.service
    systemctl start --no-block aig-cert-setup.service
  EOF

  user_data_replace_on_change = true

  depends_on = [
    aws_iam_role_policy.bastion_read_ssh_key,
    aws_secretsmanager_secret_version.ssh_private_key,
    aws_iam_role_policy.bastion_read_ca,
    aws_secretsmanager_secret_version.ca_key,
    aws_secretsmanager_secret_version.ca_cert,
    aws_iam_role_policy.bastion_describe_aig,
  ]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = { Name = local.bastion_name }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "bastion_instance_id" {
  description = "Bastion instance ID — use with: aws ssm start-session --target <id> --region <region>"
  value       = aws_instance.bastion.id
}

output "bastion_private_ip" {
  description = "Private IP of the bastion (public subnet)"
  value       = aws_instance.bastion.private_ip
}

output "bastion_ssm_connect_command" {
  description = "SSM connect command for the bastion"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}"
}
