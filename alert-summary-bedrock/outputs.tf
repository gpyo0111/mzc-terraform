output "bedrock_summary_lambda_name" {
  value = aws_lambda_function.bedrock_summary.function_name
}

output "bedrock_summary_lambda_arn" {
  value = aws_lambda_function.bedrock_summary.arn
}

output "bedrock_model_id" {
  value = var.bedrock_model_id
}

output "sns_topic_arn" {
  value = var.aiops_alerts_sns_topic_arn
}