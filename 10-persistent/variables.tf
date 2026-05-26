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

variable "db_username" {
  type    = string
  default = "mzmt"
}

variable "db_password" {
  type      = string
  sensitive = true
}