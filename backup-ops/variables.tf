variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  type    = string
  default = "bya"
}

variable "project_name" {
  type    = string
  default = "securevoice"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "audio_bucket_name" {
  type    = string
  default = "mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an"
}
