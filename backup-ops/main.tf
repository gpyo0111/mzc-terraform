# AWS 계정 ID 조회
data "aws_caller_identity" "current" {}

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

# 3. AWS Backup Selection 설정 (와일드카드 + 태그 기반 동적 매핑)
resource "aws_backup_selection" "securevoice_backup_selection" {
  iam_role_arn = aws_iam_role.backup_role.arn
  name         = "securevoice-backup-selection"
  plan_id      = aws_backup_plan.securevoice_plan.id

  # 특정 RDS 인스턴스 의존성을 배제하고, 리전 내 모든 RDS 중 태그가 있는 대상을 동적 선택
  resources = [
    "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:db:*"
  ]

  # 태그 기반 동적 백업 타겟팅
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
