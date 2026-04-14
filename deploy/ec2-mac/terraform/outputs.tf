# ==============================================================================
# Outputs
# ==============================================================================

output "host_id" {
  description = "Dedicated Host ID. Remember: 24-hour minimum allocation. Release with: aws ec2 release-hosts --host-ids <id>"
  value       = aws_ec2_host.mac.id
}

output "instance_id" {
  description = "EC2 Mac instance ID."
  value       = aws_instance.mac.id
}

output "public_ip" {
  description = "Public IP of the EC2 Mac instance (empty if in a private subnet)."
  value       = aws_instance.mac.public_ip
}

output "private_ip" {
  description = "Private IP of the EC2 Mac instance."
  value       = aws_instance.mac.private_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance."
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${coalesce(aws_instance.mac.public_ip, aws_instance.mac.private_ip)}"
}

output "api_endpoint" {
  description = "Spooktacular API endpoint (TLS). Use this when configuring the K8s controller."
  value       = "https://${coalesce(aws_instance.mac.public_ip, aws_instance.mac.private_ip)}:8484"
}

output "ssm_session_command" {
  description = "Start an SSM Session Manager session (no SSH key needed)."
  value       = "aws ssm start-session --target ${aws_instance.mac.id}"
}

output "macos_ami_id" {
  description = "The macOS AMI ID that was selected."
  value       = data.aws_ami.macos.id
}
