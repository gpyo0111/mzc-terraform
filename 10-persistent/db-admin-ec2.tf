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
# RDS SG RULE
#################################################

resource "aws_security_group_rule" "rds_from_db_admin" {
  type      = "ingress"
  from_port = 3306
  to_port   = 3306
  protocol  = "tcp"

  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.db_admin.id

  description = "Allow MySQL from DB admin EC2"
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
              dnf install -y mysql
              EOF

  tags = {
    Name        = "${var.project_name}-${var.env}-db-admin"
    Project     = var.project_name
    Environment = var.env
  }
}