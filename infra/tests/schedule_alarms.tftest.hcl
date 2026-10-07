# Offline tests for schedule.tf, alarms.tf and the alarm_email variable (#8).
#
# Run from infra/ with `terraform test`. Every run block uses `command = plan`
# against a mocked aws provider: no AWS credentials, no network calls to AWS
# and nothing is ever applied. The overrides below are fake placeholders
# (AWS documentation account id, `.example` names), not real endpoints or
# secrets. The only email address used is on the reserved example.com domain.

mock_provider "aws" {
  override_resource {
    target          = aws_lambda_function.aggregate
    override_during = plan
    values = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:sheket-aggregate"
    }
  }

  override_resource {
    target          = aws_cloudwatch_event_rule.aggregate
    override_during = plan
    values = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/sheket-aggregate"
    }
  }

  override_resource {
    target          = aws_sns_topic.alarms
    override_during = plan
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:sheket-alarms"
    }
  }

  # The mocked aws_iam_policy_document.json is a random string, which
  # aws_iam_role and aws_iam_role_policy reject as invalid JSON. Every test
  # file plans the whole module, so these placeholders are needed here too.
  override_data {
    target = data.aws_iam_policy_document.lambda_assume
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.report
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.aggregate
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# The layer zip only exists after build_layer.sh has run.
override_data {
  target = data.archive_file.layer
  values = {
    output_path         = "build/layer.zip"
    output_base64sha256 = "bGF5ZXItdGVzdA=="
  }
}

variables {
  alarm_topic_arn = "arn:aws:sns:us-east-1:123456789012:sheket-alarms"
}

run "schedule_runs_aggregate_every_15_minutes" {
  command = plan

  assert {
    condition     = aws_cloudwatch_event_rule.aggregate.schedule_expression == "rate(15 minutes)"
    error_message = "The aggregate schedule must be rate(15 minutes) (spec §5, AC-1)."
  }

  assert {
    condition     = aws_cloudwatch_event_rule.aggregate.name == "sheket-aggregate"
    error_message = "The rule must be named after the aggregate function."
  }

  # The mocked provider leaves `state` unset (null) at plan time; the AWS
  # default is ENABLED. Fail if anyone sets it to DISABLED.
  assert {
    condition     = coalesce(aws_cloudwatch_event_rule.aggregate.state, "ENABLED") == "ENABLED"
    error_message = "The schedule must be enabled."
  }

  # The deprecated `is_enabled` can still disable the rule independently of
  # `state`. It is optional and not computed, so it is null when unset.
  assert {
    condition     = aws_cloudwatch_event_rule.aggregate.is_enabled != false
    error_message = "The schedule must not be disabled through the deprecated is_enabled."
  }

  assert {
    condition     = aws_cloudwatch_event_target.aggregate.rule == aws_cloudwatch_event_rule.aggregate.name
    error_message = "The target must be attached to the aggregate rule."
  }

  assert {
    condition     = aws_cloudwatch_event_target.aggregate.arn == "arn:aws:lambda:us-east-1:123456789012:function:sheket-aggregate"
    error_message = "The target must point at the aggregate Lambda."
  }

  assert {
    condition     = aws_cloudwatch_event_target.aggregate.role_arn == null
    error_message = "A Lambda target authorises through the resource policy; no role (AC-5)."
  }

  assert {
    condition     = aws_cloudwatch_event_target.aggregate.input == null && aws_cloudwatch_event_target.aggregate.input_path == null
    error_message = "The handler ignores the event; no input is expected."
  }
}

run "schedule_permission_is_scoped_to_the_rule" {
  command = plan

  assert {
    condition     = aws_lambda_permission.aggregate_schedule.action == "lambda:InvokeFunction"
    error_message = "EventBridge needs lambda:InvokeFunction."
  }

  assert {
    condition     = aws_lambda_permission.aggregate_schedule.principal == "events.amazonaws.com"
    error_message = "Only EventBridge may invoke the aggregate Lambda through this permission."
  }

  assert {
    condition     = aws_lambda_permission.aggregate_schedule.function_name == "sheket-aggregate"
    error_message = "The permission must be on the aggregate function."
  }

  assert {
    condition     = aws_lambda_permission.aggregate_schedule.source_arn == "arn:aws:events:us-east-1:123456789012:rule/sheket-aggregate"
    error_message = "The permission must be scoped to the schedule rule ARN."
  }
}

run "exactly_five_alarms_and_no_new_iam_roles" {
  command = plan

  # Plan-time state can't be enumerated by type, so count the declarations in
  # the module source. Spec §5 lists exactly five alarms (AC-2, issue #49).
  assert {
    condition = length(regexall(
      "resource\\s+\"aws_cloudwatch_metric_alarm\"",
      join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")])
    )) == 5
    error_message = "The module must declare exactly five CloudWatch alarms (AC-2, issue #49)."
  }

  assert {
    condition = length(regexall(
      "aws_iam_",
      join("\n", [file("${path.module}/schedule.tf"), file("${path.module}/alarms.tf")])
    )) == 0
    error_message = "schedule.tf and alarms.tf must not add IAM resources (AC-5)."
  }

  # The check above only covers two files. Count role declarations across the
  # whole module so a role added anywhere else is caught too. The closing quote
  # after `aws_iam_role` stops aws_iam_role_policy from matching.
  assert {
    condition = length(regexall(
      "resource\\s+\"aws_iam_role\"",
      join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")])
    )) == 2
    error_message = "The module must declare exactly two IAM roles, report and aggregate in iam.tf (AC-5)."
  }
}

run "report_errors_alarm" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_errors.alarm_name == "sheket-report-errors" &&
      aws_cloudwatch_metric_alarm.report_errors.namespace == "AWS/Lambda" &&
      aws_cloudwatch_metric_alarm.report_errors.metric_name == "Errors" &&
      aws_cloudwatch_metric_alarm.report_errors.dimensions == tomap({ FunctionName = "sheket-report" })
    )
    error_message = "report_errors must watch AWS/Lambda Errors for the report function."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_errors.statistic == "Sum" &&
      aws_cloudwatch_metric_alarm.report_errors.period == 300 &&
      aws_cloudwatch_metric_alarm.report_errors.evaluation_periods == 1 &&
      aws_cloudwatch_metric_alarm.report_errors.threshold == 0 &&
      aws_cloudwatch_metric_alarm.report_errors.comparison_operator == "GreaterThanThreshold" &&
      aws_cloudwatch_metric_alarm.report_errors.treat_missing_data == "notBreaching"
    )
    error_message = "report_errors must fire on any error (Sum > 0 over 5 minutes), missing data not breaching."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_errors.alarm_actions == toset([var.alarm_topic_arn]) &&
      aws_cloudwatch_metric_alarm.report_errors.ok_actions == toset([var.alarm_topic_arn])
    )
    error_message = "report_errors must notify the alarms topic on ALARM and OK."
  }
}

