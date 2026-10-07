# Offline tests for storage.tf, cdn.tf, variables.tf and outputs.tf.
#
# Run from infra/ with `terraform test`. Every run block uses `command = plan`
# against a mocked aws provider: no AWS credentials, no network calls to AWS
# and nothing is ever applied. The overrides below are fake placeholders
# (AWS documentation account id, `.example` names), not real endpoints.

mock_provider "aws" {
  override_resource {
    target          = aws_s3_bucket.blocklist
    override_during = plan
    values = {
      id                          = "sheket-blocklist-test"
      arn                         = "arn:aws:s3:::sheket-blocklist-test"
      bucket_regional_domain_name = "sheket-blocklist-test.s3.example"
    }
  }

  override_resource {
    target          = aws_cloudfront_origin_access_control.blocklist
    override_during = plan
    values = {
      id = "OACTEST"
    }
  }

  override_resource {
    target          = aws_cloudfront_cache_policy.blocklist
    override_during = plan
    values = {
      id = "cache-policy-test"
    }
  }

  override_resource {
    target          = aws_cloudfront_distribution.blocklist
    override_during = plan
    values = {
      arn         = "arn:aws:cloudfront::123456789012:distribution/EXAMPLE"
      domain_name = "d-test.example"
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

# lambda.tf zips backend/build/layer, which only exists after
# backend/scripts/build_layer.sh has run. Override the data source so these
# tests run without a built layer.
override_data {
  target = data.archive_file.layer
  values = {
    output_path         = "build/layer.zip"
    output_base64sha256 = "bGF5ZXItdGVzdA=="
  }
}

run "bucket_is_private_encrypted_and_versioned" {
  command = plan

  assert {
    condition     = aws_s3_bucket.blocklist.bucket_prefix == "sheket-blocklist-"
    error_message = "The bucket must be named through bucket_prefix \"<name_prefix>-blocklist-\"."
  }

  assert {
    condition     = aws_s3_bucket.blocklist.force_destroy != true
    error_message = "The blocklist bucket must not set force_destroy."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.blocklist.block_public_acls,
      aws_s3_bucket_public_access_block.blocklist.block_public_policy,
      aws_s3_bucket_public_access_block.blocklist.ignore_public_acls,
      aws_s3_bucket_public_access_block.blocklist.restrict_public_buckets,
    ])
    error_message = "All four S3 public-access blocks must be enabled."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.blocklist.bucket == aws_s3_bucket.blocklist.id
    error_message = "The public-access block must target the blocklist bucket."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.blocklist.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "Object ownership must be BucketOwnerEnforced (ACLs disabled)."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.blocklist.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Default encryption must be SSE-S3 (AES256), not KMS."
  }

  assert {
    condition     = aws_s3_bucket_versioning.blocklist.versioning_configuration[0].status == "Enabled"
    error_message = "Bucket versioning must be enabled."
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.blocklist.rule) == 1
    error_message = "Exactly one lifecycle rule is expected."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.blocklist.rule[0].status == "Enabled"
    error_message = "The lifecycle rule must be enabled."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.blocklist.rule[0].noncurrent_version_expiration[0].noncurrent_days == 30
    error_message = "Noncurrent versions must expire after 30 days (provisional, per the design)."
  }
}

