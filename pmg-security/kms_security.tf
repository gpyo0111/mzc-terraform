# =========================================================================
# 1. AWS KMS 고객 관리형 마스터 키 (CMK) 프로비저닝
# =========================================================================
resource "aws_kms_key" "securevoice_master" {
  description             = "SecureVoice 프로젝트 중요 자산 암호화용 전용 마스터 키"
  
  # [보안 설명] 연 1회 암호화 키를 자동으로 갱신하는 키 로테이션 기능입니다.
  # 기존 암호키가 유출되더라도 미래의 데이터를 보호하는 핵심 컴플라이언스 설정입니다.
  enable_key_rotation     = true
  
  # [보안 설명] 실수로 삭제 명령이 떨어지더라도 30일 동안은 '삭제 대기' 상태로 유지되어
  # 언제든 복구가 가능하게 만드는 랜섬웨어 방지용 타임록(Time-lock) 가드레일입니다.
  deletion_window_in_days = 30

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