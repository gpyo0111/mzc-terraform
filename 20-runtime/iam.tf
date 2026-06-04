resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-${var.env}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "ecs_task_execution_secrets" {
  name = "${var.project_name}-${var.env}-ecs-task-execution-secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          var.db_password_secret_arn,
          var.jwt_secret_key_secret_arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_secrets" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.ecs_task_execution_secrets.arn
}

resource "aws_iam_role" "api_task" {
  name = "${var.project_name}-${var.env}-api-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "api_task" {
  name = "${var.project_name}-${var.env}-api-task-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = [
          "${data.aws_s3_bucket.audio.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = [
          aws_sqs_queue.free.arn,
          aws_sqs_queue.paid.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_task" {
  role       = aws_iam_role.api_task.name
  policy_arn = aws_iam_policy.api_task.arn
}

resource "aws_iam_role" "worker_task" {
  name = "${var.project_name}-${var.env}-worker-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "worker_task" {
  name = "${var.project_name}-${var.env}-worker-task-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${data.aws_s3_bucket.audio.arn}/*",
          "${data.aws_s3_bucket.model.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = [
          aws_sqs_queue.free.arn,
          aws_sqs_queue.paid.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_task" {
  role       = aws_iam_role.worker_task.name
  policy_arn = aws_iam_policy.worker_task.arn
}

# =========================================================================
# [보안 하드닝 추가] S3 정적 암호화(SSE-KMS) 대응 마스터 키 권한 정책 선언
# =========================================================================
resource "aws_iam_policy" "ecs_kms_s3_access" {
  name        = "${var.project_name}-${var.env}-ecs-kms-s3-access-policy"
  description = "ECS Fargate API 및 Worker 태스크가 KMS 마스터 키를 통해 암호화된 S3 버킷에 접근할 수 있도록 허용하는 정책"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [
          "arn:aws:kms:ap-northeast-2:455535733131:key/5b711458-5f36-427f-b4a7-0daa1b81a0b1"
        ]
      }
    ]
  })
}

# =========================================================================
# 기존 API 및 Worker 역할(Role)에 신규 KMS 보안 정책 결합(Attachment)
# =========================================================================

# 1. 기존의 api_task 역할에 KMS 권한 추가 바인딩
resource "aws_iam_role_policy_attachment" "api_task_kms_binding" {
  role       = aws_iam_role.api_task.name
  policy_arn = aws_iam_policy.ecs_kms_s3_access.arn
}

# 2. 기존의 worker_task 역할에 KMS 권한 추가 바인딩
resource "aws_iam_role_policy_attachment" "worker_task_kms_binding" {
  role       = aws_iam_role.worker_task.name
  policy_arn = aws_iam_policy.ecs_kms_s3_access.arn
}