# ==============================================================================
# AWS License Manager — macOS EULA + Host Resource Group
# ==============================================================================
#
# The Apple macOS EULA (§2B(iii)) permits up to 2 virtualized macOS
# instances per physical Mac you own or control. License Manager's
# "Core" counting type models this as a license inventory — one unit
# per Apple-owned machine — and a License Configuration enforces a
# ceiling on how many hosts Spooktacular can allocate without operator
# intervention.
#
# See: https://docs.aws.amazon.com/license-manager/latest/userguide/host-resource-groups.html
# ==============================================================================

resource "aws_licensemanager_license_configuration" "macos_eula" {
  count = var.enable_license_manager ? 1 : 0

  name                     = "${var.name_prefix}-macos-eula"
  description              = "Apple macOS EULA — cap on concurrently allocated mac*.metal hosts. Each unit represents one physical Mac."
  license_counting_type    = "Core"
  license_count            = var.license_count
  license_count_hard_limit = true

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-macos-eula"
    Purpose = "Apple macOS EULA enforcement"
  })
}

# ==============================================================================
# Resource Group — Host Resource Group for automatic host allocation
# ==============================================================================
#
# AWS License Manager Host Resource Groups drive demand-based Dedicated
# Host allocation: when an ASG launches an EC2 Mac instance, AWS
# allocates a host from the HRG, runs the instance, and (optionally)
# releases the host after the 24h minimum lapses and it goes unused.
#
# This resource-groups group is discoverable by tag — we tag Dedicated
# Hosts with `HostResourceGroup=<arn>` in `hrg.tf` for tag-based query.

resource "aws_resourcegroups_group" "mac_hrg" {
  count = var.enable_license_manager ? 1 : 0

  name        = "${var.name_prefix}-mac-hrg"
  description = "Host Resource Group for Spooktacular EC2 Mac Dedicated Hosts."

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::EC2::Host"]
      TagFilters = [
        {
          Key    = "Project"
          Values = ["Spooktacular"]
        },
        {
          Key    = "HostResourceGroup"
          Values = [var.name_prefix]
        },
      ]
    })
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-mac-hrg"
  })
}

output "license_configuration_arn" {
  description = "License Manager configuration ARN — attach to launch templates to enforce the Mac-host cap."
  value       = try(aws_licensemanager_license_configuration.macos_eula[0].arn, null)
}

output "host_resource_group_name" {
  description = "Host Resource Group name — pass to `aws ec2 allocate-hosts --host-resource-group-arn` for automatic allocation."
  value       = try(aws_resourcegroups_group.mac_hrg[0].name, null)
}
