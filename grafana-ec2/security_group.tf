resource "aws_security_group" "grafana_ec2" {
  name        = "${var.project_name}-${var.env}-grafana-ec2-sg"
  description = "Security group for private Grafana EC2 accessed through SSM port forwarding"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  egress {
    description = "All outbound for Docker pull, AMP, CloudWatch, Secrets Manager, SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.env}-grafana-ec2-sg"
  })
}