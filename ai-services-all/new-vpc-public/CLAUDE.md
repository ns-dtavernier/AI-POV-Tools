# Deployment Guide — Netskope AI Services (New VPC)

This directory contains Terraform for a full Netskope AI Services stack: **AI Gateway (AIG)**, **AI Guardrails**, and **DLP on-Demand (DLPoD)**, all in a new AWS VPC. Use this guide to walk a user through deployment from scratch.

When a user navigates to this directory and asks for help deploying, guide them step-by-step through the checklist below, confirming each item before moving to the next.

---

## What gets deployed

- **AIG** — public subnet, Elastic IP, port 443. Clients proxy AI traffic through this.
- **AI Guardrails** — private subnet, GPU instance (`g4dn.xlarge`). LLM content inspection.
- **DLPoD** — private subnet, `c5d.4xlarge`. DLP content scanning with TLS.
- **Bastion** — public subnet, `t3.small`. Troubleshooting only — delete post-POV.
- Supporting infra: VPC, NAT Gateway, VPC endpoints, Route 53, Secrets Manager, SSM, CloudWatch.

Total deploy time: **35–50 minutes** (Guardrails image download dominates).

---

## Pre-flight checklist

Walk the user through each item. Do not proceed to `terraform init` until all are confirmed.

### 1. Terraform version
```bash
terraform version
```
Must be **≥ 1.5**. If not, direct the user to https://developer.hashicorp.com/terraform/install.

### 2. AWS credentials
```bash
aws sts get-caller-identity
```
Must return a valid account/ARN. If not, the user needs to configure their AWS CLI profile or set `AWS_PROFILE`.

To use a named profile:
```bash
export AWS_PROFILE=your-profile-name
```

### 3. GPU instance quota
Before deploying, confirm the target region has `g4dn.xlarge` quota (or `g5.xlarge` if using that instance type):
- AWS Console → Service Quotas → Amazon EC2 → search "Running On-Demand G and VT instances"
- Minimum: **4 vCPUs** (g4dn.xlarge = 4 vCPU)

### 4. AIG AMI ID
The AIG AMI is region-specific and requires accepting Marketplace terms.
- Subscribe on AWS Marketplace (search "Netskope AI Gateway")
- After accepting terms, the AMI ID for your region is shown
- It looks like: `ami-0a66805d7fb085df4`

### 5. DLPoD AMI ID
Obtain from Netskope. The default in `terraform.tfvars.example` (`ami-0b3a14615c7e7944e`) is for **us-west-1 only** — it must be updated for other regions. Ask the user for their region and confirm they have the correct AMI.

### 6. Guardrails Docker image
The Guardrails instance pulls its LLM image from S3 at first boot. This must be uploaded before `terraform apply`:
```bash
# Create the bucket (skip if it already exists)
aws s3 mb s3://YOUR_BUCKET_NAME --region YOUR_REGION

# Upload the image
aws s3 cp aisecurity-llm.tgz s3://YOUR_BUCKET_NAME/aisecurity-llm.tgz
```
The bucket name goes into `image_s3_bucket` in `terraform.tfvars`. The bucket must be in the **same region** as `aws_region`.

### 7. EC2 key pairs (optional)
All four instances are reachable via SSM Session Manager; key pairs are **not required**. Only if the user wants SSH as well, the named key pairs must already exist in the target region:
```bash
aws ec2 describe-key-pairs --region YOUR_REGION --query 'KeyPairs[*].KeyName'
```
Do not tell users key pairs are mandatory — `variables.tf` defaults them to null/empty.

### 8. Netskope credentials
Set these as environment variables — **do not put them in `terraform.tfvars`** (they would appear in state):
```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-rest-api-v2-token"
```
- **Server URL**: Netskope tenant URL + `/api/v2`
- **API key**: Tenant → Settings → Tools → REST API v2 → generate a token with appliance management permissions

### 9. DLPoD license key
```bash
export TF_VAR_dlpod_licensekey="XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX"
```
Obtain from Netskope support or your account team. Alternatively, set `dlpod_licensekey` in `terraform.tfvars` (the file is gitignored).

---

## Configure terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in all **REQUIRED** values:

| Variable | Where to get it |
|----------|----------------|
| `aws_region` | Target AWS region (e.g. `us-east-1`) |
| `availability_zone` | Must be a valid AZ in `aws_region` — run `aws ec2 describe-availability-zones --region YOUR_REGION` |
| `aig_ami_id` | From AWS Marketplace after accepting AIG terms |
| `dlpod_ami_id` | From Netskope — region-specific |
| `image_s3_bucket` | S3 bucket where `aisecurity-llm.tgz` was uploaded |

`dlpod_ami_id` has a default that is valid only in us-west-1; everywhere else it must be set. The four `*_key_name` variables are optional. All other variables have working defaults and can be left as-is for a standard POV.

---

## Deploy

```bash
# 1. Initialize providers
terraform init

# 2. Preview changes (optional but recommended)
terraform plan

# 3. Deploy — takes 35–50 minutes
terraform apply
```

Type `yes` when prompted. The apply will block at two readiness gates:
1. **Guardrails ready** (~30 min) — waits for the GPU instance to download and load the LLM image
2. **DLPoD ready** (~5–10 min) — waits for `nsbootstrap` to complete TLS cert installation

Do not interrupt the apply. If it times out, see `docs/troubleshooting.md`.

---

## Verify deployment

After `terraform apply` completes, check the outputs:

```bash
terraform output
```

Key outputs:
| Output | Use |
|--------|-----|
| `aig_public_ip` | Configure AI clients to proxy through this on port 443 |
| `guardrails_ssm_connect_command` | Connect to Guardrails instance for diagnostics |
| `dlp_host` | DLP host URL — should be `https://dlp.aigw.internal` |
| `nat_gateway_ip` | Outbound IP — add to firewall allowlists if needed |

---

## Remote state (recommended)

State contains TLS private keys in plaintext. Use S3 remote state with KMS encryption for any deployment that will persist:

```bash
cp backend.hcl.example backend.hcl
# Edit backend.hcl — fill in S3 bucket, region, and KMS key
terraform init -backend-config=backend.hcl
```

See `docs/deployment.md` for the backend config, and `../../aig/docs/state-management.md` for creating the bucket and lock table.

---

## Troubleshooting

- Full diagnostic commands and common failure modes: `docs/troubleshooting.md`
- Architecture and bootstrap internals: `docs/devops.md`

To rebuild a single component without destroying everything:
```bash
# Replace just the AIG instance and re-enroll
terraform apply \
  -replace=netskope_aig_appliance_enrollment_token.this \
  -replace=aws_secretsmanager_secret_version.aig_bootstrap \
  -replace=aws_instance.aig
```

---

## Tear down

```bash
terraform destroy
```

Type `yes` when prompted. Removes all AWS and Netskope resources. The bastion is included — no need to remove `bastion.tf` first.