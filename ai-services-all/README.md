# Netskope AI Services — Combined Stack

Deploy the **AI Gateway (AIG)**, **AI Guardrails**, and **DLP On-Demand (DLPoD)** together in a single `terraform apply`. **This is the recommended way to deploy the full stack for a POV** — one state file, readiness gates between components, and the Route 53 / TLS wiring between the AIG and DLPoD handled for you.

If the combined stack is not wanted and the customer prefers to deploy one component at a time, use the standalone templates in the order described in [`STAGED-BUILD.md`](../STAGED-BUILD.md).

## Available templates

| Option | Directory | Best for |
|--------|-----------|---------|
| [New VPC — public AIG](new-vpc-public/README.md) | `new-vpc-public/` | Full stack in a fresh AWS environment; AIG with public Elastic IP |

## Deploying one component at a time instead

If the combined stack is not wanted and the customer prefers to install Guardrails, DLPoD and the AIG as three separate Terraform runs, follow [`STAGED-BUILD.md`](../STAGED-BUILD.md) at the repository root. It explains why the order is fixed and maps every output to the input that consumes it.

## Reference

- [Full-stack deployment guide](new-vpc-public/README.md)
- [Troubleshooting guide](new-vpc-public/docs/troubleshooting.md)
- [DevOps reference](new-vpc-public/docs/devops.md)
- [Remote state](new-vpc-public/docs/deployment.md)
