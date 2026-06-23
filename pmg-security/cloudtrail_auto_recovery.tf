# =========================================================================
# [자동복구 / Self-Healing] CloudTrail 정지·삭제 → Lambda 자동복구 + 알림
#
# 비유: 누가 CCTV 녹화기(CloudTrail)를 꺼버리거나 떼어가면, 경비원(Lambda)이
#       즉시 다시 켜거나(StopLogging) 같은 자리에 새로 설치(DeleteTrail)하고 보고(SNS).
#
# 안전 설계(SG Lambda 와 동일 철학):
#   ⓐ 끄기(StopLogging)·삭제(DeleteTrail) 만 자동복구. 정상 변경과 헷갈리는
#      UpdateTrail/PutEventSelectors 는 건드리지 않음(알림만) → Terraform 변경과 충돌 방지.
#   ⓑ 처음엔 복구하지 않고 '알림만'(CT_AUTO_RECOVER=false, 드라이런) → 오작동 관찰 후 켠다.
#   ⓒ 우리 트레일(securevoice-dev-trail)만 대상.
#
# 중복 방지: 새 EventBridge 규칙을 만들지 않고, security_event_alerts.tf 의
#   aws_cloudwatch_event_rule.cloudtrail_tampering(StopLogging/DeleteTrail/Update/PutEventSelectors
#   탐지)에 Lambda 타깃만 추가. → 알림(SNS)과 자동복구(Lambda)가 같은 트리거 공유.
# =========================================================================

# 복구를 실제로 수행할지 토글. 기본 false = 드라이런(알림만).
variable "cloudtrail_auto_recover_enabled" {
  type        = bool
  default     = false
  description = "true 면 CloudTrail 정지/삭제 시 Lambda 가 자동 복구, false 면 알림만(드라이런)"
}

# -------------------------------------------------------------------------
# 1. Lambda 소스 패키징
# -------------------------------------------------------------------------
data "archive_file" "cloudtrail_auto_recover" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/cloudtrail_auto_recover"
  output_path = "${path.module}/lambda/cloudtrail_auto_recover.zip"
}

# -------------------------------------------------------------------------
# 2. Lambda 실행 IAM 역할 (최소권한)
# -------------------------------------------------------------------------
resource "aws_iam_role" "cloudtrail_auto_recover" {
  name = "${var.project_name}-${var.env}-cloudtrail-auto-recover"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-cloudtrail-auto-recover"
  })
}

resource "aws_iam_role_policy" "cloudtrail_auto_recover" {
  name = "${var.project_name}-${var.env}-cloudtrail-auto-recover"
  role = aws_iam_role.cloudtrail_auto_recover.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail_auto_recover.arn}:*"
      },
      {
        # 우리 트레일(이름 고정 → ARN 결정적)로만 한정: 재가동/재생성/데이터이벤트 재적용
        Sid    = "RecoverOurTrail"
        Effect = "Allow"
        Action = [
          "cloudtrail:StartLogging",
          "cloudtrail:CreateTrail",
          "cloudtrail:PutEventSelectors"
        ]
        Resource = aws_cloudtrail.main.arn
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
resource "aws_cloudwatch_log_group" "cloudtrail_auto_recover" {
  name              = "/aws/lambda/${var.project_name}-${var.env}-cloudtrail-auto-recover"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-cloudtrail-auto-recover"
  })
}

# -------------------------------------------------------------------------
# 4. Lambda 함수
#    재생성에 필요한 '원래 설정'을 트레일 실제 속성에서 주입 → 코드/실물 항상 일치.
# -------------------------------------------------------------------------
resource "aws_lambda_function" "cloudtrail_auto_recover" {
  function_name = "${var.project_name}-${var.env}-cloudtrail-auto-recover"
  role          = aws_iam_role.cloudtrail_auto_recover.arn
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.cloudtrail_auto_recover.output_path
  source_code_hash = data.archive_file.cloudtrail_auto_recover.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN     = aws_sns_topic.security_alerts_seoul.arn
      AUTO_RECOVER      = var.cloudtrail_auto_recover_enabled ? "true" : "false"
      TRAIL_NAME        = aws_cloudtrail.main.name
      S3_BUCKET         = aws_cloudtrail.main.s3_bucket_name
      IS_MULTI_REGION   = tostring(aws_cloudtrail.main.is_multi_region_trail)
      INCLUDE_GLOBAL    = tostring(aws_cloudtrail.main.include_global_service_events)
      ENABLE_VALIDATION = tostring(aws_cloudtrail.main.enable_log_file_validation)
      # 삭제 후 재생성 시 audio uploads/ 데이터이벤트도 원복(monitoring_security.tf 와 동일 값)
      DATA_RESOURCE_ARN = "${data.aws_s3_bucket.audio.arn}/uploads/"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.cloudtrail_auto_recover,
    aws_iam_role_policy.cloudtrail_auto_recover
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-cloudtrail-auto-recover"
  })
}

# -------------------------------------------------------------------------
# 5. 기존 CloudTrail 변조 탐지 규칙(cloudtrail_tampering)에 Lambda 타깃 추가
#    (security_event_alerts.tf 의 규칙 재사용 → 별도 룰 생성 안 함)
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_target" "cloudtrail_tampering_lambda" {
  rule      = aws_cloudwatch_event_rule.cloudtrail_tampering.name
  target_id = "cloudtrail-tamper-to-lambda"
  arn       = aws_lambda_function.cloudtrail_auto_recover.arn
}

resource "aws_lambda_permission" "allow_eventbridge_cloudtrail" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cloudtrail_auto_recover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cloudtrail_tampering.arn
}
