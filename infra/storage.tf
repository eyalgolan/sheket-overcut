resource "aws_s3_bucket" "blocklist" {
  bucket_prefix = "${var.name_prefix}-blocklist-"
}

resource "aws_s3_bucket_public_access_block" "blocklist" {
  bucket                  = aws_s3_bucket.blocklist.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "blocklist" {
  bucket = aws_s3_bucket.blocklist.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3 rather than KMS: CloudFront OAC reads of SSE-KMS objects would need a key policy.
resource "aws_s3_bucket_server_side_encryption_configuration" "blocklist" {
  bucket = aws_s3_bucket.blocklist.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "blocklist" {
  bucket = aws_s3_bucket.blocklist.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 30 days of noncurrent versions is provisional, per the design.
resource "aws_s3_bucket_lifecycle_configuration" "blocklist" {
  bucket = aws_s3_bucket.blocklist.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.blocklist]
}

data "aws_iam_policy_document" "blocklist_bucket" {
  statement {
    sid       = "AllowCloudFrontReadV1"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.blocklist.arn}/v1/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.blocklist.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.blocklist.arn, "${aws_s3_bucket.blocklist.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "blocklist" {
  bucket = aws_s3_bucket.blocklist.id
  policy = data.aws_iam_policy_document.blocklist_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.blocklist]
}
