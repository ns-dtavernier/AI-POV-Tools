# AI Services — New VPC (AIG + Guardrails + DLPoD)

Deploys a complete Netskope AI Services stack in a new AWS VPC with a single `terraform apply`. All three appliances are zero-touch provisioned — no manual registration steps required.

**Use this template when** you are starting from scratch in a new AWS environment and want the full AIG + Guardrails + DLPoD stack running as quickly as possible. It creates all networking, IAM, and instance resources and wires the three services together automatically.

---

## How it works

Terraform provisions all AWS resources and the Netskope appliance registration in a defined order, enforced by readiness gates:

1. VPC, subnets, NAT gateway, VPC endpoints, and Route 53 are created first
2. Guardrails and DLPoD EC2 instances boot and run their setup sequences
3. `terraform apply` blocks at a readiness gate for each — Guardrails (~30 min) then DLPoD (~5–10 min)
4. Once both are confirmed healthy, the AIG instance is created and self-enrolls using a bootstrap secret from Secrets Manager

No SSH access is needed at any point. All instance access is via SSM Session Manager.

---

## What this deploys

```
Internet
    │ port 443
    ▼
┌─────────────────────────────────────────────────────────────┐
│  VPC (10.0.0.0/16)                                          │
│                                                              │
│  Public Subnet (10.0.1.0/24)                                │
│  ┌────────────────────┐   ┌──────────────┐                  │
│  │  AI Gateway (AIG)  │   │  NAT Gateway │                  │
│  │  EIP · port 443    │   │  EIP         │                  │
│  └────────┬───────────┘   └──────┬───────┘                  │
│           │                      │                           │
│  Private Subnet (10.0.2.0/24)                               │
│  ┌────────────────────┐  ┌───────────────────┐              │
│  │  Guardrails        │  │  DLPoD            │              │
│  │  g4dn.xlarge · .10 │  │  c5d.4xlarge · .20│              │
│  │  port 8080         │  │  port 443 (TLS)   │              │
│  └────────────────────┘  └───────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

### EC2 instances

| Instance | Default type | vCPU | RAM | Purpose |
|----------|-------------|------|-----|---------|
| AI Gateway | `c6a.4xlarge` | 16 | 32 GB | SSL offload, policy enforcement, routes traffic to Guardrails and DLPoD |
| Guardrails | `g4dn.xlarge` | 4 | 16 GB | NVIDIA T4 GPU — LLM model inference for AI content inspection |
| DLPoD | `c5d.4xlarge` | 16 | 32 GB | DLP content scanning. Local NVMe SSD speeds up first-boot `nsbootstrap` init |
| Bastion | `t3.small` | 2 | 2 GB | SSH/SSM troubleshooting access — **delete post-POV** |
| Windows 11 (optional) | `m5.xlarge` | 4 | 16 GB | Desktop for testing from inside the VPC. Only with `enable_win11_vm = true`; needs your own Windows 11 AMI |
| LibreChat (optional) | `t3.medium` | 2 | 4 GB | Chat UI (nginx + LibreChat + MongoDB in Docker) on TCP 443. Only with `enable_librechat = true` |

### Component roles

| Component | Subnet | Purpose |
|-----------|--------|---------|
| AI Gateway | Public | SSL termination, policy enforcement, routes AI traffic to Guardrails and DLP traffic to DLPoD |
| AI Guardrails | Private | GPU-backed LLM inference — scans AI prompts and responses against Netskope policies |
| DLP On-Demand | Private | AI-aware DLP inspection — detects sensitive data in AI queries and responses |
| LibreChat | Public | Optional (`enable_librechat`). HTTPS on 443 from `librechat_allowed_cidr_blocks`, with a certificate signed by the lab root CA. See [LibreChat](#librechat-optional) |
| Windows 11 VM | Public | Optional (`enable_win11_vm`). RDP from `win_allowed_cidr_blocks`; can reach every other instance on all ports. See [Windows 11 VM](#windows-11-vm-optional) |
| Bastion | Public | AIG certificate and host setup, AIG readiness reporting, DLPoD readiness probe, troubleshooting access. Optional after setup: `enable_bastion = false` removes it (see [Removing the bastion](#removing-the-bastion)) |

### AWS resources created

| Service | Resources |
|---------|-----------|
| **VPC** | VPC, public + private subnets, internet gateway, NAT gateway, route tables |
| **EC2** | 4 instances (AIG, Guardrails, DLPoD, Bastion), 2 Elastic IPs (AIG + NAT GW); optionally a Windows 11 VM and a LibreChat instance, each with its own Elastic IP |
| **Security groups** | One per instance with least-privilege ingress/egress rules |
| **IAM** | Instance roles and profiles for AIG and Guardrails; DLPoD reads config from user-data only |
| **Secrets Manager** | AIG bootstrap secret (enrollment token + Guardrails host + DLPoD TLS config) |
| **SSM Parameter Store** | Guardrails readiness signal (`/<prefix>/guardrails-ready`) and AIG readiness signal (`/<prefix>/aig-ready`) |
| **CloudWatch Logs** | Guardrails service log group (30-day retention) |
| **VPC Endpoints** | Interface: SSM, SSMMessages, EC2Messages, CloudWatch Logs. Gateway: S3 |
| **Route 53** | Private hosted zone resolving `dlp.aig.internal` → DLPoD private IP |
| **TLS certificates** | CA + leaf cert for DLPoD — generated by Terraform `tls` provider, no external CA required |

---

## How long does deployment take?

With the `wait_for_*` variables set to `true` (they default to `false`; see [Deployment ordering](#deployment-ordering)), `terraform apply` blocks at readiness gates for Guardrails and DLPoD before creating the AIG and at a third after it. With the defaults it creates everything without waiting and finishes much sooner than the totals below. Observed timings on `g4dn.xlarge` in us-west-1:

| Stage | Duration | What's happening |
|-------|----------|-----------------|
| VPC + networking | ~2 min | Subnets, IGW, NAT gateway, route tables, VPC endpoints, Route 53 |
| Guardrails Phase 1 | ~5–15 min | OS package updates, NVIDIA GPU driver check/install/upgrade; reboots only if the driver or kernel changed |
| Guardrails Phase 2 | ~3–20 min | NVIDIA container toolkit and Docker check/install/upgrade, LLM image (S3 download + `docker load` only if not already on the AMI), container start/restart, health check |
| DLPoD bootstrap | ~5–10 min | `nsbootstrap` applies TLS certs and license key, `nssetupdlpaas` installs DLP pod |
| AIG creation | ~2–3 min | Enrollment token written to Secrets Manager, AIG EC2 boots and self-enrolls with Netskope tenant |
| AIG readiness | ~3–10 min (estimate, not yet measured) | The bastion confirms enrollment, installs the certificate, and confirms the DLP and Guardrails host settings (`aig_ready` gate) |
| **Total** | **~35–50 min** | |

Observed with a pre-built Guardrails VM (`guardrails_ami_id` set), which is the fast path:

| `wait_for_*` variables | `terraform apply` takes | Fully ready |
|------------------------|-------------------------|-------------|
| `true` | about 30 minutes | When apply finishes. Everything is truly ready. |
| `false` (default) | about 5 minutes | About 30 minutes after apply started. Apply finishes before DLPoD and Guardrails are ready; see [Deployment ordering](#deployment-ordering). |

---

## Prerequisites

- [ ] **Terraform ≥ 1.9** — [download here](https://developer.hashicorp.com/terraform/install)
- [ ] **AWS CLI profile** configured — see [Environment variables](#environment-variables) below
- [ ] **GPU instance quota** for `g4dn` or `g5` in your target region — AWS console → Service Quotas → EC2
- [ ] **Netskope REST API v2 token** — Netskope tenant → Settings → Tools → REST API v2
- [ ] **AIG AMI ID** — subscribe to the Netskope AI Gateway on AWS Marketplace; AMI ID is region-specific, shown after accepting terms
- [ ] **DLPoD license key** — obtain from Netskope
- [ ] **S3 bucket with Guardrails image** — upload `aisecurity-llm.tgz` to an S3 bucket in the same region before running `terraform apply`. Not needed if you set `guardrails_ami_id` to a custom AMI that already contains the image.

---

## Environment variables

Set these before running any Terraform command. Do not put them in `terraform.tfvars`.

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-rest-api-v2-token"
```

