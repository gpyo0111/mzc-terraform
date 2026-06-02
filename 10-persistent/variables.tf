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

variable "env" {
  type    = string
  default = "dev"
}

variable "model_bucket_name" {
  type    = string
  default = "mzc-securevoiceguard-model-dev-455535733131-ap-northeast-2"
}

variable "rds_snapshot_identifier" {
  type        = string
  description = "RDS snapshot identifier for restore. Empty string means create fresh DB."
  default     = ""
}

variable "db_name" {
  type    = string
  default = "mzmt_db"
}

# RDS master 계정명이다. 비밀번호는 RDS-managed Secrets Manager에서 자동 생성/관리한다.
variable "db_master_username" {
  type        = string
  description = "RDS master username. Keep this stable for an existing DB because changing it can require replacement."
  default     = "mzmt"
}

# ECS API/worker가 DB에 접속할 때 사용할 app 계정명이다.
# 실제 MySQL user 생성과 권한 부여는 SSM bootstrap 스크립트가 수행한다.
variable "db_app_username" {
  type        = string
  description = "Application DB username used by ECS tasks."
  default     = "mzmt_app"
}

variable "final_snapshot_date" {
  type        = string
  description = "Date suffix for the RDS final snapshot identifier. Use YYYYMMDD."
  default     = "20260527"
}
