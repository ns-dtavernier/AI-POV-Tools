# Netskope POV Deployment Toolkit

This repository contains Terraform templates and supporting documentation for deploying Netskope appliances in proof-of-value (POV) environments on AWS. Each module is designed for fast, repeatable, unattended deployment — no manual console or SSH steps required.

**New here?** Read [`HELP.md`](HELP.md) — an "I want to…" index, FAQ and glossary. If you use Claude Code, open this folder and ask; `CLAUDE.md` gives it context and `/pov-preflight`, `/pov-deploy`, `/pov-troubleshoot` and `/pov-teardown` guide each step. `scripts/preflight.sh <template-dir>` runs the readiness checks from a plain shell.

---

## Modules

### AI Services — All (AIG + Guardrails + DLPoD)

Deploys the complete Netskope AI Services stack — AI Gateway, AI Guardrails GPU service, and DLP On-Demand — in a single `terraform apply`. All three appliances are zero-touch provisioned and wired together automatically.

| Option | Directory | Best for |
|--------|-----------|---------|
| [New VPC — public AIG](ai-services-all/new-vpc-public/README.md) | `ai-services-all/new-vpc-public/` | Starting from scratch; full stack in a new VPC, AIG with public Elastic IP |

**This is the recommended template for a full-stack POV.** It deploys everything in one apply with readiness gates and the AIG↔DLPoD DNS/TLS wiring done for you. Use the individual module templates below only when a single component is needed, or when the combined stack is not wanted and the components are to be deployed one at a time — in that case follow the order in [`STAGED-BUILD.md`](STAGED-BUILD.md).

---

### AI Gateway (AIG)

Deploys the AI Gateway only.

Three deployment options are provided, covering the most common network topologies encountered in POVs:

| Option | Directory | Best for                                                                                   |
|--------|-----------|--------------------------------------------------------------------------------------------|
| [Existing VPC](aig/existing-vpc/README.md) | `aig/existing-vpc/` | You already have a VPC and subnet in AWS and perhaps already deployed guardrails and DLPoD |
| [New VPC — public subnet](aig/new-vpc-public/README.md) | `aig/new-vpc-public/` | Fastest setup; gateway directly reachable from the internet                                |
| [New VPC — private subnet](aig/new-vpc-private/README.md) | `aig/new-vpc-private/` | Production-like; no inbound internet exposure, outbound via NAT                            |

The gateway self-enrolls at first boot using an enrollment token stored in AWS Secrets Manager — no interactive steps required after `terraform apply`.

**Start here:** [aig/README.md](aig/README.md)

---

### AI Guardrails — GPU

Deploys the Guardrails Docker container on an Ubuntu 22.04 EC2 GPU instance.

| Option | Directory | Best for |
|--------|-----------|---------|
| [Existing VPC](gpu-guardrails/existing-vpc/README.md) | `gpu-guardrails/existing-vpc/` | You already have a VPC and subnet with outbound internet access |
| [New VPC — private subnet](gpu-guardrails/new-vpc-private/README.md) | `gpu-guardrails/new-vpc-private/` | Starting from scratch; GPU instance in a private subnet behind NAT |

Setup is automated via a two-phase UserData script — NVIDIA drivers are installed and the instance reboots, then Docker and the Guardrails container are started automatically.

**Start here:** [gpu-guardrails/README.md](gpu-guardrails/README.md)

---

### DLP On-Demand (DLPoD)

Deploys DLP On-Demand, which provides cloud-delivered data loss prevention inspection. The appliance is zero-touch provisioned via EC2 user-data — no SSH or manual console steps are required.

| Option | Directory | Best for |
|--------|-----------|---------|
| [Existing VPC](dlpod/existing-vpc/README.md) | `dlpod/existing-vpc/` | You already have a VPC and subnet; includes Route 53 for AIG → DLPoD hostname resolution |
| [New VPC — private subnet](dlpod/new-vpc-private/README.md) | `dlpod/new-vpc-private/` | Starting from scratch; DLPoD in a private subnet behind NAT |

Both templates generate a TLS certificate chain and output `dlp_host` and `ca_cert_pem` — the two values the AIG template needs to configure the DLPoD connection.

**Start here:** [dlpod/README.md](dlpod/README.md)

---

## Repository structure

```
AI-POV-Tools/
  README.md                      # This file — project overview and navigation
  HELP.md                        # "I want to…" index, FAQ, glossary
  STAGED-BUILD.md                # One-component-at-a-time deployment order (fallback)
  CLAUDE.md                      # Context for Claude Code; module choice and safety rules
  .claude/commands/              # /pov-preflight, /pov-deploy, /pov-troubleshoot, /pov-teardown, /pov-curate
  scripts/
    preflight.sh                 # Readiness checks for a template directory
    curate.sh                    # Build a customer package (Netskope SEs)
  ai-services-all/
    new-vpc-public/               # Full stack: AIG (public EIP) + Guardrails + DLPoD in one apply
  aig/                            # AI Gateway Terraform templates
    README.md                     # AIG overview and template selection guide
    deployment-role/              # Run once: least-privilege IAM role for deployment
    existing-vpc/                 # AIG in an existing VPC and subnet
    new-vpc-public/               # AIG in a new VPC with a public subnet and EIP
    new-vpc-private/              # AIG in a new VPC with a private subnet and NAT GW
    docs/                         # Troubleshooting and state management guides
  gpu-guardrails/                 # AI Guardrails GPU Terraform templates
    README.md                     # Guardrails overview, two-phase setup, and AIGW registration
    existing-vpc/                 # GPU instance in an existing VPC and subnet
    new-vpc-private/              # GPU instance in a new VPC with a private subnet and NAT GW
  dlpod/                          # DLP On-Demand Terraform templates
    README.md                     # DLPoD overview and template selection guide
    docs/                         # bootstrap.json (ZTP) schema reference
    existing-vpc/                 # DLPoD in an existing VPC, with Route 53 for hostname TLS
    new-vpc-private/              # DLPoD in a new VPC with a private subnet and NAT GW
```

---

## Common prerequisites

- **Terraform ≥ 1.5** — [download here](https://developer.hashicorp.com/terraform/install) or `brew install terraform`
- **AWS CLI profile** configured — follow the [AWS CLI configuration guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html); Terraform picks up your default profile automatically
- **Netskope REST API v2 token** — required for AIG templates; not required for standalone Guardrails or DLPoD templates. Obtain from your Netskope tenant → Settings → Tools → REST API v2

See the module-specific README for additional requirements (AMI IDs, license keys, GPU instance quotas).
