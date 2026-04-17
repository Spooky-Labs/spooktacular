# ==============================================================================
# Launch Template + Auto Scaling Group — dedicated-host fleet
# ==============================================================================
#
# For steady-state workloads that span many hosts, an ASG keeps the
# fleet at target size and replaces unhealthy instances. The launch
# template references the Host Resource Group created in
# `license_manager.tf` so AWS auto-allocates hosts on demand, and the
# ASG lifecycle hook in `lifecycle.tf` gives us a clean drain window.
#
# When `var.enable_asg = false` (the default for single-host demos),
# none of these resources are created — the single-instance path in
# `main.tf` remains the canonical quickstart.
# ==============================================================================

resource "aws_launch_template" "mac" {
  count = var.enable_asg ? 1 : 0

  name_prefix   = "${var.name_prefix}-"
  description   = "Spooktacular EC2 Mac launch template — references HRG for auto-allocated hosts."
  image_id      = data.aws_ami.macos.id
  instance_type = var.instance_type
  key_name      = var.key_name

  user_data = base64encode(local.bootstrap_script)

  vpc_security_group_ids = [aws_security_group.spooktacular.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_mac.name
  }

  # Tenancy "host" + auto-placement pulls from the Host Resource Group.
  placement {
    tenancy                 = "host"
    availability_zone       = data.aws_subnet.selected.availability_zone
    host_resource_group_arn = try(aws_resourcegroups_group.mac_hrg[0].arn, null)
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      iops                  = 6000
      throughput            = 400
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.name_prefix}-asg-instance"
      Role = "spooktacular-host"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.name_prefix}-asg-volume"
    })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "mac" {
  count = var.enable_asg ? 1 : 0

  name_prefix         = "${var.name_prefix}-"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = [var.subnet_id]

  # Dedicated-host ASGs must be healthy-checked by EC2 only — ELB
  # health checks don't apply and cause spurious replacements.
  health_check_type         = "EC2"
  health_check_grace_period = 600 # 10 min — accounts for base-VM IPSW download on first boot

  launch_template {
    id      = aws_launch_template.mac[0].id
    version = "$Latest"
  }

  # Protect scale-in: picking a victim at random is cheap for stateless
  # services but wrong for dedicated hosts locked to 24h minimum billing.
  # The `scale-in-protection.tf` hook + operator CLI drives draining.
  termination_policies = ["OldestInstance"]

  # Instance refresh replaces machines safely when the launch template
  # changes. min_healthy 100% ensures no capacity gap during rollouts.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 900
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-asg"
    propagate_at_launch = false
  }

  tag {
    key                 = "Project"
    value               = "Spooktacular"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "spooktacular-host"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

output "asg_name" {
  description = "Name of the ASG (null when enable_asg=false)."
  value       = try(aws_autoscaling_group.mac[0].name, null)
}
