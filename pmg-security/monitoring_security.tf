# =========================================================================
# [Phase 4] 계정 거버넌스 및 모니터링 체계 수립 (CloudTrail + VPC Flow Logs)
# =========================================================================

# -------------------------------------------------------------------------
# 1. CloudTrail CCTV 녹화 테이프를 보관할 전용 S3 금고 생성
# -------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket        = "${var.project_name}-${var.env}-cloudtrail-logs-${var.account_id}"
  force_destroy = true # 프로젝트 실습 종료 후 버킷이 깔끔하게 지워지도록 설정

  tags = {
    Name        = "${var.project_name}-${var.env}-cloudtrail-logs"
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# S3 버킷 퍼블릭 액세스 차단 가드레일 (앞서 수립한 무신뢰 보안 규격 적용)
resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# [비용 최적화] CloudTrail 로그를 30일 후 자동 삭제하여 보관 비용 폭증을 방지합니다.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    id     = "expire-cloudtrail-logs-30d"
    status = "Enabled"
    filter {} # 버킷 내 전체 객체에 적용
    expiration { days = 30 }
  }
}

# AWS 감사 카메라(CloudTrail)가 이 S3 상자에 로그를 넣을 수 있도록 통로를 열어주는 문지기 정책
resource "aws_s3_bucket_policy" "cloudtrail_logs_policy" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# -------------------------------------------------------------------------
# 2. 전 세계 리전 감시 및 로그 변조 방지 도장이 결합된 CloudTrail 수립
# -------------------------------------------------------------------------
resource "aws_cloudtrail" "main" {
  name                          = "${var.project_name}-${var.env}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true # [멀티 리전] 해커가 다른 나라 방에 숨어드는 행위 차단
  enable_log_file_validation    = true # [무결성 검증] 테라폼 표준 파라미터명으로 전면 수정 완료

  # -----------------------------------------------------------------------
  # [객체 수준 감사] audio 버킷의 uploads/ 폴더에만 S3 Data Events 기록
  #   - 관리 이벤트(리소스 생성/삭제 등)는 그대로 유지(include_management_events=true)하면서
  #   - 음성 원본(생체정보)이 저장되는 uploads/ 객체의 Get/Put(누가 어떤 음성에 접근했는가)을 추가 기록.
  #   - [비용 통제] 생체정보 핵심인 uploads/ 1개 prefix로만 한정. results/(인식 결과)는 제외.
  #     (S3 Data Events는 10만건당 $0.10 → prefix 한정으로 불필요한 이벤트 과금 차단)
  #   - read_write_type="All": 업로드(Put)와 다운로드(Get) 모두 추적 → 생체정보 접근 감사.
  # -----------------------------------------------------------------------
  event_selector {
    read_write_type           = "All"
    include_management_events = true # 기존 관리 이벤트 기록 동작 보존 (이 블록 추가 시 기본값이 대체되므로 명시)

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${data.aws_s3_bucket.audio.arn}/uploads/"] # uploads/ 하위 객체만 감사 (results/ 제외)
    }
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs_policy]
}

# -------------------------------------------------------------------------
# 3. VPC 플로우 로그(차량 번호판 장부) 전용 S3 버킷 생성
#    [설계 변경] CloudWatch Logs 대신 S3에 적재 → 비용 절감 + Athena 분석 통일.
#    (GuardDuty는 VPC Flow Log를 자체 피드로 직접 읽으므로 탐지에는 영향 없음)
# -------------------------------------------------------------------------
resource "aws_s3_bucket" "vpc_flow_logs" {
  bucket        = "${var.project_name}-${var.env}-vpc-flow-logs-${var.account_id}"
  force_destroy = true # 프로젝트 실습 종료 후 버킷이 깔끔하게 지워지도록 설정

  tags = {
    Name        = "${var.project_name}-${var.env}-vpc-flow-logs"
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# 퍼블릭 액세스 전면 차단 가드레일
resource "aws_s3_bucket_public_access_block" "vpc_flow_logs" {
  bucket = aws_s3_bucket.vpc_flow_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# [비용 최적화] flow log를 30일 후 자동 삭제
resource "aws_s3_bucket_lifecycle_configuration" "vpc_flow_logs" {
  bucket = aws_s3_bucket.vpc_flow_logs.id

  rule {
    id     = "expire-vpc-flow-logs-30d"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

# AWS 로그 전송 서비스(delivery.logs.amazonaws.com)가 이 버킷에 flow log를 쓸 수 있도록 허용하는 정책
resource "aws_s3_bucket_policy" "vpc_flow_logs" {
  bucket = aws_s3_bucket.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource = aws_s3_bucket.vpc_flow_logs.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = var.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:aws:logs:${var.aws_region}:${var.account_id}:*" }
        }
      },
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.vpc_flow_logs.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = var.account_id
          }
          ArnLike = { "aws:SourceArn" = "arn:aws:logs:${var.aws_region}:${var.account_id}:*" }
        }
      }
    ]
  })
}

# -------------------------------------------------------------------------
# 4. VPC 플로우 로그 최종 가동 (S3 대상, Athena 비용 최적화 옵션 포함)
# -------------------------------------------------------------------------
resource "aws_flow_log" "main" {
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.vpc_flow_logs.arn
  traffic_type         = "ALL"      # 들어오고 나가는 모든 네트워크 번호판 강제 기록
  vpc_id               = var.vpc_id # 상위 네트워크 장부 자동 결합

  # Athena 쿼리 비용/성능 최적화: parquet 포맷 + Hive 호환 시간 파티션
  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  depends_on = [aws_s3_bucket_policy.vpc_flow_logs]
}