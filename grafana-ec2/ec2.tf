resource "aws_instance" "grafana" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.terraform_remote_state.network.outputs.private_app_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.grafana_ec2.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.grafana_ec2.name

  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region                        = var.aws_region
    amp_workspace_id                  = var.amp_workspace_id
    grafana_image                     = var.grafana_image
    grafana_admin_user                = var.grafana_admin_user
    grafana_admin_password_secret_arn = aws_secretsmanager_secret.grafana_admin_password.arn
  })

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.env}-grafana-ec2"
  })
}