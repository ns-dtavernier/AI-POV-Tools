# ══════════════════════════════════════════════════════════════════════════════
# Windows 11 VM (optional)
#
# Created only when var.enable_win11_vm is true. A Windows 11 desktop in the public
# subnet with an Elastic IP. RDP (TCP 3389) is allowed from
# var.win_allowed_cidr_blocks, and the VM may reach every other instance on every
# port: the AIG, DLPoD and Guardrails, and the bastion and LibreChat when they exist.
#
# AWS publishes no Windows 11 AMI for EC2. var.win11_ami_id must be your own
# licensed image (VM Import/Export, or EC2 Image Builder from an ISO). Windows 11
# BYOL generally needs dedicated hardware, hence var.win11_tenancy = "dedicated".
# ══════════════════════════════════════════════════════════════════════════════

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "win11" {
  count = var.enable_win11_vm ? 1 : 0

  name        = "${local.win11_name}-sg"
  description = "Windows 11 VM - RDP from win_allowed_cidr_blocks, full egress"
  vpc_id      = aws_vpc.this.id

  # No rule at all when the list is empty (an ingress block needs a source)
  dynamic "ingress" {
    for_each = length(var.win_allowed_cidr_blocks) > 0 ? [1] : []

    content {
      description = "RDP from win_allowed_cidr_blocks"
      from_port   = 3389
      to_port     = 3389
      protocol    = "tcp"
      cidr_blocks = var.win_allowed_cidr_blocks
    }
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.win11_name}-sg" }
}

# Let the Windows VM reach every other instance on all ports. The keys are fixed
# strings so for_each is known at plan time; the bastion and LibreChat have a group
# only when enable_bastion / enable_librechat is true.
locals {
  win11_reachable_security_groups = var.enable_win11_vm ? merge(
    {
      aig        = aws_security_group.aig.id
      dlpod      = aws_security_group.dlpod.id
      guardrails = aws_security_group.guardrails.id
    },
    var.enable_bastion ? { bastion = aws_security_group.bastion[0].id } : {},
    var.enable_librechat ? { librechat = aws_security_group.librechat[0].id } : {},
  ) : {}
}

resource "aws_security_group_rule" "from_win11" {
  for_each = local.win11_reachable_security_groups

  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = each.value
  source_security_group_id = aws_security_group.win11[0].id
  description              = "All traffic from the Windows 11 VM"
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "win11" {
  count = var.enable_win11_vm ? 1 : 0

  ami                    = var.win11_ami_id
  instance_type          = var.win11_instance_type
  tenancy                = var.win11_tenancy
  subnet_id              = aws_subnet.public.id
  private_ip             = var.win11_private_ip
  vpc_security_group_ids = [aws_security_group.win11[0].id]
  key_name               = local.win11_key_pair_name

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = local.win11_name }
}

# Stable RDP address across stop/start
resource "aws_eip" "win11" {
  count = var.enable_win11_vm ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.win11[0].id

  depends_on = [aws_internet_gateway.this]

  tags = { Name = "${local.win11_name}-eip" }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
# Null when enable_win11_vm is false.

output "win11_instance_id" {
  description = "Windows 11 VM instance ID. Null when enable_win11_vm is false."
  value       = one(aws_instance.win11[*].id)
}

output "win11_public_ip" {
  description = "Elastic IP of the Windows 11 VM — RDP to this address (TCP 3389) from win_allowed_cidr_blocks. Null when enable_win11_vm is false."
  value       = one(aws_eip.win11[*].public_ip)
}

output "win11_private_ip" {
  description = "Private IP of the Windows 11 VM (public subnet). Null when enable_win11_vm is false."
  value       = one(aws_instance.win11[*].private_ip)
}
