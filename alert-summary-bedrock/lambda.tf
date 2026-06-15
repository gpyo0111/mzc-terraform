data "archive_file" "bedrock_summary_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_src/bedrock_summary.py"
  output_path = "${path.module}/lambda_src/bedrock_summary.zip"
}

resource "aws_lambda_function" "bedrock_summary" {
  function_name = "${var.project_name}-${var.environment}-aiops-bedrock-summary"

  role    = aws_iam_role.bedrock_summary_lambda_role.arn
  handler = "bedrock_summary.lambda_handler"
  runtime = "python3.12"

  filename         = data.archive_file.bedrock_summary_zip.output_path
  source_code_hash = data.archive_file.bedrock_summary_zip.output_base64sha256

  timeout     = 45
  memory_size = 256

  environment {
    variables = {
      AWS_REGION_NAME            = var.aws_region
      CLUSTER_NAME               = var.cluster_name
      PAID_WORKER_SERVICE_NAME   = var.paid_worker_service_name
      FREE_WORKER_SERVICE_NAME   = var.free_worker_service_name
      PAID_QUEUE_URL             = var.paid_queue_url
      FREE_QUEUE_URL             = var.free_queue_url
      PAID_WORKER_LOG_GROUP_NAME = var.paid_worker_log_group_name
      FREE_WORKER_LOG_GROUP_NAME = var.free_worker_log_group_name
      SLACK_WEBHOOK_SECRET_NAME  = var.slack_webhook_secret_name
      RUNBOOK_BASE_URL           = var.runbook_base_url
      BEDROCK_MODEL_ID           = var.bedrock_model_id
    }
  }

  tags = var.tags
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromAIOpsAlertsSNSForBedrock"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bedrock_summary.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.aiops_alerts_sns_topic_arn
}

resource "aws_sns_topic_subscription" "bedrock_summary_lambda" {
  topic_arn = var.aiops_alerts_sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.bedrock_summary.arn

  depends_on = [
    aws_lambda_permission.allow_sns
  ]
}