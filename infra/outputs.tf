output "cloudfront_domain" {
  description = "CloudFront domain name that serves the blocklist."
  value       = aws_cloudfront_distribution.blocklist.domain_name
}

output "blocklist_url" {
  description = "Public URL of the blocklist (v1/blocklist.json via CloudFront)."
  value       = "https://${aws_cloudfront_distribution.blocklist.domain_name}/v1/blocklist.json"
}

output "report_url" {
  description = "Public report endpoint (POST /v1/reports) on the report Lambda function URL. Only exists after a human runs terraform apply."
  value       = "${trimsuffix(aws_lambda_function_url.report.function_url, "/")}/v1/reports"
}
