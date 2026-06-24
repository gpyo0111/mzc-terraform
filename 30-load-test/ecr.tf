# 부하테스트용 Locust 이미지를 저장하는 ECR 리포지토리
resource "aws_ecr_repository" "locust" {
  name                 = "securevoice-locust"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "locust" {
  repository = aws_ecr_repository.locust.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최근 5개 이미지만 보관"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
