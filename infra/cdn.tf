resource "aws_cloudfront_origin_access_control" "blocklist" {
  name                              = "${var.name_prefix}-blocklist"
  description                       = "OAC for the private blocklist bucket."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Freshness relies on the 300 s TTL; no invalidations are issued (spec §5).
resource "aws_cloudfront_cache_policy" "blocklist" {
  name        = "${var.name_prefix}-blocklist-300s"
  comment     = "Blocklist: 300 s TTL, no cookies, headers or query strings."
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 300

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

locals {
  blocklist_origin_id = "blocklist-s3"
}

resource "aws_cloudfront_distribution" "blocklist" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} blocklist"
  http_version    = "http2and3"
  # Provisional, per the design; PriceClass_200 includes Israeli edge locations.
  price_class = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.blocklist.bucket_regional_domain_name
    origin_id                = local.blocklist_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.blocklist.id
  }

  default_cache_behavior {
    target_origin_id       = local.blocklist_origin_id
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.blocklist.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
