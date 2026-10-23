# ══════════════════════════════════════════════════════════════════════════════
# Troubleshooting bastion — public subnet, SSM Session Manager + SSH access.
#
# DELETE THIS FILE when the POV is complete or when no longer needed.
# Removing bastion.tf removes all resources below, including the SG rules
# that allow bastion SSH → AIG, DLPoD, and Guardrails.
# ══════════════════════════════════════════════════════════════════════════════

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "bastion" {
  name = "bastion-role"

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

resource "aws_iam_instance_profile" "bastion" {
  name = "bastion-instance-profile"
  role = aws_iam_role.bastion.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "bastion" {
  name        = "bastion-sg"
  description = "Troubleshooting bastion - SSM access, full VPC egress"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All outbound - SSM, VPC troubleshooting"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "bastion-sg" }
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

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  key_name                    = var.bastion_key_name
  associate_public_ip_address = true

  # Install and start the SSM agent — required for Session Manager on Ubuntu
  user_data = <<-EOF
    #!/bin/bash
    snap install amazon-ssm-agent --classic
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
    systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
  EOF

  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = { Name = "pov-bastion" }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "bastion_instance_id" {
  description = "Bastion instance ID — use with: aws ssm start-session --target <id> --region <region>"
  value       = aws_instance.bastion.id
}

output "bastion_ssm_connect_command" {
  description = "SSM connect command for the bastion"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}"
}
