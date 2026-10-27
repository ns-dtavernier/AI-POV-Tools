# ══════════════════════════════════════════════════════════════════════════════
# SSH keys
#
# One SSH key pair is shared by the deployment so the bastion can SSH to the AIG
# (and optionally Guardrails and DLPoD):
#
#   - keypair_existing_private_key_local_path = ""  → a private key is generated
#     and written to my-private-key.pem in the project root directory.
#   - keypair_existing_private_key_local_path = "<path>" → that private key is
#     used. A path that does not exist, or a file that is not a valid private
#     key, fails the plan.
#
# The public key is derived from the private key and imported into AWS as
# <aws_object_unique_prefix>-keypair. The private key is stored in Secrets
# Manager and downloaded by the bastion at first boot (see bastion.tf).
#
# Private key material lives in Terraform state — use S3 remote state with
# SSE-KMS encryption to protect it at rest.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  use_existing_private_key   = var.keypair_existing_private_key_local_path != ""
  generated_private_key_path = "${path.module}/my-private-key.pem"

  keypair_name        = "${var.aws_object_unique_prefix}-keypair"
  ssh_key_secret_name = "aig/${var.aws_object_unique_prefix}/ssh-private-key"
}

# ── Private key: provided or generated ────────────────────────────────────────

data "local_sensitive_file" "existing_private_key" {
  count    = local.use_existing_private_key ? 1 : 0
  filename = pathexpand(var.keypair_existing_private_key_local_path)
}

resource "tls_private_key" "ssh" {
  count     = local.use_existing_private_key ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "generated_private_key" {
  count           = local.use_existing_private_key ? 0 : 1
  filename        = local.generated_private_key_path
  content         = tls_private_key.ssh[0].private_key_pem
  file_permission = "0600"
}

locals {
  ssh_private_key = (
    local.use_existing_private_key
    ? data.local_sensitive_file.existing_private_key[0].content
    : tls_private_key.ssh[0].private_key_pem
  )

  ssh_private_key_is_openssh = startswith(trimspace(local.ssh_private_key), "-----BEGIN OPENSSH PRIVATE KEY-----")
}

# ── Public key derived from the private key ───────────────────────────────────
# Fails if the provided file is not a valid, unencrypted private key.

data "tls_public_key" "ssh" {
  private_key_pem     = local.ssh_private_key_is_openssh ? null : local.ssh_private_key
  private_key_openssh = local.ssh_private_key_is_openssh ? local.ssh_private_key : null
}

# ── AWS key pair ──────────────────────────────────────────────────────────────

resource "aws_key_pair" "this" {
  key_name   = local.keypair_name
  public_key = trimspace(data.tls_public_key.ssh.public_key_openssh)

  tags = { Name = local.keypair_name }
}

# ── Existing key pair overrides ───────────────────────────────────────────────
# A non-blank *_key_pair_name must name a key pair that already exists in
# aws_region; the lookup fails the plan otherwise. Blank → the new key pair.

data "aws_key_pair" "override" {
  for_each = toset(compact([
    var.bastion_key_pair_name,
    var.guardrails_key_pair_name,
    var.dlpod_key_pair_name,
  ]))

  key_name = each.value
}

locals {
  aig_key_pair_name        = aws_key_pair.this.key_name
  bastion_key_pair_name    = var.bastion_key_pair_name != "" ? data.aws_key_pair.override[var.bastion_key_pair_name].key_name : aws_key_pair.this.key_name
  guardrails_key_pair_name = var.guardrails_key_pair_name != "" ? data.aws_key_pair.override[var.guardrails_key_pair_name].key_name : aws_key_pair.this.key_name
  dlpod_key_pair_name      = var.dlpod_key_pair_name != "" ? data.aws_key_pair.override[var.dlpod_key_pair_name].key_name : aws_key_pair.this.key_name
}

# ── Secrets Manager: private key for the bastion ──────────────────────────────
# The name starts with "aig/" to match the deployment IAM policy.

resource "aws_secretsmanager_secret" "ssh_private_key" {
  name                    = local.ssh_key_secret_name
  description             = "SSH private key matching the ${local.keypair_name} key pair - downloaded by the bastion to SSH to the AIG"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ssh_private_key" {
  secret_id     = aws_secretsmanager_secret.ssh_private_key.id
  secret_string = local.ssh_private_key
}
