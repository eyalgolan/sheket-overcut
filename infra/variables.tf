variable "name_prefix" {
  description = "Prefix for resource names. Lowercase letters, digits and hyphens; at most 20 characters because it feeds the S3 bucket_prefix."
  type        = string
  default     = "sheket"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,19}$", var.name_prefix))
    error_message = "The name_prefix must be 1-20 characters, start with a lowercase letter or digit, and contain only lowercase letters, digits and hyphens."
  }
}
