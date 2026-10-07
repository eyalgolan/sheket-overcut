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
# backend/requirements.txt dependencies; boto3 comes from the Lambda runtime.
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
