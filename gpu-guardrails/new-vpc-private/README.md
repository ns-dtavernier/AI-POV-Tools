# AI Guardrails Deployment — New VPC, Private Subnet

This template deploys the Netskope AI Guardrails GPU service into a **brand-new VPC** with the instance in a **private subnet**. Outbound internet access is provided by a NAT Gateway — the instance has no inbound exposure from the internet and no public IP address.

Access for management is via AWS Systems Manager Session Manager. The Guardrails service on port 8080 is reachable only from within the VPC or via a connected private network (VPN or Transit Gateway).

## What gets deployed

```
Internet
    │
    ▼
Internet Gateway
    │
    ▼
Public subnet (10.0.1.0/24)
  └── NAT Gateway ──────────────────────► apt, Docker Hub, NVIDIA repos, S3
         │
         ▼
Private subnet (10.0.2.0/24)
  └── GPU EC2 instance (no public IP)
         │  downloads image at boot
         ▼
     S3 (via VPC gateway endpoint)
         │  logs and SSM traffic
         ▼
     CloudWatch / SSM (via VPC interface endpoints)
```

**AWS resources created:**
- VPC with DNS support enabled
- Public subnet + Internet Gateway + route table (NAT Gateway only — no instances here)
- Private subnet + NAT Gateway (Elastic IP) + route table
- S3 gateway endpoint (keeps image download traffic off the NAT Gateway)
- Interface VPC endpoints for SSM, SSMMessages, EC2Messages, and CloudWatch Logs
- Security group (inbound: TCP 22 disabled by default, TCP 8080 from `allowed_service_cidr`; outbound: all)
- IAM role + instance profile (S3 image download, CloudWatch Logs write, SSM Session Manager)
- CloudWatch log group (`/<project>-<environment>/guardrails`, 30-day retention)
- EC2 GPU instance running Ubuntu 22.04

---

## Before you start

You need:

- [ ] **Terraform ≥ 1.5** installed — [download here](https://developer.hashicorp.com/terraform/install)
- [ ] **AWS credentials** configured (`aws configure` or environment variables)
- [ ] **GPU instance quota** for your chosen instance family (g4dn or g5) in the target region — check under AWS console → Service Quotas → EC2
- [ ] **S3 bucket with `aisecurity-llm.tgz`** uploaded before running `terraform apply` — see [Step 0 in the main README](../README.md)

---

## Setup

### Step 1 — Copy the configuration file

```bash
cd gpu-guardrails/new-vpc-private
cp terraform.tfvars.example terraform.tfvars
```

### Step 2 — Edit `terraform.tfvars`

Open `terraform.tfvars` in a text editor and fill in your values. The table below documents every field.

#### Required fields

| Variable | Description | Example |
|----------|-------------|---------|
| `image_s3_bucket` | S3 bucket containing `aisecurity-llm.tgz`. Must be in the same region as the EC2 instance. | `"my-guardrails-bucket"` |

#### AWS and network fields (optional — defaults work for most POVs)

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `"us-east-1"` | AWS region to deploy into. Must be the same region as the S3 bucket. |
| `availability_zone` | `"us-east-1a"` | Availability zone for the subnets. Must be within `aws_region`. |
| `vpc_cidr` | `"10.0.0.0/16"` | IP address range for the new VPC. Change if this overlaps with networks you need to peer or connect to. |
| `public_subnet_cidr` | `"10.0.1.0/24"` | CIDR for the public subnet (NAT Gateway only). Must be within `vpc_cidr`. |
| `private_subnet_cidr` | `"10.0.2.0/24"` | CIDR for the private subnet (GPU instance). Must be within `vpc_cidr` and not overlap `public_subnet_cidr`. |
| `allowed_service_cidr` | `"10.0.0.0/8"` | CIDR allowed to reach the Guardrails service on TCP port 8080. Restrict to the AIGW source CIDR or your VPN/corporate range. The instance has no public IP — `0.0.0.0/0` has no effect from the internet. |
| `allowed_ssh_cidr` | `"127.0.0.1/32"` | CIDR allowed inbound on port 22. Default effectively disables SSH — use SSM Session Manager instead. |

#### Project fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `project` | _(required)_ | Short lowercase identifier used in all resource Name tags (e.g. `guardrails`). |
| `environment` | _(required)_ | One of `dev`, `staging`, or `prod`. Used in resource Name tags. |

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

Read through the plan. It should show approximately 20 resources being created. No changes are made at this stage.

### Apply

```bash
terraform apply
```

Type `yes` when prompted. The deployment takes approximately 3–5 minutes, most of which is NAT Gateway provisioning.

When complete, Terraform prints the outputs:

```
ai_guardrails_host         = "http://10.0.2.x:8080/invocations"
health_check_url     = "http://10.0.2.x:8080/ping"
instance_id          = "i-0abc123..."
log_group_name       = "/guardrails-dev/guardrails"
nat_gateway_ip       = "52.x.x.x"
private_ip           = "10.0.2.x"
ssm_connect_command  = "aws ssm start-session --target i-0abc123 --region us-east-1"
vpc_id               = "vpc-0abc123..."
```

| Output | What it means |
|--------|---------------|
| `ai_guardrails_host` | URL to enter in the AIGW CLI when registering — copy this value exactly |
| `health_check_url` | Polls this endpoint to confirm the service is ready |
| `private_ip` | Private IP of the GPU instance (no public IP assigned) |
| `nat_gateway_ip` | Public IP the instance uses for outbound traffic — add to any firewall allowlists |
| `instance_id` | EC2 instance ID for SSM and AWS console |
| `vpc_id` | VPC ID — needed if you configure VPC peering or Transit Gateway later |
| `private_subnet_id` | Private subnet ID — `subnet_id` for `dlpod/existing-vpc/` and `aig/existing-vpc/` in a staged build |
| `public_subnet_id` | Public subnet ID (holds the NAT Gateway) |
| `vpc_cidr` | VPC CIDR — `vpc_cidr` for `dlpod/existing-vpc/` |
| `private_subnet_cidr` | Private subnet CIDR — choose `dlpod_private_ip` from it; use as `allowed_inspection_cidr` / `allowed_cidr_blocks` |
| `availability_zone` | AZ of the subnets |

### Staged build

If the combined `ai-services-all/new-vpc-public/` stack (recommended) is not wanted and the components are to be deployed one at a time, this template is **Stage 1**: it creates the VPC, and `dlpod/existing-vpc/` (Stage 2) and `aig/existing-vpc/` (Stage 3) join it using the outputs above. The AIG must be last because its bootstrap secret, read once at first boot, needs `ai_guardrails_host` from this stage and `dlp_host` + `ca_cert_pem` from Stage 2. Full walkthrough: [`ai-services-all/README.md`](../../STAGED-BUILD.md).

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

From within the VPC or your private network:

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

Type `yes` when prompted. All resources created by this template are removed — the VPC, subnets, NAT Gateway, VPC endpoints, security group, IAM role, CloudWatch log group, and EC2 instance.

---

## Help

- [Main deployment README](../README.md)
