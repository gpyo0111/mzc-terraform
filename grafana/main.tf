resource "aws_iam_role" "grafana_workspace" {
  name = "${var.project}-${var.env}-grafana-workspace-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "grafana.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "grafana_datasource_read" {
  name = "${var.project}-${var.env}-grafana-datasource-read"
  role = aws_iam_role.grafana_workspace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetInsightRuleReport",
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogEvents",
          "logs:DescribeLogStreams",
          "tag:GetResources"
        ]
        Resource = "*"
      },
      {
        Sid    = "PrometheusQuery"
        Effect = "Allow"
        Action = [
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace",
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2ReadForCloudWatchDatasource"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSRead"
        Effect = "Allow"
        Action = [
          "ecs:ListClusters",
          "ecs:DescribeClusters",
          "ecs:ListServices",
          "ecs:DescribeServices",
          "ecs:ListTasks",
          "ecs:DescribeTasks"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_grafana_workspace" "this" {
  name        = "${var.project}-${var.env}-grafana"
  description = "SecureVoice AIOps observability dashboard"

  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"

  role_arn = aws_iam_role.grafana_workspace.arn

  data_sources = [
    "CLOUDWATCH",
    "PROMETHEUS"
  ]

  tags = var.tags
}

resource "aws_grafana_role_association" "admin_users" {
  count = length(var.grafana_admin_user_ids) > 0 ? 1 : 0

  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  user_ids     = var.grafana_admin_user_ids
}

resource "aws_grafana_role_association" "admin_groups" {
  count = length(var.grafana_admin_group_ids) > 0 ? 1 : 0

  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  group_ids    = var.grafana_admin_group_ids
}