run "bucket_policy_allows_only_cloudfront_oac_reads_of_v1" {
  command = plan

  assert {
    condition     = aws_s3_bucket_policy.blocklist.bucket == aws_s3_bucket.blocklist.id
    error_message = "The bucket policy must be attached to the blocklist bucket."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.blocklist_bucket.statement) == 2
    error_message = "The bucket policy must have exactly two statements."
  }

  assert {
    condition     = length([for s in data.aws_iam_policy_document.blocklist_bucket.statement : s if s.effect == "Allow"]) == 1
    error_message = "The bucket policy must contain exactly one Allow statement."
  }

  assert {
    condition     = data.aws_iam_policy_document.blocklist_bucket.statement[0].sid == "AllowCloudFrontReadV1"
    error_message = "The first statement must be AllowCloudFrontReadV1."
  }

  assert {
    condition     = data.aws_iam_policy_document.blocklist_bucket.statement[0].effect == "Allow"
    error_message = "AllowCloudFrontReadV1 must be an Allow statement."
  }

  assert {
    condition     = data.aws_iam_policy_document.blocklist_bucket.statement[0].actions == toset(["s3:GetObject"])
    error_message = "CloudFront may only be granted s3:GetObject."
  }

  assert {
    condition     = data.aws_iam_policy_document.blocklist_bucket.statement[0].resources == toset(["arn:aws:s3:::sheket-blocklist-test/v1/*"])
    error_message = "The CloudFront grant must be limited to objects under v1/."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[0].principals).type == "Service"
    error_message = "The CloudFront grant must use a Service principal."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[0].principals).identifiers == toset(["cloudfront.amazonaws.com"])
    error_message = "The only principal granted read access must be cloudfront.amazonaws.com."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[0].condition).test == "StringEquals"
    error_message = "The CloudFront grant must use a StringEquals condition."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[0].condition).variable == "AWS:SourceArn"
    error_message = "The CloudFront grant must be conditioned on AWS:SourceArn."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[0].condition).values == tolist([aws_cloudfront_distribution.blocklist.arn])
    error_message = "AWS:SourceArn must be this distribution's ARN only."
  }

  assert {
    condition     = data.aws_iam_policy_document.blocklist_bucket.statement[1].sid == "DenyInsecureTransport"
    error_message = "The second statement must be DenyInsecureTransport."
  }

  assert {
    condition     = data.aws_iam_policy_document.blocklist_bucket.statement[1].effect == "Deny"
    error_message = "DenyInsecureTransport must be a Deny statement."
  }

  assert {
    condition     = data.aws_iam_policy_document.blocklist_bucket.statement[1].actions == toset(["s3:*"])
    error_message = "DenyInsecureTransport must cover every S3 action."
  }

  assert {
    condition = data.aws_iam_policy_document.blocklist_bucket.statement[1].resources == toset([
      "arn:aws:s3:::sheket-blocklist-test",
      "arn:aws:s3:::sheket-blocklist-test/*",
    ])
    error_message = "DenyInsecureTransport must cover the bucket and every object in it."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[1].principals).identifiers == toset(["*"])
    error_message = "DenyInsecureTransport must apply to every principal."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[1].condition).test == "Bool"
    error_message = "DenyInsecureTransport must use a Bool condition."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[1].condition).variable == "aws:SecureTransport"
    error_message = "DenyInsecureTransport must test aws:SecureTransport."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.blocklist_bucket.statement[1].condition).values == tolist(["false"])
    error_message = "DenyInsecureTransport must match requests where aws:SecureTransport is false."
  }
}

run "origin_access_control_always_signs_with_sigv4" {
  command = plan

  assert {
    condition     = aws_cloudfront_origin_access_control.blocklist.name == "sheket-blocklist"
    error_message = "The OAC name must be derived from name_prefix."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.blocklist.origin_access_control_origin_type == "s3"
    error_message = "The OAC must be for an S3 origin."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.blocklist.signing_behavior == "always"
    error_message = "The OAC must always sign origin requests."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.blocklist.signing_protocol == "sigv4"
    error_message = "The OAC must sign with sigv4."
  }
}

run "cache_policy_has_300s_ttl_and_minimal_cache_key" {
  command = plan

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.name == "sheket-blocklist-300s"
    error_message = "The cache policy name must be derived from name_prefix."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.min_ttl == 0
    error_message = "min_ttl must be 0 (spec §5)."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.default_ttl == 300
    error_message = "default_ttl must be 300 s (spec §5)."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.max_ttl == 300
    error_message = "max_ttl must be 300 s (spec §5)."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.parameters_in_cache_key_and_forwarded_to_origin[0].enable_accept_encoding_gzip
    error_message = "gzip must be part of the cache key."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.parameters_in_cache_key_and_forwarded_to_origin[0].enable_accept_encoding_brotli
    error_message = "brotli must be part of the cache key."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.parameters_in_cache_key_and_forwarded_to_origin[0].cookies_config[0].cookie_behavior == "none"
    error_message = "Cookies must not be part of the cache key."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.parameters_in_cache_key_and_forwarded_to_origin[0].headers_config[0].header_behavior == "none"
    error_message = "Headers must not be part of the cache key."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.parameters_in_cache_key_and_forwarded_to_origin[0].query_strings_config[0].query_string_behavior == "none"
    error_message = "Query strings must not be part of the cache key."
  }
}

