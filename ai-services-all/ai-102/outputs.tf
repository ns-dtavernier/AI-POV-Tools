# ── AIG outputs ───────────────────────────────────────────────────────────────

output "appliance_id" {
  description = "Netskope AIG appliance UUID"
  value       = netskope_aig_appliance.this.id
}

output "aig_instance_id" {
  description = "EC2 instance ID of the AI Gateway"
  value       = aws_instance.aig.id
}

output "aig_public_ip" {
  description = "Elastic IP assigned to the AI Gateway — this is the address clients connect to on port 443"
  value       = aws_eip.aig.public_ip
}

output "bootstrap_secret_arn" {
  description = "ARN of the Secrets Manager bootstrap secret (enrollment token + AI Guardrails config)"
  value       = aws_secretsmanager_secret.aig_bootstrap.arn
}

# ── Guardrails outputs ────────────────────────────────────────────────────────

output "ai_guardrails_host" {
  description = "Guardrails host URL embedded in the AIG bootstrap secret. The AIG routes LLM inspection requests here."
  value       = "http://${var.guardrails_private_ip}:8080/invocations"
}

output "guardrails_instance_id" {
  description = "EC2 instance ID of the Guardrails GPU host"
  value       = aws_instance.guardrails.id
}

output "guardrails_private_ip" {
  description = "Private IP of the Guardrails GPU instance (no public IP — manage via SSM Session Manager)"
  value       = aws_instance.guardrails.private_ip
}

output "guardrails_health_check_url" {
  description = "Guardrails health check endpoint (VPC-internal only). Returns {\"status\":\"Healthy\"} when ready."
  value       = "http://${var.guardrails_private_ip}:8080/ping"
}

output "guardrails_ssm_connect_command" {
  description = "AWS CLI command to connect to the Guardrails instance via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.guardrails.id} --region ${var.aws_region}"
}

output "guardrails_log_group_name" {
  description = "CloudWatch log group for Guardrails service logs"
  value       = aws_cloudwatch_log_group.guardrails.name
}

# ── Shared VPC outputs ────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the new VPC"
  value       = aws_vpc.this.id
}

output "nat_gateway_ip" {
  description = "Elastic IP of the NAT Gateway — used by the Guardrails instance for outbound traffic at boot"
  value       = aws_eip.nat.public_ip
}

# ── DLPoD outputs ─────────────────────────────────────────────────────────────

output "dlpod_instance_id" {
  description = "EC2 instance ID of the DLPoD appliance"
  value       = aws_instance.dlpod.id
}

output "dlpod_private_ip" {
  description = "Private IP of the DLPoD appliance (no public IP — private subnet only)"
  value       = aws_instance.dlpod.private_ip
}

output "dlp_host" {
  description = "DLP host URL configured in the AIG bootstrap secret — the AIG forwards DLP inspection traffic here"
  value       = "https://${var.dlpod_hostname}"
}
