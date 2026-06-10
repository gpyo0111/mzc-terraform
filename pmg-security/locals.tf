locals {
  waf_name = "${var.project_name}-${var.env}-waf"

  common_tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
  }
}