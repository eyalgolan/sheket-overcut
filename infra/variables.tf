variable "name_prefix" {
  description = "Prefix for resource names. Lowercase letters, digits and hyphens; at most 20 characters because it feeds the S3 bucket_prefix."
  type        = string
  default     = "sheket"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,19}$", var.name_prefix))
    error_message = "The name_prefix must be 1-20 characters, start with a lowercase letter or digit, and contain only lowercase letters, digits and hyphens."
  }
}

variable "min_installs" {
  description = "Publication threshold (spec §6.3): minimum number of distinct installs that must report a sender within the last 7 days before it enters the blocklist."
  type        = number
  default     = 3

  validation {
    condition     = var.min_installs >= 1 && floor(var.min_installs) == var.min_installs
    error_message = "The min_installs must be an integer >= 1; the aggregate Lambda parses it as a base-10 integer."
  }
}

variable "min_networks" {
  description = "Publication threshold (spec §6.3): minimum number of distinct /24 networks the reports must come from within the last 7 days before a sender enters the blocklist."
  type        = number
  default     = 2

  validation {
    condition     = var.min_networks >= 1 && floor(var.min_networks) == var.min_networks
    error_message = "The min_networks must be an integer >= 1; the aggregate Lambda parses it as a base-10 integer."
  }
}

variable "alarm_email" {
  description = "Optional email address that receives the alarm notifications (SNS email subscription). Leave empty for no subscription. Set it only in a gitignored *.tfvars file, never in source. The recipient is provisional until the owner settles Decision 4 (who receives the alarms)."
  type        = string
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "The alarm_email must be empty or a single email address such as name@example.com."
  }
}
