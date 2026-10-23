---
description: Build a customer-specific POV package (SE only)
---

You are helping a Netskope SE build a trimmed package of this repo for a specific customer. Follow `CLAUDE.md` §"Curating a customer package".

## 1. Gather requirements

Ask only for what the SE has not already told you. You need:

1. Customer short name (filesystem-safe: letters, digits, `.`, `_`, `-`)
2. Components: AIG, Guardrails, DLPoD, or all
3. Combined single-apply stack (`ai-services-all/new-vpc-public`) or separate/staged modules
4. Existing VPC or new VPC
5. For AIG in a new VPC: internet-reachable (`new-vpc-public`) or private (`new-vpc-private`)
6. Include regression tests (`aig/tests/`)? Default no.
7. Include remote-state docs and `backend.hcl.example`? Default no.
8. Target AWS region (optional, improves the generated README)

Map the answers to one or more of these roots:

```
ai-services-all/new-vpc-public
aig/existing-vpc  aig/new-vpc-public  aig/new-vpc-private
gpu-guardrails/existing-vpc  gpu-guardrails/new-vpc-private
dlpod/existing-vpc  dlpod/new-vpc-private
```

Guardrails and DLPoD have no public option.

If the customer wants all three components, recommend `ai-services-all/new-vpc-public` first. Offer a staged build only if they decline the combined stack and want to deploy one component at a time. Staged builds: the first stage must create the VPC and the rest join it. The staged set to use is `gpu-guardrails/new-vpc-private,dlpod/existing-vpc,aig/existing-vpc`. Only choose all-`existing-vpc` roots if the customer already has a VPC with a private subnet and NAT. A staged build cannot give an internet-reachable AIG — if they need that with Guardrails/DLPoD, select `ai-services-all/new-vpc-public` instead.

## 2. Confirm, then run

Show the exact command and wait for confirmation:

```bash
scripts/curate.sh --customer <name> --modules <comma-list> [--region <r>] [--tests] [--remote-state] --zip
```

Run it from the repo root.

## 3. Report

Read `dist/<name>-<date>/MANIFEST.md` back to the SE:

- The include list
- The secret-scan section verbatim. If there are findings (exit code 2), show each file and line and ask whether to redact or exclude it. Re-run after fixing. Do not consider the package done until the scan is clean and the zip exists.
- The informational "AMI lookup tables in .tf" list, so the SE knows those are present.

Finish with a reminder: the customer still has to obtain their own AIG AMI ID, DLPoD AMI ID, license key, and Netskope API token — the package contains none of them.

Never copy anything from `/internal/` at the repo root into the package by hand.
