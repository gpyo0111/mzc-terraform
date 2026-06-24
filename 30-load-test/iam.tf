# ── ECS Task Execution Role (ECR pull, CloudWatch logs) ──────────────────────

resource "aws_iam_role" "locust_task_execution" {
  name = "${var.project_name}-${var.env}-locust-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "locust_task_execution" {
  role       = aws_iam_role.locust_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── ECS Task Role (S3 샘플 오디오 읽기) ──────────────────────────────────────

resource "aws_iam_role" "locust_task" {
  name = "${var.project_name}-${var.env}-locust-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "locust_task" {
  name = "${var.project_name}-${var.env}-locust-task-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 부하테스트용 샘플 오디오를 S3에서 읽어 multipart/form-data로 전송
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.audio_s3_bucket}",
          "arn:aws:s3:::${var.audio_s3_bucket}/${var.audio_s3_prefix}*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "locust_task" {
  role       = aws_iam_role.locust_task.name
  policy_arn = aws_iam_policy.locust_task.arn
}
