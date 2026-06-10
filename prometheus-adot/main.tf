data "aws_caller_identity" "current" {}

resource "aws_prometheus_workspace" "this" {
  alias = "${var.project}-${var.env}-amp"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-amp"
  })
}

locals {
  amp_remote_write_endpoint = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"

  api_adot_config = templatefile("${path.module}/templates/adot-config.yaml.tftpl", {
    aws_region           = var.aws_region
    amp_remote_write_url = local.amp_remote_write_endpoint
    scrape_job_name      = "${var.project}-${var.env}-api"
    scrape_target        = "127.0.0.1:${var.api_metrics_port}"
    scrape_interval      = var.scrape_interval
    service_name         = "api-service"
    project              = var.project
    env                  = var.env
    queue_type           = "api"
    metrics_path         = "/metrics"
  })

  free_worker_adot_config = templatefile("${path.module}/templates/adot-config.yaml.tftpl", {
    aws_region           = var.aws_region
    amp_remote_write_url = local.amp_remote_write_endpoint
    scrape_job_name      = "${var.project}-${var.env}-free-worker"
    scrape_target        = "127.0.0.1:${var.worker_metrics_port}"
    scrape_interval      = var.scrape_interval
    service_name         = "free-worker"
    project              = var.project
    env                  = var.env
    queue_type           = "free"
    metrics_path         = "/metrics"
  })

  paid_worker_adot_config = templatefile("${path.module}/templates/adot-config.yaml.tftpl", {
    aws_region           = var.aws_region
    amp_remote_write_url = local.amp_remote_write_endpoint
    scrape_job_name      = "${var.project}-${var.env}-paid-worker"
    scrape_target        = "127.0.0.1:${var.worker_metrics_port}"
    scrape_interval      = var.scrape_interval
    service_name         = "paid-worker"
    project              = var.project
    env                  = var.env
    queue_type           = "paid"
    metrics_path         = "/metrics"
  })
}

resource "aws_ssm_parameter" "api_adot_config" {
  name        = "/${var.project}/${var.env}/adot/api-config"
  description = "ADOT Collector config for SecureVoice API Service"
  type        = "String"
  value       = local.api_adot_config

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-api-adot-config"
  })
}

resource "aws_ssm_parameter" "free_worker_adot_config" {
  name        = "/${var.project}/${var.env}/adot/free-worker-config"
  description = "ADOT Collector config for SecureVoice Free Worker"
  type        = "String"
  value       = local.free_worker_adot_config

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-free-worker-adot-config"
  })
}

resource "aws_ssm_parameter" "paid_worker_adot_config" {
  name        = "/${var.project}/${var.env}/adot/paid-worker-config"
  description = "ADOT Collector config for SecureVoice Paid Worker"
  type        = "String"
  value       = local.paid_worker_adot_config

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-paid-worker-adot-config"
  })
}

resource "aws_iam_policy" "adot_ssm_read" {
  name        = "${var.project}-${var.env}-adot-ssm-read"
  description = "Allow ECS task execution role to read ADOT Collector config from SSM Parameter Store"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          aws_ssm_parameter.api_adot_config.arn,
          aws_ssm_parameter.free_worker_adot_config.arn,
          aws_ssm_parameter.paid_worker_adot_config.arn
        ]
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_ssm_read" {
  count      = var.ecs_task_execution_role_name != "" ? 1 : 0
  role       = var.ecs_task_execution_role_name
  policy_arn = aws_iam_policy.adot_ssm_read.arn
}

resource "aws_iam_role_policy_attachment" "api_amp_remote_write" {
  count      = var.api_task_role_name != "" ? 1 : 0
  role       = var.api_task_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
}

resource "aws_iam_role_policy_attachment" "worker_amp_remote_write" {
  count      = var.worker_task_role_name != "" ? 1 : 0
  role       = var.worker_task_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
}