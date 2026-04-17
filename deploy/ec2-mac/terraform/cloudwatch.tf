# ==============================================================================
# CloudWatch Alarms + Log Group + SNS Paging Topic
# ==============================================================================
#
# EC2 Mac Dedicated Hosts are the most expensive compute on AWS ($1+/hour
# baseline, 24-hour minimum allocation). Silent failure modes — a wedged
# daemon, a TLS cert rolling past expiry, an ASG that failed to reach
# desired capacity — cost thousands in idle billing. These alarms paint
# a picture of "is the fleet earning its keep?" across three axes:
#
#   (a) Waste     — HostUtilizationLow detects hosts burning money idle.
#   (b) Failure   — API/VM/Audit errors detect the fleet losing requests.
#   (c) Readiness — TLS + ASG + lifecycle alarms detect configuration rot.
#
# Every alarm publishes to a single SNS topic; wire it into PagerDuty /
# Opsgenie / email externally. The topic is tenant-neutral on purpose —
# on-call isn't Spooktacular's concern; we hand off to your existing
# incident tooling.
# ==============================================================================

# ------------------------------------------------------------------------------
# Log group for aggregated structured logs from the fleet
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "spooktacular" {
  name              = "/aws/ec2-mac/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn # null => uses the AWS-managed CloudWatch KMS key

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-logs"
  })
}

# ------------------------------------------------------------------------------
# SNS topic for alerts
# ------------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.sns_kms_key_arn # null => uses aws/sns

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-alerts"
  })
}

output "alerts_sns_topic_arn" {
  description = "SNS topic ARN — subscribe PagerDuty / Opsgenie / email to this ARN."
  value       = aws_sns_topic.alerts.arn
}

# ------------------------------------------------------------------------------
# Alarm: HostUtilizationHigh — paged if a host is saturated for 15m
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "host_utilization_high" {
  alarm_name          = "${var.name_prefix}-host-utilization-high"
  alarm_description   = "EC2 Mac host CPU > 80% for 15m. Likely runaway workload or insufficient fleet capacity."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  period              = 300
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.mac.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Alarm: HostUtilizationLow — waste signal after 6h idle
# ------------------------------------------------------------------------------
#
# 24h minimum billing means 6h idle = 25% of a paid allocation wasted. If
# utilization stays below 5% for six hours, the host is almost certainly
# drainable and should be released at the 24h mark.

resource "aws_cloudwatch_metric_alarm" "host_utilization_low" {
  alarm_name          = "${var.name_prefix}-host-utilization-low"
  alarm_description   = "EC2 Mac host CPU < 5% for 6h. Candidate for drain + release at next 24h boundary."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 72 # 72 × 5m = 6 hours
  datapoints_to_alarm = 72
  threshold           = 5
  period              = 300
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.mac.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, {
    Severity = "ticket"
  })
}

# ------------------------------------------------------------------------------
# Alarm: SpooktacularAPIErrors — custom metric published by spook serve
# ------------------------------------------------------------------------------
#
# `spook serve` PutMetricData's `Spooktacular/APIErrors` as a 1-per-4xx-or-5xx
# counter (namespace "Spooktacular", see EC2_MAC_DEPLOYMENT §1 IAM). A burst
# above 5/min for 5 consecutive minutes is worth paging.

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "${var.name_prefix}-api-errors"
  alarm_description   = "Spooktacular API errors > 5/min for 5m. Check /health and audit log."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 5
  period              = 60
  namespace           = "Spooktacular"
  metric_name         = "APIErrors"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Host = aws_instance.mac.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Alarm: VMCreationFailureRate — math expression
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "vm_creation_failure_rate" {
  alarm_name          = "${var.name_prefix}-vm-creation-failure-rate"
  alarm_description   = "VM creation failure rate > 10% over 15m. Disk pressure, stale base VM, or IPSW drift."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 10
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "rate"
    expression  = "100 * (m_fail / MAX([m_total, 1]))"
    label       = "VM creation failure %"
    return_data = true
  }

  metric_query {
    id = "m_fail"
    metric {
      namespace   = "Spooktacular"
      metric_name = "VMCreateFailures"
      period      = 300
      stat        = "Sum"
      dimensions = {
        Host = aws_instance.mac.id
      }
    }
  }

  metric_query {
    id = "m_total"
    metric {
      namespace   = "Spooktacular"
      metric_name = "VMCreateAttempts"
      period      = 300
      stat        = "Sum"
      dimensions = {
        Host = aws_instance.mac.id
      }
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Alarm: AuditExportFailure — any WORM S3 write failure in a 1h window
# ------------------------------------------------------------------------------
#
# Audit export failures are SOC 2 ship-blockers: a single unreported event
# breaks the Merkle chain for that window. Page on any non-zero value.

resource "aws_cloudwatch_metric_alarm" "audit_export_failure" {
  alarm_name          = "${var.name_prefix}-audit-export-failure"
  alarm_description   = "Spooktacular audit export to S3 Object Lock failed. SOC 2 ship-blocker."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 3600
  namespace           = "Spooktacular"
  metric_name         = "AuditExportFailures"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Host = aws_instance.mac.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, {
    Severity = "page"
  })
}

# ------------------------------------------------------------------------------
# Alarm: TLSCertExpiry — published by spook serve as DaysUntilExpiry
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "tls_cert_expiry" {
  alarm_name          = "${var.name_prefix}-tls-cert-expiry"
  alarm_description   = "Spooktacular TLS cert expires in < 14 days. Rotate before it lapses."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 14
  period              = 3600
  namespace           = "Spooktacular"
  metric_name         = "TLSCertDaysUntilExpiry"
  statistic           = "Minimum"
  treat_missing_data  = "breaching" # missing data means the metric emitter is down — also worth paging

  dimensions = {
    Host = aws_instance.mac.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Alarm: ASGCapacityUnreached — desired != in-service for 30m
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "asg_capacity_unreached" {
  count = var.enable_asg ? 1 : 0

  alarm_name          = "${var.name_prefix}-asg-capacity-unreached"
  alarm_description   = "ASG desired capacity ≠ in-service for 30m. Dedicated host allocation may be blocked."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 6 # 6 × 5m = 30m
  datapoints_to_alarm = 6
  threshold           = 0
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "gap"
    expression  = "m_desired - m_in_service"
    label       = "Capacity gap"
    return_data = true
  }

  metric_query {
    id = "m_desired"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupDesiredCapacity"
      period      = 300
      stat        = "Average"
      dimensions = {
        AutoScalingGroupName = aws_autoscaling_group.mac[0].name
      }
    }
  }

  metric_query {
    id = "m_in_service"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      period      = 300
      stat        = "Average"
      dimensions = {
        AutoScalingGroupName = aws_autoscaling_group.mac[0].name
      }
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = var.tags
}
