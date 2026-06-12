variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  type    = string
  default = "sgp"
}

variable "project_name" {
  type    = string
  default = "securevoice"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "cluster_name" {
  type    = string
  default = "securevoice-dev-cluster"
}

variable "paid_worker_service_name" {
  type    = string
  default = "securevoice-dev-paid-worker-service"
}

variable "free_worker_service_name" {
  type    = string
  default = "securevoice-dev-free-worker-service"
}

variable "aiops_alerts_sns_topic_arn" {
  type    = string
  default = "arn:aws:sns:ap-northeast-2:455535733131:securevoice-dev-aiops-alerts"
}

variable "slack_webhook_secret_name" {
  type    = string
  default = "securevoice/dev/slack-aiops-webhook-url"
}

variable "paid_queue_url" {
  type = string
}

variable "free_queue_url" {
  type = string
}

variable "paid_worker_log_group_name" {
  type    = string
  default = "/ecs/securevoice-dev-paid-worker"
}

variable "free_worker_log_group_name" {
  type    = string
  default = "/ecs/securevoice-dev-free-worker"
}

variable "runbook_base_url" {
  type    = string
  default = "https://github.com/gpyo0111/mzc-runbook/blob/main/securevoice"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "SecureVoiceGuard"
    Environment = "dev"
    ManagedBy   = "Terraform"
    Component   = "AIOps-Alert-Summary"
  }
}