---
description: Safely destroy a Netskope POV deployment
---

Remove a deployment cleanly. Destroy is irreversible — be deliberate.

1. Confirm the template directory and run `terraform state list` so the user sees what exists.
2. Explain what will be removed, including anything outside AWS: the AIG templates also delete the appliance registration and enrollment token in the Netskope tenant.
3. For staged builds, destroy in reverse order: AIG first, then the other `existing-vpc/` stage, then the `new-vpc-private/` stage that owns the VPC. Destroying the VPC owner first fails (subnets still hold instances) or, worse, leaves the AIG pointing at dead endpoints.
4. Ask for an explicit "yes" before running `terraform destroy`.
5. Run `terraform destroy`. If it hangs on VPC or subnet deletion, see the VPC-endpoint-ENI note in `ai-services-all/new-vpc-public/docs/troubleshooting.md`.
6. Afterwards remind the user:
   - Secrets Manager secrets use `recovery_window_in_days = 0`, so they are gone immediately.
   - The S3 bucket holding `aisecurity-llm.tgz` and any remote-state bucket are not managed by these templates and are not deleted.
   - Revoke the Netskope API token if it was created only for this POV.
   - Delete local `terraform.tfstate*` and `terraform.tfvars` if the directory is being shared or archived.
