# RDS DB Instance 데이터 소스 조회
data "aws_db_instance" "mysql" {
  db_instance_identifier = "${var.project_name}-${var.env}-mysql"
}

# S3 오디오 버킷 데이터 소스 조회
data "aws_s3_bucket" "audio" {
  bucket = var.audio_bucket_name
}

# 1. AWS Backup Vault 생성
resource "aws_backup_vault" "securevoice_vault" {
  name        = "securevoice-vault"
  kms_key_arn = "arn:aws:kms:ap-northeast-2:455535733131:key/3229b4c8-2a82-49a6-8dbc-5b4fc5e8d73b"

  tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# 2. AWS Backup Plan 및 Rule 생성
resource "aws_backup_plan" "securevoice_plan" {
  name = "securevoice-test-plan"

  rule {
    rule_name         = "DailyBeforeOneDayDelete"
    target_vault_name = aws_backup_vault.securevoice_vault.name
    schedule          = "cron(0 5 ? * * *)"
    enable_continuous_backup = true

    lifecycle {
      delete_after = 1
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# 3. AWS Backup Selection 설정 (ARN 직접 지정 + 태그 기반)
resource "aws_backup_selection" "securevoice_backup_selection" {
  iam_role_arn = aws_iam_role.backup_role.arn
  name         = "securevoice-backup-selection"
  plan_id      = aws_backup_plan.securevoice_plan.id

  # 뼈대 폴더 미수정으로 인해 RDS 태그 유실 시에도 백업이 유지되도록 ARN 직접 추가
  resources = [
    data.aws_db_instance.mysql.db_instance_arn
  ]

  # 기존 태그 기반 선택 호환성 유지
  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "Daily"
  }
}

# 4. AWS Backup IAM Role 및 기본 정책 연결
resource "aws_iam_role" "backup_role" {
  name               = "AWSBackupDefaultServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "backup_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
  role       = aws_iam_role.backup_role.name
}

resource "aws_iam_role_policy_attachment" "restore_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
  role       = aws_iam_role.backup_role.name
}

# 5. S3 오디오 버킷의 Versioning 활성화
resource "aws_s3_bucket_versioning" "audio" {
  bucket = data.aws_s3_bucket.audio.id
  versioning_configuration {
    status = "Enabled"
  }
}
