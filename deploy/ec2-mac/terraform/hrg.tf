# ==============================================================================
# Host Resource Group Tagging
# ==============================================================================
#
# The HRG itself is created in `license_manager.tf` when
# `enable_license_manager = true`. This file handles the tag on the
# manually-provisioned Dedicated Host in `main.tf` so it can be
# discovered by the HRG's tag-based resource query.
#
# If you're using the ASG-driven path (enable_asg = true), the ASG's
# launch template references the HRG directly and this tagging step is
# unnecessary.
# ==============================================================================

resource "aws_ec2_tag" "hrg_association" {
  count = var.enable_license_manager ? 1 : 0

  resource_id = aws_ec2_host.mac.id
  key         = "HostResourceGroup"
  value       = var.name_prefix
}
