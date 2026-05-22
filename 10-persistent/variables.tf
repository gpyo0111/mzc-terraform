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

variable "vpc_id" {
  type    = string
  default = "vpc-040923e167f09c210"
}

variable "private_db_subnet_ids" {
  type = list(string)
  default = [
    "subnet-0277e1099b4dda2ac",
    "subnet-02fef76587525b847"
  ]
}

variable "private_app_subnet_ids" {
  type = list(string)
  default = [
    "subnet-0bc568164c640b910",
    "subnet-00b3943c9a029e5c2"
  ]
}

variable "private_app_subnet_cidrs" {
  type = list(string)
  default = [
    "10.0.11.0/24",
    "10.0.12.0/24"
  ]
}

variable "private_app_route_table_id" {
  type    = string
  default = "rtb-032678c4d7692558c"
}

variable "model_bucket_name" {
  type    = string
  default = "mzc-securevoiceguard-model-dev-455535733131-ap-northeast-2"
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