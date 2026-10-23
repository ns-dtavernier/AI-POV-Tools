---
description: Check the environment is ready to deploy a Netskope POV template
---

Help the user confirm they are ready to run `terraform apply` for the template they intend to deploy.

1. Determine which template directory they are deploying (ask if unclear; see `CLAUDE.md` §"Choosing a module").
2. Run `scripts/preflight.sh <template-dir>` and show the output. If the script is not present, run the equivalent checks by hand:
   - `terraform version` (≥ 1.5)
   - `aws sts get-caller-identity`
   - For AIG templates: `NETSKOPE_SERVER_URL` and `NETSKOPE_API_KEY` are set (check with `[[ -n "$VAR" ]]` — never echo their values)
   - For DLPoD templates: `TF_VAR_dlpod_licensekey` is set (same rule)
   - For Guardrails: G-family on-demand quota in the region, and the `aisecurity-llm.tgz` object exists in the configured S3 bucket
   - EC2 key pairs named in `terraform.tfvars` exist in the region
   - `terraform.tfvars` exists and every variable without a default in `variables.tf` is set
3. Walk through each failure with the fix from the template's `README.md` prerequisites section.
4. Do not proceed to `/pov-deploy` until everything passes or the user explicitly accepts a known gap.

Never print the value of a token, API key, or license key.
