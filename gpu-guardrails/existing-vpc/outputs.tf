output "instance_id" {
  description = "EC2 instance ID of the Guardrails GPU host"
  value       = aws_instance.guardrails.id
}

output "private_ip" {
  description = "Private IP of the Guardrails GPU host"
  value       = aws_instance.guardrails.private_ip
}

output "ai_guardrails_host" {
  description = "Host URL to enter in the AIGW CLI when registering the Guardrails service (Settings > Security Cloud Platform > Gateway Setup). Must end with /invocations."
  value       = "http://${aws_instance.guardrails.private_ip}:8080/invocations"
}

output "health_check_url" {
  description = "Guardrails health check endpoint. Returns {\"status\":\"Healthy\"} when ready."
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
