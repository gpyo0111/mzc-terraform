# =========================================================================
# 1. AWS KMS 고객 관리형 마스터 키 (CMK) 프로비저닝
# =========================================================================
resource "aws_kms_key" "securevoice_master" {
  description = "SecureVoice 프로젝트 중요 자산 암호화용 전용 마스터 키"

  # [보안 설명] 연 1회 암호화 키를 자동으로 갱신하는 키 로테이션 기능입니다.
  # 기존 암호키가 유출되더라도 미래의 데이터를 보호하는 핵심 컴플라이언스 설정입니다.
  enable_key_rotation = true

  # [보안 설명] 실수로 삭제 명령이 떨어지더라도 30일 동안은 '삭제 대기' 상태로 유지되어
  # 언제든 복구가 가능하게 만드는 랜섬웨어 방지용 타임록(Time-lock) 가드레일입니다.
  deletion_window_in_days = 30

  # [키 정책 - 옵션 A: 안전한 명시적 정책]
  # statement 1: 계정 루트에 키 전체 권한 → 잠금사고(lockout) 방지 + 기존 IAM 기반 접근(ECS 등) 유지.
  # statement 2: 변조음성 탐지 ECS 태스크 역할만 암복호화 용도로 키 사용을 명시(관리자/사용자 분리·감사성↑).
  # ※ 향후 2회차에서 statement 1 제거 + ViaService 제한으로 강화 가능(비운영 테스트 후).
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "securevoice-master-key-policy"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowECSTaskRolesUseOfKey"
        Effect = "Allow"
        Principal = {
          AWS = [
            data.aws_iam_role.api_task_target.arn,
            data.aws_iam_role.worker_task_target.arn
          ]
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    ManagedBy = "terraform"
    Domain    = "Security"
    Layer     = "Encryption"
  }
}

# =========================================================================
# 2. 식별 편의성을 위한 키 별칭(Alias) 매핑
# =========================================================================
resource "aws_kms_alias" "securevoice_master_alias" {
  # 변수 파일에서 정의한 표준 이름인 'alias/securevoice-dev-master-key'를 매핑합니다.
  name          = var.kms_key_alias
  target_key_id = aws_kms_key.securevoice_master.key_id
}