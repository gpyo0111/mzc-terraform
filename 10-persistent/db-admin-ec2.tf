#################################################
# DB ADMIN EC2 (SSM ONLY)
#################################################

data "aws_ami" "amazon_linux_2023" {
  most_recent = true

  owners = ["137112412989"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*x86_64"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  rds_managed_master_secret_arn_pattern = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds!*"
}

#################################################
# SECURITY GROUP
#################################################

resource "aws_security_group" "db_admin" {
  name        = "${var.project_name}-${var.env}-db-admin-sg"
  description = "SSM managed DB admin EC2 SG"
  vpc_id      = data.aws_vpc.main.id

  # no inbound

  egress {
    description = "Allow outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-db-admin-sg"
    Project     = var.project_name
    Environment = var.env
  }
}

#################################################
# IAM ROLE
#################################################

resource "aws_iam_role" "db_admin" {
  name = "${var.project_name}-${var.env}-db-admin-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
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

resource "aws_iam_role_policy_attachment" "db_admin_ssm" {
  role = aws_iam_role.db_admin.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allows the DB admin instance to run the one-time app-user bootstrap.
# It can read the RDS-managed master secret, read/write the app DB secret,
# and ask Secrets Manager to generate a password when rotation is requested.
resource "aws_iam_policy" "db_admin_db_secrets" {
  name = "${var.project_name}-${var.env}-db-admin-db-secrets-policy"

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
          local.rds_managed_master_secret_arn_pattern,
          aws_secretsmanager_secret.db_password.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:PutSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.db_password.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetRandomPassword"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "db_admin_db_secrets" {
  role       = aws_iam_role.db_admin.name
  policy_arn = aws_iam_policy.db_admin_db_secrets.arn
}

#################################################
# INSTANCE PROFILE
#################################################

resource "aws_iam_instance_profile" "db_admin" {
  name = "${var.project_name}-${var.env}-db-admin-profile"

  role = aws_iam_role.db_admin.name
}

#################################################
# EC2
#################################################

resource "aws_instance" "db_admin" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"

  subnet_id = data.terraform_remote_state.network.outputs.private_app_subnet_ids[0]

  associate_public_ip_address = false

  vpc_security_group_ids = [
    aws_security_group.db_admin.id
  ]

  iam_instance_profile = aws_iam_instance_profile.db_admin.name

  user_data = <<-EOF
#!/bin/bash
dnf install -y python3
dnf install -y awscli || dnf install -y awscli-2 || true
dnf install -y mysql || dnf install -y mariadb105 || dnf install -y mariadb || true
EOF

  tags = {
    Name        = "${var.project_name}-${var.env}-db-admin"
    Project     = var.project_name
    Environment = var.env
  }

  lifecycle {
    # The DB admin host is an SSM-only helper. Avoid replacing it just because
    # the "most recent" Amazon Linux AMI changed between Terraform runs.
    ignore_changes = [ami]
  }
}
