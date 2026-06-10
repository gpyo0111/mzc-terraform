# =========================================================================
# 1. 비상 보안 알림을 전송할 AWS SNS 토픽(보안 방송국) 엔티티 생성
# =========================================================================
resource "aws_sns_topic" "security_alerts" {
  name         = "${var.project_name}-${var.env}-security-alerts-topic" # AWS 콘솔에서 식별될 알림 허브의 고유 명칭입니다.
  display_name = "SecureVoice SecOps Alerts"                           # 실제 이메일이나 알림 수신 시 발신자명에 표기될 타이틀입니다.

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# =========================================================================
# 2. 생성한 보안 방송국에 담당자 이메일 수신처 결합 (Subscription)
# =========================================================================
resource "aws_sns_topic_subscription" "security_email_subscription" {
  topic_arn = aws_sns_topic.security_alerts.arn # 알림을 발송할 상위 SNS 토픽의 고유 ARN 주소를 매핑합니다.
  protocol  = "email"                           # 알림 전달 매개체 프로토콜을 이메일 사양으로 지정합니다. (슬랙 연동 시엔 https 활용)
  endpoint  = "your-team-security@example.com"  # 중요: 알림을 직접 수신할 본인 또는 팀의 실제 이메일 주소로 수정하셔야 합니다.
}

# =========================================================================
# 3. [WAF 디도스 차단 감시] 임계치 초과 시 비상벨을 울릴 CloudWatch 경보 선언
# =========================================================================
resource "aws_cloudwatch_metric_alarm" "waf_ddos_blocked_alarm" {
  alarm_name          = "${var.project_name}-${var.env}-waf-ddos-blocked-alarm" # 클라우드워치 대시보드에 표기될 비상 경보의 명칭입니다.
  comparison_operator = "GreaterThanThreshold"                                  # 실시간 지표 수치가 설정한 임계치보다 '클 때' 경보를 발동하도록 지정합니다.
  evaluation_periods  = 1                                                       # 연속해서 몇 번 검사 기한 동안 임계치를 넘었는지 판단하는 기준 회수입니다.
  metric_name         = "DDoSRateLimitMetric"                                   # 중요: 앞서 waf.tf에 심어둔 디도스 차단 규칙의 정확한 메트릭 지표명을 바라보게 합니다.
  namespace           = "AWS/WAFV2"                                             # AWS WAFv2 서비스 고유의 지표 수집 그룹 대역(Namespace)을 지정합니다.
  period              = 300                                                     # 지표 데이터를 묶어서 연산할 타임라인 단위를 5분(300초)으로 설정합니다.
  statistic           = "Sum"                                                   # 5분 동안 발생한 전체 차단 건수의 '총합(Sum)'을 계산 기준으로 삼습니다.
  threshold           = 0                                                       # 임계치를 0으로 두어, 단 1건의 디도스 IP 차단 패킷만 발생해도 즉시 비상 상황으로 간주합니다.
  alarm_description   = "This alarm triggers immediately when the Custom WAF Rate-Limit rule blocks malicious DDoS traffic at the CloudFront Edge."

  # 알림을 보낼 대상 행동(Action) 정의: 평온 상태에서 경보(ALARM) 상태로 전환되는 즉시 실행
  alarm_actions = [
    aws_sns_topic.security_alerts.arn # 위 1번 단계에서 개국한 보안 비상 방송국(SNS ARN)으로 경보 메타데이터 패킷을 다이렉트 전송합니다.
  ]

  dimensions = {
    WebACL = "securevoice-dev-waf" # 감시할 타깃 WAF Web ACL의 물리적 명칭을 정확히 조준합니다.
    Region = "us-east-1"           # CloudFront용 글로벌 WAF는 무조건 us-east-1 리전 메트릭으로 수집되므로 버지니아 대역을 명시합니다.
    Rule   = "DDoS-Rate-Limit-Rule" # Web ACL 내부에 들어있는 수많은 규칙 중 '디도스 차단 규칙'의 이름과 매핑합니다.
  }
}