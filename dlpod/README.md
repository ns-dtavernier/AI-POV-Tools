# Netskope DLP On-Demand (DLPoD) — Terraform Deployment

DLP On-Demand is the Netskope appliance that inspects AI traffic for sensitive data. The AI Gateway sends content to it over TLS and acts on the verdict. These templates deploy a DLPoD appliance on AWS with a single `terraform apply`. The appliance is zero-touch provisioned: Terraform generates its TLS certificates and configuration and hands them to the instance at first boot. No console or SSH steps are needed.

> **Deploying the full stack?** Use the combined [`ai-services-all/new-vpc-public/`](../ai-services-all/new-vpc-public/README.md) template instead — it includes DLPoD and wires it to the AI Gateway for you. The templates here are for deploying DLPoD on its own, or as part of a [staged build](../STAGED-BUILD.md).

---

## Which option should I use?

```
Do you already have a VPC with a private subnet that has outbound internet access (NAT)?
├── Yes → existing-vpc/       Deploys DLPoD into your network. Also creates the private DNS
│                              zone the AI Gateway needs to reach DLPoD by hostname.
└── No  → new-vpc-private/    Creates a new VPC with DLPoD in a private subnet behind a NAT Gateway.
```

| Option | Directory | What gets created | Best for |
|--------|-----------|-------------------|----------|
| [Existing VPC](existing-vpc/README.md) | `existing-vpc/` | EC2 instance, security group, IAM role, TLS certificates, Route 53 private zone | Stage 2 of a staged build; joining a VPC that Guardrails already created |
| [New VPC — private](new-vpc-private/README.md) | `new-vpc-private/` | VPC, public + private subnets, NAT Gateway, EC2 instance, security group, IAM role, TLS certificates | DLPoD on its own in a fresh account |

DLPoD is never given a public IP. It is a back-end service that only the AI Gateway talks to.

The two templates were written at different times and differ in a few defaults — for example the instance type (`c5d.4xlarge` in `existing-vpc/`, `m5.2xlarge` in `new-vpc-private/`) and whether a private DNS zone is created (only `existing-vpc/`). Each template's README lists its own variables; trust the README in the folder you are using.

---

## Prerequisites

| Requirement | How to get it |
|-------------|---------------|
| **Terraform ≥ 1.5** | [Download](https://developer.hashicorp.com/terraform/install) or `brew install terraform` |
| **AWS CLI** signed in to the target account | `aws configure`, AWS SSO, or environment variables; check with `aws sts get-caller-identity` |
| **DLPoD AMI ID for your region** | From Netskope. Both templates carry a built-in lookup for a handful of regions (see each README); for any other region set `dlpod_ami_id` yourself |
| **DLPoD license key** | From Netskope. Set it as an environment variable: `export TF_VAR_dlpod_licensekey="…"` |

No Netskope API token is needed — these templates do not call the Netskope API. The appliance is configured entirely from the file Terraform gives it at boot.

Run `../scripts/preflight.sh dlpod/<option>` to check all of the above.

---

## What happens at first boot

1. Terraform assembles a `bootstrap.json` (persona, license key, DNS, TLS certificate) from your `terraform.tfvars` and places it in the instance's EC2 user-data.
2. The appliance's `nsbootstrap` service reads it, validates it strictly, and applies it. If anything is invalid it stops and reports rather than half-configuring.
3. The DLP service installs (`nssetupdlpaas`). This takes roughly 5–10 minutes.
4. The license key and other secrets are blanked from the record the appliance keeps on disk.

`terraform apply` returns when the instance exists, which is before step 3 completes.

### Checking it worked

The appliance has no HTTP health endpoint you can poll from outside. From a shell on the appliance (SSM or SSH) run:

```bash
cat /opt/ns/states/nsbootstrap/progress.json          # progress and status
cat /opt/ns/states/nsbootstrap/bootstrap.json.done    # what was applied (secrets blanked)
journalctl -u nsbootstrap.service                     # service log
```

From the AI Gateway side, `curl -s --cacert <ca_cert_pem> https://dlp.aigw.internal/ -w "%{http_code}"` should return `404` once the service is up (the root path is simply not mapped). Details and failure modes: [`ai-services-all/new-vpc-public/docs/troubleshooting.md`](../ai-services-all/new-vpc-public/docs/troubleshooting.md) §DLPoD.

---

## Connecting DLPoD to the AI Gateway

Both templates output the two values the AI Gateway needs:

```bash
terraform output -raw dlp_host       # e.g. https://dlp.aigw.internal
terraform output -raw ca_cert_pem    # the CA certificate, safe to paste
```

In the combined stack these are wired automatically. In a staged build you paste them into the AIG template's `terraform.tfvars` as `dlp_host` and `dlp_ca_cert_pem` — see [`STAGED-BUILD.md`](../STAGED-BUILD.md).

**Why a hostname and not an IP.** The AI Gateway verifies the DLPoD certificate against the hostname in the URL. A bare IP fails that check even though the certificate also carries the IP. `existing-vpc/` therefore creates a private Route 53 zone so `dlp.aigw.internal` resolves inside the VPC. `new-vpc-private/` does not create DNS — if you start from it and will later add an AIG, set `system_hostname` and arrange resolution yourself.

---

## Reference

- [Existing VPC guide](existing-vpc/README.md)
- [New VPC — private subnet guide](new-vpc-private/README.md)
- [`bootstrap.json` zero-touch provisioning reference](docs/ztp-bootstrap-reference.md) — the full schema, worked examples, how to deliver it on Azure / GCP / VMware, known issues
- [Troubleshooting](../ai-services-all/new-vpc-public/docs/troubleshooting.md) §DLPoD