run "report_throttles_alarm" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_throttles.alarm_name == "sheket-report-throttles" &&
      aws_cloudwatch_metric_alarm.report_throttles.namespace == "AWS/Lambda" &&
      aws_cloudwatch_metric_alarm.report_throttles.metric_name == "Throttles" &&
      aws_cloudwatch_metric_alarm.report_throttles.dimensions == tomap({ FunctionName = "sheket-report" })
    )
    error_message = "report_throttles must watch AWS/Lambda Throttles for the report function."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_throttles.statistic == "Sum" &&
      aws_cloudwatch_metric_alarm.report_throttles.period == 300 &&
      aws_cloudwatch_metric_alarm.report_throttles.evaluation_periods == 1 &&
      aws_cloudwatch_metric_alarm.report_throttles.threshold == 0 &&
      aws_cloudwatch_metric_alarm.report_throttles.comparison_operator == "GreaterThanThreshold" &&
      aws_cloudwatch_metric_alarm.report_throttles.treat_missing_data == "notBreaching"
    )
    error_message = "report_throttles must fire on any throttle (Sum > 0 over 5 minutes), missing data not breaching."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_throttles.alarm_actions == toset([var.alarm_topic_arn]) &&
      aws_cloudwatch_metric_alarm.report_throttles.ok_actions == toset([var.alarm_topic_arn])
    )
    error_message = "report_throttles must notify the alarms topic on ALARM and OK."
  }
}

run "aggregate_errors_alarm" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.aggregate_errors.alarm_name == "sheket-aggregate-errors" &&
      aws_cloudwatch_metric_alarm.aggregate_errors.namespace == "AWS/Lambda" &&
      aws_cloudwatch_metric_alarm.aggregate_errors.metric_name == "Errors" &&
      aws_cloudwatch_metric_alarm.aggregate_errors.dimensions == tomap({ FunctionName = "sheket-aggregate" })
    )
    error_message = "aggregate_errors must watch AWS/Lambda Errors for the aggregate function."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.aggregate_errors.statistic == "Sum" &&
      aws_cloudwatch_metric_alarm.aggregate_errors.period == 900 &&
      aws_cloudwatch_metric_alarm.aggregate_errors.evaluation_periods == 1 &&
      aws_cloudwatch_metric_alarm.aggregate_errors.threshold == 0 &&
      aws_cloudwatch_metric_alarm.aggregate_errors.comparison_operator == "GreaterThanThreshold" &&
      aws_cloudwatch_metric_alarm.aggregate_errors.treat_missing_data == "notBreaching"
    )
    error_message = "aggregate_errors must fire on any error (Sum > 0 over 15 minutes), missing data not breaching."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.aggregate_errors.alarm_actions == toset([var.alarm_topic_arn]) &&
      aws_cloudwatch_metric_alarm.aggregate_errors.ok_actions == toset([var.alarm_topic_arn])
    )
    error_message = "aggregate_errors must notify the alarms topic on ALARM and OK."
  }
}

