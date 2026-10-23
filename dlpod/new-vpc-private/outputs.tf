output "instance_id" {
  description = "EC2 instance ID of the DLPoD appliance"
  value       = aws_instance.dlpod.id
}

output "dlpod_private_ip" {
  description = "Private IP of the DLPoD instance"
  value       = aws_instance.dlpod.private_ip
}

output "nat_public_ip" {
  description = "NAT Gateway public IP (outbound traffic to Netskope cloud egresses from this address)"
  value       = aws_eip.nat.public_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "private_subnet_id" {
  description = "ID of the private subnet containing the DLPoD instance"
  value       = aws_subnet.private.id
}

output "dlp_host" {
  description = "DLP host URL for the AIG bootstrap secret dlp.host field. Set system_hostname in terraform.tfvars for hostname-based TLS (required if the AIG's Go TLS stack cannot verify IP SANs). Retrieve with: terraform output -raw dlp_host"
  value       = local.dlp_host
}

output "ca_cert_pem" {
  description = "DLPoD CA certificate in PEM format. Pass to the AIG bootstrap secret as dlp.certificate so the AIG can verify the DLPoD TLS chain. Retrieve with: terraform output -raw ca_cert_pem"
  value       = tls_self_signed_cert.dlpod_ca.cert_pem
}

# ── Network outputs for staged builds ────────────────────────────────────────

output "public_subnet_id" {
  description = "Public subnet ID (holds the NAT Gateway)"
  value       = aws_subnet.public.id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_cidr" {
  description = "Private subnet CIDR — use as allowed_service_cidr / allowed_cidr_blocks in the other existing-vpc templates"
  value       = aws_subnet.private.cidr_block
}
