variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile"
  type        = string
  default     = "sgp"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "securevoice"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "slack_team_id" {
  description = "Slack workspace/team ID authorized in Amazon Q Developer in chat applications"
  type        = string
}

variable "slack_channel_id" {
  description = "Slack channel ID for AIOps alerts"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default = {
    Project     = "SecureVoiceGuard"
    Environment = "dev"
    ManagedBy   = "Terraform"
    Component   = "AIOps-Alerting"
  }
}