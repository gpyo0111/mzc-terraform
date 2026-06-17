# =========================================================================
# 1. 서울 리전(ap-northeast-2) 메인 컴퓨팅 인프라용 지능형 GuardDuty 가동
# =========================================================================
resource "aws_guardduty_detector" "seoul_detector" {
  enable = true # AI 위협 탐지 엔진을 활성화합니다.

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-seoul-guardduty"
  })
}

# [최신 문법] S3 보호 기능을 별도 리소스로 분리합니다.
# (구 datasources { s3_logs } 블록은 provider v5에서 deprecated → detector_feature로 대체)
resource "aws_guardduty_detector_feature" "seoul_s3" {
  detector_id = aws_guardduty_detector.seoul_detector.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

# =========================================================================
# 2. 글로벌 에지(us-east-1) WAF/CloudFront 레이어 감시를 위한 GuardDuty 확장
# =========================================================================
resource "aws_guardduty_detector" "us_east_1_detector" {
  # WAF/CloudFront 및 글로벌 서비스(IAM 등) 이벤트가 us-east-1에 적재되므로 해당 리전에도 탐지기를 둡니다.
  provider = aws.us_east_1
  enable   = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-us-east-1-guardduty"
  })
}

resource "aws_guardduty_detector_feature" "us_east_1_s3" {
  provider    = aws.us_east_1
  detector_id = aws_guardduty_detector.us_east_1_detector.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

# =========================================================================
# 3. [알림 배선] 서울 리전 GuardDuty 위협 탐지(finding) → SNS 이메일 알림
#    GuardDuty가 위협을 잡아도 콘솔에만 쌓이면 의미가 없으므로, EventBridge로
#    finding을 받아 SNS 이메일로 실시간 전달합니다.
# =========================================================================

# 서울 리전 전용 보안 알림 SNS 토픽 (us-east-1 WAF용 토픽은 monitoring_alerts.tf에 별도 존재)
resource "aws_sns_topic" "security_alerts_seoul" {
  name = "${var.project_name}-${var.env}-security-alerts-seoul"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-security-alerts-seoul"
  })
}

resource "aws_sns_topic_subscription" "security_alerts_seoul_email" {
  topic_arn = aws_sns_topic.security_alerts_seoul.arn
  protocol  = "email"
  endpoint  = var.security_alert_email # variables.tf에서 관리하는 담당자 이메일
}

# EventBridge(events.amazonaws.com)가 이 토픽에 메시지를 발행할 수 있도록 허용하는 정책
resource "aws_sns_topic_policy" "security_alerts_seoul" {
  arn = aws_sns_topic.security_alerts_seoul.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts_seoul.arn
      }
    ]
  })
}

# GuardDuty finding 중 severity 4.0 이상(Medium/High)만 라우팅 → Low 등급 노이즈 차단
# (GuardDuty severity: Low 1.0~3.9 / Medium 4.0~6.9 / High 7.0~8.9)
resource "aws_cloudwatch_event_rule" "guardduty_findings_seoul" {
  name        = "${var.project_name}-${var.env}-guardduty-findings"
  description = "Route Medium+ GuardDuty findings (Seoul) to SNS"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_findings_seoul_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings_seoul.name
  target_id = "guardduty-to-sns-seoul"
  arn       = aws_sns_topic.security_alerts_seoul.arn
}

# =========================================================================
# 4. [알림 배선] us-east-1 GuardDuty 위협 탐지(finding) → SNS 이메일 알림
#    글로벌 서비스(IAM/STS/CloudFront 등) 위협은 us-east-1에 적재되므로,
#    이 리전 finding도 반드시 알림으로 받아야 탐지 공백이 없습니다.
#    기존 WAF용 SNS 토픽(monitoring_alerts.tf)을 재사용합니다(추가 이메일 확인 불필요).
# =========================================================================

# 기존 토픽에 EventBridge 발행 권한을 추가.
# [중요] 명시적 정책은 AWS 기본 정책을 덮어쓰므로, 기존 WAF 알람 발행이 깨지지 않도록
#        '계정 소유자 기본 권한' statement를 반드시 함께 유지합니다.
resource "aws_sns_topic_policy" "security_alerts_us_east_1" {
  provider = aws.us_east_1
  arn      = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 기존 기본 정책 보존: 계정 소유자(이 계정의 CloudWatch WAF 알람 포함)의 발행/관리 허용
        Sid       = "__default_statement_ID"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes",
          "SNS:AddPermission",
          "SNS:RemovePermission",
          "SNS:DeleteTopic",
          "SNS:Subscribe",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish"
        ]
        Resource  = aws_sns_topic.security_alerts.arn
        Condition = { StringEquals = { "AWS:SourceOwner" = var.account_id } }
      },
      {
        # 신규: EventBridge가 GuardDuty finding을 이 토픽으로 발행하도록 허용
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "guardduty_findings_us_east_1" {
  provider    = aws.us_east_1
  name        = "${var.project_name}-${var.env}-guardduty-findings"
  description = "Route Medium+ GuardDuty findings (us-east-1) to SNS"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_findings_us_east_1_sns" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.guardduty_findings_us_east_1.name
  target_id = "guardduty-to-sns-us-east-1"
  arn       = aws_sns_topic.security_alerts.arn
}