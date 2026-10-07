# Single source for the function, log group and role names.
locals {
  report_name    = "${var.name_prefix}-report"
  aggregate_name = "${var.name_prefix}-aggregate"
}

# Function code: the sheket package plus the two contract files the aggregate
# handler loads from Path(__file__).parent / "contract" (CONTRACT_DIR in
# backend/src/sheket/aggregate.py). The contract files are read from ../contract
# at plan time and never copied into the repository (spec REQ-20).
data "archive_file" "code" {
  type        = "zip"
  output_path = "${path.module}/build/code.zip"

  dynamic "source" {
    for_each = fileset("${path.module}/../backend/src", "sheket/*.py")

    content {
      content  = file("${path.module}/../backend/src/${source.value}")
      filename = source.value
    }
  }

  source {
    content  = file("${path.module}/../contract/curated.json")
    filename = "sheket/contract/curated.json"
  }

  source {
    content  = file("${path.module}/../contract/blocklist.schema.json")
    filename = "sheket/contract/blocklist.schema.json"
  }
}

# Run backend/scripts/build_layer.sh before `terraform plan`. The layer holds the
# backend/requirements-lock.txt dependencies; boto3 comes from the Lambda runtime.
data "archive_file" "layer" {
  type             = "zip"
  source_dir       = "${path.module}/../backend/build/layer"
  output_path      = "${path.module}/build/layer.zip"
  output_file_mode = "0644"
}

resource "aws_lambda_layer_version" "runtime" {
  layer_name               = "${var.name_prefix}-runtime"
  filename                 = data.archive_file.layer.output_path
  source_code_hash         = data.archive_file.layer.output_base64sha256
  compatible_runtimes      = ["python3.13"]
  compatible_architectures = ["arm64"]
}

# The only source of IP_HASH_SALT (no secrets in source). No keepers, so it never
# rotates silently, which would break per-network dedup.
resource "random_password" "ip_hash_salt" {
  length  = 48
  special = false
}

resource "aws_cloudwatch_log_group" "report" {
  name              = "/aws/lambda/${local.report_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "aggregate" {
  name              = "/aws/lambda/${local.aggregate_name}"
  retention_in_days = 30
}

# The report handler needs only the standard library and boto3 (from the
# runtime), so it takes no layer.
resource "aws_lambda_function" "report" {
  function_name    = local.report_name
  role             = aws_iam_role.report.arn
  handler          = "sheket.report.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256

  # Memory and timeout are provisional values from the design.
  memory_size                    = 256
  timeout                        = 5
  reserved_concurrent_executions = 10

  environment {
    variables = {
      TABLE_NAME   = aws_dynamodb_table.reports.name
      IP_HASH_SALT = random_password.ip_hash_salt.result
    }
  }

  depends_on = [aws_cloudwatch_log_group.report, aws_iam_role_policy.report]
}

resource "aws_lambda_function" "aggregate" {
  function_name    = local.aggregate_name
  role             = aws_iam_role.aggregate.arn
  handler          = "sheket.aggregate.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  layers           = [aws_lambda_layer_version.runtime.arn]

  # Sized from a local synthetic run of the read -> build -> validate path at
  # the per-run cap of 1M reports, worst shape (every report a distinct
  # sender): peak RSS 884 MB, 18 s. memory_size is the next step above 1.5x
  # the peak; timeout is READ_TIME_BUDGET + 60 s. The cap is set by
  # MAX_REPORTS_PER_RUN and READ_TIME_BUDGET in backend/src/sheket/aggregate.py:
  # if either changes, re-measure and keep timeout above READ_TIME_BUDGET plus
  # a margin.
  memory_size                    = 1536
  timeout                        = 300
  reserved_concurrent_executions = 1

  environment {
    variables = {
      TABLE_NAME   = aws_dynamodb_table.reports.name
      BUCKET_NAME  = aws_s3_bucket.blocklist.id
      MIN_INSTALLS = tostring(var.min_installs)
      MIN_NETWORKS = tostring(var.min_networks)
    }
  }

  depends_on = [aws_cloudwatch_log_group.aggregate, aws_iam_role_policy.aggregate]
}

# A failed run is not retried; the next scheduled run rebuilds from scratch.
resource "aws_lambda_function_event_invoke_config" "aggregate" {
  function_name          = aws_lambda_function.aggregate.function_name
  maximum_retry_attempts = 0
}

# Public endpoint (spec REQ-12); abuse controls live in the handler. No CORS
# block: the clients are native apps, not browsers.
resource "aws_lambda_function_url" "report" {
  function_name      = aws_lambda_function.report.function_name
  authorization_type = "NONE"
  invoke_mode        = "BUFFERED"
}

# A public function URL needs both InvokeFunctionUrl and InvokeFunction. For
# authorization_type = "NONE" the aws provider (6.67.0, as pinned) creates both
# statements itself when it creates the URL: FunctionURLAllowPublicAccess
# (InvokeFunctionUrl) and FunctionURLAllowInvokeAction (InvokeFunction, only
# when invoked via the function URL). Declaring either one again makes a fresh
# apply fail on a duplicate statement id (issue #56), so the module declares
# neither. Deployments that imported them keep the live statements; Terraform
# only forgets them from state.
removed {
  from = aws_lambda_permission.report_url

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_permission.report_url_invoke

  lifecycle {
    destroy = false
  }
}
