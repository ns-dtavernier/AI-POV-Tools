# DevOps Reference

## Terraform files in this template

| File | Contents |
|------|----------|
| `main.tf` | Terraform config, providers, data sources, shared locals |
| `vpc.tf` | VPC, subnets, IGW, NAT gateway, route tables, VPC endpoints, Route 53 |
| `aig.tf` | Netskope appliance registration, Secrets Manager bootstrap, AIG IAM/SG/EC2 |
| `guardrails.tf` | Guardrails IAM, security group, CloudWatch, EC2, readiness gate |
| `dlpod.tf` | DLPoD TLS certificates, bootstrap config, IAM, security group, EC2, readiness gate |
| `bastion.tf` | Troubleshooting bastion (temporary — delete post-POV) |
| `variables.tf` | All input variable definitions |
| `outputs.tf` | Terraform outputs |

---


## AWS Services Used

### EC2

| Instance | Type | Purpose |
|----------|------|---------|
| AIG | `c6a.4xlarge` (16 vCPU, 32 GB) | Netskope AI Gateway appliance — SSL termination, policy enforcement, AI routing |
| Guardrails | `g4dn.xlarge` (NVIDIA T4 GPU) | LLM inference service — runs the Netskope AI security model in a Docker container |
| DLPoD | `c5d.4xlarge` (16 vCPU, 32 GB, local NVMe) | DLP On-Demand appliance — AI-aware content inspection. Root volume provisioned at 9000 IOPS GP3 to speed up `nsbootstrap` initialisation (can be reduced to 3000 IOPS post-init). `c5ad.4xlarge` is the AMD equivalent but is not available in us-west-1. |
| Bastion | `t3.small` | Troubleshooting host — delete post-POV |

**Why separate instances:** Each component has distinct compute profiles. The AIG is network-bound (SSL offload, proxying). Guardrails requires GPU for model inference. DLPoD is CPU-bound for content scanning.

### VPC & Networking

| Resource | Why |
|----------|-----|
| Public subnet | AIG requires a routable EIP for client connections and Netskope tenant communication |
| Private subnet | Guardrails and DLPoD are internal services — no public exposure needed or desired |
| NAT Gateway | Allows private subnet instances to reach the internet (NVIDIA drivers, Docker Hub, Netskope licensing) without having public IPs |
| Internet Gateway | Required for public subnet routing |
| VPC Endpoints (Interface) | SSM, SSMMessages, EC2Messages, CloudWatch Logs — keep management traffic on the AWS backbone, avoids NAT Gateway charges and latency for control plane operations |
| VPC Endpoint (Gateway) | S3 — free, keeps Guardrails image download (~10 GB) off the NAT Gateway entirely |
| Route 53 Private Hosted Zone | Resolves `dlp.aigw.internal` → DLPoD private IP within the VPC. Required because the AIG's Go TLS stack cannot verify certificates when connecting to a bare IP URL — it must connect by hostname |

### IAM

**AIG instance role:**
- `secretsmanager:GetSecretValue` on the bootstrap secret — reads enrollment token and service config at first boot

**Guardrails instance role:**
- `AmazonSSMManagedInstanceCore` (AWS managed policy) — enables SSM Session Manager
- `s3:GetObject` + `s3:ListBucket` on the image bucket/key — downloads `aisecurity-llm.tgz`
- `ssm:PutParameter` + `ssm:DeleteParameter` on `/<prefix>/guardrails-ready` — writes readiness signal
- `logs:CreateLogStream` + `logs:PutLogEvents` + `logs:DescribeLogStreams` on the CloudWatch log group

**DLPoD instance role:**
- No permissions granted — DLPoD reads its bootstrap from EC2 user-data directly

**Principle of least privilege:** Each role is scoped to the exact resources it needs. The AIG cannot read S3 or write SSM parameters. Guardrails cannot read Secrets Manager.

### Secrets Manager

The AIG bootstrap secret (`aig/prod/bootstrap`) stores:

