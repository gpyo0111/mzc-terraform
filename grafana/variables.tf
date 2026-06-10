variable "project" {
  type    = string
  default = "securevoice"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  type    = string
  default = "sgp"
}

variable "grafana_admin_user_ids" {
  description = "IAM Identity Center user IDs to assign Grafana ADMIN role"
  type        = list(string)
  default     = []
}

variable "grafana_admin_group_ids" {
  description = "IAM Identity Center group IDs to assign Grafana ADMIN role"
  type        = list(string)
  default     = []
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "securevoice"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}