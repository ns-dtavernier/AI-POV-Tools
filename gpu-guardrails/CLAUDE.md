# CLAUDE.md — AI Guardrails GPU Terraform Templates

Context for Claude Code when helping with these templates. The repo-root
`CLAUDE.md` rules (secrets, destructive commands, don't-guess list) apply here.

## What this deploys

A Netskope AI Guardrails LLM inspection service as a Docker container on an
Ubuntu 22.04 GPU EC2 instance (`g4dn.xlarge` default). The AMI is looked up
at plan time via `data "aws_ami" "ubuntu_22_04"` — there is no AMI variable.
The container image (`aisecurity-llm.tgz`) is pulled from an S3 bucket the
user must populate **before** `terraform apply`.

```
gpu-guardrails/
  README.md            # Two-phase setup, monitoring, AIGW registration
  CLAUDE.md            # This file
  main.tf              # Comment-only redirect — not a Terraform root
  existing-vpc/        # IAM role, SG, CloudWatch log group, EC2 in your VPC/subnet
  new-vpc-private/     # + VPC, public/private subnets, NAT GW, VPC endpoints (S3, SSM, logs)
```

## Choosing

Only one question: existing VPC with outbound internet → `existing-vpc/`;
otherwise `new-vpc-private/`. There is deliberately no public option — the
service listens on 8080 with no authentication and must stay private.

## The two-phase boot — explain this before anything else

`terraform apply` returns when EC2 is created (~2 min). The service is not
ready. UserData then runs:

1. **Phase 1** (5–10 min): apt update, NVIDIA driver via `ubuntu-drivers`,
   write Phase 2 script + `guardrails-setup.service`, **reboot**.
   Log: `/var/log/user-data.log`
2. **Phase 2** (15–25 min): NVIDIA Container Toolkit, Docker CE, download
   tarball from S3, `docker load`, start container on 8080, poll
   `http://localhost:8080/ping` until `{"status":"Healthy"}`.
   Log: `/var/log/guardrails-phase2.log`

Users who re-run `terraform apply` because "nothing happened" waste time.
Send them to the `ssm_connect_command` output and the two log files.

## Key design decisions

- **SSM, not SSH.** `key_pair_name` defaults to empty/`""`; access is via
  Session Manager. `new-vpc-private` creates Interface endpoints for
  `ssm`, `ssmmessages`, `ec2messages`, `logs` and a Gateway endpoint for S3
  so the private instance works without the NAT for AWS APIs. These
  endpoint ENIs are also why `terraform destroy` can hang on subnet
  deletion — see `ai-services-all/new-vpc-public/docs/troubleshooting.md`.
- **Least-privilege S3.** The instance role can `GetObject` only on
  `s3://<image_s3_bucket>/<image_s3_key>`. Wrong bucket or key in tfvars
  = Phase 2 fails at download, not at plan.
- **Bucket must be in `aws_region`.** Cross-region S3 through the Gateway
  endpoint does not work.
- **`allowed_service_cidr`** (default `10.0.0.0/8`) controls who can reach
  8080. It must include the AIG's subnet.

## Registration with the AIG

Guardrails does not self-register. After `Healthy`, the `ai_guardrails_host`
output (`http://<private-ip>:8080/invocations`) is entered in the AIG CLI:
Settings → Security Cloud Platform → Gateway Setup → AI Guardrails Service
→ Configure AI Guardrails Service Host. JWT/Client ID/Secret/Scope are left
blank. The AIG validates reachability at save time, so Guardrails must be
up and the SG must allow the AIG first. In the staged build this value is
instead passed as `guardrails_host` to `aig/existing-vpc/`.

## Staged build role

A staged build is the fallback when the customer does not want the combined
`ai-services-all/new-vpc-public/` stack and prefers one component at a time.
In that case `new-vpc-private/` is **Stage 1**: it
creates the VPC, and `dlpod/existing-vpc/` then `aig/existing-vpc/` join it.
Its outputs `vpc_id`, `private_subnet_id`, `vpc_cidr`, `private_subnet_cidr`
exist for exactly this hand-off. The AIG goes last because its bootstrap
secret (read once at first boot) must already contain `ai_guardrails_host`
and the DLPoD `dlp_host` + CA cert. Walkthrough with the variable mapping:
`STAGED-BUILD.md`.

## Common requests

- **"Is it ready?"** — `curl http://<private_ip>:8080/ping` from inside the
  VPC (or bastion). Expect `{"status":"Healthy"}`. Also `health_check_url` output.
- **"Phase 1 is stuck"** — usually the dpkg lock from unattended-upgrades.
  Diagnosis commands are in the combined-stack troubleshooting guide.
- **"Quota error at apply"** — EC2 "Running On-Demand G and VT instances"
  quota must be ≥ 4 vCPUs for `g4dn.xlarge`. `scripts/preflight.sh` checks it.
- **"Can I use g5?"** — change `instance_type`; the quota family is the same
  (G and VT). Re-check vCPU count.
- **"Where are the logs after the instance is gone?"** — CloudWatch log group
  from the `log_group_name` output.

## Do not change without care

- The reboot between phases. The NVIDIA kernel module needs it; folding
  Phase 2 into Phase 1 breaks driver load.
- The `systemd` oneshot unit for Phase 2. It is what survives the reboot.
- The S3 `GetObject` scope. Widening it is the easy "fix" for a wrong key;
  the right fix is correcting `image_s3_key`.

## Verification

Answer from `main.tf`, `variables.tf`, `outputs.tf`, and
`templates/*.tpl` in the template directory. Timings above are from
`README.md` and are approximate.
