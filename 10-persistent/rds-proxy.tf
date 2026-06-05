resource "aws_security_group" "rds_proxy" {
  name        = "${var.project_name}-${var.env}-rds-proxy-sg"
  description = "RDS Proxy security group"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "MySQL from private app subnets"
    from_port   = 3306
    to_port     = 3306
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
    Name        = "${var.project_name}-${var.env}-rds-proxy-sg"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_iam_role" "rds_proxy" {
  name = "${var.project_name}-${var.env}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_iam_policy" "rds_proxy_secrets" {
  name = "${var.project_name}-${var.env}-rds-proxy-secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.db_password.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_proxy_secrets" {
  role       = aws_iam_role.rds_proxy.name
  policy_arn = aws_iam_policy.rds_proxy_secrets.arn
}

resource "aws_db_proxy" "mysql" {
  name                   = "${var.project_name}-${var.env}-mysql-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]

  idle_client_timeout = 1800
  require_tls         = false

  auth {
    auth_scheme               = "SECRETS"
    secret_arn                = aws_secretsmanager_secret.db_password.arn
    iam_auth                  = "DISABLED"
    client_password_auth_type = "MYSQL_NATIVE_PASSWORD"
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-mysql-proxy"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_db_proxy_default_target_group" "mysql" {
  db_proxy_name = aws_db_proxy.mysql.name

  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 90
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "mysql" {
  db_proxy_name          = aws_db_proxy.mysql.name
  target_group_name      = aws_db_proxy_default_target_group.mysql.name
  db_instance_identifier = aws_db_instance.mysql.identifier
}
