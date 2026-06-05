variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  type    = string
  default = "kjh"
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
