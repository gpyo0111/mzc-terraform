# =========================================================================
# 기본 환경 변수 정의 (전역 설정)
# =========================================================================
variable "aws_region" {
  type        = string
  default     = "ap-northeast-2"
  description = "보안 자산이 배포 및 관리될 대상 AWS 기본 리전"
}

# =========================================================================
# 프로젝트 S3 대상 버킷 명칭 변수화 (단일 진실 공급원)
# =========================================================================
variable "audio_bucket_name" {
  type        = string
  default     = "mzc-securevoiceguard-audio-dev-455535733131-ap-northeast-2-an"
  description = "고위험 생체 정보(음성 파일)가 업로드되는 코어 데이터 버킷 이름"
}

variable "model_bucket_name" {
  type        = string
  default     = "mzc-securevoiceguard-model-dev-455535733131-ap-northeast-2"
  description = "변조 음성 탐지 AI 추론 모델 가중치 파일이 보관되는 버킷 이름"
}

variable "web_static_bucket_name" {
  type        = string
  default     = "mzc-securevoiceguard-web-dev"
  description = "웹 서비스 프론트엔드 정적 소스(HTML/JS) 배포용 호스팅 버킷 이름"
}

variable "tf_state_bucket_name" {
  type        = string
  default     = "securevoice-terraform-state-455535733131-ap-northeast-2"
  description = "전체 인프라 형상 관리 정보(State 파일)가 격리 저장되는 원격 백엔드 S3 버킷 이름"
}

# =========================================================================
# AWS KMS 데이터 암호화 마스터 키 변수 정의
# =========================================================================
variable "kms_key_alias" {
  type        = string
  default     = "alias/securevoice-dev-master-key"
  description = "ISMS-P 컴플라이언스 준수를 위한 SecureVoice 프로젝트 전용 데이터 암호화 마스터 키 별칭"
}

variable "account_id" {
  type    = string
  default = "455535733131"
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
  default = "vpc-09a927181645cd53c"
}

variable "alb" {
  type    = string
  default = "securevoice-dev-api-alb"
}

data "aws_lb" "target_alb" {
  name = "securevoice-dev-api-alb"
}