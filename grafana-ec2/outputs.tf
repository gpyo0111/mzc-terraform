output "grafana_instance_id" {
  value = aws_instance.grafana.id
}

output "grafana_private_ip" {
  value = aws_instance.grafana.private_ip
}

output "grafana_local_url" {
  value = "http://localhost:3000"
}

output "grafana_admin_user" {
  value = var.grafana_admin_user
}

output "grafana_admin_password_secret_arn" {
  value = aws_secretsmanager_secret.grafana_admin_password.arn
}

output "grafana_admin_password_read_command" {
  value = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.grafana_admin_password.arn} --profile ${var.aws_profile} --region ${var.aws_region} --query SecretString --output text"
}

output "grafana_ssm_port_forward_command" {
  value = "aws ssm start-session --target ${aws_instance.grafana.id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"3000\"]}' --profile ${var.aws_profile} --region ${var.aws_region}"
}