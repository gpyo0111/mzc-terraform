variable "project_name" {
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

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "grafana_image" {
  type    = string
  default = "grafana/grafana-oss:latest"
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "amp_workspace_id" {
  type    = string
  default = "ws-f5401713-ad61-4d08-89f8-c385005c9267"
}

variable "tags" {
  type = map(string)

  default = {
    Project     = "securevoice"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}