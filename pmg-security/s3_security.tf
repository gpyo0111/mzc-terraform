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
    # [비용 최적화] S3 Bucket Key 사용: 객체마다 KMS를 호출하지 않고 데이터키를 캐싱·재사용해
    # KMS API 호출(및 비용)을 대폭 절감합니다. 보안 수준은 동일.
    bucket_key_enabled = true
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
    bucket_key_enabled = true
  }
}

# =========================================================================
# [OAC 하드닝] 1. 콘솔로 생성된 실물 CloudFront 배포 정보 원격 스캔
# =========================================================================
data "aws_cloudfront_distribution" "cf" {
  id = "E2ZAHL4TTM1M8O" # AWS 콘솔에 표기된 우리 팀의 실제 CloudFront 배포 ID를 매핑합니다.
}

# =========================================================================
# [OAC 하드닝] 2. 최신 서명 기술(SigV4)이 탑재된 글로벌 OAC 컨트롤러 허브 생성
# =========================================================================
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.project_name}-${var.env}-s3-oac"                  # AWS 관리 창에 표시될 OAC 자원의 고유 식별 명칭입니다.
  description                       = "Standard OAC supporting SSE-KMS for SecureVoice Dev S3" # 해당 보안 자원의 구체적인 용도를 설명합니다.
  origin_access_control_origin_type = "s3"                                                     # 연동 대상 오리진 서버의 컴포넌트 규격을 S3 스토리지로 제한합니다.
  signing_behavior                  = "always"                                                 # CloudFront가 S3로 데이터를 요청할 때 무조건 암호화 보안 서명을 첨부하도록 강제합니다.
  signing_protocol                  = "sigv4"                                                  # AWS 최고 등급 보안 서명 연산 알고리즘인 Signature Version 4 프로토콜을 사용합니다.
}

# =========================================================================
# [OAC 하드닝] 3. (제거됨) audio 버킷 OAC 버킷 정책 — 죽은 설정 정리 (2026-06-23)
# -------------------------------------------------------------------------
# 사유: audio 버킷은 SSE-KMS(securevoice_master)로 암호화되는데, 그 KMS 키 정책에
#       CloudFront 복호화 권한이 없어 CloudFront로는 audio 객체를 복호화·서빙할 수 없음.
#       또한 음성(생체정보)은 API/프리사인드 URL 경로로만 주고받으므로 CloudFront 직접
#       서빙 대상도 아님 → 이 버킷 정책은 실효 없는 죽은 설정이라 제거.
#       (web_static OAC 정책은 KMS 비암호화 정적파일이라 정상 동작 → 아래에 유지)
# =========================================================================

# =========================================================================
# [OAC 하드닝] 4. 웹 정적 소스(React 컴포넌트) 버킷에도 동일한 OAC 정책 바인딩
# =========================================================================
resource "aws_s3_bucket_policy" "web_static_oac_policy" {
  bucket = data.aws_s3_bucket.web_static.id # 룩업해 온 웹 스태틱 버킷 ID에 방화벽 정책을 연결합니다.

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOACRead"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject" # 웹 소스(HTML/JS) 버킷은 유저들이 읽어 가기만 하므로 다운로드(GetObject) 권한만 타이트하게 개방합니다.
        Resource = "${data.aws_s3_bucket.web_static.arn}/*"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = data.aws_cloudfront_distribution.cf.arn # 오직 우리 국경 검문소를 거친 트래픽만 React 소스 파일에 접근을 허용합니다.
          }
        }
      }
    ]
  })
}