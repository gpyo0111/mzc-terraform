data "aws_vpc" "main" {
  id = var.vpc_id
}

resource "aws_s3_bucket" "model" {
  bucket = var.model_bucket_name

  tags = {
    Name        = var.model_bucket_name
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "model" {
  bucket = aws_s3_bucket.model.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model" {
  bucket = aws_s3_bucket.model.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.env}-db-subnet-group"
  subnet_ids = var.private_db_subnet_ids

  tags = {
    Name        = "${var.project_name}-${var.env}-db-subnet-group"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.env}-rds-sg"
  description = "Allow MySQL from ECS private app subnets"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "MySQL from private app subnets"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.private_app_subnet_cidrs
  }

  egress {
    description = "All outbound inside VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-rds-sg"
    Project     = var.project_name
    Environment = var.env
  }
}

resource "aws_db_instance" "mysql" {
  identifier = "${var.project_name}-${var.env}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  port                   = 3306
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az = true

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = true

  auto_minor_version_upgrade = false

  tags = {
    Name        = "${var.project_name}-${var.env}-mysql"
    Project     = var.project_name
    Environment = var.env
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "db_password" {
  name = "${var.project_name}/${var.env}/db-password"

  recovery_window_in_days = 0

  tags = {
    Project     = var.project_name
    Environment = var.env
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}

resource "aws_secretsmanager_secret" "jwt_secret_key" {
  name = "${var.project_name}/${var.env}/jwt-secret-key"

  recovery_window_in_days = 0

  tags = {
    Project     = var.project_name
    Environment = var.env
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "jwt_secret_key" {
  secret_id     = aws_secretsmanager_secret.jwt_secret_key.id
  secret_string = "change-this-jwt-secret-key-before-demo"
}