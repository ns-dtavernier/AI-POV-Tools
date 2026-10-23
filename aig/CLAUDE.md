# CLAUDE.md — AI Gateway Terraform Templates

Context for Claude Code when helping with these templates. The repo-root
`CLAUDE.md` rules (secrets, destructive commands, don't-guess list) apply here.

## What this project does

Deploys a Netskope AI Gateway (AIG) appliance on AWS EC2 using automated
Secrets Manager bootstrap. The appliance self-enrolls at first boot — no SSH
or manual CLI required. Three deployment options share identical Netskope,
IAM, and Secrets Manager logic; only the networking layer differs.

## Directory structure

```
aig/
  README.md               # User-facing getting started guide + bootstrap mechanism
  CLAUDE.md               # This file
  main.tf                 # Comment-only redirect — not a Terraform root
  deployment-role/        # Run first, once per account: least-privilege deploy role
  existing-vpc/           # Option 1: bring your own VPC and subnet
  new-vpc-public/         # Option 2: new VPC, AIG in public subnet with EIP
  new-vpc-private/        # Option 3: new VPC, AIG in private subnet + NAT GW
  docs/
    iam-permissions.md    # Deployer IAM policy with scoping rationale
    troubleshooting.md    # Enrollment and connectivity diagnostics
    state-management.md   # S3 + KMS + DynamoDB remote state
  tests/                  # pytest: static (mock providers) and integration (real AWS)
```

Each option subdirectory is a self-contained Terraform root with its own
`main.tf`, `variables.tf`, `outputs.tf`, and `terraform.tfvars.example`.

## Helping a user choose an option

1. **Existing VPC?** Yes → `existing-vpc/`
2. **Must the AIG be reachable from the internet?**
   - Yes / quickest demo → `new-vpc-public/`
   - No / production-like → `new-vpc-private/` (recommended default for a real POV)

`new-vpc-public/` has the simplest tfvars. `new-vpc-private/` is the most complete.

## Step 0 — deployment role

`deployment-role/` must be applied once per AWS account before any option,
and the resulting role assumed. Its policy is scoped by name prefixes
(`aig-*` resources, `aig/*` secrets) that match the template defaults.
If a user changes `appliance_name` or `secret_name` away from those
prefixes, the role will deny them. Full rationale and the JSON policy:
`docs/iam-permissions.md`.

## Key design decisions (understand before changing)

### Fixed private IP (`aig_private_ip`) in `new-vpc-private`
Terraform must register the AIG appliance in Netskope (`netskope_aig_appliance`)
before the EC2 instance exists, because the enrollment token depends on the
appliance ID. The `host` field on that resource requires a known address.
Pinning `private_ip = var.aig_private_ip` on the instance makes the address
deterministic at plan time. Do not remove this without an alternative
solution to the ordering problem.

### EIP allocated before EC2 in `new-vpc-public`
Same ordering problem solved differently: an Elastic IP is allocated first,
its `public_ip` is used as the appliance `host`, and the EIP is associated
with the instance after creation.

### `appliance_host` variable in `existing-vpc`
No Terraform-controlled infrastructure gives a predictable address before
EC2 creation, so the user supplies the expected IP or hostname. The AIG
still self-enrolls via the token — `host` is for display in the Netskope
UI, not for the enrollment handshake.

### Inline IAM policy (not managed policy)
The instance role's `secretsmanager:GetSecretValue` grant is an inline
`aws_iam_role_policy`, so deleting the role deletes the policy. Correct for
a scoped POV deployment.

### `recovery_window_in_days = 0` on the secret
Allows destroy/apply cycles to reuse the same secret name without the
7-day AWS deletion delay. Appropriate for a POV; flag it for production.

### Provider credentials
The `netskopeoss/netskope` provider reads `NETSKOPE_SERVER_URL` and
`NETSKOPE_API_KEY` from the environment. The `variables.tf` files also
declare `netskope_server_url` / `netskope_api_key` as a fallback — **do not
recommend setting those in tfvars**; the values would be written to state.
OAuth2 is supported via `NETSKOPE_OAUTH2_CLIENT_ID` and
`NETSKOPE_OAUTH2_CLIENT_SECRET`.

`NETSKOPE_API_KEY` is sent as the `Netskope-Api-Token` header on every API
call. Any test code or script that talks to the Netskope REST API directly
must use the same env var and header name.

### Enrollment token TTL
`netskope_aig_appliance_enrollment_token` is a create-only resource whose
token expires 24 hours after `terraform apply`. If the instance has not
enrolled in time, run `terraform apply` again — it generates and stores a
fresh token. Do not try to import or refresh this resource.

## Common tasks users may ask for

- **"How do I verify the AIG enrolled?"** — README verification section.
  API: `GET /api/v2/aig/appliances`; status `connected` means enrolled and healthy.
- **"I need to re-enroll / the token expired"** — `terraform apply` from the
  same directory. The token resource is replaced and the secret updated.
- **"I want to add DLP or AI Guardrails at bootstrap"** — Add the `dlp` or
  `ai_guardrails` block to the `secret_string` in
  `aws_secretsmanager_secret_version`. The schema is in `aig/README.md`
  §"Bootstrap secret schema". `existing-vpc/` already exposes these as the
  `guardrails_host`, `dlp_host`, and `dlp_ca_cert_pem` variables for staged builds.
- **"I want to use a different AWS region"** — Change `aws_region` and
  `availability_zone` in tfvars, and supply the AMI ID for that region.
- **"The appliance name is too long"** — Netskope enforces 15 characters;
  `appliance_name` has a `validation` block enforcing this at plan time.
- **"Access denied during apply"** — almost always the deployment role's
  prefix conditions vs. a renamed `appliance_name`/`secret_name`. See
  `docs/iam-permissions.md`.

## What not to change without careful thought

- The `depends_on` blocks on `aws_instance` — they ensure the secret and
  network route are ready before the instance boots.
- The `netskope_aig_appliance` → `netskope_aig_appliance_enrollment_token`
  → `aws_secretsmanager_secret_version` → `aws_instance` dependency chain.
  Breaking this order makes enrollment fail silently.
- The `aig-*` / `aig/*` naming prefixes, unless the deployment role policy
  is updated in step.

## Verification

Answer from the `.tf` files in the option directory and `aig/README.md`.
`tests/README.md` describes the static and integration test layers.
