output "grafana_workspace_id" {
  value = aws_grafana_workspace.this.id
}

output "grafana_workspace_endpoint" {
  value = aws_grafana_workspace.this.endpoint
}

output "grafana_workspace_arn" {
  value = aws_grafana_workspace.this.arn
}