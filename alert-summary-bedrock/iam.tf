data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "bedrock_summary_lambda_role" {
  name               = "${var.project_name}-${var.environment}-aiops-bedrock-summary-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "bedrock_summary_lambda_policy" {
  statement {
    sid    = "WriteLambdaLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ReadOperationalState"
    effect = "Allow"

    actions = [
      "ecs:DescribeServices",
      "sqs:GetQueueAttributes",
      "cloudwatch:GetMetricStatistics",
      "application-autoscaling:DescribeScalingActivities",
      "logs:FilterLogEvents"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ReadSlackWebhookSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue"
    ]

    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.slack_webhook_secret_name}*"
    ]
  }

  statement {
    sid    = "InvokeBedrockModel"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "bedrock_summary_lambda_policy" {
  name   = "${var.project_name}-${var.environment}-aiops-bedrock-summary-lambda-policy"
  policy = data.aws_iam_policy_document.bedrock_summary_lambda_policy.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "bedrock_summary_lambda_policy_attach" {
  role       = aws_iam_role.bedrock_summary_lambda_role.name
  policy_arn = aws_iam_policy.bedrock_summary_lambda_policy.arn
}