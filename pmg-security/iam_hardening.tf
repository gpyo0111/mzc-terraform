# =========================================================================
# 1. 20-runtime 폴더(팀원)가 생성해 둔 실물 IAM Role을 이름 기반으로 원격 룩업
# =========================================================================
data "aws_iam_role" "api_task_target" {
  name = "${var.project_name}-${var.env}-api-task-role"
}

data "aws_iam_role" "worker_task_target" {
  name = "${var.project_name}-${var.env}-worker-task-role"
}

# =========================================================================
# 2. [403 에러 방지] S3 버킷 존재 유무 조회를 위한 ListBucket 전용 보안 정책 정의
# =========================================================================
resource "aws_iam_policy" "ecs_s3_list_hardening" {
  name        = "${var.project_name}-${var.env}-ecs-s3-list-hardening-policy"
  description = "ECS Fargate API 및 Worker 태스크가 S3 버킷 자체를 조회(List)할 수 있도록 가드레일을 보완하여 403 오탐을 방지하는 정책"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          data.aws_s3_bucket.audio.arn,  # s3_security.tf에 이미 선언된 데이터 소스를 재사용합니다.
          data.aws_s3_bucket.model.arn
        ]
      }
    ]
  })
}

# =========================================================================
# 3. 팀원 폴더의 코드를 수정하지 않고, 우리 폴더에서 정책을 원격 추가 결합(Attachment)
# =========================================================================

# 1) 백엔드 API Task Role에 S3 ListBucket 권한 추가 바인딩
resource "aws_iam_role_policy_attachment" "api_list_hardening_binding" {
  role       = data.aws_iam_role.api_task_target.name
  policy_arn = aws_iam_policy.ecs_s3_list_hardening.arn
}

# 2) AI 변조 Worker Task Role에 S3 ListBucket 권한 추가 바인딩
resource "aws_iam_role_policy_attachment" "worker_list_hardening_binding" {
  role       = data.aws_iam_role.worker_task_target.name
  policy_arn = aws_iam_policy.ecs_s3_list_hardening.arn
}