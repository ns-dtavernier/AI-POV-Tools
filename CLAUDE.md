# CLAUDE.md — Netskope POV Deployment Toolkit

Context for Claude Code when helping a Netskope SE or a customer use this
repository. Read this first; each module has its own `CLAUDE.md` with deeper
detail that loads automatically when you work inside that directory.

Two kinds of people use this repo:

| Who | What they want | Start them at |
|-----|----------------|---------------|
| **Netskope SE** | Build a customer-specific package, run POVs, troubleshoot | `/pov-curate`, this file, `HELP.md` |
| **Customer** (received a curated package) | Deploy one or more appliances into their AWS account | `HELP.md`, then the module `README.md` |

If you cannot tell which you are talking to, ask.

---

## Repository map

```
AI-POV-Tools/
  CLAUDE.md                      # This file — router and global rules
  HELP.md                        # Human-facing "I want to…" index, FAQ, glossary
  STAGED-BUILD.md                # One-component-at-a-time deployment order (fallback)
  README.md                      # Project overview and module navigation
  .claude/commands/              # Slash commands: /pov-preflight, /pov-deploy,
                                 #   /pov-troubleshoot, /pov-teardown, /pov-curate
  scripts/
    preflight.sh                 # Checks Terraform, AWS creds, quotas, key pairs, env vars
    curate.sh                    # Builds a customer package under dist/ (SE use only)
  ai-services-all/
    new-vpc-public/              # Full stack: AIG (public EIP) + Guardrails + DLPoD + bastion
  aig/                           # AI Gateway
    CLAUDE.md
    deployment-role/             # Run once per AWS account: least-privilege deploy role
    existing-vpc/  new-vpc-public/  new-vpc-private/
    docs/                        # iam-permissions.md, troubleshooting.md, state-management.md
    tests/                       # pytest: static (mock providers) + integration (real AWS)
  gpu-guardrails/                # AI Guardrails on a GPU EC2 instance
    CLAUDE.md
    existing-vpc/  new-vpc-private/
  dlpod/                         # DLP On-Demand
    CLAUDE.md
    README.md                    # DLPoD overview and template choice
    docs/                        # ztp-bootstrap-reference.md (bootstrap.json schema)
    existing-vpc/  new-vpc-private/
  internal/                      # INTERNAL — gitignored, never shipped to customers
  dist/                          # Curated customer packages — gitignored
```

Every leaf directory named `existing-vpc/`, `new-vpc-public/`, or
`new-vpc-private/` is a self-contained Terraform root with `main.tf`,
`variables.tf`, `outputs.tf`, `README.md`, and `terraform.tfvars.example`.
The `main.tf` at a module's top level (`aig/main.tf`,
`gpu-guardrails/main.tf`, `ai-services-all/main.tf`) is a comment-only
redirect — it is not a Terraform root. Never run `terraform` there.

---

## Choosing a module

Ask these in order, or infer from what the user has already said.

```
1. Which components?
   ├── AIG + Guardrails + DLPoD → ai-services-all/new-vpc-public/   ← RECOMMENDED
   │     One apply, one state, readiness gates, DNS and TLS wired up.
   │     Use the staged build below only if the customer explicitly wants
   │     to deploy one component at a time.
   ├── One component only, or customer insists on one-at-a-time
   │     → continue
   └── Unsure → ask what the POV is testing. AIG alone proves proxying;
         Guardrails adds LLM content inspection; DLPoD adds DLP scanning.

2. Existing VPC and subnet, or new?
   ├── Existing → <module>/existing-vpc/
   └── New      → continue

3. (AIG only) Must the gateway be reachable from the internet?
   ├── Yes → aig/new-vpc-public/      (simplest tfvars, quick demo)
   └── No  → aig/new-vpc-private/     (recommended default for a real POV)
   Guardrails and DLPoD have only new-vpc-private — they should never be public.
```

**Staged build (fallback, not the default)** — use only when the combined
`ai-services-all/new-vpc-public/` stack is not wanted and the customer wishes
to deploy one component at a time. The standalone templates exist for that
case. All three should still land in one VPC: the first stage uses a
`new-vpc-private/` template to create the network, the next two use
`existing-vpc/` templates to join it.

```
Stage 1: gpu-guardrails/new-vpc-private/  →  vpc_id, private_subnet_id, vpc_cidr,
                                             private_subnet_cidr, ai_guardrails_host
Stage 2: dlpod/existing-vpc/              →  in: vpc_id, subnet_id, vpc_cidr, dlpod_private_ip
                                             out: dlp_host, ca_cert_pem
Stage 3: aig/existing-vpc/                →  in: vpc_id, subnet_id, appliance_host,
                                                 guardrails_host, dlp_host, dlp_ca_cert_pem
```

The AIG is last because its bootstrap secret is read once at first boot and
must already contain the Guardrails endpoint and the DLPoD endpoint + CA
cert, which only exist after Stages 1–2. The canonical walkthrough with
the variable-by-variable mapping is `STAGED-BUILD.md`. A staged build cannot produce an internet-reachable AIG; use the
combined stack for that.

---

## Global rules — apply in every directory

### Secrets

- `NETSKOPE_SERVER_URL` and `NETSKOPE_API_KEY` go in environment variables
  only. Never write them into `terraform.tfvars`; they would land in state.
  The provider also accepts `server_url`/`api_key` variables as a fallback —
  do not recommend that path.
- The DLPoD license goes in `TF_VAR_dlpod_licensekey`. All DLPoD-bearing
  templates use the `dlpod_licensekey` variable name.
- Never print, echo, or paste a token, license key, or `.tfstate` contents
  into the conversation. State files contain TLS private keys in plaintext.
