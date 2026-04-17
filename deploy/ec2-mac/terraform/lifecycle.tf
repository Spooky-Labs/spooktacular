# ==============================================================================
# ASG Lifecycle Hook — drain-on-terminate
# ==============================================================================
#
# When the ASG decides to terminate an instance (scale-in, instance
# refresh, or ReplaceUnhealthy), AWS fires a lifecycle event. The hook
# below holds the instance in the `Terminating:Wait` state for up to
# `var.drain_timeout_seconds` so Spooktacular can:
#
#   1. Cordon itself (write /etc/spooktacular/drain).
#   2. Stop all running VMs gracefully.
#   3. Flush pending audit events to S3 Object Lock.
#   4. Signal CONTINUE to let the ASG proceed.
#
# The SSM automation wired below handles steps 1–4 by invoking the
# `SpooktacularInstall` document with `Action=drain` via an EventBridge
# rule, then calling `CompleteLifecycleAction` when draining finishes.
#
# See: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-autoscaling-lifecyclehook.html
# ==============================================================================

resource "aws_autoscaling_lifecycle_hook" "drain_on_terminate" {
  count = var.enable_asg ? 1 : 0

  name                   = "${var.name_prefix}-drain-on-terminate"
  autoscaling_group_name = aws_autoscaling_group.mac[0].name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = var.drain_timeout_seconds
  default_result         = "CONTINUE" # If we time out, let AWS terminate anyway.

  notification_target_arn = aws_sns_topic.lifecycle_events[0].arn
  role_arn                = aws_iam_role.lifecycle_publish[0].arn
}

# Dedicated SNS topic for lifecycle events — distinct from the alert
# topic so alert fatigue can't drown out termination signals.
resource "aws_sns_topic" "lifecycle_events" {
  count = var.enable_asg ? 1 : 0

  name              = "${var.name_prefix}-asg-lifecycle"
  kms_master_key_id = var.sns_kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-asg-lifecycle"
  })
}

# IAM role the ASG uses to publish lifecycle notifications to SNS.
resource "aws_iam_role" "lifecycle_publish" {
  count = var.enable_asg ? 1 : 0

  name_prefix = "${var.name_prefix}-lc-"
  description = "ASG uses this role to publish EC2_INSTANCE_TERMINATING events to SNS."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "autoscaling.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lifecycle_publish" {
  count = var.enable_asg ? 1 : 0

  name_prefix = "${var.name_prefix}-lc-publish-"
  role        = aws_iam_role.lifecycle_publish[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.lifecycle_events[0].arn
      }
    ]
  })
}

# ==============================================================================
# EventBridge rule — on lifecycle terminate, run the drain SSM document
# ==============================================================================
#
# Rather than polling, we subscribe to the AutoScaling lifecycle-action
# event (published by ASG) and invoke the SSM document with Action=drain
# on the specific instance. The SSM document's final step posts
# `CompleteLifecycleAction CONTINUE` back so the ASG can proceed.

resource "aws_cloudwatch_event_rule" "asg_terminating" {
  count = var.enable_asg ? 1 : 0

  name        = "${var.name_prefix}-asg-terminating"
  description = "Trigger Spooktacular drain SSM when ASG starts terminating an instance."

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-terminate Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.mac[0].name]
      LifecycleHookName    = [aws_autoscaling_lifecycle_hook.drain_on_terminate[0].name]
    }
  })

  tags = var.tags
}

# ------------------------------------------------------------------------------
# SSM Automation document — DrainSpooktacularHost
# ------------------------------------------------------------------------------
#
# EventBridge run-command targets don't accept JSONPath as an instance ID, so
# we publish a minimal Automation document that takes the event-provided
# instance ID + lifecycle token, invokes `SpooktacularInstall` with
# Action=drain on that instance, then calls CompleteLifecycleAction when the
# drain finishes. Automation is the idiomatic AWS primitive for this.

resource "aws_ssm_document" "drain_automation" {
  count = var.enable_asg ? 1 : 0

  name            = "${var.name_prefix}-drain-automation"
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Drain a Spooktacular EC2 Mac on ASG termination, then signal lifecycle complete."
    assumeRole    = aws_iam_role.automation[0].arn
    parameters = {
      InstanceId           = { type = "String" }
      LifecycleActionToken = { type = "String" }
      AutoScalingGroupName = { type = "String" }
      LifecycleHookName    = { type = "String" }
    }
    mainSteps = [
      {
        name   = "InvokeDrain"
        action = "aws:runCommand"
        inputs = {
          DocumentName = aws_ssm_document.spooktacular_install.name
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters   = { Action = ["drain"] }
          TimeoutSeconds = var.drain_timeout_seconds
        }
      },
      {
        name   = "CompleteLifecycle"
        action = "aws:executeAwsApi"
        inputs = {
          Service              = "autoscaling"
          Api                  = "CompleteLifecycleAction"
          AutoScalingGroupName = "{{ AutoScalingGroupName }}"
          LifecycleActionToken = "{{ LifecycleActionToken }}"
          LifecycleHookName    = "{{ LifecycleHookName }}"
          LifecycleActionResult = "CONTINUE"
        }
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role" "automation" {
  count = var.enable_asg ? 1 : 0

  name_prefix = "${var.name_prefix}-auto-"
  description = "Role the SSM Automation document assumes to run the drain workflow."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ssm.amazonaws.com" }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "automation_ssm" {
  count      = var.enable_asg ? 1 : 0
  role       = aws_iam_role.automation[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSSMAutomationRole"
}

resource "aws_iam_role_policy" "automation_asg" {
  count = var.enable_asg ? 1 : 0

  name_prefix = "${var.name_prefix}-auto-asg-"
  role        = aws_iam_role.automation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["autoscaling:CompleteLifecycleAction"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "drain_automation" {
  count = var.enable_asg ? 1 : 0

  rule      = aws_cloudwatch_event_rule.asg_terminating[0].name
  target_id = "drain-automation"
  arn       = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.drain_automation[0].name}:$DEFAULT"
  role_arn  = aws_iam_role.eventbridge_ssm[0].arn

  input_transformer {
    input_paths = {
      instanceId     = "$.detail.EC2InstanceId"
      asgName        = "$.detail.AutoScalingGroupName"
      hookName       = "$.detail.LifecycleHookName"
      lifecycleToken = "$.detail.LifecycleActionToken"
    }
    # Automation documents take parameters as arrays of strings
    input_template = <<EOF
{
  "InstanceId": ["<instanceId>"],
  "LifecycleActionToken": ["<lifecycleToken>"],
  "AutoScalingGroupName": ["<asgName>"],
  "LifecycleHookName": ["<hookName>"]
}
EOF
  }
}

# Role EventBridge assumes to invoke the SSM document.
resource "aws_iam_role" "eventbridge_ssm" {
  count = var.enable_asg ? 1 : 0

  name_prefix = "${var.name_prefix}-eb-"
  description = "EventBridge role to invoke the Spooktacular drain SSM document on ASG termination."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "eventbridge_ssm" {
  count = var.enable_asg ? 1 : 0

  name_prefix = "${var.name_prefix}-eb-ssm-"
  role        = aws_iam_role.eventbridge_ssm[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:StartAutomationExecution"]
        Resource = "arn:aws:ssm:*:*:automation-definition/${aws_ssm_document.drain_automation[0].name}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.automation[0].arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ssm.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Account + region helpers (used in the ARN above).
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
