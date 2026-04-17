# ==============================================================================
# Input Variables
# ==============================================================================

variable "name_prefix" {
  description = "Prefix for all resource names (e.g., 'spooktacular' -> 'spooktacular-host')."
  type        = string
  default     = "spooktacular"
}

variable "instance_type" {
  description = "EC2 Mac instance type. Must be a .metal instance on a Dedicated Host."
  type        = string
  default     = "mac2.metal"

  validation {
    condition     = can(regex("^mac[0-9]+(-[a-z0-9]+)?\\.metal$", var.instance_type))
    error_message = "Instance type must be a mac*.metal Dedicated Host type (e.g., mac2.metal, mac2-m2.metal)."
  }
}

variable "subnet_id" {
  description = "Subnet ID to launch the instance in. Must be in the same AZ as the Dedicated Host."
  type        = string
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH access."
  type        = string
}

variable "macos_ami_name_filter" {
  description = "Name filter for the macOS AMI. Defaults to macOS 14 (Sonoma). Use 'amzn-ec2-macos-15*' for Sequoia."
  type        = string
  default     = "amzn-ec2-macos-14*"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. 200GB is recommended for 2 VMs (~64GB each + macOS)."
  type        = number
  default     = 200

  validation {
    condition     = var.root_volume_size_gb >= 100
    error_message = "Root volume must be at least 100GB to accommodate macOS and VM images."
  }
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access SSH (22) and the Spooktacular API (8484). Restrict to your VPN or bastion in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default = {
    Project   = "Spooktacular"
    ManagedBy = "Terraform"
  }
}

# ------------------------------------------------------------------------------
# SSM document association
# ------------------------------------------------------------------------------

variable "spooktacular_version" {
  description = "Spooktacular version to install via the SSM document. Use 'latest' for the most recent release."
  type        = string
  default     = "latest"

  validation {
    condition     = can(regex("^(latest|[0-9]+\\.[0-9]+\\.[0-9]+)$", var.spooktacular_version))
    error_message = "spooktacular_version must be 'latest' or a semver string like '1.2.0'."
  }
}

# ------------------------------------------------------------------------------
# CloudWatch / logging
# ------------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention period (days). 2555 days = 7 years, matching the audit WORM policy."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values supported by CloudWatch Logs."
  }
}

variable "log_kms_key_arn" {
  description = "KMS key ARN for CloudWatch log encryption. null => AWS-managed CloudWatch key."
  type        = string
  default     = null
}

variable "sns_kms_key_arn" {
  description = "KMS key ARN for SNS topic encryption. null => aws/sns."
  type        = string
  default     = null
}

# ------------------------------------------------------------------------------
# License Manager + Host Resource Group
# ------------------------------------------------------------------------------

variable "enable_license_manager" {
  description = "Create a License Manager License Configuration and Host Resource Group for automatic dedicated-host allocation."
  type        = bool
  default     = false
}

variable "license_count" {
  description = "License Manager license count — upper bound on concurrently allocated Mac Dedicated Hosts. Apple EULA: one unit per physical Mac you own/control."
  type        = number
  default     = 10

  validation {
    condition     = var.license_count >= 1 && var.license_count <= 10000
    error_message = "license_count must be between 1 and 10000."
  }
}

# ------------------------------------------------------------------------------
# Auto Scaling Group
# ------------------------------------------------------------------------------

variable "enable_asg" {
  description = "Provision the launch-template + ASG + lifecycle-hook set. Requires enable_license_manager=true in production."
  type        = bool
  default     = false
}

variable "asg_min_size" {
  description = "ASG min_size. Minimum dedicated hosts kept warm."
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "ASG max_size. Ceiling on dedicated hosts. Match to var.license_count."
  type        = number
  default     = 10
}

variable "asg_desired_capacity" {
  description = "ASG desired_capacity at creation. Subsequent scaling decisions come from alarms, not this value."
  type        = number
  default     = 1
}

variable "drain_timeout_seconds" {
  description = "Heartbeat timeout for the drain-on-terminate lifecycle hook. 1800 = 30 minutes, enough for a VM to finish a long CI job."
  type        = number
  default     = 1800

  validation {
    condition     = var.drain_timeout_seconds >= 300 && var.drain_timeout_seconds <= 7200
    error_message = "drain_timeout_seconds must be between 300 (5m) and 7200 (2h)."
  }
}
