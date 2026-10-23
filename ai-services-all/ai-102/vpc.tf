# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.appliance_name}-vpc" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────
#
# Public subnet  : AIG appliance (receives an Elastic IP) and NAT Gateway.
#                  The AIG is internet-accessible on port 443.
# Private subnet : Guardrails GPU instance and DLPoD appliance. No public IP,
#                  no inbound from internet. Outbound routes through the NAT GW.

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "${var.appliance_name}-public" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "${local.guardrails_prefix}-private" }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.appliance_name}-igw" }
}

# ── AIG Elastic IP ────────────────────────────────────────────────────────────
#
# Allocated before the EC2 instance so its public IP is known at plan time.
# The Netskope appliance registration uses this address as the host field.

resource "aws_eip" "aig" {
  domain = "vpc"

  tags = { Name = "${var.appliance_name}-eip" }
}

# ── NAT Gateway — outbound internet for the private subnet ────────────────────
#
# Guardrails and DLPoD have no public IPs. They use this NAT Gateway to reach
# the internet (NVIDIA drivers, Docker, Netskope licensing) during first boot.

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.this]

  tags = { Name = "${local.guardrails_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = { Name = "${local.guardrails_prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.appliance_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${local.guardrails_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── VPC Endpoints ─────────────────────────────────────────────────────────────
#
# S3 gateway endpoint (free) keeps Guardrails image download traffic off the
# NAT Gateway. Interface endpoints keep SSM and CloudWatch Logs traffic on
# the AWS backbone so the Guardrails instance is manageable via SSM Session
# Manager without requiring internet access.

resource "aws_security_group" "endpoints" {
  name        = "${local.guardrails_prefix}-endpoints-sg"
  description = "Allows HTTPS from within the VPC to interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
    description = "HTTPS from VPC"
  }

  tags = { Name = "${local.guardrails_prefix}-endpoints-sg" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.guardrails_prefix}-s3-endpoint" }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.guardrails_prefix}-ssm-endpoint" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.guardrails_prefix}-ssmmessages-endpoint" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.guardrails_prefix}-ec2messages-endpoint" }
}

resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.guardrails_prefix}-logs-endpoint" }
}

# ── Route 53 — private hosted zone for DLPoD hostname resolution ─────────────
#
# The AIG validates DLP TLS against the hostname in dlp.host. A bare-IP URL
# (https://10.0.2.20) causes Go's TLS stack to verify against an empty string
# rather than the IP SAN, producing:
#   x509: certificate is valid for dlp.aigw.internal, not
# A private hosted zone resolves var.dlpod_hostname to the DLPoD private IP
# so the AIG connects by name and the DNS SAN matches correctly.

resource "aws_route53_zone" "dlpod" {
  name = local.dlpod_dns_zone

  vpc {
    vpc_id = aws_vpc.this.id
  }

  tags = { Name = "${local.guardrails_prefix}-${local.dlpod_dns_zone}" }
}

resource "aws_route53_record" "dlpod" {
  zone_id = aws_route53_zone.dlpod.zone_id
  name    = var.dlpod_hostname
  type    = "A"
  ttl     = 60
  records = [var.dlpod_private_ip]
}
