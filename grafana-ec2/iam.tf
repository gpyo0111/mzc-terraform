resource "aws_iam_role" "grafana_ec2" {
  name = "${var.project_name}-${var.env}-grafana-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "grafana_datasource_read" {
  name = "${var.project_name}-${var.env}-grafana-datasource-read"
  role = aws_iam_role.grafana_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:GetInsightRuleReport",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",

          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:GetLogGroupFields",
          "logs:GetQueryResults",
          "logs:StartQuery",
          "logs:StopQuery",

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
      },
      {
        Sid    = "EC2Read"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadGrafanaAdminPassword"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.grafana_admin_password.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.grafana_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "grafana_ec2" {
  name = "${var.project_name}-${var.env}-grafana-ec2-profile"
  role = aws_iam_role.grafana_ec2.name
}