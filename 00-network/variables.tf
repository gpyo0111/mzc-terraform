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

variable "vpc_name" {
  type    = string
  default = "cloud-dev-vpc"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/22"
}

variable "az_a" {
  type    = string
  default = "ap-northeast-2a"
}

variable "az_c" {
  type    = string
  default = "ap-northeast-2c"
}