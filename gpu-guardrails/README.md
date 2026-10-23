# Netskope AI Guardrails — GPU Terraform Deployment

This repository provides two Terraform templates for deploying the Netskope AI Guardrails LLM service on a GPU-backed EC2 instance (Ubuntu 22.04 + NVIDIA drivers + Docker). Once running, the service is registered with the Netskope AI Gateway via the AIGW CLI.

---

## Which option should I use?

```
Do you have an existing VPC and subnet with outbound internet access?
├── Yes → existing-vpc/      Deploys only the GPU instance into your network
└── No  → new-vpc-private/   Creates a new VPC with the instance in a private subnet
```

| Option | Directory | What gets created | Best for |
|--------|-----------|------------------|---------|
| [Existing VPC](existing-vpc/README.md) | `existing-vpc/` | IAM role, security group, CloudWatch log group, EC2 instance | You already have a VPC and subnet |
| [New VPC — private](new-vpc-private/README.md) | `new-vpc-private/` | VPC, public + private subnets, NAT Gateway, VPC endpoints, IAM, CloudWatch, EC2 | Starting from scratch |

---

## Prerequisites

Before deploying either option you need:

| Requirement | How to get it |
|-------------|---------------|
| **Terraform ≥ 1.5** | [Download](https://developer.hashicorp.com/terraform/install) or `brew install terraform` |
| **AWS credentials** | `aws configure`, AWS SSO, or environment variables |
| **GPU instance quota** | EC2 service quota for your chosen instance family (g4dn or g5). Check and request increases in the AWS console under Service Quotas → EC2. |
| **S3 bucket with Guardrails image** | Upload `aisecurity-llm.tgz` to an S3 bucket in the same region before running `terraform apply`. |

---

## Step 0 — Upload the Guardrails image to S3

The EC2 instance pulls the Guardrails Docker image from S3 at first boot. The image must be in the bucket before you run `terraform apply`.

```bash
# Create a bucket (if you don't have one already)
aws s3 mb s3://my-guardrails-bucket --region YOUR_REGION

# Upload the image tarball
aws s3 cp aisecurity-llm.tgz s3://my-guardrails-bucket/aisecurity-llm.tgz
```

The instance IAM role grants least-privilege access to exactly this object — no other S3 permissions are granted.

---

## Deployment guides

Each template has a full step-by-step guide:

- **[New VPC — private subnet](new-vpc-private/README.md)** — recommended when you don't have an existing VPC
- **[Existing VPC](existing-vpc/README.md)** — use your own VPC and subnet

---

## Setup process

The Terraform templates provision the EC2 instance and inject a startup script via User Data. Setup completes in two phases after the instance first boots.

### Phase 1 — NVIDIA driver install (runs on first boot)

1. System packages are updated
2. The recommended NVIDIA GPU driver is installed via `ubuntu-drivers`
3. The Phase 2 script and a `systemd` oneshot service are written to disk
4. The instance reboots to activate the NVIDIA kernel module

**Duration:** approximately 5–10 minutes.

### Phase 2 — Docker and Guardrails container (runs after reboot)

The `guardrails-setup.service` systemd unit runs once after the Phase 1 reboot:

1. NVIDIA Container Toolkit is installed and configured
2. Docker CE is installed
3. The Guardrails image tarball is downloaded from S3 and loaded into Docker
4. The container is started on port 8080 with GPU access
5. A health check loop polls `http://localhost:8080/ping` until the service responds `Healthy`

**Duration:** approximately 15–25 minutes, depending on S3 download speed and instance type.

### Monitoring progress

`terraform apply` completes when the EC2 instance is created (~2 minutes) — not when the service is ready. Monitor the two phases via SSM Session Manager:

```bash
# Connect to the instance (use the ssm_connect_command output)
aws ssm start-session --target i-0abc123 --region YOUR_REGION

# Watch Phase 1 progress
tail -f /var/log/user-data.log

# Watch Phase 2 progress (available after Phase 1 reboot)
tail -f /var/log/guardrails-phase2.log
```

### Verifying the service is ready

Once Phase 2 completes, the health check endpoint returns a healthy response:

```bash
# From within the same VPC or private network
curl http://PRIVATE_IP:8080/ping
```

Expected response:
```json
{"status": "Healthy"}
```

---

## Registering with AIGW

After the health check passes, register the Guardrails host via the **AI Gateway CLI** on the AIG appliance:

1. Go to **Settings → Security Cloud Platform → Gateway Setup → AI Guardrails Service**
2. Select **Configure AI Guardrails Service Host**
3. Enter the `ai_guardrails_host` value from the Terraform output:
   ```
   http://<private-ip>:8080/invocations
   ```
4. Leave JWT URL, Client ID, Client Secret, and Scope blank — authentication is not required for this deployment
5. Press **Enter** to save

The AIGW validates the endpoint before saving. The instance must be reachable from the AIG appliance at the time of registration.

---

## Reference

- [New VPC — private subnet guide](new-vpc-private/README.md)
- [Existing VPC guide](existing-vpc/README.md)
