output "instance_id" {
  description = "EC2 instance ID of the Guardrails GPU host"
  value       = aws_instance.guardrails.id
}

output "private_ip" {
  description = "Private IP of the Guardrails GPU host (no public IP — access via private network or VPN/TGW)"
  value       = aws_instance.guardrails.private_ip
}

output "nat_gateway_ip" {
  description = "Elastic IP of the NAT Gateway — add to any firewall allowlists for outbound traffic"
  value       = aws_eip.nat.public_ip
}

output "vpc_id" {
  description = "ID of the new VPC"
  value       = aws_vpc.this.id
}

output "ai_guardrails_host" {
  description = "Host URL to enter in the AIGW CLI when registering the Guardrails service (Settings > Security Cloud Platform > Gateway Setup). Must end with /invocations."
  value       = "http://${aws_instance.guardrails.private_ip}:8080/invocations"
}

output "health_check_url" {
  description = "Guardrails health check endpoint (private network only). Returns {\"status\":\"Healthy\"} when ready."
  value       = "http://${aws_instance.guardrails.private_ip}:8080/ping"
}

output "ssm_connect_command" {
  description = "AWS CLI command to open an SSM Session Manager session on the instance (no SSH key required)"
  value       = "aws ssm start-session --target ${aws_instance.guardrails.id} --region ${var.aws_region}"
}

output "log_group_name" {
  description = "CloudWatch log group for Guardrails service logs"
  value       = aws_cloudwatch_log_group.guardrails.name
}

# ── Network outputs for staged builds ────────────────────────────────────────
# Feed these into dlpod/existing-vpc/ and aig/existing-vpc/ when this template
# is Stage 1 of a staged build (it creates the VPC the other two deploy into).

output "private_subnet_id" {
  description = "Private subnet ID — use as subnet_id in dlpod/existing-vpc/ and aig/existing-vpc/"
  value       = aws_subnet.private.id
}

output "public_subnet_id" {
  description = "Public subnet ID (no public IPs auto-assigned; holds the NAT Gateway)"
  value       = aws_subnet.public.id
}

output "vpc_cidr" {
  description = "VPC CIDR — use as vpc_cidr in dlpod/existing-vpc/"
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_cidr" {
  description = "Private subnet CIDR — pick dlpod_private_ip from this range (avoid the first 4 and last address, which AWS reserves) and use it as allowed_inspection_cidr / allowed_cidr_blocks"
  value       = aws_subnet.private.cidr_block
}

output "availability_zone" {
  description = "AZ of the subnets — existing-vpc templates inherit it from subnet_id"
  value       = aws_subnet.private.availability_zone
}
