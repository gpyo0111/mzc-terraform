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

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs_policy]
}

# -------------------------------------------------------------------------
# 3. VPC 플로우 로그(차량 번호판 장부)를 적어둘 CloudWatch 로그 보관소 생성
# -------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${var.project_name}-${var.env}-flow-logs"
  retention_in_days = 30 # [비용 최적화] 민규 님이 지정하신 30일 자동 파쇄 타이머 작동
}

# -------------------------------------------------------------------------
# 4. 마당 입구에서 번호판을 적어 보관소에 전달할 비서(IAM Role) 임명
# -------------------------------------------------------------------------
resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.project_name}-${var.env}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${var.project_name}-${var.env}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------------------------
# 5. VPC 플로우 로그(VPC Flow Logs) 최종 가동 및 리모트 스테이트 결합
# -------------------------------------------------------------------------
resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL" # 들어오고 나가는 모든 네트워크 번호판 강제 기록
  vpc_id          = var.vpc_id  # 상위 네트워크 장부 자동 결합
}