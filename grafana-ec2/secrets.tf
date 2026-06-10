resource "random_password" "grafana_admin" {
  length           = 24
  special          = true
  override_special = "!@#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "grafana_admin_password" {
  name        = "${var.project_name}/${var.env}/grafana-ec2/admin-password"
  description = "Admin password for self-hosted Grafana EC2"

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "grafana_admin_password" {
  secret_id     = aws_secretsmanager_secret.grafana_admin_password.id
  secret_string = random_password.grafana_admin.result
}