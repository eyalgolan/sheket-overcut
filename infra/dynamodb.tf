# Reports and rate-limit counters (spec section 5). Key schema matches the moto
# table in backend/tests/conftest.py.
resource "aws_dynamodb_table" "reports" {
  # Fixed name per the design (spec section 5), not name_prefix: one stack per
  # account and region. Collides if a "reports" table already exists there.
  name                        = "reports"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = true

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Expiry is set per item by the report handler: 30 days for reports
  # (REPORT_TTL_SECONDS in backend/src/sheket/report.py), shorter for counters.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
