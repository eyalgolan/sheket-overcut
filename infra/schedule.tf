# The EventBridge rule runs the aggregate Lambda every 15 minutes (spec §5). The
# rule invokes the Lambda through the function's resource policy
# (aws_lambda_permission below), so there is no scheduler IAM role.
resource "aws_cloudwatch_event_rule" "aggregate" {
  name                = local.aggregate_name
  description         = "Runs the aggregate Lambda every 15 minutes (spec §5)."
  schedule_expression = "rate(15 minutes)"
}

# No input: the handler ignores the event. No retry policy here:
# aws_lambda_function_event_invoke_config.aggregate already sets 0 retries.
resource "aws_cloudwatch_event_target" "aggregate" {
  rule      = aws_cloudwatch_event_rule.aggregate.name
  target_id = "aggregate"
  arn       = aws_lambda_function.aggregate.arn
}

# Scoped to this rule only.
resource "aws_lambda_permission" "aggregate_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aggregate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aggregate.arn
}
