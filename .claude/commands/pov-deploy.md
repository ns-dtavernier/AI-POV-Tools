---
description: Guided terraform init / plan / apply for a Netskope POV template
---

Guide the user through deploying one template. Work only inside a leaf Terraform root (`*/existing-vpc/`, `*/new-vpc-public/`, `*/new-vpc-private/`, or `ai-services-all/new-vpc-public/`).

1. Confirm `/pov-preflight` has passed. If not, run it first.
2. If `terraform.tfvars` does not exist, copy `terraform.tfvars.example` and help the user fill in every REQUIRED value using the table in the directory's `README.md`. Remind them: tokens and license keys go in environment variables, not this file.
3. If any AIG template is involved and this is the first deployment in the AWS account, check whether `aig/deployment-role/` has been applied. See `aig/README.md` §"Step 0".
   If this is a staged build (separate Guardrails / DLPoD / AIG templates), confirm the order: the VPC-creating template first, `existing-vpc/` templates after, AIG last. Before deploying `aig/existing-vpc/`, make sure the user has `ai_guardrails_host` from Guardrails and `dlp_host` + `ca_cert_pem` from DLPoD in hand — the AIG reads them once at first boot. Mapping table: `STAGED-BUILD.md`.
4. `terraform init`
5. `terraform plan -out=tfplan` — summarize what will be created in plain language (instance types, whether anything gets a public IP, Netskope API objects that will be registered). Ask for confirmation.
6. `terraform apply tfplan`. Tell the user how long to expect, from the README:
   - AIG alone: 3–5 minutes for apply; allow up to 15 minutes for boot and enrollment
   - Guardrails: apply returns in ~2 minutes; the service takes 15–35 minutes more — point them at `ssm_connect_command` and the log files
   - Combined stack: 35–50 minutes with readiness gates; do not interrupt
7. `terraform output` — explain each output and what the user does with it (e.g. `ai_guardrails_host` is registered in the AIG CLI; `dlp_host` and `ca_cert_pem` feed the AIG template).
8. Run the verification steps from the README (Netskope tenant shows the appliance `connected`; `curl .../ping` returns `Healthy`; etc.).

If apply fails, switch to `/pov-troubleshoot`. Do not re-run apply blindly.