run "distribution_is_get_head_https_only_via_oac" {
  command = plan

  assert {
    condition     = aws_cloudfront_distribution.blocklist.enabled
    error_message = "The distribution must be enabled."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.price_class == "PriceClass_200"
    error_message = "The price class must be PriceClass_200 (provisional, per the design)."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.blocklist.origin) == 1
    error_message = "The distribution must have exactly one origin."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.blocklist.origin).domain_name == aws_s3_bucket.blocklist.bucket_regional_domain_name
    error_message = "The origin must be the blocklist bucket's regional domain name."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.blocklist.origin).origin_access_control_id == aws_cloudfront_origin_access_control.blocklist.id
    error_message = "The origin must use the blocklist OAC."
  }

  assert {
    condition     = length(one(aws_cloudfront_distribution.blocklist.origin).s3_origin_config) == 0
    error_message = "The origin must not use a legacy OAI (s3_origin_config)."
  }

  assert {
    condition     = length(one(aws_cloudfront_distribution.blocklist.origin).custom_origin_config) == 0
    error_message = "The origin must be an S3 origin, not a custom origin."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.default_cache_behavior[0].target_origin_id == one(aws_cloudfront_distribution.blocklist.origin).origin_id
    error_message = "The default cache behavior must target the blocklist origin."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.default_cache_behavior[0].viewer_protocol_policy == "https-only"
    error_message = "Viewers must be served over HTTPS only."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.default_cache_behavior[0].allowed_methods == toset(["GET", "HEAD"])
    error_message = "Only GET and HEAD may be allowed."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.default_cache_behavior[0].cached_methods == toset(["GET", "HEAD"])
    error_message = "Only GET and HEAD may be cached."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.default_cache_behavior[0].cache_policy_id == aws_cloudfront_cache_policy.blocklist.id
    error_message = "The default cache behavior must use the 300 s cache policy."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.blocklist.default_cache_behavior[0].forwarded_values) == 0
    error_message = "Legacy forwarded_values must not be used alongside the cache policy."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.blocklist.ordered_cache_behavior) == 0
    error_message = "No extra cache behaviors are expected."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.viewer_certificate[0].cloudfront_default_certificate
    error_message = "The distribution must use the default CloudFront certificate."
  }

  assert {
    condition     = length(try(aws_cloudfront_distribution.blocklist.aliases, null) == null ? [] : aws_cloudfront_distribution.blocklist.aliases) == 0
    error_message = "No custom domain aliases may be configured."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.restrictions[0].geo_restriction[0].restriction_type == "none"
    error_message = "No geo restriction is expected."
  }
}

run "outputs_are_derived_from_the_distribution" {
  command = plan

  assert {
    condition     = output.cloudfront_domain == "d-test.example"
    error_message = "cloudfront_domain must be the distribution's domain name."
  }

  assert {
    condition     = output.blocklist_url == "https://d-test.example/v1/blocklist.json"
    error_message = "blocklist_url must be https://<cloudfront_domain>/v1/blocklist.json."
  }
}

run "custom_name_prefix_flows_into_names" {
  command = plan

  variables {
    name_prefix = "abcdefghij-123456789"
  }

  assert {
    condition     = aws_s3_bucket.blocklist.bucket_prefix == "abcdefghij-123456789-blocklist-"
    error_message = "bucket_prefix must be derived from name_prefix."
  }

  assert {
    condition     = length(aws_s3_bucket.blocklist.bucket_prefix) <= 37
    error_message = "A 20-character name_prefix must keep bucket_prefix within the S3 limit of 37 characters."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.blocklist.name == "abcdefghij-123456789-blocklist"
    error_message = "The OAC name must be derived from name_prefix."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.blocklist.name == "abcdefghij-123456789-blocklist-300s"
    error_message = "The cache policy name must be derived from name_prefix."
  }

  assert {
    condition     = aws_cloudfront_distribution.blocklist.comment == "abcdefghij-123456789 blocklist"
    error_message = "The distribution comment must be derived from name_prefix."
  }
}

run "name_prefix_single_character_is_accepted" {
  command = plan

  variables {
    name_prefix = "a"
  }

  assert {
    condition     = aws_s3_bucket.blocklist.bucket_prefix == "a-blocklist-"
    error_message = "A one-character name_prefix must be accepted."
  }
}

run "name_prefix_rejects_uppercase" {
  command = plan

  variables {
    name_prefix = "Sheket"
  }

  expect_failures = [var.name_prefix]
}

run "name_prefix_rejects_more_than_20_characters" {
  command = plan

  variables {
    name_prefix = "abcdefghij-1234567890"
  }

  expect_failures = [var.name_prefix]
}

run "name_prefix_rejects_empty" {
  command = plan

  variables {
    name_prefix = ""
  }

  expect_failures = [var.name_prefix]
}

run "name_prefix_rejects_leading_hyphen" {
  command = plan

  variables {
    name_prefix = "-sheket"
  }

  expect_failures = [var.name_prefix]
}

run "name_prefix_rejects_underscore" {
  command = plan

  variables {
    name_prefix = "sheket_dev"
  }

  expect_failures = [var.name_prefix]
}

run "name_prefix_rejects_dot" {
  command = plan

  variables {
    name_prefix = "sheket.dev"
  }

  expect_failures = [var.name_prefix]
}
