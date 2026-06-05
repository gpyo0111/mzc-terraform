# 현재 환경이 사용할 기존 VPC를 조회한다.
data "aws_vpc" "main" {
  id = data.terraform_remote_state.network.outputs.vpc_id
}

# 모델 파일을 저장할 S3 버킷을 만든다.
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

# S3 버킷의 퍼블릭 접근을 전부 차단한다.
resource "aws_s3_bucket_public_access_block" "model" {
  bucket = aws_s3_bucket.model.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버킷 데이터를 현재 AWS 설정과 동일하게 KMS로 암호화한다.
resource "aws_s3_bucket_server_side_encryption_configuration" "model" {
  bucket = aws_s3_bucket.model.id

  rule {
    bucket_key_enabled = false

    apply_server_side_encryption_by_default {
      kms_master_key_id = "arn:aws:kms:ap-northeast-2:455535733131:key/5b711458-5f36-427f-b4a7-0daa1b81a0b1"
      sse_algorithm     = "aws:kms"
    }
  }
}

# RDS가 사용할 DB subnet group을 만든다.
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.env}-db-subnet-group"
  subnet_ids = data.terraform_remote_state.network.outputs.private_data_subnet_ids

  tags = {
    Name        = "${var.project_name}-${var.env}-db-subnet-group"
    Project     = var.project_name
    Environment = var.env
  }
}

# 애플리케이션 프라이빗 서브넷에서만 MySQL 접속을 허용하는 RDS 보안그룹이다.
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.env}-rds-sg"
  description = "Allow MySQL from ECS private app subnets"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "MySQL from private app subnets"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = data.terraform_remote_state.network.outputs.private_app_subnet_cidrs
  }

  ingress {
    description     = "Allow MySQL from DB admin EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.db_admin.id]
  }

  ingress {
    description     = "Allow MySQL from RDS Proxy"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.rds_proxy.id]
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

# 실제 MySQL 데이터베이스 인스턴스를 생성한다.
resource "aws_db_instance" "mysql" {
  identifier = "${var.project_name}-${var.env}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  snapshot_identifier = var.rds_snapshot_identifier != "" ? var.rds_snapshot_identifier : null

  # 새 DB 생성 시 초기 DB명과 master 계정명을 지정한다.
  # master 비밀번호는 Terraform 변수로 받지 않고 RDS가 Secrets Manager에서 자동 관리한다.
  db_name                     = var.rds_snapshot_identifier == "" ? var.db_name : null
  username                    = var.rds_snapshot_identifier == "" ? var.db_master_username : null
  manage_master_user_password = true

  port                   = 3306
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az = true

  backup_retention_period  = 7
  backup_window            = "18:00-19:00"
  maintenance_window       = "sun:19:00-sun:20:00"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-${var.env}-mysql-final-${var.final_snapshot_date}"
  deletion_protection       = true

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

# ECS API/worker가 사용할 app DB password secret의 껍데기만 만든다.
# 실제 비밀번호 값은 Terraform state에 남기지 않기 위해 bootstrap 스크립트가 put-secret-value로 저장한다.
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

# JWT 서명 키를 저장할 Secrets Manager 시크릿을 만든다.
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

# JWT 서명 키 값을 시크릿에 저장한다.
resource "aws_secretsmanager_secret_version" "jwt_secret_key" {
  secret_id     = aws_secretsmanager_secret.jwt_secret_key.id
  secret_string = "change-this-jwt-secret-key-before-demo"
}