```json
{
  "bootstrap": true,
  "enrollment_token": "<single-use token>",
  "ai_guardrails": {
    "host": "http://10.0.2.10:8080/invocations"
  },
  "dlp": {
    "certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
    "host": "https://dlp.aigw.internal"
  }
}
```

`recovery_window_in_days = 0` is set for POV convenience — in production this should be 7-30 days to enable recovery from accidental deletion.

### CloudWatch Logs

Log group `/<project>-<environment>/guardrails` with 30-day retention captures Guardrails service logs. The Guardrails instance writes logs via the CloudWatch agent using the interface VPC endpoint (no internet path).

### TLS (Terraform `tls` provider)

Terraform generates a two-tier certificate hierarchy for DLPoD:

```
tls_self_signed_cert.dlpod_ca (CA:TRUE)
    └── tls_locally_signed_cert.dlpod (CA:FALSE, server_auth)
            SANs: DNS:dlp.aigw.internal, IP:10.0.2.20
```

**Why two-tier:** DLPoD rejects CA:TRUE certificates in the `dlpaas.server-cert` field. The leaf cert must be signed by the CA, not self-signed.

**Where private keys live:** In Terraform state. Use S3 remote state with SSE-KMS encryption. See deployment guide for backend config.

---

## Bootstrap Process

### AIG Bootstrap

#### Certificate generation (Terraform apply — before any EC2 is created)

The DLPoD TLS certificates are generated entirely within Terraform using the `tls` provider. No external CA or manual cert step is required.

1. **`tls_private_key.dlpod_ca`** — generates a 2048-bit RSA private key for the CA
2. **`tls_self_signed_cert.dlpod_ca`** — issues a self-signed CA certificate (`CA:TRUE`, `cert_signing`) valid for 1 year. This is the trust anchor the AIG uses to verify DLPoD.
3. **`tls_private_key.dlpod`** — generates a 2048-bit RSA private key for the DLPoD server
4. **`tls_cert_request.dlpod`** — creates a CSR with:
   - `CN = var.dlpod_hostname` (default: `dlp.aigw.internal`)
   - `DNS SAN = dlp.aigw.internal`
   - `IP SAN = 10.0.2.20` (var.dlpod_private_ip)
5. **`tls_locally_signed_cert.dlpod`** — CA signs the CSR to produce the leaf server cert (`CA:FALSE`, `server_auth`) valid for 1 year

