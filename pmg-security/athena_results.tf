# =========================================================================
# Athena 쿼리 결과 전용 S3 버킷 + 워크그룹(폴더 분리)
# -------------------------------------------------------------------------
# 왜 별도 버킷인가:
#   - 로그 '원본'(CloudTrail/Flow Logs) 버킷과 조회 '결과물'을 분리(섞이면 관리/권한/수명주기가 꼬임).
#   - 쿼리 결과 CSV에는 "누가 어떤 음성에 접근했나" 같은 민감한 조사 내용이 그대로 남으므로
#     퍼블릭 전면 차단 + 짧은 수명주기로 위생 관리.
#
# 왜 워크그룹을 나누나:
#   - Athena는 '워크그룹' 단위로 결과 저장 위치를 정함. 워크그룹을 나누지 않으면
#     CloudTrail/Flow 결과가 한 폴더에 섞임.
#   - 워크그룹별로 출력 위치를 박아 두면(cloudtrail/ vs flowlogs/) 자동으로 폴더가 분리됨.
#   - 덤: 결과 암호화(SSE) + 출력 위치 강제 + (옵션) 스캔량 상한을 워크그룹에서 통제.
#   - 사용처: Athena 콘솔에서 쿼리 실행 전 워크그룹을 선택 (ATHENA_SECURITY_QUERIES.md §0).
# =========================================================================
resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.project_name}-${var.env}-athena-results-${var.account_id}"
  force_destroy = true # 실습 종료 후 깔끔히 삭제되도록

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-athena-results"
  })
}

# 퍼블릭 액세스 전면 차단 (조사 결과물이라 외부 노출 절대 금지)
resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# [비용/위생] 쿼리 결과는 일회성이므로 14일 후 자동 삭제 (불필요한 민감 데이터 잔존 방지)
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-athena-results-14d"
    status = "Enabled"
    filter {}
    expiration { days = 14 }
  }
}

# -------------------------------------------------------------------------
# 워크그룹 1: CloudTrail 조사 전용 → 결과는 cloudtrail/ 폴더로
# -------------------------------------------------------------------------
resource "aws_athena_workgroup" "cloudtrail" {
  name          = "${var.project_name}-${var.env}-cloudtrail"
  force_destroy = true # 실습 종료 시 쿼리 이력까지 정리되도록

  configuration {
    enforce_workgroup_configuration    = true # 사용자가 임의로 다른 위치에 저장 못 하게 강제
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/cloudtrail/"

      encryption_configuration {
        encryption_option = "SSE_S3" # 결과물도 자동 암호화 (KMS 키정책 footgun 회피 위해 S3 관리키 사용)
      }
    }

    # [비용 가드레일·옵션] 한 쿼리가 이 용량 이상 스캔하면 자동 실패 → 실수로 비용 폭주 방지.
    # 발표 중 큰 조회가 막힐 수 있으니 기본은 주석 처리. 필요 시 해제(최소 10MB).
    # bytes_scanned_cutoff_per_query = 2147483648 # 2GB
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-cloudtrail"
  })
}

# -------------------------------------------------------------------------
# 워크그룹 2: VPC Flow Logs 조사 전용 → 결과는 flowlogs/ 폴더로
# -------------------------------------------------------------------------
resource "aws_athena_workgroup" "flowlogs" {
  name          = "${var.project_name}-${var.env}-flowlogs"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/flowlogs/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # bytes_scanned_cutoff_per_query = 2147483648 # 2GB (옵션)
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.env}-flowlogs"
  })
}
