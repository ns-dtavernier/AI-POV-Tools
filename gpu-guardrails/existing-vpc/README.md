# AI Guardrails Deployment — Existing VPC

This template deploys the Netskope AI Guardrails GPU service into a **VPC and subnet that already exist** in your AWS account. It creates only the instance resources — IAM role, security group, CloudWatch log group, and EC2 instance. Your existing networking is left untouched.

Use this option when your AWS environment is already set up and you want to place the Guardrails instance inside it.

## What gets deployed

```
Your existing VPC
  └── Your existing subnet (must have outbound internet access)
        └── GPU EC2 instance (no public IP)
               │  downloads image at boot
               ▼
           S3 (aisecurity-llm.tgz via existing network route)
               │  logs
               ▼
           CloudWatch Logs
```

**AWS resources created:**
- Security group in your existing VPC (inbound: TCP 22 disabled by default, TCP 8080 from `allowed_service_cidr`; outbound: all)
- IAM role + instance profile (S3 image download, CloudWatch Logs write, SSM Session Manager)
- CloudWatch log group (`/<project>-<environment>/guardrails`, 30-day retention)
- EC2 GPU instance running Ubuntu 22.04

**Nothing created or modified:**
- Your VPC, subnets, route tables, internet gateway, and NAT gateway are not touched

---

## Before you start

You need:

