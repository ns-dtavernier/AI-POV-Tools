# Layer 1 — Terraform native tests for dlpod/new-vpc-private
#
# These tests use mock_provider so no AWS credentials are required.
# Mock providers assign predictable values to computed attributes (like resource
# IDs) during apply. Blocks using `command = plan` test values known at plan
# time. Remaining blocks default to `command = apply` so cross-resource ID
# references are resolved before assertions.
#
# Run from this directory:
#   terraform test

mock_provider "aws" {}

variables {
  # Required bootstrap variables — use safe placeholder values for tests.
  persona     = "dlp-on-demand"
  dlpod_licensekey  = "TEST-LICENSE-KEY"
  dns_primary = "10.0.0.2"

  appliance_name = "dlpod-test"

  # Pin network values to defaults so tests are independent of terraform.tfvars.
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.0.0/24"
  private_subnet_cidr = "10.0.1.0/24"
  dlpod_private_ip    = "10.0.1.10"
}

# ── Plan-time checks (user-specified arguments — known before apply) ──────────

run "vpc_cidr" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "VPC CIDR block must be 10.0.0.0/16 (default)"
  }
}

run "vpc_dns" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support == true
    error_message = "VPC must have DNS support enabled (required for Netskope endpoints)"
  }

  assert {
    condition     = aws_vpc.this.enable_dns_hostnames == true
    error_message = "VPC must have DNS hostnames enabled"
  }
}

run "public_subnet_cidr" {
  command = plan

  assert {
    condition     = aws_subnet.public.cidr_block == "10.0.0.0/24"
    error_message = "Public subnet CIDR must be 10.0.0.0/24 (default)"
  }
}

run "private_subnet_cidr" {
  command = plan

  assert {
    condition     = aws_subnet.private.cidr_block == "10.0.1.0/24"
    error_message = "Private subnet CIDR must be 10.0.1.0/24 (default)"
  }
}

# ── Apply-time checks (cross-resource references — IDs are computed) ──────────

run "nat_in_public_subnet" {
  assert {
    condition     = aws_nat_gateway.this.subnet_id == aws_subnet.public.id
    error_message = "NAT Gateway must be placed in the public subnet"
  }
}

run "public_route_via_igw" {
  assert {
    condition = length([
      for r in aws_route_table.public.route :
      r if r.cidr_block == "0.0.0.0/0" && r.gateway_id != ""
    ]) > 0
    error_message = "Public route table must route 0.0.0.0/0 via an Internet Gateway"
  }
}

run "private_route_via_nat" {
  assert {
    condition = length([
      for r in aws_route_table.private.route :
      r if r.cidr_block == "0.0.0.0/0" && r.nat_gateway_id != ""
    ]) > 0
    error_message = "Private route table must route 0.0.0.0/0 via NAT Gateway"
  }
}

run "ec2_in_private_subnet" {
  assert {
    condition     = aws_instance.dlpod.subnet_id == aws_subnet.private.id
    error_message = "DLPoD EC2 instance must be placed in the private subnet"
  }
}

run "ec2_fixed_ip" {
  assert {
    condition     = aws_instance.dlpod.private_ip == "10.0.1.10"
    error_message = "DLPoD EC2 instance must use the fixed private IP 10.0.1.10 (default dlpod_private_ip)"
  }
}

run "imdsv2_required" {
  assert {
    condition     = aws_instance.dlpod.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required on the DLPoD instance (ZTP security design §7.5)"
  }
}

run "user_data_contains_persona" {
  assert {
    condition     = strcontains(aws_instance.dlpod.user_data, "dlp-on-demand")
    error_message = "EC2 user_data must contain the persona value — nsbootstrap reads bootstrap.json from raw user-data"
  }
}

run "user_data_contains_dns" {
  assert {
    condition     = strcontains(aws_instance.dlpod.user_data, "10.0.0.2")
    error_message = "EC2 user_data must contain the primary DNS address"
  }
}

run "security_group_ingress" {
  assert {
    condition     = length(aws_security_group.dlpod.ingress) == 1
    error_message = "DLPoD security group must have exactly 1 ingress rule (TCP 443)"
  }
}
