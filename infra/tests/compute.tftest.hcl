# Offline tests for dynamodb.tf, iam.tf, lambda.tf, the min_installs and
# min_networks variables and the report_url output.
#
# Run from infra/ with `terraform test`. Every run block uses `command = plan`
# against a mocked aws provider: no AWS credentials, no network calls to AWS
# and nothing is ever applied. The overrides below are fake placeholders
# (AWS documentation account id, `.example` names), not real endpoints or
# secrets. The archive provider is real, so the code zip is built from the
# working tree; the layer zip is overridden so no layer build is needed.

mock_provider "aws" {
  override_resource {
    target          = aws_s3_bucket.blocklist
    override_during = plan
    values = {
      id  = "sheket-blocklist-test"
      arn = "arn:aws:s3:::sheket-blocklist-test"
    }
  }

  override_resource {
    target          = aws_dynamodb_table.reports
    override_during = plan
    values = {
      arn = "arn:aws:dynamodb:us-east-1:123456789012:table/reports"
    }
  }

  override_resource {
    target          = aws_cloudwatch_log_group.report
    override_during = plan
    values = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/sheket-report"
    }
  }

  override_resource {
    target          = aws_cloudwatch_log_group.aggregate
    override_during = plan
    values = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/sheket-aggregate"
    }
  }

  override_resource {
    target          = aws_iam_role.report
    override_during = plan
    values = {
      id  = "sheket-report"
      arn = "arn:aws:iam::123456789012:role/sheket-report"
    }
  }

  override_resource {
    target          = aws_iam_role.aggregate
    override_during = plan
    values = {
      id  = "sheket-aggregate"
      arn = "arn:aws:iam::123456789012:role/sheket-aggregate"
    }
  }

  override_resource {
    target          = aws_lambda_layer_version.runtime
    override_during = plan
    values = {
      arn = "arn:aws:lambda:us-east-1:123456789012:layer:sheket-runtime:1"
    }
  }

  override_resource {
    target          = aws_lambda_function_url.report
    override_during = plan
    values = {
      function_url = "https://report-test.lambda-url.example/"
    }
  }

  # The mocked aws_iam_policy_document.json is a random string, which
  # aws_iam_role and aws_iam_role_policy reject as invalid JSON. Give the iam.tf
  # documents a syntactically valid placeholder; tests assert on their
  # statement blocks instead.
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

override_data {
  target = data.archive_file.layer
  values = {
    output_path         = "build/layer.zip"
    output_base64sha256 = "bGF5ZXItdGVzdA=="
  }
}

override_resource {
  target          = random_password.ip_hash_salt
  override_during = plan
  values = {
    result = "test-salt-placeholder"
  }
}

run "reports_table_is_on_demand_with_ttl_pitr_and_deletion_protection" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.reports.name == "reports"
    error_message = "The table must be named \"reports\" (spec §5)."
  }

  assert {
    condition     = aws_dynamodb_table.reports.billing_mode == "PAY_PER_REQUEST"
    error_message = "The table must use on-demand (PAY_PER_REQUEST) billing (REQ-13)."
  }

  assert {
    condition     = aws_dynamodb_table.reports.hash_key == "pk" && aws_dynamodb_table.reports.range_key == "sk"
    error_message = "The key schema must be pk (HASH) / sk (RANGE), matching backend/tests/conftest.py."
  }

  assert {
    condition     = { for a in aws_dynamodb_table.reports.attribute : a.name => a.type } == { pk = "S", sk = "S" }
    error_message = "Exactly two string attributes, pk and sk, must be declared."
  }

  assert {
    condition     = one(aws_dynamodb_table.reports.ttl).attribute_name == "expires_at"
    error_message = "TTL must use the expires_at attribute (REQ-13)."
  }

  assert {
    condition     = one(aws_dynamodb_table.reports.ttl).enabled
    error_message = "TTL must be enabled (REQ-13)."
  }

  assert {
    condition     = one(aws_dynamodb_table.reports.point_in_time_recovery).enabled
    error_message = "Point-in-time recovery must be enabled."
  }

  assert {
    condition     = aws_dynamodb_table.reports.deletion_protection_enabled
    error_message = "Deletion protection must be enabled."
  }

  assert {
    condition     = length(aws_dynamodb_table.reports.global_secondary_index) == 0 && length(aws_dynamodb_table.reports.local_secondary_index) == 0
    error_message = "No secondary indexes are expected."
  }
}

