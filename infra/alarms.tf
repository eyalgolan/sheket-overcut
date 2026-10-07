# Alarms for spec §5: report errors, report throttles, aggregate errors, a
# blocklist older than 45 minutes and a report read capped during a flood. All
# of them notify one SNS topic. The recipient is provisional until the owner
# settles Decision 4.
resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"
}

# Only created when alarm_email is set in a gitignored *.tfvars file. AWS sends a
# confirmation email that must be accepted from the inbox after apply. Decision 4
# (who receives the alarms) is still open.
resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# Lambda Errors and Throttles publish nothing when there are no invocations, so
# missing data is notBreaching for the next three alarms.
resource "aws_cloudwatch_metric_alarm" "report_errors" {
  alarm_name          = "${local.report_name}-errors"
  alarm_description   = "The report Lambda returned errors (spec §5)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.report.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "report_throttles" {
  alarm_name          = "${local.report_name}-throttles"
  alarm_description   = "The report Lambda was throttled (spec §5)."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.report.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "aggregate_errors" {
  alarm_name          = "${local.aggregate_name}-errors"
  alarm_description   = "The aggregate Lambda returned errors (spec §5)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.aggregate.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# Uses the metric, namespace and dimension emitted by _emit_success in
# backend/src/sheket/aggregate.py (METRIC_NAMESPACE = "Sheket"). The Function
# dimension is the Lambda's AWS_LAMBDA_FUNCTION_NAME, so it follows name_prefix.
# Fires after 3 x 15 minutes = 45 minutes with no successful run. Missing data is
# breaching because a missing heartbeat is the failure.
resource "aws_cloudwatch_metric_alarm" "blocklist_stale" {
  alarm_name          = "${local.aggregate_name}-blocklist-stale"
  alarm_description   = "No successful aggregate run for 45 minutes, so the blocklist is older than 45 minutes (spec §5, §7)."
  namespace           = "Sheket"
  metric_name         = "AggregateSucceeded"
  dimensions          = { Function = aws_lambda_function.aggregate.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# Uses the ReportReadCapped flag that _emit_success emits on every successful
# run (1 when the report read hit MAX_REPORTS_PER_RUN or READ_TIME_BUDGET in
# backend/src/sheket/aggregate.py, else 0), with the same namespace and
# function-name dimension as blocklist_stale. Fires on the first capped run in a 15-minute
# period. Missing data is notBreaching: a missing heartbeat is blocklist_stale's
# job.
resource "aws_cloudwatch_metric_alarm" "report_read_capped" {
  alarm_name          = "${local.aggregate_name}-report-read-capped"
  alarm_description   = "The aggregate Lambda capped its report read during a flood, so the oldest reports were not counted (spec §5)."
  namespace           = "Sheket"
  metric_name         = "ReportReadCapped"
  dimensions          = { Function = aws_lambda_function.aggregate.function_name }
  statistic           = "Maximum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}
