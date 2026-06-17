# =========================================================================
# 1. 비상 보안 알림을 전송할 AWS SNS 토픽(보안 방송국) 엔티티 생성
# =========================================================================
resource "aws_sns_topic" "security_alerts" {
  provider = aws.us_east_1

  name         = "${var.project_name}-${var.env}-security-alerts-topic" # AWS 콘솔에서 식별될 알림 허브의 고유 명칭입니다.
  display_name = "SecureVoice SecOps Alerts"                            # 실제 이메일이나 알림 수신 시 발신자명에 표기될 타이틀입니다.

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# =========================================================================
# 2. 생성한 보안 방송국에 담당자 이메일 수신처 결합 (Subscription)
# =========================================================================
resource "aws_sns_topic_subscription" "security_email_subscription" {
  provider = aws.us_east_1

  topic_arn = aws_sns_topic.security_alerts.arn # 알림을 발송할 상위 SNS 토픽의 고유 ARN 주소를 매핑합니다.
  protocol  = "email"                           # 알림 전달 매개체 프로토콜을 이메일 사양으로 지정합니다. (슬랙 연동 시엔 https 활용)
  endpoint  = var.security_alert_email          # 담당자 이메일은 variables.tf의 security_alert_email 변수로 관리합니다.
}

# =========================================================================
# [Tuning] 5대 마스터 규칙 중 단 1건이라도 차단 발생 시 비상벨을 울릴 통합 경보
# =========================================================================
resource "aws_cloudwatch_metric_alarm" "waf_any_blocked_alarm" {
  provider            = aws.us_east_1
  alarm_name          = "${var.project_name}-${var.env}-waf-any-blocked-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1

  # [리팩토링 핵심 1]: 특정 규칙명이 아닌, Web ACL 전체의 '차단된 요청 총합' 메트릭을 조준합니다.
  metric_name       = "BlockedRequests"
  namespace         = "AWS/WAFV2"
  period            = 300
  statistic         = "Sum"
  threshold         = 0
  alarm_description = "This alarm triggers immediately when ANY of the 5 Master WAF rules blocks malicious traffic at the CloudFront Edge."

  alarm_actions = [
    aws_sns_topic.security_alerts.arn
  ]

  # [리팩토링 핵심 2]: 특정 Rule 차원을 삭제하여 Web ACL 전체 통계령을 발동합니다.
  dimensions = {
    WebACL = "securevoice-dev-waf"
    Region = "us-east-1" # CloudFront 글로벌 메트릭 수집을 위해 us-east-1 고정
  }
}