run "roles_trust_only_lambda" {
  command = plan

  assert {
    condition     = aws_iam_role.report.name == "sheket-report" && aws_iam_role.aggregate.name == "sheket-aggregate"
    error_message = "Role names must be derived from name_prefix."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.lambda_assume.statement) == 1
    error_message = "The trust policy must have exactly one statement."
  }

  assert {
    condition     = data.aws_iam_policy_document.lambda_assume.statement[0].effect == "Allow"
    error_message = "The trust statement must be an Allow."
  }

  assert {
    condition     = data.aws_iam_policy_document.lambda_assume.statement[0].actions == toset(["sts:AssumeRole"])
    error_message = "The trust statement must grant only sts:AssumeRole."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.lambda_assume.statement[0].principals).type == "Service"
    error_message = "The trust principal must be a Service principal."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.lambda_assume.statement[0].principals).identifiers == toset(["lambda.amazonaws.com"])
    error_message = "Only lambda.amazonaws.com may assume the roles."
  }
}

run "report_role_has_inline_least_privilege_policy" {
  command = plan

  assert {
    condition     = aws_iam_role_policy.report.role == aws_iam_role.report.id
    error_message = "The report inline policy must be attached to the report role."
  }

  assert {
    condition     = aws_iam_role_policy.report.name == "sheket-report-inline"
    error_message = "The report inline policy name must be derived from name_prefix."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.report.statement) == 2
    error_message = "The report policy must have exactly two statements."
  }

  assert {
    condition     = alltrue([for s in data.aws_iam_policy_document.report.statement : s.effect == "Allow"])
    error_message = "Every report policy statement must be an Allow."
  }

  assert {
    condition     = data.aws_iam_policy_document.report.statement[0].actions == toset(["logs:CreateLogStream", "logs:PutLogEvents"])
    error_message = "The report role may only create log streams and put log events."
  }

  assert {
    condition     = data.aws_iam_policy_document.report.statement[0].resources == toset(["arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/sheket-report:*"])
    error_message = "The report role may only write to its own log group."
  }

  assert {
    condition     = data.aws_iam_policy_document.report.statement[1].actions == toset(["dynamodb:PutItem", "dynamodb:UpdateItem"])
    error_message = "The report role may only PutItem/UpdateItem (the per-item actions of TransactWriteItems)."
  }

  assert {
    condition     = data.aws_iam_policy_document.report.statement[1].resources == toset(["arn:aws:dynamodb:us-east-1:123456789012:table/reports"])
    error_message = "The report role's DynamoDB access must be limited to the reports table."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.report.statement[1].condition).test == "ForAllValues:StringLike"
    error_message = "The report role's DynamoDB writes must use a ForAllValues:StringLike condition."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.report.statement[1].condition).variable == "dynamodb:LeadingKeys"
    error_message = "The report role's DynamoDB writes must be conditioned on dynamodb:LeadingKeys."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.report.statement[1].condition).values == tolist(["R#*", "RL#*"])
    error_message = "The report role may only write R# and RL# partition keys, never OVERRIDE."
  }
}

run "aggregate_role_has_inline_least_privilege_policy" {
  command = plan

  assert {
    condition     = aws_iam_role_policy.aggregate.role == aws_iam_role.aggregate.id
    error_message = "The aggregate inline policy must be attached to the aggregate role."
  }

  assert {
    condition     = aws_iam_role_policy.aggregate.name == "sheket-aggregate-inline"
    error_message = "The aggregate inline policy name must be derived from name_prefix."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.aggregate.statement) == 4
    error_message = "The aggregate policy must have exactly four statements."
  }

  assert {
    condition     = alltrue([for s in data.aws_iam_policy_document.aggregate.statement : s.effect == "Allow"])
    error_message = "Every aggregate policy statement must be an Allow."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[0].actions == toset(["logs:CreateLogStream", "logs:PutLogEvents"])
    error_message = "The aggregate role may only create log streams and put log events."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[0].resources == toset(["arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/sheket-aggregate:*"])
    error_message = "The aggregate role may only write to its own log group."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[1].actions == toset(["dynamodb:Query"])
    error_message = "The aggregate role may only Query the table."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[1].resources == toset(["arn:aws:dynamodb:us-east-1:123456789012:table/reports"])
    error_message = "The aggregate role's DynamoDB access must be limited to the reports table."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[2].actions == toset(["s3:GetObject", "s3:PutObject"])
    error_message = "The aggregate role may only get and put the blocklist object."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[2].resources == toset(["arn:aws:s3:::sheket-blocklist-test/v1/blocklist.json"])
    error_message = "Object access must be limited to v1/blocklist.json."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[3].actions == toset(["s3:ListBucket"])
    error_message = "The bucket-level statement may only grant s3:ListBucket."
  }

  assert {
    condition     = data.aws_iam_policy_document.aggregate.statement[3].resources == toset(["arn:aws:s3:::sheket-blocklist-test"])
    error_message = "s3:ListBucket must be limited to the blocklist bucket."
  }
}

