data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_ecr_repository" "api" {
  name = "voice-api-service"
}

data "aws_ecr_repository" "worker" {
  name = "nes2net-ai-worker"
}

data "aws_s3_bucket" "audio" {
  bucket = var.audio_bucket_name
}

data "aws_s3_bucket" "model" {
  bucket = var.model_bucket_name
}

locals {
  api_image    = "${data.aws_ecr_repository.api.repository_url}:${var.api_image_tag}"
  worker_image = "${data.aws_ecr_repository.worker.repository_url}:${var.worker_image_tag}"

  common_tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
  }
}