# Remote State

Terraform state for this template contains TLS private keys (the DLPoD CA and leaf certificate). Store it remotely with encryption at rest.

## S3 backend with KMS encryption

```hcl
# backend.hcl
bucket         = "my-tfstate-bucket"
key            = "ai-services/new-vpc-public/terraform.tfstate"
region         = "YOUR_REGION"
encrypt        = true
kms_key_id     = "arn:aws:kms:YOUR_REGION:123456789:key/YOUR_KEY_ID"
dynamodb_table = "terraform-state-lock"
```

```bash
terraform init -backend-config=backend.hcl
```

See the [state management guide](../../../aig/docs/state-management.md) for instructions on creating the S3 bucket and DynamoDB lock table.

## Why this matters

The `tls_private_key` resources for DLPoD are stored in `terraform.tfstate` in plaintext. Anyone with read access to the state file can extract the private key used to sign DLPoD's TLS certificate. S3 SSE-KMS encrypts the state file at rest, and IAM policies on the bucket and KMS key scope access to the deployment role.