**AWS credentials:** A configured AWS CLI profile is required. If you haven't set one up, follow the [AWS CLI configuration guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html). Terraform picks up your default profile automatically — to use a named profile, run `export AWS_PROFILE=your-profile-name` before applying.

**DLPoD license key:** The `netskope_onpremappliance_licensekey` variable is marked sensitive. Pass it via environment variable rather than putting it in `terraform.tfvars`:

```bash
export TF_VAR_netskope_onpremappliance_licensekey="your-dlpod-license-key"
```

Or set it in `terraform.tfvars` (the file is gitignored). Either approach works.

---

## Quick start

```bash
# 1. Copy and fill in variables
cp terraform.tfvars.example terraform.tfvars
# Required: availability_zone, and either guardrails_llm_image_s3_bucket or guardrails_ami_id
# Set netskope_onpremappliance_licensekey via TF_VAR_netskope_onpremappliance_licensekey or in terraform.tfvars

# 2. Upload the Guardrails Docker image to S3
aws s3 cp aisecurity-llm.tgz s3://my-guardrails-bucket/aisecurity-llm.tgz

# 3. Set environment variables (see above)

# 4. Deploy
terraform init
terraform apply
```

---

## Variables reference

### Required — no working default

| Variable | Description | Example |
|----------|-------------|---------|
| `availability_zone` | Availability zone for all subnets — must be valid for `aws_region` | `"us-east-1a"` |
| `aig_ami_id` | AMI ID for the AIG appliance in your region. Subscribe on AWS Marketplace and accept the terms. | `"ami-0a66805d7fb085df4"` |
| `netskope_onpremappliance_licensekey` | Netskope license key for the DLPoD appliance (sensitive — use `TF_VAR_netskope_onpremappliance_licensekey`) | — |
| `netskope_server_url` | Netskope tenant API URL. Recommended: set via `NETSKOPE_SERVER_URL` env var (see [Environment variables](#environment-variables)). | `"https://tenant.goskope.com"` |
| `netskope_api_key` | Netskope REST API v2 token (sensitive). Recommended: set via `NETSKOPE_API_KEY` env var. | — |
| `bastion_private_ip` | Fixed private IP for the bastion — must be within `public_subnet_cidr` | `"10.0.1.11"` |
| `enable_bastion` | Create the bastion and everything that exists only for it. `true` by default; see [Removing the bastion](#removing-the-bastion). | `true` |
| `wait_for_guardrails_to_deploy_dlpod` | Wait for Guardrails to be healthy before creating DLPoD. See [Deployment ordering](#deployment-ordering). | `false` |
| `wait_for_guardrails_to_deploy_aig` | Wait for Guardrails to be healthy before creating the AIG | `false` |
| `wait_for_dlpod_to_deploy_aig` | Wait for DLPoD's HTTPS service before creating the AIG | `false` |
| `wait_for_aig_to_complete_template` | Wait for `aig-ready` to be healthy before `terraform apply` finishes | `false` |

### SSH keys

A new AWS key pair, `<aws_object_unique_prefix>-keypair`, is created from a private key. The AIG always uses it. The private key is stored in Secrets Manager (`aig/<aws_object_unique_prefix>/ssh-private-key`) and the bastion downloads it at first boot to `~/.ssh/<aws_object_unique_prefix>-keypair.pem` for both the `ubuntu` user (SSH logins) and `ssm-user` (SSM Session Manager), so the bastion can SSH to the AIG from either session type.

| Variable | Default | Description |
|----------|---------|-------------|
| `keypair_existing_private_key_local_path` | `""` | Local path to an existing unencrypted private key (PEM or OpenSSH). Blank generates a private key locally, written to `my-private-key.pem` in this directory (gitignored). A path that does not exist, or a file that is not a valid private key, fails the plan. |
| `bastion_key_pair_name` | `""` | Blank uses the new key pair. Otherwise the name of an existing AWS key pair in `aws_region`. |
| `win11_key_pair_name` | `""` | Blank uses the new key pair. Otherwise the name of an existing AWS key pair in `aws_region`. Used only when `enable_win11_vm` is true. |
| `librechat_key_pair_name` | `""` | Blank uses the new key pair. Otherwise the name of an existing AWS key pair in `aws_region`. Used only when `enable_librechat` is true. |
| `guardrails_key_pair_name` | `""` | Blank uses the new key pair. Otherwise the name of an existing AWS key pair in `aws_region`. |
| `dlpod_key_pair_name` | `""` | Blank uses the new key pair. Otherwise the name of an existing AWS key pair in `aws_region`. DLPoD does not use EC2 key injection; see `dlpod_ssh_public_key`. |

### AIG — Signing CA

One lab root CA signs both certificates in this deployment: the bastion signs the CSR generated by the AIG, and Terraform signs the DLPoD server certificate (the CA certificate is also the AIG's trust anchor for DLPoD). There is no intermediate CA. The CA key and certificate are stored in Secrets Manager (`aig/<aws_object_unique_prefix>/ca-key` and `aig/<aws_object_unique_prefix>/ca-cert`) and the bastion downloads them at first boot to `/home/ssm-user/<aws_object_unique_prefix>-root-ca-key.pem` and `/home/ssm-user/<aws_object_unique_prefix>-root-ca-cert.pem`. The bastion uses them to sign the AIG certificate (see [AIG certificate setup](#aig-certificate-setup-bastion)).

A new root CA is generated with `openssl` (which must be on the `PATH` of the machine running Terraform) unless `ca_existing_signing_key_local_path` is set. To regenerate it, run `terraform apply -replace='null_resource.ca_new[0]'`.

| Variable | Default | Description |
|----------|---------|-------------|
| `ca_existing_signing_key_local_path` | `""` | Local path to an existing CA signing key (PEM). When set, no signing key is created. Blank generates `<aws_object_unique_prefix>-root-ca-key.pem` and `<aws_object_unique_prefix>-root-ca-cert.pem` in this directory (gitignored). |
| `ca_existing_signing_cert_local_path` | `""` | Local path to the certificate matching the existing signing key. Required when `ca_existing_signing_key_local_path` is set. |
| `ca_new_subj` | `"/C=US/ST=CA/L=SantaClara/O=NetskopeLab/OU=Security/CN=Netskope Lab Root CA/emailAddress=admin@lab.internal"` | Subject of the new CA certificate (`openssl req -subj` format) |
| `ca_new_addext` | `["basicConstraints=critical,CA:TRUE", "keyUsage=critical,keyCertSign,cRLSign"]` | Extensions of the new CA certificate, one `-addext` value per entry |
| `ca_new_algorithm` | `"RSA"` | Key algorithm of the new CA. Only RSA is supported. |
| `ca_new_rsa_bits` | `2048` | RSA key size of the new CA: `2048`, `3072` or `4096` |
| `ca_new_days` | `365` | Validity of the new CA certificate in days |

### AIG — Cert

Subject and key settings for the certificate whose CSR the AIG generates (signed by the signing CA above). The CN is not configurable: it is always the AIG's AWS-generated public DNS name (the Elastic IP's `public_dns`, exposed as the `aig_fqdn` output). The bastion uses these fields when it requests and signs the AIG certificate (see [AIG certificate setup](#aig-certificate-setup-bastion)).

| Variable | Default | Description |
|----------|---------|-------------|
| `aig_cert_organization` | `null` | Organization (O), up to 256 characters |
| `aig_cert_organization_unit` | `null` | Organizational unit (OU), up to 256 characters |
| `aig_cert_email` | `null` | Subject email address |
| `aig_cert_country` | `null` | Two-letter country code (C) |
| `aig_cert_state` | `null` | State or province (ST), up to 256 characters |
| `aig_cert_city` | `null` | City or locality (L), up to 256 characters |
| `aig_cert_key_algorithm` | `null` | `ecdsa`, `rsa` or `ed25519`; the AIG defaults to ecdsa (P-256) when unset |
| `aig_cert_key_size` | `null` | RSA key size: `2048`, `3072` or `4096` |
| `aig_cert_key_curve` | `null` | ECDSA curve: `P256`, `P384` or `P521` |
| `aig_cert_validity_period_days` | `90` | Validity of the signed AIG certificate in days. Keep it shorter than the CA's validity. |

### DLPoD — Cert

Subject, key and validity of the DLPoD server certificate, signed by the signing CA. The DNS SAN is always `dlpod_hostname` and the IP SAN `dlpod_private_ip`.

| Variable | Default | Description |
|----------|---------|-------------|
| `dlpod_cert_common_name` | `null` | Certificate CN, up to 256 characters. Defaults to `dlpod_hostname`. |
| `dlpod_cert_organization` | `null` | Organization (O), up to 256 characters |
| `dlpod_cert_organization_unit` | `null` | Organizational unit (OU), up to 256 characters |
| `dlpod_cert_country` | `null` | Two-letter country code (C) |
| `dlpod_cert_state` | `null` | State or province (ST), up to 256 characters |
| `dlpod_cert_city` | `null` | City or locality (L), up to 256 characters |
| `dlpod_cert_key_algorithm` | `"RSA"` | Private key algorithm. Only RSA is supported. |
| `dlpod_cert_rsa_bits` | `2048` | RSA key size: `2048`, `3072` or `4096` |
| `dlpod_cert_validity_period_days` | `90` | Certificate validity in days. Keep it shorter than the CA's validity. |

### AWS and networking

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_object_unique_prefix` | `"netskope"` | Unique prefix for the names of all AWS resources (Name tags and name attributes). Lowercase letters, digits and hyphens, 1-20 characters. Must not start with `aws` or `ssm` (reserved by SSM Parameter Store, and the prefix is used in the readiness parameter names). |
| `aws_region` | `"us-east-1"` | AWS region to deploy all resources |
| `vpc_cidr` | `"10.0.0.0/16"` | CIDR for the new VPC |
| `public_subnet_cidr` | `"10.0.1.0/24"` | Public subnet — hosts the AIG (EIP) and NAT Gateway |
| `private_subnet_cidr` | `"10.0.2.0/24"` | Private subnet — hosts Guardrails and DLPoD |

### Allowed source CIDRs

Four lists control who can reach the deployment from outside. All default to `["10.0.0.0/16"]`, the default `vpc_cidr`, so by default only hosts inside the VPC can connect. Widen them to your corporate egress IP or VPN range as needed.

Every entry must be IPv4 in CIDR notation with no host bits set. Terraform rejects anything else at plan time. A single address is a `/32`; a bare address such as `203.0.113.25` fails validation, and so does `10.0.0.5/16` (use `10.0.0.0/16`). An empty list `[]` creates no rule.

```hcl
aig_allowed_cidr_blocks       = ["203.0.113.25/32", "10.0.0.0/16"]
bastion_allowed_cidr_blocks   = ["203.0.113.25/32"]
win_allowed_cidr_blocks       = ["203.0.113.25/32"]
librechat_allowed_cidr_blocks = ["203.0.113.25/32"]
```

| Variable | Default | Allows |
|----------|---------|--------|
| `aig_allowed_cidr_blocks` | `["10.0.0.0/16"]` | HTTPS (TCP 443) to the AIG. Renamed from `allowed_cidr_blocks`: update any existing `terraform.tfvars`, or the AIG reverts to the default and stops accepting your clients. |
| `bastion_allowed_cidr_blocks` | `["10.0.0.0/16"]` | SSH (TCP 22) to the bastion. Used only when `enable_bastion` is true. Session Manager needs no rule. |
| `win_allowed_cidr_blocks` | `["10.0.0.0/16"]` | RDP (TCP 3389) to the Windows 11 VM. Used only when `enable_win11_vm` is true. |
| `librechat_allowed_cidr_blocks` | `["10.0.0.0/16"]` | HTTPS (TCP 443) to LibreChat. Used only when `enable_librechat` is true. Registration is open, so this list is the only access control. |

### Windows 11 VM (optional)

Set `enable_win11_vm = true` to add a Windows 11 desktop in the public subnet, with its own Elastic IP. RDP (TCP 3389) is allowed from `win_allowed_cidr_blocks`. The VM can reach the AIG, DLPoD and Guardrails (and the bastion and LibreChat, when they are enabled) on every port: the template adds an "all traffic from the Windows 11 security group" rule to each of their security groups. Nothing is created when `enable_win11_vm` is false.

AWS publishes no Windows 11 AMI for EC2, so there is no default for `win11_ami_id`. You must supply a licensed Windows 11 image in `aws_region`, imported with VM Import/Export or built from an ISO with EC2 Image Builder. Terraform rejects `enable_win11_vm = true` without a valid `ami-…` value.

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_win11_vm` | `false` | Create the Windows 11 VM, its security group and Elastic IP, and the rules that let it reach the other instances |
| `win11_ami_id` | `""` | Your Windows 11 AMI ID. Required when `enable_win11_vm` is true |
| `win11_instance_type` | `"m5.xlarge"` | Must be a Nitro type that supports your image's UEFI boot, and be available with the chosen tenancy |
| `win11_tenancy` | `"dedicated"` | `dedicated` or `default`. Windows 11 licensing on AWS generally requires dedicated hardware, which AWS bills at an additional hourly rate. Use `default` only if your license terms allow shared tenancy |
| `win11_private_ip` | `"10.0.1.12"` | Fixed private IP. Must be within `public_subnet_cidr` and differ from `aig_private_ip` and `bastion_private_ip` |
| `win11_key_pair_name` | `""` | See [SSH keys](#ssh-keys) |

Outputs: `win11_instance_id`, `win11_public_ip` (connect with RDP to this address) and `win11_private_ip`. All are null when the VM is disabled. To remove the VM, set `enable_win11_vm = false` and apply.

### LibreChat (optional)

Set `enable_librechat = true` to add a [LibreChat](https://www.librechat.ai/) chat UI on its own instance in the public subnet, with an Elastic IP. nginx serves it over HTTPS on TCP 443 from `librechat_allowed_cidr_blocks`. Nothing is created when `enable_librechat` is false.

**Registration is open.** Anyone who can reach port 443 can create an account, so `librechat_allowed_cidr_blocks` is the only access control. Keep it to your own networks.

**Nothing is preconfigured.** LibreChat starts with its defaults and no `librechat.yaml`: no LLM or MCP endpoint is set up, and no Bedrock access is granted to the instance.

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_librechat` | `false` | Create the LibreChat instance, its security group, Elastic IP, IAM role, certificate and TLS secret |
| `librechat_allowed_cidr_blocks` | `["10.0.0.0/16"]` | See [Allowed source CIDRs](#allowed-source-cidrs) |
| `librechat_instance_type` | `"t3.medium"` | It runs LibreChat and MongoDB; use at least 4 GB of RAM |
| `librechat_private_ip` | `"10.0.1.13"` | Fixed private IP. Must be within `public_subnet_cidr` and differ from the other instances' |
| `librechat_image_tag` | `"latest"` | Tag of the `ghcr.io/danny-avila/librechat` image. `latest` follows new releases, so a rebuilt instance can run a different version; set a release tag from the [LibreChat releases](https://github.com/danny-avila/LibreChat/releases) for a repeatable deployment |
| `librechat_cert_validity_period_days` | `90` | Server certificate validity. Keep it shorter than `ca_new_days` |
| `librechat_key_pair_name` | `""` | See [SSH keys](#ssh-keys) |

**How it is built**

- **Containers:** Docker Compose under `/opt/librechat` runs nginx (`nginx:1.27-alpine`), LibreChat and MongoDB (`mongo:8.0`), all with `restart: unless-stopped`. Search (Meilisearch) and the RAG API are not installed.
- **TLS:** Terraform signs a server certificate with the lab root CA, the way it signs DLPoD's (CN and DNS name: the Elastic IP's public DNS name; IP SANs: its public and private IPs). The certificate and key are stored in the Secrets Manager secret `aig/<aws_object_unique_prefix>/librechat-tls` and downloaded by the instance at boot, so they are not in user data. They live in Terraform state, like the other keys. This does not depend on the bastion: `enable_bastion = false` leaves the LibreChat secret alone.
- **Trust:** the CA is `<aws_object_unique_prefix>-root-ca-cert.pem` in this directory. Browsers and clients show a certificate warning until it is added to their trust store. Browse to the `librechat_url` output rather than the IP, so the name matches the certificate.
- **LibreChat secrets:** `JWT_SECRET`, `JWT_REFRESH_SECRET`, `CREDS_KEY` and `CREDS_IV` are generated on the instance at first boot and saved in `/opt/librechat/.env` (mode 600). They are never in Terraform state or user data.
- **Other instances:** LibreChat can reach the AIG on 443 whatever `aig_allowed_cidr_blocks` says, the bastion can SSH to it, and the Windows 11 VM (if enabled) can reach it on every port. It has no Bedrock or other permissions beyond Session Manager and reading its own TLS secret.
- **Replacement loses data:** MongoDB is on the instance's disk. Changing `librechat_image_tag`, the certificate (including a validity change) or the setup script replaces the instance and with it every chat and account.

**Adding an endpoint later**

Put a `librechat.yaml` in `/opt/librechat/config/` on the instance and restart LibreChat:

```bash
sudo docker compose -f /opt/librechat/docker-compose.yml restart librechat
```

The config directory is mounted into the container and `CONFIG_PATH` points to `/librechat-config/librechat.yaml`. The file is absent by default, and LibreChat should run with its defaults without it (confirm in the first-boot log). Files edited on the instance are lost when it is replaced.

**Health checks**

First boot installs Docker and pulls three images, so allow about 3–6 minutes after the instance is running. No Terraform gate waits for LibreChat; `terraform apply` finishes when the instance is created. Connect with `terraform output -raw librechat_ssm_connect_command` and run the checks on the instance:

```bash
# 1. First boot finished (prints "status: done"); log: /var/log/cloud-init-output.log
sudo cloud-init status --wait

# 2. The certificate and key were downloaded (both non-empty)
ls -l /opt/librechat/tls

# 3. All three containers are running
sudo docker compose -f /opt/librechat/docker-compose.yml ps

# 4. LibreChat answers through nginx and TLS (prints OK)
curl -sk https://localhost/health
```

From a client that can reach port 443, and trusts the lab root CA:

```bash
curl --cacert <aws_object_unique_prefix>-root-ca-cert.pem "$(terraform output -raw librechat_url)/health"
```

| Symptom | Likely cause |
|---------|--------------|
| Connection times out | The client's address is not in `librechat_allowed_cidr_blocks`, or the instance is still booting |
| Certificate warning, or a TLS error without `-k` | The client does not trust the lab root CA, or you used the IP instead of the `librechat_url` name |
| `502 Bad Gateway` | nginx is up but LibreChat is still starting or has crashed: `sudo docker compose -f /opt/librechat/docker-compose.yml logs --tail 100 librechat` |
| Connection refused on 443 | nginx is not running, usually because `/opt/librechat/tls/server.key` is missing or empty (check step 2 and `/var/log/cloud-init-output.log`) |
| `librechat` keeps restarting | MongoDB is not up: `sudo docker compose -f /opt/librechat/docker-compose.yml logs --tail 100 mongodb` |

Logs: `sudo docker compose -f /opt/librechat/docker-compose.yml logs -f nginx librechat mongodb`.

### AIG — Netskope

| Variable | Default | Description |
|----------|---------|-------------|
| `aig_netskope_name` | `"aig-lab"` | AIG display name in Netskope tenant (1–15 characters) |
| `secret_name` | `aig/<aws_object_unique_prefix>/bootstrap` | Secrets Manager secret name. Must start with `aig/`. Set only to override the default. |

### AIG — EC2

| Variable | Default | Description |
|----------|---------|-------------|
| `aig_instance_type` | `"c6a.4xlarge"` | AIG EC2 instance type — 16 vCPU / 32 GB minimum |
| `aig_private_ip` | `"10.0.1.10"` | Fixed private IP — must be within `public_subnet_cidr` |

### Guardrails

| Variable | Default | Description |
|----------|---------|-------------|
| `project` | `"guardrails"` | Project identifier used in resource names and tags |
| `environment` | `"dev"` | Environment tag (`dev`, `staging`, `prod`) |
| `guardrails_instance_type` | `"g4dn.xlarge"` | GPU instance type. Use `g5.xlarge` for higher throughput. |
| `volume_size_gb` | `100` | Root EBS volume size in GB (minimum 80) |
| `guardrails_private_ip` | `"10.0.2.10"` | Fixed private IP — embedded in AIG bootstrap secret at plan time; do not change after apply |
| `guardrails_llm_image_s3_bucket` | `""` | S3 bucket containing `aisecurity-llm.tgz`. **Required when `guardrails_ami_id` is empty**; with a custom AMI that ships the image it is optional (fallback only). |
| `guardrails_llm_image_s3_key` | `"aisecurity-llm.tgz"` | S3 object key for the Guardrails image tarball |
| `guardrails_ami_id` | `""` | Custom Guardrails AMI (Ubuntu-based, with NVIDIA driver, container toolkit, Docker and the LLM image). Out-of-date components are upgraded at first boot. Empty = stock Ubuntu 22.04, install everything at boot. `volume_size_gb` must be ≥ the AMI's root snapshot size. |

### DLPoD

| Variable | Default | Description |
|----------|---------|-------------|
| `dlpod_ami_id` | `"ami-0b3a14615c7e7944e"` | DLPoD AMI — default is us-west-1; update for other regions |
| `dlpod_instance_type` | `"c5d.4xlarge"` | DLPoD EC2 instance type |
| `dlpod_private_ip` | `"10.0.2.20"` | Fixed private IP — embedded in AIG bootstrap secret at plan time; do not change after apply |
| `dlpod_persona` | `"dlp-on-demand"` | DLPoD persona (`dlp-on-demand` or `dspm`) |
| `dlpod_hostname` | `"dlp.aig.internal"` | TLS hostname and Route 53 record name for DLPoD |
| `dlpod_ssh_public_key` | `""` | SSH public key injected into `nsadmin` via bootstrap. DLPoD does not use EC2 key injection — set this explicitly if you need SSH access. |

---

## AIG setup and readiness (bastion)

The bastion runs `aig-cert-setup.service` continuously (`Restart=always`; script: [templates/aig-cert-setup.sh](templates/aig-cert-setup.sh), installed to `/usr/local/bin/aig-cert-setup.sh`; settings in `/etc/aig-cert-setup.conf`). It never exits on its own. Each step below is retried every 60 seconds until it reads back positive; where a setting is wrong it is fixed through the AIG Configuration API and read back before moving on.

| Step | Passes when |
|------|-------------|
| `prereqs` | The SSH key, lab root CA key and certificate, and `jq` are present. |
| `instance` | The AIG EC2 instance (found by its `Name` tag) is running. The bastion role has `ec2:DescribeInstances` for this. |
| `api` | The AIG public FQDN (the `aig_fqdn` output, which becomes the certificate CN) is known and `enable-api --ttl 1h` over SSH to `nsadmin@<aig_private_ip>` returns an AIG Config API token. The token is regenerated after an HTTP 401 or about 50 minutes. |
| `enrollment` | `GET https://<aig_private_ip>:8443/v1/config/bootstrap` reports `status` = `completed`. `failed` is permanent for that AIG instance. |
| `certificate` | `GET /v1/config/certificate/status` reports `Active`. If the AIG has no certificate, the script posts a CSR (the `aig_cert_*` fields) to `/v1/config/certificate/csr`, signs it with the lab root CA (`subjectAltName = DNS:<fqdn>`, `extendedKeyUsage = serverAuth`), and posts the result to `/v1/config/certificate/install`. Files: `/home/ssm-user/aig-cert-request.csr` and `aig-cert-signed.pem`. |
| `dlp` | `GET /v1/config/dlp` shows `certificate_configured` and `host_config.host_url` = `https://<dlpod_hostname>`. If not, the script uploads the lab root CA (`PUT /v1/config/dlp/ca-cert`) and sets the host (`PUT /v1/config/dlp/hostconfig`), then reads it back. |
| `guardrails` | `GET /v1/config/ai-guardrails` shows `host_config.host_url` = the `guardrails_host_url` output. If not, it is set with `PUT /v1/config/ai-guardrails/hostconfig` and read back. |

The bootstrap secret's `dlp` and `ai_guardrails` blocks are applied once after enrollment and a failure there is silent, which is why `dlp` and `guardrails` are checked and fixed here.

### Readiness reporting

The script writes its status to the SSM parameter `/<prefix>/aig-ready` (the bastion role may only `ssm:PutParameter` on it):

```
passed: prereqs, instance, api, enrollment | waiting on: certificate | then: dlp, guardrails | last error: <error>
```

The value lists the steps that have passed, the step being waited on, the steps still to come, and the last error. A permanent failure (bootstrap status `failed`) starts the value with `FAILED: <step> | `. When every step has passed the value is `healthy:<AIG instance id>`. After that the script keeps watching the AIG instance and starts over if it is replaced.

`null_resource.aig_ready` (in `aig.tf`) runs after the AIG is created and polls the parameter every 10 seconds until it equals `healthy:<this AIG's instance id>` (up to 60 minutes), so `terraform apply` finishes only once the AIG is enrolled and configured. It stops early if the value starts with `FAILED:`. Because the instance ID is part of the value, a value left by an earlier AIG can never satisfy the gate. You can read the status at any time:

```bash
aws ssm get-parameter --name "/<prefix>/aig-ready" --region <region> --query Parameter.Value --output text
```

Progress and errors are logged with timestamps to `/var/log/aig-cert-setup.log`. From an SSM session, follow it with `sudo tail -f /var/log/aig-cert-setup.log`. To force a fresh pass, run `sudo systemctl restart aig-cert-setup`.

### Removing the bastion

Once the AIG is fully set up (`aig-ready` reads `healthy:<id>`), set `enable_bastion = false` and run `terraform apply`. Terraform removes the bastion instance, its IAM role and policies, its security group and the rules it added to the AIG, DLPoD and Guardrails groups, the `aig-ready` parameter and gate, and the SSH private key and lab root CA key and certificate secrets in Secrets Manager. The AIG, DLPoD and Guardrails keep working: the AIG's certificate and its DLP and Guardrails host settings live on the appliance. The CA files on disk, the EC2 key pair, and the keys in Terraform state are not touched. The private key stays on disk where Terraform wrote it (a generated key) or where `keypair_existing_private_key_local_path` points, so you can still SSH to the appliances from a machine that can reach them.

Set `enable_bastion = true` again to rebuild it. The new bastion reads the secrets (recreated), finds the running AIG, and runs every check from the start. It changes only what differs: an `Active` certificate is left alone and matching DLP and Guardrails hosts are not rewritten. The apply then waits for `aig-ready` to read `healthy:<id>` again, because the parameter is recreated along with the bastion.

Notes:

- Do not disable the bastion on a first deployment. Without it the AIG gets no certificate and its DLP and Guardrails hosts are not re-checked.
- If the AIG is replaced while the bastion is disabled (for example after the 24-hour enrollment token expires), enable the bastion again so the new AIG is configured.
- With the bastion disabled, `wait_for_aig_to_complete_template` has no effect, and the DLPoD readiness gate probes from the Guardrails instance instead (the bastion otherwise does).
- If the AIG's certificate is no longer `Active` when the bastion is rebuilt, the script cannot reuse the old bastion's saved CSR and reports the problem instead of fixing it.

### Deployment ordering

Four variables control whether Terraform waits for a readiness gate before creating the next component. All default to `false`, so `terraform apply` creates everything without waiting and finishes quickly; set them to `true` to have Terraform wait. The `true` effects are:

| Variable | Default | Effect |
|----------|---------|--------|
| `wait_for_guardrails_to_deploy_dlpod` | `false` | DLPoD is not created until Guardrails reports healthy (about 30 minutes). `false`: as soon as the Guardrails instance exists. |
| `wait_for_guardrails_to_deploy_aig` | `false` | The AIG is not created until Guardrails reports healthy. `false`: as soon as the Guardrails instance exists. The AIG's bootstrap then fails to set the Guardrails host, and the bastion sets it later (see below). |
| `wait_for_dlpod_to_deploy_aig` | `false` | The AIG is not created until DLPoD's HTTPS service answers. `false`: as soon as the DLPoD instance exists. The AIG's bootstrap then fails to set the DLP host, and the bastion sets it later (see below). |
| `wait_for_aig_to_complete_template` | `false` | `terraform apply` does not finish until `aig-ready` is healthy. `false`: it finishes once the AIG is created. Needs `enable_bastion = true`. |

With `false`, a gate polls nothing but its dependent is still created only after the instance it would have waited for exists (about 2 minutes), because Terraform's dependencies are static.

#### What to expect with the waits on or off

The timings below are for a pre-built Guardrails VM.

- **The AIG Configuration API rejects a host that isn't answering.** Setting the DLP host (`PUT /v1/config/dlp/hostconfig`) fails while DLPoD isn't responding, and setting the AI Guardrails host (`PUT /v1/config/ai-guardrails/hostconfig`) fails while Guardrails isn't responding.
- **All waits `true`:** `terraform apply` takes about 30 minutes and everything is truly ready when it finishes. DLPoD and Guardrails are already healthy when the AIG boots, so its bootstrap sets both hosts.
- **All waits `false`:** `terraform apply` takes about 5 minutes, but everything is not truly ready until about 30 minutes after Terraform started. The AIG starts while DLPoD and Guardrails are still booting, so its bootstrap completes but fails to set the DLP and AI Guardrails hosts. The bastion script corrects this: it keeps retrying both host settings until the instances are healthy and the AIG accepts them. The `dlp` and `guardrails` steps in `aig-ready` show `waiting on` until then, with the API's error as the last error.
- **Which to use:** use `false` for a quick apply when you can wait for `aig-ready` to read `healthy:<id>` afterwards; use `true` when something needs the stack to be working the moment apply finishes.
- **Needs the bastion:** the catch-up depends on the bastion. With `enable_bastion = false` from the start, a failed bootstrap host setting is not corrected.

## Remote state

Terraform state for this template contains TLS private keys (the lab root CA and the DLPoD leaf certificate) in plaintext. Use S3 remote state with encryption at rest.

```bash
cp backend.hcl.example backend.hcl
# Edit backend.hcl — fill in your S3 bucket, region, and KMS key
terraform init -backend-config=backend.hcl
```

See [docs/deployment.md](docs/deployment.md) for the full backend configuration and why encryption matters here.

---

## Minimum AWS permissions

The IAM identity running `terraform apply` needs permissions across several services. No S3 permissions are required for the Guardrails image bucket — that access is granted to the Guardrails EC2 instance role, not the Terraform operator.

The optional Windows 11 VM (`enable_win11_vm`) and LibreChat instance (`enable_librechat`) need no actions beyond those listed below. They use the same EC2 actions (instances, Elastic IPs, security groups and rules), the same IAM role and instance profile actions, and the same Secrets Manager actions. The only new name to allow is the LibreChat TLS secret, `aig/<aws_object_unique_prefix>/librechat-tls`, which falls under the `aig/*` scope the other secrets use. Neither instance needs extra permissions on the Terraform side for Bedrock or other services, because LibreChat is not given any.

### EC2

```
ec2:Describe*
ec2:AllocateAddress / ReleaseAddress / AssociateAddress / DisassociateAddress
ec2:CreateVpc / DeleteVpc / ModifyVpcAttribute
ec2:CreateSubnet / DeleteSubnet / ModifySubnetAttribute
ec2:CreateInternetGateway / DeleteInternetGateway / AttachInternetGateway / DetachInternetGateway
ec2:CreateNatGateway / DeleteNatGateway
ec2:CreateRouteTable / DeleteRouteTable / AssociateRouteTable / DisassociateRouteTable / CreateRoute / DeleteRoute
ec2:CreateSecurityGroup / DeleteSecurityGroup
ec2:AuthorizeSecurityGroupIngress / AuthorizeSecurityGroupEgress
ec2:RevokeSecurityGroupIngress / RevokeSecurityGroupEgress
ec2:RunInstances / TerminateInstances / StopInstances
ec2:CreateVpcEndpoint / DeleteVpcEndpoints / ModifyVpcEndpoint
ec2:CreateTags / DeleteTags
```

### IAM

```
iam:CreateRole / DeleteRole / GetRole
iam:CreateInstanceProfile / DeleteInstanceProfile / GetInstanceProfile
iam:AddRoleToInstanceProfile / RemoveRoleFromInstanceProfile
iam:PutRolePolicy / DeleteRolePolicy / GetRolePolicy / ListRolePolicies
iam:AttachRolePolicy / DetachRolePolicy / ListAttachedRolePolicies  ← AmazonSSMManagedInstanceCore for Guardrails
iam:PassRole  (scoped to ec2.amazonaws.com)
```

### Secrets Manager

```
secretsmanager:CreateSecret / DeleteSecret / DescribeSecret
secretsmanager:GetSecretValue / PutSecretValue / TagResource
```

All the secrets this template creates are named `aig/<aws_object_unique_prefix>/…`: `bootstrap`, `ssh-private-key`, `ca-key`, `ca-cert` and, with LibreChat, `librechat-tls`. Scope these actions to `arn:aws:secretsmanager:<region>:<account>:secret:aig/*`. The EC2 instances' own roles are scoped to the individual secrets by Terraform.

### SSM

```
ssm:PutParameter / GetParameter / DeleteParameter   ← Guardrails and AIG readiness gates
ssm:DescribeParameters / ListTagsForResource        ← aws_ssm_parameter.aig_ready (Terraform refresh)
ssm:SendCommand / GetCommandInvocation              ← DLPoD readiness gate (polls via the bastion)
ssm:DescribeInstanceInformation
```

### CloudWatch Logs

```
logs:CreateLogGroup / DeleteLogGroup / DescribeLogGroups
logs:PutRetentionPolicy
```

### Route 53

```
route53:CreateHostedZone / DeleteHostedZone / GetHostedZone / ListHostedZones
route53:ChangeResourceRecordSets / ListResourceRecordSets
```

### Remote state (optional — recommended)

```
s3:GetObject / PutObject / DeleteObject   on your tfstate bucket
dynamodb:GetItem / PutItem / DeleteItem   on your lock table (if using DynamoDB locking)
```

---

## Terraform files

| File | Contents |
|------|----------|
| `main.tf` | Terraform config, providers, data sources, shared locals |
| `vpc.tf` | VPC, subnets, IGW, NAT gateway, route tables, VPC endpoints, Route 53 |
| `aig.tf` | Netskope appliance registration, Secrets Manager bootstrap, AIG IAM/SG/EC2, `aig-ready` parameter and readiness gate |
| `guardrails.tf` | Guardrails IAM, security group, CloudWatch, EC2, readiness parameter and gates |
| `dlpod.tf` | DLPoD TLS certificates, bootstrap config, IAM, security group, EC2, readiness gate |
| `ssh_keys.tf` | SSH key pair (provided or generated) and its Secrets Manager secret |
| `ca.tf` | Lab root CA (provided or generated with openssl) and its Secrets Manager secrets |
| `librechat.tf` | Optional LibreChat instance (`enable_librechat`): security group, lab-CA-signed certificate and its secret, IAM, EC2 instance, Elastic IP |
| `templates/librechat-userdata.sh.tpl` | LibreChat first-boot script: Docker, nginx, LibreChat and MongoDB compose stack |
| `win11.tf` | Optional Windows 11 VM (`enable_win11_vm`): security group, rules reaching the other instances, EC2 instance, Elastic IP |
| `bastion.tf` | Optional bastion (`enable_bastion`): AIG certificate and host setup, readiness reporting, DLPoD probe, troubleshooting access |
| `moved.tf` | `moved` blocks that keep existing state when resources gained `count`; safe to delete after one apply |
| `templates/aig-cert-setup.sh` | AIG certificate setup script installed on the bastion |
| `variables.tf` | All input variable definitions |
| `outputs.tf` | Terraform outputs |

---

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/deployment.md](docs/deployment.md) | Remote state setup (S3 backend with KMS encryption) |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Diagnostic commands, common failure modes, rebuild procedures |
| [docs/devops.md](docs/devops.md) | AWS service choices, bootstrap internals, AIG→DLPoD TLS validation, CI/CD integration |

---

## Key outputs

| Output | Description |
|--------|-------------|
| `aig_public_ip` | Elastic IP — configure AI clients to proxy through this on port 443 |
| `aig_instance_id` | EC2 instance ID of the AIG |
| `aig_fqdn` | AWS-generated public DNS name of the AIG's Elastic IP (the AIG certificate CN) |
| `guardrails_ssm_connect_command` | SSM Session Manager connect command for the Guardrails instance |
| `dlp_host` | DLP host URL configured in the AIG bootstrap (`https://dlp.aig.internal`) |
| `nat_gateway_ip` | Outbound IP for the private subnet — add to firewall allowlists if needed |
| `librechat_url` | HTTPS URL of the optional LibreChat instance (the Elastic IP's public DNS name, which the certificate names). Null unless `enable_librechat` is true |
| `win11_public_ip` | Elastic IP of the optional Windows 11 VM — RDP to this address. Null unless `enable_win11_vm` is true |

---

## Rebuild reference

Use `-replace` (Terraform ≥ 1.5) rather than `terraform taint`:

```bash
# AIG only — new token + new instance
terraform apply \
  -replace=netskope_aig_appliance_enrollment_token.this \
  -replace=aws_secretsmanager_secret_version.aig_bootstrap \
  -replace=aws_instance.aig

# Full AIG re-registration — new appliance record + token + instance
terraform apply \
  -replace=netskope_aig_appliance.this \
  -replace=netskope_aig_appliance_enrollment_token.this \
  -replace=aws_secretsmanager_secret_version.aig_bootstrap \
  -replace=aws_instance.aig
```

See [docs/troubleshooting.md](docs/troubleshooting.md) for DLPoD and Guardrails rebuild procedures.

---

## Tear down

```bash
terraform destroy
```

Type `yes` when prompted. All AWS and Netskope resources created by this template are removed. The bastion instance is included — there is no need to remove `bastion.tf` before destroying.
