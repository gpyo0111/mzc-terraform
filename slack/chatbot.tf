resource "aws_chatbot_slack_channel_configuration" "aiops_alerts" {
  configuration_name = "${var.project_name}-${var.environment}-aiops-alerts"

  iam_role_arn    = aws_iam_role.chatbot_role.arn
  slack_team_id   = var.slack_team_id
  slack_channel_id = var.slack_channel_id

  sns_topic_arns = [
    aws_sns_topic.aiops_alerts.arn
  ]

  logging_level = "ERROR"

  guardrail_policy_arns = [
    "arn:aws:iam::aws:policy/ReadOnlyAccess"
  ]

  tags = var.tags
}