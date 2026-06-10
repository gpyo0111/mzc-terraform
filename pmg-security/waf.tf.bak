# 1. AWS WAFv2 Web ACL 리전별 엔진 정의
resource "aws_wafv2_web_acl" "main" {
  name        = "securevoice-dev-waf"
  description = "Managed WAF for SecureVoice dev ALB in Count mode"
  scope       = "REGIONAL" # ALB에 바인딩하므로 REGIONAL 스코프 지정 (CloudFront는 CLOUDFRONT)

  # 기본 액션은 모두 통과(Allow)로 지정
  default_action {
    allow {}
  }

  # 규칙 1: AWS 관리형 코어 규칙 세트 (Core Rule Set - CRS)
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    # 핵심 가드레일: Block하지 않고 카운팅(감시)만 수행하여 오탐(False Positive) 방지
    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # 규칙 2: SQL 인젝션 방어 규칙 세트 (SQLi Rule Set)
  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # WAF 전체 통계 텔레메트리를 위한 시각화 설정
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "securevoice-dev-waf-global-metric"
    sampled_requests_enabled   = true
  }

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# 2. Web ACL과 최전방 Application Load Balancer(ALB) 결합 (Association)
resource "aws_wafv2_web_acl_association" "main" {
  # 기존에 생성해 두신 ALB의 리소스 명칭(예: aws_lb.main.arn)으로 타겟팅하셔야 합니다.
  resource_arn = data.aws_lb.target_alb.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}