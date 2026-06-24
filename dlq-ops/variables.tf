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

variable "dlq_alert_email" {
  type        = string
  default     = ""
  description = "DLQ 알림을 받을 이메일 주소. 비워두면 SNS 이메일 구독을 생성하지 않습니다."
}

variable "free_dlq_name" {
  type        = string
  default     = "free-dlq"
  description = "free 플랜 DLQ 이름 (20-runtime/sqs.tf의 aws_sqs_queue.free_dlq.name과 일치해야 함)"
}

variable "paid_dlq_name" {
  type        = string
  default     = "paid-dlq"
  description = "paid 플랜 DLQ 이름 (20-runtime/sqs.tf의 aws_sqs_queue.paid_dlq.name과 일치해야 함)"
}
