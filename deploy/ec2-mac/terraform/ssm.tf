# ==============================================================================
# SSM Document: SpooktacularInstall
# ==============================================================================
#
# Registers `ssm/install-spooktacular.yaml` as an AWS Systems Manager
# document so operators can `aws ssm send-command --document-name
# SpooktacularInstall ...` across the fleet. The YAML on disk is the
# single source of truth — this resource just uploads it.
#
# See: https://docs.aws.amazon.com/systems-manager/latest/userguide/documents.html
# ==============================================================================

resource "aws_ssm_document" "spooktacular_install" {
  name            = "${var.name_prefix}-install"
  document_type   = "Command"
  document_format = "YAML"

  # Source of truth — the YAML lives next to the bootstrap script on disk
  # so operators can version-control and review the install steps directly.
  content = file("${path.module}/../ssm/install-spooktacular.yaml")

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-install"
    Purpose = "Idempotent Spooktacular bootstrap for EC2 Mac"
  })
}

# ==============================================================================
# SSM Association — apply the install document on host state change
# ==============================================================================
#
# State-manager association keeps new Mac instances (and any that drift)
# converged to the install document. We target by tag so Host Resource
# Group replacements get picked up without Terraform changes.

resource "aws_ssm_association" "spooktacular_install" {
  name             = aws_ssm_document.spooktacular_install.name
  association_name = "${var.name_prefix}-install"

  targets {
    key    = "tag:Role"
    values = ["spooktacular-host"]
  }

  # Re-run weekly as a drift-correction. The document is idempotent: the
  # fast-path in bootstrap.sh exits 0 if `spook doctor --strict` passes.
  schedule_expression = "rate(7 days)"

  parameters = {
    Action       = "install"
    Version      = var.spooktacular_version
    CreateBaseVM = "true"
    APIPort      = "8484"
    APIHost      = "0.0.0.0"
  }

  # Cap concurrency so one broken release doesn't take the whole fleet.
  max_concurrency = "25%"
  max_errors      = "10%"
}

output "ssm_document_name" {
  description = "The registered SSM document name — pass to `aws ssm send-command --document-name`."
  value       = aws_ssm_document.spooktacular_install.name
}