run "blocklist_stale_alarm" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.blocklist_stale.alarm_name == "sheket-aggregate-blocklist-stale" &&
      aws_cloudwatch_metric_alarm.blocklist_stale.namespace == "Sheket" &&
      aws_cloudwatch_metric_alarm.blocklist_stale.metric_name == "AggregateSucceeded" &&
      aws_cloudwatch_metric_alarm.blocklist_stale.dimensions == tomap({ Function = "aggregate" })
    )
    error_message = "blocklist_stale must watch Sheket/AggregateSucceeded with Function = aggregate (AC-3)."
  }

  # Drift guard: the alarm must match what the handler actually emits
  # (backend/src/sheket/aggregate.py, _emit_success).
  assert {
    condition = (
      regex("METRIC_NAMESPACE = \"([^\"]+)\"", file("${path.module}/../backend/src/sheket/aggregate.py"))[0] == aws_cloudwatch_metric_alarm.blocklist_stale.namespace &&
      regex("FUNCTION_NAME = \"([^\"]+)\"", file("${path.module}/../backend/src/sheket/aggregate.py"))[0] == aws_cloudwatch_metric_alarm.blocklist_stale.dimensions["Function"] &&
      strcontains(file("${path.module}/../backend/src/sheket/aggregate.py"), "{\"Name\": \"${aws_cloudwatch_metric_alarm.blocklist_stale.metric_name}\", \"Unit\": \"Count\"}") &&
      strcontains(file("${path.module}/../backend/src/sheket/aggregate.py"), "\"Dimensions\": [[\"Function\"]]")
    )
    error_message = "blocklist_stale must use the namespace, metric and dimension that _emit_success emits (AC-3)."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.blocklist_stale.statistic == "Sum" &&
      aws_cloudwatch_metric_alarm.blocklist_stale.period == 900 &&
      aws_cloudwatch_metric_alarm.blocklist_stale.evaluation_periods == 3 &&
      aws_cloudwatch_metric_alarm.blocklist_stale.datapoints_to_alarm == 3 &&
      aws_cloudwatch_metric_alarm.blocklist_stale.threshold == 1 &&
      aws_cloudwatch_metric_alarm.blocklist_stale.comparison_operator == "LessThanThreshold"
    )
    error_message = "blocklist_stale must fire when Sum < 1 for 3 of 3 15-minute periods."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.blocklist_stale.period * aws_cloudwatch_metric_alarm.blocklist_stale.evaluation_periods == 45 * 60
    error_message = "blocklist_stale must cover 45 minutes (spec §5, §7)."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.blocklist_stale.treat_missing_data == "breaching"
    error_message = "A missing heartbeat is the failure, so missing data must be breaching."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.blocklist_stale.alarm_actions == toset([var.alarm_topic_arn]) &&
      aws_cloudwatch_metric_alarm.blocklist_stale.ok_actions == toset([var.alarm_topic_arn])
    )
    error_message = "blocklist_stale must notify the alarms topic on ALARM and OK."
  }
}

run "report_read_capped_alarm" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_read_capped.alarm_name == "sheket-aggregate-report-read-capped" &&
      aws_cloudwatch_metric_alarm.report_read_capped.namespace == "Sheket" &&
      aws_cloudwatch_metric_alarm.report_read_capped.metric_name == "ReportReadCapped" &&
      aws_cloudwatch_metric_alarm.report_read_capped.dimensions == tomap({ Function = "aggregate" })
    )
    error_message = "report_read_capped must watch Sheket/ReportReadCapped with Function = aggregate (issue #49)."
  }

  # Drift guard: the alarm must match what the handler actually emits
  # (backend/src/sheket/aggregate.py, _emit_success).
  assert {
    condition = (
      regex("METRIC_NAMESPACE = \"([^\"]+)\"", file("${path.module}/../backend/src/sheket/aggregate.py"))[0] == aws_cloudwatch_metric_alarm.report_read_capped.namespace &&
      regex("FUNCTION_NAME = \"([^\"]+)\"", file("${path.module}/../backend/src/sheket/aggregate.py"))[0] == aws_cloudwatch_metric_alarm.report_read_capped.dimensions["Function"] &&
      strcontains(file("${path.module}/../backend/src/sheket/aggregate.py"), "{\"Name\": \"${aws_cloudwatch_metric_alarm.report_read_capped.metric_name}\", \"Unit\": \"Count\"}") &&
      strcontains(file("${path.module}/../backend/src/sheket/aggregate.py"), "\"${aws_cloudwatch_metric_alarm.report_read_capped.metric_name}\": 1 if capped else 0")
    )
    error_message = "report_read_capped must use the namespace, metric and dimension that _emit_success emits."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_read_capped.statistic == "Maximum" &&
      aws_cloudwatch_metric_alarm.report_read_capped.period == 900 &&
      aws_cloudwatch_metric_alarm.report_read_capped.evaluation_periods == 1 &&
      aws_cloudwatch_metric_alarm.report_read_capped.threshold == 0 &&
      aws_cloudwatch_metric_alarm.report_read_capped.comparison_operator == "GreaterThanThreshold"
    )
    error_message = "report_read_capped must fire on any capped run (Maximum > 0 over 15 minutes)."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.report_read_capped.treat_missing_data == "notBreaching"
    error_message = "A missing heartbeat is blocklist_stale's job, so missing data must not breach report_read_capped."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_read_capped.alarm_actions == toset([var.alarm_topic_arn]) &&
      aws_cloudwatch_metric_alarm.report_read_capped.ok_actions == toset([var.alarm_topic_arn])
    )
    error_message = "report_read_capped must notify the alarms topic on ALARM and OK."
  }
}

