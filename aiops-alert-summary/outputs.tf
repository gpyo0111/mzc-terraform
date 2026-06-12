output "alert_summary_lambda_name" {
  value = aws_lambda_function.alert_summary.function_name
}

output "alert_summary_lambda_arn" {
  value = aws_lambda_function.alert_summary.arn
}

output "sns_topic_arn" {
  value = var.aiops_alerts_sns_topic_arn
}