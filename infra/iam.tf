# Execution roles for the two functions. Inline policies only (spec REQ-18).

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    sid     = "AllowLambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "report" {
  name               = local.report_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "report" {
  statement {
    sid       = "WriteLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.report.arn}:*"]
  }

  # The handler writes via TransactWriteItems (one Update per rate-limit
  # counter, one Put for the report), which is authorised per item as
  # PutItem/UpdateItem.
  statement {
    sid       = "WriteReports"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.reports.arn]
  }
}

resource "aws_iam_role_policy" "report" {
  name   = "${local.report_name}-inline"
  role   = aws_iam_role.report.id
  policy = data.aws_iam_policy_document.report.json
}

resource "aws_iam_role" "aggregate" {
  name               = local.aggregate_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# No KMS permissions: the bucket is SSE-S3. No cloudwatch:PutMetricData: the
# heartbeat is an EMF log line.
data "aws_iam_policy_document" "aggregate" {
  statement {
    sid       = "WriteLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.aggregate.arn}:*"]
  }

  statement {
    sid       = "QueryReports"
    effect    = "Allow"
    actions   = ["dynamodb:Query"]
    resources = [aws_dynamodb_table.reports.arn]
  }

  statement {
    sid       = "ReadWriteBlocklist"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.blocklist.arn}/v1/blocklist.json"]
  }

  # Lets a missing object return NoSuchKey rather than AccessDenied on the first run.
  statement {
    sid       = "ListBlocklistBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.blocklist.arn]
  }
}

resource "aws_iam_role_policy" "aggregate" {
  name   = "${local.aggregate_name}-inline"
  role   = aws_iam_role.aggregate.id
  policy = data.aws_iam_policy_document.aggregate.json
}
