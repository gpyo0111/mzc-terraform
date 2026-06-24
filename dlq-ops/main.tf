# ─────────────────────────────────────────────────────────────────────────────
# dlq-ops: DLQ 모니터링 및 알림
#
# 20-runtime에서 이미 생성된 free-dlq / paid-dlq를
# data source로 참조하므로, 이 모듈은 독립적으로 apply 가능합니다.
# 20-runtime과 Terraform state가 분리되어 팀 공유 인프라에 영향 없음.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
    Module      = "dlq-ops"
  }
}

# ── 기존 DLQ 큐 참조 (20-runtime에서 생성된 리소스) ─────────────────────────
data "aws_sqs_queue" "free_dlq" {
  name = var.free_dlq_name
}

data "aws_sqs_queue" "paid_dlq" {
  name = var.paid_dlq_name
}

# ── SNS 토픽 — DLQ 알림 채널 ─────────────────────────────────────────────────
resource "aws_sns_topic" "dlq_alert" {
  name = "${var.project_name}-${var.env}-dlq-alert"

  tags = local.common_tags
}

# SNS 이메일 구독 — variables.tf의 dlq_alert_email을 설정하면 활성화
resource "aws_sns_topic_subscription" "dlq_alert_email" {
  count     = var.dlq_alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.dlq_alert.arn
  protocol  = "email"
  endpoint  = var.dlq_alert_email
}

# ── free-dlq 감시 Alarm ───────────────────────────────────────────────────────
# ApproximateNumberOfMessagesVisible > 0: DLQ에 메시지가 1개라도 쌓이면 알림
resource "aws_cloudwatch_metric_alarm" "free_dlq_not_empty" {
  alarm_name          = "${var.project_name}-${var.env}-free-dlq-not-empty"
  alarm_description   = "[ALERT] free-dlq에 처리되지 못한 메시지가 있습니다. 워커 로그를 확인하고 원인 해소 후 redrive.py를 실행하세요."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = data.aws_sqs_queue.free_dlq.name
  }

  alarm_actions = [aws_sns_topic.dlq_alert.arn]
  ok_actions    = [aws_sns_topic.dlq_alert.arn]

  tags = local.common_tags
}

# ── paid-dlq 감시 Alarm ───────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "paid_dlq_not_empty" {
  alarm_name          = "${var.project_name}-${var.env}-paid-dlq-not-empty"
  alarm_description   = "[ALERT] paid-dlq에 처리되지 못한 메시지가 있습니다. 워커 로그를 확인하고 원인 해소 후 redrive.py를 실행하세요."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = data.aws_sqs_queue.paid_dlq.name
  }

  alarm_actions = [aws_sns_topic.dlq_alert.arn]
  ok_actions    = [aws_sns_topic.dlq_alert.arn]

  tags = local.common_tags
}
