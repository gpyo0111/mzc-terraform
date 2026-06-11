resource "aws_sns_topic" "aiops_alerts" {
  name = "${var.project_name}-${var.environment}-aiops-alerts"

  tags = var.tags
}