- [ ] **Terraform ≥ 1.5** installed — [download here](https://developer.hashicorp.com/terraform/install)
- [ ] **AWS credentials** configured (`aws configure` or environment variables)
- [ ] **GPU instance quota** for your chosen instance family (g4dn or g5) in the target region — check under AWS console → Service Quotas → EC2
- [ ] **S3 bucket with `aisecurity-llm.tgz`** uploaded before running `terraform apply` — see [Step 0 in the main README](../README.md)
- [ ] **VPC ID** — from the AWS console or `aws ec2 describe-vpcs`
- [ ] **Subnet ID** — the subnet where the instance will be placed; must have outbound internet access

### Subnet requirements

The subnet must have a route to the internet (outbound only is sufficient) so the instance can:
- Download NVIDIA drivers and NVIDIA Container Toolkit from public package repositories
- Pull Docker CE from `download.docker.com`
- Download the Guardrails image from S3

A private subnet with a NAT Gateway route satisfies this requirement. A public subnet also works — the instance is launched without a public IP regardless.

---

## Setup

### Step 1 — Find your VPC and subnet IDs

```bash
# List VPCs
aws ec2 describe-vpcs --region YOUR_REGION \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# List subnets in a VPC
aws ec2 describe-subnets --region YOUR_REGION \
  --filters "Name=vpc-id,Values=vpc-YOUR_VPC_ID" \
  --query 'Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

### Step 2 — Copy the configuration file

```bash
cd gpu-guardrails/existing-vpc
cp terraform.tfvars.example terraform.tfvars
```

### Step 3 — Edit `terraform.tfvars`

Open `terraform.tfvars` in a text editor and fill in your values. The table below documents every field.

#### Required fields

| Variable | Description | Example |
|----------|-------------|---------|
| `vpc_id` | ID of the existing VPC to deploy the instance into | `"vpc-0123456789abcdef0"` |
| `subnet_id` | ID of the existing subnet for the EC2 instance. Must have outbound internet access. | `"subnet-0123456789abcdef0"` |
| `allowed_service_cidr` | CIDR allowed to reach the Guardrails service on TCP port 8080. Restrict to the AIGW source CIDR or your private network range. | `"10.0.0.0/8"` |
| `image_s3_bucket` | S3 bucket containing `aisecurity-llm.tgz`. Must be in the same region as the EC2 instance. | `"my-guardrails-bucket"` |
| `project` | Short lowercase identifier used in all resource Name tags. | `"guardrails"` |
| `environment` | One of `dev`, `staging`, or `prod`. Used in resource Name tags. | `"dev"` |

#### AWS fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `"us-east-1"` | AWS region where your VPC lives. Must match the region of `vpc_id` and `subnet_id`. |
| `allowed_ssh_cidr` | `"127.0.0.1/32"` | CIDR allowed inbound on port 22. Default effectively disables SSH — use SSM Session Manager instead. |

#### EC2 fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `instance_type` | `"g4dn.xlarge"` | GPU instance type. `g4dn.xlarge` (1× T4, 4 vCPU, 16 GB RAM) is the minimum. Use `g5.xlarge` (1× A10G) for higher throughput. |
| `volume_size_gb` | `100` | Root EBS volume size in GB. Minimum 80 GB for NVIDIA drivers and Docker images. |
| `key_pair_name` | `""` | EC2 key pair name for SSH access. Optional — leave empty to use SSM Session Manager only (recommended). |
| `image_s3_key` | `"aisecurity-llm.tgz"` | S3 object key for the image tarball. Change only if you uploaded the file with a different name or prefix. |

---

## Deploy

### Initialise Terraform

```bash
terraform init
```

### Preview the changes

```bash
terraform plan
```

Read through the plan. It should show approximately 8 resources being created. No changes are made at this stage.

### Apply

```bash
terraform apply
```

Type `yes` when prompted. The deployment takes approximately 2 minutes.

When complete, Terraform prints the outputs:

```
ai_guardrails_host        = "http://10.x.x.x:8080/invocations"
health_check_url    = "http://10.x.x.x:8080/ping"
instance_id         = "i-0abc123..."
log_group_name      = "/guardrails-dev/guardrails"
private_ip          = "10.x.x.x"
ssm_connect_command = "aws ssm start-session --target i-0abc123 --region us-east-1"
```

| Output | What it means |
|--------|---------------|
| `ai_guardrails_host` | URL to enter in the AIGW CLI when registering — copy this value exactly |
| `health_check_url` | Polls this endpoint to confirm the service is ready |
| `private_ip` | Private IP of the GPU instance (no public IP assigned) |
| `instance_id` | EC2 instance ID for SSM and AWS console |

---

## Monitor setup progress

`terraform apply` finishes when the EC2 instance is created (~2 minutes). The two-phase NVIDIA/Docker setup takes an additional 15–25 minutes. See the [main README](../README.md#setup-process) for a full explanation.

Connect to the instance to watch progress:

```bash
# Use the ssm_connect_command output value
aws ssm start-session --target i-0abc123 --region us-east-1

# Watch Phase 1 (NVIDIA driver install + reboot)
tail -f /var/log/user-data.log

# Watch Phase 2 (Docker + container start — available after Phase 1 reboot)
tail -f /var/log/guardrails-phase2.log
```

When Phase 2 completes successfully you will see:
```
SUCCESS: Guardrails service is healthy and ready on port 8080.
```

---

## Verify the service

From within the same VPC or your private network:

```bash
curl http://PRIVATE_IP:8080/ping
```

Expected response:
```json
{"status": "Healthy"}
```

---

## Register with AIGW

Once the health check passes, register the host via the **AI Gateway CLI** on the AIG appliance:

1. Go to **Settings → Security Cloud Platform → Gateway Setup → AI Guardrails Service**
2. Select **Configure AI Guardrails Service Host**
3. Enter the `ai_guardrails_host` output value:
   ```
   http://<private-ip>:8080/invocations
   ```
4. Leave JWT URL, Client ID, Client Secret, and Scope blank
5. Press **Enter** to save

The AIGW validates the endpoint before saving. The AIG appliance must be able to reach the GPU instance's private IP at the time of registration.

---

## Tear down

```bash
terraform destroy
```

Type `yes` when prompted. Only the resources created by this template are removed — the security group, IAM role, CloudWatch log group, and EC2 instance. Your VPC, subnets, and all existing networking are not touched.

---

## Help

- [Main deployment README](../README.md)
