# =========================================================================
# [고위험 정책 이벤트 알림] EventBridge → SNS
#
# GuardDuty(미지/행동 기반 탐지)와 별개로, "발생 즉시 사람이 알아야 하는"
# 명확한 정책성 행동을 CloudTrail 이벤트에서 직접 매칭해 알림을 보냅니다.
#
# - 전제: 멀티리전 CloudTrail이 활성화돼 있어야 함(monitoring_security.tf) → 관리 이벤트가
#         각 리전 EventBridge 기본 버스로 자동 전달됨. CloudWatch Logs 수집 없이 동작(저비용).
# - 리전 배치: 글로벌 서비스(IAM/STS/Root)는 us-east-1, 리전 자원(EC2 SG/CloudTrail)은 서울.
# - SNS 토픽은 guardduty_security.tf의 토픽을 재사용(두 토픽 모두 events 발행 허용 정책 보유).
# =========================================================================

# -------------------------------------------------------------------------
# 1. [us-east-1] 루트 계정 사용 탐지 (로그인 + API 호출)
#    루트는 평소 거의 사용되지 않아야 정상 → 사용 자체가 고신호 경보
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "root_account_usage" {
  provider    = aws.us_east_1
  name        = "${var.project_name}-${var.env}-root-account-usage"
  description = "Alert on any root account sign-in or API activity"

  event_pattern = jsonencode({
    "detail-type" = [
      "AWS Console Sign In via CloudTrail",
      "AWS API Call via CloudTrail"
    ]
    detail = {
      userIdentity = {
        type = ["Root"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "root_account_usage_sns" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.root_account_usage.name
  target_id = "root-usage-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# -------------------------------------------------------------------------
# 2. [us-east-1] IAM 민감 변경 탐지 (권한 탈취 / 백도어 계정·키 생성 징후)
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "iam_sensitive_changes" {
  provider    = aws.us_east_1
  name        = "${var.project_name}-${var.env}-iam-sensitive-changes"
  description = "Alert on sensitive IAM mutations (users, keys, policy attachments)"

  event_pattern = jsonencode({
    source        = ["aws.iam"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        "CreateUser",
        "DeleteUser",
        "CreateAccessKey",
        "CreateLoginProfile",
        "UpdateLoginProfile",
        "AttachUserPolicy",
        "AttachRolePolicy",
        "PutUserPolicy",
        "PutRolePolicy",
        "DeactivateMFADevice"
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "iam_sensitive_changes_sns" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.iam_sensitive_changes.name
  target_id = "iam-changes-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# -------------------------------------------------------------------------
# 3. [서울] 보안그룹 인바운드/아웃바운드 규칙 변경 탐지 (방화벽 구멍 뚫기 징후)
#    참고: 특정 0.0.0.0/0 값까지 패턴으로 정밀 매칭하긴 까다로워, SG 규칙 변경 행위 자체를
#         알림 → 사람이 검토하는 방식(현업에서 흔한 안전한 기본값).
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "sg_rule_changes" {
  name        = "${var.project_name}-${var.env}-sg-rule-changes"
  description = "Alert on security group rule authorizations (potential firewall opening)"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        "AuthorizeSecurityGroupIngress",
        "AuthorizeSecurityGroupEgress"
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "sg_rule_changes_sns" {
  rule      = aws_cloudwatch_event_rule.sg_rule_changes.name
  target_id = "sg-changes-to-sns"
  arn       = aws_sns_topic.security_alerts_seoul.arn
}

# -------------------------------------------------------------------------
# 4. [서울] CloudTrail 변조 탐지 (감사 로그 끄기/삭제 = 공격 은폐 시도)
# -------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "cloudtrail_tampering" {
  name        = "${var.project_name}-${var.env}-cloudtrail-tampering"
  description = "Alert on CloudTrail disable/delete/modify attempts"

  event_pattern = jsonencode({
    source        = ["aws.cloudtrail"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        "StopLogging",
        "DeleteTrail",
        "UpdateTrail",
        "PutEventSelectors"
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "cloudtrail_tampering_sns" {
  rule      = aws_cloudwatch_event_rule.cloudtrail_tampering.name
  target_id = "cloudtrail-tamper-to-sns"
  arn       = aws_sns_topic.security_alerts_seoul.arn
}
