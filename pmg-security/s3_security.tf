# =========================================================================
# 1. 변수(variables.tf) 체계를 통한 실물 S3 버킷 동적 데이터 소스 룩업
# =========================================================================
data "aws_s3_bucket" "audio" {
  bucket = var.audio_bucket_name
}

data "aws_s3_bucket" "model" {
  bucket = var.model_bucket_name
}

data "aws_s3_bucket" "web_static" {
  bucket = var.web_static_bucket_name
}

data "aws_s3_bucket" "tf_state" {
  bucket = var.tf_state_bucket_name
}

# =========================================================================
# 2. [전체 4개 버킷] 변수 매핑 기반 퍼블릭 액세스 전면 차단 가드레일
# =========================================================================
resource "aws_s3_bucket_public_access_block" "audio_hardening" {
  bucket = data.aws_s3_bucket.audio.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "model_hardening" {
  bucket = data.aws_s3_bucket.model.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "web_static_hardening" {
  bucket = data.aws_s3_bucket.web_static.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "tf_state_hardening" {
  bucket = data.aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =========================================================================
# 3. 2중 하위 경로(uploads/results) 대입 기반 등급별 수명 주기 고도화 정책
# =========================================================================
resource "aws_s3_bucket_lifecycle_configuration" "audio_tier_lifecycle" {
  bucket = data.aws_s3_bucket.audio.id

  # -------------------------------------------------------------------------
  # [GUEST 등급] 7일 후 무조건 영구 파기 (유예 없음)
  # -------------------------------------------------------------------------
  rule {
    id     = "uploads-guest-retention"
    status = "Enabled"
    filter { prefix = "uploads/guest/" }
    expiration { days = 7 }
  }

  rule {
    id     = "results-guest-retention"
    status = "Enabled"
    filter { prefix = "results/guest/" }
    expiration { days = 7 }
  }

  # -------------------------------------------------------------------------
  # [FREE 등급] 30일 후 Glacier 비용 최적화 이관 -> 90일 후 영구 파기
  # -------------------------------------------------------------------------
  rule {
    id     = "uploads-free-lifecycle"
    status = "Enabled"
    filter { prefix = "uploads/free/" }

    transition {
      days          = 30
      storage_class = "GLACIER"
    }
    expiration { days = 90 }
  }

  rule {
    id     = "results-free-lifecycle"
    status = "Enabled"
    filter { prefix = "results/free/" }

    transition {
      days          = 30
      storage_class = "GLACIER"
    }
    expiration { days = 90 }
  }

  # -------------------------------------------------------------------------
  # [PAID 등급 - tenants] 30일 후 Glacier 백업 -> 365일(1년) 후 영구 파기
  # -------------------------------------------------------------------------
  rule {
    id     = "uploads-paid-tenants-lifecycle"
    status = "Enabled"
    filter { prefix = "uploads/tenants/" }

    transition {
      days          = 30
      storage_class = "GLACIER"
    }
    expiration { days = 365 }
  }

  rule {
    id     = "results-paid-tenants-lifecycle"
    status = "Enabled"
    filter { prefix = "results/tenants/" }

    transition {
      days          = 30
      storage_class = "GLACIER"
    }
    expiration { days = 365 }
  }
}

# =========================================================================
# [보안 고도화] 생성한 KMS 마스터 키를 이용한 S3 정적 암호화(SSE-KMS) 강제
# =========================================================================

# 오디오 버킷에 마스터 키 적용
resource "aws_s3_bucket_server_side_encryption_configuration" "audio_encryption" {
  bucket = data.aws_s3_bucket.audio.id

  rule {
    apply_server_side_encryption_by_default {
      # 우리가 만든 KMS 키의 ARN 주소를 호출하여 자물쇠로 사용합니다.
      kms_master_key_id = aws_kms_key.securevoice_master.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# AI 모델 버킷에도 동일한 마스터 키 적용
resource "aws_s3_bucket_server_side_encryption_configuration" "model_encryption" {
  bucket = data.aws_s3_bucket.model.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.securevoice_master.arn
      sse_algorithm     = "aws:kms"
    }
  }
}