run "code_archive_packages_sheket_and_contract_files" {
  command = plan

  assert {
    condition = toset([for s in data.archive_file.code.source : s.filename]) == toset([
      "sheket/__init__.py",
      "sheket/aggregate.py",
      "sheket/normalize.py",
      "sheket/report.py",
      "sheket/contract/curated.json",
      "sheket/contract/blocklist.schema.json",
    ])
    error_message = "The code zip must hold backend/src/sheket/*.py plus the two contract files under sheket/contract/."
  }

  assert {
    condition     = one([for s in data.archive_file.code.source : s.content if s.filename == "sheket/contract/curated.json"]) == file("../contract/curated.json")
    error_message = "sheket/contract/curated.json must be read from ../contract/curated.json (REQ-20)."
  }

  assert {
    condition     = one([for s in data.archive_file.code.source : s.content if s.filename == "sheket/contract/blocklist.schema.json"]) == file("../contract/blocklist.schema.json")
    error_message = "sheket/contract/blocklist.schema.json must be read from ../contract/blocklist.schema.json (REQ-20)."
  }

  assert {
    condition     = one([for s in data.archive_file.code.source : s.content if s.filename == "sheket/aggregate.py"]) == file("../backend/src/sheket/aggregate.py")
    error_message = "sheket/aggregate.py must be read from backend/src."
  }

  assert {
    condition     = data.archive_file.code.output_path == "./build/code.zip"
    error_message = "The code zip must be written under infra/build/ (gitignored)."
  }
}

run "layer_targets_python313_arm64" {
  command = plan

  assert {
    condition     = aws_lambda_layer_version.runtime.layer_name == "sheket-runtime"
    error_message = "The layer name must be derived from name_prefix."
  }

  assert {
    condition     = aws_lambda_layer_version.runtime.compatible_runtimes == toset(["python3.13"])
    error_message = "The layer must target python3.13 (REQ-21)."
  }

  assert {
    condition     = aws_lambda_layer_version.runtime.compatible_architectures == toset(["arm64"])
    error_message = "The layer must target arm64 (REQ-21)."
  }

  assert {
    condition     = aws_lambda_layer_version.runtime.filename == data.archive_file.layer.output_path
    error_message = "The layer must upload the layer archive."
  }

  assert {
    condition     = aws_lambda_layer_version.runtime.source_code_hash == data.archive_file.layer.output_base64sha256
    error_message = "The layer hash must track the layer archive."
  }

  assert {
    condition     = data.archive_file.layer.source_dir == "./../backend/build/layer"
    error_message = "The layer must be zipped from backend/build/layer (output of build_layer.sh)."
  }
}

run "report_function_configuration" {
  command = plan

  assert {
    condition     = aws_lambda_function.report.function_name == "sheket-report"
    error_message = "The report function name must be derived from name_prefix."
  }

  assert {
    condition     = aws_lambda_function.report.handler == "sheket.report.handler"
    error_message = "The report handler must be sheket.report.handler."
  }

  assert {
    condition     = aws_lambda_function.report.runtime == "python3.13"
    error_message = "The report function must run python3.13 (REQ-21)."
  }

  assert {
    condition     = aws_lambda_function.report.architectures == tolist(["arm64"])
    error_message = "The report function must run on arm64 (REQ-21)."
  }

  assert {
    condition     = aws_lambda_function.report.reserved_concurrent_executions == 10
    error_message = "The report function must reserve concurrency 10 (spec §5)."
  }

  assert {
    condition     = aws_lambda_function.report.role == "arn:aws:iam::123456789012:role/sheket-report"
    error_message = "The report function must use the report role."
  }

  assert {
    condition     = aws_lambda_function.report.source_code_hash == data.archive_file.code.output_base64sha256
    error_message = "The report function must deploy the code archive."
  }

  assert {
    condition     = length(coalesce(aws_lambda_function.report.layers, [])) == 0
    error_message = "The report function must not use the runtime layer."
  }

  assert {
    condition = one(aws_lambda_function.report.environment).variables == tomap({
      TABLE_NAME   = "reports"
      IP_HASH_SALT = "test-salt-placeholder"
    })
    error_message = "The report function needs exactly TABLE_NAME and IP_HASH_SALT (the salt from random_password)."
  }
}

