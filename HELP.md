# Help — Netskope POV Deployment Toolkit

Start here if you have never used this repository. It answers "I want to…"
questions in plain language and points you to the right guide. For the
module overview see [`README.md`](README.md).

**If you only read one line:** for a full POV, use
[`ai-services-all/new-vpc-public/`](ai-services-all/new-vpc-public/README.md).
It installs the AI Gateway, AI Guardrails and DLP On-Demand together with one
command and wires them to each other.

*What is a "template"?* A folder you `cd` into and run three commands in:
`terraform init`, `terraform plan`, `terraform apply`. Each template is
independent and has its own README. You only ever run Terraform inside one of
the sub-folders named `existing-vpc/`, `new-vpc-public/` or `new-vpc-private/`
— never at the top of `aig/`, `dlpod/` or `gpu-guardrails/`.

---

## I want to…

### …figure out which template to use

Answer these three questions in order.

**1. Do you want all three components (AI Gateway + Guardrails + DLPoD)?**

- **Yes** → `ai-services-all/new-vpc-public/`. You're done — skip to
  […check I have everything](#check-i-have-everything-before-i-start).
- **Just one** → go to question 2.
- **All three, but the customer insists on installing them one at a time** →
  skip to […deploy one component at a time](#deploy-the-three-components-one-at-a-time-only-if-the-combined-template-is-refused).

**2. Which component?**

| Component | What it proves in a POV | Folder |
|-----------|-------------------------|--------|
| AI Gateway (AIG) | AI traffic is proxied and policy is applied | `aig/` |
| AI Guardrails | LLM prompts and responses are inspected | `gpu-guardrails/` |
| DLP On-Demand (DLPoD) | Sensitive data in AI traffic is detected | `dlpod/` |

Guardrails and DLPoD are back-end services that the AIG calls. On their own
they prove very little — an AIG is almost always part of the picture.

**3. Does the customer already have an AWS VPC and subnet to use?**

- **Yes** → the component's `existing-vpc/` sub-folder.
- **No** → a `new-vpc-…` sub-folder:
  - For the **AIG**, decide whether people outside AWS must reach it directly.
    Yes → `aig/new-vpc-public/`. No → `aig/new-vpc-private/` (more realistic,
    and the better default).
  - **Guardrails** and **DLPoD** only have `new-vpc-private/`. They are never
    exposed to the internet.

The same decision as a picture:

```
All three components? ── yes ──► ai-services-all/new-vpc-public/
        │
        no
        ▼
Which one?
  ├─ AIG ────────────► existing VPC? ── yes ──► aig/existing-vpc/
  │                                   └─ no ───► internet-facing? ── yes ──► aig/new-vpc-public/
  │                                                                └─ no ───► aig/new-vpc-private/
  ├─ Guardrails ─────► existing VPC? ── yes ──► gpu-guardrails/existing-vpc/
  │                                   └─ no ───► gpu-guardrails/new-vpc-private/
  └─ DLPoD ──────────► existing VPC? ── yes ──► dlpod/existing-vpc/
                                      └─ no ───► dlpod/new-vpc-private/
```

Each module README repeats its own part of this tree with more detail:
[`aig/README.md`](aig/README.md) ·
[`gpu-guardrails/README.md`](gpu-guardrails/README.md) ·
[`dlpod/README.md`](dlpod/README.md) ·
[`ai-services-all/README.md`](ai-services-all/README.md)

### …deploy the three components one at a time (only if the combined template is refused)

**Why the order matters.** The AI Gateway configures itself **once, when it
first boots**, from a secret that must already contain the Guardrails address
and the DLPoD address plus its certificate. Those don't exist until Guardrails
and DLPoD are running. So the order is fixed and the AIG is always last.

```
1. gpu-guardrails/new-vpc-private/   creates the VPC and installs Guardrails  (wait until "Healthy" — ~30 min)
2. dlpod/existing-vpc/               joins that VPC and installs DLPoD
3. aig/existing-vpc/                 joins that VPC and installs the AIG
```

After each stage, `terraform output` prints values you copy into the next
stage's `terraform.tfvars`. The exact copy-from / paste-to list is in
[`STAGED-BUILD.md`](STAGED-BUILD.md).

Expect three separate state files and roughly twice the hands-on time of the
combined template. A staged build cannot give you an internet-facing AIG; if
the customer needs that, the combined template is the only option.

### …check I have everything before I start

You don't need to understand this table — run `scripts/preflight.sh <folder>`
(or `/pov-preflight` in Claude Code) and it checks every line and tells you
what to fix.

| Need | Templates | Where to get it |
|------|-----------|-----------------|
| Terraform ≥ 1.5 | all | [terraform.io/install](https://developer.hashicorp.com/terraform/install) |
| AWS CLI signed in to the right account | all | [AWS CLI quickstart](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) |
| EC2 key pair(s) in the region | all | `aws ec2 describe-key-pairs --region …` |
| Netskope REST API v2 token + tenant URL | AIG, combined | Tenant → Settings → Tools → REST API v2 |
| AIG AMI ID | AIG, combined | AWS Marketplace → Netskope AI Gateway → accept terms; different per region |
| DLPoD AMI ID | DLPoD, combined | From Netskope; different per region. Templates include a lookup for some regions |
| DLPoD license key | DLPoD, combined | From Netskope |
| `aisecurity-llm.tgz` uploaded to an S3 bucket in the region | Guardrails, combined | From Netskope; `aws s3 cp` it before you start |
| EC2 quota "Running On-Demand G and VT instances" ≥ 4 vCPU | Guardrails, combined | AWS Console → Service Quotas → EC2 |
| Deployment IAM role applied | AIG | `aig/deployment-role/`, once per AWS account |

### …set my credentials safely

Put secrets in environment variables, never in files:

```bash
export NETSKOPE_SERVER_URL="https://<tenant>.goskope.com/api/v2"
export NETSKOPE_API_KEY="<rest-api-v2-token>"
export TF_VAR_dlpod_licensekey="<license>"   # any template that deploys DLPoD
```

Why: anything you type into `terraform.tfvars` is copied into
`terraform.tfstate`, and that file is easy to share by accident. State already
holds TLS private keys, so treat it as a secret. For anything that will live
more than a few days, store state in S3 with encryption:
[`aig/docs/state-management.md`](aig/docs/state-management.md).

### …deploy

1. `cd` into the template folder (one of the `existing-vpc/` / `new-vpc-…/` sub-folders).
2. `cp terraform.tfvars.example terraform.tfvars`, then open `terraform.tfvars`
   and fill in the values marked REQUIRED. The folder's README has a table
   saying where each one comes from.
3. `terraform init` (downloads what Terraform needs — once per folder).
4. `terraform plan` — shows what *will* happen. Nothing is created.
5. `terraform apply` — does it. Nothing is created until you type `yes`.

How long it takes:

| Template | `apply` returns | Service usable |
|----------|-----------------|----------------|
| AIG | 3–5 min | allow up to 15 min for boot and self-enrollment |
| Guardrails | ~2 min | 15–35 min later (two-phase boot with a reboot) |
| DLPoD | a few minutes | after `nsbootstrap` completes, ~5–10 min |
| Combined stack | 35–50 min (waits for each component to be ready) | when apply finishes |

### …know whether it worked

| Component | Check |
|-----------|-------|
| AIG | Netskope tenant shows the appliance **connected**; or `GET /api/v2/aig/appliances` |
| Guardrails | `curl http://<private-ip>:8080/ping` → `{"status":"Healthy"}` from inside the VPC |
| DLPoD | Commands in [`dlpod/README.md`](dlpod/README.md) §Checking it worked |
| Combined | `terraform output` and the per-component checks above |

### …prove it works end to end

After the AIG shows **connected**: in the tenant go to **Settings → Security
Cloud Platform → AI Gateways**, select the appliance, add the customer's AI
providers, then point a test client at `https://<aig public or private ip>:443`
and send a prompt. It should show up in the tenant's AI Gateway activity with
the Guardrails and DLP verdicts. Step-by-step:
[`ai-services-all/new-vpc-public/README.md`](ai-services-all/new-vpc-public/README.md) §First test.
Client-side proxy/SDK settings depend on the customer's tools — ask your SE.

### …fix something

| Symptom | Guide |
|---------|-------|
| AIG shows Disconnected / never enrolls / token expired / provider auth error | [`aig/docs/troubleshooting.md`](aig/docs/troubleshooting.md) |
| Guardrails Phase 1 or 2 stalled, health check failing, SSM readiness stale | [`ai-services-all/new-vpc-public/docs/troubleshooting.md`](ai-services-all/new-vpc-public/docs/troubleshooting.md) §Guardrails |
| DLPoD bootstrap not applied, TLS errors, AIG cannot reach DLPoD | same guide, §DLPoD; and [`dlpod/docs/ztp-bootstrap-reference.md`](dlpod/docs/ztp-bootstrap-reference.md) §Known issues |
| `terraform destroy` hangs on subnet/VPC | same guide (VPC endpoint ENIs) |
| Access denied during apply | [`aig/docs/iam-permissions.md`](aig/docs/iam-permissions.md) — name prefixes must match |
| State lock / corrupted state | [`aig/docs/state-management.md`](aig/docs/state-management.md) |

Or run `/pov-troubleshoot`.

### …remove everything

`terraform destroy` in each template folder. For a staged build go in
reverse order (AIG → DLPoD → Guardrails, because Guardrails owns the VPC).
AIG templates also remove the appliance from the Netskope tenant. The S3
image bucket and any remote-state bucket are not managed by these templates
and stay. `/pov-teardown` walks through it.

### …understand how it works under the hood

- AIG bootstrap via Secrets Manager: [`aig/README.md`](aig/README.md) §Bootstrap process
- DLPoD zero-touch provisioning and `bootstrap.json` schema: [`dlpod/docs/ztp-bootstrap-reference.md`](dlpod/docs/ztp-bootstrap-reference.md)
- Guardrails two-phase boot: [`gpu-guardrails/README.md`](gpu-guardrails/README.md) §Setup process
- Combined stack internals, TLS validation, CI/CD: [`ai-services-all/new-vpc-public/docs/devops.md`](ai-services-all/new-vpc-public/docs/devops.md)
- Design decisions and constraints per module: the `CLAUDE.md` in each module folder (written for Claude, readable by humans)

### …run the tests

[`aig/tests/README.md`](aig/tests/README.md) — static tests with mock
providers (no credentials, ~30 s) and integration tests that deploy and
destroy real infrastructure. `dlpod/new-vpc-private/tests/` has a
`terraform test` file.

### …build a package for a customer (Netskope SEs)

Run `/pov-curate` in Claude Code, or directly:

```bash
scripts/curate.sh --customer acme --modules ai-services-all/new-vpc-public --region us-east-1 --zip
```

Output goes to `dist/acme-<date>/` with a `MANIFEST.md` listing what was
included and the result of a secret scan. See `CLAUDE.md` §Curating a
customer package for the rules.

---

## Using Claude Code with this repo

Open this folder in Claude Code and ask it anything. It reads `CLAUDE.md` for
context and offers these commands:

| Command | What it does |
|---------|--------------|
| `/pov-preflight` | Checks Terraform, AWS credentials, quotas, key pairs and env vars for the template you chose |
| `/pov-deploy` | Walks you through `terraform.tfvars`, `init`, `plan`, `apply`, outputs and verification |
| `/pov-troubleshoot` | Systematic diagnosis of a failed or unhealthy deployment |
| `/pov-teardown` | Safe `terraform destroy` with the right ordering and reminders |
| `/pov-curate` | *Netskope SEs only* — builds a customer-specific package |

Without Claude Code, `scripts/preflight.sh <folder>` runs the same readiness
checks from the shell.

---

## FAQ

**Why does the AIG template need a Netskope API token but Guardrails and
DLPoD don't?** The AIG is registered in the tenant by Terraform before the
instance boots, so the enrollment token can be placed in Secrets Manager.
Guardrails and DLPoD are configured locally and then pointed at by the AIG.

**Can I put the API key in `terraform.tfvars` since it's gitignored?**
Don't. It would be written into `terraform.tfstate`, which you may later
move to S3 or share. Use the environment variable.

**The example AMI ID didn't work.** AMI IDs are per region. The AIG AMI is
shown in AWS Marketplace after you accept the terms; the DLPoD AMI comes
from Netskope. Some DLPoD templates carry a region → AMI map, but it only
covers the regions Netskope had published at the time.

**`terraform apply` finished but Guardrails isn't responding.** Expected.
Apply returns when EC2 exists; the service needs 15–35 more minutes. Use the
`ssm_connect_command` output and `tail -f /var/log/user-data.log`, then
`/var/log/guardrails-phase2.log`.

**Why does the AIG connect to DLPoD by hostname instead of IP?** The AIG's
TLS client verifies the hostname against the certificate's DNS SANs; an IP
URL fails even with an IP SAN. `dlpod/existing-vpc/` and the combined stack
create a Route 53 private zone for `dlp.aigw.internal`. `dlpod/new-vpc-private/`
does not — set `system_hostname` and provide resolution yourself.

**My appliance name was rejected.** Netskope limits appliance names to 15
characters. The AIG deployment role also expects names starting `aig-`.

**Does `terraform destroy` remove the Netskope registration?** Yes for AIG
templates — the appliance and enrollment token are Terraform resources.

**Is the Secrets Manager secret recoverable after destroy?** No.
`recovery_window_in_days = 0` is set so destroy/apply cycles can reuse the
name. Fine for a POV; change it for production.

---

## Glossary

| Term | Meaning |
|------|---------|
| **Template** | A folder you run `terraform init` / `plan` / `apply` in — one of the `existing-vpc/`, `new-vpc-public/` or `new-vpc-private/` sub-folders |
| **AIG / AIGW** | Netskope AI Gateway — the appliance that proxies AI traffic and applies policy |
| **AI Guardrails** | LLM-based content inspection service the AIG calls; runs on a GPU instance |
| **DLPoD** | DLP On-Demand — Netskope data loss prevention inspection appliance |
| **Combined stack** | `ai-services-all/new-vpc-public/` — all three components in one apply; the recommended path |
| **Staged build** | The fallback: installing Guardrails, DLPoD and AIG as three separate Terraform runs into one VPC, in that order |
| **ZTP** | Zero-touch provisioning — DLPoD configures itself from `bootstrap.json` in EC2 user-data |
| **Bootstrap secret** | Secrets Manager JSON the AIG reads once at first boot; contains the enrollment token and optional `dlp` / `ai_guardrails` blocks |
| **Enrollment token** | 24-hour token that lets the AIG register with the Netskope tenant |
| **Persona** | DLPoD operating mode: `dlp-on-demand` or `dspm` |
| **Deployment role** | Least-privilege IAM role created by `aig/deployment-role/` for the person running Terraform |
| **Instance profile** | IAM role attached to the EC2 instance itself (reads the bootstrap secret; pulls the Guardrails image) |
| **SSM** | AWS Systems Manager Session Manager — shell access without SSH or open ports |
| **Phase 1 / Phase 2** | Guardrails boot stages: NVIDIA driver + reboot, then Docker + container |
| **Readiness gate** | A step in the combined-stack apply that waits for a component to report healthy |
| **State / remote state** | `terraform.tfstate`, Terraform's record of what it built; "remote" means stored in S3 with encryption and locking |