- Never commit `*.tfvars`, `*.tfstate*`, `tfplan*`, or `.terraform/`. They
  are gitignored; keep them that way.

### Destructive commands

- Always run `terraform plan` and summarize it before `terraform apply`.
- Before `terraform destroy`, state what will be removed (including Netskope
  appliance registrations) and get an explicit yes.
- Never run `terraform` in a directory that is not one of the leaf roots.

### Facts you must not guess

Ask the user for these; they are account-, region-, or tenant-specific:

- AIG AMI ID (from AWS Marketplace after accepting terms; region-specific)
- DLPoD AMI ID (from Netskope; region-specific)
- DLPoD license key
- Netskope tenant URL and API token
- AWS region, availability zone, EC2 key pair names
- S3 bucket holding `aisecurity-llm.tgz` (Guardrails image)

If a README default looks like a real ID (e.g. an `ami-…` string), treat it
as an example, not as correct for the user's region.

### Accuracy

When a user asks how something works, answer from the `.tf` files and
`README.md` in the directory, not from memory. If the code and a doc
disagree, say so and prefer the code.

---

## Curating a customer package (SE workflow)

SEs do not hand customers the whole repo. They build a trimmed copy with
only the modules the customer needs and none of the internal material.
`/pov-curate` drives this; `scripts/curate.sh` does the copying.

### Intake questions

Collect all of these before running the script:

| # | Question | Drives |
|---|----------|--------|
| 1 | Customer name (short, filesystem-safe) | `dist/<name>-<date>/` |
| 2 | Which components: AIG, Guardrails, DLPoD, or all? | Module selection |
| 3 | Combined single-apply stack, or staged/separate? | `ai-services-all/` vs component modules |
| 4 | Existing VPC or new? | `existing-vpc/` vs `new-vpc-*/` |
| 5 | (AIG) Internet-reachable or private? | `new-vpc-public/` vs `new-vpc-private/` |
| 6 | Will they run regression tests? | Include `aig/tests/` or not |
| 7 | Will they use remote state? | Include `aig/docs/state-management.md` and `backend.hcl.example` |
| 8 | Target AWS region | Noted in the generated README so AMI lookups are scoped |

### What is always included

- Root `HELP.md`, a generated `README.md`, a generated `CLAUDE.md`, `.gitignore`
- The selected Terraform roots with their `README.md` and `terraform.tfvars.example`
- `aig/deployment-role/` whenever any AIG root is selected
- `aig/docs/iam-permissions.md` and `aig/docs/troubleshooting.md` whenever any AIG root is selected
- `dlpod/README.md` and `dlpod/docs/ztp-bootstrap-reference.md` whenever any DLPoD root is selected
- `scripts/preflight.sh` and the `/pov-preflight`, `/pov-deploy`,
  `/pov-troubleshoot`, `/pov-teardown` commands

### What is never included

- `/internal/` at the repo root (PDFs, CA PEM, IAM policy JSON source)
- `*.tfstate*`, `*.tfvars`, `tfplan*`, `.terraform/`, `.terraform.lock.hcl`
- `.claude/settings.local.json` (pre-approves apply/destroy for the SE's machine)
- `.idea/`, `.venv/`, `__pycache__/`, `.pytest_cache/`, `test-results*.json`, `.DS_Store`
- `scripts/curate.sh` and `/pov-curate` (SE-only tooling)
- Any file matching the secret scan (goskope URLs with tokens, `ami-` IDs
  outside `.example` files, license-key patterns, 12-digit AWS account IDs)

### After the script runs

1. Open `dist/<name>-<date>/MANIFEST.md` and read the include list and the
   secret-scan result back to the SE.
2. If the scan flagged anything, show the file and line and ask whether to
   redact or exclude. Do not zip until the scan is clean.
3. Remind the SE that the customer still needs to obtain their own AMI IDs,
   license key, and API token — the package contains none of them.

---

## Common requests and where to send them

| Request | Go to |
|---------|-------|
| "Which template should I use?" | §Choosing a module above |
| "Am I ready to deploy?" | `/pov-preflight` or `scripts/preflight.sh` |
| "Walk me through the deploy" | `/pov-deploy`, then the directory's `README.md` |
| "It's not enrolling / not healthy / timed out" | `/pov-troubleshoot`; `aig/docs/troubleshooting.md`; `ai-services-all/new-vpc-public/docs/troubleshooting.md` |
| "What permissions does the deployer need?" | `aig/docs/iam-permissions.md` |
| "How do I remove everything?" | `/pov-teardown` |
| "Build a package for customer X" | `/pov-curate` (SEs only) |
| "What does bootstrap.json look like?" | `dlpod/docs/ztp-bootstrap-reference.md` |
| "How do I store state safely?" | `aig/docs/state-management.md`; `ai-services-all/new-vpc-public/docs/deployment.md` |

---

## Known constraints worth remembering

- Netskope appliance names are limited to 15 characters; `appliance_name`
  has a `validation` block enforcing this.
- The AIG enrollment token expires 24 hours after `terraform apply`. If the
  instance did not enroll in time, run `terraform apply` again.
- `terraform apply` for Guardrails finishes when EC2 is created (~2 min),
  not when the service is healthy (15–35 min more). Point users at
  `ssm_connect_command` and the two log files, not at a re-apply.
- The combined `ai-services-all` apply blocks on readiness gates and takes
  35–50 minutes. Do not let a user interrupt it.
- AIG connects to DLPoD by hostname (`dlp.aigw.internal` by default) and
  verifies the TLS SAN. A bare IP will fail even with a valid IP SAN.
  `dlpod/existing-vpc/` and `ai-services-all/` create a Route 53 private
  zone for this. `dlpod/new-vpc-private/` does not — set `system_hostname`
  and make sure the AIG can resolve it, or expect TLS verification to fail.