run "aggregate_function_configuration" {
  command = plan

  assert {
    condition     = aws_lambda_function.aggregate.function_name == "sheket-aggregate"
    error_message = "The aggregate function name must be derived from name_prefix."
  }

  assert {
    condition     = aws_lambda_function.aggregate.handler == "sheket.aggregate.handler"
    error_message = "The aggregate handler must be sheket.aggregate.handler."
  }

  assert {
    condition     = aws_lambda_function.aggregate.runtime == "python3.13"
    error_message = "The aggregate function must run python3.13 (REQ-21)."
  }

  assert {
    condition     = aws_lambda_function.aggregate.architectures == tolist(["arm64"])
    error_message = "The aggregate function must run on arm64 (REQ-21)."
  }

  assert {
    condition     = aws_lambda_function.aggregate.reserved_concurrent_executions == 1
    error_message = "The aggregate function must reserve concurrency 1 (spec §5)."
  }

  assert {
    condition     = aws_lambda_function.aggregate.role == "arn:aws:iam::123456789012:role/sheket-aggregate"
    error_message = "The aggregate function must use the aggregate role."
  }

  assert {
    condition     = aws_lambda_function.aggregate.source_code_hash == data.archive_file.code.output_base64sha256
    error_message = "The aggregate function must deploy the code archive."
  }

  assert {
    condition     = aws_lambda_function.aggregate.layers == tolist(["arn:aws:lambda:us-east-1:123456789012:layer:sheket-runtime:1"])
    error_message = "The aggregate function must use exactly the runtime layer (REQ-21)."
  }

  assert {
    condition = one(aws_lambda_function.aggregate.environment).variables == tomap({
      TABLE_NAME   = "reports"
      BUCKET_NAME  = "sheket-blocklist-test"
      MIN_INSTALLS = "3"
      MIN_NETWORKS = "2"
    })
    error_message = "The aggregate function needs TABLE_NAME, BUCKET_NAME and the default MIN_INSTALLS=3 / MIN_NETWORKS=2."
  }

  assert {
    condition     = aws_lambda_function_event_invoke_config.aggregate.function_name == "sheket-aggregate"
    error_message = "The async invoke config must target the aggregate function."
  }

  assert {
    condition     = aws_lambda_function_event_invoke_config.aggregate.maximum_retry_attempts == 0
    error_message = "Async invocations of the aggregate function must not be retried."
  }
}

run "log_groups_match_function_names_with_30_day_retention" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.report.name == "/aws/lambda/${aws_lambda_function.report.function_name}"
    error_message = "The report log group must be the report function's default log group."
  }

  assert {
    condition     = aws_cloudwatch_log_group.aggregate.name == "/aws/lambda/${aws_lambda_function.aggregate.function_name}"
    error_message = "The aggregate log group must be the aggregate function's default log group."
  }

  assert {
    condition     = aws_cloudwatch_log_group.report.retention_in_days == 30 && aws_cloudwatch_log_group.aggregate.retention_in_days == 30
    error_message = "Both log groups must retain logs for 30 days."
  }
}

run "salt_comes_from_random_password" {
  command = plan

  assert {
    condition     = random_password.ip_hash_salt.length == 48
    error_message = "The salt must be 48 characters."
  }

  assert {
    condition     = random_password.ip_hash_salt.special == false
    error_message = "The salt must not use special characters."
  }

  assert {
    condition     = random_password.ip_hash_salt.keepers == null
    error_message = "The salt must have no keepers, so it never rotates silently."
  }
}

