#################################################
# Runtime VPC Endpoints for ECS Fargate
# - ECR API
# - ECR DKR
# - CloudWatch Logs
# - Secrets Manager
# - STS
#################################################

resource "aws_security_group" "runtime_vpce" {
  name        = "${var.project_name}-${var.env}-runtime-vpce-sg"
  description = "Security group for runtime interface endpoints"
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

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-runtime-vpce-sg"
  })
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-ecr-api-endpoint"
  })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-ecr-dkr-endpoint"
  })
}

resource "aws_vpc_endpoint" "logs" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-logs-endpoint"
  })
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-secretsmanager-endpoint"
  })
}

resource "aws_vpc_endpoint" "sts" {
  vpc_id              = data.aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  security_group_ids  = [aws_security_group.runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-sts-endpoint"
  })
}