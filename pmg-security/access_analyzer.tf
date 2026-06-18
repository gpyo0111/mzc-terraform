# =========================================================================
# [IAM Access Analyzer] 외부 접근 분석기 — 무료·무위험 상시 노출 탐지
#
# 비유: 우리 집(계정)의 모든 문(S3 버킷·IAM 역할·KMS 키 등)을 자동으로 돌며
#       "바깥(외부 계정·퍼블릭 인터넷)에서 열 수 있는 문이 있나?"를 24시간 점검하는 경비원.
#       사람이 매번 권한 정책을 눈으로 검사할 필요 없이, 실수로 외부에 열린 리소스를 자동 발견.
#
# - 종류: 외부 접근 분석기(type=ACCOUNT)만 사용 → 완전 무료.
#         (미사용 권한 분석 $0.20/ID·월, 내부 접근 분석기 $9/리소스·월 → 둘 다 사용 안 함)
# - 범위: 계정 전체(ACCOUNT). 서울 1개 + us-east-1 1개(글로벌 자원 노출도 커버, 둘 다 무료).
# - 알림: 신규 finding(외부 노출 발견)을 EventBridge로 받아 기존 SNS 토픽으로 이메일.
#         (GuardDuty/정책이벤트 알림과 동일 패턴 재사용 → 토픽 정책 이미 events 발행 허용)
# - 위험: 없음(순수 additive, 탐지 전용 — 어떤 리소스도 변경/차단하지 않음).
# =========================================================================

# -------------------------------------------------------------------------
# 1. [서울] 계정 전체 외부 접근 분석기
#    서울 리전 자원(S3 버킷·IAM 역할·KMS 키·SQS·Lambda 등)의 외부 노출을 탐지
# -------------------------------------------------------------------------
resource "aws_accessanalyzer_analyzer" "account_seoul" {
  analyzer_name = "${var.project_name}-${var.env}-account-analyzer"
  type          = "ACCOUNT" # 단일 계정 외부 접근 분석 (조직 단위 아님)

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-account-analyzer"
  })
}

# -------------------------------------------------------------------------
# 2. [us-east-1] 계정 전체 외부 접근 분석기
#    IAM(글로벌)·CloudFront 등 us-east-1에 적재되는 글로벌 자원의 외부 노출까지 탐지 공백 제거
# -------------------------------------------------------------------------
resource "aws_accessanalyzer_analyzer" "account_us_east_1" {
  provider      = aws.us_east_1
  analyzer_name = "${var.project_name}-${var.env}-account-analyzer"
  type          = "ACCOUNT"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-account-analyzer"
  })
}

# =========================================================================
# 3. [알림 배선] Access Analyzer finding → SNS 이메일
#    분석기가 외부 노출을 찾아도 콘솔에만 쌓이면 의미가 없으므로, EventBridge로
#    '신규 활성 finding'만 받아 기존 SNS 토픽으로 실시간 전달합니다.
#
#    status=ACTIVE 만 매칭 → 해소(RESOLVED)된 finding의 재알림 노이즈 차단.
# =========================================================================

# -------------------------------------------------------------------------
# 3-1. [서울] 외부 노출 finding → 서울 토픽 (security_alerts_seoul)
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "access_analyzer_findings_seoul" {
  name        = "${var.project_name}-${var.env}-access-analyzer-findings"
  description = "Route new ACTIVE IAM Access Analyzer findings (Seoul) to SNS"

  event_pattern = jsonencode({
    source        = ["aws.access-analyzer"]
    "detail-type" = ["Access Analyzer Finding"]
    detail = {
      status = ["ACTIVE"]
    }
  })
}

resource "aws_cloudwatch_event_target" "access_analyzer_findings_seoul_sns" {
  rule      = aws_cloudwatch_event_rule.access_analyzer_findings_seoul.name
  target_id = "access-analyzer-to-sns-seoul"
  arn       = aws_sns_topic.security_alerts_seoul.arn
}

# -------------------------------------------------------------------------
# 3-2. [us-east-1] 글로벌 자원 외부 노출 finding → 기존 us-east-1 토픽 (security_alerts)
#      기존 WAF/GuardDuty용 토픽 재사용(추가 이메일 확인 불필요).
#      토픽 정책은 guardduty_security.tf에서 events 발행을 이미 허용함.
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "access_analyzer_findings_us_east_1" {
  provider    = aws.us_east_1
  name        = "${var.project_name}-${var.env}-access-analyzer-findings"
  description = "Route new ACTIVE IAM Access Analyzer findings (us-east-1) to SNS"

  event_pattern = jsonencode({
    source        = ["aws.access-analyzer"]
    "detail-type" = ["Access Analyzer Finding"]
    detail = {
      status = ["ACTIVE"]
    }
  })
}

resource "aws_cloudwatch_event_target" "access_analyzer_findings_us_east_1_sns" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.access_analyzer_findings_us_east_1.name
  target_id = "access-analyzer-to-sns-us-east-1"
  arn       = aws_sns_topic.security_alerts.arn
}
