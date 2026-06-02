resource "aws_cloudwatch_dashboard" "aiops" {
  dashboard_name = "securevoice-aiops-observability"
  dashboard_body = file("${path.module}/dashboards/securevoice-aiops-dashboard.json")
}