The CA cert PEM is then split across two consumers:
- → `aws_secretsmanager_secret_version.aig_bootstrap` as `dlp.certificate` (AIG uses this to verify DLPoD's TLS)
- → `local.dlpod_bootstrap.dlpaas.server-intermediate-ca-chain` (DLPoD sends this in the TLS handshake)

The leaf cert and private key go only to DLPoD:
- → `local.dlpod_bootstrap.dlpaas.server-cert` (leaf cert, `CA:FALSE`)
- → `local.dlpod_bootstrap.dlpaas.server-key` (PKCS#8 private key)

#### AIG provisioning sequence

6. **`aws_eip.aig`** allocated — public IP is known before the instance exists
7. **`netskope_aig_appliance.this`** created in the Netskope tenant using the EIP address
8. **`netskope_aig_appliance_enrollment_token.this`** generates a single-use token (expires 24 hours)
9. **`aws_secretsmanager_secret_version.aig_bootstrap`** writes to Secrets Manager:
   ```json
   {
     "bootstrap": true,
     "enrollment_token": "<single-use token>",
     "ai_guardrails": { "host": "http://10.0.2.10:8080/invocations" },
     "dlp": {
       "certificate": "-----BEGIN CERTIFICATE-----\n<CA cert PEM>\n-----END CERTIFICATE-----\n",
       "host": "https://dlp.aigw.internal"
     }
   }
   ```
   Note: `dlp.certificate` is the **CA cert**, not the leaf cert. The AIG uses it as a trust anchor to verify the cert chain DLPoD presents. `dlp.host` uses the hostname (not bare IP) — see the AIG Validation section below.

#### AIG first boot

10. **EC2 user-data** contains only: `{ "bootstrap_secret": "aig/prod/bootstrap" }`
11. AIG calls `secretsmanager:GetSecretValue` using its IAM instance profile
12. AIG uses `enrollment_token` to register with the Netskope tenant
13. AIG configures Guardrails at `ai_guardrails.host`
14. AIG validates and configures DLPoD at `dlp.host` — see AIG Validation section

**Dependency:** AIG EC2 is created only after both `null_resource.guardrails_ready` and `null_resource.dlpod_ready` succeed — Guardrails and DLPoD must be serving before the AIG tries to validate them.

### Guardrails Bootstrap (Two-Phase)

**Phase 1 — EC2 UserData (runs at first boot, triggers reboot) — observed ~15 min:**
1. Install `awscli`, `curl`, `ubuntu-drivers-common` and apply OS upgrades (~5–10 min — Ubuntu 22.04 runs automatic package updates at first boot)
2. Delete any stale `/<prefix>/guardrails-ready` SSM parameter from a previous deployment
3. Install NVIDIA GPU driver (`ubuntu-drivers install` — selects correct version automatically) (~3–5 min)
4. Write Phase 2 script to `/opt/guardrails-phase2.sh`
5. Install and enable `guardrails-setup.service` systemd unit
6. Reboot to activate the NVIDIA kernel module

**Phase 2 — systemd service (runs after reboot) — observed ~15–20 min:**
1. Verify NVIDIA driver loaded (`nvidia-smi`)
2. Install NVIDIA Container Toolkit (~2 min)
3. Install Docker CE (~1–2 min)
4. Configure Docker NVIDIA runtime; verify GPU access with a test container
5. Download `aisecurity-llm.tgz` (~15 GB) from S3 via VPC Gateway Endpoint (no NAT Gateway charge) — observed ~2 min at 100–130 MiB/s
6. Load Docker image: `docker load -i /tmp/aisecurity-llm.tgz` — observed ~3–5 min
7. Start container on port 8080 with GPU access and `--restart=unless-stopped`
8. Poll `http://localhost:8080/ping` until `{"status":"Healthy"}`
9. Write SSM Parameter `/<prefix>/guardrails-ready = healthy`

**Readiness gate:** `null_resource.guardrails_ready` deletes any stale parameter first, then polls every 30 seconds (up to 40 minutes). `terraform apply` blocks here until the parameter appears. **Observed total Phase 1 + Phase 2: ~30 minutes** on `g4dn.xlarge` in us-west-1.

**Monitor progress:**
```bash
aws ssm start-session --target <instance-id> --region <region>
sudo tail -f /var/log/user-data.log          # Phase 1
sudo tail -f /var/log/guardrails-phase2.log  # Phase 2
```

### DLPoD Bootstrap

DLPoD uses Netskope's `nsbootstrap.service` — a first-boot service that reads raw JSON from EC2 user-data and applies it. Terraform delivers the complete bootstrap config via `user_data = jsonencode(local.dlpod_bootstrap)`.

**Bootstrap fields applied:**

| Field | Content | Purpose |
|-------|---------|---------|
| `persona` | `dlp-on-demand` | Activates DLP inspection mode |
| `dns.primary` | VPC DNS resolver (`vpc_cidr + 2`) | Ensures DLPoD uses VPC DNS to resolve internal names |
| `system.licensekey` | Netskope license key | Activates the appliance |
| `system.hostname` | `dlp.aigw.internal` | Sets appliance hostname |
| `system.ssh-allowlist` | Public subnet CIDR | Restricts SSH access to the public subnet only |
| `dlpaas.server-cert` | Leaf TLS cert (CA:FALSE) | The HTTPS certificate DLPoD presents |
| `dlpaas.server-key` | Leaf private key (PKCS#8) | Private key for the TLS cert |
| `dlpaas.server-intermediate-ca-chain` | CA cert | Sent as the TLS chain |

**IMDSv2:** The DLPoD instance enforces `http_tokens = "required"` with `http_put_response_hop_limit = 1`. This mitigates two attack classes:
- **Redirect-based SSRF:** A web application tricked into following a redirect to `169.254.169.254` receives a 401 — IMDSv2 requires a PUT to obtain a session token before any GET, which redirect chains cannot satisfy.
- **Container access:** The hop limit of 1 causes the PUT token request's TTL to be decremented at the container network boundary, preventing containerised processes from obtaining a metadata token at all.

Note: IMDSv2 does not prevent processes running directly in the host network namespace from reading user-data — any host process that makes the PUT token request first can still access metadata. The protection is specifically against redirect-based SSRF and container escape paths.

**Readiness gate:** `null_resource.dlpod_ready` uses `ssm:SendCommand` on the Guardrails instance to `curl -sk https://<dlpod_ip>/` and waits for a TCP/TLS response (any HTTP status). It uses Guardrails as a proxy because DLPoD is in the private subnet and Terraform runs outside the VPC — direct connectivity is not available. Guardrails is used (rather than the bastion) because its readiness is already confirmed at this point.

---

## AIG Validation of DLPoD

When the AIG enrolls and processes its bootstrap secret, it validates the DLPoD connection as follows:

1. **Parse** `dlp.host` from the bootstrap secret → `https://dlp.aigw.internal`
2. **Resolve** `dlp.aigw.internal` via VPC DNS → Route 53 private zone → `10.0.2.20`
3. **Connect** to `10.0.2.20:443` via TCP
4. **TLS handshake:** AIG presents no client cert; DLPoD presents its server cert chain
5. **Certificate verification:** AIG uses `dlp.certificate` (the CA cert PEM) as the trust anchor
   - Verifies the server cert is signed by the CA
   - Verifies the cert's DNS SAN includes `dlp.aigw.internal` (the hostname from the URL)
   - Verifies validity period
6. **Probe request:** AIG sends a POST to `https://dlp.aigw.internal/inspections/jobs`
7. **Success:** DLPoD responds → AIG marks the DLP service as configured

**Why the hostname matters:** The AIG is written in Go. Go's `crypto/tls` package verifies TLS certificates by extracting the host from the connection URL and checking it against the cert's SANs. When the host is a bare IP address (e.g. `https://10.0.2.20`), the AIG's URL parsing returns an empty hostname string for verification, causing the error:

```
x509: certificate is valid for dlp.aigw.internal, not
```

This occurs even though the cert has a valid IP SAN (`IP Address:10.0.2.20`). Using `https://dlp.aigw.internal` as the host causes Go to correctly verify against the DNS SAN, which succeeds.

---

## CI/CD Integration

### State Management

```hcl
# backend.hcl — do not commit
bucket         = "your-tfstate-bucket"
key            = "ai-services/new-vpc-public/terraform.tfstate"
region         = "us-west-1"
encrypt        = true
kms_key_id     = "arn:aws:kms:..."
dynamodb_table = "terraform-state-lock"
```

### Pipeline Credentials

The pipeline needs:
- AWS credentials with EC2, VPC, IAM, Secrets Manager, SSM, Route53, CloudWatch permissions
- `NETSKOPE_SERVER_URL` and `NETSKOPE_API_KEY` as pipeline secrets

### Replacing Appliances

Terraform `taint` (or `-replace` flag in Terraform >= 1.5) is the mechanism for forcing appliance replacement. See the troubleshooting guide for exact commands.

The readiness gates (`null_resource.guardrails_ready`, `null_resource.dlpod_ready`) only re-run when their `triggers` change (the instance ID). Tainting only the AIG does not re-run the gates — it assumes Guardrails and DLPoD are still healthy.

### Sensitive Values in State

The Terraform state file contains:
- DLPoD TLS private keys (`tls_private_key.dlpod`, `tls_private_key.dlpod_ca`)
- The AIG enrollment token
- The DLPoD license key

Protect the state file with S3 SSE-KMS and restrict state bucket access to the pipeline role only.
