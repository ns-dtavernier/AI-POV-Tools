---
description: Diagnose a failed or unhealthy Netskope POV deployment
---

Diagnose systematically. Collect facts before proposing fixes.

1. Which template directory, and what is the symptom? (apply error, appliance Disconnected, Guardrails never Healthy, DLPoD TLS error, destroy hanging, …)
2. Pull the relevant guide and follow it before improvising:
   - AIG: `aig/docs/troubleshooting.md`
   - Combined stack, Guardrails, DLPoD, bastion: `ai-services-all/new-vpc-public/docs/troubleshooting.md`
   - DLPoD bootstrap behaviour and log locations: `dlpod/docs/ztp-bootstrap-reference.md` §"Verifying bootstrap" and §"Known issues"
3. Gather evidence (ask the user to run these and paste results, redacting anything sensitive):
   - `terraform output`
   - `aws ec2 describe-instance-status --instance-ids <id>`
   - For Guardrails: via `ssm_connect_command`, `tail -n 50 /var/log/user-data.log` and `/var/log/guardrails-phase2.log`
   - For AIG: appliance status in the Netskope tenant, or `GET /api/v2/aig/appliances` (header `Netskope-Api-Token`); `connected` means healthy
   - For DLPoD: the bootstrap status/log commands in `dlpod/README.md` §Checking it worked
4. Common causes to check first:
   - Enrollment token older than 24 h → `terraform apply` again
   - Wrong-region AMI ID → the example IDs are not universal
   - Guardrails image not in S3, or bucket in a different region
   - Missing G-family quota
   - Security group / `allowed_*_cidr` too narrow for the test client
   - AIG → DLPoD by IP instead of hostname (TLS SAN failure)
   - `terraform destroy` hang caused by VPC endpoint ENIs (see combined-stack troubleshooting guide)
5. Propose one fix at a time, explain why, and verify before moving on.

Never ask the user to paste `terraform.tfstate`, tokens, or license keys.
