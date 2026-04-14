# ==============================================================================
# Provider Requirements
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to store state remotely (recommended for team use):
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "spooktacular/ec2-mac/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  # Set the region via:
  #   - The AWS_REGION environment variable
  #   - The region field below
  #   - Or terraform.tfvars
  #
  # region = "us-east-1"

  default_tags {
    tags = {
      Project   = "Spooktacular"
      ManagedBy = "Terraform"
    }
  }
}
