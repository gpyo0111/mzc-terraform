data "aws_ecr_repository" "locust" {
  name = "securevoice-locust"
}

locals {
  locust_image = "${data.aws_ecr_repository.locust.repository_url}:${var.locust_image_tag}"

  common_tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
    Purpose     = "load-test"
  }
}