run "function_url_is_public_with_both_permissions" {
  command = plan

  assert {
    condition     = aws_lambda_function_url.report.function_name == "sheket-report"
    error_message = "The function URL must front the report function."
  }

  assert {
    condition     = aws_lambda_function_url.report.authorization_type == "NONE"
    error_message = "The function URL must use authorization_type NONE (REQ-12)."
  }

  assert {
    condition     = aws_lambda_function_url.report.invoke_mode == "BUFFERED"
    error_message = "The function URL must use BUFFERED invoke mode."
  }

  assert {
    condition     = length(aws_lambda_function_url.report.cors) == 0
    error_message = "No CORS block is expected (native clients only)."
  }

  assert {
    condition     = aws_lambda_permission.report_url.action == "lambda:InvokeFunctionUrl"
    error_message = "The first permission must grant lambda:InvokeFunctionUrl."
  }

  assert {
    condition     = aws_lambda_permission.report_url.principal == "*" && aws_lambda_permission.report_url.function_url_auth_type == "NONE"
    error_message = "lambda:InvokeFunctionUrl must be granted to * for auth type NONE."
  }

  assert {
    condition     = aws_lambda_permission.report_url.function_name == "sheket-report"
    error_message = "The InvokeFunctionUrl permission must target the report function."
  }

  assert {
    condition     = aws_lambda_permission.report_url_invoke.action == "lambda:InvokeFunction"
    error_message = "The second permission must grant lambda:InvokeFunction."
  }

  assert {
    condition     = aws_lambda_permission.report_url_invoke.principal == "*" && aws_lambda_permission.report_url_invoke.invoked_via_function_url == true
    error_message = "lambda:InvokeFunction must be granted to * only when invoked via the function URL."
  }

  assert {
    condition     = aws_lambda_permission.report_url_invoke.function_name == "sheket-report"
    error_message = "The InvokeFunction permission must target the report function."
  }

  assert {
    condition     = output.report_url == "https://report-test.lambda-url.example/v1/reports"
    error_message = "report_url must be the function URL (trailing slash trimmed) plus /v1/reports."
  }
}

run "custom_thresholds_flow_into_aggregate_environment" {
  command = plan

  variables {
    min_installs = 1
    min_networks = 5
  }

  assert {
    condition     = one(aws_lambda_function.aggregate.environment).variables["MIN_INSTALLS"] == "1"
    error_message = "MIN_INSTALLS must come from var.min_installs (spec §6.3)."
  }

  assert {
    condition     = one(aws_lambda_function.aggregate.environment).variables["MIN_NETWORKS"] == "5"
    error_message = "MIN_NETWORKS must come from var.min_networks (spec §6.3)."
  }
}

run "custom_name_prefix_flows_into_compute_names" {
  command = plan

  variables {
    name_prefix = "dev"
  }

  assert {
    condition     = aws_lambda_function.report.function_name == "dev-report" && aws_lambda_function.aggregate.function_name == "dev-aggregate"
    error_message = "Function names must be derived from name_prefix."
  }

  assert {
    condition     = aws_cloudwatch_log_group.report.name == "/aws/lambda/dev-report" && aws_cloudwatch_log_group.aggregate.name == "/aws/lambda/dev-aggregate"
    error_message = "Log group names must follow the function names."
  }

  assert {
    condition     = aws_lambda_layer_version.runtime.layer_name == "dev-runtime"
    error_message = "The layer name must be derived from name_prefix."
  }

  assert {
    condition     = aws_dynamodb_table.reports.name == "reports"
    error_message = "The table name is fixed per the design and does not take name_prefix."
  }
}

run "min_installs_rejects_zero" {
  command = plan

  variables {
    min_installs = 0
  }

  expect_failures = [var.min_installs]
}

run "min_installs_rejects_fraction" {
  command = plan

  variables {
    min_installs = 2.5
  }

  expect_failures = [var.min_installs]
}

run "min_networks_rejects_zero" {
  command = plan

  variables {
    min_networks = 0
  }

  expect_failures = [var.min_networks]
}

run "min_networks_rejects_negative" {
  command = plan

  variables {
    min_networks = -1
  }

  expect_failures = [var.min_networks]
}

run "min_networks_rejects_fraction" {
  command = plan

  variables {
    min_networks = 1.5
  }

  expect_failures = [var.min_networks]
}
