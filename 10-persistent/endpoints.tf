#################################################
# Persistent VPC Endpoints
# - S3 Gateway
# - SSM for DB Admin EC2
# - Secrets Manager for DB bootstrap and admin tasks
#################################################

resource "aws_security_group" "persistent_vpce" {
  name        = "${var.project_name}-${var.env}-persistent-vpce-sg"
  description = "Security group for persistent interface endpoints"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "HTTPS from private app subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = data.terraform_remote_state.network.outputs.private_app_subnet_cidrs
  }

  egress {
    description = "All outbound inside VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-persistent-vpce-sg"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    data.terraform_remote_state.network.outputs.private_app_route_table_id
  ]

  tags = {
    Name        = "${var.project_name}-${var.env}-s3-gateway-endpoint"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.persistent_vpce.id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.project_name}-${var.env}-ssm-endpoint"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.persistent_vpce.id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.project_name}-${var.env}-ec2messages-endpoint"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.persistent_vpce.id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.project_name}-${var.env}-ssmmessages-endpoint"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.persistent_vpce.id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.project_name}-${var.env}-secretsmanager-endpoint"
    Project     = var.project_name
    Environment = var.env
  }
}
