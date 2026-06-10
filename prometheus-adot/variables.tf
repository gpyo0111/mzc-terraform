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

variable "ecs_task_execution_role_name" {
  description = "20-runtime ECS task execution role name"
  type        = string
  default     = ""
}

variable "api_task_role_name" {
  description = "20-runtime API task role name"
  type        = string
  default     = ""
}

variable "worker_task_role_name" {
  description = "20-runtime Worker task role name"
  type        = string
  default     = ""
}

variable "api_metrics_port" {
  type    = number
  default = 8000
}

variable "worker_metrics_port" {
  type    = number
  default = 9100
}

variable "scrape_interval" {
  type    = string
  default = "15s"
}

variable "tags" {
  type = map(string)
  default = {
    Project = "securevoice"
    Env     = "dev"
    Managed = "terraform"
    Owner   = "aiops-observability-scaling"
  }
}