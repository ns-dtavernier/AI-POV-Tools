# CLAUDE.md — DLP On-Demand (DLPoD) Terraform Templates

Context for Claude Code when helping with these templates. The repo-root
`CLAUDE.md` rules (secrets, destructive commands, don't-guess list) apply here.

## What this deploys

A Netskope DLPoD appliance on EC2 (`c5d.4xlarge` default), zero-touch
provisioned: Terraform builds a `bootstrap.json`, delivers it as EC2
user-data, and the appliance's `nsbootstrap.service` applies it at first
boot. Terraform also generates the TLS chain (CA + leaf) with the `tls`
provider. No SSH, console, or Netskope API calls are needed.

```
dlpod/
  README.md            # Overview, template choice, first-boot behaviour
  docs/ztp-bootstrap-reference.md   # bootstrap.json (ZTP) schema — platform-agnostic
  CLAUDE.md            # This file
  existing-vpc/        # EC2 + SG + IAM + TLS + Route 53 private zone, in your VPC
  new-vpc-private/     # + VPC, subnets, NAT GW; no Route 53 (see below)
```

`dlpod/docs/ztp-bootstrap-reference.md` documents the ZTP schema for every platform the appliance
supports (AWS, Azure, GCP, OpenStack, VMware, seed ISO). Only AWS Terraform
templates exist in this repo. If asked about Azure/GCP, point at the schema
and the per-platform user-data delivery section; do not imply templates exist.

## The two templates are not identical — check `variables.tf`

Both use `dlpod_licensekey` (→ `TF_VAR_dlpod_licensekey`) and
`key_pair_name`. They differ in:

| | `existing-vpc/` | `new-vpc-private/` |
|---|---|---|
| Hostname | `dlpod_hostname` (default `dlp.aigw.internal`) | `system_hostname` (default empty) |
| Route 53 private zone | Yes — resolves hostname → `dlpod_private_ip` | **No** |
| `dlp_host` output | `https://<dlpod_hostname>` | `https://<system_hostname>` if set, else `https://<ip>` |
| `persona` | fixed in template | variable: `dlp-on-demand` or `dspm` |
| Inspection ingress | `allowed_inspection_cidr` | `allowed_cidr_blocks` |

Always open the directory's `variables.tf` before telling a user which
variable or env var to set.

## Why hostname matters (the most common support issue)

The AIG connects to DLPoD over TLS and Go's TLS stack verifies the URL host
against the certificate's DNS SANs. A bare-IP `dlp_host` fails even though
the leaf cert carries an IP SAN. So:

- `existing-vpc/` and `ai-services-all/` put `dlpod_hostname` in the SAN
  and create a Route 53 private hosted zone so the AIG can resolve it.
- `new-vpc-private/` only adds a DNS SAN when `system_hostname` is set,
  and creates no DNS. If the AIG will use this DLPoD, set `system_hostname`
  **and** arrange resolution (Route 53 zone associated with the AIG's VPC,
  or the AIG's own DNS). Otherwise expect "certificate is valid for … not
  <ip>" in the AIG logs.

If the AIG is in a different VPC than DLPoD, associate the Route 53 zone
with that VPC (`route53_zone_id` output).

## AMI selection

Both templates carry a `dlpod_ami_map` keyed by region (DLPoD release 141)
and fall back to `var.dlpod_ami_id`. If the user's region is not in the map
and they have not set `dlpod_ami_id`, plan fails on the `coalesce`. The
AMI comes from Netskope — never guess it. The map is a convenience for the
regions Netskope has published; it goes stale with each DLPoD release.

## Outputs the AIG needs

`dlp_host` and `ca_cert_pem`. In a staged build these become `dlp_host` and
`dlp_ca_cert_pem` inputs to `aig/existing-vpc/`:

```bash
terraform output -raw dlp_host
terraform output -raw ca_cert_pem
```

`ca_cert_pem` is a public certificate, safe to paste. The private keys stay
in state — which is why state should be remote and encrypted
(`aig/docs/state-management.md`).

## Common requests

- **"How do I know bootstrap worked?"** — commands in `dlpod/docs/ztp-bootstrap-reference.md`
  §Verifying bootstrap (status file, redacted applied record, service log).
  Needs SSM or SSH to the appliance; the templates default SSH off
  (`allowed_ssh_cidr = 127.0.0.1/32`).
- **"Is the license key in state?"** — the variable is `sensitive`, so it is
  redacted from plan/output, but it is in the user-data and therefore in
  state. Treat state as secret.
- **"Can I re-run bootstrap?"** — ZTP runs once; re-running requires removing
  the record file on the appliance and has side effects (duplicate SSH keys).
  Replacing the instance (`terraform apply -replace=aws_instance.dlpod`) is
  cleaner.
- **"Email address rejected during cert request"** — no hyphen in the
  local part. Known issue in `dlpod/docs/ztp-bootstrap-reference.md`.
- **"Invalid timezone"** — falls back to UTC silently; use an exact IANA name.

## Do not change without care

- The `tls_locally_signed_cert` SAN lists. Removing the DNS SAN breaks the
  AIG connection; the IP SAN alone is not sufficient.
- Delivering `bootstrap.json` via `user_data`. The appliance reads it from
  IMDS at first boot; a different mechanism will not be applied.
- Port 443 ingress scope. It should be the AIG subnet/CIDR, not `0.0.0.0/0`.

## Verification

Answer from `main.tf`, `variables.tf`, `outputs.tf` in the template
directory and the schema in `dlpod/docs/ztp-bootstrap-reference.md`. `new-vpc-private/tests/`
has a `terraform test` file (`validation.tftest.hcl`) for static checks.
