# ==============================================================================
# Host Resource Group Support
# ==============================================================================
#
# AWS Host Resource Groups (via License Manager) enable automatic Dedicated
# Host management. When configured, AWS allocates and releases hosts based on
# demand -- eliminating idle host charges and simplifying fleet scaling.
#
# Usage:
#   1. Create a License Configuration in AWS License Manager
#   2. Create a Host Resource Group referencing the license configuration
#   3. Pass the HRG ARN via terraform.tfvars:
#        host_resource_group_arn = "arn:aws:resource-groups:us-east-1:123456789012:group/my-mac-hrg"
#
# When host_resource_group_arn is set, the Dedicated Host is associated with
# the group for automatic placement. When null (default), the host is managed
# manually as before.
#
# See: https://docs.aws.amazon.com/license-manager/latest/userguide/host-resource-groups.html
# ==============================================================================

variable "host_resource_group_arn" {
  description = "ARN of the Host Resource Group for automatic host placement. When set, the Dedicated Host is associated with the group for demand-based allocation and release. Optional."
  type        = string
  default     = null
}

# When a Host Resource Group ARN is provided, tag the Dedicated Host so it
# can be discovered by the group's resource query. The actual association
# happens in License Manager via the host_resource_group_arn attribute on
# the dedicated host.
resource "aws_ec2_tag" "hrg_association" {
  count = var.host_resource_group_arn != null ? 1 : 0

  resource_id = aws_ec2_host.mac.id
  key         = "HostResourceGroup"
  value       = var.host_resource_group_arn
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "host_resource_group_arn" {
  description = "Host Resource Group ARN (null if not configured)."
  value       = var.host_resource_group_arn
}
