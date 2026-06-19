# =========================================================================
# [자동대응 / Self-Healing] 보안그룹 0.0.0.0/0 위험 개방 → Lambda 자동 회수 + 알림
#
# 비유: CCTV(EventBridge)가 "누가 대문(SG)을 활짝 열었다!"를 감지하면,
#       경비원(Lambda)이 달려가 그 문을 다시 잠그고(revoke) 관리실(SNS)에 보고한다.
#
# 안전 설계(진행문서 ⓐⓑⓒ 반영):
#   ⓐ 위험 포트(22/3306 등) + 0.0.0.0/0·::/0 인 규칙만 대상 → 정상 변경 오회수 방지.
#   ⓑ 처음엔 회수하지 않고 '알림만'(AUTO_REVOKE=false, 드라이런) → 오탐 관찰 후 켠다.
#   ⓒ 예외 태그 AutoRemediate=false 가 붙은 SG 는 건드리지 않음(의도적 개방 허용).
#
# 중복 방지: 새 EventBridge 규칙을 만들지 않고, 기존 security_event_alerts.tf 의
#   aws_cloudwatch_event_rule.sg_rule_changes(SG 규칙 변경 탐지)에 Lambda 타깃만 추가.
#   → 알림(SNS)과 자동대응(Lambda)이 같은 트리거를 공유(룰 중복/요금 중복 없음).
# =========================================================================

# 회수를 실제로 수행할지 토글. 기본 false = 드라이런(알림만).
# 오탐이 없다고 확인되면 true 로 바꿔 apply → 자동 회수 활성화.
variable "sg_auto_revoke_enabled" {
  type        = bool
  default     = false
  description = "true 면 위험 SG 인바운드를 Lambda가 자동 회수, false 면 알림만(드라이런)"
}

# -------------------------------------------------------------------------
# 1. Lambda 소스 패키징 (lambda/sg_auto_remediate/index.py → zip)
# -------------------------------------------------------------------------
data "archive_file" "sg_auto_remediate" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/sg_auto_remediate"
  output_path = "${path.module}/lambda/sg_auto_remediate.zip"
}

# -------------------------------------------------------------------------
# 2. Lambda 실행 IAM 역할 (최소권한)
# -------------------------------------------------------------------------
resource "aws_iam_role" "sg_auto_remediate" {
  name = "${var.project_name}-${var.env}-sg-auto-remediate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-sg-auto-remediate"
  })
}

resource "aws_iam_role_policy" "sg_auto_remediate" {
  name = "${var.project_name}-${var.env}-sg-auto-remediate"
  role = aws_iam_role.sg_auto_remediate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch Logs 기록(이 함수 전용 로그 그룹으로 제한)
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.sg_auto_remediate.arn}:*"
      },
      {
        # SG 조회: Describe* 는 리소스 수준 권한을 지원하지 않아 "*" 불가피(AWS 제약)
        Sid      = "DescribeSecurityGroups"
        Effect   = "Allow"
        Action   = "ec2:DescribeSecurityGroups"
        Resource = "*"
      },
      {
        # 위험 인바운드 회수: 이 계정/리전의 보안그룹으로만 한정
        Sid      = "RevokeIngress"
        Effect   = "Allow"
        Action   = "ec2:RevokeSecurityGroupIngress"
        Resource = "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group/*"
      },
      {
        # 알림 발행: 서울 보안 토픽 1개로만 한정
        Sid      = "Notify"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts_seoul.arn
      }
    ]
  })
}

# -------------------------------------------------------------------------
# 3. 로그 그룹 (보존 30일 — 다른 보안 로그 정책과 통일)
# -------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "sg_auto_remediate" {
  name              = "/aws/lambda/${var.project_name}-${var.env}-sg-auto-remediate"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-sg-auto-remediate"
  })
}

# -------------------------------------------------------------------------
# 4. Lambda 함수
# -------------------------------------------------------------------------
resource "aws_lambda_function" "sg_auto_remediate" {
  function_name = "${var.project_name}-${var.env}-sg-auto-remediate"
  role          = aws_iam_role.sg_auto_remediate.arn
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.sg_auto_remediate.output_path
  source_code_hash = data.archive_file.sg_auto_remediate.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.security_alerts_seoul.arn
      AUTO_REVOKE   = var.sg_auto_revoke_enabled ? "true" : "false"
    }
  }

  # 로그 그룹을 Terraform이 먼저 생성하도록(자동생성 로그그룹과 충돌 방지)
  depends_on = [
    aws_cloudwatch_log_group.sg_auto_remediate,
    aws_iam_role_policy.sg_auto_remediate
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-sg-auto-remediate"
  })
}

# -------------------------------------------------------------------------
# 5. 기존 SG 변경 탐지 규칙(sg_rule_changes)에 Lambda 타깃 추가
#    (security_event_alerts.tf 의 규칙을 재사용 → 별도 룰 생성 안 함)
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_target" "sg_rule_changes_lambda" {
  rule      = aws_cloudwatch_event_rule.sg_rule_changes.name
  target_id = "sg-changes-to-lambda"
  arn       = aws_lambda_function.sg_auto_remediate.arn
}

# EventBridge 규칙이 이 Lambda 를 호출하도록 허용
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sg_auto_remediate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sg_rule_changes.arn
}
