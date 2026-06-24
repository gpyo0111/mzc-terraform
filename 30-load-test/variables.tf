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

# ── 부하테스트 컨테이너 설정 ──────────────────────────────────────────────────

variable "locust_image_tag" {
  type        = string
  default     = "latest"
  description = "ECR에 푸시된 Locust 이미지 태그"
}

variable "locust_master_cpu" {
  type    = number
  default = 1024 # 1 vCPU
}

variable "locust_master_memory" {
  type    = number
  default = 2048
}

variable "locust_worker_cpu" {
  type    = number
  default = 512
}

variable "locust_worker_memory" {
  type    = number
  default = 1024
}

variable "locust_worker_count" {
  type        = number
  default     = 2
  description = "Locust 워커 태스크 수 (동시 사용자 부하 분산)"
}

# ── 부하테스트 파라미터 ─────────────────────────────────────────────────────

variable "target_host" {
  type        = string
  description = "부하테스트 대상 URL. 예: http://securevoice-dev-api-alb-xxxx.ap-northeast-2.elb.amazonaws.com"
}

variable "locust_users" {
  type        = number
  default     = 50
  description = "최대 동시 가상 유저 수"
}

variable "locust_spawn_rate" {
  type        = number
  default     = 5
  description = "초당 유저 증가 수"
}

variable "locust_run_time" {
  type        = string
  default     = "5m"
  description = "자동 종료 시간. 예: 5m, 10m, 1h"
}

variable "audio_s3_bucket" {
  type        = string
  default     = "mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an"
  description = "부하테스트용 샘플 오디오가 저장된 S3 버킷"
}

variable "audio_s3_prefix" {
  type        = string
  default     = "load-test-samples/"
  description = "부하테스트 샘플 오디오 S3 prefix"
}