run "alarms_topic_without_email_subscription_by_default" {
  command = plan

  assert {
    condition     = aws_sns_topic.alarms.name == "sheket-alarms"
    error_message = "The alarms topic must be named <name_prefix>-alarms."
  }

  assert {
    condition     = var.alarm_email == ""
    error_message = "alarm_email must default to empty; no address is committed (AC-4)."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.alarm_email) == 0
    error_message = "No email subscription may be created when alarm_email is empty."
  }
}

run "email_subscription_created_when_alarm_email_set" {
  command = plan

  variables {
    alarm_email = "alarms@example.com"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.alarm_email) == 1
    error_message = "Setting alarm_email must create exactly one subscription."
  }

  assert {
    condition = (
      aws_sns_topic_subscription.alarm_email[0].protocol == "email" &&
      aws_sns_topic_subscription.alarm_email[0].endpoint == "alarms@example.com" &&
      aws_sns_topic_subscription.alarm_email[0].topic_arn == var.alarm_topic_arn
    )
    error_message = "The subscription must be an email subscription to the alarms topic."
  }
}

run "custom_name_prefix_flows_into_schedule_and_alarms" {
  command = plan

  variables {
    name_prefix = "dev"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.aggregate.name == "dev-aggregate" && aws_sns_topic.alarms.name == "dev-alarms"
    error_message = "name_prefix must flow into the rule and topic names."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_errors.alarm_name == "dev-report-errors" &&
      aws_cloudwatch_metric_alarm.report_throttles.alarm_name == "dev-report-throttles" &&
      aws_cloudwatch_metric_alarm.aggregate_errors.alarm_name == "dev-aggregate-errors" &&
      aws_cloudwatch_metric_alarm.blocklist_stale.alarm_name == "dev-aggregate-blocklist-stale" &&
      aws_cloudwatch_metric_alarm.report_read_capped.alarm_name == "dev-aggregate-report-read-capped"
    )
    error_message = "name_prefix must flow into every alarm name."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.report_errors.dimensions["FunctionName"] == "dev-report" &&
      aws_cloudwatch_metric_alarm.report_throttles.dimensions["FunctionName"] == "dev-report" &&
      aws_cloudwatch_metric_alarm.aggregate_errors.dimensions["FunctionName"] == "dev-aggregate"
    )
    error_message = "The Lambda alarms must follow the function names."
  }

  # The heartbeat dimension is the literal the handler emits, not the Lambda name.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.blocklist_stale.dimensions == tomap({ Function = "aggregate" }) &&
      aws_cloudwatch_metric_alarm.report_read_capped.dimensions == tomap({ Function = "aggregate" })
    )
    error_message = "The stale and read-capped alarm dimensions must stay Function = aggregate regardless of name_prefix (AC-3)."
  }
}

run "alarm_email_rejects_non_address" {
  command = plan

  variables {
    alarm_email = "not-an-email"
  }

  expect_failures = [var.alarm_email]
}

run "alarm_email_rejects_missing_domain_dot" {
  command = plan

  variables {
    alarm_email = "alarms@example"
  }

  expect_failures = [var.alarm_email]
}

run "alarm_email_rejects_whitespace" {
  command = plan

  variables {
    alarm_email = "alarms @example.com"
  }

  expect_failures = [var.alarm_email]
}

run "alarm_email_rejects_two_addresses" {
  command = plan

  variables {
    alarm_email = "a@example.com,b@example.com"
  }

  expect_failures = [var.alarm_email]
}
