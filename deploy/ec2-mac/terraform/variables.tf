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
    condition     = can(regex("^mac[0-9]+\\.metal$", var.instance_type))
    error_message = "Instance type must be a mac*.metal Dedicated Host type (e.g., mac2.metal)."
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
