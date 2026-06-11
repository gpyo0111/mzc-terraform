output "aiops_alerts_sns_topic_arn" {
  description = "SNS Topic ARN for SecureVoice AIOps alerts"
  value       = aws_sns_topic.aiops_alerts.arn
}

output "chatbot_slack_channel_configuration_arn" {
  description = "Amazon Q Developer Slack channel configuration ARN"
  value       = aws_chatbot_slack_channel_configuration.aiops_alerts.chat_configuration_arn
}